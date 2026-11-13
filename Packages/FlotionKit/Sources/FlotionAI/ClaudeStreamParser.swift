import Foundation

/// Turns Claude Code's `--output-format stream-json` lines into `AIEvent`s.
/// One parser per request; feed it each line as it arrives.
public struct ClaudeStreamParser {
    private var text = ""
    private var sessionID: String?
    private var sawDeltas = false
    private var announcedTools = Set<String>()
    private var authFailed = false
    private var lastRetryReason: String?
    public private(set) var isFinished = false

    public init() {}

    public mutating func parse(_ line: Data) -> [AIEvent] {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = event["type"] as? String else { return [] }
        switch type {
        case "system":
            return system(event)
        case "stream_event":
            return streamEvent(event["event"] as? [String: Any] ?? [:])
        case "assistant":
            return assistant(event)
        case "user":
            return toolResults(event)
        case "result":
            return [result(event)]
        default:
            return []
        }
    }

    private mutating func system(_ event: [String: Any]) -> [AIEvent] {
        switch event["subtype"] as? String {
        case "init":
            sessionID = event["session_id"] as? String
            return [.started(sessionID: sessionID ?? "", model: event["model"] as? String ?? "")]
        case "api_retry":
            let reason = event["error"] as? String ?? "unknown"
            lastRetryReason = reason
            if reason == "authentication_failed" { authFailed = true }
            return [.retrying(reason: reason)]
        default:
            return []
        }
    }

    private mutating func streamEvent(_ inner: [String: Any]) -> [AIEvent] {
        switch inner["type"] as? String {
        case "content_block_delta":
            guard let delta = inner["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
                  let piece = delta["text"] as? String, !piece.isEmpty else { return [] }
            sawDeltas = true
            text += piece
            return [.text(piece)]
        case "content_block_start":
            guard let block = inner["content_block"] as? [String: Any], block["type"] as? String == "tool_use",
                  let id = block["id"] as? String else { return [] }
            return announce(id: id, name: block["name"] as? String ?? "tool")
        default:
            return []
        }
    }

    /// A complete assistant message. With partial messages on, its text has already been
    /// streamed; without them (older CLI, or the flag ignored) this is the only copy.
    private mutating func assistant(_ event: [String: Any]) -> [AIEvent] {
        if event["error"] as? String == "authentication_failed" { authFailed = true }
        guard let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return [] }
        var out: [AIEvent] = []
        for block in content {
            switch block["type"] as? String {
            case "text":
                if !sawDeltas, !authFailed, let piece = block["text"] as? String, !piece.isEmpty {
                    if !text.isEmpty { text += "\n\n"; out.append(.text("\n\n")) }
                    text += piece
                    out.append(.text(piece))
                }
            case "tool_use":
                if let id = block["id"] as? String { out += announce(id: id, name: block["name"] as? String ?? "tool") }
            default:
                break
            }
        }
        sawDeltas = false
        return out
    }

    private mutating func announce(id: String, name: String) -> [AIEvent] {
        guard announcedTools.insert(id).inserted else { return [] }
        return [.toolStarted(id: id, name: Self.displayName(name))]
    }

    private func toolResults(_ event: [String: Any]) -> [AIEvent] {
        guard let message = event["message"] as? [String: Any], let content = message["content"] as? [[String: Any]] else { return [] }
        return content.compactMap { block in
            guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else { return nil }
            return .toolFinished(id: id, isError: block["is_error"] as? Bool ?? false)
        }
    }

    private mutating func result(_ event: [String: Any]) -> AIEvent {
        isFinished = true
        let session = event["session_id"] as? String ?? sessionID
        let resultText = event["result"] as? String ?? ""
        guard event["is_error"] as? Bool == true else {
            return .finished(AIResult(text: text.isEmpty ? resultText : text, sessionID: session))
        }
        let lowered = resultText.lowercased()
        let failure: AIFailure
        if authFailed || lowered.contains("authenticate") || lowered.contains("/login") || lowered.contains("not logged in") {
            failure = .notSignedIn
        } else if lastRetryReason == "rate_limit" || lowered.contains("rate limit") || lowered.contains("usage limit") {
            failure = .rateLimited
        } else {
            failure = .other
        }
        return .finished(AIResult(text: text, sessionID: session, failure: failure, message: resultText.isEmpty ? "The request failed." : resultText))
    }

    /// `mcp__flotion__get_page` → `get_page`.
    static func displayName(_ name: String) -> String {
        name.hasPrefix("mcp__flotion__") ? String(name.dropFirst("mcp__flotion__".count)) : name
    }
}
