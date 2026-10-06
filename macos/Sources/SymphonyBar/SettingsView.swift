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
                    .help(
                        "How long Restart Symphony waits for agent runs before it also offers Restart Now Anyway, "
                            + "and how long an update at a set time waits for them before it tries the next day."
                    )
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
                    SectionFooter(
                        model.settings.developmentMode
                            ? "Runs bin/symphony from the checkout through a login shell, for working on Symphony itself."
                            : "Runs the Symphony built into this app. Turn on to run bin/symphony from a checkout."
                    )
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
                    SectionFooter(model.settings.updateMode.explanation)
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
                    if model.tokenLimitsError != nil {
                        CheckErrorPointer(subject: "these token limits")
                    }
                    ForEach(TokenUsage.lines(model.budget, now: Date(), timeZone: .current), id: \.self) { line in
                        Text(line).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Agents (saved in symphony.yml)")
                } footer: {
                    SectionFooter(
                        "Each epic under way keeps one of these agents for its sub-tickets; the rest take "
                            + "other work. Merges and QA runs don't count here: up to 2 more run on top. More "
                            + "agents use the Linear and GitHub API budgets faster. 2–3 is a safe range on a "
                            + "personal Linear key. The daily token cap pauses new runs once today's tokens (UTC) "
                            + "reach it; the per-ticket cap stops a ticket that goes over it. Applies within a "
                            + "minute, no restart needed."
                    )
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
                    if model.runProfilesScope == .global && (model.runProfiles.usesOpenRouter || model.runProfiles.smallModel != nil) {
                        LabeledContent("Background calls") {
                            OpenRouterModelField(
                                selection: $model.runProfiles.smallModel,
                                inherited: nil,
                                inheritedSource: "",
                                models: model.openRouterAPIKey.isEmpty ? nil : model.openRouterModelList,
                                hasKey: !model.openRouterAPIKey.isEmpty,
                                retry: model.loadOpenRouterModels,
                                isPicking: Binding(
                                    get: { model.openRouterPickerRow == RunProfilesConfig.smallModelKey },
                                    set: { model.openRouterPickerRow = $0 ? RunProfilesConfig.smallModelKey : nil }
                                ),
                                query: $model.openRouterQuery
                            )
                            .frame(width: 210)
                            .controlSize(.small)
                        }
                        .help("The OpenRouter model for Claude Code's titles and summaries on OpenRouter runs (agent.small_model)")
                        .disabled(!model.canEditRunProfiles)
                    }
                    if model.configCheckError != nil {
                        CheckErrorPointer(subject: "these models")
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
                    SectionFooter(
                        "Each kind of run uses its own provider, model and effort, or the Default row where it "
                            + "sets none. A repository's rows override All repositories for issues routed to it; "
                            + "grey values are inherited. Bigger models and higher effort use the 5-hour usage "
                            + "limit faster: keep Opus and high effort for breakdown and hard implementation, and "
                            + "Sonnet or Haiku with low effort for landing and CI fixes. Background calls sets a "
                            + "cheaper OpenRouter model for Claude Code's titles and summaries on OpenRouter runs; "
                            + "default keeps them on the run's model. Save checks symphony.yml with symphony check "
                            + "first; changes apply to the next run."
                    )
                }

                Section {
                    AcceptanceGatePicker(
                        choice: Binding(
                            get: { .mode(model.acceptanceGateMode) },
                            set: { if case let .mode(mode) = $0 { model.acceptanceGateMode = mode } }
                        ),
                        pending: $model.pendingAcceptanceGate,
                        choices: AcceptanceGateMode.allCases.map { .mode($0) },
                        inherited: model.acceptanceGateMode
                    )
                    .disabled(!model.canEditAcceptanceGate)
                    if let error = model.acceptanceGateError {
                        Text(error).foregroundStyle(.red)
                    }
                    ForEach(model.acceptanceGateLines, id: \.self) { line in
                        Text(line).foregroundStyle(.secondary)
                    }
                } header: {
                    Text(AcceptanceGate.sectionTitle)
                } footer: {
                    SectionFooter(
                        "The gate judges each PR against its ticket after QA. Each repository's Edit… sheet in "
                            + "Repos… can set its own mode, and the status menu switches an enforced repository to "
                            + "Shadow or Off at once. Save checks symphony.yml with symphony check first; Symphony "
                            + "reads the mode on its next poll, no restart needed. The stats cover each repository's "
                            + "last 50 verdicts a person decided."
                    )
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
                    SectionFooter(
                        "Stored with your other secrets and passed to Symphony as \(SecretSettings.openRouterAPIKeyName) "
                            + "for run profiles with provider: openrouter. Those run on the Claude runtime only, with "
                            + "models that support tools. Leave blank to turn OpenRouter off."
                    )
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
                // In full here, below the Form: a grouped Form row is laid out shorter than wrapped text draws, so
                // a long reason there lost its last line and covered the row above.
                if let error = model.configCheckError {
                    CheckErrorText(message: error)
                }
                if let error = model.tokenLimitsError {
                    CheckErrorText(message: error)
                }
                if model.acceptanceGateError != nil {
                    Text("symphony check rejected the acceptance gate's mode; see Acceptance gate.").foregroundStyle(.red)
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

    static let width: CGFloat = 840
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
            // A grouped Form caps a row at 684pt whatever the window's width, and moves the controls under the
            // label when label and controls don't fit. Small controls in these columns keep the longest label,
            // "Review feedback", on one line with Reset to inherited, and fit "OpenRouter, inherited",
            // "medium, inherited" and an OpenRouter name such as "Mistral: Mistral Nemo, inherited". All
            // repositories has no Reset column, so its Effort column is wide enough for "medium, from command".
            HStack {
                picker("Provider", providerSelection, RunProfilesConfig.providers, inherited: inherited.provider, source: providerSource)
                    .frame(width: 160)
                Group {
                    if isOpenRouter {
                        OpenRouterModelField(
                            selection: $profile.model,
                            inherited: inherited.model,
                            inheritedSource: inheritedSource,
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
                .frame(width: canReset ? 140 : 170)
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
            .controlSize(.small)
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
    /// The model id a nil selection falls back to, shown by its name with `inheritedSource`, such as "inherited".
    let inherited: String?
    let inheritedSource: String
    let models: Result<[OpenRouterModel], OpenRouterFailure>?
    let hasKey: Bool
    let retry: () -> Void
    @Binding var isPicking: Bool
    @Binding var query: String

    var body: some View {
        switch models {
        case nil where !hasKey:
            Text("Add an OpenRouter key below first")
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .help("Enter an OpenRouter API key in the OpenRouter section to choose OpenRouter models.")
        case nil:
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading models…").foregroundStyle(.secondary)
            }
        case .failure(let failure)?:
            // Wraps in the narrow column, with Retry under it, so the whole reason shows.
            VStack(alignment: .leading, spacing: 2) {
                Text(failure.message)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
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
                    Text(selection.map { OpenRouterModel.title(of: $0, in: models) } ?? inheritedTitle(models))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .opacity(selection == nil ? 0.55 : 1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                }
            }
            // The chosen model's id, or the inherited model's full name, which this narrow column can cut.
            .help(selection ?? (inherited == nil ? "Choose an OpenRouter model that supports tools" : inheritedTitle(models)))
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
                Button(inheritedTitle(models)) { choose(nil) }
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
        // The row's small controls stop at the popover.
        .controlSize(.regular)
    }

    private func inheritedTitle(_ models: [OpenRouterModel]) -> String {
        inherited.map { OpenRouterModel.title(of: $0, in: models) + ", " + inheritedSource } ?? "default"
    }

    private func choose(_ id: String?) {
        selection = id
        isPicking = false
    }
}

/// A section's help text under the Form. Fixed to its wrapped height: without it the grouped Form can lay a footer
/// out as one line cut off with an ellipsis.
private struct SectionFooter: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A `symphony check` failure shown in full below the Form: it wraps rather than cutting off the reason, and can
/// be copied.
private struct CheckErrorText: View {
    let message: String

    var body: some View {
        Text(message)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .help(message)
    }
}

/// One line in a section saying `symphony check` rejected `subject`, such as "these models", and that the reason
/// shows in full above Save.
private struct CheckErrorPointer: View {
    let subject: String

    var body: some View {
        Text("symphony check rejected \(subject); the reason shows above Save.")
            .foregroundStyle(.red)
            .lineLimit(1)
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
