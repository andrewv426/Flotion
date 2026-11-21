import Foundation
import Testing
@testable import FlotionCore

private let handshake = """
    flow right

    client: Client
    server: Server
    client -> server

    step "SYN": The client asks to open a connection.
      send client -> server: SYN
      tag client: SYN sent
      tag server: listening

    step "SYN-ACK": The server acknowledges and asks back.
      send server -> client: SYN-ACK
      tag server: SYN received

    step "ACK": The client confirms. The connection is open.
      send client -> server: ACK
      tag client, server: established
      mark client, server: good
    """

private let cache = """
    flow right
    user: Browser {shape: pill}
    api: API
    group data "Storage" {
      cache: Redis {shape: database}
      db: Postgres {shape: database}
    }
    user -> api
    api -> cache
    api -> db

    step "Request": The browser asks the API for the feed.
      send user -> api: GET /feed
    step "Cache miss": Redis has nothing under this key yet.
      focus api, cache
      send api -> cache: get feed:42
      tag cache: miss
      mark cache: warn
    step "Respond": The browser gets its feed.
      send api -> user: 200 OK
    """

private let pipeline = """
    flow down
    push: git push {shape: pill}
    build: Build
    test: Tests
    gate: Pass? {shape: diamond}
    deploy: Deploy
    fix: Fix
    push -> build -> test -> gate   # a chain declares three edges
    gate -> deploy: yes
    gate -> fix: no
    fix -> build {style: dashed}
    """

private let growth = """
    app: App
    db: Postgres {shape: database}
    app -> db
    step "One box": An app and a database.
    step "Cache": Reads got slow.
      cache: Redis {shape: database}
      app -> cache: read
    step "Queue": Slow work moved off the request path.
      queue: Jobs {shape: pill}
      worker: Worker
      app -> queue: enqueue
      queue -> worker
      worker -> db: write
      hide cache
    """

