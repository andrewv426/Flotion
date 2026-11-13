import Foundation

/// What a provider reports while it answers one request.
public enum AIEvent: Sendable, Equatable {
    case started(sessionID: String, model: String)
    case text(String)
    case toolStarted(id: String, name: String)
    case toolFinished(id: String, isError: Bool)
    case retrying(reason: String)
    case finished(AIResult)
}

public enum AIFailure: Sendable, Equatable {
    case notInstalled
    case notSignedIn
    case rateLimited
    case other
}

public struct AIResult: Sendable, Equatable {
    public var text: String
    public var sessionID: String?
    public var failure: AIFailure?
    public var message: String?

    public init(text: String, sessionID: String? = nil, failure: AIFailure? = nil, message: String? = nil) {
        self.text = text; self.sessionID = sessionID; self.failure = failure; self.message = message
    }

    public static func failed(_ failure: AIFailure, _ message: String) -> AIResult {
        AIResult(text: "", failure: failure, message: message)
    }
}

public enum AIProviderStatus: Sendable, Equatable {
    case notInstalled
    case signedOut
    case ready(plan: String?)
}

/// Which tools a request may use. The in-app AI only ever gets Flotion's own MCP server.
public enum ToolAccess: Sendable, Equatable {
    case none
    case flotion(server: URL, database: URL, actor: String)
}

public struct AIRequest: Sendable, Equatable {
    public var prompt: String
    public var systemPrompt: String
    public var model: String?
    public var effort: String?
    public var tools: ToolAccess
    /// Continue an earlier conversation; nil starts a fresh one.
    public var resumeSessionID: String?
    /// False for one-shot requests (inline edits) that should leave no session behind.
    public var keepSession: Bool

    public init(prompt: String, systemPrompt: String, model: String? = nil, effort: String? = nil,
                tools: ToolAccess = .none, resumeSessionID: String? = nil, keepSession: Bool = true) {
        self.prompt = prompt; self.systemPrompt = systemPrompt; self.model = model; self.effort = effort
        self.tools = tools; self.resumeSessionID = resumeSessionID; self.keepSession = keepSession
    }
}

/// A source of model responses. Claude Code is the only implementation in v1; other
/// subscription-login CLIs can be added as further conformers without touching the UI.
public protocol AIProvider: Sendable {
    func status() async -> AIProviderStatus
    /// Runs one request. The stream always ends with `.finished`; cancel by dropping it.
    func run(_ request: AIRequest) -> AsyncStream<AIEvent>
    /// Starts a process for an upcoming request of the same shape so it answers sooner.
    func prewarm(_ request: AIRequest)
}

public extension AIProvider {
    func prewarm(_ request: AIRequest) {}
}

/// A scripted provider for tests and the in-app self-test: replays events with no network.
public final class FakeProvider: AIProvider, @unchecked Sendable {
    public typealias Script = @Sendable (AIRequest) async -> [AIEvent]

    private let lock = NSLock()
    private var _requests: [AIRequest] = []
    private let script: Script
    private let providerStatus: AIProviderStatus

    public init(status: AIProviderStatus = .ready(plan: "test"), script: @escaping Script) {
        providerStatus = status
        self.script = script
    }

    public var requests: [AIRequest] {
        lock.lock(); defer { lock.unlock() }
        return _requests
    }

    public func status() async -> AIProviderStatus { providerStatus }

    public func run(_ request: AIRequest) -> AsyncStream<AIEvent> {
        lock.lock(); _requests.append(request); lock.unlock()
        return AsyncStream { continuation in
            let task = Task {
                for event in await script(request) {
                    if Task.isCancelled { break }
                    continuation.yield(event)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
