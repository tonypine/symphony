import Foundation
import Security

/// Somewhere to keep secret strings by account name.
public protocol SecretStore {
    func value(forAccount account: String) throws -> String?
    func setValue(_ value: String, forAccount account: String) throws
    func removeValue(forAccount account: String) throws
    func accounts() throws -> [String]
}

/// A Keychain error carrying the Security framework status.
public struct KeychainError: LocalizedError, Equatable, CustomStringConvertible {
    public let status: OSStatus

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }

    public var errorDescription: String? { description }
}

/// Generic password items in the login Keychain, one per account, under one service.
public struct KeychainSecretStore: SecretStore {
    /// Keychain service the app stores its secrets under.
    public static let defaultService = "symphony"

    public let service: String

    public init(service: String = KeychainSecretStore.defaultService) {
        self.service = service
    }

    public func value(forAccount account: String) throws -> String? {
        var query = itemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func setValue(_ value: String, forAccount account: String) throws {
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            itemQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KeychainError(status: updateStatus) }

        var attributes = itemQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "\(service) \(account)"
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    public func removeValue(forAccount account: String) throws {
        let status = SecItemDelete(itemQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    public func accounts() throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        let items = result as? [[String: Any]] ?? []
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    private func itemQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// The app's secrets, in a `FileSecretStore` readable only by the user. The first use moves the login Keychain
/// items earlier versions kept into the file. The Keychain pinned each item to the exact build that created it,
/// so macOS asked for the password again after every update; the file doesn't.
public final class MigratingSecretStore: SecretStore {
    public static let fileName = "secrets.json"

    public let file: FileSecretStore
    public let keychain: SecretStore
    private let lock = NSLock()

    public init(file: FileSecretStore, keychain: SecretStore = KeychainSecretStore()) {
        self.file = file
        self.keychain = keychain
    }

    /// `~/Library/Application Support/symphony/release/secrets.json`, next to the release build's control token.
    /// Fixed, so a stored `SYMPHONY_STATE_ROOT` can't move the file that holds it.
    public static func defaultFile(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        StateRoot.defaultDirectory(home: home)
            .appendingPathComponent(StateRoot.releaseSubdirectory, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public func value(forAccount account: String) throws -> String? {
        try migrateIfNeeded()
        return try file.value(forAccount: account)
    }

    public func setValue(_ value: String, forAccount account: String) throws {
        try migrateIfNeeded()
        try file.setValue(value, forAccount: account)
    }

    public func removeValue(forAccount account: String) throws {
        try migrateIfNeeded()
        try file.removeValue(forAccount: account)
    }

    public func accounts() throws -> [String] {
        try migrateIfNeeded()
        return try file.accounts()
    }

    /// Until the file exists: copies every Keychain item into it. Once it exists the Keychain is never touched
    /// again. A failed Keychain read throws before the file is written, so the next use tries again. The items
    /// stay in the Keychain, so a build from before the secrets file still finds them after a rollback.
    private func migrateIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !FileManager.default.fileExists(atPath: file.file.path) else { return }

        let accounts = try keychain.accounts()
        var values: [String: String] = [:]
        for account in accounts {
            values[account] = try keychain.value(forAccount: account) ?? ""
        }
        try file.save(values)
    }
}
