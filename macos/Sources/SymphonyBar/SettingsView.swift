import AppKit
import SwiftUI
import SymphonyBarCore
import SymphonyBarUI

/// The Settings page of the Symphony window (TP-1575): its sections down its side, drawn with the design system's
/// section list, and the current section's blocks beside them, each a design-system settings group of rows (TP-1576),
/// scrolling by itself. The Save bar and every error line stay under the groups whichever section shows, since Save
/// checks and stores them all; a section holding a value Save refused carries its count in the list.
struct SettingsView: View {
    @ObservedObject var model: SettingsViewModel
    /// Runs Check Now and gives the last update check.
    @ObservedObject var updates: UpdatePoller
    let section: SettingsSection
    let select: (SettingsSection) -> Void
    /// The last Save stored everything.
    var saved = false
    let revert: () -> Void
    let save: () -> Void

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

    /// The not-answering limit, moved into range as the field commits (TP-1562), in steps of 10 seconds as the stepper
    /// moves it: a typed value is rounded to the nearest 10.
    private var notAnsweringAlertSeconds: Binding<Int> {
        Binding(
            get: { model.settings.notAnsweringAlertSeconds },
            set: { typed in
                let tens = Int((Double(typed) / 10).rounded()) * 10
                model.settings.notAnsweringAlertSeconds = AppSettings.clampedNotAnsweringAlertSeconds(tens)
            }
        )
    }

    /// Why a section's settings wait: no symphony.yml read yet, or Save checking it.
    static let waits = ConductorSection.notEditable
    /// What a number field typed in may hold when the page says why a value is out of range, or `symphony check` does.
    static let anyWholeNumber = Int.min...Int.max

    /// The message of the first of `issues` Save refused, shown on the row that holds it.
    private func issue(_ issues: [SettingsIssue]) -> String? {
        issues.first { model.issues.contains($0) }?.message
    }

    /// The stop timeout's error while it is out of range: shown on its row, and Save waits for it.
    private var stopTimeoutError: String? {
        AppSettings.stopTimeoutRange.contains(model.settings.stopTimeoutSeconds) ? nil : SettingsIssue.stopTimeoutOutOfRange.message
    }

    /// The restart timeout's error while it is out of range: shown on its row, and Save waits for it.
    private var restartTimeoutError: String? {
        AppSettings.restartTimeoutRange.contains(model.settings.restartTimeoutMinutes)
            ? nil : SettingsIssue.restartTimeoutOutOfRange.message
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            SectionList(Self.entries(failing: Self.failing(model)), current: section, select: select)
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.SettingsRow.groupsGap) {
                        ForEach(section.blocks, id: \.self) { block in self.block(block) }
                    }
                    .frame(maxWidth: DesignTokens.SettingsRow.pageMaxWidth, alignment: .leading)
                    .padding(DesignTokens.SettingsRow.pageInset)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Another section opens at its top.
                .id(section)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                errors
                saveBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The section list's rows: each section with its glyph, and the count of its blocks Save refused.
    static func entries(failing: Set<SettingsBlock>) -> [SidebarEntry<SettingsSection>] {
        SettingsSection.allCases.map { section in
            let failures = section.failures(failing)
            return SidebarEntry(
                id: section, title: section.title, symbol: section.symbol, count: failures, countRole: .problem,
                spoken: failures == 0 ? nil : "\(failures) to fix"
            )
        }
    }

    /// The blocks holding a value Save refused or couldn't store.
    static func failing(_ model: SettingsViewModel) -> Set<SettingsBlock> {
        var failing = Set(model.issues.map(\.block))
        let errors: [(String?, SettingsBlock)] = [
            (model.loginItemError, .symphony), (model.secretsError, .environment), (model.tokenLimitsError, .agents),
            (model.timeoutsError, .timeouts), (model.conductorError, .conductor), (model.ticketPrioritiesError, .tickets),
            (model.workflowStatesError, .boardStates), (model.dispatchError, .dispatch),
            (model.dispatchLoopError, .dispatchLoops), (model.gitHubUpdatesError, .gitHubUpdates),
            (model.linearWebhooksError, .linearWebhooks), (model.ticketPatternsBuiltInError, .codeReview),
            (model.riskRulesError, .riskRules), (model.phasesError, .phases), (model.macAppQAError, .macAppQA),
            (model.qaHostToolsError, .macAppQA), (model.ledgerError, .ledger), (model.reportsError, .reports),
        ]
        for (error, block) in errors where error != nil { failing.insert(block) }
        return failing
    }

    /// Every error line, whichever section shows; a line about a block names the section that holds it. A
    /// `symphony check` failure shows in full, wraps, and can be copied.
    private var lines: [String] {
        var lines = model.issues.map { "\($0.message) See \($0.block.pointer)." }
        let pointers: [(String?, String)] = [
            (model.timeoutsError, "symphony check rejected the timeouts; see \(SettingsBlock.timeouts.pointer)."),
            (model.gitHubUpdatesError, "symphony check rejected the GitHub update settings; see \(SettingsBlock.gitHubUpdates.pointer)."),
            (model.linearWebhooksError, "The Linear webhook settings weren't saved; see \(SettingsBlock.linearWebhooks.pointer)."),
            (model.dispatchLoopError, "symphony check rejected the dispatch-loop limits; see \(SettingsBlock.dispatchLoops.pointer)."),
            (model.dispatchError, "The dispatch settings weren't saved; see \(SettingsBlock.dispatch.pointer)."),
            (model.ledgerError, "symphony check rejected the ledger settings; see \(SettingsBlock.ledger.pointer)."),
            (model.reportsError, "symphony check rejected the report settings; see \(SettingsBlock.reports.pointer)."),
            (model.conductorError, "symphony check rejected the Conductor settings; see \(SettingsBlock.conductor.pointer)."),
            (model.macAppQAError, "symphony check rejected the macOS app QA settings; see \(SettingsBlock.macAppQA.pointer)."),
            (model.ticketPrioritiesError, "symphony check rejected the ticket priorities; see \(SettingsBlock.tickets.pointer)."),
        ]
        lines += [model.secretsError, model.configFileError, model.tokenLimitsError].compactMap { $0 }
        lines += pointers.compactMap { error, line in error == nil ? nil : line }
        lines += [
            model.qaHostToolsError, model.workflowStatesError, model.ticketPatternsBuiltInError, model.riskRulesError,
            model.phasesError, model.loginItemError,
        ].compactMap { $0 }
        return lines
    }

