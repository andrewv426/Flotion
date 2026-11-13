import AppKit
import FlotionCore

/// The text view inside every text block (and the page title).
/// Editing rules live in `EditorState`; this class only forwards intent.
final class BlockTextView: NSTextView {
    var blockID: String = ""
    var isTitle = false
    var blockStyle = Theme.style(for: .paragraph)
    var placeholder: String = ""
    weak var controller: EditorController?

    static func make() -> BlockTextView {
        let tv = BlockTextView(usingTextLayoutManager: true)
        tv.drawsBackground = false
        tv.isRichText = true
        tv.allowsUndo = false // undo is owned by EditorState so it can cross blocks
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.insertionPointColor = Theme.text
        tv.focusRingType = .none
        return tv
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        needsDisplay = true
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        needsDisplay = true
        return ok
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, isTitle || window?.firstResponder === self else { return }
        var attrs = RichText.attributes(style: blockStyle)
        attrs[.foregroundColor] = Theme.placeholder
        NSAttributedString(string: placeholder, attributes: attrs).draw(at: .zero)
    }

    /// Pasted or dropped text arrives as plain text and takes on the block's style.
    override func paste(_ sender: Any?) { pasteAsPlainText(sender) }

    // MARK: Formatting commands (Format menu)

    @objc func toggleBold(_ sender: Any?) { toggle(.bold) }
    @objc func toggleItalic(_ sender: Any?) { toggle(.italic) }
    @objc func toggleCode(_ sender: Any?) { toggle(.code) }
    @objc func toggleStrike(_ sender: Any?) { toggle(.strike) }

    private func toggle(_ mark: Marks) {
        guard !isTitle, let storage = textStorage else { return }
        let range = selectedRange()
        if range.length == 0 {
            var marks = Marks(rawValue: typingAttributes[RichText.marksKey] as? Int ?? 0)
            marks.formSymmetricDifference(mark)
            typingAttributes = RichText.attributes(style: blockStyle, marks: marks, link: typingAttributes[RichText.linkKey] as? String)
            return
        }
        var allHaveIt = true
        storage.enumerateAttribute(RichText.marksKey, in: range) { value, _, _ in
            if !Marks(rawValue: value as? Int ?? 0).contains(mark) { allHaveIt = false }
        }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attrs, sub, _ in
            var marks = Marks(rawValue: attrs[RichText.marksKey] as? Int ?? 0)
            if allHaveIt { marks.remove(mark) } else { marks.insert(mark) }
            storage.setAttributes(RichText.attributes(style: blockStyle, marks: marks, link: attrs[RichText.linkKey] as? String), range: sub)
        }
        storage.endEditing()
        didChangeText()
    }

    /// True when the caret is on the first (or last) visual line, so an arrow key should leave the block.
    func caretIsOnEdgeLine(first: Bool) -> Bool {
        let length = (string as NSString).length
        guard length > 0 else { return true }
        let caret = firstRect(forCharacterRange: NSRange(location: selectedRange().location, length: 0), actualRange: nil)
        let edge = firstRect(forCharacterRange: NSRange(location: first ? 0 : length, length: 0), actualRange: nil)
        return abs(caret.midY - edge.midY) < 4
    }
}

class FlippedCell: NSTableCellView {
    override var isFlipped: Bool { true }
}

/// A row with editable text and an optional marker (bullet, number, checkbox, quote bar).
final class TextBlockCell: FlippedCell {
    let blockTextView = BlockTextView.make()
    private let marker = NSTextField(labelWithString: "")
    private let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let bar = NSView()
    private let backdrop = NSView()
    private var block = Block()
    private var style = Theme.style(for: .paragraph)

    override init(frame: NSRect) {
        super.init(frame: frame)
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 4
        bar.wantsLayer = true
        addSubview(backdrop)
        addSubview(bar)
        addSubview(marker)
        addSubview(checkbox)
        addSubview(blockTextView)
        checkbox.target = self
        checkbox.action = #selector(toggleCheckbox)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ block: Block, number: Int, controller: EditorController) {
        self.block = block
        style = Theme.style(for: block.type)
        blockTextView.controller = controller
        blockTextView.delegate = controller
        blockTextView.blockID = block.id
        blockTextView.blockStyle = style
        blockTextView.placeholder = block.type == .paragraph ? "Type '/' for commands" : block.type.placeholder
        let text = RichText.attributed(block)
        if !blockTextView.attributedString().isEqual(to: text) {
            blockTextView.textStorage?.setAttributedString(text)
        }
        blockTextView.typingAttributes = RichText.attributes(style: style, dimmed: block.type == .todo && block.props.checked == true)

        marker.isHidden = !(block.type == .bullet || block.type == .numbered)
        marker.stringValue = block.type == .bullet ? "•" : "\(number)."
        marker.font = block.type == .bullet ? .systemFont(ofSize: 20) : .systemFont(ofSize: 16)
        marker.textColor = Theme.text
        marker.alignment = block.type == .bullet ? .center : .right
        checkbox.isHidden = block.type != .todo
        checkbox.state = block.props.checked == true ? .on : .off
        bar.isHidden = block.type != .quote
        bar.layer?.backgroundColor = Theme.text.cgColor
        backdrop.isHidden = block.type != .code
        backdrop.layer?.backgroundColor = Theme.codeBackground.cgColor
        needsLayout = true
        blockTextView.needsDisplay = true
    }

