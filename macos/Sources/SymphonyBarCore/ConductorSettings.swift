import Foundation

/// Why the `conductor` settings can't be read or changed by editing one line.
public enum ConductorSettingsError: LocalizedError, Equatable {
    /// `conductor:` holds an inline value (for example `conductor: {enabled: true}`) instead of an indented block.
    case notABlock(String)
    /// The on/off key holds something other than `true`, `false` or `null`.
    case notOnOrOff(key: String, value: String)
    /// The time limit holds something other than a whole number or `null`.
    case unreadable(key: String, value: String)
    /// A junction that is not one of the four Symphony knows.
    case unknownJunction(String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the Conductor settings by hand."
        case let .notOnOrOff(key, value):
            return "`\(key): \(value)` in symphony.yml is not true or false. Change it by hand."
        case let .unreadable(key, value):
            return "`\(key): \(value)` in symphony.yml is not a whole number. Change it by hand."
        case .unknownJunction(let value):
            return "`conductor.junctions` in symphony.yml names `\(value)`, which is not a junction. Change it by hand."
        }
    }
}

/// A moment in a ticket's life at which Symphony runs the Conductor: one item of `conductor.junctions`.
public enum ConductorJunction: String, CaseIterable, Identifiable {
    /// An implementation run handed off, before Code Review or QA.
    case afterCoding = "after_coding"
    /// QA failed the change, before rework.
    case afterQAFail = "after_qa_fail"
    /// A rework run handed off.
    case afterRework = "after_rework"
    /// QA passed or was skipped, before Merging.
    case beforeMerge = "before_merge"

    public var id: String { rawValue }

    /// The junction's row title in Settings.
    public var title: String {
        switch self {
        case .afterCoding: return "After coding"
        case .afterQAFail: return "After a QA fail"
        case .afterRework: return "After rework"
        case .beforeMerge: return "Before merge"
        }
    }
}

/// The Conductor's settings in the text of a `symphony.yml`: `conductor.enabled`, whether Symphony runs the Conductor
/// at all; `conductor.junctions`, the moments it runs at; and `conductor.timeout_ms`, how long one turn may take before
/// the next run starts without it. Only the lines of the settings that change are rewritten, or inserted with
/// `conductor:` when missing, so the rest of the file stays as it is.
public struct ConductorSettings: Equatable {
    public var enabled: Bool
    public var junctions: Set<ConductorJunction>
    public var timeoutMs: Int

    /// What Symphony uses when a key is missing or null.
    public static let defaultEnabled = false
    public static let defaultJunctions = Set(ConductorJunction.allCases)
    public static let defaultTimeoutMs = 180_000

    /// Milliseconds in one second, the unit Settings shows the time limit in.
    public static let msPerSecond = 1_000

    static let enabledPath = ["conductor", "enabled"]
    static let junctionsPath = ["conductor", "junctions"]
    static let timeoutPath = ["conductor", "timeout_ms"]

    public init(enabled: Bool = defaultEnabled, junctions: Set<ConductorJunction> = defaultJunctions, timeoutMs: Int = defaultTimeoutMs) {
        self.enabled = enabled
        self.junctions = junctions
        self.timeoutMs = timeoutMs
    }

    /// The time limit in whole seconds, for the field.
    public var timeoutSeconds: Int { Int((Double(timeoutMs) / Double(Self.msPerSecond)).rounded()) }

    /// These settings with the field's time limit. When the field didn't change the limit keeps its exact value, so one
    /// that isn't a whole number of seconds is never rewritten by an untouched field.
    public func setting(timeoutSeconds seconds: Int) -> ConductorSettings {
        var settings = self
        if seconds != timeoutSeconds { settings.timeoutMs = seconds * Self.msPerSecond }
        return settings
    }

    /// Whether the Conductor runs at `junction`.
    public func runs(at junction: ConductorJunction) -> Bool { junctions.contains(junction) }

    /// These settings with `junction` on or off.
    public func setting(_ junction: ConductorJunction, on: Bool) -> ConductorSettings {
        var settings = self
        if on { settings.junctions.insert(junction) } else { settings.junctions.remove(junction) }
        return settings
    }