@Suite struct FlowParserTests {
    @Test func readsNodesEdgesGroupsAndSteps() {
        let (d, issues) = FlowParser.parse(cache)
        #expect(issues.isEmpty, "\(issues)")
        #expect(d.direction == .right)
        #expect(d.nodes.map(\.id) == ["user", "api", "cache", "db"])
        #expect(d.nodes.map(\.shape) == [.pill, .box, .database, .database])
        #expect(d.nodes.map(\.label) == ["Browser", "API", "Redis", "Postgres"])
        #expect(d.groups.map(\.title) == ["Storage"] && d.groups[0].members == ["cache", "db"])
        #expect(d.edges.map { "\($0.from)>\($0.to)" } == ["user>api", "api>cache", "api>db"])
        #expect(d.steps.map(\.title) == ["Request", "Cache miss", "Respond"])
        #expect(d.steps[1].caption == "Redis has nothing under this key yet.")
        #expect(d.steps[1].ops == [.focus([.node("api"), .node("cache")]), .send(edge: 1, against: false, label: "get feed:42", to: "cache"),
                                   .tag([.node("cache")], "miss"), .mark([.node("cache")], .warn)])
        #expect(d.steps[2].ops == [.send(edge: 0, against: true, label: "200 OK", to: "user")], "a reply travels against the declared edge")
    }

    @Test func chainsCommentsAndDashedEdges() {
        let (d, issues) = FlowParser.parse(pipeline)
        #expect(issues.isEmpty, "\(issues)")
        #expect(d.direction == .down)
        #expect(d.edges.count == 6)
        #expect(d.edges.last?.dashed == true && d.edges.dropLast().allSatisfy { !$0.dashed })
        #expect(d.edges[3].label == "yes")
        #expect(d.steps.isEmpty)
    }

    @Test func whereSomethingIsDeclaredIsWhenItAppears() {
        let (d, issues) = FlowParser.parse(growth)
        #expect(issues.isEmpty, "\(issues)")
        #expect(d.nodes.map(\.enter) == [-1, -1, 1, 2, 2])
        #expect(d.edges.map(\.enter) == [-1, 1, 2, 2, 2])
    }

    @Test func aLabelMayHoldColonsQuotesAndBraces() {
        let (d, issues) = FlowParser.parse("""
            a: "GET /users/{id}"
            b: Ratio 3:1
            c
            a -> b: "x -> y"
            """)
        #expect(issues.isEmpty, "\(issues)")
        #expect(d.nodes.map(\.label) == ["GET /users/{id}", "Ratio 3:1", "c"])
        #expect(d.edges[0].label == "x -> y")
    }

    @Test(arguments: [
        ("a: A\na -> sever", 2, "unknown node `sever`"),
        ("server: S\na: A\na -> sever", 3, "did you mean `server`?"),
        ("a: A\nb: B\na --> b", 3, "Edges are written `a -> b: label`"),
        ("a[Label]", 1, "Nodes are written `id: Label {shape: box}`"),
        ("a: A {shape: cylinder}", 1, "did you mean `database`?"),
        ("a: A {color: red}", 1, "nodes take `shape`, got `color`"),
        ("a: A\na: Again", 2, "already declared on line 1"),
        ("a: A\na -> a", 2, "cannot point at itself"),
        ("a: A\nb: B\na -> b\na -> b", 4, "already declared"),
        ("flow LR\na: A", 1, "did you mean `flow right`?"),
        ("a: A\nsend a -> a", 2, "only works inside a step"),
        ("a: A\nb: B\nstep \"One\"\n  send a -> b: hi", 4, "Declare `a -> b` first"),
        ("a: A\nstep \"One\"\n  mark a: green", 3, "did you mean `good`?"),
        ("a: A\nstep \"One\"\n  focus b", 3, "unknown node or group `b`"),
        ("group g \"G\" {\n  a: A", 1, "never closed"),
        ("step: Step", 1, "reserved word"),
        ("# only a comment", 1, "no nodes"),
    ] as [(String, Int, String)])
    func reportsTheLineAndTheFix(source: String, line: Int, message: String) {
        let issues = FlowParser.parse(source).issues
        #expect(issues.contains { $0.line == line && $0.message.contains(message) }, "\(issues)")
    }

    @Test func reportsEveryProblemNotJustTheFirst() {
        let issues = FlowParser.parse("a: A {shape: blob}\na -> b\nwhat is this").issues
        #expect(issues.map(\.line) == [1, 2, 3])
        #expect(FlowIssue.report(issues).hasPrefix("The diagram source has 3 problems."))
        #expect(FlowIssue.report(issues).contains("line 2: unknown node `b`"))
    }

    @Test func parsesAllFourEdgeOperatorsAndMixedChains() {
        let (d, issues) = FlowParser.parse("""
            a: A
            b: B
            c: C
            client: Client
            api: API
            db: DB
            n1: N1
            n2: N2
            n3: N3
            web-app: Web
            api-gw: Gateway

            a -> b <- c: synced {style: dashed}
            client <-> api -> db: rpc {style: solid}
            n1 -- n2 -- n3: link
            web-app<->api-gw
            """)
        #expect(issues.isEmpty, "\(issues)")
        #expect(d.edges.map { "\($0.from) \($0.kind.rawValue) \($0.to)" } == [
            "a forward b",
            "b backward c",
            "client bidirectional api",
            "api forward db",
            "n1 undirected n2",
            "n2 undirected n3",
            "web-app bidirectional api-gw",
        ])
        #expect(d.edges[0].label == "synced" && d.edges[0].dashed)
        #expect(d.edges[1].label == "synced" && d.edges[1].dashed)
        #expect(d.edges[2].label == "rpc" && !d.edges[2].dashed)
        #expect(d.edges[3].label == "rpc" && !d.edges[3].dashed)
        #expect(d.edges[4].label == "link" && d.edges[5].label == "link")
        #expect(d.edges[6].label.isEmpty && !d.edges[6].dashed)
    }

    @Test func showAndHideMatchAllFourEdgeOperators() {
        let (d, issues) = FlowParser.parse("""
            a: A
            b: B
            c: C
            d: D
            a -> b
            a <- b
            b <-> c
            c -- d
            step "Hide"
              hide a -> b, a <- b, c <-> b, d -- c
            step "Show"
              show b <- a, b -> a, b <-> c, c -- d
            """)
        #expect(issues.isEmpty, "\(issues)")
        #expect(d.steps[0].ops == [.hide([.edge(0), .edge(1), .edge(2), .edge(3)])])
        #expect(d.steps[1].ops == [.show([.edge(0), .edge(1), .edge(2), .edge(3)])])

        // `a <- b` also matches an edge originally declared as `b -> a`.
        let (rev, revIssues) = FlowParser.parse("""
            a: A
            b: B
            b -> a
            step "Hide"
              hide a <- b
            """)
        #expect(revIssues.isEmpty, "\(revIssues)")
        #expect(rev.steps[0].ops == [.hide([.edge(0)])])

        // Mismatched direction/operator or edges passed to node-only verbs fail.
        let bad = FlowParser.parse("""
            a: A
            b: B
            a -> b
            step "Bad"
              hide a <- b
              hide a -- b
              focus a <-> b
            """).issues
        #expect(bad.map(\.line) == [5, 6, 7], "\(bad)")
        #expect(bad[2].message.contains("not edges"))
    }

    @Test func sendResolvesNaturalThenSymmetricThenOppositeEdge() {
        // Both a -> b and a <- b: each send picks its natural direction.
        let (parallel, pIssues) = FlowParser.parse("""
            a: A
            b: B
            a -> b
            a <- b
            step "Both ways"
              send a -> b: req
              send b -> a: res
            """)
        #expect(pIssues.isEmpty, "\(pIssues)")
        #expect(parallel.steps[0].ops == [
            .send(edge: 0, against: false, label: "req", to: "b"),
            .send(edge: 1, against: true, label: "res", to: "a"),
        ])

        // Forward + bidirectional: forward matches natural a -> b; b -> a prefers <-> over opposite a -> b.
        let (mixed, mIssues) = FlowParser.parse("""
            a: A
            b: B
            a -> b
            a <-> b
            step "Preference"
              send a -> b: forward
              send b -> a: via-bi
            """)
        #expect(mIssues.isEmpty, "\(mIssues)")
        #expect(mixed.steps[0].ops == [
            .send(edge: 0, against: false, label: "forward", to: "b"),
            .send(edge: 1, against: true, label: "via-bi", to: "a"),
        ])

        // Single backward, bidirectional, and undirected edges all support sends in both directions.
        let (kinds, kIssues) = FlowParser.parse("""
            a: A
            b: B
            c: C
            d: D
            a <- b
            b <-> c
            c -- d
            step "Sends"
              send b -> a: natural-bwd
              send a -> b: opposite-bwd
              send c -> b: reverse-bi
              send c -> d: forward-link
              send d -> c: reverse-link
            """)
        #expect(kIssues.isEmpty, "\(kIssues)")
        #expect(kinds.steps[0].ops == [
            .send(edge: 0, against: true, label: "natural-bwd", to: "a"),
            .send(edge: 0, against: false, label: "opposite-bwd", to: "b"),
            .send(edge: 1, against: true, label: "reverse-bi", to: "b"),
            .send(edge: 2, against: false, label: "forward-link", to: "d"),
            .send(edge: 2, against: true, label: "reverse-link", to: "c"),
        ])
    }

    @Test(arguments: [
        ("a: A\nb: B\na --> b", 3, "Edges are written `a -> b: label`"),
        ("a: A\nb: B\na-->b", 3, "Edges are written `a -> b: label`"),
        ("a: A\nb: B\na ==> b", 3, "Edges are written `a -> b: label`"),
        ("a: A\nb: B\na -.-> b", 3, "Edges are written `a -> b: label`"),
        ("a: A\nb: B\na <-- b", 3, "Edges are written `a -> b: label`"),
        ("a: A\nb: B\na <--> b", 3, "Edges are written `a -> b: label`"),
        ("a: A\nb: B\na --- b", 3, "Edges are written `a -> b: label`"),
        ("a: A\na <- a", 2, "`a` cannot point at itself"),
        ("a: A\na <-> a", 2, "`a` cannot point at itself"),
        ("a: A\na -- a", 2, "`a` cannot point at itself"),
        ("a: A\nb: B\na <-> b\nb <-> a", 4, "already declared"),
        ("a: A\nb: B\na -- b\nb -- a", 4, "already declared"),
        ("a: A\nb: B\na <-> b\na -- b", 4, "already declared"),
        ("a: A\nb: B\nb -> a\na <- b", 4, "already declared"),
        ("a: A\nb: B\na <- b\nb -> a", 4, "already declared"),
        ("a: A\nb: B\na <- b\na <- b", 4, "already declared"),
        ("a: A\nb: B\na -> b\nb <- a", 4, "already declared"),
        ("a: A\nb: B\na <-> b\nstep \"S\"\n  send a <-> b: nope", 5, "write `send a -> b: label`"),
        ("a: A\nb: B\na <- b\nstep \"S\"\n  send a <- b: nope", 5, "write `send a -> b: label`"),
        ("a: A\nb: B\na -- b\nstep \"S\"\n  send a -- b: nope", 5, "write `send a -> b: label`"),
    ] as [(String, Int, String)])
    func rejectsInvalidEdgeArrowsSelfLoopsAndDuplicates(source: String, line: Int, message: String) {
        let issues = FlowParser.parse(source).issues
        #expect(issues.contains { $0.line == line && $0.message.contains(message) }, "\(issues)")
    }

    @Test func allowsOppositeDirectedEdgePairs() {
        let pair1 = FlowParser.parse("a: A\nb: B\na -> b\na <- b")
        #expect(pair1.issues.isEmpty, "\(pair1.issues)")
        #expect(pair1.diagram.edges.count == 2)

        let pair2 = FlowParser.parse("a: A\nb: B\na -> b\nb -> a")
        #expect(pair2.issues.isEmpty, "\(pair2.issues)")
        #expect(pair2.diagram.edges.count == 2)
    }
}

