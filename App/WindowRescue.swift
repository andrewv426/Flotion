import AppKit

/// Brings a window back when it has ended up where it cannot be reached: off every screen but
/// for a sliver in a corner. Clicking the Dock icon then activates the app and nothing appears.
/// It has been seen after a launch; what puts the window there is not known, so the app checks
/// for it whenever it opens, comes to the front, or the screens change.
@MainActor
enum WindowRescue {
    /// The least of a window that has to show on some screen for it to count as reachable: enough
    /// of the top edge to grab. A window the user has parked mostly off a screen keeps more than this.
    nonisolated static let reachable = NSSize(width: 80, height: 40)

    /// Where to put a window that cannot be reached, or nil when enough of it already shows.
    /// `screens` are the usable areas of the screens, the main one first.
    nonisolated static func rescued(_ frame: NSRect, screens: [NSRect]) -> NSRect? {
        guard let home = screens.first, frame.width > 0, frame.height > 0 else { return nil }
        let shows = screens.contains { screen in
            let part = screen.intersection(frame)
            return !part.isNull && part.width >= min(reachable.width, frame.width) && part.height >= min(reachable.height, frame.height)
        }
        guard !shows else { return nil }
        // The same size where it fits, in the middle of the main screen.
        let size = NSSize(width: min(frame.width, home.width), height: min(frame.height, home.height))
        return NSRect(x: home.midX - size.width / 2, y: home.midY - size.height / 2, width: size.width, height: size.height)
    }

    static func start() {
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didChangeScreenParametersNotification,
                     NSWindow.didBecomeMainNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { rescueWindows() }
            }
        }
    }

    static func rescueWindows() {
        #if DEBUG || SELFTEST
        // A background test run keeps its windows off screen on purpose.
        if TestHost.isBackground { return }
        #endif
        let screens = NSScreen.screens.map(\.visibleFrame)
        for window in NSApp.windows where window.isVisible && window.parent == nil && window.styleMask.contains(.titled) && !(window is NSPanel) {
            if let frame = rescued(window.frame, screens: screens) { window.setFrame(frame, display: true) }
        }
    }
}
