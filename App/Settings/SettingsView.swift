import FlotionAI
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        Form {
            if let ai = model.ai {
                Section("Assistant") {
                    LabeledContent("Claude") { StatusLabel(status: ai.status) }
                    switch ai.status {
                    case .notInstalled:
                        Text("The assistant runs on your Claude subscription through Claude Code, which is not installed on this Mac.")
                            .font(.callout).foregroundStyle(.secondary)
                        Link("How to install Claude Code", destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                    case .signedOut:
                        Text("Sign-in happens in Claude Code, in a Terminal window, through Anthropic's own page. Flotion never sees your password or token.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Sign in to Claude…") { ai.openSignIn() }
                    default:
                        EmptyView()
                    }
                    Button("Check again") { Task { await ai.refreshStatus() } }

                    Picker("Model", selection: Binding(get: { ai.modelChoice }, set: { ai.modelChoice = $0 })) {
                        ForEach(AIController.modelChoices, id: \.alias) { choice in
                            Text(choice.label).tag(choice.alias)
                        }
                    }
                    Text("Requests use your own Claude plan and count against its limits. No API key is used.")
                        .font(.callout).foregroundStyle(.secondary)
                }

                Section("Other AI apps") {
                    Text("Any MCP client can read and edit this workspace. To connect Claude Code, run:")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Text(ai.externalConnectCommand)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ai.externalConnectCommand, forType: .string)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task { await model.ai?.refreshStatus() }
    }
}

private struct StatusLabel: View {
    let status: AIProviderStatus?

    var body: some View {
        switch status {
        case .ready(let plan):
            Label(plan.map { "Signed in (\($0.capitalized) plan)" } ?? "Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .signedOut:
            Label("Signed out", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
        case .notInstalled:
            Label("Claude Code not found", systemImage: "xmark.circle").foregroundStyle(.secondary)
        case nil:
            Text("Checking…").foregroundStyle(.secondary)
        }
    }
}
