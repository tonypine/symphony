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
                    Picker("Update mode", selection: $model.settings.updateMode) {
                        ForEach(UpdateMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    if model.settings.updateMode == .atTime {
                        DatePicker(
                            "Time",
                            selection: Binding(
                                get: { model.settings.updateTime.date(on: Date(), calendar: .current) },
                                set: { model.settings.updateTime = TimeOfDay(date: $0, calendar: .current) }
                            ),
                            displayedComponents: .hourAndMinute
                        )
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    Text(model.settings.updateMode.explanation)
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
                    TokenLimitRow(toggleTitle: "Limit tokens per day", fieldTitle: "Tokens per day", field: $model.dailyTokenLimit)
                        .disabled(!model.canEditTokenLimits)
                    TokenLimitRow(
                        toggleTitle: "Limit tokens per ticket",
                        fieldTitle: "Tokens per ticket",
                        field: $model.issueTokenLimit
                    )
                    .disabled(!model.canEditTokenLimits)
                    if model.isCheckingTokenLimits {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Checking the token limits with symphony check…").foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.tokenLimitsError {
                        Text(error).foregroundStyle(.red)
                    }
                    ForEach(TokenUsage.lines(model.budget, now: Date(), timeZone: .current), id: \.self) { line in
                        Text(line).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Agents (saved in symphony.yml)")
                } footer: {
                    Text(
                        "Each epic under way keeps one of these agents for its sub-tickets; the rest take "
                            + "other work. Merges and QA runs don't count here: up to 2 more run on top. More "
                            + "agents use the Linear and GitHub API budgets faster. 2–3 is a safe range on a "
                            + "personal Linear key. The daily token cap pauses new runs once today's tokens (UTC) "
                            + "reach it; the per-ticket cap stops a ticket that goes over it. Applies within a "
                            + "minute, no restart needed."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Section {
                    Picker("Scope", selection: $model.runProfilesScope) {
                        Text("All repositories").tag(RunProfilesScope.global)
                        ForEach(model.repositoryKeys, id: \.self) { key in
                            Text(key).tag(RunProfilesScope.repository(key))
                        }
                    }
                    .disabled(!model.canEditRunProfiles || model.repositoryKeys.isEmpty)
                    ForEach(RunProfilesConfig.scopes, id: \.self) { kind in
                        RunProfileRow(
                            kind: kind,
                            profile: $model.runProfiles[model.runProfilesScope][kind],
                            inherited: model.inheritedProfile(kind),
                            inheritedSource: model.runProfilesScope == .global && kind == nil ? "from command" : "inherited",
                            providerSource: model.runProfilesScope == .global && kind == nil ? "default" : "inherited",
                            canReset: model.runProfilesScope != .global,
                            openRouterModels: model.openRouterAPIKey.isEmpty ? nil : model.openRouterModelList,
                            hasOpenRouterKey: !model.openRouterAPIKey.isEmpty,
                            retryOpenRouterModels: model.loadOpenRouterModels,
                            isPickingModel: Binding(
                                get: { model.openRouterPickerRow == kind?.rawValue ?? "default" },
                                set: { model.openRouterPickerRow = $0 ? kind?.rawValue ?? "default" : nil }
                            ),
                            modelQuery: $model.openRouterQuery
                        )
                    }
                    .disabled(!model.canEditRunProfiles)
                    if let error = model.configCheckError {
                        Text(error).foregroundStyle(.red)
                    }
                    if model.commandProfile != RunProfile() {
                        Text(
                            "agent.command passes --model or --effort. Saving any model or effort moves them "
                                + "to the Default row, and any in pre_push_review.command or auto_review.command "
                                + "(or that section's model and effort) to the Pre-push review or QA row, so runs "
                                + "keep the same model and effort."
                        )
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Models (saved in symphony.yml)")
                } footer: {
                    Text(
                        "Each kind of run uses its own provider, model and effort, or the Default row where it "
                            + "sets none. A repository's rows override All repositories for issues routed to it; "
                            + "grey values are inherited. Higher effort and bigger models use the shared 5-hour "
                            + "usage limit faster: keep Opus and high effort for breakdown and hard "
                            + "implementation, and use Sonnet or Haiku with low effort for landing and CI fixes. "
                            + "OpenRouter models must support tools. Claude runtime only. Save checks "
                            + "symphony.yml with symphony check first; changes apply to the next run."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Section {
                    if model.isLoadingSecrets {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(StatusMenu.keychainWaitingLine).foregroundStyle(.secondary)
                        }
                    }
                    // Off until the read fills them in, so nothing typed is overwritten.
                    SecureField(SecretSettings.linearAPIKeyName, text: $model.linearAPIKey, prompt: Text("lin_api_…"))
                        .disabled(model.isLoadingSecrets)
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
                        .disabled(model.isLoadingSecrets)
                } header: {
                    Text("Environment (stored in a file only you can read)")
                }

                Section {
                    SecureField(
                        SecretSettings.openRouterAPIKeyName,
                        text: $model.openRouterAPIKey,
                        prompt: Text("sk-or-…")
                    )
                    .disabled(model.isLoadingSecrets)
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
                        "Stored with your other secrets and passed to Symphony as \(SecretSettings.openRouterAPIKeyName) "
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
                if let secretsError = model.secretsError {
                    Text(secretsError).foregroundStyle(.red)
                }
                if let configFileError = model.configFileError {
                    Text(configFileError).foregroundStyle(.red)
                }
                if model.configCheckError != nil {
                    Text("symphony check rejected the models; see Models.").foregroundStyle(.red)
                }
                if model.tokenLimitsError != nil {
                    Text("symphony check rejected the token limits; see Agents.").foregroundStyle(.red)
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
                if model.isSaving {
                    ProgressView().controlSize(.small)
                    Text("Checking symphony.yml…").foregroundStyle(.secondary)
                }
                Button("Save") {
                    model.save(onSaved: close)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSave)
            }
            .padding(20)
        }
        .frame(width: SettingsView.width)
    }

    static let width: CGFloat = 780
}

/// Provider, model and effort pickers for one kind of run, or the Default row for a nil kind. `inherited` holds
/// what a field set to default falls back to, shown greyed out with `inheritedSource`, such as "inherited".
private struct RunProfileRow: View {
    let kind: RunKind?
    @Binding var profile: RunProfile
    let inherited: RunProfile
    let inheritedSource: String
    let providerSource: String
    /// Whether the row offers Reset to inherited, for a repository's rows.
    let canReset: Bool
    /// OpenRouter's models, or nil when no OpenRouter key is entered or the list hasn't loaded yet.
    let openRouterModels: Result<[OpenRouterModel], OpenRouterFailure>?
    let hasOpenRouterKey: Bool
    let retryOpenRouterModels: () -> Void
    @Binding var isPickingModel: Bool
    @Binding var modelQuery: String

    private var provider: String? { profile.provider ?? inherited.provider }
    private var isOpenRouter: Bool { provider == RunProfilesConfig.openRouter }

    private var effortNote: String? {
        guard isOpenRouter, case .success(let models)? = openRouterModels else { return nil }
        return OpenRouterModel.effortNote(for: profile.model ?? inherited.model, in: models)
    }

    var body: some View {
        LabeledContent(kind?.title ?? "Default") {
            HStack {
                picker("Provider", providerSelection, RunProfilesConfig.providers, inherited: inherited.provider, source: providerSource)
                    .frame(width: 150)
                Group {
                    if isOpenRouter {
                        OpenRouterModelField(
                            selection: $profile.model,
                            inheritedTitle: inherited.model.map { $0 + ", " + inheritedSource } ?? "default",
                            models: openRouterModels,
                            hasKey: hasOpenRouterKey,
                            retry: retryOpenRouterModels,
                            isPicking: $isPickingModel,
                            query: $modelQuery
                        )
                    } else {
                        picker("Model", $profile.model, RunProfilesConfig.models, inherited: inherited.model)
                    }
                }
                .frame(width: 210)
                // The tooltip sits on a wrapper, as a disabled control shows none of its own.
                HStack {
                    picker("Effort", $profile.effort, RunProfilesConfig.efforts, inherited: inherited.effort)
                        .disabled(effortNote != nil)
                }
                .frame(width: 130)
                .help(effortNote ?? "Effort for this kind of run")
                if canReset {
                    Button {
                        profile = RunProfile()
                    } label: {
                        Image(systemName: "arrow.uturn.backward.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(profile == RunProfile())
                    .help("Reset to inherited")
                    .accessibilityLabel("Reset to inherited")
                }
            }
        }
    }

    /// Changing the provider drops the row's own model, which names a model of the other provider.
    private var providerSelection: Binding<String?> {
        Binding(
            get: { profile.provider },
            set: { provider in
                guard provider != profile.provider else { return }
                profile.provider = provider
                profile.model = nil
            }
        )
    }

    private func picker(
        _ title: String,
        _ selection: Binding<String?>,
        _ choices: [RunProfileChoice],
        inherited: String?,
        source: String? = nil
    ) -> some View {
        Picker(title, selection: selection) {
            Text(RunProfilesConfig.defaultTitle(choices, inherited: inherited, source: source ?? inheritedSource)).tag(String?.none)
            ForEach(RunProfilesConfig.choices(choices, including: selection.wrappedValue)) { choice in
                Text(choice.title).tag(Optional(choice.id))
            }
        }
        .labelsHidden()
        .opacity(selection.wrappedValue == nil ? 0.55 : 1)
    }
}

/// A button showing the chosen OpenRouter model that opens a searchable list of the models that support tools.
/// Without an OpenRouter key it shows a disabled hint instead, and while the list loads, a progress note.
private struct OpenRouterModelField: View {
    @Binding var selection: String?
    let inheritedTitle: String
    let models: Result<[OpenRouterModel], OpenRouterFailure>?
    let hasKey: Bool
    let retry: () -> Void
    @Binding var isPicking: Bool
    @Binding var query: String

    var body: some View {
        switch models {
        case nil where !hasKey:
            Text("Add an OpenRouter key below first")
                .foregroundStyle(.secondary)
                .help("Enter an OpenRouter API key in the OpenRouter section to choose OpenRouter models.")
        case nil:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading models…").foregroundStyle(.secondary)
            }
        case .failure(let failure)?:
            HStack {
                Text(failure.message)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .help(failure.message)
                Button("Retry", action: retry)
                    .buttonStyle(.borderless)
            }
        case .success(let models)?:
            Button {
                query = ""
                isPicking = true
            } label: {
                HStack {
                    Text(selection.map { id in models.first { $0.id == id }?.name ?? id } ?? inheritedTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(selection == nil ? 0.55 : 1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
            }
            .help(selection ?? "Choose an OpenRouter model that supports tools")
            .popover(isPresented: $isPicking, arrowEdge: .bottom) {
                picker(models)
            }
        }
    }

    private func picker(_ models: [OpenRouterModel]) -> some View {
        let matches = OpenRouterModel.toolModels(models, matching: query)
        return VStack(alignment: .leading, spacing: 8) {
            TextField("Search models that support tools", text: $query)
                .textFieldStyle(.roundedBorder)
            List {
                Button(inheritedTitle) { choose(nil) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                ForEach(matches, id: \.id) { model in
                    Button {
                        choose(model.id)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(model.name)
                            Text(model.id).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(minHeight: 260)
            if matches.isEmpty {
                Text("No OpenRouter model that supports tools matches.").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 360, height: 360)
    }

    private func choose(_ id: String?) {
        selection = id
        isPicking = false
    }
}

/// A switch for a token cap and, while it's on, the number of tokens with a hint such as "1,000,000,000 = 1B".
private struct TokenLimitRow: View {
    let toggleTitle: String
    let fieldTitle: String
    @Binding var field: TokenLimitField

    var body: some View {
        Toggle(toggleTitle, isOn: $field.isOn)
        if field.isOn {
            LabeledContent(fieldTitle) {
                HStack {
                    TextField(fieldTitle, text: $field.text, prompt: Text("1000000000"))
                        .labelsHidden()
                        .monospacedDigit()
                        .frame(width: 160)
                    Text(field.limit == nil ? field.hint : "tokens, \(field.hint)")
                        .foregroundStyle(field.limit == nil ? .red : .secondary)
                }
            }
        }
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
