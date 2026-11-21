import XCTest
@testable import SymphonyBarCore

final class SettingsStoreTests: XCTestCase {
    func testLoadSettingsReturnsDefaultsWhenNothingIsStored() {
        let store = SettingsStore(defaults: MemoryKeyValueStore(), secrets: MemorySecretStore())

        XCTAssertEqual(store.loadSettings(), AppSettings())
        XCTAssertEqual(store.loadSettings().stopTimeoutSeconds, AppSettings.defaultStopTimeoutSeconds)
        XCTAssertEqual(store.loadSettings().restartTimeoutMinutes, 30)
        XCTAssertFalse(store.loadSettings().startOnLaunch)
        XCTAssertEqual(store.loadSettings().updateMode, .onRelease, "a fresh install updates when released")
        XCTAssertEqual(store.loadSettings().updateTime, TimeOfDay(hour: 3, minute: 0))
        XCTAssertEqual(store.loadSettings().releaseCheckMinutes, 5)
    }

    func testReleaseCheckMinutesRoundTripThroughANewStore() {
        let defaults = MemoryKeyValueStore()
        var settings = AppSettings()
        settings.releaseCheckMinutes = 10

        SettingsStore(defaults: defaults, secrets: MemorySecretStore()).saveSettings(settings)

        XCTAssertEqual(defaults.values[SettingsStore.Key.releaseCheckMinutes] as? Int, 10)
        let reopened = SettingsStore(defaults: defaults, secrets: MemorySecretStore()).loadSettings()
        XCTAssertEqual(reopened.releaseCheckMinutes, 10)
    }

    func testAStoredReleaseCheckMinutesOutsideTheRangeIsClampedWhenLoaded() {
        for (stored, loaded) in [(0, 2), (-3, 2), (1, 2), (2, 2), (60, 60), (61, 60), (1_000, 60)] {
            let defaults = MemoryKeyValueStore()
            defaults.values[SettingsStore.Key.releaseCheckMinutes] = stored

            let settings = SettingsStore(defaults: defaults, secrets: MemorySecretStore()).loadSettings()

            XCTAssertEqual(settings.releaseCheckMinutes, loaded, "\(stored)")
        }
        let unreadable = MemoryKeyValueStore()
        unreadable.values[SettingsStore.Key.releaseCheckMinutes] = "ten"
        let fallback = SettingsStore(defaults: unreadable, secrets: MemorySecretStore()).loadSettings()
        XCTAssertEqual(fallback.releaseCheckMinutes, 5)
    }

    func testTheNotAnsweringAlertDefaultsToAMinuteAndIsClampedWhenLoaded() {
        // TP-1562: how long Symphony may not answer before the menu bar shows it and one notification goes out.
        let fresh = SettingsStore(defaults: MemoryKeyValueStore(), secrets: MemorySecretStore()).loadSettings()
        XCTAssertEqual(fresh.notAnsweringAlertSeconds, 60)
        for (stored, loaded) in [(0, 10), (10, 10), (90, 90), (3_600, 3_600), (5_000, 3_600)] {
            let defaults = MemoryKeyValueStore()
            defaults.values[SettingsStore.Key.notAnsweringAlertSeconds] = stored

            let settings = SettingsStore(defaults: defaults, secrets: MemorySecretStore()).loadSettings()

            XCTAssertEqual(settings.notAnsweringAlertSeconds, loaded, "\(stored)")
        }
        var settings = AppSettings()
        settings.notAnsweringAlertSeconds = 120
        let defaults = MemoryKeyValueStore()
        SettingsStore(defaults: defaults, secrets: MemorySecretStore()).saveSettings(settings)
        XCTAssertEqual(defaults.values[SettingsStore.Key.notAnsweringAlertSeconds] as? Int, 120)
    }

