import FlotionCore
import Foundation

/// Where the caret is. Offsets are UTF-16 units, matching NSTextView ranges.
public struct Focus: Equatable, Sendable {
    public var blockID: String
    public var offset: Int
    public init(blockID: String, offset: Int) { self.blockID = blockID; self.offset = offset }
}

public enum EditorChange: Equatable, Sendable {
    /// Rows were inserted, removed or reordered: reload the list.
    case structure
    /// These rows changed content or appearance but the list shape is the same.
    case rows([Int])
}

/// The editing model for one page: an ordered list of blocks plus the commands that change it.
/// It has no view dependencies, so every editing rule is unit-tested directly.
@MainActor
public final class EditorState {
    public let pageID: String
    public private(set) var blocks: [Block]
    public var focus: Focus?
    public var onChange: ((EditorChange) -> Void)?
    /// Called whenever there is something new to save.
    public var onDirty: (() -> Void)?

    private var dirty = Set<String>()
    private var deleted = Set<String>()
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastTypingCheckpoint: (blockID: String, at: Date)?

    private struct Snapshot {
        var blocks: [Block]
        var focus: Focus?
    }

    public init(pageID: String, blocks: [Block]) {
        self.pageID = pageID
        self.blocks = blocks
        if self.blocks.isEmpty {
            let first = Block(pageID: pageID, type: .paragraph, position: 1024)
            self.blocks = [first]
            dirty.insert(first.id)
        }
    }

    // MARK: Queries

    public func index(of id: String) -> Int? { blocks.firstIndex { $0.id == id } }

    /// The 1-based number shown beside a numbered-list block.
    public func listNumber(at index: Int) -> Int {
        let depth = blocks[index].depth
        var n = 1
        var i = index - 1
        while i >= 0 {
            let b = blocks[i]
            if b.depth < depth { break }
            if b.depth == depth {
                if b.type == .numbered { n += 1 } else { break }
            }
            i -= 1
        }
        return n
    }

    public var hasPendingChanges: Bool { !dirty.isEmpty || !deleted.isEmpty }

    /// Hands over everything changed since the last call, for one save transaction.
    public func takePendingChanges() -> (upserts: [Block], deletes: [String]) {
        let upserts = blocks.filter { dirty.contains($0.id) }
        let deletes = Array(deleted)
        dirty.removeAll()
        deleted.removeAll()
        return (upserts, deletes)
    }

    // MARK: Text edits

    /// The text view reports new content for a block. Returns true when a Markdown
    /// shortcut changed the block's type (the caller must refresh that row's text).
    @discardableResult
    public func setRuns(_ runs: [TextRun], for id: String, caret: Int) -> Bool {
        guard let i = index(of: id), blocks[i].runs != runs else { return false }
        typingCheckpoint(id)
        blocks[i].runs = runs
        touch(i)
        focus = Focus(blockID: id, offset: caret)
        if applyMarkdownShortcut(at: i) {
            onChange?(.rows([i]))
            return true
        }
        return false
    }

    private static let shortcuts: [(prefix: String, type: BlockType)] = [
        ("### ", .heading3), ("## ", .heading2), ("# ", .heading1),
        ("- ", .bullet), ("* ", .bullet), ("+ ", .bullet), ("1. ", .numbered),
        ("[] ", .todo), ("[ ] ", .todo), ("> ", .quote), ("```", .code),
    ]

    private func applyMarkdownShortcut(at i: Int) -> Bool {
        guard blocks[i].type == .paragraph else { return false }
        let text = blocks[i].plainText
        if text == "---" {
            blocks[i].runs = []
            blocks[i].type = .divider
            let next = Block(pageID: pageID, type: .paragraph, depth: blocks[i].depth, position: position(after: i))
            blocks.insert(next, at: i + 1)
            touch(i); touch(i + 1)
            focus = Focus(blockID: next.id, offset: 0)
            onChange?(.structure)
            return false
        }
        guard let match = Self.shortcuts.first(where: { text.hasPrefix($0.prefix) }) else { return false }
        blocks[i].type = match.type
        blocks[i].runs = blocks[i].runs.droppingUTF16Prefix(match.prefix.utf16.count)
        if match.type == .todo { blocks[i].props.checked = false }
        touch(i)
        focus = Focus(blockID: blocks[i].id, offset: 0)
        return true
    }

    // MARK: Structural commands

