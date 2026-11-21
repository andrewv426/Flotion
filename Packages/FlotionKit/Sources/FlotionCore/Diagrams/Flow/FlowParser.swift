import Foundation

/// Reads Flow source, one statement per line:
///
///     flow right | down
///     id: Label {shape: box | pill | circle | diamond | database}
///     a -> b: label {style: dashed}   # also <-, <->, -- and mixed chains
///     group id "Title" {  ...nodes...  }
///     step "Title": caption
///       send a -> b: label    focus a, b    tag a: status    mark a: good
///       set a: New label      hide a        show a           x: New node
///
/// The language is closed on purpose: no coordinates, colours or sizes, so every diagram comes out in one
/// visual system. Anything it cannot read is an issue with a line number and, where it can guess, the fix.
public enum FlowParser {
    public static let maxNodes = 80
    public static let maxEdges = 200
    public static let maxSteps = 60

    public static func parse(_ source: String) -> (diagram: FlowDiagram, issues: [FlowIssue]) {
        var reader = Reader()
        for (index, line) in source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            reader.read(String(line), line: index + 1)
        }
        reader.finish()
        return (reader.diagram, reader.issues)
    }
}

private struct Reader {
    var diagram = FlowDiagram()
    var issues: [FlowIssue] = []
    private var nodeAt: [String: Int] = [:]
    private var groupAt: [String: Int] = [:]
    private var openGroup: Int?

    private static let verbs: Set<String> = ["show", "hide", "set", "tag", "mark", "send", "focus"]
    private static let reserved = verbs.union(["flow", "group", "step"])
    private static let shapeAliases = ["cylinder": "database", "db": "database", "rect": "box", "rectangle": "box", "square": "box",
                                       "rounded": "box", "oval": "pill", "ellipse": "pill", "stadium": "pill", "rhombus": "diamond",
                                       "decision": "diamond"]
    private static let toneAliases = ["green": "good", "success": "good", "ok": "good", "red": "bad", "error": "bad", "danger": "bad",
                                      "yellow": "warn", "orange": "warn", "warning": "warn", "blue": "accent", "highlight": "accent",
                                      "gray": "muted", "grey": "muted", "clear": "none"]
    private static let tones = FlowTone.allCases.map(\.rawValue) + ["none"]
    private static let shapes = FlowShape.allCases.map(\.rawValue)

    private mutating func fail(_ line: Int, _ message: String) { issues.append(FlowIssue(line: line, message: message)) }

    // MARK: Lines

