import Foundation

/// Why the `conductor` settings can't be read or changed by editing one line.
public enum ConductorSettingsError: LocalizedError, Equatable {
    /// `conductor:` holds an inline value (for example `conductor: {enabled: true}`) instead of an indented block.
    case notABlock(String)
    /// The on/off key holds something other than `true`, `false` or `null`.
    case notOnOrOff(key: String, value: String)
    /// The time limit holds something other than a whole number or `null`.
    case unreadable(key: String, value: String)
    /// A junction that is not one Symphony runs the Conductor at by a setting.
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

/// A moment in a ticket's life at which Symphony runs the Conductor, as a `conductor.update` names it. Each but
/// `duringRun` is one item of `conductor.junctions` (`settable`).
public enum ConductorJunction: String, CaseIterable, Identifiable {
    /// Before the first run of a ticket that has no plan: the Conductor writes the plan.
    case grooming
    /// An implementation run handed off, before Code Review or QA.
    case afterCoding = "after_coding"
    /// QA failed the change, before rework.
    case afterQAFail = "after_qa_fail"
    /// QA could not judge the change (its pass ended blocked or inconclusive), before Symphony retries it or asks.
    case afterQABlocked = "after_qa_blocked"
    /// A rework run handed off.
    case afterRework = "after_rework"
    /// QA passed or was skipped, before Merging.
    case beforeMerge = "before_merge"
    /// A person wrote to the ticket: the Conductor answers.
    case message
    /// A sub-ticket reached Done or Canceled while others remain; it runs on the parent.
    case subTicketEnded = "sub_ticket_ended"
    /// The last sub-ticket ended; it runs on the parent.
    case finalCheck = "final_check"
    /// A person wrote to a sub-ticket; it runs on the parent.
    case childMessage = "child_message"
    /// While it watched a running run (`conductor.watch`). Never an item of `conductor.junctions`.
    case duringRun = "during_run"

    public var id: String { rawValue }

    /// The junctions `conductor.junctions` may name, in the order Settings lists them.
    public static let settable: [ConductorJunction] = allCases.filter { $0 != .duringRun }

    /// The junction's row title in Settings.
    public var title: String {
        switch self {
        case .grooming: return "Grooming a new ticket"
        case .message: return "On a message from you"
        case .subTicketEnded: return "After a sub-ticket ends"
        case .finalCheck: return "At the final check"
        case .childMessage: return "On a message to a sub-ticket"
        case .duringRun: return "During a run"
        case .afterCoding: return "After coding"
        case .afterQAFail: return "After a QA fail"
        case .afterQABlocked: return "After a blocked QA"
        case .afterRework: return "After rework"
        case .beforeMerge: return "Before merge"
        }
    }
}

/// The Conductor's settings in the text of a `symphony.yml`: `conductor.enabled`, whether Symphony runs the Conductor
/// at all; `conductor.junctions`, the moments it runs at; `conductor.timeout_ms`, how long one turn may take before
/// the next run starts without it; `conductor.file_tickets`, whether it may file a linked ticket for a problem that is
/// not the current ticket's to solve; and `conductor.max_filed_tickets`, how many one ticket may file. Only the lines of the settings that change are rewritten, or inserted with
/// `conductor:` when missing, so the rest of the file stays as it is.
public struct ConductorSettings: Equatable {
    public var enabled: Bool
    public var junctions: Set<ConductorJunction>
    public var timeoutMs: Int
    /// `conductor.file_tickets`: whether the Conductor may file a linked ticket.
    public var fileTickets: Bool
    /// `conductor.max_filed_tickets`: how many tickets one ticket may file over its whole life.
    public var maxFiledTickets: Int
    /// `conductor.watch`: whether it watches running runs and may steer them, and its limits.
    public var watch: ConductorWatchSettings

    /// What Symphony uses when a key is missing or null.
    public static let defaultEnabled = false
    public static let defaultJunctions = Set(ConductorJunction.settable)
    public static let defaultTimeoutMs = 180_000
    public static let defaultFileTickets = true
    public static let defaultMaxFiledTickets = 2

    /// Milliseconds in one second, the unit Settings shows the time limit in.
    public static let msPerSecond = 1_000

    static let enabledPath = ["conductor", "enabled"]
    static let junctionsPath = ["conductor", "junctions"]
    static let timeoutPath = ["conductor", "timeout_ms"]
    static let fileTicketsPath = ["conductor", "file_tickets"]
    static let maxFiledTicketsPath = ["conductor", "max_filed_tickets"]

