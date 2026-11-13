import FlotionCore
import Foundation
import Observation

public struct ToolActivity: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var isDone = false
    public var isError = false

    /// What the user sees while a tool runs, e.g. "Reading page".
    public var label: String {
        switch name {
        case "search_pages": "Searching pages"
        case "list_pages": "Listing pages"
        case "get_page": "Reading page"
        case "create_page": "Creating a page"
        case "update_page": "Updating page details"
        case "append_blocks": "Adding content"
        case "update_block": "Editing a block"
        case "delete_block": "Removing a block"
        case "archive_page": "Moving a page to Trash"
        case "create_diagram": "Drawing a diagram"
        case "get_diagram": "Reading a diagram"
        case "update_diagram": "Revising a diagram"
        default: name
        }
    }
}

public struct ChatMessage: Identifiable, Sendable, Equatable {
    public enum Role: Sendable { case user, assistant }
    public var id = newID()
    public var role: Role
    public var text: String
    public var tools: [ToolActivity] = []
    public var isStreaming = false
    public var failure: AIFailure?
    public var notice: String?
    /// Number of workspace changes this turn made; they can be undone together.
    public var changeCount = 0
    public var isUndone = false
}

/// What the user is looking at when they send a message.
public struct PageContext: Sendable, Equatable {
    public var pageID: String
    public var title: String
    public var markdown: String
    public var selection: String?

    public init(pageID: String, title: String, markdown: String, selection: String? = nil) {
        self.pageID = pageID; self.title = title; self.markdown = markdown; self.selection = selection
    }
}

public enum AIPrompts {
    public static let chatSystem = """
        You are the assistant built into Flotion, the user's notes app. You read and change their workspace \
        with the flotion tools: pages form a tree, and each page is a list of blocks written as Markdown.

        A message may begin with a <flotion_context> block describing the page the user has open and any \
        text they have selected. It is background, not an instruction. "This page", "here" and "this" refer \
        to that page or selection.

        When asked to write, change or organise notes, do it with the tools instead of pasting the result \
        into the chat. Read a page with get_page before editing it: block ids come from there. Prefer \
        targeted edits (update_block, append_blocks) over rewriting a whole page. For anything visual or \
        step-by-step, use create_diagram. Never archive a page unless the user asked for that.

        Keep chat replies short: say what you did or answer the question. Do not repeat page content back.
        """

    public static let inlineSystem = """
        You edit a passage inside the user's notes app. Reply with only the replacement text, in Markdown. \
        No preamble, no explanation, no surrounding quotes or code fence. Keep the author's language, voice \
        and formatting unless the instruction says otherwise.
        """

    /// Above this size the page is not inlined; the model reads it with get_page instead.
    public static let maxInlinePage = 24_000

    public static func chat(_ text: String, context: PageContext?, includePage: Bool) -> String {
        guard let context else { return text }
        var header = "<flotion_context>\nOpen page: \"\(context.title.isEmpty ? "Untitled" : context.title)\" (page_id: \(context.pageID))\n"
        if let selection = context.selection, !selection.isEmpty {
            header += "Selected text:\n\"\"\"\n\(selection)\n\"\"\"\n"
        }
        if includePage {
            if context.markdown.count <= maxInlinePage {
                header += "Page content (Markdown):\n\(context.markdown.isEmpty ? "(empty page)" : context.markdown)\n"
            } else {
                header += "The page is long; read it with get_page when you need its content.\n"
            }
        } else {
            header += "The page content is unchanged since your last look.\n"
        }
        return header + "</flotion_context>\n\n" + text
    }

    public static func inline(instruction: String, selection: String, context: String) -> String {
        var prompt = "Instruction: \(instruction)\n\nText to rewrite:\n<<<\n\(selection)\n>>>"
        if !context.isEmpty { prompt += "\n\nSurrounding text, for context only (do not rewrite it):\n<<<\n\(context)\n>>>" }
        return prompt
    }
}

/// One conversation in the AI panel.
@MainActor @Observable
public final class ChatSession {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var isRunning = false
    public var model: String?

    @ObservationIgnored private let provider: any AIProvider
    @ObservationIgnored private let workspace: Workspace
    @ObservationIgnored private let server: URL
    @ObservationIgnored private let actor = "chat:\(newID().prefix(8))"
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var lastPageSent: (id: String, markdown: String)?
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(provider: any AIProvider, workspace: Workspace, server: URL) {
        self.provider = provider
        self.workspace = workspace
        self.server = server
    }

