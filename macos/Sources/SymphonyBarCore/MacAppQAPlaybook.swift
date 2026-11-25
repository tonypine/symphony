import Foundation

/// Why the macOS app QA settings can't be read or changed by editing their lines.
public enum MacAppQAPlaybookError: LocalizedError, Equatable {
    /// A key on the path holds an inline value (for example `macos_app: {build: make}`) instead of an indented block.
    case notABlock(String)
    /// A key holds something Settings can't read, such as a port that isn't a whole number.
    case unreadable(key: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the macOS app QA settings by hand."
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

/// The `macos_app` QA playbook settings that hand the app its environment and set its QA target (window size and
/// appearance), in the text of a `symphony.yml`: `dev_server_port`, `launch_env`, `window_width`, `window_height` and
/// `appearance` under `auto_review.playbooks.macos_app`, with the project's own server (`verification.dev_server`),
/// which Settings shows in the same block. Only the lines that change are rewritten, or inserted when missing, so the
/// rest of the file stays as it is.
public struct MacAppQAPlaybook: Equatable {
    /// The project's own server, `verification.dev_server`: how it runs, and when.
    public var projectServer: ProjectServerSettings
    /// The port the project's server listens on, as `SYMPHONY_VERIFICATION_PORT`, when it runs on the QA host.
    public var devServerPort: Int
    /// The extra variables the app gets, after Symphony's own.
    public var launchEnv: [LaunchVariable]
    /// The width, in points, of the QA target window: QA sets the app's main window to it for the walkthrough.
    public var windowWidth: Int
    /// The height, in points, of the QA target window: QA sets the app's main window to it for the walkthrough.
    public var windowHeight: Int
    /// The appearance QA launches the app in: `light` or `dark`.
    public var appearance: String

    /// What Symphony uses when a key is missing or null.
    public static let defaultDevServerPort = 8090
    public static let defaultWindowWidth = 2560
    public static let defaultWindowHeight = 1440
    public static let defaultAppearance = "dark"
    /// The appearances `appearance` may hold.
    public static let appearances = ["light", "dark"]

    static let path = ["auto_review", "playbooks", "macos_app"]
    static let emptyMaps: Set<String> = ["{}", "~", "null", "Null", "NULL"]

    public init(
        projectServer: ProjectServerSettings = ProjectServerSettings(),
        devServerPort: Int = defaultDevServerPort,
        launchEnv: [LaunchVariable] = [],
        windowWidth: Int = defaultWindowWidth,
        windowHeight: Int = defaultWindowHeight,
        appearance: String = defaultAppearance
    ) {
        self.projectServer = projectServer
        self.devServerPort = devServerPort
        self.launchEnv = launchEnv
        self.windowWidth = windowWidth
        self.windowHeight = windowHeight
        self.appearance = appearance
    }

    /// These settings without the variable rows left blank, names trimmed.
    public func trimmed() -> MacAppQAPlaybook {
        var copy = self
        copy.projectServer = projectServer.trimmed()
        copy.launchEnv = launchEnv
            .map { LaunchVariable(id: $0.id, name: $0.name.trimmingWhitespace(), value: $0.value) }
            .filter { !$0.name.isEmpty || !$0.value.isEmpty }
        return copy
    }

    /// The settings, with Symphony's default for a missing or null key.
    public static func values(in yaml: String) throws -> MacAppQAPlaybook {
        let projectServer = try ProjectServerSettings.values(in: yaml)
        let document = Document(yaml)
        guard let range = try block(path, in: document) else { return MacAppQAPlaybook(projectServer: projectServer) }
        return MacAppQAPlaybook(
            projectServer: projectServer,
            devServerPort: try integer(document.child("dev_server_port", in: range), key: "dev_server_port", default: defaultDevServerPort),
            launchEnv: try launchEnv(document.child("launch_env", in: range), in: document),
            windowWidth: try integer(document.child("window_width", in: range), key: "window_width", default: defaultWindowWidth),
            windowHeight: try integer(document.child("window_height", in: range), key: "window_height", default: defaultWindowHeight),
            appearance: try appearance(document.child("appearance", in: range))
        )
    }

    /// The same text with the settings that differ between `old` and `new` set to their `new` values. A missing key
    /// goes first under `macos_app:`, so they are set last to first and read in order.
    public static func updating(_ yaml: String, from old: MacAppQAPlaybook, to new: MacAppQAPlaybook) throws -> String {
        var yaml = yaml
        if new.appearance != old.appearance {
            yaml = try setting("appearance", to: new.appearance, in: yaml)
        }
        let sizes: [(String, KeyPath<MacAppQAPlaybook, Int>)] = [
            ("window_height", \.windowHeight),
            ("window_width", \.windowWidth),
        ]
        for (key, size) in sizes where new[keyPath: size] != old[keyPath: size] {
            yaml = try setting(key, to: String(new[keyPath: size]), in: yaml)
        }
        if new.launchEnv != old.launchEnv {
            yaml = try settingLaunchEnv(new.launchEnv, in: yaml)
        }
        if new.devServerPort != old.devServerPort {
            yaml = try setting("dev_server_port", to: String(new.devServerPort), in: yaml)
        }
        if new.projectServer != old.projectServer {
            yaml = try ProjectServerSettings.updating(yaml, from: old.projectServer, to: new.projectServer)
        }
        return yaml
    }

    // MARK: Reading

    /// The lines under `path`, or nil when a key on it is missing, `{}` or null.
    static func block(_ path: [String], in document: Document) throws -> Range<Int>? {
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

    /// A whole-number setting such as `dev_server_port` or `window_width`, with `fallback` when it is missing or null.
    private static func integer(_ key: Document.Key?, key name: String, default fallback: Int) throws -> Int {
        guard let key else { return fallback }
        let value = ValueLine(key.rest).value
        if TokenLimits.nullValues.contains(value) { return fallback }
        guard let number = Int(value.filter { $0 != "_" }) else {
            throw MacAppQAPlaybookError.unreadable(key: name, value: value)
        }
        return number
    }

    /// The `appearance` setting, `light` or `dark`, with `dark` when it is missing or null.
    private static func appearance(_ key: Document.Key?) throws -> String {
        guard let key else { return defaultAppearance }
        let value = ValueLine(key.rest).value
        if TokenLimits.nullValues.contains(value) { return defaultAppearance }
        let text = try scalar(value, key: "appearance")
        guard appearances.contains(text) else {
            throw MacAppQAPlaybookError.unreadable(key: "appearance", value: value)
        }
        return text
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
    static func opening(_ path: [String], in yaml: String) throws -> String {
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

    /// Reports an inline section above a setting as a macOS app QA error.
    static func blockSection<T>(_ body: () throws -> T) throws -> T {
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

    /// Sets the macOS app QA settings that differ between `old` and `new`, once `check` passes on the result.
    public func writeMacAppQAPlaybook(
        _ new: MacAppQAPlaybook,
        from old: MacAppQAPlaybook,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try MacAppQAPlaybook.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
