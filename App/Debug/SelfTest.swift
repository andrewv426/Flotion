#if DEBUG || SELFTEST
import AppKit
import FlotionAI
import FlotionCore
import WebKit

/// An in-process UI smoke test, run with `FLOTION_SELFTEST=<output dir>`.
///
/// It types through the real text views and key bindings, checks the model and the
/// database, and renders the window to PNG files. It needs no accessibility or
/// screen-recording permission, so it runs anywhere the app can launch.
@MainActor
enum SelfTest {
    static func run(model: AppModel, output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var failures: [String] = []
        var log: [String] = []

        func check(_ condition: Bool, _ what: String) {
            log.append((condition ? "ok   " : "FAIL ") + what)
            if !condition { failures.append(what) }
        }
        func pause(_ ms: Int = 120) async { try? await Task.sleep(for: .milliseconds(ms)) }
        /// Waits for a condition instead of guessing a delay, so the test is not timing-sensitive.
        func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
        func window() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil } }
        func responder() -> BlockTextView? { window()?.firstResponder as? BlockTextView }
        func type(_ text: String) {
            guard let tv = responder() else { failures.append("no focused text view when typing '\(text)'"); return }
            tv.insertText(text, replacementRange: tv.selectedRange())
        }
        func key(_ selector: Selector) { responder()?.doCommand(by: selector) }
        func snapshot(_ name: String) {
            guard let view = window()?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                failures.append("no window to snapshot for \(name)")
                return
            }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("\(name).png"))
        }
        let newline = #selector(NSResponder.insertNewline(_:))

        await waitFor { model.editor != nil && window() != nil }
        await pause(300)
        snapshot("01-launch")
        check(model.title == "Getting Started", "first launch opens the welcome page")
        check((model.editor?.blocks.count ?? 0) == 10, "welcome page has its 10 blocks")
        let welcomeID = model.selectedPageID

        await model.newPage()
        await pause(400)
        check(responder()?.isTitle == true, "a new page puts the caret in the title")
        type("Smoke test")
        await pause()
        check(model.title == "Smoke test", "typing in the title renames the page")
        check(model.pages.contains { $0.title == "Smoke test" }, "the sidebar sees the new title")

        key(newline)
        check(responder().map { !$0.isTitle } == true, "Return in the title moves to the first block")
        type("# "); type("Heading one")
        key(newline)
        type("Plain paragraph with bold word")
        if let tv = responder() {
            tv.setSelectedRange(NSRange(location: 21, length: 4))
            tv.toggleBold(nil)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        }
        key(newline)
        type("- "); type("first item")
        key(newline)
        type("second item")
        key(#selector(NSResponder.insertTab(_:)))
        key(newline); key(newline); key(newline)
        type("[] "); type("a task")
        key(newline); key(newline)
        type("---")
        // The empty block shows its hint, and plain typing (no Markdown shortcut, so no
        // row refresh) must repaint the view so the hint does not stay under the text.
        await pause()
        check(responder()?.drewPlaceholder == true, "an empty focused block shows its placeholder")
        type("Last line")
        await pause()
        check(responder()?.drewPlaceholder == false, "typing into an empty block clears its placeholder")
        await pause()

        let blocks = model.editor?.blocks ?? []
        check(blocks.map(\.type) == [.heading1, .paragraph, .bullet, .bullet, .todo, .divider, .paragraph],
              "typed blocks have the expected types, got \(blocks.map(\.type.rawValue))")
        check(blocks.map(\.plainText) == ["Heading one", "Plain paragraph with bold word", "first item", "second item", "a task", "", "Last line"],
              "typed blocks have the expected text, got \(blocks.map(\.plainText))")
        check(blocks.count > 3 && blocks[3].depth == 1, "Tab indents the second list item")
        check(blocks.count > 1 && blocks[1].runs.contains { $0.text == "bold" && $0.marks.contains(.bold) }, "Cmd-B makes the selection bold")
        check(responder()?.string == "Last line", "the caret ends in the last block")
        snapshot("02-edited")

        // Backspace at the start of a block merges it into the one above; undo brings it back.
        if blocks.count == 7, let tv = responder() {
            model.editor?.focus = nil
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            key(#selector(NSResponder.deleteBackward(_:)))
            check(model.editor?.blocks.count == 6, "Backspace at the start removes the divider above")
            model.editor?.undo()
            check(model.editor?.blocks.count == 7, "Undo restores it")
        }

        await pause(700) // let the debounced save land
        if let workspace = model.workspace, let pageID = model.selectedPageID {
            let saved = (try? workspace.blocks(pageID: pageID)) ?? []
            let current = model.editor?.blocks ?? []
            check(saved.map(\.id) == current.map(\.id) && saved.map(\.runs) == current.map(\.runs) && saved.map(\.type) == current.map(\.type),
                  "the database matches the editor after the autosave delay")
            check((try? workspace.page(id: pageID))?.title == "Smoke test", "the title is saved")

            // A write from another process (as flotion-mcp makes) appears without reloading.
            _ = try? workspace.insertBlocks(pageID: pageID, MarkdownCodec.parse("Added from outside the editor."),
                                            context: ChangeContext(actor: "selftest"))
            await waitFor { model.editor?.blocks.last?.plainText == "Added from outside the editor." }
            check(model.editor?.blocks.last?.plainText == "Added from outside the editor.", "an external write shows up live in the open page")
            snapshot("03-live-refresh")
        }

        // A diagram created the way the MCP tool creates one renders in the sandboxed web view.
        if let workspace = model.workspace, let pageID = model.selectedPageID {
            func frame(_ client: String, _ server: String, _ arrow: String) -> String {
                """
                <svg viewBox="0 0 600 220" xmlns="http://www.w3.org/2000/svg" font-family="var(--fl-font)">
                  <rect x="40" y="60" width="150" height="100" rx="10" fill="none" stroke="var(--fl-border)" stroke-width="2"/>
                  <rect x="410" y="60" width="150" height="100" rx="10" fill="none" stroke="var(--fl-border)" stroke-width="2"/>
                  <text x="115" y="105" text-anchor="middle" fill="var(--fl-text)" font-size="17" font-weight="600">Client</text>
                  <text x="485" y="105" text-anchor="middle" fill="var(--fl-text)" font-size="17" font-weight="600">Server</text>
                  <text x="115" y="130" text-anchor="middle" fill="var(--fl-muted)" font-size="13">\(client)</text>
                  <text x="485" y="130" text-anchor="middle" fill="var(--fl-muted)" font-size="13">\(server)</text>
                  \(arrow)
                </svg>
                """
            }
            func arrow(_ label: String, leftToRight: Bool) -> String {
                let (x1, x2) = leftToRight ? (200, 400) : (400, 200)
                return """
                <line x1="\(x1)" y1="110" x2="\(x2)" y2="110" stroke="var(--fl-accent)" stroke-width="3" stroke-linecap="round"/>
                <circle cx="\(x2)" cy="110" r="7" fill="var(--fl-accent)"/>
                <text x="300" y="96" text-anchor="middle" fill="var(--fl-accent)" font-size="15" font-weight="600">\(label)</text>
                """
            }
            let steps = [
                DiagramStep(title: "1. SYN", caption: "The client asks to open a connection.", svg: frame("SYN sent", "listening", arrow("SYN", leftToRight: true))),
                DiagramStep(title: "2. SYN-ACK", caption: "The server acknowledges and asks back.", svg: frame("SYN sent", "SYN received", arrow("SYN-ACK", leftToRight: false))),
                DiagramStep(title: "3. ACK", caption: "The client confirms. The connection is open.", svg: frame("established", "established", arrow("ACK", leftToRight: true))),
            ]
            let source = String(decoding: (try? JSONEncoder().encode(steps)) ?? Data(), as: UTF8.self)
            let created = try? workspace.createDiagram(pageID: pageID, title: "TCP three-way handshake", format: .steps, source: source,
                                                       height: 300, context: ChangeContext(actor: "selftest"))
            check(created != nil, "a steps diagram passes validation and is stored")
            await waitFor { model.editor?.blocks.last?.type == .diagram }
            await pause(1200) // the web view loads asynchronously
            check(model.editor?.blocks.last?.type == .diagram, "the diagram block appears in the open page")

            func findWebView(_ view: NSView?) -> WKWebView? {
                guard let view else { return nil }
                if let web = view as? WKWebView { return web }
                for sub in view.subviews { if let found = findWebView(sub) { return found } }
                return nil
            }
            if let web = findWebView(window()?.contentView) {
                let count = try? await web.evaluateJavaScript("window.flotion ? window.flotion.count : -1") as? Int
                check(count == 3, "the slideshow frame loaded with 3 steps, got \(String(describing: count))")
                let fetchResult = try? await web.callAsyncJavaScript(
                    "try { await fetch('https://example.com/'); return 'loaded' } catch (e) { return 'blocked' }",
                    arguments: [:], in: nil, contentWorld: .page) as? String
                check(fetchResult == "blocked", "fetch() from a diagram is blocked, got \(String(describing: fetchResult))")
                let imageResult = try? await web.callAsyncJavaScript(
                    "return await new Promise(r => { const i = new Image(); i.onload = () => r('loaded'); i.onerror = () => r('blocked'); i.src = 'https://example.com/a.png'; setTimeout(() => r('timeout'), 4000) })",
                    arguments: [:], in: nil, contentWorld: .page) as? String
                check(imageResult == "blocked", "a remote image in a diagram is blocked, got \(String(describing: imageResult))")
                func webSnapshot(_ name: String) async {
                    guard let image = try? await web.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    try? png.write(to: output.appendingPathComponent("\(name).png"))
                }
                await webSnapshot("05-diagram-step1")
                _ = try? await web.evaluateJavaScript("window.flotion.go(2)")
                await pause(500)
                await webSnapshot("06-diagram-step3")
            } else {
                check(false, "a web view exists for the visible diagram block")
            }
            snapshot("07-page-with-diagram")
        }

        // The assistant (a scripted provider stands in for Claude; see AIController.fakeProvider).
        if let ai = model.ai {
            await ai.refreshStatus()
            check(ai.status == .ready(plan: "test"), "the assistant reports ready")
            ai.isPanelOpen = true
            await pause(400)
            let before = model.editor?.blocks.count ?? 0
            await model.sendChat("Summarise this page")
            await waitFor { !ai.chat.isRunning && ai.chat.messages.count == 2 }
            await waitFor { (model.editor?.blocks.count ?? 0) == before + 1 }
            let reply = ai.chat.messages.last
            check(ai.chat.messages.count == 2 && reply?.text == "Added a summary to the end of the page.", "the chat reply streams into the panel")
            check(reply?.tools.map(\.label) == ["Adding content"], "tool activity is shown, got \(reply?.tools.map(\.label) ?? [])")
            check(reply?.changeCount == 1, "the reply knows it made one change, got \(reply?.changeCount ?? -1)")
            check(model.editor?.blocks.count == before + 1 && model.editor?.blocks.last?.plainText == "Summary added by the assistant.",
                  "the assistant's edit appears live in the open page")
            await pause(500)
            snapshot("08-assistant-panel")
            if let reply {
                await ai.chat.undo(reply.id)
                await waitFor { (model.editor?.blocks.count ?? 0) == before }
                check(model.editor?.blocks.count == before, "Undo on the reply removes its change from the page")
            }

            // Edit with AI on a selection.
            func findTextView(_ view: NSView?, containing text: String) -> BlockTextView? {
                guard let view else { return nil }
                if let tv = view as? BlockTextView, tv.string == text { return tv }
                for sub in view.subviews { if let found = findTextView(sub, containing: text) { return found } }
                return nil
            }
            if let tv = findTextView(window()?.contentView, containing: "Last line"), let controller = tv.controller {
                window()?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: 0, length: 4))
                await waitFor(2) { model.selection != nil }
                check(model.selection?.text == "Last", "selecting text is tracked for the assistant (first responder is the block: \(window()?.firstResponder === tv), responder: \(String(describing: window()?.firstResponder).prefix(60)), delegate set: \(tv.delegate != nil), controller selection: \(String(describing: controller.currentSelection?.text)))")
                check(controller.aiButton.isHidden == false && controller.aiButton.superview != nil, "the Edit with AI button appears at the selection")
                controller.editSelectionWithAI()
                await pause(300)
                check(controller.inlinePopover?.isShown == true, "the inline prompt opens")
                controller.inlineModel?.run("Make shorter")
                await waitFor { controller.inlineModel?.phase != .running }
                check(controller.inlineModel?.phase == .done && controller.inlineModel?.preview == "A shorter **sentence**.",
                      "the rewrite streams into a preview without touching the page")
                check(tv.string == "Last line", "the page is unchanged until the edit is accepted")
                let blockID = tv.blockID
                controller.finishInlineEdit(controller.inlineModel?.preview ?? "", blockID: blockID, range: NSRange(location: 0, length: 4), below: false)
                await pause(200)
                let edited = model.editor?.blocks.first { $0.id == blockID }
                check(edited?.plainText == "A shorter sentence. line", "accepting replaces only the selection, got \(edited?.plainText ?? "nil")")
                check(edited?.runs.contains { $0.text == "sentence" && $0.marks.contains(.bold) } == true, "Markdown in the result becomes formatting")
                check(controller.inlinePopover == nil && controller.aiButton.isHidden, "the prompt and button go away afterwards")
                model.editor?.undo()
                check(model.editor?.blocks.first { $0.id == blockID }?.plainText == "Last line", "one Undo reverts the AI edit")
            } else {
                check(false, "the 'Last line' block is on screen for the inline edit test")
            }
        }

        // Quick find
        if let workspace = model.workspace {
            let hits = (try? workspace.search("handsh")) ?? []
            check(hits.isEmpty, "diagram sources are not indexed as page text")
            let byBody = (try? workspace.search("paragraph bold")) ?? []
            check(byBody.first?.pageTitle == "Smoke test", "search finds the page by its content")
            model.showQuickFind = true
            await pause(300)
            snapshot("09-quick-find")
            model.showQuickFind = false
        }

        if let welcomeID {
            await model.open(welcomeID)
            await pause(300)
            check(model.title == "Getting Started", "switching pages loads the other page")
            snapshot("04-welcome")
        }

        log.append(failures.isEmpty ? "RESULT pass" : "RESULT fail (\(failures.count))")
        try? log.joined(separator: "\n").write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        model.flushNow()
        exit(failures.isEmpty ? 0 : 1)
    }
}