    /// The settings, with Symphony's default for a missing or null key. `junctions` reads an inline list
    /// (`[after_coding, before_merge]`) or a block list; `[]` runs it at none.
    public static func values(in yaml: String) throws -> ConductorSettings {
        ConductorSettings(
            enabled: try onOff(enabledPath, default: defaultEnabled, in: yaml),
            junctions: try junctions(in: yaml),
            timeoutMs: try number(timeoutPath, default: defaultTimeoutMs, in: yaml)
        )
    }

    /// The same text with the settings that differ between `old` and `new` set to their `new` values. A missing key is
    /// inserted at the top of `conductor:`, so they are written last to first and read in order.
    public static func updating(_ yaml: String, from old: ConductorSettings, to new: ConductorSettings) throws -> String {
        let changes: [(path: [String], changed: Bool, value: String)] = [
            (timeoutPath, new.timeoutMs != old.timeoutMs, String(new.timeoutMs)),
            (junctionsPath, new.junctions != old.junctions, inline(new.junctions)),
            (enabledPath, new.enabled != old.enabled, new.enabled ? "true" : "false"),
        ]
        var yaml = yaml
        for change in changes where change.changed {
            yaml = try blockSection { try ConfigSetting.setting(at: change.path, to: change.value, in: yaml) }
        }
        return yaml
    }

    /// `[after_coding, before_merge]`, in the junctions' order.
    static func inline(_ junctions: Set<ConductorJunction>) -> String {
        "[" + ConductorJunction.allCases.filter(junctions.contains).map(\.rawValue).joined(separator: ", ") + "]"
    }

    private static func junctions(in yaml: String) throws -> Set<ConductorJunction> {
        let raw = try blockSection { try ConfigSetting.value(at: junctionsPath, of: yaml) }
        guard let raw = raw?.trimmingCharacters(in: .whitespaces) else { return defaultJunctions }
        let items: [String]
        if raw.isEmpty {
            // A block list under the key; `junctions:` with nothing under it is null.
            items = try blockListItems(in: yaml)
            if items.isEmpty { return defaultJunctions }
        } else if TokenLimits.nullValues.contains(raw) {
            return defaultJunctions
        } else {
            items = inlineItems(raw)
        }
        return try items.reduce(into: Set<ConductorJunction>()) { result, item in
            guard let junction = ConductorJunction(rawValue: unquoted(item)) else { throw ConductorSettingsError.unknownJunction(item) }
            result.insert(junction)
        }
    }

    /// The items of an inline list, `[after_coding, before_merge]`, or a single bare value.
    private static func inlineItems(_ raw: String) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("["), text.hasSuffix("]") else { return [text] }
        return text.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The items of a block list under `conductor.junctions`.
    private static func blockListItems(in yaml: String) throws -> [String] {
        let document = Document(yaml)
        var range = document.all
        for name in junctionsPath {
            guard let child = document.child(name, in: range) else { return [] }
            if name == junctionsPath.last { return document.blockListItems(child) }
            range = try blockSection { try document.block(of: child) }
        }
        return []
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func number(_ path: [String], default defaultValue: Int, in yaml: String) throws -> Int {
        let value = try blockSection { try ConfigSetting.value(at: path, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return defaultValue }
        guard let number = Int(value.filter { $0 != "_" }) else {
            throw ConductorSettingsError.unreadable(key: path.joined(separator: "."), value: value)
        }
        return number
    }

    private static func onOff(_ path: [String], default defaultValue: Bool, in yaml: String) throws -> Bool {
        let value = try blockSection { try ConfigSetting.value(at: path, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return defaultValue }
        switch value {
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: throw ConductorSettingsError.notOnOrOff(key: path.joined(separator: "."), value: value)
        }
    }

    /// Reports an inline `conductor:` section as a Conductor settings error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw ConductorSettingsError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readConductorSettings() throws -> ConductorSettings {
        try ConductorSettings.values(in: read())
    }

    /// Sets the settings that differ between `old` and `new`, once `check` passes on the result.
    public func writeConductorSettings(
        _ new: ConductorSettings,
        from old: ConductorSettings,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try ConductorSettings.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
