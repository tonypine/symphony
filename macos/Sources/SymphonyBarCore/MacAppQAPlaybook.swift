import Foundation

/// Why the Mac app QA settings can't be read or changed by editing their lines.
public enum MacAppQAPlaybookError: LocalizedError, Equatable {
    /// A key on the path holds an inline value (for example `macos_app: {build: make}`) instead of an indented block.
    case notABlock(String)
    /// A key holds something Settings can't read, such as a port that isn't a whole number.
    case unreadable(key: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the Mac app QA settings by hand."
        case let .unreadable(key, value):
            return "`\(key): \(value)` in symphony.yml can't be read here. Change it by hand."
        }
    }
}

/// One variable the app under test gets when QA launches it: `auto_review.playbooks.macos_app.launch_env.<name>`.
/// Two variables are equal when their names and values are, whatever their row.
public struct LaunchVariable: Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String, value: String) {
        self.id = id
        self.name = name
        self.value = value
    }

    public static func == (lhs: LaunchVariable, rhs: LaunchVariable) -> Bool {
        lhs.name == rhs.name && lhs.value == rhs.value
    }
}

/// The `macos_app` QA playbook settings that run the project's dev server on the QA host and hand the app its
/// environment, in the text of a `symphony.yml`: `dev_server`, `dev_server_port` and `launch_env` under
/// `auto_review.playbooks.macos_app`. Only the lines that change are rewritten, or inserted when missing, so the
/// rest of the file stays as it is.
public struct MacAppQAPlaybook: Equatable {
    /// Whether a pass on the QA host starts `verification.dev_server` there, beside the app.
    public var devServer: Bool
    /// The port that dev server listens on, as `SYMPHONY_VERIFICATION_PORT`.
    public var devServerPort: Int
    /// The extra variables the app gets, after Symphony's own.
    public var launchEnv: [LaunchVariable]

    /// What Symphony uses when a key is missing or null.
    public static let defaultDevServerPort = 8090

    static let path = ["auto_review", "playbooks", "macos_app"]
    static let emptyMaps: Set<String> = ["{}", "~", "null", "Null", "NULL"]

    public init(devServer: Bool = false, devServerPort: Int = defaultDevServerPort, launchEnv: [LaunchVariable] = []) {
        self.devServer = devServer
        self.devServerPort = devServerPort
        self.launchEnv = launchEnv
    }

    /// These settings without the variable rows left blank, names trimmed.
    public func trimmed() -> MacAppQAPlaybook {
        var copy = self
        copy.launchEnv = launchEnv
            .map { LaunchVariable(id: $0.id, name: $0.name.trimmingWhitespace(), value: $0.value) }
            .filter { !$0.name.isEmpty || !$0.value.isEmpty }
        return copy
    }

    /// The settings, with Symphony's default for a missing or null key.
    public static func values(in yaml: String) throws -> MacAppQAPlaybook {
        let document = Document(yaml)
        guard let range = try block(path, in: document) else { return MacAppQAPlaybook() }
        return MacAppQAPlaybook(
            devServer: try devServer(document.child("dev_server", in: range)),
            devServerPort: try port(document.child("dev_server_port", in: range)),
            launchEnv: try launchEnv(document.child("launch_env", in: range), in: document)
        )
    }

    /// The same text with the settings that differ between `old` and `new` set to their `new` values. A missing key
    /// goes first under `macos_app:`, so they are set last to first and read in order.
    public static func updating(_ yaml: String, from old: MacAppQAPlaybook, to new: MacAppQAPlaybook) throws -> String {
        var yaml = yaml
        if new.launchEnv != old.launchEnv {
            yaml = try settingLaunchEnv(new.launchEnv, in: yaml)
        }
        if new.devServerPort != old.devServerPort {
            yaml = try setting("dev_server_port", to: String(new.devServerPort), in: yaml)
        }
        if new.devServer != old.devServer {
            yaml = try setting("dev_server", to: new.devServer ? "true" : "false", in: yaml)
        }
        return yaml
    }

    // MARK: Reading

    /// The lines under `path`, or nil when a key on it is missing, `{}` or null.
    private static func block(_ path: [String], in document: Document) throws -> Range<Int>? {
        var range = document.all
        for name in path {
            guard let key = document.child(name, in: range) else { return nil }
            let value = ValueLine(key.rest).value
            if value.isEmpty {
                range = document.children(of: key)
            } else if emptyMaps.contains(value) {
                return nil
            } else {
                throw MacAppQAPlaybookError.notABlock(name)
            }
        }
        return range
    }

    private static func devServer(_ key: Document.Key?) throws -> Bool {
        guard let key else { return false }
        switch ValueLine(key.rest).value {
        case "true": return true
        case "false": return false
        case let value where TokenLimits.nullValues.contains(value): return false
        case let value: throw MacAppQAPlaybookError.unreadable(key: "dev_server", value: value)
        }
    }

