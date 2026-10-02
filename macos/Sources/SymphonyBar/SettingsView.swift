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
                    PathField(title: "Checkout folder", path: $model.settings.checkoutPath, choosesDirectories: true)
                    PathField(title: "symphony.yml", path: $model.settings.configPath, choosesDirectories: false)
                    TextField(
                        "Command prefix",
                        text: $model.settings.commandPrefix,
                        prompt: Text("Optional, e.g. mise exec --")
                    )
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
                        "More agents use the Linear and GitHub API budgets faster. 2–3 is a safe range on a "
                            + "personal Linear key. Applies within a minute, no restart needed."
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
