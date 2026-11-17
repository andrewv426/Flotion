import FlotionAI
import SwiftUI

struct SettingsView: View {
    let model: AppModel
    @State private var service: AssistantService

    init(model: AppModel) {
        self.model = model
        _service = State(initialValue: model.ai?.selectedModel.service ?? .claude)
    }

    var body: some View {
        Form {
            if let ai = model.ai {
                Section("Assistant models") {
                    Text("Choose which models appear in the Assistant picker. The selected provider receives recent chat turns and the open page when you send a message.")
                        .font(.callout).foregroundStyle(.secondary)
                    Picker("Provider", selection: $service) {
                        ForEach(AssistantService.allCases) { item in Text(item.label).tag(item) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                ProviderSettings(ai: ai, service: service)
                    .id(service)
                    .disabled(ai.chat.isRunning)

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
        .frame(width: 560, height: 580)
        .task { await model.ai?.refreshStatus() }
    }
}

private struct ProviderSettings: View {
    let ai: AIController
    let service: AssistantService
    @State private var key = ""
    @State private var modelID = ""
    @State private var keyError: String?
    @State private var modelError = false

    var body: some View {
        Section(service.label) {
            Text(service == .claude ? "Chat, inline edits, and workspace tools through Claude Code."
                 : (service == .cursor ? "Chat and inline edits through the Cursor CLI in Ask mode." : "Chat and inline edits through the provider’s API."))
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("Connection") {
                Text(connectionLabel).foregroundStyle(.secondary)
            }
            if service == .claude {
                if ai.statuses[service] == .signedOut {
                    Button("Sign in to Claude…") { ai.openSignIn() }
                }
            } else {
                HStack {
                    SecureField(ai.hasAPIKey(service) ? "Replacement API key" : "API key", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if ai.hasAPIKey(service) {
                        Button("Remove key") { keyError = ai.saveAPIKey(nil, for: service) }
                    }
                }
                if let keyError { Text(keyError).font(.callout).foregroundStyle(.red) }
                if let url = service.keyURL { Link("Get a \(service.label) API key", destination: url) }
            }
            if service.installURL != nil {
                HStack {
                    if ai.statuses[service] == .notInstalled, let url = service.installURL {
                        Link("Installation guide", destination: url)
                    }
                    Button("Check again") { Task { await ai.refreshStatus() } }
                }
            }

            ForEach(ai.allModels.filter { $0.service == service }) { model in
                let isLast = ai.enabledIDs.contains(model.id) && ai.enabledIDs.count == 1
                HStack {
                    Toggle(model.name, isOn: Binding(get: { ai.enabledIDs.contains(model.id) },
                                                     set: { ai.setEnabled($0, for: model) }))
                        .disabled(isLast)
                        .help(isLast ? "Enable another model before hiding this one." : "Show in the Assistant model picker.")
                    Spacer()
                    if ai.customModels.contains(model) {
                        Button("Remove") { ai.removeModel(model) }
                            .disabled(isLast)
                            .accessibilityLabel("Remove \(model.name)")
                    }
                }
            }
            HStack {
                TextField("Custom model ID", text: $modelID)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addModel)
                Button("Add model", action: addModel)
                    .disabled(modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if modelError {
                Text("Enter a new model ID using letters, numbers, or . _ : / -")
                    .font(.callout).foregroundStyle(.red)
            }
        }
    }

    private var connectionLabel: String {
        switch ai.statuses[service] {
        case .ready(let plan):
            service == .claude ? plan.map { "Signed in (\($0.capitalized) plan)" } ?? "Signed in" : "API key saved"
        case .signedOut: service == .claude ? "Signed out" : "API key required"
        case .notInstalled: service == .claude ? "Claude Code not found" : "Cursor CLI not found"
        case nil: "Checking…"
        }
    }

    private func saveKey() {
        keyError = ai.saveAPIKey(key, for: service)
        if keyError == nil { key = "" }
    }

    private func addModel() {
        modelError = !ai.addModel(alias: modelID, service: service)
        if !modelError { modelID = "" }
    }
}
