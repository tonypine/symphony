import Foundation

/// QA mode, for test launches: `SYMPHONY_BAR_QA_ROOT=<dir>` keeps the app's settings, secrets, Launch at Login,
/// logs, update downloads, Symphony's state and logs and the embedded Symphony's unpacked release under `<dir>`,
/// never in UserDefaults, the app's secrets file or the folders a normal launch uses. With
/// `SYMPHONY_QA_OPENROUTER_URL` it talks to Symphony's OpenRouter stub instead of openrouter.ai, and with
/// `SYMPHONY_BAR_QA_API_FIXTURES` it reads Symphony's local API from files (see `APIFixtures`).
public struct QAMode: Equatable {
    /// The directory QA mode keeps everything under. QA mode is on while it is set and not blank.
    public static let environmentKey = "SYMPHONY_BAR_QA_ROOT"
    /// `1` makes the app scriptable: see `QAScript`.
    public static let scriptedKey = "SYMPHONY_BAR_QA_SCRIPTED"
    /// The releases/latest URL update checks read instead of GitHub's, for a local update feed.
    public static let updateURLKey = "SYMPHONY_BAR_UPDATE_URL"
    /// The API base of the OpenRouter stub QA starts (`symphony openrouter-stub`), such as
    /// `http://127.0.0.1:4100/api`. The Symphony the app runs reads it too, also only in QA mode.
    public static let openRouterURLKey = "SYMPHONY_QA_OPENROUTER_URL"
    /// A directory of API fixtures the app reads Symphony's local API from instead of Symphony: see `APIFixtures`.
    public static let apiFixturesKey = "SYMPHONY_BAR_QA_API_FIXTURES"
    /// Where Symphony writes its logs (`SymphonyElixir.Paths`).
    public static let symphonyLogsRootKey = "SYMPHONY_LOGS_ROOT"
    /// Where the embedded Burrito binary unpacks its release, under `.burrito/`. Burrito's launcher removes older
    /// versions' unpacked releases from that folder, so a test launch must never share it with the installed app.
    public static let burritoInstallDirectoryKey = "SYMPHONY_INSTALL_DIR"

    public static let settingsFileName = "settings.plist"
    public static let secretsFileName = "secrets.json"
    public static let logsFolder = "logs"
    public static let symphonyLogsFolder = "symphony-logs"
    public static let updatesFolder = "updates"
    public static let stateFolder = "state"
    public static let burritoFolder = "burrito"

    public let root: URL
    /// True when `SYMPHONY_BAR_QA_SCRIPTED` is `1`.
    public let scripted: Bool
    /// The update feed from `SYMPHONY_BAR_UPDATE_URL`, nil for GitHub's.
    public let updateURL: URL?
    /// The OpenRouter stub from `SYMPHONY_QA_OPENROUTER_URL`, nil for openrouter.ai.
    public let openRouterURL: URL?
    /// The API fixtures directory from `SYMPHONY_BAR_QA_API_FIXTURES`, nil for Symphony's own API.
    public let apiFixturesDirectory: URL?

    public init(
        root: URL,
        scripted: Bool = false,
        updateURL: URL? = nil,
        openRouterURL: URL? = nil,
        apiFixturesDirectory: URL? = nil
    ) {
        self.root = root.standardizedFileURL
        self.scripted = scripted
        self.updateURL = updateURL
        self.openRouterURL = openRouterURL
        self.apiFixturesDirectory = apiFixturesDirectory?.standardizedFileURL
    }

