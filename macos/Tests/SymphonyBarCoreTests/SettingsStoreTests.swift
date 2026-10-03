import XCTest
@testable import SymphonyBarCore

final class SettingsStoreTests: XCTestCase {
    func testLoadSettingsReturnsDefaultsWhenNothingIsStored() {
        let store = SettingsStore(defaults: MemoryKeyValueStore(), secrets: MemorySecretStore())

        XCTAssertEqual(store.loadSettings(), AppSettings())
        XCTAssertEqual(store.loadSettings().stopTimeoutSeconds, AppSettings.defaultStopTimeoutSeconds)
        XCTAssertEqual(store.loadSettings().restartTimeoutMinutes, 30)
        XCTAssertFalse(store.loadSettings().startOnLaunch)
    }

    func testCommandPrefixDefaultsToMiseUntilSavedEvenWhenCleared() {
        let defaults = MemoryKeyValueStore()
        let store = SettingsStore(defaults: defaults, secrets: MemorySecretStore())
        XCTAssertEqual(store.loadSettings().commandPrefix, "mise exec --")

        store.saveSettings(AppSettings(commandPrefix: ""))

        XCTAssertEqual(store.loadSettings().commandPrefix, "")
    }

    func testSettingsRoundTripThroughANewStore() {
        let defaults = MemoryKeyValueStore()
        let settings = AppSettings(
            checkoutPath: "/src/symphony",
            configPath: "/src/symphony/symphony.yml",
            commandPrefix: "mise exec --",
            stopTimeoutSeconds: 45,
            restartTimeoutMinutes: 5,
            startOnLaunch: true,
            developmentMode: true
        )

        SettingsStore(defaults: defaults, secrets: MemorySecretStore()).saveSettings(settings)
        let reopened = SettingsStore(defaults: defaults, secrets: MemorySecretStore())

        XCTAssertEqual(reopened.loadSettings(), settings)
    }

    func testDevelopmentModeIsOffUntilSaved() {
        let store = SettingsStore(defaults: MemoryKeyValueStore(), secrets: MemorySecretStore())
        XCTAssertFalse(store.loadSettings().developmentMode)
    }

    func testMigrationTurnsDevelopmentModeOnForACheckoutWithoutAnEmbeddedSymphony() {
        let defaults = MemoryKeyValueStore()
        defaults.values[SettingsStore.Key.checkoutPath] = "/src/symphony"
        let store = SettingsStore(defaults: defaults, secrets: MemorySecretStore())

        store.migrateDevelopmentMode(embeddedSymphonyAvailable: false)

        XCTAssertTrue(store.loadSettings().developmentMode)
        XCTAssertEqual(defaults.values[SettingsStore.Key.developmentMode] as? Bool, true)
    }

    func testMigrationLeavesDevelopmentModeOffOtherwise() {
        for (checkout, embedded) in [("/src/symphony", true), ("", false), ("  ", false), ("", true)] {
            let defaults = MemoryKeyValueStore()
            defaults.values[SettingsStore.Key.checkoutPath] = checkout
            let store = SettingsStore(defaults: defaults, secrets: MemorySecretStore())

            store.migrateDevelopmentMode(embeddedSymphonyAvailable: embedded)

            XCTAssertEqual(defaults.values[SettingsStore.Key.developmentMode] as? Bool, false, "\(checkout) \(embedded)")
        }
        let fresh = MemoryKeyValueStore()
        SettingsStore(defaults: fresh, secrets: MemorySecretStore()).migrateDevelopmentMode(embeddedSymphonyAvailable: false)
        XCTAssertEqual(fresh.values[SettingsStore.Key.developmentMode] as? Bool, false)
    }

