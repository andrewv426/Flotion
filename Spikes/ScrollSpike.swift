// Spike (build step 1b): can one NSTextView per block hold the scroll and typing
// budgets at 5,000 blocks?  NSTableView with cell reuse + cached row heights.
//
// Build & run:  swiftc -O -swift-version 5 -parse-as-library Spikes/ScrollSpike.swift -o .build/scrollspike && .build/scrollspike
// Opens a window for about ten seconds, prints measurements, then quits.
//
// Result on this Mac (120 Hz), 2026-11-12:
//   scrolling    p95 frame 8.4 ms; 0-3 dropped frames on a flick, all in the first
//                frames while cells are first created (run-to-run variance on the stress pass)
//   keystroke    p95 0.7 ms including row re-measure and display (budget 8 ms)
//   open page    236 ms, of which 162 ms is measuring all 5,000 row heights up front
// Decision: keep NSTableView + reused NSTextView cells. To hit the 150 ms page-open
// budget the editor must paint with estimated heights and refine exact heights after
// first paint (not yet measured; the editor's performance test has to confirm it).
import AppKit
import QuartzCore

let blockCount = 5_000
let columnWidth: CGFloat = 708

struct SpikeBlock {
    let text: NSAttributedString
}

func makeBlocks() -> [SpikeBlock] {
    let words = "the quick brown fox jumps over a lazy dog while notes pages blocks and diagrams keep scrolling without a hitch across every frame".split(separator: " ").map(String.init)
    let body = NSMutableParagraphStyle()
    body.minimumLineHeight = 24
    body.maximumLineHeight = 24
    let textColor = NSColor(srgbRed: 0x37 / 255, green: 0x35 / 255, blue: 0x2F / 255, alpha: 1)
    var out: [SpikeBlock] = []
    out.reserveCapacity(blockCount)
    for i in 0..<blockCount {
        let isHeading = i % 10 == 0
        let wordCount = isHeading ? 4 : 6 + (i * 37) % 70
        var s = ""
        for w in 0..<wordCount { s += words[(i + w * 7) % words.count] + " " }
        let font = isHeading ? NSFont.systemFont(ofSize: 24, weight: .semibold) : NSFont.systemFont(ofSize: 16)
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = isHeading ? 32 : 24
        para.maximumLineHeight = isHeading ? 32 : 24
        out.append(SpikeBlock(text: NSAttributedString(string: s, attributes: [
            .font: font, .foregroundColor: textColor, .paragraphStyle: para,
        ])))
    }
    return out
}

final class BlockCell: NSTableCellView {
    let tv: NSTextView

    override init(frame: NSRect) {
        tv = NSTextView(usingTextLayoutManager: true)
        super.init(frame: frame)
        tv.drawsBackground = false
        tv.isRichText = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width, .height]
        tv.frame = bounds.insetBy(dx: 0, dy: 3)
        addSubview(tv)
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class Spike: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate {
    var window: NSWindow!
    var scroll: NSScrollView!
    var table: NSTableView!
    var blocks: [SpikeBlock] = []
    var heights: [CGFloat] = []
    var link: CADisplayLink?

    var phase = 0
    var phaseStart: CFTimeInterval = 0
    var lastTick: CFTimeInterval = 0
    var deltas: [Double] = []
    var results: [String] = []
    var frameInterval = 1.0 / 60.0

    func applicationDidFinishLaunching(_ note: Notification) {
        let t0 = CACurrentMediaTime()
        blocks = makeBlocks()
        let tData = CACurrentMediaTime()

        // First attempt measured serially with NSStringDrawing: 261 ms for 5,000 rows.
        // CoreText framesetters are thread-safe, so measure across all cores instead.
        let source = blocks
        var measured = [CGFloat](repeating: 0, count: source.count)
        measured.withUnsafeMutableBufferPointer { buf in
            let out = UnsafeMutablePointer<CGFloat>(buf.baseAddress!)
            let chunk = 64
            DispatchQueue.concurrentPerform(iterations: (source.count + chunk - 1) / chunk) { c in
                for i in (c * chunk)..<min(source.count, (c + 1) * chunk) {
                    let fs = CTFramesetterCreateWithAttributedString(source[i].text)
                    let size = CTFramesetterSuggestFrameSizeWithConstraints(
                        fs, CFRange(location: 0, length: 0), nil,
                        CGSize(width: columnWidth, height: .greatestFiniteMagnitude), nil)
                    out[i] = ceil(size.height) + 6
                }
            }
        }
        heights = measured
        let tHeights = CACurrentMediaTime()

        window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 1000, height: 760),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Flotion scroll spike"
        table = NSTableView()
        let col = NSTableColumn(identifier: .init("c"))
        col.width = columnWidth
        table.addTableColumn(col)
        table.headerView = nil
        table.style = .plain
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.backgroundColor = .white
        table.dataSource = self
        table.delegate = self
        scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.displayIfNeeded()
        let tPaint = CACurrentMediaTime()

        frameInterval = 1.0 / Double(max(60, NSScreen.main?.maximumFramesPerSecond ?? 60))
        results.append(String(format: "blocks                      %d", blockCount))
        results.append(String(format: "display                     %.0f Hz", 1.0 / frameInterval))
        results.append(String(format: "build attributed strings    %6.1f ms", (tData - t0) * 1000))
        results.append(String(format: "measure all row heights     %6.1f ms", (tHeights - tData) * 1000))
        results.append(String(format: "window + first paint        %6.1f ms", (tPaint - tHeights) * 1000))
        results.append(String(format: "open page total             %6.1f ms", (tPaint - t0) * 1000))

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.startPhase(1) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { blocks.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { heights[row] }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("block")
        let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? BlockCell) ?? {
            let c = BlockCell(frame: NSRect(x: 0, y: 0, width: columnWidth, height: 30))
            c.identifier = id
            return c
        }()
        cell.tv.textStorage?.setAttributedString(blocks[row].text)
        return cell
    }

