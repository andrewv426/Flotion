import Foundation

/// Everything the player needs to draw and animate one diagram, already resolved: outlines as SVG paths,
/// arrows cut to the node edges, and the full picture at every step. The player decides nothing; it only
/// switches between these states. Encoded as JSON into the diagram's document.
public struct FlowScene: Codable, Sendable, Equatable {
    public struct Node: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        /// The outline, centred on the origin.
        public var d: String
        /// How far the text sits below centre (a database's lid pushes it down).
        public var sink: Double
    }
    public struct Edge: Codable, Sendable, Equatable {
        /// The line trimmed for each arrowhead placement: far end, near end, both ends, or neither.
        public var lineHi: String
        public var lineLo: String
        public var lineBoth: String
        public var lineNone: String
        public var headHi: String
        public var headLo: String
        public var lx: Double
        public var ly: Double
        public var anchor: String
        public var solid: Bool
        public var inGroup: Bool
    }
    public struct Group: Codable, Sendable, Equatable {
        public var x: Double
        public var y: Double
        /// Zero for a group with no members, which draws nothing.
        public var w: Double
        public var h: Double
        public var title: String
    }
    public struct NodeState: Codable, Sendable, Equatable {
        public var on: Bool
        public var dim: Bool
        public var label: String
        public var tag: String
        public var tone: String?
    }
    public struct EdgeState: Codable, Sendable, Equatable {
        public var on: Bool
        public var dim: Bool
        public var live: Bool
        public var label: String
        /// Arrowhead placement along the laid-out path: `"hi"`, `"lo"`, `"both"`, or `"none"`.
        public var heads: String
    }
    public struct GroupState: Codable, Sendable, Equatable {
        public var on: Bool
        public var dim: Bool
    }
    public struct Send: Codable, Sendable, Equatable {
        public var edge: Int
        /// The message travels with the flow (from the line's start to its end).
        public var forward: Bool
        /// Index of the receiving node, which pulses when the message lands.
        public var to: Int
    }
    public struct Step: Codable, Sendable, Equatable {
        public var title: String
        public var caption: String
        public var nodes: [NodeState]
        public var edges: [EdgeState]
        public var groups: [GroupState]
        public var sends: [Send]
    }

    /// The drawing's bounds in points; also its SVG view box.
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double
    /// False for a diagram without steps: it shows one picture and no caption or controls.
    public var stepped: Bool
    public var nodes: [Node]
    public var edges: [Edge]
    public var groups: [Group]
    public var steps: [Step]

    /// Space under the drawing for the step title and caption, and for the step controls.
    public static let captionHeight = 66.0
    public static let controlsHeight = 34.0

    /// The height the diagram needs in a column `width` points wide. The drawing is never enlarged,
    /// only scaled down to fit, so text stays at its designed size wherever there is room.
    public func displayHeight(forWidth width: Double) -> Double {
        let scale = w > 0 ? min(1, max(0.1, width / w)) : 1
        return (h * scale).rounded(.up) + (stepped ? Self.captionHeight + Self.controlsHeight : 0)
    }

    /// Parses and lays out Flow source. Throws `FlotionError.invalid` listing every problem by line.
    public init(source: String) throws {
        let (diagram, issues) = FlowParser.parse(source)
        guard issues.isEmpty else { throw FlotionError.invalid(FlowIssue.report(issues)) }
        self.init(diagram: diagram)
    }

    public init(diagram: FlowDiagram, layout: FlowLayout? = nil) {
        let layout = layout ?? FlowLayout.compute(diagram)
        let H = layout.horizontal
        x = layout.bounds.x; y = layout.bounds.y; w = layout.bounds.w; h = layout.bounds.h
        stepped = !diagram.steps.isEmpty
        nodes = zip(diagram.nodes, layout.nodes).map { node, box in
            Node(x: box.x, y: box.y, d: Self.outline(node.shape, w: box.w, h: box.h),
                 sink: node.shape == .database ? FlowMetrics.databaseRy / 2 : 0)
        }
        edges = zip(diagram.edges, layout.edges).map { edge, path in
            Edge(lineHi: Self.line(path.points, horizontal: H, trimStart: false, trimEnd: true),
                 lineLo: Self.line(path.points, horizontal: H, trimStart: true, trimEnd: false),
                 lineBoth: Self.line(path.points, horizontal: H, trimStart: true, trimEnd: true),
                 lineNone: Self.line(path.points, horizontal: H, trimStart: false, trimEnd: false),
                 headHi: Self.head(path.points, horizontal: H, atEnd: true), headLo: Self.head(path.points, horizontal: H, atEnd: false),
                 lx: path.label.x, ly: path.label.y, anchor: path.labelStartsAtPoint ? "start" : "middle",
                 solid: !edge.dashed, inGroup: path.insideGroup)
        }
        groups = zip(diagram.groups, layout.groups).map { group, box in
            Group(x: box?.x ?? 0, y: box?.y ?? 0, w: box?.w ?? 0, h: box?.h ?? 0, title: group.title)
        }
        let index = Dictionary(uniqueKeysWithValues: diagram.nodes.enumerated().map { ($1.id, $0) })
        steps = diagram.states().enumerated().map { i, state in
            Step(title: i < diagram.steps.count ? diagram.steps[i].title : "",
                 caption: i < diagram.steps.count ? diagram.steps[i].caption : "",
                 nodes: state.nodes.map { NodeState(on: $0.visible, dim: $0.dim, label: $0.label, tag: $0.tag, tone: $0.tone?.rawValue) },
                 edges: zip(state.edges, layout.edges).map {
                     EdgeState(on: $0.visible, dim: $0.dim, live: $0.live, label: $0.label,
                               heads: Self.resolvedHeads($0.heads, flipped: $1.flipped))
                 },
                 groups: state.groups.map { GroupState(on: $0.visible, dim: $0.dim) },
                 sends: state.sends.map { Send(edge: $0.edge, forward: $0.against == layout.edges[$0.edge].flipped, to: index[$0.to] ?? 0) })
        }
    }

    private static func resolvedHeads(_ heads: FlowEdgeHeads, flipped: Bool) -> String {
        switch heads {
        case .to: flipped ? "lo" : "hi"
        case .from: flipped ? "hi" : "lo"
        case .both: "both"
        case .none: "none"
        }
    }

    // MARK: Paths

    /// A coordinate to one decimal place, without a trailing `.0`.
    static func n(_ value: Double) -> String {
        let r = (value * 10).rounded() / 10
        if r == 0 { return "0" }
        return r == r.rounded() ? String(Int(r)) : String(r)
    }

    /// The edge as a run of smooth curves through its waypoints. Each end carrying an arrowhead stops short of it.
    static func line(_ points: [FlowPoint], horizontal: Bool, trimStart: Bool, trimEnd: Bool) -> String {
        var p = points
        let cut = FlowMetrics.tipGap + FlowMetrics.headLength - 1.5
        if trimEnd {
            if horizontal { p[p.count - 1].x -= cut } else { p[p.count - 1].y -= cut }
        }
        if trimStart {
            if horizontal { p[0].x += cut } else { p[0].y += cut }
        }
        var d = "M\(n(p[0].x)),\(n(p[0].y))"
        for (a, b) in zip(p, p.dropFirst()) {
            if horizontal {
                let mx = n((a.x + b.x) / 2)
                d += "C\(mx),\(n(a.y)) \(mx),\(n(b.y)) \(n(b.x)),\(n(b.y))"
            } else {
                let my = n((a.y + b.y) / 2)
                d += "C\(n(a.x)),\(my) \(n(b.x)),\(my) \(n(b.x)),\(n(b.y))"
            }
        }
        return d
    }

    /// A small solid triangle whose tip stops just short of the node outline.
    static func head(_ points: [FlowPoint], horizontal: Bool, atEnd: Bool) -> String {
        let q = atEnd ? points[points.count - 1] : points[0]
        let s: Double = atEnd ? 1 : -1, half = FlowMetrics.headHalf
        if horizontal {
            let tip = q.x - s * FlowMetrics.tipGap, base = tip - s * FlowMetrics.headLength
            return "M\(n(tip)),\(n(q.y))L\(n(base)),\(n(q.y - half))L\(n(base)),\(n(q.y + half))Z"
        }
        let tip = q.y - s * FlowMetrics.tipGap, base = tip - s * FlowMetrics.headLength
        return "M\(n(q.x)),\(n(tip))L\(n(q.x - half)),\(n(base))L\(n(q.x + half)),\(n(base))Z"
    }

    static func outline(_ shape: FlowShape, w: Double, h: Double) -> String {
        let x = -w / 2, y = -h / 2
        func roundRect(_ r: Double) -> String {
            "M\(n(x + r)),\(n(y))H\(n(x + w - r))A\(n(r)),\(n(r)) 0 0 1 \(n(x + w)),\(n(y + r))V\(n(y + h - r))"
                + "A\(n(r)),\(n(r)) 0 0 1 \(n(x + w - r)),\(n(y + h))H\(n(x + r))A\(n(r)),\(n(r)) 0 0 1 \(n(x)),\(n(y + h - r))"
                + "V\(n(y + r))A\(n(r)),\(n(r)) 0 0 1 \(n(x + r)),\(n(y))Z"
        }
        switch shape {
        case .box: return roundRect(8)
        case .pill: return roundRect(h / 2)
        case .circle:
            let r = n(w / 2)
            return "M\(n(x)),0A\(r),\(r) 0 1 1 \(n(w / 2)),0A\(r),\(r) 0 1 1 \(n(x)),0Z"
        case .diamond:
            // Each corner is rounded by cutting it short on both sides and curving through the point.
            let corners = [(0.0, y), (w / 2, 0.0), (0.0, h / 2), (x, 0.0)], radius = 6.0
            var d = ""
            for (i, p) in corners.enumerated() {
                func toward(_ q: (Double, Double)) -> String {
                    let dx = q.0 - p.0, dy = q.1 - p.1, length = (dx * dx + dy * dy).squareRoot()
                    return "\(n(p.0 + dx / length * radius)),\(n(p.1 + dy / length * radius))"
                }
                d += (i == 0 ? "M" : "L") + toward(corners[(i + 3) % 4]) + "Q\(n(p.0)),\(n(p.1)) " + toward(corners[(i + 1) % 4])
            }
            return d + "Z"
        case .database:
            let ry = FlowMetrics.databaseRy, rx = n(w / 2)
            return "M\(n(x)),\(n(y + ry))A\(rx),\(n(ry)) 0 0 1 \(n(x + w)),\(n(y + ry))V\(n(y + h - ry))A\(rx),\(n(ry)) 0 0 1 \(n(x)),\(n(y + h - ry))Z"
                + "M\(n(x)),\(n(y + ry))A\(rx),\(n(ry)) 0 0 0 \(n(x + w)),\(n(y + ry))"
        }
    }
}

public extension FlowIssue {
    /// Every problem, one per line, in a form a model can act on in its next call.
    static func report(_ issues: [FlowIssue]) -> String {
        let count = issues.count == 1 ? "1 problem" : "\(issues.count) problems"
        return "The diagram source has \(count). Fix and send it again.\n" + issues.map { "line \($0.line): \($0.message)" }.joined(separator: "\n")
    }
}