    public init(
        enabled: Bool = defaultEnabled, junctions: Set<ConductorJunction> = defaultJunctions, timeoutMs: Int = defaultTimeoutMs,
        fileTickets: Bool = defaultFileTickets, maxFiledTickets: Int = defaultMaxFiledTickets,
        watch: ConductorWatchSettings = ConductorWatchSettings()
    ) {
        self.enabled = enabled
        self.junctions = junctions
        self.timeoutMs = timeoutMs
        self.fileTickets = fileTickets
        self.maxFiledTickets = maxFiledTickets
        self.watch = watch
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
            timeoutMs: try number(timeoutPath, default: defaultTimeoutMs, in: yaml),
            fileTickets: try onOff(fileTicketsPath, default: defaultFileTickets, in: yaml),
            maxFiledTickets: try number(maxFiledTicketsPath, default: defaultMaxFiledTickets, in: yaml),
            watch: ConductorWatchSettings(
                enabled: try onOff(ConductorWatchSettings.path("enabled"), default: false, in: yaml),
                runMinutes: try number(ConductorWatchSettings.path("run_minutes"), default: ConductorWatchSettings.defaultRunMinutes, in: yaml),
                runTokens: try number(ConductorWatchSettings.path("run_tokens"), default: ConductorWatchSettings.defaultRunTokens, in: yaml),
                minIntervalMinutes: try number(
                    ConductorWatchSettings.path("min_interval_minutes"), default: ConductorWatchSettings.defaultMinIntervalMinutes, in: yaml),
                maxTurnsPerRun: try number(
                    ConductorWatchSettings.path("max_turns_per_run"), default: ConductorWatchSettings.defaultMaxTurnsPerRun, in: yaml),
                allowStop: try onOff(ConductorWatchSettings.path("allow_stop"), default: false, in: yaml)
            )
        )
    }

    /// The same text with the settings that differ between `old` and `new` set to their `new` values. A missing key is
    /// inserted at the top of `conductor:`, so they are written last to first and read in order.
    public static func updating(_ yaml: String, from old: ConductorSettings, to new: ConductorSettings) throws -> String {
        let (w, o) = (new.watch, old.watch)
        let changes: [(path: [String], changed: Bool, value: String)] = [
            (ConductorWatchSettings.path("allow_stop"), w.allowStop != o.allowStop, w.allowStop ? "true" : "false"),
            (ConductorWatchSettings.path("max_turns_per_run"), w.maxTurnsPerRun != o.maxTurnsPerRun, String(w.maxTurnsPerRun)),
            (ConductorWatchSettings.path("min_interval_minutes"), w.minIntervalMinutes != o.minIntervalMinutes, String(w.minIntervalMinutes)),
            (ConductorWatchSettings.path("run_tokens"), w.runTokens != o.runTokens, String(w.runTokens)),
            (ConductorWatchSettings.path("run_minutes"), w.runMinutes != o.runMinutes, String(w.runMinutes)),
            (ConductorWatchSettings.path("enabled"), w.enabled != o.enabled, w.enabled ? "true" : "false"),
            (maxFiledTicketsPath, new.maxFiledTickets != old.maxFiledTickets, String(new.maxFiledTickets)),
            (fileTicketsPath, new.fileTickets != old.fileTickets, new.fileTickets ? "true" : "false"),
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
        "[" + ConductorJunction.settable.filter(junctions.contains).map(\.rawValue).joined(separator: ", ") + "]"
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
            guard let junction = ConductorJunction(rawValue: unquoted(item)), ConductorJunction.settable.contains(junction) else {
                throw ConductorSettingsError.unknownJunction(item)
            }
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

/// `conductor.watch`: whether the Conductor watches running runs and may steer them (`enabled`), when it looks at one
/// past its start (`run_minutes`, `run_tokens`), how often at most (`min_interval_minutes`, `max_turns_per_run`) and
/// whether it may stop one, always with a question to the person (`allow_stop`).
public struct ConductorWatchSettings: Equatable {
    public var enabled: Bool
    public var runMinutes: Int
    public var runTokens: Int
    public var minIntervalMinutes: Int
    public var maxTurnsPerRun: Int
    public var allowStop: Bool

    /// What Symphony uses when a key is missing or null.
    public static let defaultRunMinutes = 30
    public static let defaultRunTokens = 30_000_000
    public static let defaultMinIntervalMinutes = 10
    public static let defaultMaxTurnsPerRun = 3

    /// The key paths of the settings, as `SettingsUIManifest` lists them.
    public static let keyPaths = ["enabled", "run_minutes", "run_tokens", "min_interval_minutes", "max_turns_per_run", "allow_stop"]
        .map { "conductor.watch." + $0 }

    public init(
        enabled: Bool = false, runMinutes: Int = defaultRunMinutes, runTokens: Int = defaultRunTokens,
        minIntervalMinutes: Int = defaultMinIntervalMinutes, maxTurnsPerRun: Int = defaultMaxTurnsPerRun, allowStop: Bool = false
    ) {
        self.enabled = enabled
        self.runMinutes = runMinutes
        self.runTokens = runTokens
        self.minIntervalMinutes = minIntervalMinutes
        self.maxTurnsPerRun = maxTurnsPerRun
        self.allowStop = allowStop
    }

    /// `conductor.watch.<key>` as a path.
    static func path(_ key: String) -> [String] { ["conductor", "watch", key] }
}
