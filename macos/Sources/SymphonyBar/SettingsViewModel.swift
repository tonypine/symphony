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
        didSet { if openRouterAPIKey != oldValue { openRouterResult = nil } }
    }
    /// The last Test connection result: the key's label and credit, or why it failed.
    @Published private(set) var openRouterResult: Result<OpenRouterKeyInfo, OpenRouterFailure>?
    /// "312 models, 141 support tools", or why the model list couldn't be loaded.
    @Published private(set) var openRouterModels: Result<String, OpenRouterFailure>?
    /// OpenRouter's models for the Models pickers, loaded while an OpenRouter key is entered.
    @Published private(set) var openRouterModelList: Result<[OpenRouterModel], OpenRouterFailure>?
    @Published private(set) var isTestingOpenRouter = false
    @Published var extraRows: [EnvironmentRow] = []
    /// Launch at Login, read from macOS rather than UserDefaults so it follows changes made in System Settings.
    @Published var launchAtLogin: Bool
    @Published private(set) var loginItemNote: String?
    @Published private(set) var loginItemError: String?
    @Published private(set) var issues: [SettingsIssue] = []
    @Published private(set) var keychainError: String?
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
    /// True while Save waits for `symphony check`.
    @Published private(set) var isSaving = false

    /// The value read from symphony.yml, or nil when it couldn't be read. The file is written only when the
    /// stepper moved away from it, so an untouched form never edits symphony.yml.
    private var loadedMaxConcurrentAgents: Int?

    /// The profiles read from symphony.yml, or nil when they couldn't be read. Only fields changed from these
    /// are written.
    private var loadedRunProfiles: ScopedRunProfiles?

    /// Extra variable names known to be in the Keychain. Only these can be removed on save, so a failed
    /// load never turns into deletions.
    private var storedNames: Set<String> = []

    /// The secrets as read from the Keychain, or nil when the read failed. Saving different secrets restarts
    /// Symphony so it picks them up.
    private var loadedSecrets: SecretSettings?

    private let store: SettingsStore
    private let validator: SettingsValidator
    private let loginItem: LoginItemService
    private let openRouter: OpenRouterClient
    private let configCheck: SettingsConfigCheck
    private let onSecretsChanged: () -> Void

    init(
        store: SettingsStore = AppStores.current.settingsStore(),
        validator: SettingsValidator = SettingsValidator(embeddedSymphonyPath: SymphonyRunner.embeddedSymphonyPath),
        loginItem: LoginItemService = AppStores.current.loginItem,
        openRouter: OpenRouterClient = OpenRouterClient(),
        configCheck: @escaping SettingsConfigCheck = SettingsViewModel.runConfigCheck,
        onSecretsChanged: @escaping () -> Void = {}
    ) {
        self.store = store
        self.validator = validator
        self.loginItem = loginItem
        self.openRouter = openRouter
        self.configCheck = configCheck
        self.onSecretsChanged = onSecretsChanged
        settings = store.loadSettings()
        let loginStatus = loginItem.status
        launchAtLogin = LoginItem.isOn(loginStatus)
        loginItemNote = LoginItem.note(loginStatus)

        do {
            let secrets = try store.loadSecrets()
            linearAPIKey = secrets.linearAPIKey
            openRouterAPIKey = secrets.openRouterAPIKey
            extraRows = secrets.extraEnvironment.map { EnvironmentRow(name: $0.name, value: $0.value) }
            storedNames = Self.storedNames(secrets)
            loadedSecrets = secrets.trimmed()
        } catch {
            keychainError = "Could not read the Keychain: \(error)"
        }
        loadMaxConcurrentAgents()
        loadRunProfiles()
        if !openRouterAPIKey.isEmpty { loadOpenRouterModels() }
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
    func loadOpenRouterModels() {
        let client = openRouter
        Task { openRouterModelList = await client.models() }
    }

    /// Names that may be removed from the Keychain on save: the extra variables and a stored OpenRouter key.
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
            if case .success = models { openRouterModelList = models }
            isTestingOpenRouter = false
        }
    }

    func addRow() {
        extraRows.append(EnvironmentRow(name: "", value: ""))
    }

    func removeRow(id: EnvironmentRow.ID) {
        extraRows.removeAll { $0.id == id }
    }

    /// Validates and saves, then calls `onSaved` when everything was stored. Changed models are written only
    /// after `symphony check` passes on them; until then nothing is saved, and a failure shows in
    /// `configCheckError`.
    func save(onSaved: @escaping () -> Void) {
        guard !isSaving else { return }
        let settings = settings.trimmed()
        let secrets = SecretSettings(
            linearAPIKey: linearAPIKey,
            openRouterAPIKey: openRouterAPIKey,
            extraEnvironment: extraRows.map { EnvironmentVariable(name: $0.name, value: $0.value) }
        ).trimmed()

        issues = validator.validate(settings, secrets)
        guard issues.isEmpty else { return }
        configCheckError = nil

        guard let loaded = loadedRunProfiles, runProfiles != loaded else {
            if saveRest(settings, secrets) { onSaved() }
            return
        }
        isSaving = true
        Task {
            let saved = await saveRunProfiles(runProfiles, from: loaded, settings: settings, secrets: secrets)
            isSaving = false
            if saved && saveRest(settings, secrets) { onSaved() }
        }
    }

    /// Saves everything but the models. Returns true when it was all stored.
    private func saveRest(_ settings: AppSettings, _ secrets: SecretSettings) -> Bool {
        do {
            try store.saveSecrets(secrets, removing: storedNames)
        } catch {
            keychainError = "Could not save to the Keychain: \(error)"
            return false
        }
        storedNames = Self.storedNames(secrets)
        keychainError = nil
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
                subcommand: ["check"],
                qaMode: AppStores.current.isQAMode
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
