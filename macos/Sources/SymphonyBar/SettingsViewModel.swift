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
    /// keys under each `repositories[].agent`.
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
    /// Today's tokens from Symphony's latest state, nil while it isn't answering.
    @Published var budget: StateSnapshot.Budget?
    /// `auto_review.acceptance_gate.mode` in the configured symphony.yml.
    @Published var acceptanceGateMode = AcceptanceGateMode.off
    /// Enforce, while its confirmation is open.
    @Published var pendingAcceptanceGate: AcceptanceGateChoice?
    /// Symphony's latest state, for the acceptance gate's agreement stats; nil while it isn't answering.
    @Published var state: StateSnapshot?
    /// Why `symphony check` rejected the changed acceptance gate mode, shown in its section.
    @Published private(set) var acceptanceGateError: String?
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

    /// The gate mode read from symphony.yml, or nil when it couldn't be read. Written only when it changed.
    private var loadedAcceptanceGateMode: AcceptanceGateMode?

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
        openRouter: OpenRouterClient = OpenRouterClient(),
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
        loadRunProfiles()
        loadAcceptanceGateMode()
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
            if case .failed(let message) = result { tokenLimitsError = "symphony check rejects this: \(message)" }
        }
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

    /// The gate picker is off until a symphony.yml has been read, and while Save checks it.
    var canEditAcceptanceGate: Bool { loadedAcceptanceGateMode != nil && !isSaving }

    /// The agreement stats under the gate picker: one line per repository, or why there are none.
    var acceptanceGateLines: [String] {
        AcceptanceGate.agreementLines(keys: repositoryKeys, in: state)
    }

    private func loadAcceptanceGateMode() {
        let path = settings.trimmed().configPath
        guard !path.isEmpty else { return }
        do {
            let mode = try SymphonyConfigFile(path: path).readAcceptanceGateMode()
            acceptanceGateMode = mode
            loadedAcceptanceGateMode = mode
        } catch {
            configFileError = "Could not read the acceptance gate's mode from symphony.yml: \(error.localizedDescription)"
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

    /// The secrets as entered in the form.
    private var formSecrets: SecretSettings {
        SecretSettings(
            linearAPIKey: linearAPIKey,
            openRouterAPIKey: openRouterAPIKey,
            extraEnvironment: extraRows.map { EnvironmentVariable(name: $0.name, value: $0.value) }
        ).trimmed()
    }

    /// Validates and saves, then calls `onSaved` when everything was stored. Changed models and token limits are
    /// written only after `symphony check` passes on them; until then the rest isn't saved, and a failure shows
    /// in `configCheckError` or `tokenLimitsError`.
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
        acceptanceGateError = nil
        let gateMode = acceptanceGateMode
        let gateChanged = loadedAcceptanceGateMode.map { $0 != gateMode } ?? false
        guard loadedProfiles != nil || loadedLimits != nil || gateChanged else {
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
            if saved, gateChanged {
                saved = await saveAcceptanceGateMode(gateMode, settings: settings, secrets: secrets)
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
            configCheckError = "symphony check rejected these models, so nothing was saved: \(message)"
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
            tokenLimitsError = "symphony check rejected these token limits, so nothing was saved: \(message)"
            return false
        }
        configFileError = nil
        loadedTokenLimits = limits
        return true
    }

    /// Writes `auto_review.acceptance_gate.mode` to symphony.yml once `symphony check` passes on the result.
    private func saveAcceptanceGateMode(
        _ mode: AcceptanceGateMode,
        settings: AppSettings,
        secrets: SecretSettings
    ) async -> Bool {
        let check = configCheck
        let result: ConfigCheckResult
        do {
            result = try await SymphonyConfigFile(path: settings.configPath).writeAcceptanceGateMode(mode) { path in
                await check(path, settings, secrets)
            }
        } catch {
            configFileError = "Could not save the acceptance gate's mode to symphony.yml: \(error.localizedDescription)"
            return false
        }
        if case .failed(let message) = result {
            acceptanceGateError = "symphony check rejected this mode, so nothing was saved: \(message)"
            return false
        }
        configFileError = nil
        loadedAcceptanceGateMode = mode
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
            return await ConfigCheck.run(launch)
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