@Suite struct FlowStateTests {
    @Test func stateCarriesForwardAndEffectsLastOneStep() throws {
        let d = FlowParser.parse(handshake).diagram
        let states = d.states()
        #expect(states.count == 3)
        #expect(states[0].nodes.map(\.tag) == ["SYN sent", "listening"])
        #expect(states[1].nodes.map(\.tag) == ["SYN sent", "SYN received"], "a tag stays until it is changed")
        #expect(states[2].nodes.map(\.tone) == [.good, .good])
        #expect(states.map { $0.edges[0].live } == [true, true, true])
        #expect(states.map { $0.edges[0].heads } == [.to, .from, .to], "the head follows the message")
        #expect(states.map { $0.edges[0].label } == ["SYN", "SYN-ACK", "ACK"])
    }

    @Test func focusDimsTheRestForOneStep() {
        let states = FlowParser.parse(cache).diagram.states()
        #expect(states[1].nodes.map(\.dim) == [true, false, false, true])
        #expect(states[1].edges.map(\.dim) == [true, false, true])
        #expect(states[1].groups[0].dim == false, "a group stays lit while one of its members is in focus")
        #expect(states[2].nodes.allSatisfy { !$0.dim })
        #expect(states[2].nodes[2].tone == .warn, "but a mark persists")
    }