    private var errors: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Space.s1) {
            ForEach(lines, id: \.self) { line in
                FieldFootnote(footnote: .error(line))
                    .textSelection(.enabled)
                    .help(line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DesignTokens.SettingsRow.pageInset)
    }

    /// The Save bar: the count of settings that differ from the saved values, Revert, which puts back the saved values (the page has no window to
    /// close, as the old Settings window's Cancel did), and Save, which checks and stores every section's values at
    /// once. Save waits while nothing changed, while a value is out of range and while the form can't save yet.
    private var saveBar: some View {
        SaveBar(
            changes: model.changeCount, state: model.isSaving ? .saving : saved ? .saved : .editing,
            saveDisabledReason: stopTimeoutError ?? restartTimeoutError ?? model.saveBlockedReason, onRevert: revert, onSave: save
        )
        .padding(DesignTokens.SettingsRow.pageInset)
    }

    @ViewBuilder private func block(_ block: SettingsBlock) -> some View {
        switch block {
        case .symphony: symphonyBlock
        case .notifications: notificationsBlock
        case .developmentMode: developmentModeBlock
        case .updates: updatesBlock
        case .agents: agentsBlock
        case .tickets: ticketsBlock
        case .boardStates: boardStatesBlock
        case .codeReview: codeReviewBlock
        case .riskRules: riskRulesBlock
        case .phases: phasesBlock
        case .timeouts: timeoutsBlock
        case .gitHubUpdates: gitHubUpdatesBlock
        case .linearWebhooks: linearWebhooksBlock
        case .dispatchLoops: dispatchLoopsBlock
        case .dispatch: dispatchBlock
        case .ledger: ledgerBlock
        case .reports: reportsBlock
        case .conductor: conductorBlock
        case .macAppQA: macAppQABlock
        case .environment: environmentBlock
        }
    }

    private var symphonyBlock: some View {
        SettingsGroup("Symphony") {
            PathRow(
                title: "symphony.yml", path: $model.settings.configPath, choosesDirectories: false,
                error: issue([.configPathMissing, .configPathNotAbsolute, .configPathNotFile])
            )
            SettingsRow("Stop timeout", error: stopTimeoutError) {
                NumberField(
                    value: $model.settings.stopTimeoutSeconds, in: AppSettings.stopTimeoutRange, accepts: Self.anyWholeNumber,
                    unit: "seconds"
                )
                .controlLabel("Seconds")
            }
            SettingsRow(
                "Restart timeout",
                help: "How long Restart Symphony waits for agent runs before it also offers Restart Now Anyway, "
                    + "and how long an update at a set time waits for them before it tries the next day.",
                error: restartTimeoutError
            ) {
                NumberField(
                    value: $model.settings.restartTimeoutMinutes, in: AppSettings.restartTimeoutRange, accepts: Self.anyWholeNumber,
                    unit: "minutes"
                )
                .controlLabel("Minutes")
            }
            SettingsRow(
                "Not answering alert",
                help: "How long Symphony may not answer before the menu bar shows the problem and the app sends "
                    + "one notification. The Director keeps its pages meanwhile."
            ) {
                NumberField(value: notAnsweringAlertSeconds, in: AppSettings.notAnsweringAlertRange, step: 10, unit: "seconds")
                    .controlLabel("Seconds")
            }
            SettingsRow("Start Symphony when the app opens") { DirectorSwitch(isOn: $model.settings.startOnLaunch) }
            SettingsRow(LoginItem.toggleTitle) { DirectorSwitch(isOn: $model.launchAtLogin) }
            if let note = model.loginItemNote {
                SettingsLine {
                    HStack(spacing: DesignTokens.SettingsRow.columnGap) {
                        FieldFootnote(footnote: .help(note))
                        Spacer(minLength: 0)
                        Button("Open Login Items") { MainAppLoginItem.openSystemSettings() }
                            .directorButton(.secondary, size: .small)
                            .fixedSize()
                    }
                }
            }
        }
    }

    private var notificationsBlock: some View {
        NotificationsSection()
    }

    private var developmentModeBlock: some View {
        SettingsGroup(
            footer: model.settings.developmentMode
                ? "Runs bin/symphony from the checkout through a login shell, for working on Symphony itself."
                : "Runs the Symphony built into this app. Turn on to run bin/symphony from a checkout."
        ) {
            SettingsRow("Development mode", error: issue([.embeddedSymphonyMissing])) {
                DirectorSwitch(isOn: $model.settings.developmentMode)
            }
            if model.settings.developmentMode {
                PathRow(
                    title: "Checkout folder", path: $model.settings.checkoutPath, choosesDirectories: true,
                    error: issue([.checkoutPathMissing, .checkoutPathNotAbsolute, .checkoutPathNotDirectory])
                )
                SettingsRow("Command prefix", error: issue([.commandPrefixUnbalancedQuotes])) {
                    DirectorTextField(nil, text: $model.settings.commandPrefix, placeholder: "Optional, e.g. mise exec --", mono: true)
                        .frame(width: DesignTokens.SettingsRow.fieldWidth)
                }
            }
        }
    }

    /// What the Updates group's footer says: the mode's effect, GitHub's limit on checks, and what keeps this copy from
    /// installing updates, one to a line.
    private var updatesFooter: String {
        var lines = [model.settings.updateMode.explanation]
        if model.settings.updateMode == .onRelease { lines.append(UpdateCheckSchedule.rateLimitNote) }
        if let line = model.settings.updateMode.blockerLine(model.updateBlocker(model.settings.developmentMode)) {
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private var updatesBlock: some View {
        SettingsGroup("Updates", footer: updatesFooter) {
            SettingsRow("Update mode") {
                PopUp(
                    nil, selection: $model.settings.updateMode, choices: UpdateMode.allCases.map { PopUpChoice($0, $0.title) },
                    accessibilityLabel: "Update mode"
                )
            }
            .onChange(of: model.settings.updateMode) { old, new in
                // Shows straight away what the mode would find; Save then re-arms the checks.
                if new == .onRelease && old != .onRelease { updates.check(manual: false) }
            }
            if model.settings.updateMode == .atTime {
                SettingsRow("Time") { TimeField(time: $model.settings.updateTime) }
            }
            if model.settings.updateMode == .onRelease {
                SettingsRow("Check for releases every") {
                    NumberField(
                        value: releaseCheckMinutes, in: AppSettings.releaseCheckMinutesRange, accepts: Self.anyWholeNumber,
                        unit: "minutes"
                    )
                    .controlLabel("Minutes")
                }
                ReleaseCheckLine(schedule: updates.schedule, note: model.releaseCheckNote) {
                    updates.check(manual: true)
                }
                .onChange(of: updates.isChecking) { _, checking in
                    if checking { model.releaseCheckNote = nil }
                }
            }
        }
    }

    /// Why the token limits wait: no symphony.yml read yet, the secrets still being read, or Save checking it.
    private var tokenLimitsReason: String? { model.canEditTokenLimits ? nil : Self.waits }

    private var agentsBlock: some View {
        SettingsGroup(
            "Agents (saved in symphony.yml)",
            footer: "Each epic under way keeps one of these agents for its sub-tickets; the rest take "
                + "other work. Merges and QA runs don't count here: up to 2 more run on top. More "
                + "agents use the Linear and GitHub API budgets faster. 2–3 is a safe range on a "
                + "personal Linear key. The daily token cap pauses new runs once today's tokens (UTC) "
                + "reach it; the per-ticket cap stops a ticket that goes over it. Applies within a "
                + "minute, no restart needed."
        ) {
            SettingsRow("Max concurrent agents", disabledReason: model.canEditMaxConcurrentAgents ? nil : Self.waits) {
                NumberField(value: $model.maxConcurrentAgents, in: MaxConcurrentAgents.range)
            }
            TokenLimitRows(
                toggleTitle: "Limit tokens per day", fieldTitle: "Tokens per day", field: $model.dailyTokenLimit,
                disabledReason: tokenLimitsReason
            )
            TokenLimitRows(
                toggleTitle: "Limit tokens per ticket", fieldTitle: "Tokens per ticket", field: $model.issueTokenLimit,
                disabledReason: tokenLimitsReason
            )
            if model.isCheckingTokenLimits {
                SettingsLine {
                    HStack(spacing: DesignTokens.Space.s2) {
                        ProgressView().controlSize(.small)
                        FieldFootnote(footnote: .help("Checking the token limits with symphony check…"))
                    }
                }
            }
            if model.tokenLimitsError != nil {
                CheckErrorPointer(subject: "these token limits")
            }
            ForEach(TokenUsage.lines(model.budget, now: Date(), timeZone: .current), id: \.self) { line in
                SettingsLine(line)
            }
        }
    }

    private var ticketsBlock: some View {
        SettingsGroup(
            "Tickets (saved in symphony.yml)",
            footer: "An issue whose priority is not chosen is not dispatched: Symphony waits with free "
                + "lanes even when it sits in Todo. Use it to focus limited API spend, for example "
                + "on urgent and high tickets only. A run already under way still goes. "
                + "Save checks symphony.yml with symphony check first; Symphony reads it "
                + "on its next poll, no restart needed."
        ) {
            SettingsLine("Only the chosen priorities start new work. With none chosen, every priority may.")
            ForEach(TicketPriority.allCases, id: \.self) { priority in
                SettingsRow(priority.title) {
                    DirectorSwitch(isOn: Binding(
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
            }
            if model.ticketPrioritiesError != nil {
                CheckErrorPointer(subject: "these ticket priorities")
            }
        }
        .disabledReason(model.canEditTicketPriorities ? nil : Self.waits)
    }

    private var boardStatesBlock: some View {
        SettingsGroup(
            "Board states (saved in symphony.yml)",
            footer: "issues.states.code_review, .qa, .plan_review, .epic_review and .ci_fix. At startup Symphony "
                + "creates a Linear state with each name in your team, and reports the exact name loudly "
                + "when one is missing or renamed instead of creating a duplicate. Renamed a state in "
                + "Linear? Point its field here at the new name. Save checks symphony.yml with symphony "
                + "check first; Symphony reads it when it next starts."
        ) {
            SettingsLine("The Linear workflow states Symphony creates for the board's phases. Nothing moves tickets into them yet.")
            WorkflowStateRow(title: "Code review", name: $model.workflowStates.codeReview)
            WorkflowStateRow(title: "QA", name: $model.workflowStates.qa)
            WorkflowStateRow(title: "Plan review", name: $model.workflowStates.planReview)
            WorkflowStateRow(title: "Epic review", name: $model.workflowStates.epicReview)
            WorkflowStateRow(title: "CI fix", name: $model.workflowStates.ciFix)
            if model.workflowStatesError != nil {
                CheckErrorPointer(subject: "these board states")
            }
        }
        .disabledReason(model.canEditWorkflowStates ? nil : Self.waits)
    }

    private var codeReviewBlock: some View {
        SettingsGroup(
            "Code Review (saved in symphony.yml)",
            footer: "auto_review.acceptance_gate.escalate.ticket_patterns_builtin. The built-in ticket patterns "
                + "match a title or description asking for a human or manual review, saying it must not be "
                + "auto-approved, or that it needs a human. Turn them off when they misfire on your tickets; "
                + "a repo can override this in its Review sheet in Repos. Save checks symphony.yml with symphony check "
                + "first; Symphony reads it on its next poll, no restart needed."
        ) {
            SettingsRow(
                BuiltInTicketPatterns.toggleTitle,
                help: model.ticketPatternsBuiltIn
                    ? BuiltInTicketPatternsChoice.on.explanation
                    : BuiltInTicketPatternsChoice.off.explanation
            ) {
                DirectorSwitch(isOn: $model.ticketPatternsBuiltIn)
            }
            if model.ticketPatternsBuiltInError != nil {
                CheckErrorPointer(subject: "this setting")
            }
        }
        .disabledReason(model.canEditTicketPatternsBuiltIn ? nil : Self.waits)
    }

    private var riskRulesBlock: some View {
        RiskRulesSection(model: model)
    }

    private var phasesBlock: some View {
        PhasesSection(model: model)
    }

    private var timeoutsBlock: some View {
        SettingsGroup(
            "Timeouts (saved in symphony.yml)",
            footer: "workspaces.git_network_timeout_ms (default 5 minutes), execution.timeouts.mcp_tool_ms (default "
                + "10 minutes), watchdog.pending_tool_report_after_ms (default 1 minute) and "
                + "execution.usage_limit.sign_in_ask_after_seconds (default 30 minutes). Save checks "
                + "symphony.yml with symphony check first; Symphony reads them on the next call, no restart "
                + "needed."
        ) {
            TimeoutRow(
                title: "Git network timeout", minutes: $model.gitNetworkTimeoutMinutes,
                help: "Stops a git fetch, pull, push or ls-remote that runs longer, so a remote that stops answering can't hold the repo."
            )
            TimeoutRow(
                title: "MCP tool timeout", minutes: $model.mcpToolTimeoutMinutes,
                help: "Stops one call of Symphony's Linear and GitHub tools that runs longer and answers the agent with an error."
            )
            TimeoutRow(
                title: "Show a pending tool call after", minutes: $model.pendingToolReportMinutes,
                help: "Shows a run as waiting on one of those calls once the call has run this long."
            )
            TimeoutRow(
                title: "Ask me to sign in again after", minutes: $model.signInAskAfterMinutes,
                help: "Asks you in the Inbox once agents have been unable to sign in to their model this long."
            )
            if let error = model.timeoutsError {
                SettingsLine(error, error: true)
            }
        }
        .disabledReason(model.canEditTimeouts ? nil : Self.waits)
    }

    private var gitHubUpdatesBlock: some View {
        SettingsGroup(
            "GitHub updates (saved in symphony.yml)",
            footer: "github.webhooks.fallback_poll_interval_ms (default 5 minutes) and "
                + "github.webhooks.silence_alert_minutes (default 10 minutes). Save checks symphony.yml with "
                + "symphony check first; Symphony reads them on its next check, no restart needed."
        ) {
            SettingsRow(
                "Safety-net check every",
                help: "While GitHub's webhook deliveries arrive, Symphony also checks every PR this often, to catch "
                    + "one a delivery missed. Without deliveries it checks at the poll interval."
            ) {
                NumberField(value: $model.safetyNetCheckMinutes, in: GitHubUpdates.minuteRange, unit: "min")
            }
            SettingsRow("Warn me after no updates for", help: "Shows a warning when no delivery has arrived from GitHub for this long.") {
                NumberField(value: $model.silenceAlertMinutes, in: GitHubUpdates.minuteRange, unit: "min")
            }
            if let error = model.gitHubUpdatesError {
                SettingsLine(error, error: true)
            }
        }
        .disabledReason(model.canEditGitHubUpdates ? nil : Self.waits)
    }

    private var linearWebhooksBlock: some View {
        LinearWebhooksSection(model: model)
    }

    private var dispatchLoopsBlock: some View {
        SettingsGroup(
            "Dispatch loops (saved in symphony.yml)",
            footer: "watchdog.dispatch_loop_runs in watchdog.dispatch_loop_window_ms (default 4 runs in 10 minutes) "
                + "and watchdog.dispatch_loop_long_runs in watchdog.dispatch_loop_long_window_ms (default 8 "
                + "runs in 60 minutes). Save checks symphony.yml with symphony check first; Symphony reads "
                + "them on its next dispatch, no restart needed."
        ) {
            DispatchLoopRow(title: "Hold a ticket after", runs: $model.dispatchLoopRuns, minutes: $model.dispatchLoopWindowMinutes)
            DispatchLoopRow(title: "Or after", runs: $model.dispatchLoopLongRuns, minutes: $model.dispatchLoopLongWindowMinutes)
            SettingsLine(
                "Once a ticket got this many runs of one kind in that time with no state change, new PR head or "
                    + "decision, Symphony starts no more and puts it on a Blocked hold that says why. Unblock it "
                    + "from the Inbox."
            )
            if let error = model.dispatchLoopError {
                SettingsLine(error, error: true)
            }
        }
        .disabledReason(model.canEditDispatchLoop ? nil : Self.waits)
    }

    private var dispatchBlock: some View {
        DispatchSection(model: model)
    }

    private var ledgerBlock: some View {
        SettingsGroup(
            "Ledger (saved in symphony.yml)",
            footer: "ledger.artifact_max_bytes (default 25 MB), ledger.prompt_brief_enabled (default on) and "
                + "ledger.prompt_brief_max_tokens (default 50,000 tokens). Save checks symphony.yml with symphony "
                + "check first; Symphony reads them on its next stored file and agent prompt, no restart needed."
        ) {
            SettingsRow(
                "Largest artifact",
                help: "Symphony keeps every artifact file (screenshots, transcripts) for good, so a ticket's history "
                    + "stays whole. It refuses to store a file larger than the cap."
            ) {
                NumberField(value: $model.artifactMaxMegabytes, in: LedgerSettings.megabyteRange, unit: "MB")
                    .controlLabel("Largest artifact in MB")
            }
            SettingsRow(
                "Give agents the ticket's history summary",
                help: "Every agent starts from a summary of the ticket's whole history: every decision, open finding "
                    + "and note in full. Nothing is left out: a ticket whose summary is over the limit waits for you "
                    + "to choose in the Inbox whether it goes on with the whole summary or is canceled."
            ) {
                DirectorSwitch(isOn: $model.promptBriefEnabled)
            }
            SettingsRow(
                "Summary size limit",
                disabledReason: model.promptBriefEnabled ? nil : "Turn on Give agents the ticket's history summary first"
            ) {
                NumberField(value: $model.promptBriefMaxTokens, in: 1...Int.max, accepts: Self.anyWholeNumber, unit: "tokens")
                    .controlLabel("Summary size limit in tokens")
            }
            if let error = model.ledgerError {
                SettingsLine(error, error: true)
            }
        }
        .disabledReason(model.canEditLedger ? nil : Self.waits)
    }

    private var reportsBlock: some View {
        ReportsSection(model: model)
    }

    private var conductorBlock: some View {
        ConductorSection(settings: $model.conductor, error: model.conductorError, editable: model.canEditConductor)
    }

    private var macAppQABlock: some View {
        MacAppQASection(model: model)
    }

    private var environmentBlock: some View {
        SettingsGroup("Environment (stored in a file only you can read)") {
            // Off until the read fills them in, so nothing typed is overwritten.
            SettingsRow(
                SecretSettings.linearAPIKeyName, error: issue([.linearAPIKeyMissing]),
                disabledReason: model.isLoadingSecrets ? StatusMenu.keychainWaitingLine : nil
            ) {
                DirectorTextField(nil, text: $model.linearAPIKey, placeholder: "lin_api_…", mono: true, secure: true)
                    .frame(width: DesignTokens.SettingsRow.fieldWidth)
            }
            ForEach($model.extraRows) { $row in
                VariableLine(name: $row.name, value: $row.value, secure: true) { model.removeRow(id: row.id) }
            }
            if !model.isLoadingSecrets {
                SettingsLine {
                    Button("Add Variable") { model.addRow() }
                        .directorButton(.quiet, size: .small, glyph: "plus")
                }
            }
        }
    }
}

/// Code Review's risk rules (`auto_review.acceptance_gate.escalate.on_match` and `.size_counts`): per rule, whether
/// its match only tells the reviewer or also asks you once the reviewer approves, and what the change size counts.
private struct RiskRulesSection: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SettingsGroup(
            "Code Review risk rules (saved in symphony.yml)",
            footer: "auto_review.acceptance_gate.escalate.on_match and .size_counts. Code Review reviews each change once. "
                + "A risk rule that matches tells the reviewer what it found, so the review weighs it; set to Ask me, "
                + "an approval it matches also waits for your answer in the Inbox. These apply to every repo. Save "
                + "checks symphony.yml with symphony check first; Symphony reads it on its next poll, no restart needed."
        ) {
            ForEach(RiskRule.allCases) { rule in
                SettingsRow(rule.title, help: rule.explanation) {
                    PopUp(
                        nil, selection: match(rule), choices: RiskRuleMatch.allCases.map { PopUpChoice($0, $0.title) },
                        accessibilityLabel: rule.title
                    )
                }
            }
            SettingsRow(RiskRuleSettings.sizeCountsTitle, help: model.riskRules.sizeCounts.explanation) {
                PopUp(
                    nil, selection: $model.riskRules.sizeCounts, choices: ChangeSizeCount.allCases.map { PopUpChoice($0, $0.title) },
                    accessibilityLabel: RiskRuleSettings.sizeCountsTitle
                )
            }
            if model.riskRulesError != nil {
                CheckErrorPointer(subject: "these risk rules")
            }
        }
        .disabledReason(model.canEditRiskRules ? nil : SettingsView.waits)
    }

    private func match(_ rule: RiskRule) -> Binding<RiskRuleMatch> {
        Binding(
            get: { model.riskRules.match(for: rule) },
            set: { model.riskRules.onMatch[rule] = $0 }
        )
    }
}

/// The `macos_app` QA playbook: the tools the QA host needs and the variables the app under test gets
/// (`auto_review.playbooks.macos_app.requires` and `launch_env`), the QA target it judges the app at: the window size
/// and appearance (`window_width`, `window_height` and `appearance`), and the project's own server
/// (`verification.dev_server`, with `dev_server_port` for its port on the QA host). The tools are a group of their
/// own, since they wait on their own read of symphony.yml; the project's server is one group too.
private struct MacAppQASection: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.SettingsRow.groupsGap) {
            SettingsGroup("macOS app QA (saved in symphony.yml)") {
                SettingsRow(
                    "QA host tools",
                    help: "The programs a macOS app QA pass needs on the QA host, comma-separated. Symphony looks for "
                        + "each when the pass starts; a missing one blocks the pass, and self-heal files the fix "
                        + "for the QA host.",
                    disabledReason: model.canEditQAHostTools ? nil : SettingsView.waits
                ) {
                    DirectorTextField(nil, text: $model.qaHostToolsText, placeholder: "e.g. go, pg_ctl", mono: true)
                        .frame(width: DesignTokens.SettingsRow.fieldWidth)
                }
                if model.qaHostToolsError != nil {
                    CheckErrorPointer(subject: "these QA host tools")
                }
            }
            SettingsGroup(
                footer: "auto_review.playbooks.macos_app.requires (default none), window_width and window_height (default "
                    + "2560 × 1440), appearance (default dark) and launch_env (default none). A repository's WORKFLOW.md "
                    + "can set them too, and wins. scripts/qa-vm/provision.sh installs Go, Postgres and jq on a QA VM. Save checks "
                    + "symphony.yml with symphony check first; the next QA pass uses them."
            ) {
                qaTargetControls
                appEnvironmentControls
            }
            .disabledReason(model.canEditMacAppQA ? nil : SettingsView.waits)
            SettingsGroup("Project server") {
                projectServerControls
            }
            .disabledReason(model.canEditMacAppQA ? nil : SettingsView.waits)
        }
    }

    /// The QA target: the window size and the appearance QA launches the app in.
    @ViewBuilder private var qaTargetControls: some View {
        sizeField("QA target window width in points", key: "window_width", value: \.windowWidth)
        sizeField("QA target window height in points", key: "window_height", value: \.windowHeight)
        SettingsRow("QA target appearance") {
            SegmentedControl(
                "QA target appearance",
                selection: $model.macAppQA.appearance,
                segments: [Segment("light", "Light"), Segment("dark", "Dark")]
            )
            .help("auto_review.playbooks.macos_app.appearance")
        }
    }

    /// A whole-number field for one of the QA target window's sizes.
    private func sizeField(_ label: String, key: String, value: WritableKeyPath<MacAppQAPlaybook, Int>) -> some View {
        SettingsRow(label) {
            NumberField(
                value: Binding(get: { model.macAppQA[keyPath: value] }, set: { model.macAppQA[keyPath: value] = $0 }),
                in: 1...Int.max, accepts: SettingsView.anyWholeNumber
            )
            .help("auto_review.playbooks.macos_app.\(key)")
        }
    }

    /// The project's own server, `verification.dev_server`: one row for each of its settings, the rule for when it
    /// runs among them, the port it listens on when it runs on the QA host, and the block's save error.
    @ViewBuilder private var projectServerControls: some View {
        SettingsRow("When it runs") {
            PopUp(
                nil, selection: $model.macAppQA.projectServer.runs,
                choices: ProjectServerRuns.allCases.map { PopUpChoice($0, $0.title) },
                help: "verification.dev_server.runs", accessibilityLabel: "When the project server runs"
            )
        }
        SettingsRow("Build command") {
            DirectorTextField(
                nil,
                text: Binding(
                    get: { model.macAppQA.projectServer.buildCmd ?? "" },
                    set: { model.macAppQA.projectServer.buildCmd = $0.isEmpty ? nil : $0 }
                ),
                placeholder: "None", mono: true
            )
            .frame(width: DesignTokens.SettingsRow.fieldWidth)
            .help("verification.dev_server.build_cmd")
        }
        SettingsRow("Start command") {
            DirectorTextField(nil, text: $model.macAppQA.projectServer.startCmd, mono: true)
                .frame(width: DesignTokens.SettingsRow.fieldWidth)
                .help("verification.dev_server.start_cmd")
        }
        SettingsRow("Health check URL") {
            DirectorTextField(nil, text: $model.macAppQA.projectServer.healthCheckURL, mono: true)
                .frame(width: DesignTokens.SettingsRow.fieldWidth)
                .help("verification.dev_server.health_check_url")
        }
        SettingsRow("Health check timeout") {
            NumberField(
                value: $model.macAppQA.projectServer.healthTimeoutMs, in: 1...Int.max, accepts: SettingsView.anyWholeNumber,
                step: 1_000, unit: "ms"
            )
            .help("verification.dev_server.health_timeout_ms")
        }
        SettingsRow("Stop signal") {
            PopUp(
                nil, selection: $model.macAppQA.projectServer.stopSignal,
                choices: ProjectServerStopSignal.allCases.map { PopUpChoice($0, $0.rawValue) },
                help: "verification.dev_server.stop_signal", accessibilityLabel: "Stop signal"
            )
        }
        SettingsRow("Stop timeout") {
            NumberField(
                value: $model.macAppQA.projectServer.stopTimeoutMs, in: 0...Int.max, accepts: SettingsView.anyWholeNumber,
                step: 1_000, unit: "ms"
            )
            .help("verification.dev_server.stop_timeout_ms")
        }
        SettingsRow("Port on the QA host") {
            NumberField(value: $model.macAppQA.devServerPort, in: 1...65_535, accepts: SettingsView.anyWholeNumber)
                .help("auto_review.playbooks.macos_app.dev_server_port")
        }
        if let error = model.macAppQAError {
            SettingsLine(error, error: true)
        }
    }

    /// The variables the app under test gets.
    @ViewBuilder private var appEnvironmentControls: some View {
        SettingsLine {
            Text("App environment")
                .textStyle(.rowTitle)
                .foregroundStyle(DesignTokens.TextColor.primary.color)
        }
        ForEach($model.macAppQA.launchEnv) { $variable in
            VariableLine(name: $variable.name, value: $variable.value, secure: false) {
                model.removeLaunchVariable(id: variable.id)
            }
        }
        SettingsLine {
            Button("Add Variable") { model.addLaunchVariable() }
                .directorButton(.quiet, size: .small, glyph: "plus")
        }
        SettingsLine(
            "QA sets these on the app after its own variables; $SYMPHONY_VERIFICATION_PORT becomes the port. "
                + "They are saved in plain text, so never put a secret here."
        )
    }
}

