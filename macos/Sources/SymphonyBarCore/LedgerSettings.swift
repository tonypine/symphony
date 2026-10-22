import Foundation

/// Why the `ledger` settings can't be read or changed by editing one line.
public enum LedgerSettingsError: LocalizedError, Equatable {
    /// `ledger:` holds an inline value (for example `ledger: {artifact_retention_days: 7}`) instead of an indented block.
    case notABlock(String)
    /// The key holds something other than a whole number or `null`.
    case unreadable(key: String, value: String)
    /// The on/off key holds something other than `true`, `false` or `null`.
    case notOnOrOff(key: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the ledger settings by hand."
        case let .unreadable(key, value):
            return "`\(key): \(value)` in symphony.yml is not a whole number. Change it by hand."
        case let .notOnOrOff(key, value):
            return "`\(key): \(value)` in symphony.yml is not true or false. Change it by hand."
        }
    }
}

/// The ticket ledger's settings in the text of a `symphony.yml`: `ledger.artifact_retention_days`, how many days a
/// finished ticket's artifact files are kept; `ledger.artifact_max_bytes`, the largest file Symphony stores;
/// `ledger.prompt_brief_enabled`, whether agents get the summary of the ticket's history; and
/// `ledger.prompt_brief_max_tokens`, the size over which a ticket asks the Director before its agent starts (the
/// summary is still given whole).
/// Only the lines of the settings that change are rewritten, or inserted with `ledger:` when missing, so the rest of
/// the file stays as it is.
public struct LedgerSettings: Equatable {
    public var retentionDays: Int
    public var maxBytes: Int
    public var briefEnabled: Bool
    public var briefMaxTokens: Int

    /// What Symphony uses when a key is missing or null.
    public static let defaultRetentionDays = 14
    public static let defaultMaxBytes = 26_214_400
    public static let defaultBriefEnabled = true
    public static let defaultBriefMaxTokens = 50_000

    /// Bytes in one MB, the unit Settings shows the size cap in.
    public static let bytesPerMB = 1_048_576

    /// Values Settings offers: days, and the size cap in MB.
    public static let dayRange = 1...365
    public static let megabyteRange = 1...1_024

    static let retentionPath = ["ledger", "artifact_retention_days"]
    static let maxBytesPath = ["ledger", "artifact_max_bytes"]
    static let briefEnabledPath = ["ledger", "prompt_brief_enabled"]
    static let briefMaxTokensPath = ["ledger", "prompt_brief_max_tokens"]

    public init(
        retentionDays: Int = defaultRetentionDays,
        maxBytes: Int = defaultMaxBytes,
        briefEnabled: Bool = defaultBriefEnabled,
        briefMaxTokens: Int = defaultBriefMaxTokens
    ) {
        self.retentionDays = retentionDays
        self.maxBytes = maxBytes
        self.briefEnabled = briefEnabled
        self.briefMaxTokens = briefMaxTokens
    }

    /// The settings, with Symphony's default for a missing or null key.
    public static func values(in yaml: String) throws -> LedgerSettings {
        LedgerSettings(
            retentionDays: try number(retentionPath, default: defaultRetentionDays, in: yaml),
            maxBytes: try number(maxBytesPath, default: defaultMaxBytes, in: yaml),
            briefEnabled: try onOff(briefEnabledPath, default: defaultBriefEnabled, in: yaml),
            briefMaxTokens: try number(briefMaxTokensPath, default: defaultBriefMaxTokens, in: yaml)
        )
    }

    /// The same text with the settings that differ between `old` and `new` set to their `new` values. A missing key is
    /// inserted at the top of `ledger:`, so they are written last to first and read in order.
    public static func updating(_ yaml: String, from old: LedgerSettings, to new: LedgerSettings) throws -> String {
        let changes: [(path: [String], changed: Bool, value: String)] = [
            (briefMaxTokensPath, new.briefMaxTokens != old.briefMaxTokens, String(new.briefMaxTokens)),
            (briefEnabledPath, new.briefEnabled != old.briefEnabled, new.briefEnabled ? "true" : "false"),
            (maxBytesPath, new.maxBytes != old.maxBytes, String(new.maxBytes)),
            (retentionPath, new.retentionDays != old.retentionDays, String(new.retentionDays)),
        ]
        var yaml = yaml
        for change in changes where change.changed {
            yaml = try setting(change.path, to: change.value, in: yaml)
        }
        return yaml
    }

    /// `days` for a stepper: kept within `dayRange`.
    public static func steppedDays(_ days: Int) -> Int {
        min(max(days, dayRange.lowerBound), dayRange.upperBound)
    }

    /// `bytes` in whole MB for a stepper: rounded, and kept within `megabyteRange`.
    public static func megabytes(_ bytes: Int) -> Int {
        min(max(Int((Double(bytes) / Double(bytesPerMB)).rounded()), megabyteRange.lowerBound), megabyteRange.upperBound)
    }

    /// These settings with the steppers' values. A setting whose stepper didn't move keeps its exact value, so one the
    /// stepper can't show (a cap that isn't a whole number of MB, say) is never rewritten by an untouched stepper.
    public func setting(retentionDays: Int, maxMegabytes: Int) -> LedgerSettings {
        LedgerSettings(
            retentionDays: retentionDays == Self.steppedDays(self.retentionDays) ? self.retentionDays : retentionDays,
            maxBytes: maxMegabytes == Self.megabytes(maxBytes) ? maxBytes : maxMegabytes * Self.bytesPerMB,
            briefEnabled: briefEnabled,
            briefMaxTokens: briefMaxTokens
        )
    }

    private static func number(_ path: [String], default defaultValue: Int, in yaml: String) throws -> Int {
        let value = try blockSection { try ConfigSetting.value(at: path, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return defaultValue }
        guard let number = Int(value.filter { $0 != "_" }) else {
            throw LedgerSettingsError.unreadable(key: path.joined(separator: "."), value: value)
        }
        return number
    }

    private static func onOff(_ path: [String], default defaultValue: Bool, in yaml: String) throws -> Bool {
        let value = try blockSection { try ConfigSetting.value(at: path, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return defaultValue }
        switch value {
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: throw LedgerSettingsError.notOnOrOff(key: path.joined(separator: "."), value: value)
        }
    }

    private static func setting(_ path: [String], to value: String, in yaml: String) throws -> String {
        try blockSection { try ConfigSetting.setting(at: path, to: value, in: yaml) }
    }

    /// Reports an inline `ledger:` section as a ledger settings error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw LedgerSettingsError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readLedgerSettings() throws -> LedgerSettings {
        try LedgerSettings.values(in: read())
    }

    /// Sets the settings that differ between `old` and `new`, once `check` passes on the result.
    public func writeLedgerSettings(
        _ new: LedgerSettings,
        from old: LedgerSettings,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try LedgerSettings.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
