import XCTest
@testable import SymphonyBarCore

/// The webhook secret Symphony hands off: moved into the app's secret item through an injectable store, passed to
/// Symphony at launch, and never shown, logged or kept in what a move answers.
final class WebhookSecretTests: XCTestCase {
    private let secret = "4f1c0de5ec4e7a11ab1e5ec7e7dead0b4f1c0de5ec4e7a11ab1e5ec7e7dead0b"
    private var root: URL!

    override func setUpWithError() throws {
        root = uniqueTemporaryDirectory("webhook-secret")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var handOff: URL { WebhookSecret.handOffFile(stateRoot: root) }

    /// A store that refuses every write, naming its status as the Keychain does.
    private final class RefusingStore: SecretStore {
        func value(forAccount account: String) throws -> String? { nil }
        func setValue(_ value: String, forAccount account: String) throws { throw KeychainError(status: errSecAuthFailed) }
        func removeValue(forAccount account: String) throws {}
        func accounts() throws -> [String] { [] }
    }

    func testTheHandedOffSecretMovesIntoTheSecretItemAndTheFileGoes() throws {
        try (secret + "\n").write(to: handOff, atomically: true, encoding: .utf8)
        let store = MemorySecretStore()

        XCTAssertEqual(handOff.lastPathComponent, "github_webhook_secret")
        XCTAssertFalse(WebhookSecret.isStored(in: store))
        XCTAssertEqual(WebhookSecret.moveHandOff(from: handOff, into: store), .saved)

        XCTAssertEqual(store.values, ["symphony-github-webhook": secret])
        XCTAssertTrue(WebhookSecret.isStored(in: store))
        XCTAssertFalse(FileManager.default.fileExists(atPath: handOff.path))
        // Moving again finds nothing and keeps what the item holds.
        XCTAssertEqual(WebhookSecret.moveHandOff(from: handOff, into: store), .nothingHandedOff)
        XCTAssertEqual(store.values["symphony-github-webhook"], secret)
    }

    func testAnEmptyHandOffIsNothingAndAStoreThatRefusesKeepsTheFile() throws {
        try "  \n".write(to: handOff, atomically: true, encoding: .utf8)
        XCTAssertEqual(WebhookSecret.moveHandOff(from: handOff, into: MemorySecretStore()), .nothingHandedOff)

        try secret.write(to: handOff, atomically: true, encoding: .utf8)
        let move = WebhookSecret.moveHandOff(from: handOff, into: RefusingStore())

        guard case let .failed(message) = move else { return XCTFail("expected a failure, got \(move)") }
        XCTAssertTrue(message.hasPrefix("Couldn't save the webhook secret in your Keychain: Keychain error"), message)
        XCTAssertFalse(message.contains(secret), "the reason never holds the secret")
        XCTAssertFalse(String(describing: move).contains(secret))
        XCTAssertTrue(FileManager.default.fileExists(atPath: handOff.path), "Symphony still reads the hand-off")
        XCTAssertFalse(WebhookSecret.isStored(in: RefusingStore()))
    }

    func testTheLaunchPassesTheSecretAndSettingsNeitherListsNorRemovesIt() throws {
        let store = MemorySecretStore()
        store.values = [
            SecretSettings.linearAPIKeyName: "lin_api_test",
            "symphony-github-webhook": secret,
            "EXTRA": "1",
        ]
        let settings = SettingsStore(defaults: MemoryKeyValueStore(), secrets: store)

        let secrets = try settings.loadSecrets()
        XCTAssertEqual(secrets.githubWebhookSecret, secret)
        XCTAssertEqual(secrets.extraEnvironment.map(\.name), ["EXTRA"], "the item is never an extra variable")
        XCTAssertTrue(SecretSettings.reservedNames.contains(WebhookSecret.item))
        XCTAssertTrue(settings.hasWebhookSecret)

        // Saving Settings, even naming every extra to remove, leaves the item alone.
        try settings.saveSecrets(SecretSettings(linearAPIKey: "lin_api_test"), removing: ["EXTRA", "symphony-github-webhook"])
        XCTAssertEqual(store.values["symphony-github-webhook"], secret)
        XCTAssertNil(store.values["EXTRA"])

        let environment = ChildLaunchBuilder.environment(base: ["PATH": "/usr/bin"], secrets: secrets, files: StubFileChecker())
        XCTAssertEqual(environment["SYMPHONY_GITHUB_WEBHOOK_SECRET"], secret)
        XCTAssertNil(ChildLaunchBuilder.environment(base: [:], secrets: SecretSettings(), files: StubFileChecker())["SYMPHONY_GITHUB_WEBHOOK_SECRET"])
        XCTAssertEqual(secrets.trimmed().githubWebhookSecret, secret)
    }

    func testTheSettingsStoreMovesAHandOffIntoItsOwnSecrets() throws {
        try secret.write(to: handOff, atomically: true, encoding: .utf8)
        let store = MemorySecretStore()
        let settings = SettingsStore(defaults: MemoryKeyValueStore(), secrets: store)

        XCTAssertFalse(settings.hasWebhookSecret)
        XCTAssertEqual(settings.moveWebhookSecret(handedOffAt: handOff), .saved)
        XCTAssertTrue(settings.hasWebhookSecret)
    }

    func testFixturesStandForTheHandOffWhileTheyAnswer() {
        let home = root.appendingPathComponent("home")
        let plain = AppStores(environment: [:], home: home)
        XCTAssertEqual(plain.webhookSecretHandOff(stateRoot: root), handOff)

        let qa = AppStores(environment: [QAMode.environmentKey: root.path, QAMode.apiFixturesKey: "/tmp/fixtures/github-updates-setup"], home: home)
        XCTAssertEqual(qa.webhookSecretHandOff(stateRoot: root).path, "/tmp/fixtures/github-updates-setup/github_webhook_secret")
    }

    // MARK: The API

    func testReadAsksForTheSetupAndAnswersItsSection() async throws {
        let contract = try Data(contentsOf: GitHubUpdatesCardTests.contract)
        var asked: URLRequest?
        let result = await GitHubUpdatesAPI.read(stateRoot: root, fallback: URL(string: "http://127.0.0.1:4123")!) { request in
            asked = request
            return (contract, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        XCTAssertEqual(asked?.url?.absoluteString, "http://127.0.0.1:4123/api/v1/setup")
        XCTAssertEqual(asked?.httpMethod, "GET")
        guard case let .updated(section) = result else { return XCTFail("expected the section, got \(result)") }
        XCTAssertEqual(section.mode, .on)
        XCTAssertTrue(section.isInstant)
        XCTAssertEqual(section.listeningPort, 4040)
        XCTAssertEqual(section.repo("lib")?.name, "acme/lib")
        XCTAssertNil(section.step("gh_ready")?.action)

        let unreachable = await GitHubUpdatesAPI.read(stateRoot: root, fallback: URL(string: "http://127.0.0.1:4123")!) { _ in throw URLError(.cannotConnectToHost) }
        XCTAssertEqual(unreachable, .failed("Couldn't read the setup: nothing answered at http://127.0.0.1:4123."))
        let nowhere = await GitHubUpdatesAPI.read(stateRoot: root, fallback: nil)
        XCTAssertEqual(nowhere, .failed("Couldn't read the setup: Symphony hasn't said where it listens."))
        XCTAssertEqual(GitHubUpdatesAPI.result(.leaveOnPolling, statusCode: 404, data: Data()), .failed("Couldn't leave the repo on polling: this Symphony predates instant updates. Update it."))
        XCTAssertEqual(GitHubUpdatesAPI.path(.runStep), "api/v1/setup/github_updates/run_step")
        XCTAssertEqual(GitHubUpdatesAPI.Action.test.failurePrefix, "Couldn't send a test update")
    }

    func testAStepNamesTheButtonForAFixOnlyThePersonMakes() throws {
        let data = Data(#"""
        {"github_updates": {"mode": "setting_up", "enabled": true, "steps": [
          {"id": "gh_ready", "status": "failed", "action": "grant_permission"},
          {"id": "port", "status": "failed", "action": "restart_symphony"},
          {"id": "relay", "status": "failed", "action": "sign_in"},
          {"id": "secret", "status": "failed", "action": "dance"}
        ]}}
        """#.utf8)
        let section = try XCTUnwrap(GitHubUpdatesSection.decode(data))

        XCTAssertEqual(section.steps.map(\.action), [.grantPermission, .restartSymphony, .signIn, nil])
        XCTAssertFalse(section.isInstant)
        XCTAssertNil(section.listeningPort)
    }
}