/// D14: one switch per kind of notification, kept in the app's defaults and read at each poll.
private struct NotificationsSection: View {
    @State private var preferences = NotificationPreferences.load(from: AppStores.current.defaults)

    var body: some View {
        SettingsGroup(
            "Notifications",
            footer: "One notification for each new thing that waits on you and each new problem, never twice for the same "
                + "one, and nothing for routine progress."
        ) {
            ForEach(NoticeKind.allCases, id: \.self) { kind in
                SettingsRow(kind.settingsTitle) {
                    DirectorSwitch(isOn: Binding(
                        get: { preferences.isOn(kind) },
                        set: { on in
                            preferences.set(kind, on: on)
                            preferences.save(to: AppStores.current.defaults)
                        }
                    ))
                }
            }
        }
    }
}

/// The last update check under Check for releases every N minutes, with Check Now (S1a–S1d): a spinner while it
/// checks, and `note` in its place once after the minutes were moved into range.
struct ReleaseCheckLine: View {
    let schedule: UpdateCheckSchedule
    let note: String?
    let checkNow: () -> Void

    var body: some View {
        SettingsLine {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                HStack(spacing: DesignTokens.SettingsRow.columnGap) {
                    if schedule.isChecking {
                        ProgressView().controlSize(.small)
                    }
                    FieldFootnote(footnote: .help(
                        schedule.isChecking ? UpdateCheckSchedule.checkingLine
                            : note ?? schedule.settingsLine(now: context.date, calendar: .current)
                    ))
                    Spacer(minLength: 0)
                    // Gone while a check runs: the line says it checks.
                    if !schedule.isChecking {
                        Button("Check Now", action: checkNow)
                            .directorButton(.secondary, size: .small)
                            .fixedSize()
                    }
                }
            }
        }
    }
}