    @Test func nodesEnterAndLeave() {
        let states = FlowParser.parse(growth).diagram.states()
        #expect(states.map { $0.nodes.map(\.visible) } == [[true, true, false, false, false], [true, true, true, false, false], [true, true, false, true, true]])
        #expect(states[2].edges[1].visible == false, "an edge goes when either end is hidden")
    }

    @Test func aDiagramWithoutStepsHasOneState() {
        let states = FlowParser.parse(pipeline).diagram.states()
        #expect(states.count == 1)
        #expect(states[0].nodes.allSatisfy(\.visible) && states[0].sends.isEmpty)
    }

    @Test func edgeHeadsRestByKindOverrideOnSendAndRevert() {
        let (diagram, issues) = FlowParser.parse("""
            a: A
            b: B
            c: C
            d: D
            e: E
            a -> b <- c <-> d -- e
            step "Rest"
            step "Send"
              send b -> a: back-on-fwd
              send b -> c: fwd-on-bwd
              send d -> c: back-on-bi
              send d -> e: fwd-on-link
            step "Revert"
            """)
        #expect(issues.isEmpty, "\(issues)")
        let states = diagram.states()
        #expect(states.count == 3)
        #expect(states[0].edges.map(\.heads) == [.to, .from, .both, .none])
        #expect(states[1].edges.map(\.heads) == [.from, .to, .from, .to])
        #expect(states[2].edges.map(\.heads) == [.to, .from, .both, .none])
    }