    /// QA mode from `SYMPHONY_BAR_QA_ROOT`, or nil when it is unset or blank. `~` is expanded.
    public static func detect(environment: [String: String]) -> QAMode? {
        guard let path = environment[environmentKey]?.trimmingWhitespace(), !path.isEmpty else { return nil }
        let updateURL = environment[updateURLKey].flatMap { URL(string: $0.trimmingWhitespace()) }
        return QAMode(
            root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true),
            scripted: environment[scriptedKey]?.trimmingWhitespace() == "1",
            updateURL: updateURL.flatMap { ["http", "https"].contains($0.scheme ?? "") ? $0 : nil },
            openRouterURL: environment[openRouterURLKey].flatMap(loopbackURL),
            apiFixturesDirectory: environment[apiFixturesKey].map { $0.trimmingWhitespace() }.flatMap { path in
                path.isEmpty ? nil : URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
            }
        )
    }

    /// `value` as an http(s) URL on a loopback host without a trailing slash, or nil. The stub only ever runs on the
    /// app's own Mac, so no other host is accepted, and a key typed in QA never leaves it.
    static func loopbackURL(_ value: String) -> URL? {
        var text = value.trimmingWhitespace()
        while text.hasSuffix("/") { text.removeLast() }
        guard let components = URLComponents(string: text),
              ["http", "https"].contains(components.scheme ?? ""),
              ["127.0.0.1", "localhost", "::1", "[::1]"].contains(components.host ?? ""),
              components.user == nil, components.password == nil, components.query == nil, components.fragment == nil
        else { return nil }
        return components.url
    }

    public var settingsFile: URL { root.appendingPathComponent(Self.settingsFileName) }
    public var secretsFile: URL { root.appendingPathComponent(Self.secretsFileName) }
    public var logDirectory: URL { root.appendingPathComponent(Self.logsFolder, isDirectory: true) }
    public var symphonyLogsRoot: URL { root.appendingPathComponent(Self.symphonyLogsFolder, isDirectory: true) }
    public var updateCacheDirectory: URL { root.appendingPathComponent(Self.updatesFolder, isDirectory: true) }
    public var stateRoot: URL { root.appendingPathComponent(Self.stateFolder, isDirectory: true) }
    public var burritoInstallDirectory: URL { root.appendingPathComponent(Self.burritoFolder, isDirectory: true) }

    /// The fixtures the app reads Symphony's API from, logging control requests under the QA root; nil without
    /// `SYMPHONY_BAR_QA_API_FIXTURES`.
    public var apiFixtures: APIFixtures? {
        apiFixturesDirectory.map {
            APIFixtures(directory: $0, requestLog: root.appendingPathComponent(APIFixtures.requestLogFileName))
        }
    }
}

/// Where the app keeps its settings and secrets, and the environment it reads Symphony's state root from:
/// UserDefaults, the secrets file and macOS's login item normally, files under the QA root in QA mode.
public struct AppStores {
    public let qaMode: QAMode?
    public let defaults: KeyValueStore
    public let secrets: SecretStore
    public let loginItem: LoginItemService
    public let logDirectory: URL
    /// Where update downloads go, nil for the default caches folder.
    public let updateCacheDirectory: URL?
    /// The releases/latest URL update checks read.
    public let updateURL: URL
    /// The OpenRouter API base Settings talks to: openrouter.ai's, whatever the environment says, except in QA mode
    /// with a stub.
    public let openRouterBaseURL: URL
    /// The control URL used while Symphony hasn't written one. Nil in QA mode, so the app never mistakes the
    /// Symphony a normal launch runs, on the default port, for its own.
    public let controlURLFallback: URL?
    /// The API fixtures that answer instead of Symphony, only in QA mode with `SYMPHONY_BAR_QA_API_FIXTURES`.
    public let apiFixtures: APIFixtures?
    /// The app's environment. In QA mode `SYMPHONY_STATE_ROOT`, `SYMPHONY_LOGS_ROOT` and `SYMPHONY_INSTALL_DIR`
    /// default to folders under the QA root, so the app neither sees nor controls a Symphony started outside QA
    /// mode, and the Symphony it starts keeps its state, logs and unpacked release there.
    public let environment: [String: String]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        guard let qaMode = QAMode.detect(environment: environment) else {
            self.qaMode = nil
            defaults = UserDefaults.standard
            secrets = MigratingSecretStore(file: FileSecretStore(file: MigratingSecretStore.defaultFile(home: home)))
            loginItem = MainAppLoginItem()
            logDirectory = ChildLog.defaultDirectory(home: home)
            updateCacheDirectory = nil
            updateURL = UpdateChecker.latestReleaseURL
            openRouterBaseURL = OpenRouterClient.baseURL
            controlURLFallback = SymphonyState.defaultBaseURL
            apiFixtures = nil
            self.environment = environment
            return
        }