/// One line in a section saying `symphony check` rejected `subject`, such as "these models", and that the reason
/// shows in full above Save.
private struct CheckErrorPointer: View {
    let subject: String

    var body: some View {
        SettingsLine("symphony check rejected \(subject); the reason shows above Save.", error: true)
    }
}

/// A timeout in whole minutes over `OperationTimeouts.minuteRange`, with what it does under its title.
private struct TimeoutRow: View {
    let title: String
    @Binding var minutes: Int
    let help: String

    var body: some View {
        SettingsRow(title, help: help) {
            NumberField(value: $minutes, in: OperationTimeouts.minuteRange, unit: "minutes")
        }
    }
}

/// `linear.webhooks`: whether Symphony accepts Linear's webhook deliveries, and the signing secret it checks them with,
/// named by its environment variable or typed in a secure field. The secret's value is never shown.
private struct LinearWebhooksSection: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SettingsGroup(
            "Linear webhooks (saved in symphony.yml)",
            footer: "linear.webhooks.enabled (default off) and linear.webhooks.secret. Save checks symphony.yml with "
                + "symphony check first, which refuses the webhook on without a secret; Symphony reads them on the "
                + "next delivery, no restart needed."
        ) {
            SettingsRow("Accept Linear's webhook deliveries") { DirectorSwitch(isOn: $model.linearWebhooksEnabled) }
            SettingsRow("Signing secret") {
                SegmentedControl(
                    "Signing secret", selection: $model.linearWebhookSecretSource,
                    segments: [
                        Segment(LinearWebhookSettings.SecretSource.environment, "Environment variable"),
                        Segment(LinearWebhookSettings.SecretSource.literal, "Typed in symphony.yml"),
                    ]
                )
            }
            switch model.linearWebhookSecretSource {
            case .environment:
                SettingsRow(
                    "Variable",
                    help: "symphony.yml names the variable, never the value. Add the variable under Environment with the "
                        + "signing secret Linear shows for the webhook; Symphony reads it when it starts."
                ) {
                    HStack(spacing: DesignTokens.Space.s1) {
                        Text("$")
                            .font(DesignTokens.TypeStyle.monoFont(weight: DesignTokens.Field.textWeight))
                            .foregroundStyle(DesignTokens.TextColor.secondary.color)
                            .accessibilityHidden(true)
                        DirectorTextField(
                            nil, text: $model.linearWebhookSecretName, placeholder: LinearWebhookSettings.suggestedEnvironmentName,
                            mono: true
                        )
                        .frame(width: DesignTokens.SettingsRow.fieldWidth)
                        .controlLabel("Signing secret's environment variable")
                    }
                }
            case .literal:
                SettingsRow(
                    "Secret",
                    help: "The secret is saved in symphony.yml in plain text. An environment variable keeps it out of the file."
                ) {
                    DirectorTextField(nil, text: $model.linearWebhookSecretLiteral, placeholder: "Linear's signing secret", secure: true)
                        .frame(width: DesignTokens.SettingsRow.fieldWidth)
                        .controlLabel("Signing secret")
                }
            }
            SettingsLine(
                "Linear signs every delivery with the webhook's secret, and Symphony refuses one it can't check. "
                    + "Setup shows whether deliveries arrive."
            )
            if let error = model.linearWebhooksError {
                SettingsLine(error, error: true)
            }
        }
        .disabledReason(model.canEditLinearWebhooks ? nil : SettingsView.waits)
    }
}

