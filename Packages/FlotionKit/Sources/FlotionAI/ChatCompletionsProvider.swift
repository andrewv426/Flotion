import Foundation

public final class ChatCompletionsProvider: AIProvider {
    public enum Service: String, Sendable {
        case openAI = "OpenAI"
        case gemini = "Gemini"
        case grok = "Grok"

        var endpoint: URL {
            switch self {
            case .openAI: URL(string: "https://api.openai.com/v1/chat/completions")!
            case .gemini: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions")!
            case .grok: URL(string: "https://api.x.ai/v1/chat/completions")!
            }
        }
    }

    private let service: Service
    private let apiKey: String?

    public init(service: Service, apiKey: String?) {
        self.service = service
        self.apiKey = apiKey
    }

    public func status() async -> AIProviderStatus {
        apiKey == nil ? .signedOut : .ready(plan: nil)
    }

    struct Body: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let stream = true
    }

    func urlRequest(_ request: AIRequest) throws -> URLRequest? {
        guard let apiKey, let model = request.model else { return nil }
        var messages = [Body.Message(role: "system", content: request.systemPrompt)]
        for turn in request.history {
            messages.append(.init(role: "user", content: turn.user))
            messages.append(.init(role: "assistant", content: turn.assistant))
        }
        messages.append(.init(role: "user", content: request.prompt))
        var http = URLRequest(url: service.endpoint, timeoutInterval: 120)
        http.httpMethod = "POST"
        http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        http.httpBody = try JSONEncoder().encode(Body(model: model, messages: messages))
        return http
    }

    public func run(_ request: AIRequest) -> AsyncStream<AIEvent> {
        AsyncStream { continuation in
            let task = Task {
                let result = await complete(request, continuation: continuation, session: Self.session)
                if !Task.isCancelled { continuation.yield(.finished(result)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)

    private func complete(_ request: AIRequest, continuation: AsyncStream<AIEvent>.Continuation, session: URLSession) async -> AIResult {
        guard apiKey != nil else { return .failed(.notSignedIn, "Add your \(service.rawValue) API key.") }
        do {
            guard let http = try urlRequest(request) else { return .failed(.other, "Select a model to continue.") }
            let (bytes, response) = try await session.bytes(for: http)
            guard let response = response as? HTTPURLResponse else {
                return .failed(.other, "\(service.rawValue) returned an invalid response.")
            }
            guard (200..<300).contains(response.statusCode) else {
                bytes.task.cancel()
                return failure(status: response.statusCode, model: request.model)
            }
            continuation.yield(.started(sessionID: "", model: request.model ?? ""))
            var stream = CompletionStream()
            for try await line in bytes.lines {
                try Task.checkCancellation()
                if let text = stream.consume(line) { continuation.yield(.text(text)) }
                if stream.ended { break }
            }
            let result = stream.result()
            if result.failure != nil { bytes.task.cancel() }
            return result
        } catch {
            return .failed(.other, "Could not complete the \(service.rawValue) request. Try again.")
        }
    }

    private func failure(status: Int, model: String?) -> AIResult {
        switch status {
        case 401, 403: .failed(.notSignedIn, "\(service.rawValue) denied access. Check your API key and model permissions.")
        case 429: .failed(.rateLimited, "\(service.rawValue) rate limit reached.")
        case 404: .failed(.other, "\(service.rawValue) could not find model \(model ?? ""). Check the model ID in Settings.")
        default: .failed(.other, "\(service.rawValue) rejected the request (HTTP \(status)). Check model access and try a shorter prompt.")
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct CompletionStream {
    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta?
            let finish_reason: String?
        }
        struct Failure: Decodable { let message: String? }
        let choices: [Choice]?
        let error: Failure?
    }

    private var text = ""
    private var reason: String?
    private var hasError = false
    private(set) var ended = false

    mutating func consume(_ line: String) -> String? {
        guard !ended, line.hasPrefix("data:") else { return nil }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" {
            ended = true
            return nil
        }
        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(payload.utf8)) else { return nil }
        if chunk.error != nil {
            hasError = true
            ended = true
        }
        guard let choice = chunk.choices?.first else { return nil }
        if let finish = choice.finish_reason { reason = finish }
        guard let content = choice.delta?.content, !content.isEmpty else { return nil }
        text += content
        return content
    }

    func result() -> AIResult {
        if reason == "length" { return .failed(.other, "The model reached its response limit.") }
        if reason == "content_filter" { return .failed(.other, "The provider filtered the response.") }
        if hasError || (!ended && reason == nil) { return .failed(.other, "The provider interrupted the response.") }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .failed(.other, "The model returned no text.") }
        return AIResult(text: text)
    }
}
