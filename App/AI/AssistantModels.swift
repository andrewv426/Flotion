import Foundation

enum AssistantService: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude, openAI, antigravity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "ChatGPT"
        case .antigravity: "Antigravity"
        }
    }

    var cliName: String {
        switch self {
        case .claude: "Claude Code"
        case .openAI: "Codex CLI"
        case .antigravity: "Antigravity CLI"
        }
    }

    var installURL: URL {
        switch self {
        case .claude: URL(string: "https://code.claude.com/docs/en/setup")!
        case .openAI: URL(string: "https://developers.openai.com/codex/cli")!
        case .antigravity: URL(string: "https://antigravity.google/docs/install/")!
        }
    }

    var signInHelp: String {
        switch self {
        case .claude: "Sign in through Claude Code to use chat, inline edits, and workspace tools."
        case .openAI: "Sign in with your ChatGPT account through Codex CLI."
        case .antigravity: "Sign in with Google through Antigravity CLI to use your available models."
        }
    }
}

struct AssistantModel: Codable, Equatable, Identifiable, Sendable {
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
        .init(service: .antigravity, alias: "", name: "Account default"),
    ]
}

extension AssistantModel {
    private enum CodingKeys: String, CodingKey { case service, alias, name }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let service = try values.decode(String.self, forKey: .service)
        if service == "gemini" {
            self.service = .antigravity
            alias = ""
            name = "Account default"
        } else {
            self.service = try values.decode(AssistantService.self, forKey: .service)
            alias = try values.decode(String.self, forKey: .alias)
            name = try values.decode(String.self, forKey: .name)
        }
    }
}
