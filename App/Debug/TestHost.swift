#if DEBUG || SELFTEST
import AppKit

/// How the app behaves when a script runs it for a test (`FLOTION_SELFTEST`, `FLOTION_PERFTEST`
/// or `FLOTION_MEMTEST`): with its own preferences, and by default out of the user's way.
///
/// Background mode (the default for test runs; `FLOTION_FOREGROUND=1` turns it off):
/// - no Dock icon or menu bar, and the app never comes to the front or takes the keyboard;
/// - its windows are transparent, pushed off-screen and ignore the mouse, while AppKit still lays out and draws them;
/// - checks that need keyboard focus cannot run, so `SelfTest` skips them and lists them in result.txt.
/// - App Nap is held off so timers and timings are not throttled while it is out of sight.
@MainActor
enum TestHost {
    private static let environment = ProcessInfo.processInfo.environment

    /// True for any scripted test run.
    static let isActive = ["FLOTION_SELFTEST", "FLOTION_PERFTEST", "FLOTION_MEMTEST"].contains { environment[$0] != nil }
    static let isBackground = isActive && environment["FLOTION_FOREGROUND"] != "1"

    /// Test runs read and write preferences here, never in the user's own domain.
    nonisolated static let defaultsSuite = "app.flotion.Flotion.tests"

    private static let offscreen = NSPoint(x: -30_000, y: -30_000)
    /// Class-name prefixes of the system's text-input helper windows, seen in this app's process.
    private static let systemTextInputWindows = ["NSCampo", "TUINSWindow", "SPRoundedWindow"]
    private static var activity: NSObjectProtocol?

    static func willFinishLaunching() {
        guard isActive else { return }
        // Each run starts from empty preferences, like a first launch.
        UserDefaults.standard.removePersistentDomain(forName: defaultsSuite)
        guard isBackground else { return }
        NSApp.setActivationPolicy(.accessory)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                         reason: "Flotion test run in the background")
    }

    static func didFinishLaunching() {
        guard isActive else { return }
        let center = NotificationCenter.default
        prepareWindows()
        // AppKit's private "will become visible" notice arrives before a window reaches the screen,
        // so popovers, the slash menu and system text-input windows never flash. Undocumented, so
        // the end of every event-loop pass is checked as well.
        center.addObserver(forName: Notification.Name("_NSWindowWillBecomeVisible"), object: nil, queue: nil) { note in
            // AppKit posts this on the main thread, where windows are ordered.
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { if let window { prepare(window) } }
        }
        center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { prepareWindows() }
        }
        if isBackground {
            // macOS sometimes lets the app become active anyway, for example when a popover wants a
            // focused text field while the user is in the app that launched the test. Hand focus
            // straight back, and count it so the run reports it.
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    focusTakenCount += 1
                    NSApp.deactivate()
                }
            }
        } else {
            // In the foreground, ask for focus so checks that need it can run. macOS may still say no
            // while the user is busy in another app; those checks then report themselves as skipped.
            NSApp.activate()
        }
    }

    /// How often a background run was made active (and gave focus back).
    private(set) static var focusTakenCount = 0

    private static func prepareWindows() {
        NSApp.windows.forEach(prepare)
    }

    /// Stops a test window saving its frame over the user's, and in background mode hides it.
    /// Safe to call again on the same window: it only changes what is not already set.
    private static func prepare(_ window: NSWindow) {
        if window.parent == nil, !window.frameAutosaveName.isEmpty { window.setFrameAutosaveName("") }
        guard isBackground else { return }
        // macOS's own text-input helpers (autocorrect and completion bubbles, the input-source
        // indicator, Writing Tools) fade themselves in over any transparency set here, and no test
        // needs them, so they are closed as they appear.
        if systemTextInputWindows.contains(where: { NSStringFromClass(type(of: window)).hasPrefix($0) }) {
            window.alphaValue = 0
            if window.isVisible { window.orderOut(nil) }
            return
        }
        // Every window is transparent (a child does not inherit its parent's). AppKit still lays
        // them out and draws them, so checks and snapshots work as before.
        if window.alphaValue != 0 { window.alphaValue = 0 }
        if !window.ignoresMouseEvents { window.ignoresMouseEvents = true }
        // The window server still keeps a corner of a titled window on screen, which is why the
        // transparency matters. Child windows such as the slash menu follow their parent.
        if window.parent == nil, window.frame.origin != offscreen { window.setFrameOrigin(offscreen) }
    }
}
#endif