    mutating func read(_ raw: String, line: Int) {
        let s = Self.stripComment(raw).trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return }
        if s == "}" {
            if openGroup == nil { fail(line, "`}` without an open group") }
            openGroup = nil
            return
        }
        let word = Self.leadingWord(s)
        guard Self.reserved.contains(word) else { return readDeclaration(s, line) }
        let rest = s.dropFirst(word.count).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix(":") { return fail(line, "`\(word)` is a reserved word and cannot be a node id") }
        switch word {
        case "flow": readDirection(rest, line)
        case "group": readGroup(rest, line)
        case "step": readStep(rest, line)
        default: readVerb(word, rest, line)
        }
    }

    mutating func finish() {
        if let open = openGroup { fail(diagram.groups[open].line, "group `\(diagram.groups[open].id)` is never closed with `}`") }
        if diagram.nodes.isEmpty && issues.isEmpty { fail(1, "the diagram has no nodes") }
    }

    private mutating func readDirection(_ rest: String, _ line: Int) {
        let value = rest.lowercased()
        if let direction = FlowDiagram.Direction(rawValue: value) { diagram.direction = direction; return }
        let alias = ["lr": "right", "tb": "down", "td": "down", "horizontal": "right", "vertical": "down"][value]
        fail(line, "direction must be `right` or `down`" + (alias.map { ", did you mean `flow \($0)`?" } ?? ""))
    }

    private mutating func readGroup(_ rest: String, _ line: Int) {
        let help = "write a group as `group id \"Title\" {` and close it with `}` on its own line"
        guard rest.hasSuffix("{") else { return fail(line, help) }
        let body = rest.dropLast().trimmingCharacters(in: .whitespaces)
        let id = Self.leadingWord(body)
        guard !id.isEmpty else { return fail(line, help) }
        var title = body.dropFirst(id.count).trimmingCharacters(in: .whitespaces)
        if title.hasPrefix(":") { title = title.dropFirst().trimmingCharacters(in: .whitespaces) }
        if openGroup != nil { return fail(line, "groups cannot be nested") }
        if !diagram.steps.isEmpty { return fail(line, "declare groups before the first step") }
        if groupAt[id] != nil || nodeAt[id] != nil { return fail(line, "`\(id)` is already declared") }
        let unquoted = Self.unquote(title)
        groupAt[id] = diagram.groups.count
        openGroup = diagram.groups.count
        diagram.groups.append(FlowGroup(id: id, title: unquoted.isEmpty ? id : unquoted, line: line))
    }

    private mutating func readStep(_ rest: String, _ line: Int) {
        if let open = openGroup {
            fail(line, "close group `\(diagram.groups[open].id)` with `}` before the first step")
            openGroup = nil
        }
        var title = rest, caption = ""
        if rest.hasPrefix("\""), let close = rest.dropFirst().firstIndex(of: "\"") {
            title = String(rest[rest.index(after: rest.startIndex)..<close])
            let after = rest[rest.index(after: close)...].trimmingCharacters(in: .whitespaces)
            if after.hasPrefix(":") { caption = String(after.dropFirst()) }
            else if !after.isEmpty { fail(line, "a step is written `step \"Title\": caption`") }
        } else if let split = rest.range(of: ": ") {
            title = String(rest[..<split.lowerBound])
            caption = String(rest[split.upperBound...])
        } else if rest.hasSuffix(":") {
            title = String(rest.dropLast())
        }
        title = title.trimmingCharacters(in: .whitespaces)
        if title.isEmpty { fail(line, "a step needs a title: `step \"Title\": caption`") }
        if diagram.steps.count >= FlowParser.maxSteps { return fail(line, "a diagram can have at most \(FlowParser.maxSteps) steps") }
        diagram.steps.append(FlowStep(title: title, caption: caption.trimmingCharacters(in: .whitespaces), line: line))
    }

    // MARK: Step verbs

    private mutating func readVerb(_ verb: String, _ body: String, _ line: Int) {
        guard !diagram.steps.isEmpty else { return fail(line, "`\(verb)` only works inside a step") }
        let colon = body.firstIndex(of: ":")
        let head = (colon.map { String(body[..<$0]) } ?? body).trimmingCharacters(in: .whitespaces)
        let value = colon.map { Self.unquote(String(body[body.index(after: $0)...])) }
        let step = diagram.steps.count - 1

        switch verb {
        case "show": diagram.steps[step].ops.append(.show(targets(body, line, allowEdges: true)))
        case "hide": diagram.steps[step].ops.append(.hide(targets(body, line, allowEdges: true)))
        case "focus": diagram.steps[step].ops.append(.focus(targets(body, line, allowEdges: false)))
        case "set":
            guard let value, !value.isEmpty else { return fail(line, "write `set id: New label`") }
            guard let index = knownNode(head, line) else { return }
            diagram.nodes[index].labels.append(value)
            diagram.steps[step].ops.append(.set(node: head, label: value))
        case "tag":
            let found = targets(head, line, allowEdges: false)
            for id in nodeIDs(found) { if let index = nodeAt[id] { diagram.nodes[index].tags.append(value ?? "") } }
            diagram.steps[step].ops.append(.tag(found, value ?? ""))
        case "mark":
            let name = (value ?? "").lowercased()
            guard Self.tones.contains(name) else {
                let guess = Self.toneAliases[name] ?? Self.closest(name, in: Self.tones)
                return fail(line, "tone must be one of \(Self.tones.joined(separator: ", "))" + Self.didYouMean(guess))
            }
            diagram.steps[step].ops.append(.mark(targets(head, line, allowEdges: false), FlowTone(rawValue: name)))
        case "send":
            guard let pair = Self.pair(head) else { return fail(line, "write `send a -> b: label`") }
            guard knownNode(pair.0, line) != nil, knownNode(pair.1, line) != nil else { return }
            guard let found = edge(from: pair.0, to: pair.1) else {
                return fail(line, "no edge between `\(pair.0)` and `\(pair.1)`. Declare `\(pair.0) -> \(pair.1)` first")
            }
            let label = value.flatMap { $0.isEmpty ? nil : $0 }
            if let label { diagram.edges[found.index].labels.append(label) }
            diagram.steps[step].ops.append(.send(edge: found.index, against: found.against, label: label, to: pair.1))
        default: break
        }
    }

    private mutating func targets(_ list: String, _ line: Int, allowEdges: Bool) -> [FlowTarget] {
        let parts = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.isEmpty { fail(line, "name at least one node") }
        var out: [FlowTarget] = []
        for part in parts {
            if let ref = Self.edgeRef(part) {
                guard allowEdges else { fail(line, "this takes nodes or groups, not edges"); continue }
                guard knownNode(ref.from, line) != nil, knownNode(ref.to, line) != nil else { continue }
                if let index = edge(matching: ref.from, kind: ref.kind, to: ref.to) { out.append(.edge(index)) }
                else { fail(line, "no edge `\(ref.from) \(ref.kind.operatorSymbol) \(ref.to)`") }
            } else if nodeAt[part] != nil {
                out.append(.node(part))
            } else if groupAt[part] != nil {
                out.append(.group(part))
            } else {
                fail(line, "unknown node or group `\(part)`" + Self.didYouMean(Self.closest(part, in: Array(nodeAt.keys) + Array(groupAt.keys))))
            }
        }
        return out
    }

    private func nodeIDs(_ targets: [FlowTarget]) -> [String] {
        targets.flatMap { target -> [String] in
            switch target {
            case .node(let id): [id]
            case .group(let id): groupAt[id].map { diagram.groups[$0].members } ?? []
            case .edge: []
            }
        }
    }

    private mutating func knownNode(_ id: String, _ line: Int) -> Int? {
        if let index = nodeAt[id] { return index }
        let guess = Self.closest(id, in: Array(nodeAt.keys))
        fail(line, "unknown node `\(id)`" + (guess.map { ", did you mean `\($0)`?" } ?? ". Declare it first: `\(id): Label`"))
        return nil
    }

    private func edge(from x: String, to y: String) -> (index: Int, against: Bool)? {
        // Prefer an edge whose natural direction is x -> y.
        if let index = diagram.edges.firstIndex(where: { $0.points(from: x, to: y) }) {
            return (index, diagram.edges[index].from != x)
        }
        // Then a symmetric (<-> or --) edge connecting x and y.
        if let index = diagram.edges.firstIndex(where: { $0.kind.isSymmetric && $0.connects(x, y) }) {
            return (index, diagram.edges[index].from != x)
        }
        // Finally, an opposite-direction edge connecting x and y.
        if let index = diagram.edges.firstIndex(where: { $0.connects(x, y) }) {
            return (index, diagram.edges[index].from != x)
        }
        return nil
    }

    private func edge(matching a: String, kind: FlowEdgeKind, to b: String) -> Int? {
        if kind.isSymmetric {
            return diagram.edges.firstIndex { $0.kind == kind && $0.connects(a, b) }
        }
        let (src, dst) = kind == .forward ? (a, b) : (b, a)
        return diagram.edges.firstIndex { $0.points(from: src, to: dst) }
    }

    private func hasDuplicateEdge(from a: String, kind: FlowEdgeKind, to b: String) -> Bool {
        if kind.isSymmetric {
            return diagram.edges.contains { $0.kind.isSymmetric && $0.connects(a, b) }
        }
        let (src, dst) = kind == .forward ? (a, b) : (b, a)
        return diagram.edges.contains { $0.points(from: src, to: dst) }
    }

    // MARK: Declarations

    private mutating func readDeclaration(_ statement: String, _ line: Int) {
        var s = statement
        var attributes: [(key: String, value: String)] = []
        if let block = Self.attributeBlock(s) {
            s = block.rest
            for part in block.inner.split(whereSeparator: { $0 == "," || $0 == ";" }).map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                let pieces = part.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pieces.count == 2, !pieces[0].isEmpty, pieces[0].allSatisfy(\.isLetter), !pieces[1].isEmpty {
                    attributes.append((pieces[0].lowercased(), pieces[1].lowercased()))
                } else {
                    fail(line, "attributes are written `{key: value}`, got `\(part)`")
                }
            }
        }
        let colon = s.firstIndex(of: ":")
        let head = (colon.map { String(s[..<$0]) } ?? s).trimmingCharacters(in: .whitespaces)
        let label = colon.map { Self.unquote(String(s[s.index(after: $0)...])) } ?? ""
        let enter = diagram.steps.count - 1

        if let chain = Self.edgeChain(head) {
            var dashed = false
            for (key, value) in attributes {
                if key != "style" { fail(line, "edges take `style`, got `\(key)`") }
                else if value == "dashed" || value == "solid" { dashed = value == "dashed" }
                else { fail(line, "style must be `dashed` or `solid`") }
            }
            for (a, kind, b) in chain {
                guard knownNode(a, line) != nil, knownNode(b, line) != nil else { continue }
                if a == b { fail(line, "`\(a)` cannot point at itself"); continue }
                if hasDuplicateEdge(from: a, kind: kind, to: b) {
                    fail(line, "`\(a) \(kind.operatorSymbol) \(b)` is already declared")
                    continue
                }
                if diagram.edges.count >= FlowParser.maxEdges { fail(line, "a diagram can have at most \(FlowParser.maxEdges) edges"); continue }
                diagram.edges.append(FlowEdge(from: a, to: b, kind: kind, label: label, dashed: dashed, enter: enter, line: line,
                                              labels: label.isEmpty ? [] : [label]))
            }
            return
        } else if Self.isID(head) {
            if let earlier = nodeAt[head].map({ diagram.nodes[$0].line }) ?? groupAt[head].map({ diagram.groups[$0].line }) {
                return fail(line, "`\(head)` is already declared on line \(earlier)")
            }
            var shape = FlowShape.box
            for (key, value) in attributes {
                if key != "shape" { fail(line, "nodes take `shape`, got `\(key)`") }
                else if let known = FlowShape(rawValue: value) { shape = known }
                else {
                    let guess = Self.shapeAliases[value] ?? Self.closest(value, in: Self.shapes)
                    fail(line, "shape must be one of \(Self.shapes.joined(separator: ", "))" + Self.didYouMean(guess))
                }
            }
            if diagram.nodes.count >= FlowParser.maxNodes { return fail(line, "a diagram can have at most \(FlowParser.maxNodes) nodes") }
            let shown = label.isEmpty ? head : label
            nodeAt[head] = diagram.nodes.count
            diagram.nodes.append(FlowNode(id: head, label: shown, shape: shape, group: openGroup.map { diagram.groups[$0].id },
                                          enter: enter, line: line, labels: [shown]))
            if let open = openGroup { diagram.groups[open].members.append(head) }
            return
        }

        var hint = ""
        if statement.contains("-->") || statement.contains("<--") || statement.contains("==>") || statement.contains("-.->") || statement.contains("---") {
            hint = " Edges are written `a -> b: label`."
        } else if statement.contains("[") || statement.contains("(") {
            hint = " Nodes are written `id: Label {shape: box}`."
        }
        fail(line, "cannot read this line." + hint)
    }

    // MARK: Text helpers

    private static func isIDStart(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c == "_") }
    private static func isIDPart(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_" || c == "-") }

    static func isID(_ s: String) -> Bool {
        guard let first = s.first, isIDStart(first) else { return false }
        return s.allSatisfy(isIDPart)
    }

    private static func leadingWord(_ s: String) -> String {
        guard let first = s.first, isIDStart(first) else { return "" }
        return String(s.prefix(while: isIDPart))
    }

    /// `a -> b` with both sides valid ids (used by `send`).
    private static func pair(_ s: String) -> (String, String)? {
        guard let ref = edgeRef(s), ref.kind == .forward else { return nil }
        return (ref.from, ref.to)
    }

    /// A single edge reference using any of `->`, `<-`, `<->`, or `--`.
    private static func edgeRef(_ s: String) -> (from: String, kind: FlowEdgeKind, to: String)? {
        guard let chain = edgeChain(s), chain.count == 1 else { return nil }
        return chain[0]
    }

    /// Parses `a op b (op c)*` left-to-right where each `op` is `<->`, `<-`, `->`, or `--`.
    private static func edgeChain(_ s: String) -> [(from: String, kind: FlowEdgeKind, to: String)]? {
        var i = s.startIndex
        func skipSpaces() {
            while i < s.endIndex, s[i].isWhitespace { i = s.index(after: i) }
        }
        func match(_ token: String) -> Bool {
            guard s[i...].hasPrefix(token) else { return false }
            i = s.index(i, offsetBy: token.count)
            return true
        }
        func readID() -> String? {
            guard i < s.endIndex, isIDStart(s[i]) else { return nil }
            let start = i
            i = s.index(after: i)
            while i < s.endIndex, isIDPart(s[i]) {
                if s[i] == "-" {
                    let next = s.index(after: i)
                    if next < s.endIndex, s[next] == ">" || s[next] == "-" { break }
                }
                i = s.index(after: i)
            }
            return String(s[start..<i])
        }
        func readOp() -> FlowEdgeKind? {
            if match("<->") { return .bidirectional }
            if match("<-") { return .backward }
            if match("->") { return .forward }
            if match("--") { return .undirected }
            return nil
        }

        skipSpaces()
        guard var current = readID() else { return nil }
        var out: [(from: String, kind: FlowEdgeKind, to: String)] = []
        while true {
            skipSpaces()
            if i == s.endIndex { break }
            guard let kind = readOp() else { return nil }
            skipSpaces()
            guard let next = readID() else { return nil }
            out.append((current, kind, next))
            current = next
        }
        return out.isEmpty ? nil : out
    }

    /// `#` starts a comment when it begins the line or follows a space, outside quotes.
    private static func stripComment(_ s: String) -> String {
        var quoted = false
        var previous: Character = " "
        for index in s.indices {
            let c = s[index]
            if c == "\"" { quoted.toggle() }
            else if c == "#", !quoted, previous.isWhitespace { return String(s[..<index]) }
            previous = c
        }
        return s
    }

    private static func unquote(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.count >= 2 && t.hasPrefix("\"") && t.hasSuffix("\"") ? String(t.dropFirst().dropLast()) : t
    }

    /// A trailing `{...}` that is not inside a quoted label.
    private static func attributeBlock(_ s: String) -> (rest: String, inner: String)? {
        guard s.hasSuffix("}"), let open = s.lastIndex(of: "{") else { return nil }
        let inner = s[s.index(after: open)..<s.index(before: s.endIndex)]
        guard !inner.contains("}"), s[..<open].filter({ $0 == "\"" }).count % 2 == 0 else { return nil }
        return (s[..<open].trimmingCharacters(in: .whitespaces), String(inner))
    }

    private static func didYouMean(_ guess: String?) -> String { guess.map { ", did you mean `\($0)`?" } ?? "" }

    /// The option within two edits of `word`, if there is one. Short words get less leeway, and one- or
    /// two-letter words none: every other short id is "close" to them, which would only mislead.
    private static func closest(_ word: String, in options: [String]) -> String? {
        let a = Array(word.lowercased())
        var best: String?
        var bestDistance = a.count <= 2 ? 1 : a.count <= 4 ? 2 : 3
        for option in options.sorted() {
            let b = Array(option.lowercased())
            var row = Array(0...b.count)
            for i in 0..<a.count {
                var previous = row[0]
                row[0] = i + 1
                for j in 0..<b.count {
                    let current = row[j + 1]
                    row[j + 1] = min(row[j + 1] + 1, row[j] + 1, previous + (a[i] == b[j] ? 0 : 1))
                    previous = current
                }
            }
            if row[b.count] < bestDistance { bestDistance = row[b.count]; best = option }
        }
        return best
    }
}
