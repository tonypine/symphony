import Foundation

/// QA mode, for test launches: `SYMPHONY_BAR_QA_ROOT=<dir>` keeps the app's settings, secrets, Launch at Login,
/// logs, update downloads and Symphony state under `<dir>`, never in UserDefaults or the login Keychain.
public struct QAMode: Equatable {
    /// The directory QA mode keeps everything under. QA mode is on while it is set and not blank.
    public static let environmentKey = "SYMPHONY_BAR_QA_ROOT"

    public static let settingsFileName = "settings.plist"
    public static let secretsFileName = "secrets.json"
    public static let logsFolder = "logs"
    public static let updatesFolder = "updates"
    public static let stateFolder = "state"

    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// QA mode from `SYMPHONY_BAR_QA_ROOT`, or nil when it is unset or blank. `~` is expanded.
    public static func detect(environment: [String: String]) -> QAMode? {
        guard let path = environment[environmentKey]?.trimmingWhitespace(), !path.isEmpty else { return nil }
        return QAMode(root: URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true))
    }

    public var settingsFile: URL { root.appendingPathComponent(Self.settingsFileName) }
    public var secretsFile: URL { root.appendingPathComponent(Self.secretsFileName) }
    public var logDirectory: URL { root.appendingPathComponent(Self.logsFolder, isDirectory: true) }
    public var updateCacheDirectory: URL { root.appendingPathComponent(Self.updatesFolder, isDirectory: true) }
    public var stateRoot: URL { root.appendingPathComponent(Self.stateFolder, isDirectory: true) }
}

/// Where the app keeps its settings and secrets, and the environment it reads Symphony's state root from:
/// UserDefaults, the login Keychain and macOS's login item normally, files under the QA root in QA mode.
public struct AppStores {
    public let qaMode: QAMode?
    public let defaults: KeyValueStore
    public let secrets: SecretStore
    public let loginItem: LoginItemService
    public let logDirectory: URL
    /// Where update downloads go, nil for the default caches folder.
    public let updateCacheDirectory: URL?
    /// The app's environment. In QA mode `SYMPHONY_STATE_ROOT` defaults to `<QA root>/state`, so the app neither
    /// sees nor controls a Symphony started outside QA mode, and the Symphony it starts keeps its state there.
    public let environment: [String: String]

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        guard let qaMode = QAMode.detect(environment: environment) else {
            self.qaMode = nil
            defaults = UserDefaults.standard
            secrets = KeychainSecretStore()
            loginItem = MainAppLoginItem()
            logDirectory = ChildLog.defaultDirectory(home: home)
            updateCacheDirectory = nil
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
        var environment = environment
        if environment[StateRoot.environmentKey]?.trimmingWhitespace().isEmpty ?? true {
            environment[StateRoot.environmentKey] = qaMode.stateRoot.path
        }
        self.environment = environment
    }

    public var isQAMode: Bool { qaMode != nil }

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

/// Secrets in a JSON file readable only by the user, one string per account. For QA mode only: the login
/// Keychain is where real secrets belong.
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

    private func save(_ values: [String: String]) throws {
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
private func writeReplacing(_ file: URL, with data: Data, permissions: mode_t) throws {
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
