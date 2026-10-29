import Foundation

/// Why the `linear.webhooks` settings can't be read or changed by editing one line.
public enum LinearWebhookSettingsError: LocalizedError, Equatable {
    /// `linear:` or `webhooks:` holds an inline value (for example `webhooks: {enabled: true}`) instead of an
    /// indented block.
    case notABlock(String)
    /// `linear.webhooks.enabled` holds something other than `true`, `false` or `null`.
    case notOnOrOff(key: String, value: String)
    /// `linear.webhooks.secret` is a quoted string that doesn't close. The value is never named.
    case unreadableSecret(key: String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the Linear webhook settings by hand."
        case let .notOnOrOff(key, value):
            return "`\(key): \(value)` in symphony.yml is not true or false. Change it by hand."
        case .unreadableSecret(let key):
            return "`\(key)` in symphony.yml is not a readable string. Change it by hand."
        }
    }
}

/// Linear's workspace webhook in the text of a `symphony.yml`: `linear.webhooks.enabled`, whether Symphony accepts
/// its deliveries, and `linear.webhooks.secret`, the signing secret it checks them with: an `$ENV` reference (the
/// variable holds the value) or a literal. Only the lines of the settings that change are rewritten, or inserted with
/// `linear:` and `webhooks:` when missing, so the rest of the file stays as it is. A literal secret is never shown,
/// logged or named in an error.
public struct LinearWebhookSettings: Equatable {
    /// Where the signing secret comes from.
    public enum Secret: Equatable {
        /// No secret: `null`, empty or missing.
        case none
        /// `$NAME`: Symphony reads the value from the environment variable `NAME`.
        case environment(String)
        /// The value itself, written in `symphony.yml`.
        case literal(String)
    }

    public var enabled: Bool
    public var secret: Secret

    /// What Symphony uses when `enabled` is missing or null.
    public static let defaultEnabled = false

    /// The variable the docs name for the secret, which Settings offers when none is set.
    public static let suggestedEnvironmentName = "SYMPHONY_LINEAR_WEBHOOK_SECRET"

    static let enabledPath = ["linear", "webhooks", "enabled"]
    static let secretPath = ["linear", "webhooks", "secret"]

    public init(enabled: Bool = defaultEnabled, secret: Secret = .none) {
        self.enabled = enabled
        self.secret = secret
    }

    /// The settings, with Symphony's default for a missing or null key.
    public static func values(in yaml: String) throws -> LinearWebhookSettings {
        LinearWebhookSettings(enabled: try onOff(in: yaml), secret: try secret(in: yaml))
    }

    /// The same text with the settings that differ between `old` and `new` set to their `new` values. A missing key
    /// is inserted at the top of `webhooks:`, so they are written last to first and read in order.
    public static func updating(_ yaml: String, from old: LinearWebhookSettings, to new: LinearWebhookSettings) throws -> String {
        var yaml = yaml
        if new.secret != old.secret { yaml = try setting(secretPath, to: scalar(new.secret), in: yaml) }
        if new.enabled != old.enabled { yaml = try setting(enabledPath, to: new.enabled ? "true" : "false", in: yaml) }
        return yaml
    }

    /// Where Settings takes the secret from.
    public enum SecretSource: String, CaseIterable, Equatable {
        case environment
        case literal
    }

    /// What Settings' fields show for `secret`: its source, the variable's name and the literal. No secret shows as
    /// an empty variable name.
    public static func fields(_ secret: Secret) -> (source: SecretSource, name: String, literal: String) {
        switch secret {
        case .none: return (.environment, "", "")
        case .environment(let name): return (.environment, name, "")
        case .literal(let value): return (.literal, "", value)
        }
    }

    /// The secret Settings' fields name: the variable's name, with or without its `$`, or the literal as typed. An
    /// empty field is no secret; nil when the name is not one Symphony resolves.
    public static func secret(source: SecretSource, name: String, literal: String) -> Secret? {
        switch source {
        case .environment:
            var name = name.trimmingWhitespace()
            if name.hasPrefix("$") { name.removeFirst() }
            if name.isEmpty { return Secret.none }
            return isEnvironmentName(name) ? .environment(name) : nil
        case .literal:
            return literal.isEmpty ? Secret.none : .literal(literal)
        }
    }

    /// Why Settings refuses a variable's name.
    public static let environmentNameRule = "The variable's name takes letters, digits and _, and starts with a letter or _."

    /// True when a name can follow `$` in a reference Symphony resolves: a letter or `_`, then letters, digits or `_`.
    public static func isEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first == "_" || isASCIILetter(first) else { return false }
        return name.unicodeScalars.allSatisfy { $0 == "_" || isASCIILetter($0) || ("0"..."9").contains($0) }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    /// How `secret` is written after `secret:`.
    static func scalar(_ secret: Secret) -> String {
        switch secret {
        case .none: return "null"
        case .environment(let name): return "$" + name
        case .literal(let value): return MacAppQAPlaybook.quoted(value)
        }
    }

    private static func onOff(in yaml: String) throws -> Bool {
        let value = try blockSection { try ConfigSetting.value(at: enabledPath, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return defaultEnabled }
        switch value {
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: throw LinearWebhookSettingsError.notOnOrOff(key: enabledPath.joined(separator: "."), value: value)
        }
    }

    private static func secret(in yaml: String) throws -> Secret {
        let raw = try blockSection { try ConfigSetting.value(at: secretPath, of: yaml) }
        guard let raw, !TokenLimits.nullValues.contains(raw) else { return .none }
        let key = secretPath.joined(separator: ".")
        let text: String
        do {
            text = try MacAppQAPlaybook.scalar(raw, key: key)
        } catch {
            // The playbook's error would quote the value; this one never does.
            throw LinearWebhookSettingsError.unreadableSecret(key: key)
        }
        if text.isEmpty { return .none }
        if text.hasPrefix("$"), isEnvironmentName(String(text.dropFirst())) { return .environment(String(text.dropFirst())) }
        return .literal(text)
    }

    private static func setting(_ path: [String], to value: String, in yaml: String) throws -> String {
        try blockSection { try ConfigSetting.setting(at: path, to: value, in: yaml) }
    }

    /// Reports an inline section above a setting as a Linear webhook settings error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw LinearWebhookSettingsError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readLinearWebhookSettings() throws -> LinearWebhookSettings {
        try LinearWebhookSettings.values(in: read())
    }

    /// Sets the Linear webhook settings that differ between `old` and `new`, once `check` passes on the result.
    public func writeLinearWebhookSettings(
        _ new: LinearWebhookSettings,
        from old: LinearWebhookSettings,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try LinearWebhookSettings.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