    func testMigrationRunsOnlyOnceAndKeepsTheSavedChoice() {
        let defaults = MemoryKeyValueStore()
        let store = SettingsStore(defaults: defaults, secrets: MemorySecretStore())
        store.saveSettings(AppSettings(checkoutPath: "/src/symphony", developmentMode: false))

        store.migrateDevelopmentMode(embeddedSymphonyAvailable: false)
        XCTAssertFalse(store.loadSettings().developmentMode)

        store.saveSettings(AppSettings(developmentMode: true))
        store.migrateDevelopmentMode(embeddedSymphonyAvailable: true)
        XCTAssertTrue(store.loadSettings().developmentMode)
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

    func testOpenRouterKeyRoundTripsThroughTheKeychainAndIsNotAnExtraVariable() throws {
        let keychain = MemorySecretStore()
        try SettingsStore(defaults: MemoryKeyValueStore(), secrets: keychain).saveSecrets(
            SecretSettings(
                linearAPIKey: "lin_api_secret",
                openRouterAPIKey: "sk-or-v1-secret",
                extraEnvironment: [EnvironmentVariable(name: "GITHUB_TOKEN", value: "ghp-a")]
            )
        )

        XCTAssertEqual(keychain.values[SecretSettings.openRouterAPIKeyName], "sk-or-v1-secret")
        let loaded = try SettingsStore(defaults: MemoryKeyValueStore(), secrets: keychain).loadSecrets()
        XCTAssertEqual(loaded.openRouterAPIKey, "sk-or-v1-secret")
        XCTAssertEqual(loaded.extraEnvironment, [EnvironmentVariable(name: "GITHUB_TOKEN", value: "ghp-a")])
        XCTAssertEqual(SecretSettings.openRouterAPIKeyName, "OPENROUTER_API_KEY")
    }

    func testOpenRouterKeyStoredAsAnExtraVariableLoadsIntoItsField() throws {
        let keychain = MemorySecretStore()
        keychain.values = [SecretSettings.linearAPIKeyName: "one", "OPENROUTER_API_KEY": "sk-or-v1-old"]

        let loaded = try SettingsStore(defaults: MemoryKeyValueStore(), secrets: keychain).loadSecrets()

        XCTAssertEqual(loaded, SecretSettings(linearAPIKey: "one", openRouterAPIKey: "sk-or-v1-old"))
    }

    func testABlankOpenRouterKeyIsRemovedOnlyWhenNamed() throws {
        let keychain = MemorySecretStore()
        keychain.values = [SecretSettings.linearAPIKeyName: "one", SecretSettings.openRouterAPIKeyName: "sk-or-v1-a"]
        let store = SettingsStore(defaults: MemoryKeyValueStore(), secrets: keychain)

        // As after a failed Keychain read: the field is blank but the stored key was never loaded.
        try store.saveSecrets(SecretSettings(linearAPIKey: "one"))
        XCTAssertEqual(keychain.values[SecretSettings.openRouterAPIKeyName], "sk-or-v1-a")

        // A set key is kept even when named.
        try store.saveSecrets(
            SecretSettings(linearAPIKey: "one", openRouterAPIKey: "sk-or-v1-b"),
            removing: [SecretSettings.openRouterAPIKeyName]
        )
        XCTAssertEqual(keychain.values[SecretSettings.openRouterAPIKeyName], "sk-or-v1-b")

        try store.saveSecrets(SecretSettings(linearAPIKey: "one"), removing: [SecretSettings.openRouterAPIKeyName])
        XCTAssertEqual(keychain.values, [SecretSettings.linearAPIKeyName: "one"])
        XCTAssertEqual(try store.loadSecrets().openRouterAPIKey, "")
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
                openRouterAPIKey: "sk-or-v1-secret",
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
                SettingsStore.Key.restartTimeoutMinutes,
                SettingsStore.Key.startOnLaunch,
                SettingsStore.Key.developmentMode,
            ]
        )
        for value in defaults.values.values {
            let text = "\(value)"
            XCTAssertFalse(text.contains("lin_api_secret"))
            XCTAssertFalse(text.contains("sk-or-v1-secret"))
            XCTAssertFalse(text.contains("other-secret"))
            XCTAssertFalse(text.contains("OTHER_TOKEN"))
        }
    }

    func testKeychainStoreUsesTheSymphonyService() {
        XCTAssertEqual(KeychainSecretStore().service, "symphony")
        XCTAssertEqual(SecretSettings.linearAPIKeyName, "LINEAR_API_KEY")
    }
}