    @Test func showAndHideToggleMatchingEdges() {
        let (diagram, issues) = FlowParser.parse("""
            a: A
            b: B
            c: C
            a -> b
            a <- b
            b <-> c
            step "Initial"
            step "Hide"
              hide a <- b, c <-> b
            step "Show"
              show b -> a, b <-> c
            """)
        #expect(issues.isEmpty, "\(issues)")
        let states = diagram.states()
        #expect(states[0].edges.map(\.visible) == [true, true, true])
        #expect(states[1].edges.map(\.visible) == [true, false, false])
        #expect(states[2].edges.map(\.visible) == [true, true, true])
    }
}

@Suite struct FlowLayoutTests {
    private func layout(_ source: String) -> (FlowDiagram, FlowLayout) {
        let d = FlowParser.parse(source).diagram
        return (d, FlowLayout.compute(d))
    }

    @Test(arguments: [handshake, cache, pipeline, growth])
    func nothingOverlapsAndNoEdgesCross(source: String) {
        let (d, l) = layout(source)
        #expect(l.crossings == 0)
        for i in d.nodes.indices {
            for j in d.nodes.indices where j > i {
                let a = l.nodes[i], b = l.nodes[j]
                let apart = abs(a.x - b.x) >= (a.w + b.w) / 2 + 20 || abs(a.y - b.y) >= (a.h + b.h) / 2 + 20
                #expect(apart, "\(d.nodes[i].id) and \(d.nodes[j].id) are too close")
            }
        }
        for node in l.nodes {
            #expect(node.x - node.w / 2 >= l.bounds.x && node.x + node.w / 2 <= l.bounds.x + l.bounds.w)
            #expect(node.y - node.h / 2 >= l.bounds.y && node.y + node.h / 2 <= l.bounds.y + l.bounds.h)
        }
    }

    @Test func aChainIsDeadStraightEvenWithALoopBesideIt() {
        let (d, l) = layout(pipeline)
        let x = Dictionary(uniqueKeysWithValues: zip(d.nodes.map(\.id), l.nodes.map(\.x)))
        #expect(x["push"] == x["build"] && x["build"] == x["test"] && x["test"] == x["gate"])
        let y = l.nodes.map(\.y)
        #expect(y[0] < y[1] && y[1] < y[2] && y[2] < y[3] && y[3] < y[4] && y[4] == y[5])
        #expect(l.edges[5].flipped, "the edge that closes the loop is laid out against its direction")
        #expect(l.edges[5].points.count == 4, "and bends around the two ranks it passes")
    }

    @Test func arrowsEndOnTheOutline() {
        let (d, l) = layout(cache)
        for (edge, path) in zip(d.edges, l.edges) {
            let from = l.nodes[d.nodeIndex(edge.from)!], to = l.nodes[d.nodeIndex(edge.to)!]
            let first = path.points.first!, last = path.points.last!
            #expect(abs(first.x - (from.x + from.w / 2)) < 0.11, "\(edge.from) -> \(edge.to) leaves the right side")
            #expect(abs(last.x - (to.x - to.w / 2)) < 0.11, "\(edge.from) -> \(edge.to) arrives on the left side")
            #expect(abs(first.y - from.y) <= from.h / 2 && abs(last.y - to.y) <= to.h / 2)
        }
        // A circle's outline curves away from a port that is off-centre.
        let (d2, l2) = layout("flow right\nhub: Hub {shape: circle}\na: A\nb: B\nhub -> a\nhub -> b")
        let hub = l2.nodes[0]
        for path in l2.edges {
            let p = path.points[0], distance = ((p.x - hub.x) * (p.x - hub.x) + (p.y - hub.y) * (p.y - hub.y)).squareRoot()
            #expect(abs(distance - hub.w / 2) < 0.2, "\(d2.nodes[0].id) port sits on the circle")
        }
    }