/// `reports.model`: the model a status report is written with; `reports.cadence`, how often one is written on its own;
/// `reports.triggers.*`, the events that start one at once.
private struct ReportsSection: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SettingsGroup(
            "Reports (saved in symphony.yml)",
            footer: "reports.model (default \(ReportSettings.defaultModel)), reports.cadence (default six_hours) and "
                + "reports.triggers (a ticket shipped and the factory paused by a rule on by default). Save checks "
                + "symphony.yml with symphony check first; Symphony reads it within the hour, no restart needed."
        ) {
            SettingsRow(
                "Report model",
                help: "A status report reads a period's notable events and cites each one it rests on. It asks you at most "
                    + "one question in the Inbox and changes nothing else, so the cheapest capable model is enough."
            ) {
                DirectorTextField(nil, text: $model.reportModel, placeholder: ReportSettings.defaultModel, mono: true)
                    .frame(width: DesignTokens.SettingsRow.fieldWidth)
                    .help("The model a status report is written with (reports.model)")
            }
            SettingsRow("Write a report") {
                PopUp(
                    nil, selection: $model.reportCadence, choices: ReportCadence.allCases.map { PopUpChoice($0, $0.title) },
                    help: "How often Symphony writes a status report on its own, on the UTC clock (reports.cadence)",
                    accessibilityLabel: "Report cadence"
                )
            }
            SettingsLine("Also write a report at once when:")
            ForEach(ReportTrigger.allCases) { trigger in
                SettingsRow(trigger.title) {
                    DirectorSwitch("Report when \(trigger.title.lowercased())", isOn: Binding(
                        get: { model.reportTriggers[trigger] ?? trigger.defaultOn },
                        set: { model.reportTriggers[trigger] = $0 }
                    ))
                    .help("reports.triggers.\(trigger.rawValue)")
                }
            }
            SettingsLine(
                "Each report covers the time since the previous one. Triggers within a minute of a report start no "
                    + "second one, and the Linear project update reads the newest report."
            )
            if let error = model.reportsError {
                SettingsLine(error, error: true)
            }
        }
        .disabledReason(model.canEditReports ? nil : SettingsView.waits)
    }
}

