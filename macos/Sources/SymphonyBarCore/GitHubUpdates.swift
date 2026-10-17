import Foundation

/// Why `github.webhooks.fallback_poll_interval_ms` or `github.webhooks.silence_alert_minutes` can't be read or
/// changed by editing one line.
public enum GitHubUpdatesError: LocalizedError, Equatable {
    /// The key holds an inline value (for example `webhooks: {enabled: true}`) instead of an indented block.
    case notABlock(String)
    /// The key holds something other than a whole number or `null`.
    case unreadable(key: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the GitHub update settings by hand."
        case let .unreadable(key, value):
            return "`\(key): \(value)` in symphony.yml is not a whole number. Change it by hand."
        }
    }
}

/// How often Symphony checks GitHub while webhook deliveries are healthy (`github.webhooks.fallback_poll_interval_ms`,
/// the safety net) and how long it waits without a delivery before warning (`github.webhooks.silence_alert_minutes`),
/// in the text of a `symphony.yml`. Only the lines that change are rewritten, or inserted when missing, so the rest
/// of the file stays as it is.
public struct GitHubUpdates: Equatable {
    /// The safety-net check's interval while deliveries are healthy, in milliseconds.
    public var fallbackPollMs: Int
    /// How many minutes without a delivery before Symphony warns.
    public var silenceAlertMinutes: Int

    /// What Symphony uses when a key is missing or null.
    public static let defaultFallbackPollMs = 300_000
    public static let defaultSilenceAlertMinutes = 10

    /// Values Settings offers, in minutes.
    public static let minuteRange = 1...120

    static let fallbackPollPath = ["github", "webhooks", "fallback_poll_interval_ms"]
    static let silenceAlertPath = ["github", "webhooks", "silence_alert_minutes"]

    public init(fallbackPollMs: Int = defaultFallbackPollMs, silenceAlertMinutes: Int = defaultSilenceAlertMinutes) {
        self.fallbackPollMs = fallbackPollMs
        self.silenceAlertMinutes = silenceAlertMinutes
    }

    /// The settings, with Symphony's default for a missing or null key.
    public static func values(in yaml: String) throws -> GitHubUpdates {
        GitHubUpdates(
            fallbackPollMs: try number(fallbackPollPath, default: defaultFallbackPollMs, in: yaml),
            silenceAlertMinutes: try number(silenceAlertPath, default: defaultSilenceAlertMinutes, in: yaml)
        )
    }

    /// The same text with the settings that differ between `old` and `new` set to their `new` values.
    public static func updating(_ yaml: String, from old: GitHubUpdates, to new: GitHubUpdates) throws -> String {
        var yaml = yaml
        if new.fallbackPollMs != old.fallbackPollMs { yaml = try setting(fallbackPollPath, to: new.fallbackPollMs, in: yaml) }
        if new.silenceAlertMinutes != old.silenceAlertMinutes {
            yaml = try setting(silenceAlertPath, to: new.silenceAlertMinutes, in: yaml)
        }
        return yaml
    }

    /// The safety-net interval in whole minutes for a stepper: rounded, and kept within `minuteRange`.
    public static func minutes(_ ms: Int) -> Int {
        stepperMinutes(Int((Double(ms) / 60_000).rounded()))
    }

    /// A number of minutes as a stepper over `minuteRange` shows it.
    public static func stepperMinutes(_ minutes: Int) -> Int {
        min(max(minutes, minuteRange.lowerBound), minuteRange.upperBound)
    }

    /// These settings with the steppers' minutes. A setting whose stepper didn't move keeps its exact value, so one
    /// outside the stepper's range, or an interval that isn't a whole number of minutes, is never rewritten by an
    /// untouched stepper.
    public func settingMinutes(fallbackPoll: Int, silenceAlert: Int) -> GitHubUpdates {
        GitHubUpdates(
            fallbackPollMs: fallbackPoll == Self.minutes(fallbackPollMs) ? fallbackPollMs : fallbackPoll * 60_000,
            silenceAlertMinutes: silenceAlert == Self.stepperMinutes(silenceAlertMinutes) ? silenceAlertMinutes : silenceAlert
        )
    }

    private static func number(_ path: [String], default defaultValue: Int, in yaml: String) throws -> Int {
        let value = try blockSection { try ConfigSetting.value(at: path, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return defaultValue }
        guard let number = Int(value.filter { $0 != "_" }) else {
            throw GitHubUpdatesError.unreadable(key: path.joined(separator: "."), value: value)
        }
        return number
    }

    private static func setting(_ path: [String], to number: Int, in yaml: String) throws -> String {
        try blockSection { try ConfigSetting.setting(at: path, to: String(number), in: yaml) }
    }

    /// Reports an inline section above a setting as a GitHub updates error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw GitHubUpdatesError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readGitHubUpdates() throws -> GitHubUpdates {
        try GitHubUpdates.values(in: read())
    }

    /// Sets the GitHub update settings that differ between `old` and `new`, once `check` passes on the result.
    public func writeGitHubUpdates(
        _ new: GitHubUpdates,
        from old: GitHubUpdates,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try GitHubUpdates.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
