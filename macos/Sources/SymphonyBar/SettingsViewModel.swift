import Foundation
import SymphonyBarCore

/// An editable extra environment variable row. The id keeps SwiftUI rows stable while names change.
struct EnvironmentRow: Identifiable {
    let id = UUID()
    var name: String
    var value: String
}

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
    @Published private(set) var configFileError: String?

    /// The value read from symphony.yml, or nil when it couldn't be read. The file is written only when the
    /// stepper moved away from it, so an untouched form never edits symphony.yml.
    private var loadedMaxConcurrentAgents: Int?

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
    private let onSecretsChanged: () -> Void

    init(
        store: SettingsStore = AppStores.current.settingsStore(),
        validator: SettingsValidator = SettingsValidator(embeddedSymphonyPath: SymphonyRunner.embeddedSymphonyPath),
        loginItem: LoginItemService = AppStores.current.loginItem,
        openRouter: OpenRouterClient = OpenRouterClient(),
        onSecretsChanged: @escaping () -> Void = {}
    ) {
        self.store = store
        self.validator = validator
        self.loginItem = loginItem
        self.openRouter = openRouter
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
            isTestingOpenRouter = false
        }
    }

    func addRow() {
        extraRows.append(EnvironmentRow(name: "", value: ""))
    }

    func removeRow(id: EnvironmentRow.ID) {
        extraRows.removeAll { $0.id == id }
    }

    /// Validates and saves. Returns true when the settings were stored.
    func save() -> Bool {
        let settings = settings.trimmed()
        let secrets = SecretSettings(
            linearAPIKey: linearAPIKey,
            openRouterAPIKey: openRouterAPIKey,
            extraEnvironment: extraRows.map { EnvironmentVariable(name: $0.name, value: $0.value) }
        ).trimmed()

        issues = validator.validate(settings, secrets)
        guard issues.isEmpty else { return false }

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
