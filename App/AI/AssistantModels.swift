import Foundation
import Security

enum AssistantService: String, CaseIterable, Codable, Identifiable {
    case claude, openAI, gemini, grok, cursor

    var id: String { rawValue }

    var label: String {
        switch self {
        case .claude: "Claude"
        case .openAI: "OpenAI"
        case .gemini: "Gemini"
        case .grok: "Grok"
        case .cursor: "Cursor"
        }
    }

    var keyURL: URL? {
        switch self {
        case .claude: nil
        case .openAI: URL(string: "https://platform.openai.com/api-keys")
        case .gemini: URL(string: "https://aistudio.google.com/apikey")
        case .grok: URL(string: "https://console.x.ai/")
        case .cursor: URL(string: "https://cursor.com/dashboard")
        }
    }

    var installURL: URL? {
        switch self {
        case .claude: URL(string: "https://code.claude.com/docs/en/setup")
        case .cursor: URL(string: "https://cursor.com/docs/cli/installation")
        default: nil
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
        .init(service: .openAI, alias: "gpt-5.4-mini", name: "GPT-5.4 mini"),
        .init(service: .openAI, alias: "chat-latest", name: "ChatGPT Instant"),
        .init(service: .gemini, alias: "gemini-3.1-flash-lite", name: "Gemini 3.1 Flash-Lite"),
        .init(service: .grok, alias: "grok-4.7", name: "Grok 4.7"),
        .init(service: .cursor, alias: "auto", name: "Auto"),
    ]
}

enum AssistantKeychain {
    private static func query(_ service: AssistantService) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "app.flotion.Flotion.assistant",
         kSecAttrAccount as String: service.rawValue]
    }

    static func read(_ service: AssistantService) -> String? {
        var lookup = query(service)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String?, for service: AssistantService) -> OSStatus {
        let lookup = query(service)
        guard let key else {
            let status = SecItemDelete(lookup as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        return SecItemAdd(lookup.merging(attributes) { _, data in data } as CFDictionary, nil)
    }
}
