import Foundation

/// Why the `code_review` reviewer settings can't be read or changed by editing one line.
public enum CodeReviewSettingsError: LocalizedError, Equatable {
    /// `code_review:` holds an inline value (for example `code_review: {enabled: true}`) instead of an indented block.
    case notABlock(String)
    /// `code_review.enabled` holds something other than `true`, `false` or `null`.
    case notOnOrOff(String)
    /// `code_review.runtime` holds something other than `codex`, `claude` or `null`.
    case unknownRuntime(String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change Code Review's reviewer by hand."
        case .notOnOrOff(let value):
            return "`code_review.enabled: \(value)` in symphony.yml is not true or false. Change it by hand."
        case .unknownRuntime(let value):
            return "`code_review.runtime: \(value)` in symphony.yml is not codex or claude. Change it by hand."
        }
    }
}

/// The agent runtime Code Review's reviewer runs on: `code_review.runtime`.
public enum CodeReviewRuntime: String, CaseIterable, Identifiable {
    case codex
    case claude

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

/// Code Review's reviewer in the text of a `symphony.yml`: `code_review.enabled`, whether the read-only agent that
/// judges each pull request in Code Review runs at all (with it off, Code Review tickets wait and nothing reviews
/// the PR), and `code_review.runtime`, the runtime it runs on. `code_review.command`, `.model` and `.effort` are the
/// Models section's Code review row. Only the lines of the settings that change are rewritten, or inserted with
/// `code_review:` when missing, so the rest of the file stays as it is.
public struct CodeReviewSettings: Equatable {
    public var enabled: Bool
    /// nil when the key is missing or null; Symphony then requires it before the reviewer can be turned on.
    public var runtime: CodeReviewRuntime?

    /// What Symphony uses when a key is missing or null.
    public static let defaultEnabled = false

    static let enabledPath = ["code_review", "enabled"]
    static let runtimePath = ["code_review", "runtime"]

    public init(enabled: Bool = defaultEnabled, runtime: CodeReviewRuntime? = nil) {
        self.enabled = enabled
        self.runtime = runtime
    }

    /// The settings, with Symphony's default for a missing or null key.
    public static func values(in yaml: String) throws -> CodeReviewSettings {
        CodeReviewSettings(enabled: try enabled(in: yaml), runtime: try runtime(in: yaml))
    }

    /// The same text with the settings that differ between `old` and `new` set to their `new` values. A missing key is
    /// inserted at the top of `code_review:`, so they are written last to first and read in order.
    public static func updating(_ yaml: String, from old: CodeReviewSettings, to new: CodeReviewSettings) throws -> String {
        var yaml = yaml
        if new.runtime != old.runtime {
            yaml = try setting(runtimePath, to: new.runtime?.rawValue ?? "null", in: yaml)
        }
        if new.enabled != old.enabled {
            yaml = try setting(enabledPath, to: new.enabled ? "true" : "false", in: yaml)
        }
        return yaml
    }

    private static func enabled(in yaml: String) throws -> Bool {
        let value = try blockSection { try ConfigSetting.value(at: enabledPath, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return defaultEnabled }
        switch value {
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: throw CodeReviewSettingsError.notOnOrOff(value)
        }
    }

    private static func runtime(in yaml: String) throws -> CodeReviewRuntime? {
        let value = try blockSection { try ConfigSetting.value(at: runtimePath, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return nil }
        guard let runtime = CodeReviewRuntime(rawValue: unquoted(value)) else {
            throw CodeReviewSettingsError.unknownRuntime(value)
        }
        return runtime
    }

    /// `value` without the single or double quotes around it, if any.
    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func setting(_ path: [String], to value: String, in yaml: String) throws -> String {
        try blockSection { try ConfigSetting.setting(at: path, to: value, in: yaml) }
    }

    /// Reports an inline `code_review:` section as a Code Review settings error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw CodeReviewSettingsError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readCodeReviewSettings() throws -> CodeReviewSettings {
        try CodeReviewSettings.values(in: read())
    }

    /// Sets the settings that differ between `old` and `new`, once `check` passes on the result.
    public func writeCodeReviewSettings(
        _ new: CodeReviewSettings,
        from old: CodeReviewSettings,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try CodeReviewSettings.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
