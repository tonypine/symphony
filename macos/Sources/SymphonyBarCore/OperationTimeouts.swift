import Foundation

/// Why `workspaces.git_network_timeout_ms`, `agent.timeouts.mcp_tool_ms` or `watchdog.pending_tool_report_after_ms`
/// can't be read or changed by editing one line.
public enum OperationTimeoutsError: LocalizedError, Equatable {
    /// The key holds an inline value (for example `timeouts: {mcp_tool_ms: 5}`) instead of an indented block.
    case notABlock(String)
    /// The key holds something other than a whole number or `null`.
    case unreadable(key: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .notABlock(let key):
            return "`\(key):` in symphony.yml is not an indented block. Change the timeouts by hand."
        case let .unreadable(key, value):
            return "`\(key): \(value)` in symphony.yml is not a whole number of milliseconds. Change it by hand."
        }
    }
}

/// `workspaces.git_network_timeout_ms`, `agent.timeouts.mcp_tool_ms` and `watchdog.pending_tool_report_after_ms` in
/// the text of a `symphony.yml`, in milliseconds. Only the lines of the timeouts that change are rewritten, or
/// inserted when missing, so the rest of the file stays as it is.
public struct OperationTimeouts: Equatable {
    /// The wall-clock limit of each git `fetch`, `pull`, `push` or `ls-remote` Symphony runs.
    public var gitNetworkMs: Int
    /// How long one call of Symphony's own MCP tools (`linear_*`, `github_*`) may run.
    public var mcpToolMs: Int
    /// How long one of those calls runs before Symphony's state reports the run as waiting on it.
    public var pendingToolReportMs: Int

    /// What Symphony uses when a key is missing or null.
    public static let defaultGitNetworkMs = 300_000
    public static let defaultMcpToolMs = 600_000
    public static let defaultPendingToolReportMs = 60_000

    /// Values Settings offers, in minutes.
    public static let minuteRange = 1...120

    static let gitNetworkPath = ["workspaces", "git_network_timeout_ms"]
    static let mcpToolPath = ["agent", "timeouts", "mcp_tool_ms"]
    static let pendingToolReportPath = ["watchdog", "pending_tool_report_after_ms"]

    public init(
        gitNetworkMs: Int = defaultGitNetworkMs,
        mcpToolMs: Int = defaultMcpToolMs,
        pendingToolReportMs: Int = defaultPendingToolReportMs
    ) {
        self.gitNetworkMs = gitNetworkMs
        self.mcpToolMs = mcpToolMs
        self.pendingToolReportMs = pendingToolReportMs
    }

    /// The timeouts, with Symphony's default for a missing or null key.
    public static func values(in yaml: String) throws -> OperationTimeouts {
        OperationTimeouts(
            gitNetworkMs: try milliseconds(gitNetworkPath, default: defaultGitNetworkMs, in: yaml),
            mcpToolMs: try milliseconds(mcpToolPath, default: defaultMcpToolMs, in: yaml),
            pendingToolReportMs: try milliseconds(pendingToolReportPath, default: defaultPendingToolReportMs, in: yaml)
        )
    }

    /// The same text with the timeouts that differ between `old` and `new` set to their `new` values.
    public static func updating(_ yaml: String, from old: OperationTimeouts, to new: OperationTimeouts) throws -> String {
        var yaml = yaml
        if new.gitNetworkMs != old.gitNetworkMs { yaml = try setting(gitNetworkPath, to: new.gitNetworkMs, in: yaml) }
        if new.mcpToolMs != old.mcpToolMs { yaml = try setting(mcpToolPath, to: new.mcpToolMs, in: yaml) }
        if new.pendingToolReportMs != old.pendingToolReportMs {
            yaml = try setting(pendingToolReportPath, to: new.pendingToolReportMs, in: yaml)
        }
        return yaml
    }

    /// `ms` in whole minutes for a stepper: rounded, and kept within `minuteRange`.
    public static func minutes(_ ms: Int) -> Int {
        min(max(Int((Double(ms) / 60_000).rounded()), minuteRange.lowerBound), minuteRange.upperBound)
    }

    /// These timeouts with the steppers' minutes. A timeout whose minutes didn't move keeps its exact value, so
    /// one that isn't a whole number of minutes is never rewritten by an untouched stepper.
    public func settingMinutes(gitNetwork: Int, mcpTool: Int, pendingToolReport: Int) -> OperationTimeouts {
        OperationTimeouts(
            gitNetworkMs: gitNetwork == Self.minutes(gitNetworkMs) ? gitNetworkMs : gitNetwork * 60_000,
            mcpToolMs: mcpTool == Self.minutes(mcpToolMs) ? mcpToolMs : mcpTool * 60_000,
            pendingToolReportMs: pendingToolReport == Self.minutes(pendingToolReportMs)
                ? pendingToolReportMs : pendingToolReport * 60_000
        )
    }

    private static func milliseconds(_ path: [String], default defaultMs: Int, in yaml: String) throws -> Int {
        let value = try blockSection { try ConfigSetting.value(at: path, of: yaml) }
        guard let value, !TokenLimits.nullValues.contains(value) else { return defaultMs }
        guard let ms = Int(value.filter { $0 != "_" }) else {
            throw OperationTimeoutsError.unreadable(key: path.joined(separator: "."), value: value)
        }
        return ms
    }

    private static func setting(_ path: [String], to ms: Int, in yaml: String) throws -> String {
        try blockSection { try ConfigSetting.setting(at: path, to: String(ms), in: yaml) }
    }

    /// Reports an inline section above a timeout as a timeouts error.
    private static func blockSection<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch MaxConcurrentAgentsError.notABlock(let key) {
            throw OperationTimeoutsError.notABlock(key)
        }
    }
}

extension SymphonyConfigFile {
    public func readOperationTimeouts() throws -> OperationTimeouts {
        try OperationTimeouts.values(in: read())
    }

    /// Sets the timeouts that differ between `old` and `new`, once `check` passes on the result.
    public func writeOperationTimeouts(
        _ new: OperationTimeouts,
        from old: OperationTimeouts,
        checkingWith check: (String) async -> ConfigCheckResult
    ) async throws -> ConfigCheckResult {
        try await rewrite({ try OperationTimeouts.updating($0, from: old, to: new) }, checkingWith: check)
    }
}