    private static func port(_ key: Document.Key?) throws -> Int {
        guard let key else { return defaultDevServerPort }
        let value = ValueLine(key.rest).value
        if TokenLimits.nullValues.contains(value) { return defaultDevServerPort }
        guard let port = Int(value.filter { $0 != "_" }) else {
            throw MacAppQAPlaybookError.unreadable(key: "dev_server_port", value: value)
        }
        return port
    }

    /// The `NAME: value` lines of the `launch_env` block, in file order.
    private static func launchEnv(_ key: Document.Key?, in document: Document) throws -> [LaunchVariable] {
        guard let key else { return [] }
        let value = ValueLine(key.rest).value
        guard value.isEmpty else {
            if emptyMaps.contains(value) { return [] }
            throw MacAppQAPlaybookError.notABlock("launch_env")
        }
        let children = document.children(of: key)
        guard let indent = document.childIndent(in: children) else { return [] }
        return try children.compactMap { index -> LaunchVariable? in
            guard let lineIndent = document.indent(at: index) else { return nil }
            let line = document.lines[index].dropFirst(lineIndent)
            guard lineIndent == indent, let colon = line.firstIndex(of: ":") else {
                throw MacAppQAPlaybookError.unreadable(key: "launch_env", value: String(line))
            }
            let name = try scalar(String(line[..<colon]).trimmingWhitespace(), key: "launch_env")
            let value = try scalar(ValueLine(String(line[line.index(after: colon)...])).value, key: "launch_env.\(name)")
            return LaunchVariable(name: name, value: value)
        }
    }

    /// A plain, `"double-quoted"` or `'single-quoted'` YAML scalar's text.
    static func scalar(_ text: String, key: String) throws -> String {
        if text.count >= 2, text.hasPrefix("'"), text.hasSuffix("'") {
            return String(text.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        guard text.hasPrefix("\"") else { return text }
        var result = ""
        var escaped = false
        for character in text.dropFirst() {
            if escaped {
                switch character {
                case "\"", "\\", "/": result.append(character)
                case "n": result.append("\n")
                case "t": result.append("\t")
                default: throw MacAppQAPlaybookError.unreadable(key: key, value: text)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
        }
        throw MacAppQAPlaybookError.unreadable(key: key, value: text)
    }

    // MARK: Writing

    private static func setting(_ key: String, to value: String, in yaml: String) throws -> String {
        try blockSection { try ConfigSetting.setting(at: path + [key], to: value, in: opening(path, in: yaml)) }
    }

    /// Replaces the `launch_env` block, inserting it when missing; an empty list is `launch_env: {}`.
    private static func settingLaunchEnv(_ variables: [LaunchVariable], in yaml: String) throws -> String {
        var yaml = try opening(path, in: yaml)
        var document = Document(yaml)
        guard let range = try block(path, in: document), let existing = document.child("launch_env", in: range) else {
            yaml = try setting("launch_env", to: "{}", in: yaml)
            return variables.isEmpty ? yaml : try settingLaunchEnv(variables, in: yaml)
        }
        let value = ValueLine(existing.rest).value
        guard value.isEmpty || emptyMaps.contains(value) else { throw MacAppQAPlaybookError.notABlock("launch_env") }

        let prefix = String(repeating: " ", count: existing.indent) + "launch_env:"
        let childIndent = String(repeating: " ", count: existing.indent + ConfigSetting.defaultIndentStep)
        let lines = variables.isEmpty
            ? [prefix + " {}"]
            : [prefix] + variables.map { childIndent + $0.name + ": " + quoted($0.value) }
        let last = document.lastStructural(in: document.children(of: existing)) ?? existing.index
        document.lines.replaceSubrange(existing.index...last, with: lines)
        return document.text
    }

    /// `value` as a double-quoted YAML string, so a value such as `yes`, `8090` or `a: b` stays text.
    static func quoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"" + escaped + "\""
    }

    /// The text with a `{}` or null section on `path` turned into an empty block, so keys can go under it.
    private static func opening(_ path: [String], in yaml: String) throws -> String {
        var document = Document(yaml)
        var range = document.all
        for name in path {
            guard let key = document.child(name, in: range) else { break }
            let value = ValueLine(key.rest).value
            if emptyMaps.contains(value) {
                document.lines[key.index] = String(repeating: " ", count: key.indent) + name + ":"
            } else if !value.isEmpty {
                throw MacAppQAPlaybookError.notABlock(name)
            }
            range = document.children(of: key)
        }
        return document.text
    }

    /// Reports an inline section above a setting as a Mac app QA error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw MacAppQAPlaybookError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readMacAppQAPlaybook() throws -> MacAppQAPlaybook {
        try MacAppQAPlaybook.values(in: read())
    }

    /// Sets the Mac app QA settings that differ between `old` and `new`, once `check` passes on the result.
    public func writeMacAppQAPlaybook(
        _ new: MacAppQAPlaybook,
        from old: MacAppQAPlaybook,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try MacAppQAPlaybook.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
