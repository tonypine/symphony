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
        public static let restartTimeoutMinutes = "restartTimeoutMinutes"
        public static let startOnLaunch = "startOnLaunch"
        public static let developmentMode = "developmentMode"
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
            commandPrefix: defaults.object(forKey: Key.commandPrefix) as? String ?? AppSettings.defaultCommandPrefix,
            stopTimeoutSeconds: defaults.object(forKey: Key.stopTimeoutSeconds) as? Int
                ?? AppSettings.defaultStopTimeoutSeconds,
            restartTimeoutMinutes: defaults.object(forKey: Key.restartTimeoutMinutes) as? Int
                ?? AppSettings.defaultRestartTimeoutMinutes,
            startOnLaunch: defaults.object(forKey: Key.startOnLaunch) as? Bool ?? false,
            developmentMode: defaults.object(forKey: Key.developmentMode) as? Bool ?? false
        )
    }

    /// Picks Development mode the first time this version runs, so an install that already ran its checkout's
    /// `bin/symphony` keeps doing so: on when a checkout folder is set and the app has no embedded Symphony,
    /// off otherwise. Does nothing once the setting is stored.
    public func migrateDevelopmentMode(embeddedSymphonyAvailable: Bool) {
        guard defaults.object(forKey: Key.developmentMode) == nil else { return }
        let checkoutPath = (defaults.object(forKey: Key.checkoutPath) as? String ?? "").trimmingWhitespace()
        defaults.set(!checkoutPath.isEmpty && !embeddedSymphonyAvailable, forKey: Key.developmentMode)
    }

    public func saveSettings(_ settings: AppSettings) {
        defaults.set(settings.checkoutPath, forKey: Key.checkoutPath)
        defaults.set(settings.configPath, forKey: Key.configPath)
        defaults.set(settings.commandPrefix, forKey: Key.commandPrefix)
        defaults.set(settings.stopTimeoutSeconds, forKey: Key.stopTimeoutSeconds)
        defaults.set(settings.restartTimeoutMinutes, forKey: Key.restartTimeoutMinutes)
        defaults.set(settings.startOnLaunch, forKey: Key.startOnLaunch)
        defaults.set(settings.developmentMode, forKey: Key.developmentMode)
    }

    /// Reads the Linear and OpenRouter API keys, and every other account under the Keychain service as an extra
    /// variable.
    public func loadSecrets() throws -> SecretSettings {
        let extra = try secrets.accounts()
            .filter { !SecretSettings.reservedNames.contains($0) }
            .sorted()
            .map { EnvironmentVariable(name: $0, value: try secrets.value(forAccount: $0) ?? "") }

        return SecretSettings(
            linearAPIKey: try secrets.value(forAccount: SecretSettings.linearAPIKeyName) ?? "",
            openRouterAPIKey: try secrets.value(forAccount: SecretSettings.openRouterAPIKeyName) ?? "",
            extraEnvironment: extra
        )
    }

    /// Writes the secrets, then removes the named extra variables. Only names in `removing` are ever
    /// deleted, so a list that failed to load or is stale can't wipe stored variables. Names still listed
    /// and the Linear API key are never removed. A blank OpenRouter key is removed only when `removing`
    /// names it, like an extra variable.
    public func saveSecrets(_ settings: SecretSettings, removing removed: Set<String> = []) throws {
        let keyName = SecretSettings.linearAPIKeyName
        try secrets.setValue(settings.linearAPIKey, forAccount: keyName)

        var kept = Set(settings.extraEnvironment.map(\.name)).union([keyName])
        if !settings.openRouterAPIKey.isEmpty {
            try secrets.setValue(settings.openRouterAPIKey, forAccount: SecretSettings.openRouterAPIKeyName)
            kept.insert(SecretSettings.openRouterAPIKeyName)
        }

        for variable in settings.extraEnvironment {
            try secrets.setValue(variable.value, forAccount: variable.name)
        }
        for account in removed.subtracting(kept).sorted() {
            try secrets.removeValue(forAccount: account)
        }
    }
}