    // Phase 1: fast flick, 3,000 pt/s for 4 s.  Phase 2: whole document in 5 s (stress).
    func startPhase(_ p: Int) {
        phase = p
        deltas.removeAll(keepingCapacity: true)
        phaseStart = CACurrentMediaTime()
        lastTick = phaseStart
        if link == nil {
            link = scroll.displayLink(target: self, selector: #selector(tick(_:)))
            link?.add(to: .main, forMode: .common)
        }
    }

    @objc func tick(_ l: CADisplayLink) {
        let now = CACurrentMediaTime()
        deltas.append(now - lastTick)
        lastTick = now
        let elapsed = now - phaseStart
        let clip = scroll.contentView
        let maxY = max(0, table.frame.height - clip.bounds.height)
        let duration: Double = phase == 1 ? 4 : 5
        let y: CGFloat = phase == 1 ? min(maxY, CGFloat(elapsed) * 3000) : maxY * CGFloat(min(1, elapsed / duration))
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        if elapsed >= duration { finishPhase() }
    }

    func finishPhase() {
        let d = deltas.dropFirst().sorted()
        let dropped = d.filter { $0 > frameInterval * 1.5 }.count
        let p95 = d[Int(Double(d.count - 1) * 0.95)]
        let name = phase == 1 ? "flick 3,000 pt/s" : "stress, full doc in 5 s"
        results.append(String(format: "scroll %-22@ frames %4d  dropped %3d  p95 %5.2f ms  max %5.2f ms",
                              name as NSString, d.count, dropped, p95 * 1000, (d.last ?? 0) * 1000))
        if phase == 1 {
            scroll.contentView.scroll(to: .zero)
            startPhase(2)
        } else {
            link?.invalidate()
            link = nil
            typingTest()
        }
    }

    // Insert characters into a visible block, re-measure its row, force display.
    func typingTest() {
        let visible = table.rows(in: table.visibleRect)
        let row = visible.location + visible.length / 2
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? BlockCell else { finish(); return }
        window.makeFirstResponder(cell.tv)
        var times: [Double] = []
        for i in 0..<120 {
            let t = CACurrentMediaTime()
            cell.tv.insertText(i % 9 == 8 ? " " : "a", replacementRange: cell.tv.selectedRange())
            let text = cell.tv.attributedString()
            let r = text.boundingRect(with: NSSize(width: columnWidth, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading])
            let h = ceil(r.height) + 6
            if h != heights[row] {
                heights[row] = h
                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                NSAnimationContext.endGrouping()
            }
            window.displayIfNeeded()
            times.append(CACurrentMediaTime() - t)
        }
        times.sort()
        results.append(String(format: "keystroke (insert+measure+display)  p50 %5.2f ms  p95 %5.2f ms  max %5.2f ms",
                              times[times.count / 2] * 1000, times[Int(Double(times.count - 1) * 0.95)] * 1000, times.last! * 1000))
        finish()
    }

    func finish() {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            results.append(String(format: "resident memory             %6.1f MB", Double(info.resident_size) / 1_048_576))
        }
        print(results.joined(separator: "\n"))
        NSApp.terminate(nil)
    }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = Spike()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