    func testAnExistingInstallWithoutAStoredUpdateModeGetsOnRelease() {
        let defaults = MemoryKeyValueStore()
        defaults.values[SettingsStore.Key.configPath] = "/src/symphony/symphony.yml"
        defaults.values[SettingsStore.Key.startOnLaunch] = true

        let settings = SettingsStore(defaults: defaults, secrets: MemorySecretStore()).loadSettings()

        XCTAssertEqual(settings.updateMode, .onRelease, "no migration keeps it on Manual")
        XCTAssertEqual(settings.updateTime, .defaultUpdateTime)
        XCTAssertNil(defaults.values[SettingsStore.Key.updateMode], "loading stores nothing")
    }

    func testAStoredUpdateModeIsNeverChanged() {
        for mode in UpdateMode.allCases {
            let defaults = MemoryKeyValueStore()
            defaults.values[SettingsStore.Key.updateMode] = mode.rawValue

            XCTAssertEqual(SettingsStore(defaults: defaults, secrets: MemorySecretStore()).loadSettings().updateMode, mode)
        }
    }

    func testUpdateModeAndTimeRoundTripThroughANewStore() {
        let defaults = MemoryKeyValueStore()
        var settings = AppSettings()
        settings.updateMode = .atTime
        settings.updateTime = TimeOfDay(hour: 22, minute: 30)

        SettingsStore(defaults: defaults, secrets: MemorySecretStore()).saveSettings(settings)
        let reopened = SettingsStore(defaults: defaults, secrets: MemorySecretStore()).loadSettings()

        XCTAssertEqual(reopened.updateMode, .atTime)
        XCTAssertEqual(reopened.updateTime, TimeOfDay(hour: 22, minute: 30))
        XCTAssertEqual(defaults.values[SettingsStore.Key.updateMode] as? String, "atTime")
        XCTAssertEqual(defaults.values[SettingsStore.Key.updateTime] as? Int, 22 * 60 + 30)
    }

    func testManualAndOnReleaseRoundTripThroughANewStore() {
        let defaults = MemoryKeyValueStore()
        for mode in [UpdateMode.manual, .onRelease] {
            var settings = AppSettings()
            settings.updateMode = mode

            SettingsStore(defaults: defaults, secrets: MemorySecretStore()).saveSettings(settings)

            XCTAssertEqual(defaults.values[SettingsStore.Key.updateMode] as? String, mode.rawValue)
            XCTAssertEqual(SettingsStore(defaults: defaults, secrets: MemorySecretStore()).loadSettings().updateMode, mode)
        }
    }

    func testUnreadableUpdateSettingsFallBackToTheDefaults() {
        for (mode, time) in [("hourly", 1440), ("", -5)] as [(Any, Any)] + [(3, "03:00")] {
            let defaults = MemoryKeyValueStore()
            defaults.values[SettingsStore.Key.updateMode] = mode
            defaults.values[SettingsStore.Key.updateTime] = time

            let settings = SettingsStore(defaults: defaults, secrets: MemorySecretStore()).loadSettings()

            XCTAssertEqual(settings.updateMode, .onRelease, "\(mode)")
            XCTAssertEqual(settings.updateTime, .defaultUpdateTime, "\(time)")
        }
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
            developmentMode: true,
            updateMode: .whenIdle,
            updateTime: TimeOfDay(hour: 4, minute: 15),
            releaseCheckMinutes: 42,
            notAnsweringAlertSeconds: 90
        )

        SettingsStore(defaults: defaults, secrets: MemorySecretStore()).saveSettings(settings)
        let reopened = SettingsStore(defaults: defaults, secrets: MemorySecretStore())

        XCTAssertEqual(reopened.loadSettings(), settings)
        XCTAssertEqual(settings.trimmed(), settings, "trimming keeps every setting")
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

    func testAKeySavedByTheOldSettingsIsReadAsTheProvidersAndStartsEnabled() throws {
        let keychain = MemorySecretStore()
        keychain.values = [
            SecretSettings.linearAPIKeyName: "one", "OPENROUTER_API_KEY": "sk-or-v1-old", "GITHUB_TOKEN": "ghp-a",
        ]

        let loaded = try SettingsStore(defaults: MemoryKeyValueStore(), secrets: keychain).loadSecrets()

        XCTAssertEqual(loaded.providers.keys, ["openrouter": "sk-or-v1-old"])
        XCTAssertTrue(loaded.providers.isEnabled("openrouter"), "nothing that works today stops")
        XCTAssertEqual(loaded.extraEnvironment, [EnvironmentVariable(name: "GITHUB_TOKEN", value: "ghp-a")], "never an extra variable")
    }

