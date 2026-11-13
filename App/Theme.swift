import AppKit
import FlotionCore

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light }
    }
}

/// Notion-style design tokens: colours, type scale and spacing.
@MainActor
enum Theme {
    static let text = NSColor.dynamic(light: NSColor(hex: 0x37352F), dark: NSColor(white: 1, alpha: 0.81))
    static let page = NSColor.dynamic(light: .white, dark: NSColor(hex: 0x191919))
    static let sidebar = NSColor.dynamic(light: NSColor(hex: 0xF7F7F5), dark: NSColor(hex: 0x202020))
    static let secondary = NSColor.dynamic(light: NSColor(hex: 0x787774), dark: NSColor(white: 1, alpha: 0.44))
    static let placeholder = NSColor.dynamic(light: NSColor(hex: 0x37352F, alpha: 0.3), dark: NSColor(white: 1, alpha: 0.28))
    static let hover = NSColor.dynamic(light: NSColor(hex: 0x37352F, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.055))
    static let divider = NSColor.dynamic(light: NSColor(hex: 0x37352F, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.094))
    static let accent = NSColor(hex: 0x2383E2)
    static let codeText = NSColor(hex: 0xEB5757)
    static let codeBackground = NSColor(hex: 0x878378, alpha: 0.15)

    static let contentWidth: CGFloat = 708
    static let sidebarWidth: CGFloat = 240
    static let minimumSideMargin: CGFloat = 64
    static let indentStep: CGFloat = 24
    static let markerWidth: CGFloat = 24

    struct BlockStyle {
        var font: NSFont
        var lineHeight: CGFloat
        var top: CGFloat
        var bottom: CGFloat
    }

    static let titleStyle = BlockStyle(font: .systemFont(ofSize: 40, weight: .bold), lineHeight: 48, top: 72, bottom: 12)

    static func style(for type: BlockType) -> BlockStyle {
        switch type {
        case .heading1: BlockStyle(font: .systemFont(ofSize: 30, weight: .semibold), lineHeight: 39, top: 28, bottom: 4)
        case .heading2: BlockStyle(font: .systemFont(ofSize: 24, weight: .semibold), lineHeight: 31, top: 22, bottom: 3)
        case .heading3: BlockStyle(font: .systemFont(ofSize: 20, weight: .semibold), lineHeight: 26, top: 16, bottom: 3)
        case .code: BlockStyle(font: .monospacedSystemFont(ofSize: 13.6, weight: .regular), lineHeight: 21, top: 14, bottom: 14)
        case .quote: BlockStyle(font: .systemFont(ofSize: 16), lineHeight: 24, top: 5, bottom: 5)
        default: BlockStyle(font: .systemFont(ofSize: 16), lineHeight: 24, top: 3, bottom: 3)
        }
    }

    /// The horizontal extent of the centred content column in a view of the given width.
    static func contentColumn(in width: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let w = max(200, min(contentWidth, width - 2 * minimumSideMargin))
        return ((width - w) / 2, w)
    }

    /// Where a block's text sits inside the content column.
    static func textInset(for block: Block) -> CGFloat {
        let hasMarker = block.type == .bullet || block.type == .numbered || block.type == .todo
        let quoteOrCode: CGFloat = block.type == .quote ? 16 : block.type == .code ? 16 : 0
        return CGFloat(block.depth) * indentStep + (hasMarker ? markerWidth : 0) + quoteOrCode
    }
}