    @Test func aBranchSplitsEvenlyAroundItsSource() {
        let (d, l) = layout(cache)
        let y = Dictionary(uniqueKeysWithValues: zip(d.nodes.map(\.id), l.nodes.map(\.y)))
        #expect(y["user"] == y["api"])
        #expect(abs((y["cache"]! + y["db"]!) / 2 - y["api"]!) <= 1)
        let group = try! #require(l.groups[0])
        #expect(group.x < l.nodes[2].x - l.nodes[2].w / 2 && group.y < l.nodes[2].y - l.nodes[2].h / 2)
    }

    @Test func isTheSameEveryTimeAndUnaffectedBySteps() {
        let (d, l) = layout(growth)
        #expect(FlowLayout.compute(d) == l)
        // The same graph declared up front, with no steps, lays out identically: later arrivals already have their place.
        let flat = growth.split(separator: "\n").filter { !$0.contains("step ") && !$0.contains("hide ") }.joined(separator: "\n")
        let (_, l2) = layout(flat)
        #expect(l2.nodes == l.nodes && l2.bounds == l.bounds)
    }

    @Test func aTaggedNodeIsTallerAndFitsItsLongestText() {
        let (_, l) = layout(handshake)
        #expect(l.nodes.allSatisfy { $0.tagged && $0.h == 58 })
        let wide = FlowText.width("SYN received", size: 12, medium: false)
        #expect(l.nodes[1].w >= wide + 36)
        #expect(l.edges[0].labelWidth >= FlowText.width("SYN-ACK", size: 12.5, medium: true))
    }

    @Test func backwardEdgeKeepsLeftNodeEarlierInLayout() {
        let (_, right) = layout("flow right\na: Left\nb: Right\na <- b")
        #expect(right.nodes[0].x < right.nodes[1].x)
        #expect(!right.edges[0].flipped)

        let (_, down) = layout("flow down\na: Top\nb: Bottom\na <- b")
        #expect(down.nodes[0].y < down.nodes[1].y)
        #expect(!down.edges[0].flipped)
    }

    @Test func parallelForwardAndBackwardEdgesSeparatePorts() {
        let (_, l) = layout("flow right\na: Client\nb: Server\na -> b: req\na <- b: res")
        #expect(l.nodes[0].x < l.nodes[1].x)
        #expect(l.edges.count == 2)
        #expect(!l.edges[0].flipped && !l.edges[1].flipped)
        #expect(l.edges[0].points.first!.y != l.edges[1].points.first!.y, "parallel edges fan out to distinct ports")
        #expect(l.edges[0].points.last!.y != l.edges[1].points.last!.y)
    }
}

@Suite struct FlowSceneTests {
    @Test func resolvesEveryStepForThePlayer() throws {
        let scene = try FlowScene(source: handshake)
        #expect(scene.stepped && scene.steps.count == 3)
        #expect(scene.steps.map(\.title) == ["SYN", "SYN-ACK", "ACK"])
        #expect(scene.steps.map { $0.edges[0].heads } == ["hi", "lo", "hi"])
        #expect(scene.steps.map { $0.sends.map(\.forward) } == [[true], [false], [true]])
        #expect(scene.steps[1].sends[0].to == 0, "the reply lands on the client")
        #expect(scene.steps[2].nodes.map(\.tone) == ["good", "good"])
        #expect(scene.edges[0].lineHi != scene.edges[0].lineLo, "the line is cut short at whichever end carries the head")
        #expect(scene.edges[0].lineHi.hasPrefix("M") && scene.nodes[0].d.hasSuffix("Z"))
        let decoded = try JSONDecoder().decode(FlowScene.self, from: JSONEncoder().encode(scene))
        #expect(decoded == scene)
    }

