import Foundation

/// Why the `watchdog.dispatch_loop_*` limits can't be read or changed by editing one line.
public enum DispatchLoopLimitsError: LocalizedError, Equatable {
    /// `watchdog:` holds an inline value (for example `watchdog: {enabled: true}`) instead of an indented block.
    case notABlock(String)
    /// The key holds something other than a whole number or `null`.
    case unreadable(key: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the dispatch-loop limits by hand."
        case let .unreadable(key, value):
            return "`\(key): \(value)` in symphony.yml is not a whole number. Change it by hand."
        }
    }
}

/// The dispatch-loop guard's two limits in the text of a `symphony.yml`: `watchdog.dispatch_loop_runs` runs within
/// `watchdog.dispatch_loop_window_ms`, and `watchdog.dispatch_loop_long_runs` within
/// `watchdog.dispatch_loop_long_window_ms`. Once a ticket got that many runs of one kind without progress, Symphony
/// holds it instead of dispatching it again. Only the lines of the limits that change are rewritten, or inserted when
/// missing, so the rest of the file stays as it is.
public struct DispatchLoopLimits: Equatable {
    /// Runs of one kind a ticket may get without progress within `windowMs`.
    public var runs: Int
    public var windowMs: Int
    /// Runs of one kind a ticket may get without progress within `longWindowMs`.
    public var longRuns: Int
    public var longWindowMs: Int

    /// What Symphony uses when a key is missing or null.
    public static let defaultRuns = 4
    public static let defaultWindowMs = 600_000
    public static let defaultLongRuns = 8
    public static let defaultLongWindowMs = 3_600_000

    /// Values Settings offers: runs, and windows in minutes (up to a day).
    public static let runRange = 1...50
    public static let minuteRange = 1...1_440

    static let runsPath = ["watchdog", "dispatch_loop_runs"]
    static let windowPath = ["watchdog", "dispatch_loop_window_ms"]
    static let longRunsPath = ["watchdog", "dispatch_loop_long_runs"]
    static let longWindowPath = ["watchdog", "dispatch_loop_long_window_ms"]

    public init(
        runs: Int = defaultRuns,
        windowMs: Int = defaultWindowMs,
        longRuns: Int = defaultLongRuns,
        longWindowMs: Int = defaultLongWindowMs
    ) {
        self.runs = runs
        self.windowMs = windowMs
        self.longRuns = longRuns
        self.longWindowMs = longWindowMs
    }

    /// The limits, with Symphony's default for a missing or null key.
    public static func values(in yaml: String) throws -> DispatchLoopLimits {
        DispatchLoopLimits(
            runs: try number(runsPath, default: defaultRuns, in: yaml),
            windowMs: try number(windowPath, default: defaultWindowMs, in: yaml),
            longRuns: try number(longRunsPath, default: defaultLongRuns, in: yaml),
            longWindowMs: try number(longWindowPath, default: defaultLongWindowMs, in: yaml)
        )
    }

    /// The same text with the limits that differ between `old` and `new` set to their `new` values. A missing key is
    /// inserted at the top of `watchdog:`, so they are written last to first and read in order.
    public static func updating(_ yaml: String, from old: DispatchLoopLimits, to new: DispatchLoopLimits) throws -> String {
        var yaml = yaml
        for (path, keyPath) in [
            (longWindowPath, \DispatchLoopLimits.longWindowMs),
            (longRunsPath, \DispatchLoopLimits.longRuns),
            (windowPath, \DispatchLoopLimits.windowMs),
            (runsPath, \DispatchLoopLimits.runs),
        ] where new[keyPath: keyPath] != old[keyPath: keyPath] {
            yaml = try setting(path, to: new[keyPath: keyPath], in: yaml)
        }
        return yaml
    }

    /// `runs` for a stepper: kept within `runRange`.
    public static func steppedRuns(_ runs: Int) -> Int {
        min(max(runs, runRange.lowerBound), runRange.upperBound)
    }

    /// `ms` in whole minutes for a stepper: rounded, and kept within `minuteRange`.
    public static func minutes(_ ms: Int) -> Int {
        min(max(Int((Double(ms) / 60_000).rounded()), minuteRange.lowerBound), minuteRange.upperBound)
    }

    /// These limits with the steppers' values. A limit whose stepper didn't move keeps its exact value, so one the
    /// stepper can't show (a window that isn't a whole number of minutes, say) is never rewritten by an untouched
    /// stepper.
    public func setting(runs: Int, windowMinutes: Int, longRuns: Int, longWindowMinutes: Int) -> DispatchLoopLimits {
        DispatchLoopLimits(
            runs: runs == Self.steppedRuns(self.runs) ? self.runs : runs,
            windowMs: windowMinutes == Self.minutes(windowMs) ? windowMs : windowMinutes * 60_000,
            longRuns: longRuns == Self.steppedRuns(self.longRuns) ? self.longRuns : longRuns,
            longWindowMs: longWindowMinutes == Self.minutes(longWindowMs) ? longWindowMs : longWindowMinutes * 60_000
        )
    }

    private static func number(_ path: [String], default defaultValue: Int, in yaml: String) throws -> Int {
        let value = try blockSection { try ConfigSetting.value(at: path, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return defaultValue }
        guard let number = Int(value.filter { $0 != "_" }) else {
            throw DispatchLoopLimitsError.unreadable(key: path.joined(separator: "."), value: value)
        }
        return number
    }

    private static func setting(_ path: [String], to value: Int, in yaml: String) throws -> String {
        try blockSection { try ConfigSetting.setting(at: path, to: String(value), in: yaml) }
    }

    /// Reports an inline `watchdog:` section as a dispatch-loop limits error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw DispatchLoopLimitsError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readDispatchLoopLimits() throws -> DispatchLoopLimits {
        try DispatchLoopLimits.values(in: read())
    }

    /// Sets the limits that differ between `old` and `new`, once `check` passes on the result.
    public func writeDispatchLoopLimits(
        _ new: DispatchLoopLimits,
        from old: DispatchLoopLimits,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try DispatchLoopLimits.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
