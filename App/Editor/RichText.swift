import AppKit
import FlotionCore

/// Converts between stored runs and the attributed strings NSTextView edits.
/// Marks and links travel as custom attributes; fonts and colours are derived from them.
@MainActor
enum RichText {
    static let marksKey = NSAttributedString.Key("flotion.marks")
    static let linkKey = NSAttributedString.Key("flotion.link")

    static func paragraphStyle(_ style: Theme.BlockStyle) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = style.lineHeight
        p.maximumLineHeight = style.lineHeight
        return p
    }

    static func attributes(style: Theme.BlockStyle, marks: Marks = [], link: String? = nil,
                           dimmed: Bool = false) -> [NSAttributedString.Key: Any] {
        var font = style.font
        if marks.contains(.code) {
            font = .monospacedSystemFont(ofSize: (style.font.pointSize * 0.85).rounded(), weight: .regular)
        }
        if marks.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if marks.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: dimmed ? Theme.secondary : Theme.text,
            .paragraphStyle: paragraphStyle(style),
            // Centre glyphs in the taller line box instead of sitting on its floor.
            .baselineOffset: (style.lineHeight - (font.ascender - font.descender + font.leading)) / 2,
            marksKey: marks.rawValue,
        ]
        if marks.contains(.code) {
            attrs[.foregroundColor] = Theme.codeText
            attrs[.backgroundColor] = Theme.codeBackground
        }
        if marks.contains(.strike) || dimmed { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let link {
            attrs[linkKey] = link
            attrs[.foregroundColor] = Theme.accent
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attrs
    }

    static func attributed(_ runs: [TextRun], style: Theme.BlockStyle, dimmed: Bool = false) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for run in runs {
            out.append(NSAttributedString(string: run.text, attributes: attributes(style: style, marks: run.marks, link: run.link, dimmed: dimmed)))
        }
        return out
    }

    static func attributed(_ block: Block) -> NSAttributedString {
        attributed(block.runs, style: Theme.style(for: block.type), dimmed: block.type == .todo && block.props.checked == true)
    }

    static func runs(from text: NSAttributedString) -> [TextRun] {
        var out: [TextRun] = []
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            let marks = Marks(rawValue: attrs[marksKey] as? Int ?? 0)
            out.append(TextRun(text.attributedSubstring(from: range).string, marks: marks, link: attrs[linkKey] as? String))
        }
        return out.normalized()
    }

    /// Height of `text` laid out at `width`; an empty string still occupies one line.
    static func height(of text: NSAttributedString, width: CGFloat, lineHeight: CGFloat) -> CGFloat {
        guard text.length > 0 else { return lineHeight }
        let rect = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading])
        return max(lineHeight, ceil(rect.height))
    }
}