        self.qaMode = qaMode
        let defaults = PropertyListFileStore(file: qaMode.settingsFile)
        self.defaults = defaults
        secrets = FileSecretStore(file: qaMode.secretsFile)
        loginItem = FileLoginItem(defaults: defaults)
        logDirectory = qaMode.logDirectory
        updateCacheDirectory = qaMode.updateCacheDirectory
        updateURL = qaMode.updateURL ?? UpdateChecker.latestReleaseURL
        openRouterBaseURL = qaMode.openRouterURL.map(OpenRouterClient.baseURL(api:)) ?? OpenRouterClient.baseURL
        controlURLFallback = nil
        apiFixtures = qaMode.apiFixtures
        var environment = environment
        for (key, folder) in [
            (StateRoot.environmentKey, qaMode.stateRoot),
            (QAMode.symphonyLogsRootKey, qaMode.symphonyLogsRoot),
            (QAMode.burritoInstallDirectoryKey, qaMode.burritoInstallDirectory),
        ] where environment[key]?.trimmingWhitespace().isEmpty ?? true {
            environment[key] = folder.path
        }
        self.environment = environment
    }

    public var isQAMode: Bool { qaMode != nil }

    /// What sends the app's requests to Symphony's local API: the fixtures when they answer, else the network.
    public var apiTransport: ControlAPI.Transport {
        apiFixtures?.transport ?? { try await URLSession.shared.data(for: $0) }
    }

    /// The base URL used while Symphony hasn't written a control URL: the fixtures' when they answer.
    public var apiFallback: URL? {
        apiFixtures == nil ? controlURLFallback : APIFixtures.baseURL
    }

    /// The control token sent instead of the state directory's while fixtures answer.
    public var apiToken: String? {
        apiFixtures == nil ? nil : APIFixtures.token
    }

    /// The update helper's environment. In QA mode it is the app's, so the app the helper relaunches is in QA mode
    /// too and keeps the same folders.
    public var updateHelperEnvironment: [String: String] {
        guard isQAMode else { return ["PATH": UpdateHelper.path] }
        var environment = environment
        environment["PATH"] = environment["PATH"].flatMap { $0.isEmpty ? nil : $0 } ?? UpdateHelper.path
        return environment
    }

    public func settingsStore() -> SettingsStore {
        SettingsStore(defaults: defaults, secrets: secrets)
    }
}

/// A key-value store in a property list file, read on every lookup so separate instances agree.
public final class PropertyListFileStore: KeyValueStore {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func object(forKey defaultName: String) -> Any? {
        load()[defaultName]
    }

    /// Stores `value`, or removes the key for nil. Like UserDefaults, a failed write is dropped.
    public func set(_ value: Any?, forKey defaultName: String) {
        var values = load()
        values[defaultName] = value
        try? save(values)
    }

    /// The stored values; empty when the file is missing or not a dictionary.
    func load() -> [String: Any] {
        guard let data = try? Data(contentsOf: file),
            let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return [:] }
        return values
    }

    private func save(_ values: [String: Any]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeReplacing(
            file,
            with: PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0),
            permissions: 0o644
        )
    }
}

/// Secrets in a JSON file readable only by the user, one string per account.
public struct FileSecretStore: SecretStore {
    public let file: URL

    public init(file: URL) {
        self.file = file
    }

    public func value(forAccount account: String) throws -> String? {
        try load()[account]
    }

    public func setValue(_ value: String, forAccount account: String) throws {
        var values = try load()
        values[account] = value
        try save(values)
    }

    public func removeValue(forAccount account: String) throws {
        var values = try load()
        guard values.removeValue(forKey: account) != nil else { return }
        try save(values)
    }

    public func accounts() throws -> [String] {
        try load().keys.sorted()
    }

    /// The stored secrets; empty when the file doesn't exist yet. Throws when it can't be read or parsed.
    private func load() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        return try JSONDecoder().decode([String: String].self, from: Data(contentsOf: file))
    }

    /// Replaces every stored secret with `values`.
    func save(_ values: [String: String]) throws {
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Created 0600 before the secrets go in, so they are never readable by others.
        try writeReplacing(file, with: encoder.encode(values), permissions: 0o600)
    }
}

/// Launch at Login kept in a key-value store instead of macOS's login items, for QA mode.
public final class FileLoginItem: LoginItemService {
    public static let key = "launchAtLogin"

    private let defaults: KeyValueStore

    public init(defaults: KeyValueStore) {
        self.defaults = defaults
    }

    public var status: LoginItemStatus {
        defaults.object(forKey: Self.key) as? Bool == true ? .enabled : .notRegistered
    }

    public func register() throws {
        defaults.set(true, forKey: Self.key)
    }

    public func unregister() throws {
        defaults.set(false, forKey: Self.key)
    }
}

/// Writes `data` to a new file with `permissions` next to `file`, then renames it over `file`, so readers see the old
/// contents or the new ones, never part of a write.
func writeReplacing(_ file: URL, with data: Data, permissions: mode_t) throws {
    let temporary = file.deletingLastPathComponent().appendingPathComponent(".\(file.lastPathComponent).\(UUID())")
    let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, permissions)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporary.path, file.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw error
    }
}