    /// Return key: split the block at the caret.
    public func split(_ id: String, at offset: Int) {
        guard let i = index(of: id) else { return }
        checkpoint()
        let block = blocks[i]
        let isList = block.type == .bullet || block.type == .numbered || block.type == .todo

        // Return on an empty list item or quote leaves the list instead of adding another item.
        if block.runs.isEmpty, isList || block.type == .quote {
            if block.depth > 0 { blocks[i].depth -= 1 } else { blocks[i].type = .paragraph; blocks[i].props = BlockProps() }
            touch(i)
            focus = Focus(blockID: id, offset: 0)
            onChange?(.rows([i]))
            return
        }
        if block.type == .code {
            // Return inside code inserts a newline; the text view handles it.
            return
        }
        let (head, tail) = block.runs.splitUTF16(at: offset)
        blocks[i].runs = head
        var next = Block(pageID: pageID, type: isList ? block.type : .paragraph, depth: block.depth,
                         position: position(after: i), runs: tail)
        if next.type == .todo { next.props.checked = false }
        // Splitting at the very start of a heading pushes the heading down, as in Notion.
        if offset == 0, !isList, block.type != .paragraph, !tail.isEmpty {
            next.type = block.type
            blocks[i].type = .paragraph
        }
        blocks.insert(next, at: i + 1)
        touch(i); touch(i + 1)
        focus = Focus(blockID: next.id, offset: 0)
        onChange?(.structure)
    }

    /// Backspace at the start of a block.
    public func deleteBackwardAtStart(_ id: String) {
        guard let i = index(of: id) else { return }
        checkpoint()
        let block = blocks[i]
        if block.type != .paragraph {
            blocks[i].type = .paragraph
            blocks[i].props = BlockProps()
            touch(i)
            focus = Focus(blockID: id, offset: 0)
            onChange?(.rows([i]))
            return
        }
        if block.depth > 0 {
            blocks[i].depth -= 1
            touch(i)
            onChange?(.rows([i]))
            return
        }
        guard i > 0 else { return }
        let previous = blocks[i - 1]
        if previous.type.hasText {
            let junction = previous.runs.utf16Count
            blocks[i - 1].runs = (previous.runs + block.runs).normalized()
            touch(i - 1)
            remove(at: i)
            focus = Focus(blockID: previous.id, offset: junction)
        } else if block.runs.isEmpty {
            remove(at: i)
            focus = Focus(blockID: previous.id, offset: 0)
        } else {
            // Backspace into a divider or diagram removes that block, keeping the text.
            remove(at: i - 1)
            focus = Focus(blockID: id, offset: 0)
        }
        onChange?(.structure)
    }

    public func indent(_ id: String) {
        guard let i = index(of: id), i > 0 else { return }
        let limit = blocks[i - 1].depth + 1
        guard blocks[i].depth < limit, blocks[i].depth < 6 else { return }
        checkpoint()
        blocks[i].depth += 1
        touch(i)
        onChange?(.rows([i]))
    }

    public func outdent(_ id: String) {
        guard let i = index(of: id), blocks[i].depth > 0 else { return }
        checkpoint()
        blocks[i].depth -= 1
        touch(i)
        onChange?(.rows([i]))
    }

    public func setType(_ type: BlockType, for id: String) {
        guard let i = index(of: id), blocks[i].type != type else { return }
        checkpoint()
        blocks[i].type = type
        blocks[i].props = type == .todo ? BlockProps(checked: false) : BlockProps()
        if !type.hasText { blocks[i].runs = [] }
        touch(i)
        if !type.hasText, i == blocks.count - 1 || !blocks[i + 1].type.hasText {
            let next = Block(pageID: pageID, type: .paragraph, depth: blocks[i].depth, position: position(after: i))
            blocks.insert(next, at: i + 1)
            touch(i + 1)
            focus = Focus(blockID: next.id, offset: 0)
            onChange?(.structure)
        } else {
            focus = Focus(blockID: id, offset: min(focus?.offset ?? 0, blocks[i].runs.utf16Count))
            onChange?(.rows([i]))
        }
    }

    public func toggleChecked(_ id: String) {
        guard let i = index(of: id), blocks[i].type == .todo else { return }
        checkpoint()
        blocks[i].props.checked = !(blocks[i].props.checked ?? false)
        touch(i)
        onChange?(.rows([i]))
    }

    /// Inserts a new block after `id` (or at the top when nil) and focuses it.
    @discardableResult
    public func insertBlock(_ draft: Block, after id: String?) -> String {
        checkpoint()
        let i = id.flatMap(index(of:)) ?? -1
        var block = draft
        block.pageID = pageID
        block.position = position(after: i)
        blocks.insert(block, at: i + 1)
        touch(i + 1)
        if block.type.hasText { focus = Focus(blockID: block.id, offset: 0) }
        onChange?(.structure)
        return block.id
    }

