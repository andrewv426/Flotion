#if DEBUG || SELFTEST
import AppKit
import FlotionAI
import FlotionCore
import FlotionEditor
import SwiftUI
import WebKit

/// An in-process UI smoke test, run with `FLOTION_SELFTEST=<output dir>`.
///
/// It types through the real text views and key bindings, checks the model and the
/// database, and renders the window to PNG files. It needs no accessibility or
/// screen-recording permission, so it runs anywhere the app can launch.
@MainActor
enum SelfTest {
    /// Runs long message chains without wall-clock waits; WebKit still supplies real SVG geometry.
    private static func checkFlowSequence(web: WKWebView, output: URL, check: (Bool, String) -> Void) async {
        let source = """
            flow right
            a: Sender
            b: Relay
            c: Receiver
            a -> b -> c
            c -> a {style: dashed}
            step "Ready"
            step "Exchange"
              send a -> b: first
              send b -> c: second
              send c -> a: reply
              send a -> b: last
              tag a, b, c: arrived
            step "Finished"
            """
        guard let scene = try? FlowScene(source: source) else {
            check(false, "the message-chain fixture parses")
            return
        }
        let originalFrame = web.frame
        web.setFrameSize(NSSize(width: 720, height: scene.displayHeight(forWidth: 720)))
        defer { web.frame = originalFrame }
        let clock = """
            let now = 0, frames = [], timers = [], serial = 0;
            performance.now = () => now;
            window.requestAnimationFrame = callback => { frames.push(callback); return ++serial; };
            window.setTimeout = (callback, delay) => { const id = ++serial; timers.push({ id, at: now + delay, callback }); return id; };
            window.clearTimeout = id => { timers = timers.filter(t => t.id !== id); };
            window.flowClock = { step: () => {
              now += 20;
              const pending = frames; frames = []; pending.forEach(f => f(now));
              const due = timers.filter(t => t.at <= now); timers = timers.filter(t => t.at > now);
              due.forEach(t => t.callback());
            } };
            """
        for reduced in [false, true] {
            let setup = "window.flowReduced = \(reduced); window.matchMedia = () => ({ matches: \(reduced) });\n" + clock
            let html = DiagramTemplate.flowDocument(scene).replacingOccurrences(of: "<script>", with: "<script>" + setup)
            web.loadHTMLString(html, baseURL: nil)
            for _ in 0..<100 {
                if (try? await web.evaluateJavaScript("window.flowReduced === \(reduced) && !!window.flowClock && !!window.flotion") as? Bool) == true { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let result = try? await web.evaluateJavaScript("""
                (() => {
                  const scene = JSON.parse(document.getElementById('scene').textContent);
                  const nodes = [...document.querySelectorAll('.node')];
                  const edges = [...document.querySelectorAll('.edge')], labels = [...document.querySelectorAll('.elabel')];
                  const arrived = i => nodes[i].querySelector('.tag').textContent === 'arrived';
                  const running = e => e.getAnimations().some(a => a.playState === 'running');
                  const lit = k => edges[k].classList.contains('live') && labels[k].classList.contains('live');
                  const unlit = k => !edges[k].classList.contains('live') && !labels[k].classList.contains('live');
                  // Every node and arrow shows exactly the given step's resolved state.
                  const matches = i => {
                    const step = scene.steps[i];
                    return step.nodes.every((s, k) => {
                      const n = nodes[k];
                      return n.classList.contains('off') === !s.on && n.classList.contains('dim') === s.dim &&
                        n.querySelector('.label').textContent === s.label && n.querySelector('.tag').textContent === s.tag &&
                        (n.dataset.tone ?? null) === (s.tone ?? null);
                    }) && step.edges.every((s, k) =>
                      edges[k].classList.contains('off') === !s.on && edges[k].classList.contains('dim') === s.dim &&
                      edges[k].classList.contains('at-hi') === s.hi && labels[k].textContent === s.label && (s.live ? lit(k) : unlit(k)));
                  };
                  const initial = matches(0);
                  window.flotion.go(1);
                  const sends = scene.steps[1].sends, senders = [0, 1, 2, 0];
                  const sendDots = [...document.querySelectorAll('.token')];
                  // Arrows carrying a message wait for it; each lights the moment its message leaves.
                  let liveOnDeparture = sendDots.length === sends.length && sends.every(s => unlit(s.edge));
                  let emits = true, responds = true, landings = 0, growsIn = true, absorbs = true, absorbing = false;
                  const departed = new Set(), landed = new Set();
                  document.getElementById('play').click();
                  let serial = true, held = true, curve = false, lastReceiver = true, traveled = false;
                  let completedAt = null;
                  for (let frame = 0; frame < 400; frame++) {
                    window.flowClock.step();
                    const dots = [...document.querySelectorAll('.token')];
                    const visible = dots.filter(d => +d.getAttribute('opacity') > .5);
                    serial &&= visible.length <= 1;
                    traveled ||= visible.length > 0;
                    curve ||= visible.some(d => Math.abs(+d.getAttribute('cy') - \(scene.nodes[0].y)) > 10);
                    if (window.flotion.index() === 1) {
                      sendDots.forEach((d, j) => {
                        if (d.hasAttribute('cx') && !departed.has(j)) {
                          departed.add(j);
                          emits &&= running(nodes[senders[j]].querySelector('.ring'));
                          growsIn &&= +d.getAttribute('r') < 3;
                        }
                        const opacity = +d.getAttribute('opacity'), r = +d.getAttribute('r');
                        if (d.isConnected && opacity > 0 && opacity < 1) { absorbing = true; absorbs &&= r >= 2 && r < 4.5; }
                        if (!d.isConnected && !landed.has(j)) {
                          landed.add(j);
                          landings++;
                          const receiver = nodes[sends[j].to];
                          responds &&= running(receiver.querySelector('.inner')) && running(receiver.querySelector('.ring'));
                        }
                      });
                      liveOnDeparture &&= sends.every(s => sends.some((o, j) => o.edge === s.edge && departed.has(j)) ? lit(s.edge) : unlit(s.edge));
                    }
                    if (dots.length > 0) {
                      held &&= window.flotion.index() === 1;
                      lastReceiver &&= !arrived(1);
                    } else if (completedAt === null) completedAt = frame;
                    if (completedAt !== null && frame - completedAt < 50) held &&= window.flotion.index() === 1;
                  }
                  const finished = serial && held && curve && lastReceiver && traveled && completedAt !== null &&
                    nodes.every((_, i) => arrived(i)) && !document.querySelector('.message-trail') && window.flotion.index() === 2;
                  const after = matches(2);
                  // A seek the moment a message lands cancels the receiver's bump and pulse.
                  window.flotion.go(0);
                  window.flotion.go(1);
                  let landing = false;
                  for (let i = 0; i < 100 && !landing; i++) {
                    window.flowClock.step();
                    landing = running(nodes[1].querySelector('.inner'));
                  }
                  window.flotion.go(0);
                  const cancelled = landing && nodes.every(n => !running(n.querySelector('.inner')) && !running(n.querySelector('.ring')));
                  // Seeks in mid-journey settle on the target step's own state, with no arrow left unlit.
                  for (let i = 0; i < 250; i++) window.flowClock.step();
                  let settled = matches(0);
                  window.flotion.go(1);
                  for (let i = 0; i < 30; i++) window.flowClock.step();
                  window.flotion.go(2);
                  for (let i = 0; i < 250; i++) window.flowClock.step();
                  settled &&= matches(2);
                  window.flotion.go(0);
                  window.flotion.go(1);
                  for (let i = 0; i < 30; i++) window.flowClock.step();
                  window.flotion.go(0);
                  window.flotion.go(1);
                  for (let i = 0; i < 300; i++) window.flowClock.step();
                  settled &&= matches(1);
                  window.flotion.go(0);
                  for (let i = 0; i < 250; i++) window.flowClock.step();
                  document.getAnimations().forEach(a => a.finish());
                  settled &&= matches(0) && window.flotion.index() === 0;
                  return { journey: finished && initial && after, live: liveOnDeparture && departed.size === sends.length,
                           respond: emits && responds && landings === sends.length && growsIn && absorbs && absorbing,
                           cancelled, settled };
                })()
                """) as? [String: Bool]
            let label = reduced ? " (with macOS Reduce Motion enabled)" : ""
            check(result?["journey"] == true, "ordered curved journeys commit on arrival and finish before autoplay advances" + label)
            check(result?["live"] == true, "an arrow carrying a message stays unlit until the message departs, then lights" + label)
            check(result?["respond"] == true, "a message grows out of a pulsing sender and shrinks into a receiver that bumps and pulses" + label)
            check(result?["cancelled"] == true, "a seek cancels the receiver's bump and pulse" + label)
            check(result?["settled"] == true, "seeks mid-journey settle every node and arrow on the target step's state" + label)
            if !reduced {
                for (name, script) in [
                    ("06b-flow-before", "window.flotion.go(0)"),
                    // The reply a third of the way round the long dashed loop, where its tail is at full length.
                    ("06c-flow-travel", "window.flotion.go(1); const reply = document.querySelectorAll('.edge')[2];" +
                        "for (let i = 0; i < 400 && !reply.classList.contains('live'); i++) window.flowClock.step();" +
                        "for (let i = 0; i < 18; i++) window.flowClock.step()")
                ] {
                    // The page's own background, so the picture reads the same on any backdrop.
                    _ = try? await web.evaluateJavaScript(script + "; document.getAnimations().forEach(a => a.finish());" +
                        "document.body.style.background = getComputedStyle(document.documentElement).getPropertyValue('--fl-bg')")
                    if let image = try? await web.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: output.appendingPathComponent("\(name).png"))
                    }
                }
            }
        }
    }

