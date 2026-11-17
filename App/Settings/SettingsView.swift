import AppKit
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
                    Text("All providers can read and edit workspace pages from Assistant chat.")
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
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.ai?.refreshStatus() }
        }
    }
}

private struct ProviderSettings: View {
    let ai: AIController
    let service: AssistantService
    @State private var modelID = ""
    @State private var modelError = false

    var body: some View {
        Section(service.label) {
            Text(service.signInHelp)
                .font(.callout).foregroundStyle(.secondary)
            LabeledContent("Connection") {
                Text(connectionLabel).foregroundStyle(.secondary)
            }
            HStack {
                if ai.statuses[service] == .notInstalled {
                    Link("Install \(service.cliName)", destination: service.installURL)
                } else if ai.statuses[service] != nil {
                    Button("Sign in to \(service.label)…") { ai.openSignIn(service) }
                }
                Button("Check again") { Task { await ai.refreshStatus() } }
            }

            if service != .claude, case .ready = ai.statuses[service] {
                if ai.loadingModelCatalogs.contains(service) {
                    ProgressView("Loading available models…").controlSize(.small)
                } else if ai.modelCatalogs[service] == nil {
                    Text("Couldn’t load the model list. Check again or update \(service.cliName).")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            ForEach(ai.allModels.filter { $0.service == service }) { model in
                let isVisible = ai.visibleModels.contains { $0.id == model.id }
                let isLast = isVisible && ai.visibleModels.count == 1
                HStack {
                    Toggle(model.name, isOn: Binding(get: { ai.visibleModels.contains { $0.id == model.id } },
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
            plan.map { "Signed in (\($0.capitalized) plan)" } ?? "Signed in"
        case .signedOut: "Signed out"
        case .notInstalled: "\(service.cliName) not found"
        case nil: "Checking…"
        }
    }

    private func addModel() {
        modelError = !ai.addModel(alias: modelID, service: service)
        if !modelError { modelID = "" }
    }
}
