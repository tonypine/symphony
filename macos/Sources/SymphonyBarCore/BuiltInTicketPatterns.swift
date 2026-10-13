import Foundation

/// Why `auto_review.acceptance_gate.escalate.ticket_patterns_builtin` can't be read or changed by editing one line.
public enum BuiltInTicketPatternsError: LocalizedError, Equatable {
    /// A key above it holds an inline value (for example `escalate: {labels: []}`) instead of an indented block.
    case notABlock(String)
    /// The key holds something other than `true`, `false` or `null`.
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the built-in ticket patterns by hand."
        case .unreadable(let value):
            return "`ticket_patterns_builtin: \(value)` in symphony.yml is not true or false. Change it by hand."
        }
    }
}

/// `escalate.ticket_patterns_builtin`: whether Code Review's built-in ticket patterns (a ticket asking for a human
/// or manual review, saying it must not be auto-approved, or that it needs a human) send a ticket to a person, on
/// top of the `ticket_patterns` listed in `symphony.yml`. Settings edits the global key, the Edit Repo sheet a
/// repo's override.
public enum BuiltInTicketPatterns {
    public static let toggleTitle = "Built-in ticket patterns"
    public static let pickerTitle = "Built-in ticket patterns"

    /// What Symphony uses when the key is missing.
    public static let defaultIsOn = true

    static let path = ["auto_review", "acceptance_gate", "escalate", "ticket_patterns_builtin"]

    /// Whether the built-in ticket patterns apply, with Symphony's default for a missing or null key.
    public static func isOn(in yaml: String) throws -> Bool {
        let value = try blockSection { try ConfigSetting.value(at: path, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return defaultIsOn }
        switch value {
        case "true", "True", "TRUE": return true
        case "false", "False", "FALSE": return false
        default: throw BuiltInTicketPatternsError.unreadable(value)
        }
    }

    /// The same text with the key set to `isOn`. Inserts it, and the blocks above it, when they are missing.
    public static func setting(_ isOn: Bool, in yaml: String) throws -> String {
        try blockSection { try ConfigSetting.setting(at: path, to: isOn ? "true" : "false", in: yaml) }
    }

    /// Reports an inline block above the key as a built-in ticket patterns error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw BuiltInTicketPatternsError.notABlock(key)
        }
    }
}

/// `repositories[<key>].acceptance_gate.escalate.ticket_patterns_builtin`, a repo's override of the global setting.
/// `inherit` writes no key.
public enum BuiltInTicketPatternsChoice: String, CaseIterable, Identifiable {
    case inherit
    case on
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inherit: return "Same as Settings"
        case .on: return "On"
        case .off: return "Off"
        }
    }

    /// One line on what the choice does to the repo's tickets in Code Review.
    public var explanation: String {
        switch self {
        case .inherit:
            return "Follows Built-in ticket patterns in Settings."
        case .on:
            return "A ticket asking for a human or manual review goes to a person, "
                + "as do the ticket patterns symphony.yml lists."
        case .off:
            return "Only the ticket patterns symphony.yml lists send a ticket to a person."
        }
    }

    /// The choice for the value in the file: nil is Same as Settings.
    public init(override: Bool?) {
        switch override {
        case nil: self = .inherit
        case true?: self = .on
        case false?: self = .off
        }
    }

    /// The value written to `symphony.yml`; nil for Same as Settings removes the key.
    public var override: Bool? {
        switch self {
        case .inherit: return nil
        case .on: return true
        case .off: return false
        }
    }
}

extension SymphonyConfigFile {
    public func readBuiltInTicketPatterns() throws -> Bool {
        try BuiltInTicketPatterns.isOn(in: read())
    }

    /// Sets the global key, once `check` passes on the result.
    public func writeBuiltInTicketPatterns(
        _ isOn: Bool,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try BuiltInTicketPatterns.setting(isOn, in: $0) }, checkingWith: check)
    }
}
