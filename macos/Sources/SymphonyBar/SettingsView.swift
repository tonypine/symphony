import AppKit
import SwiftUI
import SymphonyBarCore

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Symphony") {
                    PathField(title: "symphony.yml", path: $model.settings.configPath, choosesDirectories: false)
                    LabeledContent("Stop timeout") {
                        HStack {
                            TextField("Seconds", value: $model.settings.stopTimeoutSeconds, format: .number)
                                .labelsHidden()
                                .frame(width: 60)
                            Stepper(
                                "Seconds",
                                value: $model.settings.stopTimeoutSeconds,
                                in: AppSettings.stopTimeoutRange
                            )
                            .labelsHidden()
                            Text("seconds")
                        }
                    }
                    LabeledContent("Restart timeout") {
                        HStack {
                            TextField("Minutes", value: $model.settings.restartTimeoutMinutes, format: .number)
                                .labelsHidden()
                                .frame(width: 60)
                            Stepper(
                                "Minutes",
                                value: $model.settings.restartTimeoutMinutes,
                                in: AppSettings.restartTimeoutRange
                            )
                            .labelsHidden()
                            Text("minutes")
                        }
                    }
                    .help("How long Restart Symphony waits for agent runs before it also offers Restart Now Anyway.")
                    Toggle("Start Symphony when the app opens", isOn: $model.settings.startOnLaunch)
                    Toggle(LoginItem.toggleTitle, isOn: $model.launchAtLogin)
                    if let note = model.loginItemNote {
                        HStack {
                            Text(note).foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Login Items") { MainAppLoginItem.openSystemSettings() }
                        }
                    }
                }

                Section {
                    Toggle("Development mode", isOn: $model.settings.developmentMode)
                    if model.settings.developmentMode {
                        PathField(title: "Checkout folder", path: $model.settings.checkoutPath, choosesDirectories: true)
                        TextField(
                            "Command prefix",
                            text: $model.settings.commandPrefix,
                            prompt: Text("Optional, e.g. mise exec --")
                        )
                    }
                } footer: {
                    Text(
                        model.settings.developmentMode
                            ? "Runs bin/symphony from the checkout through a login shell, for working on Symphony itself."
                            : "Runs the Symphony built into this app. Turn on to run bin/symphony from a checkout."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Section {
                    LabeledContent("Max concurrent agents") {
                        HStack {
                            Text("\(model.maxConcurrentAgents)")
                                .monospacedDigit()
                            Stepper(
                                "Max concurrent agents",
                                value: $model.maxConcurrentAgents,
                                in: MaxConcurrentAgents.range
                            )
                            .labelsHidden()
                        }
                    }
                    .disabled(!model.canEditMaxConcurrentAgents)
                } header: {
                    Text("Agents (saved in symphony.yml)")
                } footer: {
                    Text(
                        "Each epic under way keeps one of these agents for its sub-tickets; the rest take "
                            + "other work. More agents use the Linear and GitHub API budgets faster. 2–3 is a "
                            + "safe range on a personal Linear key. Applies within a minute, no restart needed."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Section {
                    ForEach(RunProfilesConfig.scopes, id: \.self) { kind in
                        RunProfileRow(
                            kind: kind,
                            profile: $model.runProfiles[kind],
                            inherited: kind == nil ? model.commandProfile : RunProfile()
                        )
                    }
                    .disabled(!model.canEditRunProfiles)
                    if model.commandProfile != RunProfile() {
                        Text(
                            "agent.command passes --model or --effort. Saving any model or effort moves them "
                                + "to the Default row, and any in pre_push_review.command or auto_review.command "
                                + "into that section, so runs keep the same model and effort."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Models (saved in symphony.yml)")
                } footer: {
                    Text(
                        "Each kind of run uses its own model and effort, or the Default row when set to default. "
                            + "Higher effort and bigger models use the shared 5-hour usage limit faster: keep "
                            + "Opus and high effort for breakdown and hard implementation, and use Sonnet or "
                            + "Haiku with low effort for landing and CI fixes. Claude runtime only. Applies to the "
                            + "next run, no restart needed."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Section {
                    SecureField(SecretSettings.linearAPIKeyName, text: $model.linearAPIKey, prompt: Text("lin_api_…"))
                    ForEach($model.extraRows) { $row in
                        HStack {
                            TextField("Name", text: $row.name, prompt: Text("NAME"))
                                .labelsHidden()
                            SecureField("Value", text: $row.value, prompt: Text("Value"))
                                .labelsHidden()
                            Button {
                                model.removeRow(id: row.id)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("Remove this variable")
                        }
                    }
                    Button("Add Variable") { model.addRow() }
                } header: {
                    Text("Environment (stored in the Keychain)")
                }

                Section {
                    SecureField(
                        SecretSettings.openRouterAPIKeyName,
                        text: $model.openRouterAPIKey,
                        prompt: Text("sk-or-…")
                    )
                    HStack {
                        Button("Test connection") { model.testOpenRouter() }
                            .disabled(model.isTestingOpenRouter || model.openRouterAPIKey.isEmpty)
                        if model.isTestingOpenRouter {
                            ProgressView().controlSize(.small)
                        }
                    }
                    switch model.openRouterResult {
                    case .success(let key):
                        Text(key.summary).foregroundStyle(.green)
                    case .failure(let failure):
                        Text(failure.message).foregroundStyle(.red)
                    case nil:
                        EmptyView()
                    }
                    switch model.openRouterModels {
                    case .success(let summary):
                        LabeledContent("Models", value: summary)
                    case .failure(let failure):
                        LabeledContent("Models") { Text(failure.message).foregroundStyle(.red) }
                    case nil:
                        EmptyView()
                    }
                } header: {
                    Text("OpenRouter")
                } footer: {
                    Text(
                        "Stored in the Keychain and passed to Symphony as \(SecretSettings.openRouterAPIKeyName) "
                            + "for run profiles with provider: openrouter. Leave blank to turn OpenRouter off."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            // A grouped Form is scroll-backed with no height of its own (ideal height 0), so without this it collapses.
            .frame(minHeight: 460, idealHeight: 640, maxHeight: 900)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(model.issues.map(\.message), id: \.self) { message in
                    Text(message).foregroundStyle(.red)
                }
                if let keychainError = model.keychainError {
                    Text(keychainError).foregroundStyle(.red)
                }
                if let configFileError = model.configFileError {
                    Text(configFileError).foregroundStyle(.red)
                }
                if let loginItemError = model.loginItemError {
                    Text(loginItemError).foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)

            HStack {
                Spacer()
                Button("Cancel", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if model.save() { close() }
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 600)
    }
}

/// Model and effort pickers for one kind of run, or the Default row for a nil kind. `inherited` holds what
/// runs use when a field is set to default, from the flags in `agent.command`.
private struct RunProfileRow: View {
    let kind: RunKind?
    @Binding var profile: RunProfile
    let inherited: RunProfile

    var body: some View {
        LabeledContent(kind?.title ?? "Default") {
            HStack {
                picker("Model", $profile.model, RunProfilesConfig.models, inherited: inherited.model)
                    .frame(width: 190)
                picker("Effort", $profile.effort, RunProfilesConfig.efforts, inherited: inherited.effort)
                    .frame(width: 150)
            }
        }
    }

    private func picker(
        _ title: String,
        _ selection: Binding<String?>,
        _ choices: [RunProfileChoice],
        inherited: String?
    ) -> some View {
        Picker(title, selection: selection) {
            Text(RunProfilesConfig.defaultTitle(choices, inherited: inherited)).tag(String?.none)
            ForEach(RunProfilesConfig.choices(choices, including: selection.wrappedValue)) { choice in
                Text(choice.title).tag(Optional(choice.id))
            }
        }
        .labelsHidden()
    }
}

/// A path text field with a Choose… button that opens a panel.
private struct PathField: View {
    let title: String
    @Binding var path: String
    let choosesDirectories: Bool

    var body: some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: $path, prompt: Text("/path/to/…"))
                    .labelsHidden()
                Button("Choose…", action: choose)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = choosesDirectories
        panel.canChooseFiles = !choosesDirectories
        panel.allowsMultipleSelection = false
        if !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path)
        }
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}
