import Foundation

/// A parsed Flow diagram: what exists and what each step changes. It holds no geometry;
/// `FlowLayout` decides where things go and `FlowScene` what the player draws.
public struct FlowDiagram: Sendable, Equatable {
    public enum Direction: String, Sendable { case right, down }

    public var direction: Direction = .right
    public var nodes: [FlowNode] = []
    public var edges: [FlowEdge] = []
    public var groups: [FlowGroup] = []
    public var steps: [FlowStep] = []

    public init() {}

    public func nodeIndex(_ id: String) -> Int? { nodes.firstIndex { $0.id == id } }
}

public enum FlowShape: String, Sendable, CaseIterable { case box, pill, circle, diamond, database }

/// The only colours a diagram can use. Each is a role, so every diagram draws from one palette.
public enum FlowTone: String, Sendable, CaseIterable, Codable { case accent, good, warn, bad, muted }

public struct FlowNode: Sendable, Equatable {
    public var id: String
    public var label: String
    public var shape: FlowShape
    public var group: String?
    /// The step at which the node first appears; -1 when it is there from the start.
    public var enter: Int
    public var line: Int
    /// Every label and status tag the node shows in any step. The layout sizes the node for the widest.
    public var labels: [String]
    public var tags: [String] = []
}

public enum FlowEdgeKind: String, Sendable, Equatable, CaseIterable { case forward, backward, bidirectional, undirected }

public enum FlowEdgeHeads: String, Sendable, Equatable, Codable { case to, from, both, none }

extension FlowEdgeKind {
    var restingHeads: FlowEdgeHeads {
        switch self {
        case .forward: .to
        case .backward: .from
        case .bidirectional: .both
        case .undirected: .none
        }
    }

    var operatorSymbol: String {
        switch self {
        case .forward: "->"
        case .backward: "<-"
        case .bidirectional: "<->"
        case .undirected: "--"
        }
    }

    var isSymmetric: Bool { self == .bidirectional || self == .undirected }
}

public struct FlowEdge: Sendable, Equatable {
    public var from: String
    public var to: String
    public var kind: FlowEdgeKind = .forward
    public var label: String
    public var dashed: Bool
    public var enter: Int
    public var line: Int
    /// The declared label plus every label a `send` puts on this edge.
    public var labels: [String]
}

extension FlowEdge {
    func connects(_ a: String, _ b: String) -> Bool {
        (from == a && to == b) || (from == b && to == a)
    }

    /// Whether this is a directed edge (`->` or `<-`) whose effective direction is `src -> dst`.
    func points(from src: String, to dst: String) -> Bool {
        switch kind {
        case .forward: from == src && to == dst
        case .backward: to == src && from == dst
        case .bidirectional, .undirected: false
        }
    }
}

public struct FlowGroup: Sendable, Equatable {
    public var id: String
    public var title: String
    public var members: [String] = []
    public var line: Int
}

public struct FlowStep: Sendable, Equatable {
    public var title: String
    public var caption: String
    public var ops: [FlowOp] = []
    public var line: Int
}

public enum FlowTarget: Sendable, Equatable {
    case node(String)
    case group(String)
    case edge(Int)
}

/// What one line inside a step does. State verbs carry forward to later steps; `send` and `focus` last one step.
public enum FlowOp: Sendable, Equatable {
    case show([FlowTarget])
    case hide([FlowTarget])
    case focus([FlowTarget])
    case set(node: String, label: String)
    case tag([FlowTarget], String)
    /// `nil` clears the tone.
    case mark([FlowTarget], FlowTone?)
    /// `against` is true when the message travels from `edge.to` to `edge.from`.
    case send(edge: Int, against: Bool, label: String?, to: String)
}

/// A problem in Flow source, phrased so the author (usually a model) can fix that line.
public struct FlowIssue: Sendable, Equatable {
    public var line: Int
    public var message: String

    public init(line: Int, message: String) { self.line = line; self.message = message }
}

