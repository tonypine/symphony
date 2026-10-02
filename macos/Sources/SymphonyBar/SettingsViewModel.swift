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
    @Published private(set) var issues: [SettingsIssue] = []
    @Published private(set) var keychainError: String?

    private let store: SettingsStore
    private let validator: SettingsValidator

    init(store: SettingsStore = SettingsStore(), validator: SettingsValidator = SettingsValidator()) {
        self.store = store
        self.validator = validator
        settings = store.loadSettings()

        do {
            let secrets = try store.loadSecrets()
            linearAPIKey = secrets.linearAPIKey
            extraRows = secrets.extraEnvironment.map { EnvironmentRow(name: $0.name, value: $0.value) }
        } catch {
            keychainError = "Could not read the Keychain: \(error)"
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
            try store.saveSecrets(secrets)
        } catch {
            keychainError = "Could not save to the Keychain: \(error)"
            return false
        }
        keychainError = nil
        store.saveSettings(settings)
        return true
    }
}
