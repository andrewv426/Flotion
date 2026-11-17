import Foundation

enum AssistantService: String, CaseIterable, Codable, Identifiable {
    case claude, openAI, gemini

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "ChatGPT"
        case .gemini: "Gemini"
        }
    }

    var cliName: String {
        switch self {
        case .claude: "Claude Code"
        case .openAI: "Codex CLI"
        case .gemini: "Gemini CLI"
        }
    }

    var installURL: URL {
        switch self {
        case .claude: URL(string: "https://code.claude.com/docs/en/setup")!
        case .openAI: URL(string: "https://developers.openai.com/codex/cli")!
        case .gemini: URL(string: "https://geminicli.com/docs/get-started/installation/")!
        }
    }

    var signInHelp: String {
        switch self {
        case .claude: "Sign in through Claude Code to use chat, inline edits, and workspace tools."
        case .openAI: "Sign in with your ChatGPT account through Codex CLI."
        case .gemini: "Choose Sign in with Google when Gemini CLI opens, then return to Flotion."
        }
    }
}

struct AssistantModel: Codable, Equatable, Identifiable {
    let service: AssistantService
    let alias: String
    let name: String

    var id: String { "\(service.rawValue):\(alias)" }
    var label: String { "\(service.label) · \(name)" }

    static let claudeDefault = Self(service: .claude, alias: "", name: "Account default")
    static let suggested: [Self] = [
        claudeDefault,
        .init(service: .claude, alias: "fable", name: "Fable"),
        .init(service: .claude, alias: "opus", name: "Opus"),
        .init(service: .claude, alias: "sonnet", name: "Sonnet"),
        .init(service: .claude, alias: "haiku", name: "Haiku"),
        .init(service: .openAI, alias: "", name: "Codex default"),
        .init(service: .gemini, alias: "", name: "Auto"),
    ]
}
