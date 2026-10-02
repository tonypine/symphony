import Foundation

/// The subset of UserDefaults the settings store uses, so tests can swap it out.
public protocol KeyValueStore: AnyObject {
    func object(forKey defaultName: String) -> Any?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: KeyValueStore {}

/// Loads and saves settings: plain values in a key-value store, secrets only in a secret store.
public final class SettingsStore {
    /// UserDefaults keys. None of these ever hold a secret.
    public enum Key {
        public static let checkoutPath = "checkoutPath"
        public static let configPath = "configPath"
        public static let commandPrefix = "commandPrefix"
        public static let stopTimeoutSeconds = "stopTimeoutSeconds"
        public static let startOnLaunch = "startOnLaunch"
    }

    private let defaults: KeyValueStore
    private let secrets: SecretStore

    public init(defaults: KeyValueStore = UserDefaults.standard, secrets: SecretStore = KeychainSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    public func loadSettings() -> AppSettings {
        AppSettings(
            checkoutPath: defaults.object(forKey: Key.checkoutPath) as? String ?? "",
            configPath: defaults.object(forKey: Key.configPath) as? String ?? "",
            commandPrefix: defaults.object(forKey: Key.commandPrefix) as? String ?? "",
            stopTimeoutSeconds: defaults.object(forKey: Key.stopTimeoutSeconds) as? Int
                ?? AppSettings.defaultStopTimeoutSeconds,
            startOnLaunch: defaults.object(forKey: Key.startOnLaunch) as? Bool ?? false
        )
    }

    public func saveSettings(_ settings: AppSettings) {
        defaults.set(settings.checkoutPath, forKey: Key.checkoutPath)
        defaults.set(settings.configPath, forKey: Key.configPath)
        defaults.set(settings.commandPrefix, forKey: Key.commandPrefix)
        defaults.set(settings.stopTimeoutSeconds, forKey: Key.stopTimeoutSeconds)
        defaults.set(settings.startOnLaunch, forKey: Key.startOnLaunch)
    }

    /// Reads the Linear API key and every other account under the Keychain service as an extra variable.
    public func loadSecrets() throws -> SecretSettings {
        let keyName = SecretSettings.linearAPIKeyName
        let extra = try secrets.accounts()
            .filter { $0 != keyName }
            .sorted()
            .map { EnvironmentVariable(name: $0, value: try secrets.value(forAccount: $0) ?? "") }

        return SecretSettings(
            linearAPIKey: try secrets.value(forAccount: keyName) ?? "",
            extraEnvironment: extra
        )
    }

    /// Writes the secrets and removes extra variables that are no longer listed.
    public func saveSecrets(_ settings: SecretSettings) throws {
        let keyName = SecretSettings.linearAPIKeyName
        try secrets.setValue(settings.linearAPIKey, forAccount: keyName)

        let kept = Set(settings.extraEnvironment.map(\.name))
        for account in try secrets.accounts() where account != keyName && !kept.contains(account) {
            try secrets.removeValue(forAccount: account)
        }
        for variable in settings.extraEnvironment {
            try secrets.setValue(variable.value, forAccount: variable.name)
        }
    }
}