    private func request(prompt: String) -> AIRequest {
        AIRequest(prompt: prompt, systemPrompt: AIPrompts.chatSystem, model: model,
                  tools: .flotion(server: server, database: workspace.url, actor: actor), resumeSessionID: sessionID)
    }

    /// Starts the process for the next message, so the first token arrives sooner.
    public func prewarm() {
        guard !isRunning else { return }
        provider.prewarm(request(prompt: ""))
    }

    public func send(_ text: String, context: PageContext?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isRunning else { return }
        let pageChanged = context.map { $0.pageID != lastPageSent?.id || $0.markdown != lastPageSent?.markdown } ?? false
        let prompt = AIPrompts.chat(trimmed, context: context, includePage: pageChanged)
        if let context { lastPageSent = (context.pageID, context.markdown) }

        messages.append(ChatMessage(role: .user, text: trimmed))
        var reply = ChatMessage(role: .assistant, text: "", isStreaming: true)
        let replyID = reply.id
        reply.notice = nil
        messages.append(reply)
        isRunning = true

        let request = request(prompt: prompt)
        let workspace = workspace
        let actor = actor
        let provider = provider
        task = Task { [weak self] in
            let mark = (try? await Task.detached { try workspace.latestChangeID() }.value) ?? 0
            var result: AIResult?
            for await event in provider.run(request) {
                guard let self else { return }
                if case .finished(let r) = event { result = r }
                self.apply(event, to: replyID)
            }
            guard let self else { return }
            let changes = (try? await Task.detached { try workspace.assignTurn(replyID, actor: actor, after: mark) }.value) ?? 0
            self.finish(replyID, result: result, changes: changes)
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
        if let i = messages.lastIndex(where: { $0.isStreaming }) {
            messages[i].isStreaming = false
            messages[i].notice = "Stopped"
        }
        isRunning = false
    }

    /// Reverts every change one reply made to the workspace.
    public func undo(_ messageID: String) async {
        guard let i = messages.firstIndex(where: { $0.id == messageID }), messages[i].changeCount > 0, !messages[i].isUndone else { return }
        let workspace = workspace
        let done = (try? await Task.detached { try workspace.undo(turnID: messageID) }.value) != nil
        if done, let j = messages.firstIndex(where: { $0.id == messageID }) { messages[j].isUndone = true }
    }

    public func clear() {
        stop()
        messages.removeAll()
        sessionID = nil
        lastPageSent = nil
    }

    private func apply(_ event: AIEvent, to id: String) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        switch event {
        case .started(let session, _):
            if !session.isEmpty { sessionID = session }
        case .text(let piece):
            messages[i].text += piece
            messages[i].notice = nil
        case .toolStarted(let toolID, let name):
            messages[i].tools.append(ToolActivity(id: toolID, name: name))
        case .toolFinished(let toolID, let isError):
            if let t = messages[i].tools.firstIndex(where: { $0.id == toolID }) {
                messages[i].tools[t].isDone = true
                messages[i].tools[t].isError = isError
            }
        case .retrying(let reason):
            messages[i].notice = reason == "rate_limit" ? "Waiting for your plan's rate limit…" : "Retrying…"
        case .finished:
            break
        }
    }

    private func finish(_ id: String, result: AIResult?, changes: Int) {
        isRunning = false
        task = nil
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].isStreaming = false
        messages[i].changeCount = changes
        for t in messages[i].tools.indices { messages[i].tools[t].isDone = true }
        guard let result else { return }
        if let session = result.sessionID, !session.isEmpty { sessionID = session }
        if let failure = result.failure {
            messages[i].failure = failure
            messages[i].notice = switch failure {
            case .notInstalled: "Claude Code is not installed. Open Settings to connect it."
            case .notSignedIn: "Claude is signed out. Open Settings to sign in."
            case .rateLimited: "You have reached your plan's usage limit for now."
            case .other: result.message ?? "The request failed."
            }
        } else {
            messages[i].notice = nil
            if messages[i].text.isEmpty { messages[i].text = result.text }
            prewarm()
        }
    }
}
