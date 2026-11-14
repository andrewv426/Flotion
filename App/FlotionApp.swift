import FlotionCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationWillFinishLaunching(_ notification: Notification) {
        #if DEBUG || SELFTEST
        TestHost.willFinishLaunching()
        #endif
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG || SELFTEST
        TestHost.didFinishLaunching()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.flushNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct FlotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Flotion", id: "main") {
            RootView(model: model)
                .frame(minWidth: 820, minHeight: 520)
                .task {
                    delegate.model = model
                    await model.start()
                    #if DEBUG || SELFTEST
                    if let dir = ProcessInfo.processInfo.environment["FLOTION_MEMTEST"] {
                        await SelfTest.runMemory(model: model, output: URL(fileURLWithPath: dir))
                    } else if let dir = ProcessInfo.processInfo.environment["FLOTION_PERFTEST"] {
                        await SelfTest.runPerformance(model: model, output: URL(fileURLWithPath: dir))
                    } else if let dir = ProcessInfo.processInfo.environment["FLOTION_SELFTEST"] {
                        await SelfTest.run(model: model, output: URL(fileURLWithPath: dir))
                    }
                    #endif
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Page") { Task { await model.newPage() } }
                    .keyboardShortcut("n")
            }
            CommandGroup(replacing: .importExport) {
                Button("Export Page as Markdown…") { model.exportMarkdown() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Quick Find") { model.showQuickFind.toggle() }
                    .keyboardShortcut("k")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.editor?.undo() }
                    .keyboardShortcut("z")
                Button("Redo") { model.editor?.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Assistant") { model.ai?.isPanelOpen.toggle() }
                    .keyboardShortcut("j")
            }
            CommandMenu("Format") {
                Button("Bold") { NSApp.sendAction(#selector(BlockTextView.toggleBold(_:)), to: nil, from: nil) }
                    .keyboardShortcut("b")
                Button("Italic") { NSApp.sendAction(#selector(BlockTextView.toggleItalic(_:)), to: nil, from: nil) }
                    .keyboardShortcut("i")
                Button("Inline Code") { NSApp.sendAction(#selector(BlockTextView.toggleCode(_:)), to: nil, from: nil) }
                    .keyboardShortcut("e")
                Button("Strikethrough") { NSApp.sendAction(#selector(BlockTextView.toggleStrike(_:)), to: nil, from: nil) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: model)
        }
    }
}

struct RootView: View {
    let model: AppModel

    var body: some View {
        if let error = model.startupError {
            Text(error).padding(40)
        } else {
            HStack(spacing: 0) {
                SidebarView(model: model)
                    .frame(width: Theme.sidebarWidth)
                Rectangle().fill(Color(nsColor: Theme.divider)).frame(width: 1)
                Group {
                    if model.selectedPageID != nil {
                        EditorView(model: model, generation: model.editorGeneration, diagramGeneration: model.diagramGeneration)
                    } else {
                        Text("No page selected")
                            .foregroundStyle(Color(nsColor: Theme.secondary))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .background(Color(nsColor: Theme.page))
                .overlay(alignment: .topTrailing) {
                    if let ai = model.ai, !ai.isPanelOpen {
                        Button { ai.isPanelOpen = true } label: {
                            Label("Assistant", systemImage: "sparkles").font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color(nsColor: Theme.secondary))
                        .padding(10)
                        .help("Open the assistant (⌘J)")
                    }
                }
                if let ai = model.ai, ai.isPanelOpen {
                    Rectangle().fill(Color(nsColor: Theme.divider)).frame(width: 1)
                    AIPanelView(model: model, ai: ai)
                        .frame(width: 360)
                }
            }
            .overlay(alignment: .top) {
                if model.showQuickFind {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.18)
                            .contentShape(Rectangle())
                            .onTapGesture { model.showQuickFind = false }
                        QuickFindView(model: model).padding(.top, 110)
                    }
                }
            }
            // An opaque base, so the translucent divider blends with the page and not the bare window.
            .background(Color(nsColor: Theme.page))
            .ignoresSafeArea()
        }
    }
}