/// The picture at one step, after every earlier step has been applied.
public struct FlowState: Sendable, Equatable {
    public struct Node: Sendable, Equatable {
        public var visible: Bool
        public var dim: Bool
        public var label: String
        public var tag: String
        public var tone: FlowTone?
    }
    public struct Edge: Sendable, Equatable {
        public var visible: Bool
        public var dim: Bool
        /// A message is travelling this edge in this step.
        public var live: Bool
        public var label: String
        /// Arrowhead placement for this step: resting heads by edge kind, or temporarily pointing with an active `send`.
        public var heads: FlowEdgeHeads
    }
    public struct Group: Sendable, Equatable {
        public var visible: Bool
        public var dim: Bool
    }
    public struct Send: Sendable, Equatable {
        public var edge: Int
        public var against: Bool
        public var to: String
    }

    public var nodes: [Node]
    public var edges: [Edge]
    public var groups: [Group]
    public var sends: [Send]
}

public extension FlowDiagram {
    /// One state per step, or a single state for a diagram without steps.
    func states() -> [FlowState] {
        var hiddenNodes = Set<String>(), hiddenEdges = Set<Int>()
        var label: [String: String] = [:], tag: [String: String] = [:], tone: [String: FlowTone] = [:]
        let members = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.members) })
        func ids(_ targets: [FlowTarget]) -> [String] {
            targets.flatMap { target -> [String] in
                switch target {
                case .node(let id): [id]
                case .group(let id): members[id] ?? []
                case .edge: []
                }
            }
        }

        var out: [FlowState] = []
        for i in 0..<max(1, steps.count) {
            var focus: Set<String>?
            var sends: [(edge: Int, against: Bool, label: String?, to: String)] = []
            for op in i < steps.count ? steps[i].ops : [] {
                switch op {
                case .show(let targets), .hide(let targets):
                    var hiding = false
                    if case .hide = op { hiding = true }
                    for target in targets {
                        if case .edge(let index) = target {
                            if hiding { hiddenEdges.insert(index) } else { hiddenEdges.remove(index) }
                        }
                    }
                    for id in ids(targets) { if hiding { hiddenNodes.insert(id) } else { hiddenNodes.remove(id) } }
                case .focus(let targets): focus = (focus ?? []).union(ids(targets))
                case .set(let node, let text): label[node] = text
                case .tag(let targets, let text): for id in ids(targets) { tag[id] = text.isEmpty ? nil : text }
                case .mark(let targets, let value): for id in ids(targets) { tone[id] = value }
                case .send(let edge, let against, let text, let to): sends.append((edge, against, text, to))
                }
            }

            let nodeStates = nodes.map { node in
                FlowState.Node(visible: node.enter <= i && !hiddenNodes.contains(node.id),
                               dim: focus.map { !$0.contains(node.id) } ?? false,
                               label: label[node.id] ?? node.label, tag: tag[node.id] ?? "", tone: tone[node.id])
            }
            let visible = Dictionary(uniqueKeysWithValues: zip(nodes.map(\.id), nodeStates.map(\.visible)))
            let edgeStates = edges.enumerated().map { index, edge in
                let send = sends.last { $0.edge == index }
                let shown = edge.enter <= i && !hiddenEdges.contains(index) && visible[edge.from] == true && visible[edge.to] == true
                let focused = focus.map { $0.contains(edge.from) && $0.contains(edge.to) } ?? true
                let heads: FlowEdgeHeads = if let send { send.against ? .from : .to } else { edge.kind.restingHeads }
                return FlowState.Edge(visible: shown, dim: send == nil && !focused, live: send != nil,
                                      label: send?.label ?? edge.label, heads: heads)
            }
            let groupStates = groups.map { group in
                FlowState.Group(visible: group.members.contains { visible[$0] == true },
                                dim: focus.map { focused in !group.members.contains { focused.contains($0) } } ?? false)
            }
            out.append(FlowState(nodes: nodeStates, edges: edgeStates, groups: groupStates,
                                 sends: sends.filter { edgeStates[$0.edge].visible }.map { .init(edge: $0.edge, against: $0.against, to: $0.to) }))
        }
        return out
    }
}
