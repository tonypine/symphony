import XCTest
@testable import SymphonyBarCore

/// Factory › Providers' keys (TP-1540): which providers take a key, Enable kept apart from the key, the keys and the
/// enabled set in the secret store, and the start from a key the old Settings saved.
final class ProviderKeysTests: XCTestCase {
    func testOnlyOpenRouterAndOpenCodeGoTakeAKey() {
        XCTAssertEqual(ProviderKeys.all.map(\.id), ["openrouter", "opencode-go"])
        XCTAssertEqual(ProviderKeys.spec("openrouter")?.variable, "OPENROUTER_API_KEY")
        XCTAssertEqual(ProviderKeys.spec("opencode-go")?.variable, "OPENCODE_API_KEY")
        XCTAssertNil(ProviderKeys.spec("anthropic"), "Anthropic signs in through its harness")
        XCTAssertNil(ProviderKeys.spec("openai"))
        XCTAssertEqual(ProviderKeys.reservedNames, ["OPENROUTER_API_KEY", "OPENCODE_API_KEY", ProviderKeys.enabledAccount])
        XCTAssertTrue(SecretSettings.reservedNames.isSuperset(of: ProviderKeys.reservedNames), "never an extra variable")
    }

    func testEnableIsItsOwnSwitchAndNeedsAKey() {
        let keys = ProviderKeys(keys: ["opencode-go": "sk-go", "openrouter": ""])
        XCTAssertEqual(keys.keys, ["opencode-go": "sk-go"], "a blank key is no key")
        XCTAssertFalse(keys.isEnabled("opencode-go"), "saving a key doesn't enable it")
        XCTAssertEqual(keys.off, ["openrouter", "opencode-go"])

        let on = keys.enabling("opencode-go", true)
        XCTAssertTrue(on.isEnabled("opencode-go"))
        XCTAssertEqual(on.off, ["openrouter"])
        XCTAssertEqual(on.environment, ["OPENCODE_API_KEY": "sk-go"])

        let off = on.enabling("opencode-go", false)
        XCTAssertEqual(off.keys, on.keys, "Disable keeps the key")
        XCTAssertEqual(off.environment, [:])

        // A new key or no key leaves Enable as it was; with no key the provider is not on.
        XCTAssertEqual(on.setting(" sk-go-2 ", for: "opencode-go").enabled, ["opencode-go"])
        XCTAssertEqual(on.setting(" sk-go-2 ", for: "opencode-go").keys["opencode-go"], "sk-go-2")
        let cleared = on.setting("  ", for: "opencode-go")
        XCTAssertEqual(cleared.enabled, ["opencode-go"])
        XCTAssertFalse(cleared.isEnabled("opencode-go"))
        XCTAssertEqual(cleared.environment, [:])
        XCTAssertFalse(ProviderKeys().enabling("openrouter", true).isEnabled("openrouter"), "no key, never on")
    }

    func testTheKeyReachesTheEnvironmentOnlyWhileEnabled() {
        var environment = ["OPENROUTER_API_KEY": "from-the-shell", "PATH": "/usr/bin"]
        ProviderKeys(keys: ["openrouter": "sk-or", "opencode-go": "sk-go"], enabled: ["opencode-go"]).apply(to: &environment)
        XCTAssertEqual(environment, ["OPENCODE_API_KEY": "sk-go", "PATH": "/usr/bin"])
    }

    func testAKeyTheOldSettingsSavedStartsEnabled() throws {
        let store = MemorySecretStore()
        store.values = ["OPENROUTER_API_KEY": " sk-or-old "]
        let keys = try ProviderKeys.load(from: store)
        XCTAssertEqual(keys.keys, ["openrouter": "sk-or-old"])
        XCTAssertTrue(keys.isEnabled("openrouter"))
        XCTAssertFalse(keys.isEnabled("opencode-go"))

        // The first write keeps that start, so a key saved later for another provider doesn't enable it.
        let added = keys.setting("sk-go", for: "opencode-go")
        try added.save(to: store, over: keys)
        XCTAssertEqual(store.values[ProviderKeys.enabledAccount], "openrouter")
        let reloaded = try ProviderKeys.load(from: store)
        XCTAssertTrue(reloaded.isEnabled("openrouter"))
        XCTAssertFalse(reloaded.isEnabled("opencode-go"))
    }

    func testTheEnabledSetIsReadAsStored() throws {
        let store = MemorySecretStore()
        store.values = [
            "OPENROUTER_API_KEY": "sk-or", "OPENCODE_API_KEY": "sk-go", ProviderKeys.enabledAccount: " opencode-go, ,unknown",
        ]
        let keys = try ProviderKeys.load(from: store)
        XCTAssertEqual(keys.enabled, ["opencode-go", "unknown"])
        XCTAssertFalse(keys.isEnabled("openrouter"), "a disabled provider stays off after a relaunch")
        XCTAssertTrue(keys.isEnabled("opencode-go"))

        // Only what changed is written: removing a key takes it out, the other key stays.
        try keys.setting("", for: "openrouter").save(to: store, over: keys)
        XCTAssertNil(store.values["OPENROUTER_API_KEY"])
        XCTAssertEqual(store.values["OPENCODE_API_KEY"], "sk-go")
        XCTAssertEqual(store.values[ProviderKeys.enabledAccount], "opencode-go")
    }
}
