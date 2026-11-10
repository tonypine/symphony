import Foundation

/// One settings key a release's build rewrites by itself, from the release's `version.json`: the table
/// `symphony config migrations` prints.
public struct ReleaseSettingsMigration: Equatable, Decodable {
    /// A dotted path, with `[]` for a list's items: `repositories[].agent.model`.
    public var key: String
    /// The sibling key it becomes; nil when the key is simply gone.
    public var to: String?

    public init(key: String, to: String?) {
        self.key = key
        self.to = to
    }
}

/// What a release will change in your symphony.yml, found before it is downloaded, from the keys the file holds.
public enum SettingsMigrationPreview {
    /// The migrations whose key `text` holds. Reads key lines by indentation, as `Config.Migration` does.
    public static func affecting(_ migrations: [ReleaseSettingsMigration], text: String) -> [ReleaseSettingsMigration] {
        guard !migrations.isEmpty else { return [] }
        let paths = keyPaths(text)
        return migrations.filter { paths.contains($0.key) }
    }

    /// The dotted path of every key line in `text`.
    static func keyPaths(_ text: String) -> Set<String> {
        var stack: [(column: Int, path: String, item: Bool)] = []
        var paths = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            guard let key = keyLine(line) else { continue }
            if key.dash > 0 {
                stack.removeAll { $0.column > key.spaces || ($0.item && $0.column == key.spaces) }
                stack.append((key.spaces, (stack.last?.path ?? "") + "[]", true))
            }
            let column = key.spaces + key.dash
            stack.removeAll { $0.column >= column }
            let parent = stack.last?.path ?? ""
            let path = parent.isEmpty ? key.name : parent + "." + key.name
            stack.append((column, path, false))
            paths.insert(path)
        }
        return paths
    }

    private static func keyLine(_ line: String) -> (spaces: Int, dash: Int, name: String)? {
        let spaces = line.prefix { $0 == " " }.count
        var rest = line.dropFirst(spaces)
        var dash = 0
        if rest.hasPrefix("- ") {
            let after = rest.dropFirst(1)
            let gap = after.prefix { $0 == " " }.count
            dash = 1 + gap
            rest = after.dropFirst(gap)
        }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }
        let after = rest.dropFirst(name.count)
        guard let first = name.first, first != "-", after.first == ":" else { return nil }
        guard after.count == 1 || after.dropFirst().first?.isWhitespace == true else { return nil }
        return (spaces, dash, String(name))
    }
}

/// The file as it was before a build migrated it, which that build keeps beside it: `symphony.yml.before-v0.0.1.700`.
public enum SettingsMigrationBackup {
    public static func url(config: URL, version: String) -> URL {
        config.deletingLastPathComponent().appendingPathComponent("\(config.lastPathComponent).before-v\(version)")
    }

    /// Puts the file as it was back when the build at `version` migrated it, because the build the rollback restores
    /// can't read the new keys. The migrated file stays beside it as `.after-v<version>`, for edits made since.
    /// Returns whether it put a file back.
    @discardableResult
    public static func restore(config: URL, version: String, files: FileManager = .default) -> Bool {
        let backup = url(config: config, version: version)
        guard files.fileExists(atPath: backup.path) else { return false }
        let migrated = config.deletingLastPathComponent().appendingPathComponent("\(config.lastPathComponent).after-v\(version)")
        try? files.removeItem(at: migrated)
        try? files.moveItem(at: config, to: migrated)
        return (try? files.moveItem(at: backup, to: config)) != nil
    }
}