    static func run(model: AppModel, output: URL) async {
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var failures: [String] = []
        var log: [String] = []

        func check(_ condition: Bool, _ what: String) {
            log.append((condition ? "ok   " : "FAIL ") + what)
            if !condition { failures.append(what) }
        }
        /// Some behaviour only happens when the app has keyboard focus (SwiftUI key handlers, for one).
        /// A run in the background never takes focus, so such checks are skipped and listed, never
        /// passed silently. Wrap them as `if needsFocus("what is checked") { ... }`.
        func needsFocus(_ what: String) -> Bool {
            if NSApp.isActive { return true }
            log.append("skip \(what): needs keyboard focus; run FLOTION_FOREGROUND=1 Scripts/selftest.sh")
            return false
        }
        func pause(_ ms: Int = 120) async { try? await Task.sleep(for: .milliseconds(ms)) }
        /// Waits for a condition instead of guessing a delay, so the test is not timing-sensitive.
        func waitFor(_ seconds: Double = 5, _ condition: () -> Bool) async {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        }
        func window() -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.contentView != nil } }
        func responder() -> BlockTextView? { window()?.firstResponder as? BlockTextView }
        func findView<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
            guard let view else { return nil }
            if let match = view as? T { return match }
            for sub in view.subviews { if let found = findView(type, in: sub) { return found } }
            return nil
        }
        func findController() -> EditorController? {
            findView(EditorTableView.self, in: window()?.contentView)?.delegate as? EditorController
        }
        func type(_ text: String) {
            guard let tv = responder() else { failures.append("no focused text view when typing '\(text)'"); return }
            tv.insertText(text, replacementRange: tv.selectedRange())
        }
        func key(_ selector: Selector) { responder()?.doCommand(by: selector) }
        func pressDiagramKey(_ character: String, code: UInt16, in table: EditorTableView) {
            guard let w = table.window,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: w.windowNumber, context: nil, characters: character,
                                               charactersIgnoringModifiers: character, isARepeat: false, keyCode: code) else { return }
            table.keyDown(with: event)
        }
        func snapshot(_ name: String, view explicitView: NSView? = nil) {
            guard let view = explicitView ?? window()?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
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

            // Below the last block there is room to scroll it up and click to keep typing.
            if let table = findView(EditorTableView.self, in: window()?.contentView),
               let controller = table.delegate as? EditorController, let scroll = table.enclosingScrollView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, table.frame.height - scroll.contentView.bounds.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
                window()?.displayIfNeeded()
                let lastBlock = table.rect(ofRow: controller.endRow - 1)
                let gap = scroll.contentView.bounds.maxY - lastBlock.maxY
                check(gap >= Theme.minimumEndSpace - 1, "scrolled to the end, the last block sits \(Int(gap)) pt above the bottom edge")
                let count = model.editor?.blocks.count ?? 0
                if let end = table.view(atColumn: 0, row: controller.endRow, makeIfNecessary: false) as? EndSpaceCell,
                   let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window()?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    end.mouseDown(with: event)
                    end.mouseDown(with: event)
                    await pause()
                    check(model.editor?.blocks.count == count + 1 && model.editor?.blocks.last?.type == .paragraph
                          && model.editor?.blocks.last?.runs.isEmpty == true,
                          "clicking below the last block adds one empty block, however often it is clicked")
                    check(responder()?.blockID == model.editor?.blocks.last?.id, "the caret goes to that empty block")
                    type("Typed at the end")
                    check(model.editor?.blocks.last?.plainText == "Typed at the end", "typing there fills the new block")
                    snapshot("03b-end-space")
                    // Let it save before the next external write appends after it.
                    await waitFor { model.editor?.hasPendingChanges == false }
                    await pause(100)
                } else {
                    check(false, "the space after the last block is a row of the table")
                }
            }
        }

        // A diagram created the way the MCP tool creates one renders in the sandboxed web view.
        if let workspace = model.workspace, let pageID = model.selectedPageID {
            let source = """
                flow right
                client: Client
                server: Server
                client -> server
                step "SYN": The client asks to open a connection.
                  send client -> server: SYN
                  tag client: SYN sent
                  tag server: listening
                step "SYN-ACK": The server acknowledges and asks back.
                  send server -> client: SYN-ACK
                  tag server: SYN received
                step "ACK": The client confirms. The connection is open.
                  send client -> server: ACK
                  tag client, server: established
                  mark client, server: good
                """
            let created = try? workspace.createDiagram(pageID: pageID, title: "TCP three-way handshake", format: .flow, source: source,
                                                       context: ChangeContext(actor: "selftest"))
            check(created != nil, "a Flow diagram passes validation and is stored")
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
                // The document loads in its own process: wait for the player instead of guessing how long that takes.
                for _ in 0..<100 {
                    if (try? await web.evaluateJavaScript("!!window.flotion") as? Bool) == true { break }
                    await pause(50)
                }
                let count = try? await web.evaluateJavaScript("window.flotion ? window.flotion.count : -1") as? Int
                check(count == 3, "the player loaded with 3 steps, got \(String(describing: count))")
                let drawn = try? await web.evaluateJavaScript("document.querySelectorAll('.node').length * 10 + document.querySelectorAll('.edge').length") as? Int
                check(drawn == 21, "the player drew 2 nodes and 1 edge, got \(String(describing: drawn))")
                let fits = try? await web.evaluateJavaScript("document.documentElement.scrollHeight <= window.innerHeight + 1") as? Bool
                check(fits == true, "the diagram block is exactly as tall as its drawing, caption and controls")
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
                let sequence = try? await web.evaluateJavaScript("""
                    (() => {
                      const next = document.getElementById('next');
                      const prev = document.getElementById('prev');
                      const title = document.getElementById('cap-title');
                      const seen = [];
                      for (const button of [next, next, prev, prev, next, next]) {
                        button.click();
                        seen.push(window.flotion.index() + ':' + title.textContent);
                      }
                      const caption = document.getElementById('caption');
                      const outgoing = document.querySelectorAll('.cap-copy[aria-hidden="true"]');
                      const animated = caption.getAnimations().length > 0;
                      return { sequence: seen.join('|'), motion:
                        animated && outgoing.length > 0 && [...outgoing].every(copy => !copy.querySelector('[id]')) };
                    })()
                    """) as? [String: Any]
                let captions = sequence?["sequence"] as? String
                check(captions == "1:SYN-ACK|2:ACK|1:SYN-ACK|0:SYN|1:SYN-ACK|2:ACK",
                      "rapid diagram clicks update the step and caption together, got \(String(describing: captions))")
                check(sequence?["motion"] as? Bool == true, "caption motion stays animated and keeps outgoing text out of accessibility")
                await pause(900)
                let settled = try? await web.evaluateJavaScript("document.querySelectorAll('.cap-copy').length === 1") as? Bool
                check(settled == true, "interrupted caption animations clean up after settling")
                let last = try? await web.evaluateJavaScript("[...document.querySelectorAll('.node')].map(n => n.dataset.tone + ':' + n.querySelector('.tag').textContent).join(' ')") as? String
                check(last == "good:established good:established", "step 3 shows both ends established, got \(String(describing: last))")
                let head = try? await web.evaluateJavaScript("document.querySelector('.edge').classList.contains('at-hi')") as? Bool
                check(head == true, "the arrowhead is at the server end on the final ACK")
                await webSnapshot("06-diagram-step3")
                _ = try? await web.evaluateJavaScript("document.getElementById('prev').click()")
                await pause(360)
                await webSnapshot("06a-diagram-reply-travel")
                let journey = try? await web.callAsyncJavaScript("""
                    const receiver = document.querySelectorAll('.node')[0];
                    const tag = () => receiver.querySelector('.tag').textContent;
                    const pending = tag() === 'established';
                    const samples = [];
                    const deadline = performance.now() + 3000;
                    while (performance.now() < deadline) {
                      await new Promise(requestAnimationFrame);
                      const dot = document.querySelector('.token');
                      if (!dot) break;
                      if (+dot.getAttribute('opacity') > .5) {
                        samples.push({ x: +dot.getAttribute('cx'), pending: tag() === 'established',
                          trail: +document.querySelector('.message-trail').getAttribute('stroke-dasharray').split(' ')[0] > 0 });
                      }
                    }
                    return { pending, samples: samples.length,
                      movedBack: samples.length > 1 && samples[0].x > samples[samples.length - 1].x,
                      stayedPending: samples.every(s => s.pending), trail: samples.some(s => s.trail),
                      arrived: tag() === 'SYN sent', cleaned: !document.querySelector('.message-trail'),
                      pulse: receiver.querySelector('.ring').getAnimations().some(a => a.playState === 'running') &&
                        receiver.querySelector('.inner').getAnimations().some(a => a.playState === 'running') };
                    """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
                check(journey?["pending"] as? Bool == true && journey?["stayedPending"] as? Bool == true,
                          "a receiver keeps its previous status while the message is traveling")
                check(journey?["movedBack"] as? Bool == true && journey?["trail"] as? Bool == true,
                          "the reply visibly travels backward along the arrow with a tapering trail")
                check(journey?["arrived"] as? Bool == true && journey?["pulse"] as? Bool == true && journey?["cleaned"] as? Bool == true,
                          "arrival reveals the receiving status, pulses and bumps the receiver and removes the travel graphics")
                // Interrupt a reply, jump with a dot, then go back with the keyboard. Only the
                // latest destination may commit a delayed receiver update.
                _ = try? await web.evaluateJavaScript("document.getElementById('next').click()")
                await pause(300)
                _ = try? await web.evaluateJavaScript("""
                    document.querySelectorAll('.dot')[0].click();
                    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }));
                    """)
                await pause(1000)
                let interrupted = try? await web.evaluateJavaScript("""
                    window.flotion.index() === 1 && document.getElementById('cap-title').textContent === 'SYN-ACK' &&
                    [...document.querySelectorAll('.node .tag')].map(n => n.textContent).join('|') === 'SYN sent|SYN received' &&
                    [...document.querySelectorAll('.node')].every(n => !n.dataset.tone) &&
                    !document.querySelector('.token, .message-trail')
                    """) as? Bool
                check(interrupted == true, "interrupting a journey via arrows, dots and keyboard cannot apply a stale arrival")
                _ = try? await web.evaluateJavaScript("window.flotion.go(2)")
                await pause(1000)
                if let scroll = web.enclosingScrollView, let table = scroll.documentView as? EditorTableView,
                   let controller = table.editor, let editor = model.editor,
                   let diagram = editor.blocks.last, let w = table.window {
                    let row = editor.blocks.count
                    let previous = table.view(atColumn: 0, row: row - 1, makeIfNecessary: true) as? TextBlockCell
                    let webPoint = table.convert(NSPoint(x: web.bounds.midX, y: web.bounds.midY), from: web)
                    let hit = table.hitTest(table.convert(webPoint, to: table.superview))
                    check(hit === web || hit?.isDescendant(of: web) == true, "the interactive diagram receives clicks inside the player")
                    let clip = scroll.contentView
                    let original = clip.bounds.origin
                    clip.scroll(to: NSPoint(x: 0, y: table.frame.height - clip.bounds.height))
                    scroll.reflectScrolledClipView(clip)
                    w.displayIfNeeded()
                    let bottom = clip.bounds.minY
                    if web.visibleRect.contains(NSPoint(x: web.bounds.midX, y: web.bounds.midY)),
                       let wheel = TestHost.wheelEvent(over: web, deltaY: 40) {
                        // Dequeue the event so AppKit exposes it as the current event during hit-testing.
                        NSApp.postEvent(wheel, atStart: true)
                        if let queuedWheel = NSApp.nextEvent(matching: .scrollWheel, until: .distantPast, inMode: .default, dequeue: true) {
                            let wheelPoint = table.convert(queuedWheel.locationInWindow, from: nil)
                            check(table.hitTest(table.convert(wheelPoint, to: table.superview)) === table,
                                  "a wheel event over the interactive diagram targets the editor directly")
                            w.sendEvent(queuedWheel)
                        }
                        await waitFor(1) { clip.bounds.minY < bottom }
                        check(clip.bounds.minY < bottom, "a wheel turn over the interactive diagram scrolls the page")
                    } else {
                        check(false, "the interactive diagram is visible for the wheel test")
                    }
                    let top = clip.constrainBoundsRect(clip.bounds.offsetBy(dx: 0, dy: -table.bounds.height)).minY
                    clip.setBoundsOrigin(NSPoint(x: original.x, y: top - 40))
                    check(abs(clip.bounds.minY - top) <= 0.5, "the editor clamps a scroll step past the top of the page")
                    clip.setBoundsOrigin(NSPoint(x: original.x, y: bottom + 40))
                    check(abs(clip.bounds.minY - bottom) <= 0.5, "the editor clamps a scroll step past the bottom of the page")
                    clip.scroll(to: original)
                    scroll.reflectScrolledClipView(clip)
                    if let click = NSEvent.mouseEvent(with: .leftMouseDown, location: table.convert(webPoint, to: nil),
                                                       modifierFlags: [.command, .shift], timestamp: 0, windowNumber: w.windowNumber,
                                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        table.mouseDown(with: click)
                    }
                    check(controller.selectedDiagramID == diagram.id, "a Command–Shift click selects the interactive diagram even when the table receives it")
                    if let tv = previous?.blockTextView {
                        w.makeFirstResponder(tv)
                        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
                        key(#selector(NSResponder.moveDown(_:)))
                    }
                    check(controller.selectedDiagramID == diagram.id && w.firstResponder === table,
                          "Down from text selects the whole diagram")
                    pressDiagramKey("\u{1B}", code: 53, in: table)
                    check(controller.selectedDiagramID == nil && responder() === previous?.blockTextView,
                          "Escape clears the diagram selection and returns to text")
                } else {
                    check(false, "the player is hosted in the editor table")
                }
                await checkFlowSequence(web: web, output: output, check: check)
                if let scene = try? FlowScene(source: source) {
                    web.loadHTMLString(DiagramTemplate.flowDocument(scene), baseURL: nil)
                    await pause(300)
                }
            } else {
                check(false, "a web view exists for the visible diagram block")
            }
            snapshot("07-page-with-diagram")

            let drawing = try? workspace.createDiagram(pageID: pageID, title: "Static flow", format: .flow, source: """
                flow right
                first: Draft
                next: Review
                first -> next
                """,
                context: ChangeContext(actor: "selftest"))
            if let (_, block) = drawing, let w = window() {
                await waitFor { model.editor?.blocks.last?.id == block.id }
                if let editor = model.editor, let table = findWebView(w.contentView)?.enclosingScrollView?.documentView as? EditorTableView,
                   let controller = table.editor, let i = editor.index(of: block.id) {
                    let row = i + 1
                    table.scrollRowToVisible(row)
                    table.layoutSubtreeIfNeeded()
                    let rect = table.rect(ofRow: row)
                    let point = NSPoint(x: rect.midX, y: rect.midY)
                    let cell = table.hitTest(table.convert(point, to: table.superview)) as? DiagramBlockCell
                    check(cell != nil, "a click on a static diagram targets block selection")
                    if let click = NSEvent.mouseEvent(with: .leftMouseDown, location: table.convert(point, to: nil),
                                                       modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        table.mouseDown(with: click)
                    }
                    check(controller.selectedDiagramID == block.id && cell?.isBlockSelected == true && cell?.actionsButton.isHidden == false,
                          "clicking the drawing selects it, highlights it and reveals its actions")
                    snapshot("07-diagram-selected")
                    pressDiagramKey("\u{7F}", code: 51, in: table)
                    check(controller.selectedDiagramID == nil && editor.index(of: block.id) == nil,
                          "Delete removes the selected final diagram")
                    await waitFor { (try? workspace.block(id: block.id)) == nil }
                    check((try? workspace.block(id: block.id)) == nil, "diagram deletion is saved")
                    editor.undo()
                    await waitFor { (try? workspace.block(id: block.id)) != nil }
                    check(editor.blocks.last?.id == block.id && (try? workspace.block(id: block.id))?.id == block.id,
                          "undo restores the same diagram to the page and database")
                    if let item = controller.diagramMenu(for: block.id)?.item(at: 0), let action = item.action {
                        NSApp.sendAction(action, to: item.target, from: item)
                    }
                    check(editor.index(of: block.id) == nil, "the diagram actions menu deletes the diagram")
                } else {
                    check(false, "the static diagram is available for selection")
                }
            } else {
                check(false, "a static diagram can be created for the selection test")
            }
        }

        // Scripted providers exercise the same model selection as the real Assistant.
        if let ai = model.ai {
            ai.setEnabled(true, for: .claudeDefault)
            ai.selectModel(AssistantModel.claudeDefault.id)
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
                tv.setSelectedRange(NSRange(location: 0, length: 0))
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

            // The chat composer: Shift-Return breaks the line, Return sends.
            // SwiftUI keeps its accessibility identifier off the AppKit view, so find the field by its hint.
            func findField(_ view: NSView?, placeholder: String) -> NSTextField? {
                guard let view else { return nil }
                if let field = view as? NSTextField, field.isEditable, field.placeholderString == placeholder { return field }
                for sub in view.subviews { if let found = findField(sub, placeholder: placeholder) { return found } }
                return nil
            }
            func pressReturn(shift: Bool) {
                guard let w = window(), let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: w.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: 36) else { return }
                w.sendEvent(event)
            }
            // SwiftUI only routes key presses to a focused field while the app is active. A test run
            // that does not have focus (the user is working in another app) cannot check this.
            if !NSApp.isActive {
                log.append("skip Shift-Return in the chat composer: needs keyboard focus; run FLOTION_FOREGROUND=1 Scripts/selftest.sh")
            } else if let field = findField(window()?.contentView, placeholder: "Ask, or say what to change…"), window()?.makeFirstResponder(field) == true,
               let editor = window()?.firstResponder as? NSTextView {
                let sent = ai.chat.messages.count
                editor.insertText("line one", replacementRange: editor.selectedRange())
                pressReturn(shift: true)
                editor.insertText("line two", replacementRange: editor.selectedRange())
                await pause()
                check(editor.string == "line one\nline two", "Shift-Return in the chat composer adds a line break, got \(editor.string.debugDescription)")
                check(ai.chat.messages.count == sent, "Shift-Return does not send the message")
                snapshot("10-composer-two-lines")
                pressReturn(shift: false)
                await waitFor { !ai.chat.isRunning && ai.chat.messages.count == sent + 2 }
                check(ai.chat.messages.count == sent + 2 && ai.chat.messages[sent].text == "line one\nline two",
                      "Return sends both lines as one message")
            } else {
                check(false, "the chat composer can take focus")
            }
        }

        // The slash menu: the caret stays in the line, typing filters, arrows move, Return picks, Esc keeps the text.
        await model.newPage()
        await pause(400)
        key(newline)
        if let tv = responder(), !tv.isTitle, let controller = tv.controller {
            type("/")
            check(controller.slashMenu != nil, "typing / on an empty line opens the slash menu")
            check(controller.slashMenu?.session.matches.count == SlashMenu.blockCommands.count + 1, "the menu lists Ask AI and every block type")
            check(responder() === tv, "the caret stays in the line while the menu is open")
            await pause(300)
            if let view = controller.slashMenu?.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("11-slash-menu.png"))
            }
            type("head")
            check(controller.slashMenu?.session.matches.map(\.title) == ["Heading 1", "Heading 2", "Heading 3"],
                  "typing after / filters the menu, got \(controller.slashMenu?.session.matches.map(\.title) ?? [])")
            key(#selector(NSResponder.moveDown(_:)))
            check(controller.slashMenu?.session.selectedCommand?.title == "Heading 2", "Down moves the highlight")
            await pause(300)
            if let view = controller.slashMenu?.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("12-slash-menu-filtered.png"))
            }
            key(newline)
            let first = model.editor?.blocks.first
            check(controller.slashMenu == nil && first?.type == .heading2 && first?.plainText == "",
                  "Return turns the line into the highlighted type and removes /head, got \(first?.type.rawValue ?? "nil") '\(first?.plainText ?? "")'")
            type("Plan ")
            type("/")
            check(controller.slashMenu != nil, "/ after a space opens the menu mid-line")
            key(#selector(NSResponder.cancelOperation(_:)))
            check(controller.slashMenu == nil && responder()?.string == "Plan /", "Esc closes the menu and keeps the text")
            type("and/")
            check(controller.slashMenu == nil, "a / inside a word, as in and/or, does not open the menu")
        } else {
            check(false, "a new page has an empty line to type / into")
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

            // Page switches reuse the rows' cells instead of building new ones each time.
            if let smokeID = model.pages.first(where: { $0.title == "Smoke test" })?.id,
               let controller = findController() {
                await model.open(smokeID); await pause(300)
                await model.open(welcomeID); await pause(300)
                let built = controller.cellsCreated
                for id in [smokeID, welcomeID, smokeID, welcomeID] {
                    await model.open(id)
                    await pause(300)
                }
                check(controller.cellsCreated == built, "switching between pages already shown builds no new cells, built \(controller.cellsCreated - built)")
                check(model.title == "Getting Started" && model.editor?.blocks.count == 10, "the welcome page shows again after reused cells")
                snapshot("04b-welcome-reused")
            }
        }

        // Scrolling a long page both ways and switching pages: every row on screen shows its own
        // block, in its own row view, and no cell is in two rows. (Taking cells out of rows while
        // scrolling once left rows blank or showing another block's text.)
        if let workspace = model.workspace, let controller = findController(), let welcomeID {
            let types: [BlockType] = [.paragraph, .heading2, .bullet, .todo, .numbered, .quote, .code, .divider, .paragraph]
            let drafts = (0..<300).map { i -> Block in
                let type = types[i % types.count]
                return Block(type, type == .divider ? "" : "row \(i) " + String(repeating: "word ", count: (i * 13) % 40))
            }
            if let long = try? workspace.createPage(title: "Long scrolling page"), (try? workspace.insertBlocks(pageID: long.id, drafts)) != nil {
                await model.reloadPages()
                let table = controller.table
                var problems: [String] = []
                func audit(_ when: String) {
                    guard let editor = model.editor else { return }
                    let rows = table.rows(in: table.visibleRect)
                    var seen: [ObjectIdentifier: Int] = [:]
                    for row in rows.lowerBound..<rows.upperBound {
                        guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: false) else {
                            problems.append("\(when): row \(row) has no cell"); continue
                        }
                        if let other = seen.updateValue(row, forKey: ObjectIdentifier(view)) {
                            problems.append("\(when): rows \(other) and \(row) share one cell")
                        }
                        if view.window == nil || view.superview !== table.rowView(atRow: row, makeIfNecessary: false) {
                            problems.append("\(when): row \(row)'s cell is not in its row")
                        }
                        if row >= 1, row <= editor.blocks.count, let cell = view as? TextBlockCell {
                            let block = editor.blocks[row - 1]
                            if cell.blockTextView.blockID != block.id || cell.blockTextView.string != block.plainText {
                                problems.append("\(when): row \(row) shows another block's text")
                            }
                        }
                    }
                }
                func scroll(to y: CGFloat, _ when: String) async {
                    guard let scroll = table.enclosingScrollView else { return }
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    window()?.displayIfNeeded()
                    await Task.yield()
                    window()?.displayIfNeeded()
                    audit(when)
                }
                await model.open(long.id); await pause(300)
                for pass in 0..<2 {
                    var y: CGFloat = 0
                    while y < table.frame.height { y += 97; await scroll(to: y, "pass \(pass) down") }
                    while y > 0 { y -= 151; await scroll(to: y, "pass \(pass) up") }
                    await scroll(to: table.frame.height / 2, "pass \(pass) middle")
                    await model.open(welcomeID); await pause(200); audit("pass \(pass) welcome")
                    await model.open(long.id); await pause(200); audit("pass \(pass) long page again")
                }
                check(problems.isEmpty, "scrolling and switching pages keep every row's own cell, \(problems.count) problems \(problems.prefix(3))")
            } else {
                check(false, "the long scrolling page is created")
            }
        }

        if let problem = TestHost.savedWindowProblem() {
            check(false, problem)
        } else {
            check(true, "a test run does not restore or save the window")
        }
        // Run the follow-up edit checks after the focus-sensitive editor interactions.
        if let ai = model.ai, let smokeID = model.pages.first(where: { $0.title == "Smoke test" })?.id {
            await model.open(smokeID)
            await pause(200)
            let before = model.editor?.blocks.count ?? 0
            let priorMessages = ai.chat.messages.count
            let alternatives = AssistantModel.suggested.filter { $0.service != .claude }
            check(alternatives.count == 2, "ChatGPT and Antigravity are available in Settings")
            let discovered = ai.allModels.filter { $0.alias == "codex-test" || $0.alias == "agy-test" }
            check(discovered.count == 2 && discovered.allSatisfy { ai.visibleModels.contains($0) },
                  "discovered account models appear in the picker automatically")
            if let model = discovered.first {
                ai.selectModel(model.id)
                check(ai.selectedModel == model, "a discovered model can be selected")
                let restored = AIController(workspace: ai.workspace)
                await restored.refreshStatus()
                check(restored.selectedModel == model, "the discovered model selection survives relaunch")
                ai.setEnabled(false, for: model)
                await ai.refreshStatus()
                check(!ai.visibleModels.contains(model), "refreshing keeps a discovered model hidden")
                let restoredHidden = AIController(workspace: ai.workspace)
                await restoredHidden.refreshStatus()
                check(!restoredHidden.visibleModels.contains(model), "a hidden discovered model stays hidden after relaunch")
                ai.setEnabled(true, for: model)
                ai.selectModel(AssistantModel.claudeDefault.id)
            }
            for (index, alternative) in alternatives.enumerated() {
                ai.setEnabled(false, for: alternative)
                check(!ai.visibleModels.contains(alternative), "a hidden model is absent from the picker")
                ai.setEnabled(true, for: alternative)
                ai.selectModel(alternative.id)
                let restored = AIController(workspace: ai.workspace)
                check(restored.selectedModel == alternative && restored.visibleModels.contains(alternative), "model choice and visibility persist")
                await model.sendChat("Add a follow-up summary to this page")
                await waitFor { !ai.chat.isRunning && ai.chat.messages.count == priorMessages + (index + 1) * 2 }
                await waitFor { (model.editor?.blocks.count ?? 0) == before + 1 }
                let followUp = ai.chat.messages.last
                check(followUp?.text == "Added a summary to the end of the page." && followUp?.modelLabel == alternative.label,
                      "\(alternative.service.label) takes the follow-up in the same chat")
                check(followUp?.tools.map(\.label) == ["Adding content"] && followUp?.changeCount == 1
                      && model.editor?.blocks.count == before + 1, "\(alternative.service.label) edits the page and reports the change")
                if alternative.service == .openAI {
                    await pause(150)
                    snapshot("08b-assistant-model-switch")
                }
                if let followUp {
                    await ai.chat.undo(followUp.id)
                    await waitFor { (model.editor?.blocks.count ?? 0) == before }
                    check(model.editor?.blocks.count == before, "Undo reverts the \(alternative.service.label) edit")
                }
                ai.setEnabled(false, for: alternative)
                check(ai.selectedModel == .claudeDefault && !ai.visibleModels.contains(alternative),
                      "hiding the active model selects an available model")
            }
        } else {
            check(false, "the smoke page is available for ChatGPT and Antigravity")
        }

        // Render the Settings window after the tests that use the editor's first responder.
        if let ai = model.ai, let antigravity = AssistantModel.suggested.first(where: { $0.service == .antigravity }) {
            ai.setEnabled(true, for: antigravity)
            ai.selectModel(antigravity.id)
            let settingsWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 580),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
            let settings = NSHostingView(rootView: SettingsView(model: model))
            settingsWindow.contentView = settings
            settings.layoutSubtreeIfNeeded()
            await pause(150)
            snapshot("08c-assistant-model-settings", view: settings)
            ai.setEnabled(false, for: antigravity)
        }

        if let workspace = model.workspace {
            let defaults = AppDefaults.store
            defaults.set(Data(#"[{"service":"openAI","alias":"saved-custom","name":"Saved model"},{"service":"gemini","alias":"gemini-3.5-flash","name":"Old Gemini"}]"#.utf8),
                         forKey: "assistantCustomModels")
            defaults.set(["gemini:gemini-3.5-flash", "openAI:saved-custom"], forKey: "assistantEnabledModels")
            defaults.set("gemini:gemini-3.5-flash", forKey: "assistantModel")
            let migrated = AIController(workspace: workspace)
            check(migrated.selectedModel.service == .antigravity && migrated.selectedModel.alias.isEmpty,
                  "a saved Gemini selection migrates to the Antigravity account default")
            check(migrated.customModels.contains { $0.id == "openAI:saved-custom" },
                  "migrating Gemini preserves custom models for other providers")
            check(!migrated.allModels.contains { $0.alias == "gemini-3.5-flash" },
                  "obsolete Gemini CLI IDs are removed from the picker")
        }

        if TestHost.focusTakenCount > 0 {
            log.append("note macOS made the background app active \(TestHost.focusTakenCount) time(s); it gave focus straight back")
        }
        let skips = log.filter { $0.hasPrefix("skip ") }.count
        let skipped = skips == 0 ? "" : ", \(skips) skipped"
        log.append(failures.isEmpty ? "RESULT pass\(skipped)" : "RESULT fail (\(failures.count)\(skipped))")
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
        let savedWindow = TestHost.savedWindowProblem()
        let ok = savedWindow == nil && megabytes <= 150 && model.editor?.blocks.count == 1_000
        let line = savedWindow.map { "PERF OVER \($0)" } ?? String(format: "PERF %@ memory, fresh launch with a 1,000-block page open: %.1f MB (budget 150)", ok ? "ok  " : "OVER", megabytes)
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

        // Steadiness: a row in the middle of the screen must move by exactly the scroll step, whatever
        // happens to the heights of the rows coming into view. The run loop turns between frames, as it
        // does in the app, so height corrections that are put off to the next turn are included.
        if let table = find(EditorTableView.self, in: window()?.contentView), let scroll = table.enclosingScrollView {
            let clip = scroll.contentView
            func settle() async {
                window()?.displayIfNeeded()
                await Task.yield()
                await Task.yield()
                window()?.displayIfNeeded()
            }
            func jump(to y: CGFloat) async {
                clip.scroll(to: NSPoint(x: 0, y: y))
                scroll.reflectScrolledClipView(clip)
                await settle()
            }
            /// The largest distance the middle row ended a frame away from where the scroll step put it.
            func largestJump(from start: CGFloat, step: CGFloat, frames: Int) async -> Double {
                await jump(to: start)
                var worst = 0.0
                for _ in 0..<frames {
                    let visible = table.rows(in: table.visibleRect)
                    let row = visible.location + visible.length / 2
                    let before = table.rect(ofRow: row).minY - clip.bounds.minY
                    let from = clip.bounds.minY
                    clip.scroll(to: NSPoint(x: 0, y: from + step))
                    scroll.reflectScrolledClipView(clip)
                    await settle()
                    let after = table.rect(ofRow: row).minY - clip.bounds.minY
                    worst = max(worst, Double(abs(after - before + step)))
                }
                return worst
            }
            // Each run starts somewhere the page has not been scrolled through yet.
            let end = table.frame.height
            record("scroll up, rows not shown before: largest jump", await largestJump(from: end - 4_000, step: -30, frames: 300), unit: "pt", budget: 1)
            record("flick up, rows not shown before: largest jump", await largestJump(from: end - 30_000, step: -120, frames: 200), unit: "pt", budget: 1)
            record("flick down, rows not shown before: largest jump", await largestJump(from: end / 2, step: 120, frames: 200), unit: "pt", budget: 1)

            // Changing the width (a window resize, the assistant panel opening) re-measures every row.
            // The top row on screen must stay where it is, and a step must not stall the resize (measuring
            // every row the table asks about on each step took 80 ms).
            if let window = window() {
                await jump(to: end / 3)
                try? await Task.sleep(for: .milliseconds(400)) // rows measured in the background settle first
                let original = window.frame
                let row = table.rows(in: table.visibleRect).location + 1
                let before = table.rect(ofRow: row).minY - clip.bounds.minY
                var steps: [Double] = []
                for k in 0..<60 {
                    var frame = window.frame
                    frame.size.width += k < 30 ? -6 : 6
                    let start = CACurrentMediaTime()
                    window.setFrame(frame, display: true)
                    await settle()
                    steps.append((CACurrentMediaTime() - start) * 1000)
                }
                window.setFrame(original, display: true)
                await settle()
                try? await Task.sleep(for: .milliseconds(600))
                await settle()
                record("width change step work, 5,000-block page (p95)", percentile(steps, 0.95), budget: 33)
                record("width changed and back mid-page: movement of the top row", Double(abs(table.rect(ofRow: row).minY - clip.bounds.minY - before)), unit: "pt", budget: 3)
            }
        }

        // The same steadiness with real scroll-wheel events, as a mouse wheel sends them: each is
        // hit-tested by the window and climbs the responder chain to the scroll view, which does the
        // scrolling itself. (The checks above set the scroll offset directly.) A trackpad cannot be
        // stood in for this way: its events carry gesture phases, and after the first of a gesture the
        // scroll view takes no more of them from the app, so only the first one sent from here moves the page.
        if let window = window(), let table = find(EditorTableView.self, in: window.contentView), let scroll = table.enclosingScrollView {
            let clip = scroll.contentView
            /// Turns the wheel once per frame and follows a row on screen through it. Every turn must
            /// move that row by the turn's own distance. Returns the largest miss and the distances.
            func wheel(from start: CGFloat, turns: [CGFloat]) async -> (jump: Double, sent: Double, moved: Double) {
                clip.scroll(to: NSPoint(x: 0, y: start))
                scroll.reflectScrolledClipView(clip)
                window.displayIfNeeded()
                try? await Task.sleep(for: .milliseconds(300)) // rows measured in the background settle first
                func middleRow() -> (row: Int, offset: CGFloat) {
                    let visible = table.rows(in: table.visibleRect)
                    let row = visible.location + visible.length / 2
                    return (row, table.rect(ofRow: row).minY - clip.bounds.minY)
                }
                var followed = middleRow()
                var worst = 0.0, sent = 0.0, moved = 0.0
                for turn in turns {
                    guard let event = TestHost.wheelEvent(over: scroll, deltaY: turn) else { continue }
                    window.sendEvent(event)
                    window.displayIfNeeded()
                    await Task.yield()
                    await Task.yield()
                    window.displayIfNeeded()
                    let offset = table.rect(ofRow: followed.row).minY - clip.bounds.minY
                    worst = max(worst, Double(abs(offset - followed.offset - turn)))
                    sent += Double(turn)
                    moved += Double(offset - followed.offset)
                    followed = middleRow()
                }
                return (worst, sent, moved)
            }
            // Upwards (a positive turn): slowly, then fast.
            let turns = [CGFloat](repeating: 30, count: 150) + [CGFloat](repeating: 120, count: 100)
            let start = table.frame.height * 0.8
            let first = await wheel(from: start, turns: turns)
            if abs(first.moved) < 1 {
                failed += 1
                lines.append("PERF OVER wheel events did not scroll the page")
            } else {
                record("wheel up, rows not shown before: largest jump", first.jump, unit: "pt", budget: 1)
                // The same turns over the same rows, now all measured: what steady looks like.
                let again = await wheel(from: start, turns: turns)
                record("wheel up, same rows again: largest jump", again.jump, unit: "pt", budget: 1)
                lines.append(String(format: "PERF info wheel turned %.0f pt; the page moved %.0f pt, then %.0f pt", first.sent, first.moved, again.moved))
            }
        }

        if let problem = TestHost.savedWindowProblem() {
            lines.append("PERF OVER \(problem)")
            failed += 1
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