/// `dispatch`: whether dispatch reads its candidates from the Linear poll or from Symphony's record, how many poll
/// cycles Setup's Dispatch shadow line counts their differences over, and `linear.reconcile_interval_ms`, how often the
/// Linear poll reconciles the record while dispatch reads it, in minutes.
private struct DispatchSection: View {
    @ObservedObject var model: SettingsViewModel

    var body: some View {
        SettingsGroup(
            "Dispatch (saved in symphony.yml)",
            footer: "dispatch.source (default the Linear poll), dispatch.shadow_window (default 20 cycles, at least 1) and "
                + "linear.reconcile_interval_ms (default 5 minutes, at least 1). Save checks symphony.yml with "
                + "symphony check first; Symphony reads them on its next poll cycle, no restart needed."
        ) {
            SettingsRow("Dispatch from") {
                PopUp(
                    nil, selection: $model.dispatchSource,
                    choices: DispatchSettings.Source.allCases.map { PopUpChoice($0, $0.title) }, accessibilityLabel: "Dispatch from"
                )
            }
            SettingsRow(
                "Shadow window",
                help: "Every poll cycle Symphony also works out the candidates from its own record and compares them with "
                    + "the poll's. Setup shows the differences over the window. Move dispatch to the record once the "
                    + "window stays at zero, and back to the poll if anything looks wrong."
            ) {
                NumberField(value: $model.dispatchShadowWindow, in: 1...Int.max, accepts: SettingsView.anyWholeNumber, unit: "cycles")
                    .controlLabel("Shadow window in poll cycles")
            }
            SettingsRow(
                "Reconcile every",
                help: "While dispatch reads the record, the Linear poll only reconciles it with Linear, at this interval: it "
                    + "applies changes made in Linear and moves back tickets moved by hand. Setup's Reconcile line shows "
                    + "what it did."
            ) {
                NumberField(
                    value: $model.dispatchReconcileMinutes, in: 1...Int.max, accepts: SettingsView.anyWholeNumber, unit: "minutes"
                )
                .controlLabel("Reconcile interval in minutes")
            }
            if let error = model.dispatchError {
                SettingsLine(error, error: true)
            }
        }
        .disabledReason(model.canEditDispatch ? nil : SettingsView.waits)
    }
}

