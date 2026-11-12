import Foundation

/// Why the `reports` settings can't be read or changed by editing one line.
public enum ReportSettingsError: LocalizedError, Equatable {
    /// `reports:` holds an inline value (for example `reports: {model: x}`) instead of an indented block.
    case notABlock(String)
    /// `reports.cadence` holds something other than `none`, `hourly`, `six_hours` or `daily`.
    case unknownCadence(String)
    /// A trigger holds something other than `true`, `false` or `null`.
    case notOnOrOff(key: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the report settings by hand."
        case .unknownCadence(let value):
            return "`reports.cadence: \(value)` in symphony.yml is not none, hourly, six_hours or daily. Change it by hand."
        case let .notOnOrOff(key, value):
            return "`\(key): \(value)` in symphony.yml is not true or false. Change it by hand."
        }
    }
}

/// How often Symphony writes a status report on its own: `reports.cadence`.
public enum ReportCadence: String, CaseIterable, Identifiable {
    case none
    case hourly
    case sixHours = "six_hours"
    case daily

    public var id: String { rawValue }

    /// The cadence as Settings' picker names it.
    public var title: String {
        switch self {
        case .none: return "Never"
        case .hourly: return "Every hour"
        case .sixHours: return "Every six hours"
        case .daily: return "Every day"
        }
    }
}

/// An event that starts a status report at once: one key of `reports.triggers`.
public enum ReportTrigger: String, CaseIterable, Identifiable {
    case ticketShipped = "ticket_shipped"
    case epicClosed = "epic_closed"
    case ciFixLoop = "ci_fix_loop"
    case selfHealFiled = "self_heal_filed"
    case releaseInstalled = "release_installed"
    case pausedByRule = "paused_by_rule"

    public var id: String { rawValue }

    /// The switch's title in Settings.
    public var title: String {
        switch self {
        case .ticketShipped: return "A ticket shipped"
        case .epicClosed: return "An epic closed"
        case .ciFixLoop: return "A ticket's CI fix loop passed three rounds"
        case .selfHealFiled: return "Self-heal filed a fix ticket"
        case .releaseInstalled: return "A release installed"
        case .pausedByRule: return "The factory paused by a rule"
        }
    }

    /// Whether Symphony starts a report on it when the key is missing or null.
    public var defaultOn: Bool { self == .ticketShipped || self == .pausedByRule }

    var path: [String] { ["reports", "triggers", rawValue] }
}

/// The status report's settings in the text of a `symphony.yml`: `reports.model`, the model a report run writes with
/// (the cheapest capable model when it is missing); `reports.cadence`, how often a report is written on its own (every
/// six hours when missing); and `reports.triggers.*`, the events that start one at once. Only the lines of the
/// settings that change are rewritten, or inserted with `reports:` (and `triggers:`) when missing, so the rest of the
/// file stays as it is.
public struct ReportSettings: Equatable {
    public var model: String
    public var cadence: ReportCadence
    public var triggers: [ReportTrigger: Bool]

    /// What Symphony uses when the key is missing, null or blank.
    public static let defaultModel = "claude-haiku-5-5"
    public static let defaultCadence = ReportCadence.sixHours
    public static let defaultTriggers = Dictionary(uniqueKeysWithValues: ReportTrigger.allCases.map { ($0, $0.defaultOn) })

    static let modelPath = ["reports", "model"]
    static let cadencePath = ["reports", "cadence"]

    public init(model: String = defaultModel, cadence: ReportCadence = defaultCadence, triggers: [ReportTrigger: Bool] = [:]) {
        self.model = model
        self.cadence = cadence
        self.triggers = Self.defaultTriggers.merging(triggers) { _, new in new }
    }

    /// Whether `trigger` starts a report.
    public func isOn(_ trigger: ReportTrigger) -> Bool { triggers[trigger] ?? trigger.defaultOn }

    /// The settings, with Symphony's default for a missing, null or blank key. A quoted value is read without its quotes.
    public static func values(in yaml: String) throws -> ReportSettings {
        let model = try scalar(at: modelPath, in: yaml).flatMap { $0.isEmpty ? nil : $0 } ?? defaultModel
        var cadence = defaultCadence
        if let value = try scalar(at: cadencePath, in: yaml), !value.isEmpty {
            guard let read = ReportCadence(rawValue: value) else { throw ReportSettingsError.unknownCadence(value) }
            cadence = read
        }
        var triggers: [ReportTrigger: Bool] = [:]
        for trigger in ReportTrigger.allCases {
            guard let value = try scalar(at: trigger.path, in: yaml) else { continue }
            switch value {
            case "true", "True", "TRUE": triggers[trigger] = true
            case "false", "False", "FALSE": triggers[trigger] = false
            default: throw ReportSettingsError.notOnOrOff(key: trigger.path.joined(separator: "."), value: value)
            }
        }
        return ReportSettings(model: model, cadence: cadence, triggers: triggers)
    }

    /// The same text with the settings that differ between `old` and `new` set to their `new` values. A blank model
    /// writes the default, since Symphony refuses a blank one. A missing key is inserted at the top of its section, so
    /// they are written last to first and read in order.
    public static func updating(_ yaml: String, from old: ReportSettings, to new: ReportSettings) throws -> String {
        let model = new.model.trimmingCharacters(in: .whitespacesAndNewlines)
        var changes: [(path: [String], changed: Bool, value: String)] = ReportTrigger.allCases.reversed().map { trigger in
            (trigger.path, new.isOn(trigger) != old.isOn(trigger), new.isOn(trigger) ? "true" : "false")
        }
        changes.append((cadencePath, new.cadence != old.cadence, new.cadence.rawValue))
        changes.append((modelPath, new.model != old.model, StepsWriter.scalar(model.isEmpty ? defaultModel : model)))
        var yaml = yaml
        for change in changes where change.changed {
            yaml = try blockSection { try ConfigSetting.setting(at: change.path, to: change.value, in: yaml) }
        }
        return yaml
    }

    /// The unquoted value at `path`, or nil for a missing or null key.
    private static func scalar(at path: [String], in yaml: String) throws -> String? {
        let value = try blockSection { try ConfigSetting.value(at: path, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return nil }
        return unquoted(value)
    }

    private static func unquoted(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2, let first = trimmed.first, first == trimmed.last, first == "\"" || first == "'" else { return trimmed }
        return String(trimmed.dropFirst().dropLast())
    }

    /// Reports an inline `reports:` section as a report settings error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw ReportSettingsError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readReportSettings() throws -> ReportSettings {
        try ReportSettings.values(in: read())
    }

    /// Sets the report settings that differ between `old` and `new`, once `check` passes on the result.
    public func writeReportSettings(
        _ new: ReportSettings,
        from old: ReportSettings,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try ReportSettings.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
