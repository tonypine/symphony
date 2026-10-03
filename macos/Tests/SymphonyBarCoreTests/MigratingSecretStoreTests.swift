import Security
import XCTest
@testable import SymphonyBarCore

/// A Keychain stand-in that counts reads and can fail them or the deletes.
private final class LegacyKeychain: SecretStore {
    var values: [String: String] = [:]
    var readError: Error?
    var deleteError: Error?
    private(set) var reads = 0

    func value(forAccount account: String) throws -> String? {
        reads += 1
        if let readError { throw readError }
        return values[account]
    }

    func setValue(_ value: String, forAccount account: String) throws { values[account] = value }

    func removeValue(forAccount account: String) throws {
        if let deleteError { throw deleteError }
        values[account] = nil
    }

    func accounts() throws -> [String] { values.keys.sorted() }
}

final class MigratingSecretStoreTests: XCTestCase {
    private var root: URL!
    private var keychain: LegacyKeychain!
    private var store: MigratingSecretStore!

    override func setUp() {
        root = uniqueTemporaryDirectory("secrets")
        keychain = LegacyKeychain()
        store = MigratingSecretStore(
            file: FileSecretStore(file: root.appendingPathComponent("release/secrets.json")),
            keychain: keychain
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var fileExists: Bool { FileManager.default.fileExists(atPath: store.file.file.path) }

    func testTheDefaultFileIsNextToTheReleaseControlToken() {
        let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

        XCTAssertEqual(
            MigratingSecretStore.defaultFile(home: home).path,
            "/Users/me/Library/Application Support/symphony/release/secrets.json"
        )
        XCTAssertEqual(
            MigratingSecretStore.defaultFile(home: home).deletingLastPathComponent(),
            StateRoot.controlTokenFile(in: StateRoot.defaultDirectory(home: home).appendingPathComponent("release"))
                .deletingLastPathComponent()
        )
    }

    func testMovesBothKeysAndExtraVariablesOutOfTheKeychainOnce() throws {
        keychain.values = [
            SecretSettings.linearAPIKeyName: "lin_api_1",
            SecretSettings.openRouterAPIKeyName: "sk-or-v1-1",
            "GITHUB_TOKEN": "ghp-1",
        ]
        let settings = SettingsStore(defaults: MemoryKeyValueStore(), secrets: store)

        XCTAssertEqual(
            try settings.loadSecrets(),
            SecretSettings(
                linearAPIKey: "lin_api_1",
                openRouterAPIKey: "sk-or-v1-1",
                extraEnvironment: [EnvironmentVariable(name: "GITHUB_TOKEN", value: "ghp-1")]
            )
        )
        XCTAssertEqual(keychain.values, [:])
        XCTAssertEqual(keychain.reads, 3)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.file.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        // As after an update: a new store over the same file never reads the Keychain again.
        keychain.values = [SecretSettings.linearAPIKeyName: "stale"]
        let updated = MigratingSecretStore(file: store.file, keychain: keychain)
        try SettingsStore(defaults: MemoryKeyValueStore(), secrets: updated).saveSecrets(
            SecretSettings(linearAPIKey: "lin_api_2", openRouterAPIKey: "sk-or-v1-2", extraEnvironment: [])
        )
        let loaded = try SettingsStore(defaults: MemoryKeyValueStore(), secrets: updated).loadSecrets()

        XCTAssertEqual(loaded.linearAPIKey, "lin_api_2")
        XCTAssertEqual(loaded.openRouterAPIKey, "sk-or-v1-2")
        XCTAssertEqual(keychain.reads, 3)
        XCTAssertEqual(keychain.values, [SecretSettings.linearAPIKeyName: "stale"])
    }

    func testAFreshInstallWritesAnEmptyFileAndNeverLooksAtTheKeychainAgain() throws {
        XCTAssertEqual(try store.accounts(), [])
        XCTAssertTrue(fileExists)

        keychain.values = ["LATE": "x"]
        XCTAssertNil(try store.value(forAccount: "LATE"))
        try store.setValue("v", forAccount: "A")
        try store.removeValue(forAccount: "A")
        XCTAssertEqual(try store.accounts(), [])
        XCTAssertEqual(keychain.reads, 0)
    }

    func testAFailedKeychainReadWritesNothingAndIsRetried() throws {
        keychain.values = [SecretSettings.linearAPIKeyName: "lin_api_1"]
        keychain.readError = KeychainError(status: errSecAuthFailed)

        XCTAssertThrowsError(try store.value(forAccount: SecretSettings.linearAPIKeyName)) { error in
            XCTAssertEqual(error as? KeychainError, KeychainError(status: errSecAuthFailed))
        }
        XCTAssertFalse(fileExists)
        XCTAssertEqual(keychain.values, [SecretSettings.linearAPIKeyName: "lin_api_1"])

        keychain.readError = nil
        XCTAssertEqual(try store.value(forAccount: SecretSettings.linearAPIKeyName), "lin_api_1")
        XCTAssertEqual(keychain.values, [:])
    }

    func testAFailedDeleteKeepsTheMigratedValues() throws {
        keychain.values = [SecretSettings.linearAPIKeyName: "lin_api_1"]
        keychain.deleteError = KeychainError(status: errSecAuthFailed)

        XCTAssertEqual(try store.value(forAccount: SecretSettings.linearAPIKeyName), "lin_api_1")
        XCTAssertEqual(try store.accounts(), [SecretSettings.linearAPIKeyName])
        XCTAssertEqual(keychain.reads, 1)
    }

    func testAFailedFileWriteLeavesTheKeychainItems() throws {
        // The parent "directory" is a file, so the secrets file can't be created.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("release"))
        keychain.values = [SecretSettings.linearAPIKeyName: "lin_api_1"]

        XCTAssertThrowsError(try store.accounts())
        XCTAssertThrowsError(try store.setValue("v", forAccount: "A"))
        XCTAssertThrowsError(try store.removeValue(forAccount: "A"))
        XCTAssertEqual(keychain.values, [SecretSettings.linearAPIKeyName: "lin_api_1"])
    }
}