    public func delete(_ id: String) {
        guard let i = index(of: id) else { return }
        checkpoint()
        remove(at: i)
        if blocks.isEmpty {
            let first = Block(pageID: pageID, type: .paragraph, position: 1024)
            blocks = [first]
            touch(0)
        }
        let target = blocks[min(i, blocks.count - 1)]
        focus = Focus(blockID: target.id, offset: 0)
        onChange?(.structure)
    }

    /// Replaces a UTF-16 range of one block's text with new content (an accepted AI edit).
    /// One replacement block is spliced into the text; several become following blocks,
    /// with whatever came after the range attached to the last of them.
    public func replaceText(in id: String, range: Range<Int>, with drafts: [Block]) {
        guard let i = index(of: id), let first = drafts.first else { return }
        checkpoint()
        let (head, rest) = blocks[i].runs.splitUTF16(at: range.lowerBound)
        let tail = rest.droppingUTF16Prefix(range.upperBound - range.lowerBound)
        let wholeBlock = head.isEmpty && tail.isEmpty
        if drafts.count == 1 {
            blocks[i].runs = (head + first.runs + tail).normalized()
            if wholeBlock, first.type != .paragraph, first.type.hasText { blocks[i].type = first.type; blocks[i].props = first.props }
            touch(i)
            focus = Focus(blockID: id, offset: (head + first.runs).utf16Count)
            onChange?(.rows([i]))
            return
        }
        blocks[i].runs = (head + first.runs).normalized()
        if wholeBlock, first.type.hasText { blocks[i].type = first.type; blocks[i].props = first.props }
        touch(i)
        var at = i
        for draft in drafts.dropFirst() {
            var block = draft
            block.id = newID()
            block.pageID = pageID
            block.depth += blocks[i].depth
            block.position = position(after: at)
            blocks.insert(block, at: at + 1)
            at += 1
            touch(at)
        }
        if !tail.isEmpty {
            if blocks[at].type.hasText {
                blocks[at].runs = (blocks[at].runs + tail).normalized()
            } else {
                blocks.insert(Block(pageID: pageID, type: .paragraph, depth: blocks[i].depth, position: position(after: at), runs: tail), at: at + 1)
                at += 1
            }
            touch(at)
        }
        focus = blocks[at].type.hasText ? Focus(blockID: blocks[at].id, offset: blocks[at].runs.utf16Count - tail.utf16Count) : nil
        onChange?(.structure)
    }

    /// Inserts several blocks after `id` as one undo step (AI "insert below").
    public func insertBlocks(_ drafts: [Block], after id: String) {
        guard var at = index(of: id), !drafts.isEmpty else { return }
        checkpoint()
        let depth = blocks[at].depth
        for draft in drafts {
            var block = draft
            block.id = newID()
            block.pageID = pageID
            block.depth += depth
            block.position = position(after: at)
            blocks.insert(block, at: at + 1)
            at += 1
            touch(at)
        }
        focus = blocks[at].type.hasText ? Focus(blockID: blocks[at].id, offset: blocks[at].runs.utf16Count) : nil
        onChange?(.structure)
    }

    /// Drag reorder: move the block at `source` so it lands at `destination` (an index in the list before removal).
    public func move(from source: Int, to destination: Int) {
        guard blocks.indices.contains(source), destination != source, destination != source + 1 else { return }
        checkpoint()
        let block = blocks.remove(at: source)
        let target = destination > source ? destination - 1 : destination
        blocks.insert(block, at: min(target, blocks.count))
        let i = min(target, blocks.count - 1)
        blocks[i].position = position(after: i - 1, before: i + 1)
        blocks[i].depth = min(blocks[i].depth, i > 0 ? blocks[i - 1].depth + 1 : 0)
        touch(i)
        onChange?(.structure)
    }

    /// The block the caret should move to with the up / down arrow keys.
    public func neighbour(of id: String, direction: Int) -> String? {
        guard var i = index(of: id) else { return nil }
        i += direction
        while blocks.indices.contains(i) {
            if blocks[i].type.hasText { return blocks[i].id }
            i += direction
        }
        return nil
    }

    // MARK: Undo

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func undo() { restore(from: &undoStack, saving: &redoStack) }
    public func redo() { restore(from: &redoStack, saving: &undoStack) }

