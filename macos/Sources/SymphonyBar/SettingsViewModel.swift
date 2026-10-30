import Foundation
import SymphonyBarCore

/// An editable extra environment variable row. The id keeps SwiftUI rows stable while names change.
struct EnvironmentRow: Identifiable {
    let id = UUID()
    var name: String
    var value: String
}

/// Runs `symphony check` on a symphony.yml at the given path with the form's settings and secrets.
typealias SettingsConfigCheck = (_ configPath: String, AppSettings, SecretSettings) async -> ConfigCheckResult

/// Form state for the Settings window. Loads on creation and saves only when everything validates.
@MainActor
final class SettingsViewModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var linearAPIKey = ""
    @Published var openRouterAPIKey = "" {
        didSet {
            guard openRouterAPIKey != oldValue else { return }
            openRouterResult = nil
            // A key entered into an empty field loads the list the Models pickers need, unless one is loaded.
            if oldValue.isEmpty && !openRouterAPIKey.isEmpty, !hasOpenRouterModelList { loadOpenRouterModels() }
        }
    }
    /// The last Test connection result: the key's label and credit, or why it failed.
    @Published private(set) var openRouterResult: Result<OpenRouterKeyInfo, OpenRouterFailure>?
    /// "312 models, 141 support tools", or why the model list couldn't be loaded.
    @Published private(set) var openRouterModels: Result<String, OpenRouterFailure>?
    /// OpenRouter's models for the Models pickers, loaded while an OpenRouter key is entered.
    @Published private(set) var openRouterModelList: Result<[OpenRouterModel], OpenRouterFailure>?
    @Published private(set) var isLoadingOpenRouterModels = false
    @Published private(set) var isTestingOpenRouter = false
    @Published var extraRows: [EnvironmentRow] = []
    /// Launch at Login, read from macOS rather than UserDefaults so it follows changes made in System Settings.
    @Published var launchAtLogin: Bool
    @Published private(set) var loginItemNote: String?
    @Published private(set) var loginItemError: String?
    @Published private(set) var issues: [SettingsIssue] = []
    @Published private(set) var secretsError: String?
    /// True until the secrets have been read, which can wait on a Keychain prompt while they move out of the
    /// Keychain. Save stays off until then, so an empty form can't overwrite them.
    @Published private(set) var isLoadingSecrets = true
    /// `agent.concurrency.max_total` in the configured symphony.yml. Saved to that file, not UserDefaults.
    @Published var maxConcurrentAgents = MaxConcurrentAgents.symphonyDefault
    /// `agent.provider`, `.model`, `.effort` and `.run_profiles` in the configured symphony.yml, and the same
    /// keys under each `repositories[].agent`, plus `agent.small_model`.
    @Published var runProfiles = ScopedRunProfiles()
    /// The `agent` block the Models rows edit: the top-level one or a repository's.
    @Published var runProfilesScope = RunProfilesScope.global
    /// The `repositories[]` keys, in file order, for the scope picker.
    @Published private(set) var repositoryKeys: [String] = []
    /// The `--model` / `--effort` in `agent.command`, which runs use while the Default row is set to default.
    @Published private(set) var commandProfile = RunProfile()
    @Published private(set) var configFileError: String?
    /// Why `symphony check` rejected the changed models, shown in the Models section.
    @Published private(set) var configCheckError: String?
    /// The row whose OpenRouter model list is open (its run kind, or "default"), and the list's search text.
    @Published var openRouterPickerRow: String?
    @Published var openRouterQuery = ""
    /// `agent.limits.tokens_per_day` and `.tokens_per_issue` in the configured symphony.yml. A change is checked
    /// with `symphony check` shortly after the last edit.
    @Published var dailyTokenLimit = TokenLimitField(.tokens(TokenLimits.defaultPerDay), default: TokenLimits.defaultPerDay) {
        didSet { if dailyTokenLimit != oldValue { checkTokenLimits() } }
    }
    @Published var issueTokenLimit = TokenLimitField(.tokens(TokenLimits.defaultPerIssue), default: TokenLimits.defaultPerIssue) {
        didSet { if issueTokenLimit != oldValue { checkTokenLimits() } }
    }
    /// Why `symphony check` rejects the changed token limits. Save stays off while it's set.
    @Published private(set) var tokenLimitsError: String?
    /// True while `symphony check` runs on the changed token limits.
    @Published private(set) var isCheckingTokenLimits = false
    /// `tickets.priorities` in the configured symphony.yml: the Linear priorities allowed to start
    /// new work. Empty means every priority may.
    @Published var ticketPriorities = TicketPriorities()
    /// Why `symphony check` rejected the changed ticket priorities, shown in their section.
    @Published private(set) var ticketPrioritiesError: String?
    /// `auto_review.playbooks.macos_app.requires` in the configured symphony.yml, as the field shows it: the
    /// executables a macOS app QA pass needs on the QA host, comma-separated.
    @Published var qaHostToolsText = ""
    /// Why `symphony check` rejected the changed QA host tools, shown in their section.
    @Published private(set) var qaHostToolsError: String?
    /// `issues.states.*` in the configured symphony.yml: the machine-owned phase states the board
    /// creates at startup. Nothing dispatches on them yet.
    @Published var workflowStates = WorkflowStates()
    /// Why `symphony check` rejected the changed board states, shown in their section.
    @Published private(set) var workflowStatesError: String?
    /// `auto_review.acceptance_gate.escalate.ticket_patterns_builtin` in the configured symphony.yml: whether Code
    /// Review's built-in ticket patterns send a ticket to a person.
    @Published var ticketPatternsBuiltIn = BuiltInTicketPatterns.defaultIsOn
    /// Why `symphony check` rejected the changed built-in ticket patterns setting, shown above Save.
    @Published private(set) var ticketPatternsBuiltInError: String?
    /// `auto_review.acceptance_gate.escalate.on_match.*` and `.size_counts` in the configured symphony.yml: what
    /// each of Code Review's risk rules does when it matches, and what the change-size rule counts.
    @Published var riskRules = RiskRuleSettings()
    /// Why `symphony check` rejected the changed risk rule settings, shown above Save.
    @Published private(set) var riskRulesError: String?
    /// Today's tokens from Symphony's latest state, nil while it isn't answering.
    @Published var budget: StateSnapshot.Budget?
    /// Why this copy can't install updates with Development mode on or off, nil when it can.
    var updateBlocker: (_ developmentMode: Bool) -> String? = { _ in nil }
    /// Called after the settings are stored.
    var onSettingsSaved: (AppSettings) -> Void = { _ in }
    /// Shown once in place of the last-check line after a typed check interval was moved into range (S1d).
    @Published var releaseCheckNote: String?

    /// `workspaces.git_network_timeout_ms`, `agent.timeouts.mcp_tool_ms` and `watchdog.pending_tool_report_after_ms`
    /// in the configured symphony.yml, in minutes.
    @Published var gitNetworkTimeoutMinutes = OperationTimeouts.minutes(OperationTimeouts.defaultGitNetworkMs)
    @Published var mcpToolTimeoutMinutes = OperationTimeouts.minutes(OperationTimeouts.defaultMcpToolMs)
    @Published var pendingToolReportMinutes = OperationTimeouts.minutes(OperationTimeouts.defaultPendingToolReportMs)
    /// Why `symphony check` rejected the changed timeouts, shown in their section.
    @Published private(set) var timeoutsError: String?
    /// `github.webhooks.fallback_poll_interval_ms` and `github.webhooks.silence_alert_minutes` in the configured
    /// symphony.yml, in minutes: how often Symphony checks GitHub while webhook deliveries arrive, and how long it
    /// waits without one before warning.
    @Published var safetyNetCheckMinutes = GitHubUpdates.minutes(GitHubUpdates.defaultFallbackPollMs)
    @Published var silenceAlertMinutes = GitHubUpdates.defaultSilenceAlertMinutes
    /// Why `symphony check` rejected the changed GitHub update settings, shown in their section.
    @Published private(set) var gitHubUpdatesError: String?
    /// `watchdog.dispatch_loop_*` in the configured symphony.yml: the runs of one kind a ticket may get without
    /// progress within each window, in minutes, before Symphony holds it instead of dispatching it again.
    @Published var dispatchLoopRuns = DispatchLoopLimits.defaultRuns
    @Published var dispatchLoopWindowMinutes = DispatchLoopLimits.minutes(DispatchLoopLimits.defaultWindowMs)
    @Published var dispatchLoopLongRuns = DispatchLoopLimits.defaultLongRuns
    @Published var dispatchLoopLongWindowMinutes = DispatchLoopLimits.minutes(DispatchLoopLimits.defaultLongWindowMs)
    /// Why `symphony check` rejected the changed dispatch-loop limits, shown in their section.
    @Published private(set) var dispatchLoopError: String?
    /// `dispatch.source` in the configured symphony.yml: whether dispatch reads its candidates from the Linear poll or
    /// from Symphony's record.
    @Published var dispatchSource = DispatchSettings.defaultSource
    /// `dispatch.shadow_window`: how many poll cycles Setup's Dispatch shadow line counts its differences over.
    @Published var dispatchShadowWindow = DispatchSettings.defaultShadowWindow
    /// `linear.reconcile_interval_ms`, in whole minutes: how often the Linear poll reconciles the record while
    /// dispatch reads it.
    @Published var dispatchReconcileMinutes = DispatchSettings.reconcileMinutes(DispatchSettings.defaultReconcileIntervalMs)
    /// Why the dispatch settings weren't saved, shown in their section.
    @Published private(set) var dispatchError: String?
    /// `linear.webhooks.enabled` in the configured symphony.yml: whether Symphony accepts Linear's webhook deliveries.
    @Published var linearWebhooksEnabled = LinearWebhookSettings.defaultEnabled
    /// `linear.webhooks.secret`: an environment variable's name (written `$NAME`) or the secret itself. The literal
    /// sits in a secure field and is never shown or logged.
    @Published var linearWebhookSecretSource = LinearWebhookSettings.SecretSource.environment
    @Published var linearWebhookSecretName = ""
    @Published var linearWebhookSecretLiteral = ""
    /// Why the Linear webhook settings weren't saved, shown in their section.
    @Published private(set) var linearWebhooksError: String?
    /// `ledger.artifact_max_bytes` in the configured symphony.yml: the largest file Symphony stores, in MB.
    @Published var artifactMaxMegabytes = LedgerSettings.megabytes(LedgerSettings.defaultMaxBytes)
    /// `ledger.prompt_brief_enabled` and `ledger.prompt_brief_max_tokens`: whether agents get the summary of the
    /// ticket's history, and the size in tokens over which Symphony warns about one (it still gives it whole).
    @Published var promptBriefEnabled = LedgerSettings.defaultBriefEnabled
    @Published var promptBriefMaxTokens = LedgerSettings.defaultBriefMaxTokens
    /// Why `symphony check` rejected the changed ledger settings, shown in their section.
    @Published private(set) var ledgerError: String?
    /// `auto_review.playbooks.macos_app.dev_server`, `dev_server_port` and `launch_env` in the configured
    /// symphony.yml: whether a macOS app QA pass on the QA host starts the project's dev server there, on which port,
    /// and the variables the app under test gets.
    @Published var macAppQA = MacAppQAPlaybook()
    /// Why `symphony check` rejected the changed macOS app QA settings, shown in their section.
    @Published private(set) var macAppQAError: String?
    /// True while Save waits for `symphony check`.
    @Published private(set) var isSaving = false

    /// The value read from symphony.yml, or nil when it couldn't be read. The file is written only when the
    /// stepper moved away from it, so an untouched form never edits symphony.yml.
    private var loadedMaxConcurrentAgents: Int?

    /// The profiles read from symphony.yml, or nil when they couldn't be read. Only fields changed from these
    /// are written.
    private var loadedRunProfiles: ScopedRunProfiles?

    /// The limits read from symphony.yml, or nil when they couldn't be read. Only limits changed from these
    /// are written.
    private var loadedTokenLimits: TokenLimits?

    /// The timeouts read from symphony.yml, or nil when they couldn't be read. Only a timeout whose stepper
    /// moved is written.
    private var loadedTimeouts: OperationTimeouts?

    /// The GitHub update settings read from symphony.yml, or nil when they couldn't be read. Only a setting whose
    /// stepper moved is written.
    private var loadedGitHubUpdates: GitHubUpdates?

    /// The dispatch-loop limits read from symphony.yml, or nil when they couldn't be read. Only a limit whose
    /// stepper moved is written.
    private var loadedDispatchLoopLimits: DispatchLoopLimits?

    /// The dispatch settings read from symphony.yml, or nil when they couldn't be read. Only a setting whose control
    /// moved is written.
    private var loadedDispatchSettings: DispatchSettings?

    /// The Linear webhook settings read from symphony.yml, or nil when they couldn't be read. Only a setting that
    /// changed is written.
    private var loadedLinearWebhooks: LinearWebhookSettings?

    /// The ledger settings read from symphony.yml, or nil when they couldn't be read. Only a setting whose control
    /// moved is written.
    private var loadedLedgerSettings: LedgerSettings?

    /// The macOS app QA settings read from symphony.yml, or nil when they couldn't be read. Only a setting that
    /// changed is written.
    private var loadedMacAppQA: MacAppQAPlaybook?

    /// The allowed ticket priorities read from symphony.yml, or nil when they couldn't be read. Only
    /// a change from these is written.
    private var loadedTicketPriorities: TicketPriorities?

    /// The QA host tools read from symphony.yml, or nil when they couldn't be read. Only a change from these is
    /// written.
    private var loadedQAHostTools: QAHostTools?

    /// The board states read from symphony.yml, or nil when they couldn't be read. Only a name changed
    /// from these is written.
    private var loadedWorkflowStates: WorkflowStates?

    /// The built-in ticket patterns setting read from symphony.yml, or nil when it couldn't be read. It is
    /// written only when the toggle moved away from it.
    private var loadedTicketPatternsBuiltIn: Bool?

    /// The risk rule settings read from symphony.yml, or nil when they couldn't be read. Only what changed from
    /// these is written.
    private var loadedRiskRules: RiskRuleSettings?

    /// The pending or running `symphony check` on the changed token limits.
    private var tokenLimitsCheck: Task<Void, Never>?

    /// Extra variable names known to be stored. Only these can be removed on save, so a failed
    /// load never turns into deletions.
    private var storedNames: Set<String> = []

    /// The secrets as read from the store, or nil when the read failed. Saving different secrets restarts
    /// Symphony so it picks them up.
    private var loadedSecrets: SecretSettings?

    private let store: SettingsStore
    private let secrets: SecretsReader
    private let validator: SettingsValidator
    private let loginItem: LoginItemService
    private let openRouter: OpenRouterClient
    private let configCheck: SettingsConfigCheck
    private let onSecretsChanged: () -> Void

    init(
        store: SettingsStore = AppStores.current.settingsStore(),
        secrets: SecretsReader? = nil,
        validator: SettingsValidator = SettingsValidator(embeddedSymphonyPath: SymphonyRunner.embeddedSymphonyPath),
        loginItem: LoginItemService = AppStores.current.loginItem,
        openRouter: OpenRouterClient = OpenRouterClient(baseURL: AppStores.current.openRouterBaseURL),
        configCheck: @escaping SettingsConfigCheck = SettingsViewModel.runConfigCheck,
        onSecretsChanged: @escaping () -> Void = {}
    ) {
        self.store = store
        self.secrets = secrets ?? SecretsReader(load: store.loadSecrets)
        self.validator = validator
        self.loginItem = loginItem
        self.openRouter = openRouter
        self.configCheck = configCheck
        self.onSecretsChanged = onSecretsChanged
        settings = store.loadSettings()
        let loginStatus = loginItem.status
        launchAtLogin = LoginItem.isOn(loginStatus)
        loginItemNote = LoginItem.note(loginStatus)

        loadMaxConcurrentAgents()
        loadTokenLimits()
        loadTicketPriorities()
        loadQAHostTools()
        loadWorkflowStates()
        loadTicketPatternsBuiltIn()
        loadRiskRules()
        loadTimeouts()
        loadGitHubUpdates()
        loadLinearWebhooks()
        loadDispatchLoopLimits()
        loadDispatchSettings()
        loadLedgerSettings()
        loadMacAppQA()
        loadRunProfiles()
        // Off the main thread, so a Keychain prompt can't freeze the app while Settings opens.
        self.secrets.read { [weak self] result in self?.showSecrets(result) }
    }

    /// Fills the secret fields from the read. A failed read leaves `storedNames` empty, so Save can't delete
    /// anything stored.
    private func showSecrets(_ result: Result<SecretSettings, Error>) {
        isLoadingSecrets = false
        switch result {
        case .success(let secrets):
            linearAPIKey = secrets.linearAPIKey
            // Setting a non-empty key loads the OpenRouter model list.
            openRouterAPIKey = secrets.openRouterAPIKey
            extraRows = secrets.extraEnvironment.map { EnvironmentRow(name: $0.name, value: $0.value) }
            storedNames = Self.storedNames(secrets)
            loadedSecrets = secrets.trimmed()
        case .failure(let error):
            secretsError = "Could not read the secrets: \(error)"
        }
    }

    /// The stepper is off until a symphony.yml has been read.
    var canEditMaxConcurrentAgents: Bool { loadedMaxConcurrentAgents != nil }

    private func loadMaxConcurrentAgents() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let value = try SymphonyConfigFile(path: path).readMaxConcurrentAgents() ?? MaxConcurrentAgents.symphonyDefault
            maxConcurrentAgents = value
            loadedMaxConcurrentAgents = value
        } catch {
            configFileError = "Could not read max_total from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// The token limit switches and fields are off until a symphony.yml and the secrets `symphony check` runs
    /// with have been read, and while Save checks it.
    var canEditTokenLimits: Bool { loadedTokenLimits != nil && !isLoadingSecrets && !isSaving }

    private func loadTokenLimits() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let limits = try SymphonyConfigFile(path: path).readTokenLimits()
            // Before the fields, so filling them in doesn't start a check.
            loadedTokenLimits = limits
            dailyTokenLimit = TokenLimitField(limits.perDay, default: TokenLimits.defaultPerDay)
            issueTokenLimit = TokenLimitField(limits.perIssue, default: TokenLimits.defaultPerIssue)
        } catch {
            configFileError = "Could not read the token limits from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// The limits in the form, or nil while a field that's switched on holds no whole number.
    private var formTokenLimits: TokenLimits? {
        guard let perDay = dailyTokenLimit.limit, let perIssue = issueTokenLimit.limit else { return nil }
        return TokenLimits(perDay: perDay, perIssue: perIssue)
    }

    /// Runs `symphony check` on a copy of symphony.yml with the changed limits, half a second after the last
    /// edit, so a value it rejects shows before Save.
    private func checkTokenLimits() {
        tokenLimitsCheck?.cancel()
        tokenLimitsCheck = nil
        isCheckingTokenLimits = false
        tokenLimitsError = nil
        guard let loaded = loadedTokenLimits, let limits = formTokenLimits, limits != loaded else { return }
        isCheckingTokenLimits = true
        let settings = settings.trimmed()
        let secrets = formSecrets
        let check = configCheck
        tokenLimitsCheck = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            let result: ConfigCheckResult
            do {
                result = try await SymphonyConfigFile(path: settings.configPath).checkTokenLimits(limits, from: loaded) { path in
                    await check(path, settings, secrets)
                }
            } catch {
                result = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            isCheckingTokenLimits = false
            if case .failed(let message) = result { tokenLimitsError = "symphony check rejects this: \(ConfigCheck.reasonFirst(message))" }
        }
    }

    /// The ticket priority toggles are off until a symphony.yml has been read, and while Save checks it.
    var canEditTicketPriorities: Bool { loadedTicketPriorities != nil && !isSaving }

    private func loadTicketPriorities() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let priorities = try SymphonyConfigFile(path: path).readTicketPriorities()
            ticketPriorities = priorities
            loadedTicketPriorities = priorities
        } catch {
            configFileError = "Could not read the allowed ticket priorities from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// The QA host tools field is off until a symphony.yml has been read, and while Save checks it.
    var canEditQAHostTools: Bool { loadedQAHostTools != nil && !isSaving }

    private func loadQAHostTools() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let tools = try SymphonyConfigFile(path: path).readQAHostTools()
            qaHostToolsText = tools.text
            loadedQAHostTools = tools
        } catch {
            configFileError = "Could not read the QA host tools from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// The board state fields are off until a symphony.yml has been read, and while Save checks it.
    var canEditWorkflowStates: Bool { loadedWorkflowStates != nil && !isSaving }

    private func loadWorkflowStates() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let states = try SymphonyConfigFile(path: path).readWorkflowStates()
            workflowStates = states
            loadedWorkflowStates = states
        } catch {
            configFileError = "Could not read the board states from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// The built-in ticket patterns toggle is off until a symphony.yml has been read, and while Save checks it.
    var canEditTicketPatternsBuiltIn: Bool { loadedTicketPatternsBuiltIn != nil && !isSaving }

    private func loadTicketPatternsBuiltIn() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let isOn = try SymphonyConfigFile(path: path).readBuiltInTicketPatterns()
            ticketPatternsBuiltIn = isOn
            loadedTicketPatternsBuiltIn = isOn
        } catch {
            configFileError = "Could not read the built-in ticket patterns setting from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// The risk rule pickers are off until a symphony.yml has been read, and while Save checks it.
    var canEditRiskRules: Bool { loadedRiskRules != nil && !isSaving }

    private func loadRiskRules() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let rules = try SymphonyConfigFile(path: path).readRiskRuleSettings()
            riskRules = rules
            loadedRiskRules = rules
        } catch {
            configFileError = "Could not read the risk rules from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// The timeout steppers are off until a symphony.yml has been read, and while Save checks it.
    var canEditTimeouts: Bool { loadedTimeouts != nil && !isSaving }

    private func loadTimeouts() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let timeouts = try SymphonyConfigFile(path: path).readOperationTimeouts()
            gitNetworkTimeoutMinutes = OperationTimeouts.minutes(timeouts.gitNetworkMs)
            mcpToolTimeoutMinutes = OperationTimeouts.minutes(timeouts.mcpToolMs)
            pendingToolReportMinutes = OperationTimeouts.minutes(timeouts.pendingToolReportMs)
            loadedTimeouts = timeouts
        } catch {
            configFileError = "Could not read the timeouts from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// The GitHub update steppers are off until a symphony.yml has been read, and while Save checks it.
    var canEditGitHubUpdates: Bool { loadedGitHubUpdates != nil && !isSaving }

    private func loadGitHubUpdates() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let updates = try SymphonyConfigFile(path: path).readGitHubUpdates()
            safetyNetCheckMinutes = GitHubUpdates.minutes(updates.fallbackPollMs)
            silenceAlertMinutes = GitHubUpdates.stepperMinutes(updates.silenceAlertMinutes)
            loadedGitHubUpdates = updates
        } catch {
            configFileError = "Could not read the GitHub update settings from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// The dispatch-loop steppers are off until a symphony.yml has been read, and while Save checks it.
    var canEditDispatchLoop: Bool { loadedDispatchLoopLimits != nil && !isSaving }

    private func loadDispatchLoopLimits() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let limits = try SymphonyConfigFile(path: path).readDispatchLoopLimits()
            dispatchLoopRuns = DispatchLoopLimits.steppedRuns(limits.runs)
            dispatchLoopWindowMinutes = DispatchLoopLimits.minutes(limits.windowMs)
            dispatchLoopLongRuns = DispatchLoopLimits.steppedRuns(limits.longRuns)
            dispatchLoopLongWindowMinutes = DispatchLoopLimits.minutes(limits.longWindowMs)
            loadedDispatchLoopLimits = limits
        } catch {
            configFileError = "Could not read the dispatch-loop limits from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// The dispatch controls are off until a symphony.yml has been read, and while Save checks it.
    var canEditDispatch: Bool { loadedDispatchSettings != nil && !isSaving }

    private func loadDispatchSettings() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let dispatch = try SymphonyConfigFile(path: path).readDispatchSettings()
            dispatchSource = dispatch.source
            dispatchShadowWindow = dispatch.shadowWindow
            dispatchReconcileMinutes = DispatchSettings.reconcileMinutes(dispatch.reconcileIntervalMs)
            loadedDispatchSettings = dispatch
        } catch {
            configFileError = "Could not read the dispatch settings from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// The Linear webhook controls are off until a symphony.yml has been read, and while Save checks it.
    var canEditLinearWebhooks: Bool { loadedLinearWebhooks != nil && !isSaving }

    private func loadLinearWebhooks() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let webhooks = try SymphonyConfigFile(path: path).readLinearWebhookSettings()
            linearWebhooksEnabled = webhooks.enabled
            let fields = LinearWebhookSettings.fields(webhooks.secret)
            (linearWebhookSecretSource, linearWebhookSecretName, linearWebhookSecretLiteral) = (fields.source, fields.name, fields.literal)
            loadedLinearWebhooks = webhooks
        } catch {
            configFileError = "Could not read the Linear webhook settings from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// The ledger controls are off until a symphony.yml has been read, and while Save checks it.
    var canEditLedger: Bool { loadedLedgerSettings != nil && !isSaving }

    private func loadLedgerSettings() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let ledger = try SymphonyConfigFile(path: path).readLedgerSettings()
            artifactMaxMegabytes = LedgerSettings.megabytes(ledger.maxBytes)
            promptBriefEnabled = ledger.briefEnabled
            promptBriefMaxTokens = ledger.briefMaxTokens
            loadedLedgerSettings = ledger
        } catch {
            configFileError = "Could not read the ledger settings from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// The macOS app QA controls are off until a symphony.yml has been read, and while Save checks it.
    var canEditMacAppQA: Bool { loadedMacAppQA != nil && !isSaving }

    private func loadMacAppQA() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let playbook = try SymphonyConfigFile(path: path).readMacAppQAPlaybook()
            macAppQA = playbook
            loadedMacAppQA = playbook
        } catch {
            configFileError = "Could not read the macOS app QA settings from symphony.yml: \(error.localizedDescription)"
        }
    }

    func addLaunchVariable() {
        macAppQA.launchEnv.append(LaunchVariable(name: "", value: ""))
    }

    func removeLaunchVariable(id: LaunchVariable.ID) {
        macAppQA.launchEnv.removeAll { $0.id == id }
    }

    /// The model and effort pickers are off until a symphony.yml has been read, and while Save checks it.
    var canEditRunProfiles: Bool { loadedRunProfiles != nil && !isSaving }

    /// What each field of the row for `kind` falls back to in the current scope.
    func inheritedProfile(_ kind: RunKind?) -> RunProfile {
        runProfiles.inherited(kind, in: runProfilesScope, command: commandProfile)
    }

    private func loadRunProfiles() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let file = SymphonyConfigFile(path: path)
            let profiles = try file.readScopedRunProfiles()
            commandProfile = try file.readCommandProfile()
            runProfiles = profiles
            loadedRunProfiles = profiles
            repositoryKeys = try RunProfilesConfig.repositoryKeys(in: String(contentsOfFile: path, encoding: .utf8))
            if case .repository(let key) = runProfilesScope, !repositoryKeys.contains(key) { runProfilesScope = .global }
        } catch {
            configFileError = "Could not read models from symphony.yml: \(error.localizedDescription)"
        }
    }

    /// Loads OpenRouter's model list for the Models pickers. The list needs no key, but the pickers only offer
    /// OpenRouter models once a key is entered.
    /// Retried from a failed list in the Models section.
    func loadOpenRouterModels() {
        guard !isLoadingOpenRouterModels else { return }
        isLoadingOpenRouterModels = true
        let client = openRouter
        Task {
            setOpenRouterModelList(await client.models())
            isLoadingOpenRouterModels = false
        }
    }

    private var hasOpenRouterModelList: Bool {
        if case .success? = openRouterModelList { return true }
        return false
    }

    /// A failed reload keeps a list that loaded earlier; otherwise the latest result replaces the last one.
    private func setOpenRouterModelList(_ models: Result<[OpenRouterModel], OpenRouterFailure>) {
        if case .failure = models, hasOpenRouterModelList { return }
        openRouterModelList = models
    }

    /// Names that may be removed from the store on save: the extra variables and a stored OpenRouter key.
    private static func storedNames(_ secrets: SecretSettings) -> Set<String> {
        var names = Set(secrets.extraEnvironment.map(\.name))
        if !secrets.openRouterAPIKey.isEmpty { names.insert(SecretSettings.openRouterAPIKeyName) }
        return names
    }

    /// Checks the OpenRouter key and loads the model list, both at once.
    func testOpenRouter() {
        guard !isTestingOpenRouter else { return }
        isTestingOpenRouter = true
        openRouterResult = nil
        openRouterModels = nil
        let key = openRouterAPIKey
        let client = openRouter
        Task {
            async let keyResult = client.checkKey(key)
            async let modelsResult = client.models()
            let (checked, models) = await (keyResult, modelsResult)
            // A key edited during the test makes the result stale.
            if openRouterAPIKey == key { openRouterResult = checked }
            openRouterModels = models.map(OpenRouterModel.summary)
            setOpenRouterModelList(models)
            isTestingOpenRouter = false
        }
    }

    func addRow() {
        extraRows.append(EnvironmentRow(name: "", value: ""))
    }

    func removeRow(id: EnvironmentRow.ID) {
        extraRows.removeAll { $0.id == id }
    }

    /// Save is off while it runs, until the secrets have been read, and while the token limits aren't valid
    /// or are being checked.
    var canSave: Bool {
        !isSaving && !isLoadingSecrets && formTokenLimits != nil && tokenLimitsError == nil && !isCheckingTokenLimits
    }

    /// The secrets as entered in the form, with the GitHub webhook secret as loaded: the form never shows or edits it.
    private var formSecrets: SecretSettings {
        SecretSettings(
            linearAPIKey: linearAPIKey,
            openRouterAPIKey: openRouterAPIKey,
            extraEnvironment: extraRows.map { EnvironmentVariable(name: $0.name, value: $0.value) },
            githubWebhookSecret: loadedSecrets?.githubWebhookSecret ?? ""
        ).trimmed()
    }

    /// Validates and saves, then calls `onSaved` when everything was stored. Changed models, token limits and
    /// timeouts are written only after `symphony check` passes on them; until then the rest isn't saved, and a
    /// failure shows in `configCheckError`, `tokenLimitsError`, `timeoutsError`, `gitHubUpdatesError`,
    /// `linearWebhooksError`, `dispatchLoopError`, `dispatchError`, `ledgerError` or `macAppQAError`.
    func save(onSaved: @escaping () -> Void) {
        guard canSave else { return }
        let settings = settings.trimmed()
        let secrets = formSecrets

        issues = validator.validate(settings, secrets)
        guard issues.isEmpty else { return }
        configCheckError = nil

        let profiles = runProfiles
        let loadedProfiles = loadedRunProfiles.flatMap { $0 != profiles ? $0 : nil }
        let limits = formTokenLimits
        let loadedLimits = loadedTokenLimits.flatMap { $0 != limits ? $0 : nil }
        timeoutsError = nil
        let timeouts = loadedTimeouts?.settingMinutes(
            gitNetwork: gitNetworkTimeoutMinutes,
            mcpTool: mcpToolTimeoutMinutes,
            pendingToolReport: pendingToolReportMinutes
        )
        let oldTimeouts = loadedTimeouts.flatMap { $0 != timeouts ? $0 : nil }
        gitHubUpdatesError = nil
        let updates = loadedGitHubUpdates?.settingMinutes(fallbackPoll: safetyNetCheckMinutes, silenceAlert: silenceAlertMinutes)
        let oldUpdates = loadedGitHubUpdates.flatMap { $0 != updates ? $0 : nil }
        linearWebhooksError = nil
        let webhookSecret = LinearWebhookSettings.secret(
            source: linearWebhookSecretSource, name: linearWebhookSecretName, literal: linearWebhookSecretLiteral
        )
        if loadedLinearWebhooks != nil, webhookSecret == nil {
            linearWebhooksError = LinearWebhookSettings.environmentNameRule
            return
        }
        let webhooks = loadedLinearWebhooks.map { _ in
            LinearWebhookSettings(enabled: linearWebhooksEnabled, secret: webhookSecret ?? .none)
        }
        let oldWebhooks = loadedLinearWebhooks.flatMap { $0 != webhooks ? $0 : nil }
        dispatchLoopError = nil
        let loopLimits = loadedDispatchLoopLimits?.setting(
            runs: dispatchLoopRuns,
            windowMinutes: dispatchLoopWindowMinutes,
            longRuns: dispatchLoopLongRuns,
            longWindowMinutes: dispatchLoopLongWindowMinutes
        )
        let oldLoopLimits = loadedDispatchLoopLimits.flatMap { $0 != loopLimits ? $0 : nil }
        dispatchError = nil
        if loadedDispatchSettings != nil, !DispatchSettings.isValidWindow(dispatchShadowWindow) {
            dispatchError = DispatchSettings.windowRule
            return
        }
        if loadedDispatchSettings != nil, !DispatchSettings.isValidReconcileMinutes(dispatchReconcileMinutes) {
            dispatchError = DispatchSettings.reconcileRule
            return
        }
        let dispatch = loadedDispatchSettings?.setting(
            source: dispatchSource, shadowWindow: dispatchShadowWindow, reconcileMinutes: dispatchReconcileMinutes
        )
        let oldDispatch = loadedDispatchSettings.flatMap { $0 != dispatch ? $0 : nil }
        ledgerError = nil
        var ledger = loadedLedgerSettings?.setting(maxMegabytes: artifactMaxMegabytes)
        ledger?.briefEnabled = promptBriefEnabled
        ledger?.briefMaxTokens = promptBriefMaxTokens
        let oldLedger = loadedLedgerSettings.flatMap { $0 != ledger ? $0 : nil }
        macAppQAError = nil
        let qaPlaybook = macAppQA.trimmed()
        let oldQAPlaybook = loadedMacAppQA.flatMap { $0 != qaPlaybook ? $0 : nil }
        ticketPrioritiesError = nil
        let priorities = ticketPriorities
        let loadedPriorities = loadedTicketPriorities.flatMap { $0 != priorities ? $0 : nil }
        qaHostToolsError = nil
        let hostTools = QAHostTools(text: qaHostToolsText)
        let loadedHostTools = loadedQAHostTools.flatMap { $0 != hostTools ? $0 : nil }
        workflowStatesError = nil
        let states = workflowStates
        let loadedStates = loadedWorkflowStates.flatMap { $0 != states ? $0 : nil }
        ticketPatternsBuiltInError = nil
        let builtInPatterns = ticketPatternsBuiltIn
        let builtInPatternsChanged = loadedTicketPatternsBuiltIn.map { $0 != builtInPatterns } ?? false
        riskRulesError = nil
        let rules = riskRules
        let loadedRules = loadedRiskRules.flatMap { $0 != rules ? $0 : nil }

        guard loadedProfiles != nil || loadedLimits != nil || oldTimeouts != nil || oldUpdates != nil || oldWebhooks != nil
            || oldLoopLimits != nil || oldDispatch != nil || oldLedger != nil || oldQAPlaybook != nil || loadedPriorities != nil || loadedHostTools != nil || loadedStates != nil
            || builtInPatternsChanged || loadedRules != nil else {
            if saveRest(settings, secrets) { onSaved() }
            return
        }
        isSaving = true
        Task {
            var saved = true
            if let loadedProfiles {
                saved = await saveRunProfiles(profiles, from: loadedProfiles, settings: settings, secrets: secrets)
            }
            if saved, let limits, let loadedLimits {
                saved = await saveTokenLimits(limits, from: loadedLimits, settings: settings, secrets: secrets)
            }
            if saved, let timeouts, let oldTimeouts {
                saved = await saveTimeouts(timeouts, from: oldTimeouts, settings: settings, secrets: secrets)
            }
            if saved, let updates, let oldUpdates {
                saved = await saveGitHubUpdates(updates, from: oldUpdates, settings: settings, secrets: secrets)
            }
            if saved, let webhooks, let oldWebhooks {
                saved = await saveLinearWebhooks(webhooks, from: oldWebhooks, settings: settings, secrets: secrets)
            }
            if saved, let loopLimits, let oldLoopLimits {
                saved = await saveDispatchLoopLimits(loopLimits, from: oldLoopLimits, settings: settings, secrets: secrets)
            }
            if saved, let dispatch, let oldDispatch {
                saved = await saveDispatchSettings(dispatch, from: oldDispatch, settings: settings, secrets: secrets)
            }
            if saved, let ledger, let oldLedger {
                saved = await saveLedgerSettings(ledger, from: oldLedger, settings: settings, secrets: secrets)
            }
            if saved, let oldQAPlaybook {
                saved = await saveMacAppQA(qaPlaybook, from: oldQAPlaybook, settings: settings, secrets: secrets)
            }
            if saved, let loadedPriorities {
                saved = await saveTicketPriorities(priorities, from: loadedPriorities, settings: settings, secrets: secrets)
            }
            if saved, let loadedHostTools {
                saved = await saveQAHostTools(hostTools, from: loadedHostTools, settings: settings, secrets: secrets)
            }
            if saved, let loadedStates {
                saved = await saveWorkflowStates(states, from: loadedStates, settings: settings, secrets: secrets)
            }
            if saved, builtInPatternsChanged {
                saved = await saveTicketPatternsBuiltIn(builtInPatterns, settings: settings, secrets: secrets)
            }
            if saved, let loadedRules {
                saved = await saveRiskRules(rules, from: loadedRules, settings: settings, secrets: secrets)
            }
            isSaving = false
            if saved && saveRest(settings, secrets) { onSaved() }
        }
    }

    /// Saves everything but the models. Returns true when it was all stored.
    private func saveRest(_ settings: AppSettings, _ secrets: SecretSettings) -> Bool {
        do {
            try store.saveSecrets(secrets, removing: storedNames)
        } catch {
            secretsError = "Could not save the secrets: \(error)"
            return false
        }
        storedNames = Self.storedNames(secrets)
        secretsError = nil
        let secretsChanged = secrets != loadedSecrets
        loadedSecrets = secrets
        store.saveSettings(settings)
        onSettingsSaved(settings)
        let saved = saveMaxConcurrentAgents(to: settings.configPath) && saveLaunchAtLogin()
        // After the settings are stored, so the restart starts Symphony with all of them.
        if secretsChanged { onSecretsChanged() }
        return saved
    }

    /// Writes `max_total` to symphony.yml when the stepper changed it.
    private func saveMaxConcurrentAgents(to path: String) -> Bool {
        guard let loaded = loadedMaxConcurrentAgents, maxConcurrentAgents != loaded else { return true }
        do {
            try SymphonyConfigFile(path: path).writeMaxConcurrentAgents(maxConcurrentAgents)
        } catch {
            configFileError = "Could not save max_total to symphony.yml: \(error.localizedDescription)"
            return false
        }
        configFileError = nil
        loadedMaxConcurrentAgents = maxConcurrentAgents
        return true
    }

    /// Writes the provider, model and effort fields the rows changed to symphony.yml once `symphony check`
    /// passes on the result, then reads them back, since saving can move `--model` / `--effort` out of
    /// `agent.command` into the Default row.
    private func saveRunProfiles(
        _ profiles: ScopedRunProfiles,
        from loaded: ScopedRunProfiles,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeRunProfiles(profiles, from: loaded) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save models to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            configCheckError = "symphony check rejected these models, so nothing was saved: \(ConfigCheck.reasonFirst(message))"
            return false
        }
        configFileError = nil
        loadRunProfiles()
        return configFileError == nil
    }

    /// Writes the token limits that changed to symphony.yml once `symphony check` passes on the result.
    private func saveTokenLimits(
        _ limits: TokenLimits,
        from loaded: TokenLimits,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeTokenLimits(limits, from: loaded) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the token limits to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            tokenLimitsError = "symphony check rejected these token limits, so nothing was saved: \(ConfigCheck.reasonFirst(message))"
            return false
        }
        configFileError = nil
        loadedTokenLimits = limits
        return true
    }

    /// Writes the timeouts that changed to symphony.yml once `symphony check` passes on the result.
    private func saveTimeouts(
        _ timeouts: OperationTimeouts,
        from loaded: OperationTimeouts,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeOperationTimeouts(timeouts, from: loaded) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the timeouts to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            timeoutsError = "symphony check rejected these timeouts, so nothing was saved: \(ConfigCheck.reasonFirst(message))"
            return false
        }
        configFileError = nil
        loadedTimeouts = timeouts
        return true
    }

    /// Writes the GitHub update settings that changed to symphony.yml once `symphony check` passes on the result.
    private func saveGitHubUpdates(
        _ updates: GitHubUpdates,
        from loaded: GitHubUpdates,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeGitHubUpdates(updates, from: loaded) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the GitHub update settings to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            gitHubUpdatesError = "symphony check rejected these GitHub update settings, so nothing was saved: \(ConfigCheck.reasonFirst(message))"
            return false
        }
        configFileError = nil
        loadedGitHubUpdates = updates
        return true
    }

    /// Writes the dispatch-loop limits that changed to symphony.yml once `symphony check` passes on the result.
    private func saveDispatchLoopLimits(
        _ limits: DispatchLoopLimits,
        from loaded: DispatchLoopLimits,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeDispatchLoopLimits(limits, from: loaded) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the dispatch-loop limits to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            dispatchLoopError = "symphony check rejected these limits, so nothing was saved: \(ConfigCheck.reasonFirst(message))"
            return false
        }
        configFileError = nil
        loadedDispatchLoopLimits = limits
        return true
    }

    /// Writes the dispatch settings that changed to symphony.yml once `symphony check` passes on the result.
    private func saveDispatchSettings(
        _ dispatch: DispatchSettings,
        from loaded: DispatchSettings,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeDispatchSettings(dispatch, from: loaded) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the dispatch settings to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            dispatchError = "symphony check rejected these settings, so nothing was saved: \(ConfigCheck.reasonFirst(message))"
            return false
        }
        configFileError = nil
        loadedDispatchSettings = dispatch
        return true
    }

    /// Writes the Linear webhook settings that changed to symphony.yml once `symphony check` passes on the result.
    private func saveLinearWebhooks(
        _ webhooks: LinearWebhookSettings,
        from loaded: LinearWebhookSettings,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeLinearWebhookSettings(webhooks, from: loaded) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the Linear webhook settings to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            linearWebhooksError = "symphony check rejected these settings, so nothing was saved: \(ConfigCheck.reasonFirst(message))"
            return false
        }
        configFileError = nil
        loadedLinearWebhooks = webhooks
        return true
    }

    /// Writes the ledger settings that changed to symphony.yml once `symphony check` passes on the result.
    private func saveLedgerSettings(
        _ ledger: LedgerSettings,
        from loaded: LedgerSettings,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeLedgerSettings(ledger, from: loaded) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the ledger settings to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            ledgerError = "symphony check rejected these settings, so nothing was saved: \(ConfigCheck.reasonFirst(message))"
            return false
        }
        configFileError = nil
        loadedLedgerSettings = ledger
        return true
    }

    /// Writes the macOS app QA settings that changed to symphony.yml once `symphony check` passes on the result.
    private func saveMacAppQA(
        _ playbook: MacAppQAPlaybook,
        from loaded: MacAppQAPlaybook,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeMacAppQAPlaybook(playbook, from: loaded) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the macOS app QA settings to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            macAppQAError = "symphony check rejected these macOS app QA settings, so nothing was saved: \(ConfigCheck.reasonFirst(message))"
            return false
        }
        configFileError = nil
        macAppQA = playbook
        loadedMacAppQA = playbook
        return true
    }

    /// Writes `tickets.priorities` to symphony.yml once `symphony check` passes on the result.
    private func saveTicketPriorities(
        _ priorities: TicketPriorities,
        from loaded: TicketPriorities,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeTicketPriorities(priorities, from: loaded) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the allowed ticket priorities to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            ticketPrioritiesError = "symphony check rejected these ticket priorities, so nothing was saved: \(ConfigCheck.reasonFirst(message))"
            return false
        }
        configFileError = nil
        loadedTicketPriorities = priorities
        return true
    }

    /// Writes `auto_review.playbooks.macos_app.requires` to symphony.yml once `symphony check` passes on the result.
    private func saveQAHostTools(
        _ tools: QAHostTools,
        from loaded: QAHostTools,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeQAHostTools(tools, from: loaded) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the QA host tools to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            qaHostToolsError = "symphony check rejected these QA host tools, so nothing was saved: \(ConfigCheck.reasonFirst(message))"
            return false
        }
        configFileError = nil
        loadedQAHostTools = tools
        qaHostToolsText = tools.text
        return true
    }

    /// Writes `issues.states.*` to symphony.yml once `symphony check` passes on the result.
    private func saveWorkflowStates(
        _ states: WorkflowStates,
        from loaded: WorkflowStates,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeWorkflowStates(states, from: loaded) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the board states to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            workflowStatesError = "symphony check rejected these board states, so nothing was saved: \(ConfigCheck.reasonFirst(message))"
            return false
        }
        configFileError = nil
        loadedWorkflowStates = states
        return true
    }

    /// Writes `auto_review.acceptance_gate.escalate.ticket_patterns_builtin` to symphony.yml once `symphony check`
    /// passes on the result.
    private func saveTicketPatternsBuiltIn(_ isOn: Bool, settings: AppSettings, secrets: SecretSettings) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeBuiltInTicketPatterns(isOn) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the built-in ticket patterns setting to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            ticketPatternsBuiltInError = "symphony check rejected the built-in ticket patterns setting, so nothing was saved: "
                + ConfigCheck.reasonFirst(message)
            return false
        }
        configFileError = nil
        loadedTicketPatternsBuiltIn = isOn
        return true
    }

    /// Writes the risk rule settings that changed to symphony.yml once `symphony check` passes on the result.
    private func saveRiskRules(
        _ rules: RiskRuleSettings,
        from old: RiskRuleSettings,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeRiskRuleSettings(rules, from: old) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the risk rules to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            riskRulesError = "symphony check rejected the risk rules, so nothing was saved: " + ConfigCheck.reasonFirst(message)
            return false
        }
        configFileError = nil
        loadedRiskRules = rules
        return true
    }

    /// `symphony check --config <configPath>`, run the way Start would run Symphony with these settings.
    nonisolated static func runConfigCheck(
        configPath: String,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> ConfigCheckResult {
        var settings = settings
        settings.configPath = configPath
        do {
            let launch = try ChildLaunchBuilder.build(
                settings: settings,
                secrets: secrets,
                baseEnvironment: AppStores.current.environment,
                embeddedSymphonyPath: SymphonyRunner.embeddedSymphonyPath,
                subcommand: ["check"]
            )
            return await ConfigCheck.run(launch, log: ConfigCheck.qaLog(AppStores.current.qaMode))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Registers or unregisters the login item. When macOS wants the user to allow it, opens Login Items.
    private func saveLaunchAtLogin() -> Bool {
        let wasPending = loginItem.status == .requiresApproval
        do {
            try LoginItem.apply(launchAtLogin, to: loginItem)
        } catch {
            loginItemError = "Could not change \(LoginItem.toggleTitle): \(error.localizedDescription)"
            return false
        }
        loginItemError = nil
        let status = loginItem.status
        launchAtLogin = LoginItem.isOn(status)
        loginItemNote = LoginItem.note(status)
        if status == .requiresApproval && !wasPending {
            MainAppLoginItem.openSystemSettings()
        }
        return true
    }
}