    func testAnOpenCodeKeySetAsAVariableMovesToItsProviderAndStartsEnabled() throws {
        let keychain = MemorySecretStore()
        keychain.values = [SecretSettings.linearAPIKeyName: "one", "OPENCODE_API_KEY": "sk-go-old"]

        let loaded = try SettingsStore(defaults: MemoryKeyValueStore(), secrets: keychain).loadSecrets()

        XCTAssertEqual(loaded, SecretSettings(linearAPIKey: "one", providers: ProviderKeys(keys: ["opencode-go": "sk-go-old"], enabled: ["opencode-go"])))
    }

    func testSettingsNeverWritesOrRemovesAProviderKey() throws {
        let keychain = MemorySecretStore()
        keychain.values = [
            SecretSettings.linearAPIKeyName: "one", "OPENROUTER_API_KEY": "sk-or-v1-a", ProviderKeys.enabledAccount: "openrouter",
        ]
        let store = SettingsStore(defaults: MemoryKeyValueStore(), secrets: keychain)

        try store.saveSecrets(
            SecretSettings(linearAPIKey: "two", providers: ProviderKeys(keys: ["opencode-go": "sk-go"], enabled: ["opencode-go"])),
            removing: ["OPENROUTER_API_KEY", ProviderKeys.enabledAccount]
        )

        XCTAssertEqual(
            keychain.values,
            [SecretSettings.linearAPIKeyName: "two", "OPENROUTER_API_KEY": "sk-or-v1-a", ProviderKeys.enabledAccount: "openrouter"]
        )
    }

    func testProviderKeysSaveLoadAndRemove() throws {
        let keychain = MemorySecretStore()
        let store = SettingsStore(defaults: MemoryKeyValueStore(), secrets: keychain)
        let none = try store.loadProviderKeys()
        XCTAssertEqual(none, ProviderKeys())

        let saved = none.setting(" sk-go-1 ", for: "opencode-go")
        try store.saveProviderKeys(saved, over: none)
        XCTAssertEqual(keychain.values["OPENCODE_API_KEY"], "sk-go-1")
        XCTAssertEqual(keychain.values[ProviderKeys.enabledAccount], "", "saving a key doesn't enable it")
        let loaded = try store.loadProviderKeys()
        XCTAssertEqual(loaded.keys, ["opencode-go": "sk-go-1"])
        XCTAssertFalse(loaded.isEnabled("opencode-go"))

        let enabled = loaded.enabling("opencode-go", true)
        try store.saveProviderKeys(enabled, over: loaded)
        XCTAssertEqual(keychain.values[ProviderKeys.enabledAccount], "opencode-go")
        XCTAssertTrue(try store.loadProviderKeys().isEnabled("opencode-go"))

        let disabled = enabled.enabling("opencode-go", false)
        try store.saveProviderKeys(disabled, over: enabled)
        XCTAssertEqual(try store.loadProviderKeys().keys, ["opencode-go": "sk-go-1"], "Disable keeps the key")

        let removed = enabled.setting("", for: "opencode-go")
        try store.saveProviderKeys(removed, over: enabled)
        XCTAssertNil(keychain.values["OPENCODE_API_KEY"])
        let reloaded = try store.loadProviderKeys()
        XCTAssertEqual(reloaded.enabled, ["opencode-go"], "removing a key doesn't change Enable")
        XCTAssertFalse(reloaded.isEnabled("opencode-go"), "a provider with no key is never on")
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
                providers: ProviderKeys(keys: ["openrouter": "sk-or-v1-secret"], enabled: ["openrouter"]),
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
                SettingsStore.Key.updateMode,
                SettingsStore.Key.updateTime,
                SettingsStore.Key.releaseCheckMinutes,
                SettingsStore.Key.notAnsweringAlertSeconds,
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
