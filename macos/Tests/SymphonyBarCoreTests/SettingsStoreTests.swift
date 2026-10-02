import XCTest
@testable import SymphonyBarCore

final class SettingsStoreTests: XCTestCase {
    func testLoadSettingsReturnsDefaultsWhenNothingIsStored() {
        let store = SettingsStore(defaults: MemoryKeyValueStore(), secrets: MemorySecretStore())

        XCTAssertEqual(store.loadSettings(), AppSettings())
        XCTAssertEqual(store.loadSettings().stopTimeoutSeconds, AppSettings.defaultStopTimeoutSeconds)
        XCTAssertFalse(store.loadSettings().startOnLaunch)
    }

    func testSettingsRoundTripThroughANewStore() {
        let defaults = MemoryKeyValueStore()
        let settings = AppSettings(
            checkoutPath: "/src/symphony",
            configPath: "/src/symphony/symphony.yml",
            commandPrefix: "mise exec --",
            stopTimeoutSeconds: 45,
            startOnLaunch: true
        )

        SettingsStore(defaults: defaults, secrets: MemorySecretStore()).saveSettings(settings)
        let reopened = SettingsStore(defaults: defaults, secrets: MemorySecretStore())

        XCTAssertEqual(reopened.loadSettings(), settings)
    }

    func testSecretsRoundTripThroughANewStore() throws {
        let keychain = MemorySecretStore()
        let secrets = SecretSettings(
            linearAPIKey: "lin_api_secret",
            extraEnvironment: [
                EnvironmentVariable(name: "OPENAI_API_KEY", value: "sk-b"),
                EnvironmentVariable(name: "GITHUB_TOKEN", value: "ghp-a"),
            ]
        )

        try SettingsStore(defaults: MemoryKeyValueStore(), secrets: keychain).saveSecrets(secrets)
        let loaded = try SettingsStore(defaults: MemoryKeyValueStore(), secrets: keychain).loadSecrets()

        XCTAssertEqual(loaded.linearAPIKey, "lin_api_secret")
        XCTAssertEqual(
            loaded.extraEnvironment,
            [
                EnvironmentVariable(name: "GITHUB_TOKEN", value: "ghp-a"),
                EnvironmentVariable(name: "OPENAI_API_KEY", value: "sk-b"),
            ]
        )
        XCTAssertEqual(keychain.values[SecretSettings.linearAPIKeyName], "lin_api_secret")
    }

    func testSavingSecretsRemovesOnlyTheNamedVariables() throws {
        let keychain = MemorySecretStore()
        let store = SettingsStore(defaults: MemoryKeyValueStore(), secrets: keychain)
        try store.saveSecrets(
            SecretSettings(
                linearAPIKey: "one",
                extraEnvironment: [
                    EnvironmentVariable(name: "KEEP", value: "1"),
                    EnvironmentVariable(name: "DROP", value: "2"),
                    EnvironmentVariable(name: "UNLISTED", value: "4"),
                ]
            )
        )

        try store.saveSecrets(
            SecretSettings(linearAPIKey: "two", extraEnvironment: [EnvironmentVariable(name: "KEEP", value: "3")]),
            removing: ["DROP"]
        )

        XCTAssertEqual(keychain.values, [SecretSettings.linearAPIKeyName: "two", "KEEP": "3", "UNLISTED": "4"])
    }

    func testSavingAnEmptyListRemovesNothingByDefault() throws {
        let keychain = MemorySecretStore()
        keychain.values = [SecretSettings.linearAPIKeyName: "one", "GITHUB_TOKEN": "ghp-a"]
        let store = SettingsStore(defaults: MemoryKeyValueStore(), secrets: keychain)

        try store.saveSecrets(SecretSettings(linearAPIKey: "two"))

        XCTAssertEqual(keychain.values, [SecretSettings.linearAPIKeyName: "two", "GITHUB_TOKEN": "ghp-a"])
    }

    func testSavingNeverRemovesTheLinearKeyOrAListedName() throws {
        let keychain = MemorySecretStore()
        let store = SettingsStore(defaults: MemoryKeyValueStore(), secrets: keychain)

        try store.saveSecrets(
            SecretSettings(linearAPIKey: "one", extraEnvironment: [EnvironmentVariable(name: "KEEP", value: "1")]),
            removing: [SecretSettings.linearAPIKeyName, "KEEP"]
        )

        XCTAssertEqual(keychain.values, [SecretSettings.linearAPIKeyName: "one", "KEEP": "1"])
    }

    func testSecretsAreNeverWrittenToDefaults() throws {
        let defaults = MemoryKeyValueStore()
        let store = SettingsStore(defaults: defaults, secrets: MemorySecretStore())

        store.saveSettings(AppSettings(checkoutPath: "/src", configPath: "/src/symphony.yml"))
        try store.saveSecrets(
            SecretSettings(
                linearAPIKey: "lin_api_secret",
                extraEnvironment: [EnvironmentVariable(name: "OTHER_TOKEN", value: "other-secret")]
            )
        )

        XCTAssertEqual(
            Set(defaults.values.keys),
            [
                SettingsStore.Key.checkoutPath,
                SettingsStore.Key.configPath,
                SettingsStore.Key.commandPrefix,
                SettingsStore.Key.stopTimeoutSeconds,
                SettingsStore.Key.startOnLaunch,
            ]
        )
        for value in defaults.values.values {
            let text = "\(value)"
            XCTAssertFalse(text.contains("lin_api_secret"))
            XCTAssertFalse(text.contains("other-secret"))
            XCTAssertFalse(text.contains("OTHER_TOKEN"))
        }
    }

    func testKeychainStoreUsesTheSymphonyService() {
        XCTAssertEqual(KeychainSecretStore().service, "symphony")
        XCTAssertEqual(SecretSettings.linearAPIKeyName, "LINEAR_API_KEY")
    }
}
