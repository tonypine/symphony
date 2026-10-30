import Foundation

/// Why the `dispatch` settings can't be read or changed by editing one line.
public enum DispatchSettingsError: LocalizedError, Equatable {
    /// `dispatch:` holds an inline value (for example `dispatch: {source: record}`) instead of an indented block.
    case notABlock(String)
    /// `dispatch.source` holds something other than `poll`, `record` or `null`.
    case unknownSource(String)
    /// `dispatch.shadow_window` holds something other than a whole number or `null`.
    case unreadable(key: String, value: String)
    /// The window to write is 0 or negative, which `symphony check` refuses.
    case windowNotPositive(Int)
    /// The reconcile interval to write is under one minute, which `symphony check` refuses.
    case reconcileUnderOneMinute(Int)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the dispatch settings by hand."
        case .unknownSource(let value):
            return "`dispatch.source: \(value)` in symphony.yml is not poll or record. Change it by hand."
        case let .unreadable(key, value):
            return "`\(key): \(value)` in symphony.yml is not a whole number. Change it by hand."
        case .windowNotPositive:
            return DispatchSettings.windowRule
        case .reconcileUnderOneMinute:
            return DispatchSettings.reconcileRule
        }
    }
}

/// Where dispatch reads its candidates from, in the text of a `symphony.yml`: `dispatch.source`, the Linear poll's cache
/// (`poll`) or Symphony's ticket records (`record`), and `dispatch.shadow_window`, how many poll cycles the shadow
/// report (`DispatchShadowReport`) counts its differences over; and `linear.reconcile_interval_ms`, how often the Linear
/// poll reconciles the record with Linear while dispatch reads the record (`ReconcileReport`), shown in whole minutes.
/// Only the lines of the settings that change are rewritten, or inserted with `dispatch:` when missing, so the rest of
/// the file stays as it is.
public struct DispatchSettings: Equatable {
    /// What the dispatcher reads its candidates from.
    public enum Source: String, CaseIterable, Equatable {
        /// The Linear poll's cache.
        case poll
        /// Symphony's ticket records.
        case record

        /// The picker's words.
        public var title: String {
            switch self {
            case .poll: "Linear poll"
            case .record: "Symphony's record"
            }
        }
    }

    public var source: Source
    public var shadowWindow: Int
    /// `linear.reconcile_interval_ms`, in milliseconds as symphony.yml holds it.
    public var reconcileIntervalMs: Int

    /// What Symphony uses when a key is missing or null.
    public static let defaultSource = Source.poll
    public static let defaultShadowWindow = 20
    public static let defaultReconcileIntervalMs = 300_000

    /// Why Save refused the window: Symphony counts at least one cycle.
    public static let windowRule = "The shadow window is a number of poll cycles: 1 or more."
    /// Why Save refused the reconcile interval: Symphony reconciles at most once a minute.
    public static let reconcileRule = "The reconcile interval is a number of minutes: 1 or more."

    static let sourcePath = ["dispatch", "source"]
    static let shadowWindowPath = ["dispatch", "shadow_window"]
    static let reconcileIntervalPath = ["linear", "reconcile_interval_ms"]

    public init(
        source: Source = defaultSource,
        shadowWindow: Int = defaultShadowWindow,
        reconcileIntervalMs: Int = defaultReconcileIntervalMs
    ) {
        self.source = source
        self.shadowWindow = shadowWindow
        self.reconcileIntervalMs = reconcileIntervalMs
    }

    /// True for a window Symphony accepts: 1 cycle or more.
    public static func isValidWindow(_ window: Int) -> Bool { window > 0 }

    /// True for a reconcile interval Symphony accepts: one minute or more.
    public static func isValidReconcileMinutes(_ minutes: Int) -> Bool { minutes >= 1 }

    /// `ms` in whole minutes for the field, rounded; never under one.
    public static func reconcileMinutes(_ ms: Int) -> Int {
        max(Int((Double(ms) / 60_000).rounded()), 1)
    }

    /// These settings with the controls' values. An interval whose field still shows the minutes it was read as keeps
    /// its exact value, so one that isn't a whole number of minutes is never rewritten by an untouched field.
    public func setting(source: Source, shadowWindow: Int, reconcileMinutes: Int) -> DispatchSettings {
        DispatchSettings(
            source: source,
            shadowWindow: shadowWindow,
            reconcileIntervalMs: reconcileMinutes == Self.reconcileMinutes(reconcileIntervalMs)
                ? reconcileIntervalMs : reconcileMinutes * 60_000
        )
    }

    /// The settings, with Symphony's default for a missing or null key.
    public static func values(in yaml: String) throws -> DispatchSettings {
        DispatchSettings(source: try source(in: yaml), shadowWindow: try window(in: yaml), reconcileIntervalMs: try reconcileInterval(in: yaml))
    }

    /// The same text with the settings that differ between `old` and `new` set to their `new` values. A missing key is
    /// inserted at the top of its section, so they are written last to first and read in order. Throws
    /// `windowNotPositive` for a window of 0 or less and `reconcileUnderOneMinute` for an interval under one minute,
    /// and writes nothing then.
    public static func updating(_ yaml: String, from old: DispatchSettings, to new: DispatchSettings) throws -> String {
        guard isValidWindow(new.shadowWindow) else { throw DispatchSettingsError.windowNotPositive(new.shadowWindow) }
        guard new.reconcileIntervalMs >= 60_000 else {
            throw DispatchSettingsError.reconcileUnderOneMinute(new.reconcileIntervalMs)
        }
        let changes: [(path: [String], changed: Bool, value: String)] = [
            (reconcileIntervalPath, new.reconcileIntervalMs != old.reconcileIntervalMs, String(new.reconcileIntervalMs)),
            (shadowWindowPath, new.shadowWindow != old.shadowWindow, String(new.shadowWindow)),
            (sourcePath, new.source != old.source, new.source.rawValue),
        ]
        var yaml = yaml
        for change in changes where change.changed {
            yaml = try blockSection { try ConfigSetting.setting(at: change.path, to: change.value, in: yaml) }
        }
        return yaml
    }

    private static func source(in yaml: String) throws -> Source {
        guard let value = try present(sourcePath, in: yaml) else { return defaultSource }
        let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard let source = Source(rawValue: unquoted) else { throw DispatchSettingsError.unknownSource(value) }
        return source
    }

    private static func window(in yaml: String) throws -> Int {
        try number(shadowWindowPath, default: defaultShadowWindow, in: yaml)
    }

    private static func reconcileInterval(in yaml: String) throws -> Int {
        try number(reconcileIntervalPath, default: defaultReconcileIntervalMs, in: yaml)
    }

    private static func number(_ path: [String], default defaultValue: Int, in yaml: String) throws -> Int {
        guard let value = try present(path, in: yaml) else { return defaultValue }
        guard let number = Int(value.filter { $0 != "_" }) else {
            throw DispatchSettingsError.unreadable(key: path.joined(separator: "."), value: value)
        }
        return number
    }

    /// The key's value, or nil when it is missing or null.
    private static func present(_ path: [String], in yaml: String) throws -> String? {
        let value = try blockSection { try ConfigSetting.value(at: path, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return nil }
        return value
    }

    /// Reports an inline `dispatch:` or `linear:` section as a dispatch settings error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw DispatchSettingsError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readDispatchSettings() throws -> DispatchSettings {
        try DispatchSettings.values(in: read())
    }

    /// Sets the settings that differ between `old` and `new`, once `check` passes on the result.
    public func writeDispatchSettings(
        _ new: DispatchSettings,
        from old: DispatchSettings,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try DispatchSettings.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