    @Test func aLoopEdgePutsItsHeadAtTheNearEnd() throws {
        let scene = try FlowScene(source: pipeline)
        #expect(!scene.stepped && scene.steps.count == 1)
        #expect(scene.steps[0].edges.map(\.heads) == ["hi", "hi", "hi", "hi", "hi", "lo"])
        #expect(scene.edges.map(\.solid) == [true, true, true, true, true, false])
    }

    @Test func sizesItselfAndOnlyEverShrinks() throws {
        let scene = try FlowScene(source: handshake)
        let chrome = FlowScene.captionHeight + FlowScene.controlsHeight
        #expect(scene.displayHeight(forWidth: 2000) == scene.h + chrome)
        #expect(scene.displayHeight(forWidth: scene.w / 2) == (scene.h / 2).rounded(.up) + chrome)
        let still = try FlowScene(source: pipeline)
        #expect(still.displayHeight(forWidth: .infinity) == still.h, "no caption or controls without steps")
    }

    @Test func badSourceThrowsEveryProblemByLine() {
        #expect(throws: FlotionError.invalid("The diagram source has 1 problem. Fix and send it again.\nline 2: unknown node `b`. Declare it first: `b: Label`")) {
            try FlowScene(source: "a: A\na -> b")
        }
    }

    @Test func numbersAreShortAndExact() {
        #expect(FlowScene.n(12) == "12" && FlowScene.n(-0.04) == "0" && FlowScene.n(3.25) == "3.3" && FlowScene.n(-7.5) == "-7.5")
    }

    @Test func resolvesAllFourEdgeTypesLineVariantsAndFlippedHeads() throws {
        let source = """
            flow right
            a: A
            b: B
            c: C
            d: D
            e: E
            a -> b <- c <-> d -- e
            e <- a
            step "Rest"
            step "Send"
              send a -> b: fwd
              send b -> c: bwd
              send c -> d: bi
              send e -> d: link
              send a -> e: loop
            step "Revert"
            """
        let scene = try FlowScene(source: source)
        // Edge 4 (`e <- a`) closes the cycle from e back to a, so FlowLayout flips it: `.from` (at e) becomes `"hi"`.
        #expect(scene.steps[0].edges.map(\.heads) == ["hi", "lo", "both", "none", "hi"])
        #expect(scene.steps[1].edges.map(\.heads) == ["hi", "hi", "hi", "lo", "hi"])
        #expect(scene.steps[1].sends.map(\.forward) == [true, true, true, false, true])
        #expect(scene.steps[2].edges.map(\.heads) == ["hi", "lo", "both", "none", "hi"])

        // Each edge carries four distinct line path variants (hi, lo, both, none).
        let edge = scene.edges[0]
        #expect(Set([edge.lineHi, edge.lineLo, edge.lineBoth, edge.lineNone]).count == 4)
        let startOf: (String) -> Substring = { $0.split(separator: "C")[0] }
        let endOf: (String) -> Substring = { $0.split(separator: " ").last! }
        #expect(startOf(edge.lineHi) == startOf(edge.lineNone), "lineHi is untrimmed at start")
        #expect(endOf(edge.lineLo) == endOf(edge.lineNone), "lineLo is untrimmed at end")
        #expect(startOf(edge.lineBoth) == startOf(edge.lineLo), "lineBoth trims start like lineLo")
        #expect(endOf(edge.lineBoth) == endOf(edge.lineHi), "lineBoth trims end like lineHi")

        // Codable round-trip preserves lineBoth, lineNone, and heads.
        let encoded = try JSONEncoder().encode(scene)
        let decoded = try JSONDecoder().decode(FlowScene.self, from: encoded)
        #expect(decoded == scene)
    }
}