// MARK: - In-app performance budgets

extension SelfTest {
    /// Seconds since this process was started, from the kernel's record of its start time.
    private static func secondsSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_starttime
        return Date().timeIntervalSince1970 - (Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000)
    }

    private static func residentMegabytes() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    /// The idle-memory budget: a fresh launch, one 1,000-block page open, nothing else done.
    static func runMemory(model: AppModel, output: URL) async {
        if let page = model.pages.first(where: { $0.title == "One thousand" }) { await model.open(page.id) }
        try? await Task.sleep(for: .seconds(2))
        let megabytes = residentMegabytes()
        let ok = megabytes <= 150 && model.editor?.blocks.count == 1_000
        let line = String(format: "PERF %@ memory, fresh launch with a 1,000-block page open: %.1f MB (budget 150)", ok ? "ok  " : "OVER", megabytes)
        try? line.write(to: output.appendingPathComponent("memory.txt"), atomically: true, encoding: .utf8)
        exit(ok ? 0 : 1)
    }

    /// Measures the user-visible budgets inside the running app: launch, opening long pages,
    /// typing and scrolling. Run against a release build (Scripts/perftest.sh).
    static func runPerformance(model: AppModel, output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var lines: [String] = []
        var failed = 0
        func record(_ name: String, _ value: Double, unit: String = "ms", budget: Double) {
            let ok = value <= budget
            if !ok { failed += 1 }
            lines.append(String(format: "PERF %@ %@: %.1f %@ (budget %.0f)", ok ? "ok  " : "OVER", name, value, unit, budget))
        }
        func window() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil } }
        func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
            guard let view else { return nil }
            if let match = view as? T { return match }
            for sub in view.subviews { if let found = find(type, in: sub) { return found } }
            return nil
        }
        func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { await Task.yield() }
        }
        func controller() -> EditorController? { find(EditorTableView.self, in: window()?.contentView)?.delegate as? EditorController }
        func percentile(_ samples: [Double], _ p: Double) -> Double {
            let sorted = samples.sorted()
            return sorted.isEmpty ? -1 : sorted[Int(Double(sorted.count - 1) * p)]
        }

        // Launch: process start until the first page is on screen.
        await waitFor { model.editor != nil && controller()?.generation == model.editorGeneration }
        window()?.displayIfNeeded()
        record("launch to first page drawn", secondsSinceProcessStart() * 1000, budget: 400)

        guard let workspace = model.workspace else { return }
        func makePage(_ title: String, blocks: Int) -> String {
            let page = try! workspace.createPage(title: title)
            let words = "the quick brown fox jumps over a lazy dog while notes pages blocks and diagrams keep scrolling without a hitch".split(separator: " ")
            let drafts = (0..<blocks).map { i -> Block in
                let type: BlockType = i % 12 == 0 ? .heading2 : i % 5 == 0 ? .bullet : .paragraph
                let count = type == .heading2 ? 4 : 8 + (i * 37) % 60
                return Block(type, (0..<count).map { String(words[(i + $0 * 7) % words.count]) }.joined(separator: " "))
            }
            try! workspace.insertBlocks(pageID: page.id, drafts)
            return page.id
        }
        let small = makePage("Five hundred", blocks: 500)
        let medium = makePage("One thousand", blocks: 1_000)
        let large = makePage("Five thousand", blocks: 5_000)
        await model.reloadPages()

        func timeOpen(_ id: String) async -> Double {
            let start = CACurrentMediaTime()
            await model.open(id)
            await waitFor { controller()?.generation == model.editorGeneration }
            window()?.displayIfNeeded()
            return (CACurrentMediaTime() - start) * 1000
        }
        var open500: [Double] = [], open5000: [Double] = []
        for _ in 0..<6 {
            open500.append(await timeOpen(small))
            open5000.append(await timeOpen(large))
        }
        record("open 500-block page (median of 6)", percentile(open500, 0.5), budget: 50)
        record("open 5,000-block page (median of 6)", percentile(open5000, 0.5), budget: 150)
        record("open 5,000-block page (worst of 6)", open5000.max() ?? -1, budget: 150)

        // Typing in the 5,000-block page: insert, model update, row re-measure, draw.
        if let editorController = controller(), let first = model.editor?.blocks.first(where: { $0.type.hasText }) {
            model.editor?.focus = .init(blockID: first.id, offset: 0)
            model.editor?.onChange?(.rows([0]))
            await waitFor(2) { window()?.firstResponder is BlockTextView }
            _ = editorController
            if let tv = window()?.firstResponder as? BlockTextView {
                var samples: [Double] = []
                for i in 0..<150 {
                    let start = CACurrentMediaTime()
                    tv.insertText(i % 7 == 6 ? " " : "a", replacementRange: tv.selectedRange())
                    window()?.displayIfNeeded()
                    samples.append((CACurrentMediaTime() - start) * 1000)
                }
                record("keystroke to drawn, 5,000-block page (p95)", percentile(samples, 0.95), budget: 8)
            } else {
                lines.append("PERF OVER keystroke: no focused block")
                failed += 1
            }
        }

        // Scrolling: main-thread work per frame while moving 30 pt per frame (3,600 pt/s at 120 Hz).
        if let table = find(EditorTableView.self, in: window()?.contentView), let scroll = table.enclosingScrollView {
            var samples: [Double] = []
            var y: CGFloat = 0
            for _ in 0..<600 {
                y += 30
                let start = CACurrentMediaTime()
                scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(scroll.contentView)
                window()?.displayIfNeeded()
                samples.append((CACurrentMediaTime() - start) * 1000)
            }
            record("scroll frame work, 5,000-block page (p95)", percentile(samples, 0.95), budget: 8.3)
            record("scroll frame work, 5,000-block page (worst)", samples.max() ?? -1, budget: 16.6)
        }

        lines.append(String(format: "PERF info memory at the end of this stress run: %.1f MB", residentMegabytes()))
        _ = medium // measured separately, in a fresh launch (runMemory)

        lines.append(failed == 0 ? "RESULT pass" : "RESULT fail (\(failed))")
        try? lines.joined(separator: "\n").write(to: output.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        model.flushNow()
        exit(failed == 0 ? 0 : 1)
    }
}
#endif
