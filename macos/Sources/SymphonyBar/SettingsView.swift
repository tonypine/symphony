import AppKit
import SwiftUI
import SymphonyBarCore

struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    /// Runs Check Now and gives the last update check.
    @ObservedObject var updates: UpdatePoller
    let close: () -> Void

    /// The check interval, moved into range as the field commits, with a note saying so (S1d).
    private var releaseCheckMinutes: Binding<Int> {
        Binding(
            get: { model.settings.releaseCheckMinutes },
            set: { typed in
                let committed = UpdateCheckSchedule.committed(
                    typed,
                    current: model.settings.releaseCheckMinutes,
                    note: model.releaseCheckNote
                )
                model.releaseCheckNote = committed.note
                model.settings.releaseCheckMinutes = committed.minutes
            }
        )
    }

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

                NotificationsSection()

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
                    .onChange(of: model.settings.updateMode) { old, new in
                        // Shows straight away what the mode would find; Save then re-arms the checks.
                        if new == .onRelease && old != .onRelease { updates.check(manual: false) }
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
                    if model.settings.updateMode == .onRelease {
                        LabeledContent("Check for releases every") {
                            HStack {
                                TextField("Minutes", value: releaseCheckMinutes, format: .number)
                                    .labelsHidden()
                                    .frame(width: 60)
                                Stepper("Minutes", value: releaseCheckMinutes, in: AppSettings.releaseCheckMinutesRange)
                                    .labelsHidden()
                                Text("minutes")
                            }
                        }
                        ReleaseCheckLine(schedule: updates.schedule, note: model.releaseCheckNote) {
                            updates.check(manual: true)
                        }
                        .onChange(of: updates.isChecking) { _, checking in
                            if checking { model.releaseCheckNote = nil }
                        }
                    }
                } header: {
                    Text("Updates")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionFooter(model.settings.updateMode.explanation)
                        if model.settings.updateMode == .onRelease {
                            SectionFooter(UpdateCheckSchedule.rateLimitNote)
                        }
                        if let line = model.settings.updateMode.blockerLine(
                            model.updateBlocker(model.settings.developmentMode)
                        ) {
                            SectionFooter(line)
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
                    Text("Only the chosen priorities start new work. With none chosen, every priority may.")
                        .foregroundStyle(.secondary)
                    ForEach(TicketPriority.allCases, id: \.self) { priority in
                        Toggle(priority.title, isOn: Binding(
                            get: { model.ticketPriorities.priorities.contains(priority) },
                            set: { on in
                                if on {
                                    model.ticketPriorities.priorities.insert(priority)
                                } else {
                                    model.ticketPriorities.priorities.remove(priority)
                                }
                            }
                        ))
                    }
                    if model.ticketPrioritiesError != nil {
                        CheckErrorPointer(subject: "these ticket priorities")
                    }
                } header: {
                    Text("Tickets (saved in symphony.yml)")
                } footer: {
                    SectionFooter(
                        "An issue whose priority is not chosen is not dispatched: Symphony waits with free "
                            + "lanes even when it sits in Todo. Use it to focus limited API spend, for example "
                            + "on urgent and high tickets only. A forced ticket, and a run already under way, "
                            + "still go. Save checks symphony.yml with symphony check first; Symphony reads it "
                            + "on its next poll, no restart needed."
                    )
                }
                .disabled(!model.canEditTicketPriorities)

                Section {
                    Text("The Linear workflow states Symphony creates for the board's phases. Nothing moves tickets into them yet.")
                        .foregroundStyle(.secondary)
                    WorkflowStateRow(title: "Code review", name: $model.workflowStates.codeReview)
                    WorkflowStateRow(title: "QA", name: $model.workflowStates.qa)
                    WorkflowStateRow(title: "Plan review", name: $model.workflowStates.planReview)
                    WorkflowStateRow(title: "Epic review", name: $model.workflowStates.epicReview)
                    WorkflowStateRow(title: "CI fix", name: $model.workflowStates.ciFix)
                    if model.workflowStatesError != nil {
                        CheckErrorPointer(subject: "these board states")
                    }
                } header: {
                    Text("Board states (saved in symphony.yml)")
                } footer: {
                    SectionFooter(
                        "issues.states.code_review, .qa, .plan_review, .epic_review and .ci_fix. At startup Symphony "
                            + "creates a Linear state with each name in your team, and reports the exact name loudly "
                            + "when one is missing or renamed instead of creating a duplicate. Renamed a state in "
                            + "Linear? Point its field here at the new name. Save checks symphony.yml with symphony "
                            + "check first; Symphony reads it when it next starts."
                    )
                }
                .disabled(!model.canEditWorkflowStates)

                Section {
                    Toggle(BuiltInTicketPatterns.toggleTitle, isOn: $model.ticketPatternsBuiltIn)
                    Text(
                        model.ticketPatternsBuiltIn
                            ? BuiltInTicketPatternsChoice.on.explanation
                            : BuiltInTicketPatternsChoice.off.explanation
                    )
                    .foregroundStyle(.secondary)
                    if model.ticketPatternsBuiltInError != nil {
                        CheckErrorPointer(subject: "this setting")
                    }
                } header: {
                    Text("Code Review (saved in symphony.yml)")
                } footer: {
                    SectionFooter(
                        "auto_review.acceptance_gate.escalate.ticket_patterns_builtin. The built-in ticket patterns "
                            + "match a title or description asking for a human or manual review, saying it must not be "
                            + "auto-approved, or that it needs a human. Turn them off when they misfire on your tickets; "
                            + "a repo can override this in its Review sheet in Repos. Save checks symphony.yml with symphony check "
                            + "first; Symphony reads it on its next poll, no restart needed."
                    )
                }
                .disabled(!model.canEditTicketPatternsBuiltIn)

                Section {
                    TimeoutRow(title: "Git network timeout", minutes: $model.gitNetworkTimeoutMinutes)
                    Text("Stops a git fetch, pull, push or ls-remote that runs longer, so a remote that stops answering can't hold the repo.")
                        .foregroundStyle(.secondary)
                    TimeoutRow(title: "MCP tool timeout", minutes: $model.mcpToolTimeoutMinutes)
                    Text("Stops one call of Symphony's Linear and GitHub tools that runs longer and answers the agent with an error.")
                        .foregroundStyle(.secondary)
                    TimeoutRow(title: "Show a pending tool call after", minutes: $model.pendingToolReportMinutes)
                    Text("Shows a run as waiting on one of those calls once the call has run this long.")
                        .foregroundStyle(.secondary)
                    if let error = model.timeoutsError {
                        Text(error).foregroundStyle(.red)
                    }
                } header: {
                    Text("Timeouts (saved in symphony.yml)")
                } footer: {
                    SectionFooter(
                        "workspaces.git_network_timeout_ms (default 5 minutes), agent.timeouts.mcp_tool_ms (default "
                            + "10 minutes) and watchdog.pending_tool_report_after_ms (default 1 minute). Save checks "
                            + "symphony.yml with symphony check first; Symphony reads them on the next call, no restart "
                            + "needed."
                    )
                }
                .disabled(!model.canEditTimeouts)

                Section {
                    MinutesRow(title: "Safety-net check every", minutes: $model.safetyNetCheckMinutes)
                    Text(
                        "While GitHub's webhook deliveries arrive, Symphony also checks every PR this often, to catch "
                            + "one a delivery missed. Without deliveries it checks at the poll interval."
                    )
                    .foregroundStyle(.secondary)
                    MinutesRow(title: "Warn me after no updates for", minutes: $model.silenceAlertMinutes)
                    Text("Shows a warning when no delivery has arrived from GitHub for this long.")
                        .foregroundStyle(.secondary)
                    if let error = model.gitHubUpdatesError {
                        Text(error).foregroundStyle(.red)
                    }
                } header: {
                    Text("GitHub updates (saved in symphony.yml)")
                } footer: {
                    SectionFooter(
                        "github.webhooks.fallback_poll_interval_ms (default 5 minutes) and "
                            + "github.webhooks.silence_alert_minutes (default 10 minutes). Save checks symphony.yml with "
                            + "symphony check first; Symphony reads them on its next check, no restart needed."
                    )
                }
                .disabled(!model.canEditGitHubUpdates)

                Section {
                    DispatchLoopRow(title: "Hold a ticket after", runs: $model.dispatchLoopRuns, minutes: $model.dispatchLoopWindowMinutes)
                    DispatchLoopRow(title: "Or after", runs: $model.dispatchLoopLongRuns, minutes: $model.dispatchLoopLongWindowMinutes)
                    Text(
                        "Once a ticket got this many runs of one kind in that time with no state change, new PR head or "
                            + "decision, Symphony starts no more and puts it on a Blocked hold that says why. Unblock it "
                            + "from the Inbox."
                    )
                    .foregroundStyle(.secondary)
                    if let error = model.dispatchLoopError {
                        Text(error).foregroundStyle(.red)
                    }
                } header: {
                    Text("Dispatch loops (saved in symphony.yml)")
                } footer: {
                    SectionFooter(
                        "watchdog.dispatch_loop_runs in watchdog.dispatch_loop_window_ms (default 4 runs in 10 minutes) "
                            + "and watchdog.dispatch_loop_long_runs in watchdog.dispatch_loop_long_window_ms (default 8 "
                            + "runs in 60 minutes). Save checks symphony.yml with symphony check first; Symphony reads "
                            + "them on its next dispatch, no restart needed."
                    )
                }
                .disabled(!model.canEditDispatchLoop)

                Section {
                    LabeledContent("Keep artifact files for") {
                        HStack {
                            Text(model.artifactRetentionDays == 1 ? "1 day" : "\(model.artifactRetentionDays) days")
                                .monospacedDigit()
                            Stepper("Keep artifact files for days", value: $model.artifactRetentionDays, in: LedgerSettings.dayRange)
                                .labelsHidden()
                        }
                    }
                    LabeledContent("Largest artifact") {
                        HStack {
                            Text("\(model.artifactMaxMegabytes) MB")
                                .monospacedDigit()
                            Stepper("Largest artifact in MB", value: $model.artifactMaxMegabytes, in: LedgerSettings.megabyteRange)
                                .labelsHidden()
                        }
                    }
                    Text(
                        "Once a ticket has been finished this long, Symphony deletes its artifact files (screenshots, "
                            + "transcripts) and keeps their details and the events that name them. It refuses to store a "
                            + "file larger than the cap."
                    )
                    .foregroundStyle(.secondary)
                    Toggle("Give agents the ticket's history summary", isOn: $model.promptBriefEnabled)
                    LabeledContent("Summary size limit") {
                        HStack {
                            TextField("Summary size limit in tokens", value: $model.promptBriefMaxTokens, format: .number)
                                .labelsHidden()
                                .monospacedDigit()
                                .frame(width: 90)
                                .accessibilityLabel("Summary size limit in tokens")
                            Text("tokens")
                        }
                    }
                    .disabled(!model.promptBriefEnabled)
                    Text(
                        "Every agent starts from a summary of the ticket's whole history: every decision, open finding "
                            + "and note in full. Nothing is left out: a summary over the limit is still given whole, and "
                            + "Symphony logs a warning."
                    )
                    .foregroundStyle(.secondary)
                    if let error = model.ledgerError {
                        Text(error).foregroundStyle(.red)
                    }
                } header: {
                    Text("Ledger (saved in symphony.yml)")
                } footer: {
                    SectionFooter(
                        "ledger.artifact_retention_days (default 14 days), ledger.artifact_max_bytes (default 25 MB), "
                            + "ledger.prompt_brief_enabled (default on) and ledger.prompt_brief_max_tokens (default 50,000 "
                            + "tokens). Save checks symphony.yml with symphony check first; Symphony reads them on its next "
                            + "cleanup, stored file and agent prompt, no restart needed."
                    )
                }
                .disabled(!model.canEditLedger)

                MacAppQASection(model: model)

                Section {
                    Picker("Scope", selection: $model.runProfilesScope) {
                        Text("All repositories").tag(RunProfilesScope.global)
                        ForEach(model.repositoryKeys, id: \.self) { key in
                            Text(key).tag(RunProfilesScope.repository(key))
                        }
                    }
                    .disabled(!model.canEditRunProfiles || model.repositoryKeys.isEmpty)
                    ForEach(RunProfilesConfig.scopes, id: \.self) { kind in
                        runProfileRow(kind)
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
                if model.timeoutsError != nil {
                    Text("symphony check rejected the timeouts; see Timeouts.").foregroundStyle(.red)
                }
                if model.gitHubUpdatesError != nil {
                    Text("symphony check rejected the GitHub update settings; see GitHub updates.").foregroundStyle(.red)
                }
                if model.dispatchLoopError != nil {
                    Text("symphony check rejected the dispatch-loop limits; see Dispatch loops.").foregroundStyle(.red)
                }
                if model.ledgerError != nil {
                    Text("symphony check rejected the ledger settings; see Ledger.").foregroundStyle(.red)
                }
                if model.macAppQAError != nil {
                    Text("symphony check rejected the macOS app QA settings; see macOS app QA.").foregroundStyle(.red)
                }
                if model.ticketPrioritiesError != nil {
                    Text("symphony check rejected the ticket priorities; see Tickets.").foregroundStyle(.red)
                }
                if let error = model.qaHostToolsError {
                    CheckErrorText(message: error)
                }
                if let error = model.ticketPatternsBuiltInError {
                    CheckErrorText(message: error)
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

    /// One kind's run profile row, its arguments worked out in separate statements: as one expression it came near
    /// the type-checker's budget on CI's Xcode (TP-1017).
    private func runProfileRow(_ kind: RunKind?) -> RunProfileRow {
        let isGlobal: Bool = model.runProfilesScope == .global
        let isCommandDefault: Bool = isGlobal && kind == nil
        let hasOpenRouterKey: Bool = !model.openRouterAPIKey.isEmpty
        let pickerRow: String = kind?.rawValue ?? "default"
        return RunProfileRow(
            kind: kind,
            profile: $model.runProfiles[model.runProfilesScope][kind],
            inherited: model.inheritedProfile(kind),
            inheritedSource: isCommandDefault ? "from command" : "inherited",
            providerSource: isCommandDefault ? "default" : "inherited",
            canReset: !isGlobal,
            openRouterModels: hasOpenRouterKey ? model.openRouterModelList : nil,
            hasOpenRouterKey: hasOpenRouterKey,
            retryOpenRouterModels: model.loadOpenRouterModels,
            isPickingModel: Binding(
                get: { model.openRouterPickerRow == pickerRow },
                set: { model.openRouterPickerRow = $0 ? pickerRow : nil }
            ),
            modelQuery: $model.openRouterQuery
        )
    }
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

/// The `macos_app` QA playbook: the tools the QA host needs, the project's dev server there and the variables the
/// app under test gets (`auto_review.playbooks.macos_app.requires`, `dev_server`, `dev_server_port` and `launch_env`).
private struct MacAppQASection: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        Section {
            Group {
                LabeledContent("QA host tools") {
                    TextField("QA host tools", text: $model.qaHostToolsText, prompt: Text("e.g. go, pg_ctl"))
                        .labelsHidden()
                }
                Text(
                    "The programs a macOS app QA pass needs on the QA host, comma-separated. Symphony looks for "
                        + "each when the pass starts; a missing one blocks the pass, and self-heal files the fix "
                        + "for the QA host."
                )
                .foregroundStyle(.secondary)
                if model.qaHostToolsError != nil {
                    CheckErrorPointer(subject: "these QA host tools")
                }
            }
            .disabled(!model.canEditQAHostTools)
            Group {
                devServerControls
            }
            .disabled(!model.canEditMacAppQA)
        } header: {
            Text("macOS app QA (saved in symphony.yml)")
        } footer: {
            SectionFooter(
                "auto_review.playbooks.macos_app.requires (default none), dev_server (default off), dev_server_port "
                    + "(default 8090) and launch_env (default none). A repository's WORKFLOW.md can set them too, and "
                    + "wins. scripts/qa-vm/provision.sh installs Go, Postgres and jq on a QA VM. Save checks "
                    + "symphony.yml with symphony check first; the next QA pass uses them."
            )
        }
    }

    @ViewBuilder private var devServerControls: some View {
        Toggle("Start the project's dev server on the QA host", isOn: $model.macAppQA.devServer)
        Text(
            "A macOS app QA pass on the QA host runs the project's verification.dev_server there, beside the app, "
                + "from the PR head, before the app launches, and stops it when the pass ends."
        )
        .foregroundStyle(.secondary)
        LabeledContent("Dev server port") {
            TextField("Dev server port", value: $model.macAppQA.devServerPort, format: .number.grouping(.never))
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
        }
        Text("App environment")
        ForEach($model.macAppQA.launchEnv) { $variable in
            HStack {
                TextField("Name", text: $variable.name, prompt: Text("NAME"))
                    .labelsHidden()
                TextField("Value", text: $variable.value, prompt: Text("Value"))
                    .labelsHidden()
                Button {
                    model.removeLaunchVariable(id: variable.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this variable")
            }
        }
        Button("Add Variable") { model.addLaunchVariable() }
        Text(
            "QA sets these on the app after its own variables; $SYMPHONY_VERIFICATION_PORT becomes the port. "
                + "They are saved in plain text, so never put a secret here."
        )
        .foregroundStyle(.secondary)
        if let error = model.macAppQAError {
            Text(error).foregroundStyle(.red)
        }
    }
}

/// A section's help text under the Form. Fixed to its wrapped height: without it the grouped Form can lay a footer
/// out as one line cut off with an ellipsis.
/// D14: one switch per kind of notification, kept in the app's defaults and read at each poll.
private struct NotificationsSection: View {
    @State private var preferences = NotificationPreferences.load(from: AppStores.current.defaults)

    var body: some View {
        Section {
            ForEach(NoticeKind.allCases, id: \.self) { kind in
                Toggle(kind.settingsTitle, isOn: Binding(
                    get: { preferences.isOn(kind) },
                    set: { on in
                        preferences.set(kind, on: on)
                        preferences.save(to: AppStores.current.defaults)
                    }
                ))
            }
        } header: {
            Text("Notifications")
        } footer: {
            SectionFooter(
                "One notification for each new thing that waits on you and each new problem, never twice for the same "
                    + "one, and nothing for routine progress."
            )
        }
    }
}

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

/// The last update check under Check for releases every N minutes, with Check Now (S1a–S1d): a spinner while it
/// checks, and `note` in its place once after the minutes were moved into range.
struct ReleaseCheckLine: View {
    let schedule: UpdateCheckSchedule
    let note: String?
    let checkNow: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            HStack {
                if schedule.isChecking {
                    ProgressView().controlSize(.small)
                }
                Text(schedule.isChecking ? UpdateCheckSchedule.checkingLine
                    : note ?? schedule.settingsLine(now: context.date, calendar: .current))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Check Now", action: checkNow)
                    .disabled(schedule.isChecking)
            }
        }
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

/// A timeout in whole minutes, with a stepper over `OperationTimeouts.minuteRange`.
private struct TimeoutRow: View {
    let title: String
    @Binding var minutes: Int

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(minutes == 1 ? "1 minute" : "\(minutes) minutes")
                    .monospacedDigit()
                Stepper(title, value: $minutes, in: OperationTimeouts.minuteRange)
                    .labelsHidden()
            }
        }
    }
}

/// A number of minutes, shown as "5 min", with a stepper over `GitHubUpdates.minuteRange`; Settings and Setup's GitHub
/// updates card both use it.
struct MinutesRow: View {
    let title: String
    @Binding var minutes: Int

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text("\(minutes) min")
                    .monospacedDigit()
                Stepper(title, value: $minutes, in: GitHubUpdates.minuteRange)
                    .labelsHidden()
            }
        }
    }
}

/// A dispatch-loop limit: a number of runs and a window in whole minutes, each with a stepper.
private struct DispatchLoopRow: View {
    let title: String
    @Binding var runs: Int
    @Binding var minutes: Int

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(runs == 1 ? "1 run" : "\(runs) runs")
                    .monospacedDigit()
                Stepper("\(title) runs", value: $runs, in: DispatchLoopLimits.runRange)
                    .labelsHidden()
                Text(minutes == 1 ? "in 1 minute" : "in \(minutes) minutes")
                    .monospacedDigit()
                Stepper("\(title) minutes", value: $minutes, in: DispatchLoopLimits.minuteRange)
                    .labelsHidden()
            }
        }
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

/// One `issues.states.*` phase state: the Linear state name the board creates for that phase.
private struct WorkflowStateRow: View {
    let title: String
    @Binding var name: String

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $name, prompt: Text("State name"))
                .labelsHidden()
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
