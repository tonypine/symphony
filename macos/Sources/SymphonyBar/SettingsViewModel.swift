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

    private let store: SettingsStore
    private let validator: SettingsValidator
    private let loginItem: LoginItemService

    init(
        store: SettingsStore = SettingsStore(),
        validator: SettingsValidator = SettingsValidator(),
        loginItem: LoginItemService = MainAppLoginItem()
    ) {
        self.store = store
        self.validator = validator
        self.loginItem = loginItem
        settings = store.loadSettings()
        let loginStatus = loginItem.status
        launchAtLogin = LoginItem.isOn(loginStatus)
        loginItemNote = LoginItem.note(loginStatus)

        do {
            let secrets = try store.loadSecrets()
            linearAPIKey = secrets.linearAPIKey
            extraRows = secrets.extraEnvironment.map { EnvironmentRow(name: $0.name, value: $0.value) }
            storedNames = Set(secrets.extraEnvironment.map(\.name))
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
        storedNames = Set(secrets.extraEnvironment.map(\.name))
        keychainError = nil
        store.saveSettings(settings)
        return saveMaxConcurrentAgents(to: settings.configPath) && saveLaunchAtLogin()
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