/// A dispatch-loop limit: a number of runs and a window in whole minutes, each a number field with its stepper.
private struct DispatchLoopRow: View {
    let title: String
    @Binding var runs: Int
    @Binding var minutes: Int

    var body: some View {
        SettingsRow(title) {
            HStack(spacing: DesignTokens.NumberField.unitGap) {
                NumberField(value: $runs, in: DispatchLoopLimits.runRange, unit: "runs in")
                    .controlLabel("\(title) runs")
                NumberField(value: $minutes, in: DispatchLoopLimits.minuteRange, unit: "minutes")
                    .controlLabel("\(title) minutes")
            }
        }
    }
}

/// A switch for a token cap and, while it's on, the number of tokens with a hint such as "1,000,000,000 = 1B", in the
/// problem colour while the text is no whole number.
private struct TokenLimitRows: View {
    let toggleTitle: String
    let fieldTitle: String
    @Binding var field: TokenLimitField
    let disabledReason: String?

    var body: some View {
        SettingsRow(toggleTitle, disabledReason: disabledReason) { DirectorSwitch(isOn: $field.isOn) }
        if field.isOn {
            SettingsRow(
                fieldTitle, help: field.limit == nil ? nil : "tokens, \(field.hint)", error: field.limit == nil ? field.hint : nil,
                disabledReason: disabledReason
            ) {
                DirectorTextField(nil, text: $field.text, placeholder: "1000000000", mono: true)
                    .frame(width: DesignTokens.SettingsRow.fieldWidth)
            }
        }
    }
}