    private func restore(from: inout [Snapshot], saving: inout [Snapshot]) {
        guard let snapshot = from.popLast() else { return }
        saving.append(Snapshot(blocks: blocks, focus: focus))
        let before = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        let after = Set(snapshot.blocks.map(\.id))
        for block in snapshot.blocks where before[block.id] != block {
            dirty.insert(block.id)
            deleted.remove(block.id)
        }
        for id in before.keys where !after.contains(id) {
            dirty.remove(id)
            deleted.insert(id)
        }
        blocks = snapshot.blocks
        focus = snapshot.focus
        lastTypingCheckpoint = nil
        onChange?(.structure)
        onDirty?()
    }

    private func checkpoint() {
        undoStack.append(Snapshot(blocks: blocks, focus: focus))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        lastTypingCheckpoint = nil
    }

    /// Typing in one block collapses into a single undo step per pause.
    private func typingCheckpoint(_ id: String) {
        let now = Date()
        if let last = lastTypingCheckpoint, last.blockID == id, now.timeIntervalSince(last.at) < 1.5 {
            lastTypingCheckpoint = (id, now)
            return
        }
        checkpoint()
        lastTypingCheckpoint = (id, now)
    }

    // MARK: Changes from another process (MCP / AI)

    /// Merges the page as it now is in the database. A block with unsaved local edits
    /// keeps the local version; the returned ids are those conflicts.
    @discardableResult
    public func applyRemote(_ fresh: [Block]) -> [String] {
        var conflicts: [String] = []
        let local = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        var merged: [Block] = []
        var seen = Set<String>()
        for block in fresh where !deleted.contains(block.id) {
            seen.insert(block.id)
            if dirty.contains(block.id), let mine = local[block.id] {
                if mine.runs != block.runs || mine.type != block.type { conflicts.append(block.id) }
                merged.append(mine)
            } else {
                merged.append(block)
            }
        }
        // Blocks created locally and not yet saved are not in `fresh`; keep them.
        for block in blocks where !seen.contains(block.id) && dirty.contains(block.id) {
            merged.append(block)
        }
        merged.sort { $0.position < $1.position }
        guard merged != blocks else { return conflicts }
        blocks = merged.isEmpty ? [Block(pageID: pageID, type: .paragraph, position: 1024)] : merged
        if let f = focus, index(of: f.blockID) == nil { focus = nil }
        undoStack.removeAll()
        redoStack.removeAll()
        onChange?(.structure)
        return conflicts
    }

    // MARK: Helpers

    private func touch(_ i: Int) {
        blocks[i].updatedAt = Date()
        dirty.insert(blocks[i].id)
        onDirty?()
    }

    private func remove(at i: Int) {
        let id = blocks.remove(at: i).id
        dirty.remove(id)
        deleted.insert(id)
        onDirty?()
    }

    /// A position between the block at `i` and its successor (`i == -1` means before the first).
    private func position(after i: Int) -> Double { position(after: i, before: i + 1) }

    private func position(after i: Int, before j: Int) -> Double {
        let prev = blocks.indices.contains(i) ? blocks[i].position : 0
        if blocks.indices.contains(j) {
            let next = blocks[j].position
            if next - prev > 1e-6 { return (prev + next) / 2 }
            renumber()
            return ((blocks.indices.contains(i) ? blocks[i].position : 0) + blocks[j].position) / 2
        }
        return prev + 1024
    }

    private func renumber() {
        for k in blocks.indices {
            blocks[k].position = Double(k + 1) * 1024
            dirty.insert(blocks[k].id)
        }
    }
}

// MARK: - Run arithmetic in UTF-16 units

public extension Array where Element == TextRun {
    var utf16Count: Int { reduce(0) { $0 + $1.text.utf16.count } }

    func splitUTF16(at offset: Int) -> (head: [TextRun], tail: [TextRun]) {
        var head: [TextRun] = []
        var tail: [TextRun] = []
        var consumed = 0
        for run in self {
            let length = run.text.utf16.count
            if consumed + length <= offset {
                head.append(run)
            } else if consumed >= offset {
                tail.append(run)
            } else {
                let cut = String.Index(utf16Offset: offset - consumed, in: run.text)
                head.append(TextRun(String(run.text[..<cut]), marks: run.marks, link: run.link))
                tail.append(TextRun(String(run.text[cut...]), marks: run.marks, link: run.link))
            }
            consumed += length
        }
        return (head.normalized(), tail.normalized())
    }

    func droppingUTF16Prefix(_ count: Int) -> [TextRun] { splitUTF16(at: count).tail }
}
