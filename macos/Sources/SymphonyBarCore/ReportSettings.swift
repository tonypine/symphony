import Foundation

/// Why the `reports` settings can't be read or changed by editing one line.
public enum ReportSettingsError: LocalizedError, Equatable {
    /// `reports:` holds an inline value (for example `reports: {model: x}`) instead of an indented block.
    case notABlock(String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the report settings by hand."
        }
    }
}

/// The status report's settings in the text of a `symphony.yml`: `reports.model`, the model a report run writes with
/// (the cheapest capable model when it is missing). Only its line is rewritten, or inserted with `reports:` when
/// missing, so the rest of the file stays as it is.
public struct ReportSettings: Equatable {
    public var model: String

    /// What Symphony uses when the key is missing, null or blank.
    public static let defaultModel = "claude-haiku-5-5"

    static let modelPath = ["reports", "model"]

    public init(model: String = defaultModel) {
        self.model = model
    }

    /// The settings, with Symphony's default for a missing, null or blank key. A quoted value is read without its quotes.
    public static func values(in yaml: String) throws -> ReportSettings {
        let value = try blockSection { try ConfigSetting.value(at: modelPath, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return ReportSettings() }
        let model = unquoted(value)
        return ReportSettings(model: model.isEmpty ? defaultModel : model)
    }

    /// The same text with `reports.model` set to `new`'s model when it differs from `old`'s. A blank model writes the
    /// default, since Symphony refuses a blank one.
    public static func updating(_ yaml: String, from old: ReportSettings, to new: ReportSettings) throws -> String {
        guard new.model != old.model else { return yaml }
        let model = new.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return try blockSection {
            try ConfigSetting.setting(at: modelPath, to: StepsWriter.scalar(model.isEmpty ? defaultModel : model), in: yaml)
        }
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

    /// Sets `reports.model` when it differs between `old` and `new`, once `check` passes on the result.
    public func writeReportSettings(
        _ new: ReportSettings,
        from old: ReportSettings,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try ReportSettings.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
