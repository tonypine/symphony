import Foundation

/// Why Code Review's risk rule settings can't be read or changed by editing one line.
public enum RiskRuleSettingsError: LocalizedError, Equatable {
    /// A key above them holds an inline value (for example `escalate: {labels: []}`) instead of an indented block.
    case notABlock(String)
    /// The key holds a value Symphony doesn't take.
    case unreadable(key: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the risk rules by hand."
        case .unreadable(let key, let value):
            return "`\(key): \(value)` in symphony.yml is not a value Symphony takes. Change it by hand."
        }
    }
}

/// One of Code Review's risk rules, by its `escalate.on_match` key.
public enum RiskRule: String, CaseIterable, Identifiable {
    case paths
    case diffPatterns = "diff_patterns"
    case dependencies
    case maxChangedLines = "max_changed_lines"
    case busyFiles = "busy_files"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .paths: return "Sensitive paths"
        case .diffPatterns: return "Sensitive content"
        case .dependencies: return "Dependency changes"
        case .maxChangedLines: return "Change size"
        case .busyFiles: return "Busiest files"
        }
    }

    /// One line on what the rule matches.
    public var explanation: String {
        switch self {
        case .paths: return "A change to sign-in, secrets, permissions, migrations or the build workflows."
        case .diffPatterns: return "An added line that can delete data, such as DROP TABLE or rm -rf."
        case .dependencies: return "A new dependency, or one moved to a new major version."
        case .maxChangedLines: return "More lines than the size limit outside docs and tests."
        case .busyFiles: return "Many lines of one of the files changed most often lately."
        }
    }
}

/// What a risk rule's match does: tell the reviewer, or also ask you once the reviewer approves.
public enum RiskRuleMatch: String, CaseIterable, Identifiable {
    case inform
    case ask

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inform: return "Tell the reviewer"
        case .ask: return "Ask me"
        }
    }
}

/// What the change-size rule counts.
public enum ChangeSizeCount: String, CaseIterable, Identifiable {
    case total
    case added

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .total: return "Every changed line"
        case .added: return "Added and changed lines"
        }
    }

    /// One line on what the choice counts.
    public var explanation: String {
        switch self {
        case .total: return "Added, changed and removed lines all count toward the size limit."
        case .added: return "Removed lines don't count, so a large clean-up stays under the size limit."
        }
    }
}

/// `auto_review.acceptance_gate.escalate.on_match.*` and `.size_counts`: what each of Code Review's risk rules
/// does when it matches, and what the change-size rule counts. Settings edits them for every repository.
public struct RiskRuleSettings: Equatable {
    public var onMatch: [RiskRule: RiskRuleMatch]
    public var sizeCounts: ChangeSizeCount

    public static let sizeCountsTitle = "Change size counts"

    static let escalate = ["auto_review", "acceptance_gate", "escalate"]

    /// Symphony's defaults for whatever isn't given: a rule tells the reviewer, and the size counts every changed
    /// line. `onMatch` always holds every rule.
    public init(onMatch: [RiskRule: RiskRuleMatch] = [:], sizeCounts: ChangeSizeCount = .total) {
        self.onMatch = Dictionary(uniqueKeysWithValues: RiskRule.allCases.map { ($0, onMatch[$0] ?? .inform) })
        self.sizeCounts = sizeCounts
    }

    /// What `rule`'s match does, `inform` unless set.
    public func match(for rule: RiskRule) -> RiskRuleMatch {
        onMatch[rule] ?? .inform
    }

    /// The settings in `yaml`, with Symphony's default for a missing or null key.
    public static func values(in yaml: String) throws -> RiskRuleSettings {
        var settings = RiskRuleSettings()
        for rule in RiskRule.allCases {
            settings.onMatch[rule] = try read(escalate + ["on_match", rule.rawValue], as: RiskRuleMatch.self, in: yaml) ?? .inform
        }
        settings.sizeCounts = try read(escalate + ["size_counts"], as: ChangeSizeCount.self, in: yaml) ?? .total
        return settings
    }

    /// The same text with the settings that differ between `old` and `new` set to their `new` values.
    public static func updating(_ yaml: String, from old: RiskRuleSettings, to new: RiskRuleSettings) throws -> String {
        var yaml = yaml
        for rule in RiskRule.allCases where old.match(for: rule) != new.match(for: rule) {
            yaml = try blockSection {
                try ConfigSetting.setting(at: escalate + ["on_match", rule.rawValue], to: new.match(for: rule).rawValue, in: yaml)
            }
        }
        if old.sizeCounts != new.sizeCounts {
            yaml = try blockSection { try ConfigSetting.setting(at: escalate + ["size_counts"], to: new.sizeCounts.rawValue, in: yaml) }
        }
        return yaml
    }

    private static func read<Value: RawRepresentable>(_ path: [String], as _: Value.Type, in yaml: String) throws -> Value?
    where Value.RawValue == String {
        let value = try blockSection { try ConfigSetting.value(at: path, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return nil }
        guard let parsed = Value(rawValue: value) else {
            throw RiskRuleSettingsError.unreadable(key: path[path.count - 1], value: value)
        }
        return parsed
    }

    /// Reports an inline block above a key as a risk rule settings error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw RiskRuleSettingsError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readRiskRuleSettings() throws -> RiskRuleSettings {
        try RiskRuleSettings.values(in: read())
    }

    /// Sets the risk rule settings that differ between `old` and `new`, once `check` passes on the result.
    public func writeRiskRuleSettings(
        _ new: RiskRuleSettings,
        from old: RiskRuleSettings,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try RiskRuleSettings.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
