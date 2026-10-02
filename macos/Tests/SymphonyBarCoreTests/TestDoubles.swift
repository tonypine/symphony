import Foundation
@testable import SymphonyBarCore

final class MemoryKeyValueStore: KeyValueStore {
    var values: [String: Any] = [:]

    func object(forKey defaultName: String) -> Any? { values[defaultName] }
    func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
}

final class MemorySecretStore: SecretStore {
    var values: [String: String] = [:]

    func value(forAccount account: String) throws -> String? { values[account] }
    func setValue(_ value: String, forAccount account: String) throws { values[account] = value }
    func removeValue(forAccount account: String) throws { values[account] = nil }
    func accounts() throws -> [String] { values.keys.sorted() }
}

struct StubFileChecker: FileChecker {
    var directories: Set<String> = []
    var files: Set<String> = []

    func isDirectory(atPath path: String) -> Bool { directories.contains(path) }
    func isFile(atPath path: String) -> Bool { files.contains(path) }
}

/// A fresh directory path for one test, under `TMPDIR` when set (sandboxes allow only that), else the user temp dir.
func uniqueTemporaryDirectory(_ prefix: String) -> URL {
    let root = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
    return root.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
}
