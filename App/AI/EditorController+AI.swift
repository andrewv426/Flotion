import AppKit
import FlotionCore
import SwiftUI

/// "Edit with AI" on a selection, and "Ask AI to write" on an empty line.
extension EditorController {
    /// Called from the text view delegate whenever a block's selection changes.
    func selectionChanged(in tv: BlockTextView) {
        guard !tv.isTitle else { return }
        let range = tv.selectedRange()
        if range.length > 0, tv.window?.firstResponder === tv {
            let selection = EditorSelection(blockID: tv.blockID, range: range, text: (tv.string as NSString).substring(with: range))
            guard selection != currentSelection else { return }
            currentSelection = selection
            onSelectionChange?(selection)
            showAIButton(near: tv, range: range)
        } else if currentSelection?.blockID == tv.blockID {
            clearSelection()
        }
    }

    func clearSelection() {
        guard currentSelection != nil || !aiButton.isHidden else { return }
        currentSelection = nil
        aiButton.isHidden = true
        onSelectionChange?(nil)
    }

    /// The selection's rectangle in the table's coordinates.
    private func rect(of range: NSRange, in tv: BlockTextView) -> NSRect? {
        guard let window = tv.window else { return nil }
        let onScreen = tv.firstRect(forCharacterRange: range, actualRange: nil)
        guard onScreen.width.isFinite, onScreen.height > 0 else { return nil }
        return table.convert(window.convertFromScreen(onScreen), from: nil)
    }

    private func showAIButton(near tv: BlockTextView, range: NSRange) {
        guard ai != nil, let rect = rect(of: range, in: tv) else { return }
        if aiButton.superview == nil {
            aiButton.title = "✦ Edit with AI"
            aiButton.bezelStyle = .accessoryBarAction
            aiButton.controlSize = .small
            aiButton.font = .systemFont(ofSize: 12, weight: .medium)
            aiButton.target = self
            aiButton.action = #selector(editSelectionWithAI)
            aiButton.setAccessibilityIdentifier("edit-with-ai")
            aiButton.sizeToFit()
            table.addSubview(aiButton)
        }
        aiButton.frame.origin = NSPoint(x: rect.minX, y: max(0, rect.minY - aiButton.frame.height - 4))
        aiButton.isHidden = false
    }

    @objc func editSelectionWithAI() {
        guard let selection = currentSelection else { return }
        beginInlineEdit(blockID: selection.blockID, range: selection.range, text: selection.text)
    }

    /// Opens the inline AI prompt. An empty `text` means "write something new here".
    func beginInlineEdit(blockID: String, range: NSRange, text: String) {
        guard let ai, let state, let i = state.index(of: blockID) else { return }
        // Nearby text gives the model the voice and subject without sending the whole page.
        let nearby = state.blocks[max(0, i - 3)...min(state.blocks.count - 1, i + 2)].map(\.plainText).filter { !$0.isEmpty }
        let model = InlineEditModel(ai: ai, selection: text, context: String(nearby.joined(separator: "\n").prefix(2_000)))
        inlineModel = model

        let popover = NSPopover()
        popover.behavior = .semitransient
        let view = InlineEditView(
            model: model,
            onAccept: { [weak self] markdown in self?.finishInlineEdit(markdown, blockID: blockID, range: range, below: false) },
            onInsertBelow: { [weak self] markdown in self?.finishInlineEdit(markdown, blockID: blockID, range: range, below: true) },
            onDiagram: { [weak self] in
                self?.closeInlineEdit()
                self?.onAskChat?("Turn the selected text into a step-by-step diagram and place it right after that text on this page.")
            },
            onClose: { [weak self] in self?.closeInlineEdit() })
        popover.contentViewController = NSHostingController(rootView: view)
        inlinePopover?.close()
        inlinePopover = popover

        let row = i + 1
        var anchor = table.rect(ofRow: row)
        if let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? TextBlockCell,
           let selectionRect = rect(of: range, in: cell.blockTextView) {
            anchor = selectionRect
        }
        popover.show(relativeTo: anchor, of: table, preferredEdge: .maxY)
    }

    func closeInlineEdit() {
        inlinePopover?.close()
        inlinePopover = nil
        inlineModel = nil
    }

    /// Applies an accepted result as one undoable editor command.
    func finishInlineEdit(_ markdown: String, blockID: String, range: NSRange, below: Bool) {
        defer {
            closeInlineEdit()
            clearSelection()
        }
        guard let state, let i = state.index(of: blockID) else { return }
        let drafts = MarkdownCodec.parse(markdown.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !drafts.isEmpty else { return }
        if below {
            state.insertBlocks(drafts, after: blockID)
        } else {
            // The block may have changed while the popover was open; never index past its end.
            let length = state.blocks[i].runs.utf16Count
            let lower = min(range.location, length)
            state.replaceText(in: blockID, range: lower..<min(NSMaxRange(range), length), with: drafts)
        }
    }
}
