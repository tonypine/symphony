import Foundation

/// Why an `issues.states.*` board state can't be read or changed by editing one line.
public enum WorkflowStatesError: LocalizedError, Equatable {
    /// The key holds an inline value (for example `states: {qa: QA}`) instead of an indented block.
    case notABlock(String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the board states by hand."
        }
    }
}

/// The machine-owned phase states in `issues.states`: the board columns Symphony creates at startup.
/// Nothing dispatches on them yet; they name the Linear workflow states the board will use.
public struct WorkflowStates: Equatable {
    public var codeReview: String
    public var qa: String
    public var planReview: String
    public var epicReview: String
    public var ciFix: String

    /// What Symphony creates and uses when a key is missing.
    public static let defaults = WorkflowStates()

    /// The keys of the phase states, in board order.
    public static let keys = ["code_review", "qa", "plan_review", "epic_review", "ci_fix"]

    /// The values YAML reads as null, which leave a phase without a state. An empty value is null too.
    static let nullValues: Set<String> = ["", "~", "null", "Null", "NULL"]

    public init(
        codeReview: String = "Code Review",
        qa: String = "QA",
        planReview: String = "Plan Review",
        epicReview: String = "Epic Review",
        ciFix: String = "CI Fix"
    ) {
        self.codeReview = codeReview
        self.qa = qa
        self.planReview = planReview
        self.epicReview = epicReview
        self.ciFix = ciFix
    }

    /// The five names, in board order, matching `keys`.
    public var values: [String] {
        [codeReview, qa, planReview, epicReview, ciFix]
    }

    /// The five names, with Symphony's default for a missing key and an empty string for one turned off.
    public static func values(in yaml: String) throws -> WorkflowStates {
        let names = try keys.enumerated().map { index, key in
            try name(key, default: defaults.values[index], in: yaml)
        }
        return WorkflowStates(codeReview: names[0], qa: names[1], planReview: names[2], epicReview: names[3], ciFix: names[4])
    }

    /// The same text with the phase states that differ between `old` and `new` set to their `new` values.
    public static func updating(_ yaml: String, from old: WorkflowStates, to new: WorkflowStates) throws -> String {
        var yaml = yaml
        for index in keys.indices where old.values[index] != new.values[index] {
            yaml = try setting(keys[index], to: new.values[index], in: yaml)
        }
        return yaml
    }

    private static func name(_ key: String, default fallback: String, in yaml: String) throws -> String {
        let value = try blockSection { try ConfigSetting.value(at: ["issues", "states", key], of: yaml) }
        guard let value else { return fallback }
        return nullValues.contains(value) ? "" : value
    }

    /// Writes a name, or `null` when it is blank, so a phase can be left without a state.
    private static func setting(_ key: String, to name: String, in yaml: String) throws -> String {
        let trimmed = name.trimmingWhitespace()
        let value = trimmed.isEmpty ? "null" : trimmed
        return try blockSection { try ConfigSetting.setting(at: ["issues", "states", key], to: value, in: yaml) }
    }

    /// Reports an inline `issues:` or `states:` as a board states error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw WorkflowStatesError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readWorkflowStates() throws -> WorkflowStates {
        try WorkflowStates.values(in: read())
    }

    /// Sets the phase states that differ between `old` and `new`, once `check` passes on the result.
    public func writeWorkflowStates(
        _ new: WorkflowStates,
        from old: WorkflowStates,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try WorkflowStates.updating($0, from: old, to: new) }, checkingWith: check)
    }

    /// Runs `check` on a copy of the file with the phase states set, without changing the file.
    public func checkWorkflowStates(
        _ new: WorkflowStates,
        from old: WorkflowStates,
        with check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await checking({ try WorkflowStates.updating($0, from: old, to: new) }, with: check)
    }
}
