import XCTest
@testable import SymphonyBarCore

final class QAModeTests: XCTestCase {
    private var root: URL!
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)

    override func setUp() {
        root = uniqueTemporaryDirectory("qa-mode")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func qaStores(_ environment: [String: String] = [:]) -> AppStores {
        AppStores(environment: environment.merging([QAMode.environmentKey: root.path]) { $1 }, home: home)
    }

    /// Every file under the QA root, relative to it.
    private func filesUnderRoot() throws -> [String] {
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: root.path))
        return enumerator.compactMap { $0 as? String }.filter { name in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return !isDirectory.boolValue
        }.sorted()
    }

    // MARK: - Detection

    func testQAModeIsOffWithoutTheVariable() {
        XCTAssertNil(QAMode.detect(environment: [:]))
        XCTAssertNil(QAMode.detect(environment: [QAMode.environmentKey: " \n"]))
    }

    func testQAModeReadsTheTrimmedDirectoryAndExpandsTilde() {
        XCTAssertEqual(
            QAMode.detect(environment: [QAMode.environmentKey: " /tmp/qa/../qa-run \n"])?.root.path,
            "/tmp/qa-run"
        )
        XCTAssertEqual(
            QAMode.detect(environment: [QAMode.environmentKey: "~/qa"])?.root.path,
            (NSHomeDirectory() as NSString).appendingPathComponent("qa")
        )
    }

    func testAPIFixturesAreReadOnlyInQAMode() {
        let outside = AppStores(environment: [QAMode.apiFixturesKey: "/tmp/fixtures"], home: home)
        XCTAssertNil(outside.apiFixtures)
        XCTAssertNil(outside.apiToken)
        XCTAssertEqual(outside.apiFallback, SymphonyState.defaultBaseURL)

        XCTAssertNil(qaStores().apiFixtures)
        XCTAssertNil(qaStores([QAMode.apiFixturesKey: " "]).apiFixtures)

        let stores = qaStores([QAMode.apiFixturesKey: " /tmp/fixtures/../director-app \n"])
        XCTAssertEqual(stores.apiFixtures?.directory.path, "/tmp/director-app")
        XCTAssertEqual(stores.apiFixtures?.requestLog, root.appendingPathComponent("api-requests.jsonl"))
        XCTAssertEqual(stores.apiFallback, APIFixtures.baseURL)
        XCTAssertEqual(stores.apiToken, APIFixtures.token)
        // The control URL Open Web Dashboard uses stays unset in QA mode.
        XCTAssertNil(stores.controlURLFallback)
    }

    func testQAModeReadsScriptedAndTheUpdateURL() {
        let plain = QAMode.detect(environment: [QAMode.environmentKey: "/tmp/qa"])
        XCTAssertEqual(plain?.scripted, false)
        XCTAssertNil(plain?.updateURL)

        let scripted = QAMode.detect(environment: [
            QAMode.environmentKey: "/tmp/qa",
            QAMode.scriptedKey: " 1 ",
            QAMode.updateURLKey: " http://127.0.0.1:8123/releases/latest\n",
        ])
        XCTAssertEqual(scripted?.scripted, true)
        XCTAssertEqual(scripted?.updateURL?.absoluteString, "http://127.0.0.1:8123/releases/latest")

        let ignored = QAMode.detect(environment: [
            QAMode.environmentKey: "/tmp/qa",
            QAMode.scriptedKey: "yes",
            QAMode.updateURLKey: "file:///tmp/latest.json",
        ])
        XCTAssertEqual(ignored?.scripted, false)
        XCTAssertNil(ignored?.updateURL)
    }

    func testQAModeReadsOnlyALoopbackOpenRouterStub() {
        func stub(_ value: String) -> String? {
            QAMode.detect(environment: [QAMode.environmentKey: "/tmp/qa", QAMode.openRouterURLKey: value])?
                .openRouterURL?.absoluteString
        }

        XCTAssertNil(QAMode.detect(environment: [QAMode.environmentKey: "/tmp/qa"])?.openRouterURL)
        XCTAssertEqual(stub(" http://127.0.0.1:4100/api/ \n"), "http://127.0.0.1:4100/api")
        XCTAssertEqual(stub("https://localhost:4100/api"), "https://localhost:4100/api")
        XCTAssertEqual(stub("http://[::1]:4100/api"), "http://[::1]:4100/api")
        // Any other host, scheme or a URL with credentials would take the key off this Mac.
        XCTAssertNil(stub("https://openrouter.example.com/api"))
        XCTAssertNil(stub("http://10.0.0.5:4100/api"))
        XCTAssertNil(stub("http://127.0.0.1.example.com/api"))
        XCTAssertNil(stub("http://user:pass@127.0.0.1:4100/api"))
        XCTAssertNil(stub("http://127.0.0.1:4100/api?next=https://evil.example"))
        XCTAssertNil(stub("file:///tmp/api"))
        XCTAssertNil(stub(""))
    }

    func testQAPathsAreUnderTheRoot() {
        let qa = QAMode(root: URL(fileURLWithPath: "/tmp/qa", isDirectory: true))

        XCTAssertEqual(qa.settingsFile.path, "/tmp/qa/settings.plist")
        XCTAssertEqual(qa.secretsFile.path, "/tmp/qa/secrets.json")
        XCTAssertEqual(qa.logDirectory.path, "/tmp/qa/logs")
        XCTAssertEqual(qa.symphonyLogsRoot.path, "/tmp/qa/symphony-logs")
        XCTAssertEqual(qa.updateCacheDirectory.path, "/tmp/qa/updates")
        XCTAssertEqual(qa.stateRoot.path, "/tmp/qa/state")
        XCTAssertEqual(qa.burritoInstallDirectory.path, "/tmp/qa/burrito")
        XCTAssertEqual(qa.commandsFolder.path, "/tmp/qa/commands")
        XCTAssertEqual(qa.statusFile.path, "/tmp/qa/status.json")
    }

    // MARK: - Store selection

    func testWithoutQAModeTheAppUsesUserDefaultsTheSecretsFileAndMacOSLoginItems() {
        let stores = AppStores(environment: ["HOME": "/Users/me"], home: home)

        XCTAssertFalse(stores.isQAMode)
        XCTAssertTrue(stores.defaults as AnyObject === UserDefaults.standard)
        let secrets = stores.secrets as? MigratingSecretStore
        XCTAssertEqual(secrets?.file.file.path, "/Users/me/Library/Application Support/symphony/release/secrets.json")
        XCTAssertEqual((secrets?.keychain as? KeychainSecretStore)?.service, KeychainSecretStore.defaultService)
        XCTAssertTrue(stores.loginItem is MainAppLoginItem)
        XCTAssertEqual(stores.logDirectory, ChildLog.defaultDirectory(home: home))
        XCTAssertNil(stores.updateCacheDirectory)
        XCTAssertEqual(stores.updateURL, UpdateChecker.latestReleaseURL)
        XCTAssertEqual(stores.controlURLFallback, SymphonyState.defaultBaseURL)
        XCTAssertEqual(stores.environment, ["HOME": "/Users/me"])
        XCTAssertEqual(stores.updateHelperEnvironment, ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        XCTAssertEqual(stores.openRouterBaseURL, OpenRouterClient.baseURL)
    }

    func testANormalLaunchAlwaysTalksToOpenRouterWhateverTheEnvironmentSays() {
        let stores = AppStores(
            environment: [QAMode.openRouterURLKey: "http://127.0.0.1:4100/api", QAMode.environmentKey: " "],
            home: home
        )

        XCTAssertFalse(stores.isQAMode)
        XCTAssertEqual(stores.openRouterBaseURL.absoluteString, "https://openrouter.ai/api/v1/")
    }

    func testQAModeTalksToTheOpenRouterStubWhenGivenOne() {
        XCTAssertEqual(qaStores().openRouterBaseURL, OpenRouterClient.baseURL)
        XCTAssertEqual(qaStores([QAMode.openRouterURLKey: "https://openrouter.ai/api"]).openRouterBaseURL, OpenRouterClient.baseURL)

        let stores = qaStores([QAMode.openRouterURLKey: "http://127.0.0.1:4100/api"])
        XCTAssertEqual(stores.openRouterBaseURL.absoluteString, "http://127.0.0.1:4100/api/v1/")
        // The Symphony the app runs gets the URL too, and reads it only in QA mode.
        XCTAssertEqual(stores.environment[QAMode.openRouterURLKey], "http://127.0.0.1:4100/api")
    }

    func testQAModeUsesFilesUnderTheRoot() {
        let stores = qaStores()

        XCTAssertTrue(stores.isQAMode)
        XCTAssertEqual((stores.defaults as? PropertyListFileStore)?.file, stores.qaMode?.settingsFile)
        XCTAssertEqual((stores.secrets as? FileSecretStore)?.file, stores.qaMode?.secretsFile)
        XCTAssertTrue(stores.loginItem is FileLoginItem)
        XCTAssertEqual(stores.logDirectory, stores.qaMode?.logDirectory)
        XCTAssertEqual(stores.updateCacheDirectory, stores.qaMode?.updateCacheDirectory)
        // Never the Symphony a normal launch runs on the default port.
        XCTAssertNil(stores.controlURLFallback)
        XCTAssertEqual(stores.updateURL, UpdateChecker.latestReleaseURL)
        XCTAssertEqual(
            qaStores([QAMode.updateURLKey: "http://127.0.0.1:8123/releases/latest"]).updateURL.absoluteString,
            "http://127.0.0.1:8123/releases/latest"
        )
    }

    func testQAModeKeepsSymphonysLogsAndUnpackedReleaseUnderTheRootUnlessSet() {
        let path = root.standardizedFileURL.path
        let environment = qaStores(["PATH": "/opt/bin"]).environment
        XCTAssertEqual(environment[QAMode.symphonyLogsRootKey], path + "/symphony-logs")
        XCTAssertEqual(environment[QAMode.burritoInstallDirectoryKey], path + "/burrito")

        let given = qaStores([QAMode.symphonyLogsRootKey: "/srv/logs", QAMode.burritoInstallDirectoryKey: "/srv/burrito"])
        XCTAssertEqual(given.environment[QAMode.symphonyLogsRootKey], "/srv/logs")
        XCTAssertEqual(given.environment[QAMode.burritoInstallDirectoryKey], "/srv/burrito")
        XCTAssertEqual(qaStores([QAMode.burritoInstallDirectoryKey: " "]).environment[QAMode.burritoInstallDirectoryKey], path + "/burrito")
    }

    func testTheUpdateHelperGetsTheQAEnvironment() {
        // So the app it relaunches is in QA mode too, with the same folders.
        let helper = qaStores(["PATH": "/opt/bin:/usr/bin", "HOME": "/Users/me"]).updateHelperEnvironment
        XCTAssertEqual(helper[QAMode.environmentKey], root.path)
        XCTAssertEqual(helper["PATH"], "/opt/bin:/usr/bin")
        XCTAssertEqual(helper[QAMode.burritoInstallDirectoryKey], root.standardizedFileURL.path + "/burrito")
        XCTAssertEqual(qaStores().updateHelperEnvironment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testQAModePointsSymphonyStateAtTheRootUnlessSet() {
        XCTAssertEqual(qaStores().environment[StateRoot.environmentKey], root.standardizedFileURL.path + "/state")
        XCTAssertEqual(
            qaStores([StateRoot.environmentKey: " "]).environment[StateRoot.environmentKey],
            root.standardizedFileURL.path + "/state"
        )
        XCTAssertEqual(
            qaStores([StateRoot.environmentKey: "/srv/state"]).environment[StateRoot.environmentKey],
            "/srv/state"
        )
        XCTAssertEqual(
            StateRoot.locate(environment: qaStores().environment, home: home).path,
            root.standardizedFileURL.path + "/state"
        )
    }

    func testSavingSettingsInQAModeWritesOnlyUnderTheRoot() throws {
        let stores = qaStores()
        let store = stores.settingsStore()
        let settings = AppSettings(
            checkoutPath: "/src/symphony",
            configPath: "/src/symphony/symphony.yml",
            stopTimeoutSeconds: 45,
            startOnLaunch: true,
            developmentMode: true
        )
        let secrets = SecretSettings(
            linearAPIKey: "lin_api_QA",
            extraEnvironment: [EnvironmentVariable(name: "GITHUB_TOKEN", value: "ghp_QA")]
        )

        store.saveSettings(settings)
        try store.saveSecrets(secrets)
        try stores.loginItem.register()

        XCTAssertEqual(try filesUnderRoot(), ["secrets.json", "settings.plist"])
        // A fresh store reads back what was saved.
        let reloaded = qaStores().settingsStore()
        XCTAssertEqual(reloaded.loadSettings(), settings)
        XCTAssertEqual(try reloaded.loadSecrets(), secrets)
        XCTAssertEqual(qaStores().loginItem.status, .enabled)
    }

    // MARK: - PropertyListFileStore

    func testPropertyListFileStoreRoundTripsAndRemovesValues() {
        let store = PropertyListFileStore(file: root.appendingPathComponent("nested/settings.plist"))

        XCTAssertNil(store.object(forKey: "configPath"))
        store.set("/a/symphony.yml", forKey: "configPath")
        store.set(30, forKey: "stopTimeoutSeconds")
        store.set(true, forKey: "startOnLaunch")
        store.set(["toBuild": 2] as [String: Any], forKey: "pendingUpdate")

        let other = PropertyListFileStore(file: store.file)
        XCTAssertEqual(other.object(forKey: "configPath") as? String, "/a/symphony.yml")
        XCTAssertEqual(other.object(forKey: "stopTimeoutSeconds") as? Int, 30)
        XCTAssertEqual(other.object(forKey: "startOnLaunch") as? Bool, true)
        XCTAssertEqual((other.object(forKey: "pendingUpdate") as? [String: Any])?["toBuild"] as? Int, 2)

        other.set(nil, forKey: "configPath")
        XCTAssertNil(store.object(forKey: "configPath"))
        XCTAssertEqual(store.object(forKey: "stopTimeoutSeconds") as? Int, 30)
    }

    func testPropertyListFileStoreTreatsAnUnreadableFileAsEmpty() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("settings.plist")
        try Data("not a plist".utf8).write(to: file)

        let store = PropertyListFileStore(file: file)
        XCTAssertNil(store.object(forKey: "configPath"))
        store.set("/b", forKey: "configPath")
        XCTAssertEqual(store.object(forKey: "configPath") as? String, "/b")
    }

    func testPendingUpdateSurvivesInTheQASettingsFile() {
        let pending = PendingUpdate(
            fromBuild: 1,
            toBuild: 2,
            version: "0.0.1.2",
            startSymphony: true,
            resumeDispatch: false
        )
        PendingUpdateStore(defaults: qaStores().defaults).save(pending)

        XCTAssertEqual(PendingUpdateStore(defaults: qaStores().defaults).take(), pending)
        XCTAssertNil(PendingUpdateStore(defaults: qaStores().defaults).take())
    }

    // MARK: - FileSecretStore

    func testFileSecretStoreRoundTripsAndKeepsTheFilePrivate() throws {
        let store = FileSecretStore(file: root.appendingPathComponent("secrets.json"))

        XCTAssertEqual(try store.accounts(), [])
        XCTAssertNil(try store.value(forAccount: "LINEAR_API_KEY"))

        try store.setValue("lin_api_1", forAccount: "LINEAR_API_KEY")
        try store.setValue("x", forAccount: "B_VAR")
        try store.setValue("y", forAccount: "A_VAR")
        try store.setValue("lin_api_2", forAccount: "LINEAR_API_KEY")

        XCTAssertEqual(try store.accounts(), ["A_VAR", "B_VAR", "LINEAR_API_KEY"])
        XCTAssertEqual(try store.value(forAccount: "LINEAR_API_KEY"), "lin_api_2")

        try store.removeValue(forAccount: "B_VAR")
        try store.removeValue(forAccount: "MISSING")
        XCTAssertEqual(try store.accounts(), ["A_VAR", "LINEAR_API_KEY"])

        let attributes = try FileManager.default.attributesOfItem(atPath: store.file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try filesUnderRoot(), ["secrets.json"])
    }

    func testFileSecretStoreReportsAnUnreadableFile() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = FileSecretStore(file: root.appendingPathComponent("secrets.json"))
        try Data("[]".utf8).write(to: store.file)

        XCTAssertThrowsError(try store.accounts())
        XCTAssertThrowsError(try store.setValue("v", forAccount: "A"))
    }

    func testFileSecretStoreReportsAFailedWrite() throws {
        // The parent "directory" is a file, so neither the folder nor the secrets file can be created.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("blocker")
        try Data().write(to: blocker)
        let store = FileSecretStore(file: blocker.appendingPathComponent("secrets.json"))

        XCTAssertThrowsError(try store.setValue("v", forAccount: "A"))
    }

    // MARK: - FileLoginItem

    func testFileLoginItemFollowsRegisterAndUnregister() throws {
        let defaults = MemoryKeyValueStore()
        let item = FileLoginItem(defaults: defaults)

        XCTAssertEqual(item.status, .notRegistered)
        try LoginItem.apply(true, to: item)
        XCTAssertEqual(item.status, .enabled)
        XCTAssertEqual(defaults.values[FileLoginItem.key] as? Bool, true)
        try LoginItem.apply(false, to: item)
        XCTAssertEqual(item.status, .notRegistered)
    }

    // MARK: - Embedded Symphony

    func testQAModeStartsTheEmbeddedSymphonyWithItsFoldersUnderTheRoot() throws {
        let files = StubFileChecker(files: ["/app/symphony"])
        let launch = try ChildLaunchBuilder.build(
            settings: AppSettings(configPath: "/qa/symphony.yml", developmentMode: false),
            secrets: SecretSettings(linearAPIKey: "lin_api_QA"),
            baseEnvironment: qaStores().environment,
            embeddedSymphonyPath: "/app/symphony",
            files: files
        )

        let path = root.standardizedFileURL.path
        XCTAssertEqual(launch.executable, "/app/symphony")
        XCTAssertEqual(launch.environment[StateRoot.environmentKey], path + "/state")
        XCTAssertEqual(launch.environment[QAMode.symphonyLogsRootKey], path + "/symphony-logs")
        XCTAssertEqual(launch.environment[QAMode.burritoInstallDirectoryKey], path + "/burrito")
    }
}