/// One `issues.states.*` phase state: the Linear state name the board creates for that phase.
private struct WorkflowStateRow: View {
    let title: String
    @Binding var name: String

    var body: some View {
        SettingsRow(title) {
            DirectorTextField(nil, text: $name, placeholder: "State name")
                .frame(width: DesignTokens.SettingsRow.fieldWidth)
        }
    }
}

/// An environment variable on a line of its own: its name and its value, each a text field, and the button that
/// removes it. `secure` masks the value, for a secret.
private struct VariableLine: View {
    @Binding var name: String
    @Binding var value: String
    let secure: Bool
    let remove: () -> Void

    var body: some View {
        SettingsLine {
            HStack(spacing: DesignTokens.Space.s2) {
                DirectorTextField(nil, text: $name, placeholder: "NAME", mono: true)
                    .controlLabel("Name")
                DirectorTextField(nil, text: $value, placeholder: "Value", secure: secure)
                    .controlLabel("Value")
                IconButton("minus.circle", help: "Remove this variable", size: .small, action: remove)
            }
        }
    }
}

/// A path in a text field with Choose…, which opens a panel to pick it, and the reason Save refused it under its title.
private struct PathRow: View {
    let title: String
    @Binding var path: String
    let choosesDirectories: Bool
    var error: String?

    var body: some View {
        SettingsRow(title, error: error) {
            HStack(spacing: DesignTokens.Space.s2) {
                DirectorTextField(nil, text: $path, placeholder: "/path/to/…", mono: true)
                    .frame(width: DesignTokens.SettingsRow.fieldWidth)
                // The button keeps its title whole: the row's label gives up the room first (TP-1576).
                Button("Choose…", action: choose)
                    .directorButton(.secondary)
                    .fixedSize()
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
