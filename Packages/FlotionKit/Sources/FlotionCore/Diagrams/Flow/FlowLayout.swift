import CoreText
import Foundation

public struct FlowPoint: Sendable, Equatable {
    public var x: Double
    public var y: Double
}

/// A rectangle by its top-left corner.
public struct FlowRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
}

/// The one set of sizes every Flow diagram is drawn with.
enum FlowMetrics {
    static let labelSize = 14.0, tagSize = 12.0, edgeLabelSize = 12.5
    static let groupPad = 16.0, groupTitle = 20.0, databaseRy = 6.0
    static let tipGap = 3.0, headLength = 8.0, headHalf = 3.4, margin = 14.0
}

/// Measures text in the system font, the same face the web view draws with.
public enum FlowText {
    public static func width(_ text: String, size: Double, medium: Bool) -> Double {
        var font = CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
        if medium {
            let traits = [kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.23]] as CFDictionary
            font = CTFontCreateWithFontDescriptor(CTFontDescriptorCreateCopyWithAttributes(CTFontCopyFontDescriptor(font), traits), size, nil)
        }
        let string = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        // A little slack: the web view may shape the same text a fraction wider.
        return ceil(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(string), nil, nil, nil) * 1.03)
    }
}

/// Where everything in a diagram goes. Computed once over every element the diagram ever shows,
/// so nothing moves between steps: things only appear in the space already kept for them.
public struct FlowLayout: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        /// The centre.
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double
        /// The node shows a status tag in at least one step, so it is tall enough for two lines.
        public var tagged: Bool
    }
    public struct Edge: Sendable, Equatable {
        /// Waypoints from the end nearer the start of the flow to the end further along it. The first and
        /// last sit on the node outlines.
        public var points: [FlowPoint]
        /// The edge closes a loop, so it was laid out against its declared direction: `points` runs from `to` to `from`.
        public var flipped: Bool
        public var label: FlowPoint
        /// The label starts at `label` (beside a vertical line) instead of being centred on it.
        public var labelStartsAtPoint: Bool
        public var labelWidth: Double
        /// Both ends are in the same group, so the label sits on the group's fill, not the page.
        public var insideGroup: Bool
    }

    public var horizontal: Bool
    public var nodes: [Node]
    public var edges: [Edge]
    /// `nil` for a group with no members.
    public var groups: [FlowRect?]
    public var bounds: FlowRect
    public var crossings: Int

    public static func compute(_ diagram: FlowDiagram,
                               measure: (_ text: String, _ size: Double, _ medium: Bool) -> Double = FlowText.width) -> FlowLayout {
        typealias M = FlowMetrics
        let H = diagram.direction == .right
        let count = diagram.nodes.count
        guard count > 0 else {
            return FlowLayout(horizontal: H, nodes: [], edges: [], groups: diagram.groups.map { _ in nil }, bounds: FlowRect(x: 0, y: 0, w: 0, h: 0), crossings: 0)
        }
        func even(_ v: Double) -> Double { 2 * (v / 2).rounded(.up) }

        var nodes: [Node] = diagram.nodes.map { node in
            let text = max(node.labels.map { measure($0, M.labelSize, true) }.max() ?? 0, node.tags.map { measure($0, M.tagSize, false) }.max() ?? 0)
            let tagged = node.tags.contains { !$0.isEmpty }
            var w = max(104, text + 36), h: Double = tagged ? 58 : 44
            switch node.shape {
            case .box: break
            case .pill: w += 8
            case .database: h += 10
            case .diamond: w = max(116, text + 72); h = tagged ? 82 : 64
            case .circle: w = max(tagged ? 72 : 60, text + 30); h = w
            }
            return Node(x: 0, y: 0, w: even(w), h: even(h), tagged: tagged)
        }

        // Break cycles: an edge that points back up the depth-first tree is laid out reversed.
        let index = Dictionary(uniqueKeysWithValues: diagram.nodes.enumerated().map { ($1.id, $0) })
        let ends = diagram.edges.map { (u: index[$0.from] ?? 0, v: index[$0.to] ?? 0) }
        var outgoing = [[Int]](repeating: [], count: count)
        for (i, end) in ends.enumerated() { outgoing[end.u].append(i) }
        var flipped = [Bool](repeating: false, count: ends.count)
        var seen = [Int](repeating: 0, count: count)
        func visit(_ u: Int) {
            seen[u] = 1
            for ei in outgoing[u] {
                let v = ends[ei].v
                if seen[v] == 1 { flipped[ei] = true } else if seen[v] == 0 { visit(v) }
            }
            seen[u] = 2
        }
        for i in 0..<count where seen[i] == 0 { visit(i) }
        let laid = ends.enumerated().map { i, end in flipped[i] ? (a: end.v, b: end.u) : (a: end.u, b: end.v) }

        // Rank by longest path, then pull lone sources next to what they feed.
        var rank = [Int](repeating: 0, count: count)
        var succ = [[Int]](repeating: [], count: count), pred = [[Int]](repeating: [], count: count)
        for l in laid { succ[l.a].append(l.b); pred[l.b].append(l.a) }
        var waiting = pred.map(\.count)
        var queue = (0..<count).filter { waiting[$0] == 0 }
        var next = 0
        while next < queue.count {
            let u = queue[next]
            next += 1
            for v in succ[u] {
                rank[v] = max(rank[v], rank[u] + 1)
                waiting[v] -= 1
                if waiting[v] == 0 { queue.append(v) }
            }
        }
        for i in 0..<count where pred[i].isEmpty && !succ[i].isEmpty { rank[i] = (succ[i].map { rank[$0] }.min() ?? 1) - 1 }

        // Items are real nodes plus one dummy per rank a long edge passes through.
        struct Item {
            var node: Int?
            var rank: Int
            var rs: Double   // size along the flow
            var cs: Double   // size across it
            var group: String?
            var up: [Int] = []
            var down: [Int] = []
            var c = 0.0
            var r = 0.0
            var dummy: Bool { node == nil }
        }
        var items = (0..<count).map { Item(node: $0, rank: rank[$0], rs: H ? nodes[$0].w : nodes[$0].h, cs: H ? nodes[$0].h : nodes[$0].w, group: diagram.nodes[$0].group) }
        var chains: [[Int]] = []
        for l in laid {
            let group = diagram.nodes[l.a].group
            let shared = group != nil && group == diagram.nodes[l.b].group ? group : nil
            var chain = [l.a]
            if rank[l.b] - rank[l.a] > 1 {
                for r in (rank[l.a] + 1)..<rank[l.b] {
                    items.append(Item(node: nil, rank: r, rs: 0, cs: 0, group: shared))
                    chain.append(items.count - 1)
                }
            }
            chain.append(l.b)
            for k in 0..<(chain.count - 1) {
                items[chain[k]].down.append(chain[k + 1])
                items[chain[k + 1]].up.append(chain[k])
            }
            chains.append(chain)
        }
        let R = (items.map(\.rank).max() ?? 0) + 1
        var ranks = [[Int]](repeating: [], count: R)
        for (i, item) in items.enumerated() { ranks[item.rank].append(i) }

        // Order each rank by the barycenter of its neighbours, keeping group members together.
        let segments = chains.flatMap { chain in zip(chain, chain.dropFirst()).map { ($0, $1) } }
        func crossingCount(_ order: [[Int]]) -> Int {
            var position = [Int](repeating: 0, count: items.count)
            for r in order { for (i, item) in r.enumerated() { position[item] = i } }
            var perRank = [[(Int, Int)]](repeating: [], count: R)
            for (a, b) in segments { perRank[items[a].rank].append((position[a], position[b])) }
            var total = 0
            for list in perRank {
                for i in 0..<list.count {
                    for j in (i + 1)..<list.count where (list[i].0 - list[j].0) * (list[i].1 - list[j].1) < 0 { total += 1 }
                }
            }
            return total
        }
        func arrange(_ k: Int, _ weight: [Int: Double]) {
            var sums: [String: (sum: Double, n: Double)] = [:]
            for item in ranks[k] {
                guard let group = items[item].group else { continue }
                let old = sums[group] ?? (0, 0)
                sums[group] = (old.sum + (weight[item] ?? 0), old.n + 1)
            }
            func key(_ item: Int) -> Double {
                if let group = items[item].group, let s = sums[group] { return s.sum / s.n }
                return weight[item] ?? 0
            }
            func unit(_ item: Int) -> String { items[item].group ?? "~\(item)" }
            let now = Dictionary(uniqueKeysWithValues: ranks[k].enumerated().map { ($1, $0) })
            ranks[k] = ranks[k].sorted { a, b in
                let ka = key(a), kb = key(b)
                if ka != kb { return ka < kb }
                let ua = unit(a), ub = unit(b)
                if ua != ub { return ua < ub }
                let wa = weight[a] ?? 0, wb = weight[b] ?? 0
                if wa != wb { return wa < wb }
                return (now[a] ?? 0) < (now[b] ?? 0)
            }
        }
        func sweep(down: Bool) {
            guard R > 1 else { return }
            for s in 1..<R {
                let k = down ? s : R - 1 - s
                var position: [Int: Double] = [:]
                for (i, item) in ranks[down ? k - 1 : k + 1].enumerated() { position[item] = Double(i) }
                var weight: [Int: Double] = [:]
                for (i, item) in ranks[k].enumerated() {
                    let neighbours = down ? items[item].up : items[item].down
                    weight[item] = neighbours.isEmpty ? Double(i) : neighbours.reduce(0) { $0 + (position[$1] ?? 0) } / Double(neighbours.count)
                }
                arrange(k, weight)
            }
        }
        for k in 0..<R { arrange(k, Dictionary(uniqueKeysWithValues: ranks[k].enumerated().map { ($1, Double($0)) })) }
        var best = ranks, bestCount = crossingCount(ranks)
        for pass in 0..<8 {
            sweep(down: pass % 2 == 0)
            let found = crossingCount(ranks)
            if found < bestCount || (pass == 0 && found == bestCount) { bestCount = found; best = ranks }
        }
        ranks = best

        // Positions across the flow. Each rank is first packed at its minimum spacing and centred.
        func gap(_ a: Item, _ b: Item) -> Double {
            let dummies = (a.dummy ? 1 : 0) + (b.dummy ? 1 : 0)
            if a.group == b.group { return dummies == 2 ? 16 : dummies == 1 ? 22 : 28 }
            return (dummies > 0 ? 10 : 24) + (a.group != nil ? M.groupPad : 0) + (b.group != nil ? M.groupPad + (H ? M.groupTitle : 0) : 0)
        }
        func separation(_ a: Item, _ b: Item) -> Double { a.cs / 2 + b.cs / 2 + gap(a, b) }
        for r in ranks {
            var c = 0.0
            for (i, item) in r.enumerated() {
                if i > 0 { c += separation(items[r[i - 1]], items[item]) }
                items[item].c = c
            }
            for item in r { items[item].c -= c / 2 }
        }
        // Then minimise the weighted sum of |offset| over every edge segment (the objective Graphviz dot uses),
        // by iteratively reweighted least squares one rank at a time. Absolute distance, unlike squared distance,
        // settles on exact alignment: a chain comes out dead straight and a branch hangs off it.
        func pull(_ a: Item, _ b: Item) -> Double { a.dummy && b.dummy ? 4 : a.dummy || b.dummy ? 0.5 : 1 }
        for pass in 0..<90 {
            let epsilon = max(0.2, 24 * pow(0.86, Double(pass)))
            for s in 0..<R {
                let r = ranks[pass % 2 == 1 ? R - 1 - s : s]
                var offset = [0.0]
                for i in r.indices.dropFirst() { offset.append(offset[i - 1] + separation(items[r[i - 1]], items[r[i]])) }
                // Pool adjacent violators: the weighted least-squares positions that keep the order and spacing.
                var blocks: [(sum: Double, weight: Double, n: Int)] = []
                for (i, ix) in r.enumerated() {
                    let item = items[ix]
                    var weight = 1e-6, sum = 1e-6 * item.c
                    for other in item.up + item.down {
                        let w = pull(item, items[other]) / max(epsilon, abs(item.c - items[other].c))
                        sum += w * items[other].c
                        weight += w
                    }
                    blocks.append(((sum / weight - offset[i]) * weight, weight, 1))
                    while blocks.count > 1 {
                        let b = blocks[blocks.count - 1], a = blocks[blocks.count - 2]
                        if a.sum / a.weight <= b.sum / b.weight { break }
                        blocks.removeLast()
                        blocks[blocks.count - 1] = (a.sum + b.sum, a.weight + b.weight, a.n + b.n)
                    }
                }
                var i = 0
                for block in blocks {
                    for _ in 0..<block.n {
                        items[r[i]].c = block.sum / block.weight + offset[i]
                        i += 1
                    }
                }
            }
        }
        // Snap to whole points, giving items that ended up within a fraction of each other the same value.
        var anchor = -Double.infinity, snapped = 0.0
        for ix in items.indices.sorted(by: { items[$0].c < items[$1].c }) {
            if items[ix].c - anchor > 0.4 { anchor = items[ix].c; snapped = items[ix].c.rounded() }
            items[ix].c = snapped
        }

        // Positions along the flow. A gap widens to fit the longest label that sits in it.
        let rankSize = ranks.map { r in r.map { items[$0].rs }.max() ?? 0 }
        var rankGap = [Double](repeating: H ? 76 : 60, count: max(0, R - 1))
        let labelSegment = chains.map { ($0.count - 2) / 2 }
        let labelWidth = diagram.edges.map { edge in edge.labels.map { measure($0, M.edgeLabelSize, true) }.max() ?? 0 }
        for ei in diagram.edges.indices where H && labelWidth[ei] > 0 {
            let k = items[chains[ei][labelSegment[ei]]].rank
            rankGap[k] = max(rankGap[k], labelWidth[ei].rounded(.up) + 44)
        }
        var along = [0.0]
        for k in 1..<max(1, R) { along.append(along[k - 1] + rankSize[k - 1] / 2 + rankGap[k - 1] + rankSize[k] / 2) }
        for ix in items.indices { items[ix].r = along[items[ix].rank] }
        for i in 0..<count {
            nodes[i].x = H ? items[i].r : items[i].c
            nodes[i].y = H ? items[i].c : items[i].r
        }

        // Ports: edges sharing a side fan out along it, ordered by where they are going.
        var portOut = [Double](repeating: 0, count: chains.count), portIn = portOut
        for i in 0..<count {
            for out in [true, false] {
                var list: [(edge: Int, other: Double)] = []
                for (ei, chain) in chains.enumerated() {
                    if out, chain[0] == i { list.append((ei, items[chain[1]].c)) }
                    if !out, chain[chain.count - 1] == i { list.append((ei, items[chain[chain.count - 2]].c)) }
                }
                guard list.count > 1 else { continue }
                list.sort { $0.other != $1.other ? $0.other < $1.other : $0.edge < $1.edge }
                let curved = diagram.nodes[i].shape == .circle || diagram.nodes[i].shape == .diamond
                let stride = min(curved ? 9 : 12, items[i].cs * (curved ? 0.34 : 0.56) / Double(list.count - 1))
                for (j, entry) in list.enumerated() {
                    let offset = (Double(j) - Double(list.count - 1) / 2) * stride
                    if out { portOut[entry.edge] = offset } else { portIn[entry.edge] = offset }
                }
            }
        }
        /// How far the outline is from the centre along the flow, `d` off-centre across it.
        func reach(_ i: Int, _ d: Double) -> Double {
            let hw = nodes[i].w / 2, hh = nodes[i].h / 2, a = abs(d)
            switch diagram.nodes[i].shape {
            case .circle: return max(0, hw * hw - d * d).squareRoot()
            case .diamond: return H ? hw * (1 - a / hh) : hh * (1 - a / hw)
            case .pill:
                if H { return hw - hh + max(0, hh * hh - d * d).squareRoot() }
                return a <= hw - hh ? hh : max(0, hh * hh - (a - hw + hh) * (a - hw + hh)).squareRoot()
            case .database: return H ? hw : hh - M.databaseRy + M.databaseRy * max(0, 1 - (d / hw) * (d / hw)).squareRoot()
            case .box: return H ? hw : hh
            }
        }
        func tenth(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        func point(_ r: Double, _ c: Double) -> FlowPoint { H ? FlowPoint(x: tenth(r), y: tenth(c)) : FlowPoint(x: tenth(c), y: tenth(r)) }

        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        func grow(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) { x0 = min(x0, ax); y0 = min(y0, ay); x1 = max(x1, bx); y1 = max(y1, by) }

        var edges: [Edge] = []
        for (ei, chain) in chains.enumerated() {
            let points = chain.enumerated().map { k, ix -> FlowPoint in
                let item = items[ix]
                if k == 0 { return point(item.r + reach(ix, portOut[ei]), item.c + portOut[ei]) }
                if k == chain.count - 1 { return point(item.r - reach(ix, portIn[ei]), item.c + portIn[ei]) }
                return point(item.r, item.c)
            }
            let a = points[labelSegment[ei]], b = points[labelSegment[ei] + 1]
            let mid = FlowPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let straight = H ? abs(a.y - b.y) < 3 : abs(a.x - b.x) < 3
            // Beside a straight edge, on top of a bent one (where a halo knocks the line out behind the text).
            let lift = M.edgeLabelSize * 0.8
            let label = !straight ? mid : H ? FlowPoint(x: mid.x, y: mid.y - lift) : FlowPoint(x: mid.x + lift, y: mid.y)
            let startsAtPoint = straight && !H
            let from = diagram.nodes[ends[ei].u].group
            edges.append(Edge(points: points, flipped: flipped[ei], label: label, labelStartsAtPoint: startsAtPoint,
                              labelWidth: labelWidth[ei], insideGroup: from != nil && from == diagram.nodes[ends[ei].v].group))
            for p in points { grow(p.x, p.y, p.x, p.y) }
            if labelWidth[ei] > 0 {
                let left = startsAtPoint ? label.x : label.x - labelWidth[ei] / 2
                grow(left, label.y - 9, left + labelWidth[ei], label.y + 9)
            }
        }
        for node in nodes { grow(node.x - node.w / 2, node.y - node.h / 2, node.x + node.w / 2, node.y + node.h / 2) }
        let groups: [FlowRect?] = diagram.groups.map { group in
            let members = group.members.compactMap { index[$0] }.map { nodes[$0] }
            guard !members.isEmpty else { return nil }
            let left = (members.map { $0.x - $0.w / 2 }.min() ?? 0) - M.groupPad, right = (members.map { $0.x + $0.w / 2 }.max() ?? 0) + M.groupPad
            let top = (members.map { $0.y - $0.h / 2 }.min() ?? 0) - M.groupPad - M.groupTitle, bottom = (members.map { $0.y + $0.h / 2 }.max() ?? 0) + M.groupPad
            grow(left, top, right, bottom)
            return FlowRect(x: left, y: top, w: right - left, h: bottom - top)
        }
        let bounds = FlowRect(x: (x0 - M.margin).rounded(.down), y: (y0 - M.margin).rounded(.down),
                              w: (x1 - x0 + 2 * M.margin).rounded(.up), h: (y1 - y0 + 2 * M.margin).rounded(.up))
        return FlowLayout(horizontal: H, nodes: nodes, edges: edges, groups: groups, bounds: bounds, crossings: bestCount)
    }
}