    override func layout() {
        super.layout()
        let column = Theme.contentColumn(in: bounds.width)
        let inset = Theme.textInset(for: block)
        let textX = column.x + inset
        let textHeight = bounds.height - style.top - style.bottom
        blockTextView.frame = NSRect(x: textX, y: style.top, width: column.width - inset - (block.type == .code ? 16 : 0), height: textHeight)
        let markerX = column.x + CGFloat(block.depth) * Theme.indentStep
        marker.frame = NSRect(x: markerX - (block.type == .numbered ? 8 : 0), y: style.top + (block.type == .bullet ? -2 : 1),
                              width: Theme.markerWidth + (block.type == .numbered ? 4 : 0), height: style.lineHeight)
        checkbox.frame = NSRect(x: markerX + 1, y: style.top + 3, width: 18, height: 18)
        bar.frame = NSRect(x: markerX, y: 2, width: 3, height: bounds.height - 4)
        backdrop.frame = NSRect(x: markerX, y: 4, width: column.width - CGFloat(block.depth) * Theme.indentStep, height: bounds.height - 8)
    }

    @objc private func toggleCheckbox() {
        blockTextView.controller?.toggleChecked(block.id)
    }
}

private extension BlockType {
    var placeholder: String {
        switch self {
        case .heading1: "Heading 1"
        case .heading2: "Heading 2"
        case .heading3: "Heading 3"
        case .bullet, .numbered: "List"
        case .todo: "To-do"
        case .quote: "Quote"
        default: ""
        }
    }
}

final class TitleCell: FlippedCell {
    let textView = BlockTextView.make()

    override init(frame: NSRect) {
        super.init(frame: frame)
        textView.isTitle = true
        textView.isRichText = false
        textView.blockStyle = Theme.titleStyle
        textView.placeholder = "Untitled"
        textView.typingAttributes = RichText.attributes(style: Theme.titleStyle)
        textView.setAccessibilityIdentifier("page-title")
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title: String, controller: EditorController) {
        textView.controller = controller
        textView.delegate = controller
        if textView.string != title {
            textView.textStorage?.setAttributedString(NSAttributedString(string: title, attributes: RichText.attributes(style: Theme.titleStyle)))
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let column = Theme.contentColumn(in: bounds.width)
        textView.frame = NSRect(x: column.x, y: Theme.titleStyle.top, width: column.width,
                                height: bounds.height - Theme.titleStyle.top - Theme.titleStyle.bottom)
    }
}

/// Rows without editable text: divider and sub-page link.
final class StaticBlockCell: FlippedCell {
    private let line = NSView()
    private let label = NSButton(title: "", target: nil, action: nil)
    private var block = Block()
    private weak var controller: EditorController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        line.wantsLayer = true
        label.isBordered = false
        label.alignment = .left
        label.font = .systemFont(ofSize: 16)
        label.target = self
        label.action = #selector(activate)
        addSubview(line)
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ block: Block, title: String, controller: EditorController) {
        self.block = block
        self.controller = controller
        line.isHidden = block.type != .divider
        line.layer?.backgroundColor = Theme.divider.cgColor
        label.isHidden = block.type == .divider
        label.title = "📄  \(title)"
        label.contentTintColor = Theme.text
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let column = Theme.contentColumn(in: bounds.width)
        let x = column.x + CGFloat(block.depth) * Theme.indentStep
        line.frame = NSRect(x: x, y: (bounds.height / 2).rounded(), width: column.width - (x - column.x), height: 1)
        label.frame = NSRect(x: x, y: 3, width: column.width - (x - column.x), height: bounds.height - 6)
    }

    @objc private func activate() {
        if block.type == .pageLink, let target = block.props.targetPageID { controller?.onOpenPage?(target) }
    }
}
