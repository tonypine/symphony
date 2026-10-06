import Foundation

/// The `symphony.yml` settings the app's Settings, Models and Repos sections read and write, as dotted key
/// paths: `agent.concurrency.max_total`, or `repositories[].route.team` for a key of every `repositories`
/// item. A key holding a free-form map, such as `agent.run_profiles`, covers everything under it.
///
/// `mix settings.ui_coverage` reads this list from this file and fails CI for a setting that is neither here
/// nor in `config/settings_ui_exempt.yml`, so a new setting ships with a control. `SettingsUIManifestTests`
/// checks that every key the line editors (`RepositoriesConfig`, `RunProfilesConfig`, `MaxConcurrentAgents`,
/// `TokenLimits`, `OperationTimeouts`, `AcceptanceGate`) write is here. Keep one string literal per line, sorted.
public enum SettingsUIManifest {
    public static let keyPaths: [String] = [
        "agent.command",
        "agent.concurrency.max_total",
        "agent.effort",
        "agent.limits.tokens_per_day",
        "agent.limits.tokens_per_issue",
        "agent.model",
        "agent.provider",
        "agent.run_profiles",
        "agent.small_model",
        "agent.timeouts.mcp_tool_ms",
        "auto_review.acceptance_gate.mode",
        "auto_review.command",
        "auto_review.effort",
        "auto_review.model",
        "pre_push_review.command",
        "pre_push_review.effort",
        "pre_push_review.model",
        "repositories[].acceptance_gate.mode",
        "repositories[].agent.effort",
        "repositories[].agent.model",
        "repositories[].agent.provider",
        "repositories[].agent.run_profiles",
        "repositories[].base_branch",
        "repositories[].default",
        "repositories[].key",
        "repositories[].route.assignee",
        "repositories[].route.labels",
        "repositories[].route.projects",
        "repositories[].route.team",
        "repositories[].workflow",
        "repositories[].workspace.fetch_before_dispatch",
        "repositories[].workspace.repo",
        "repositories[].workspace.source",
        "repositories[].workspace.strategy",
        "watchdog.pending_tool_report_after_ms",
        "workspaces.git_network_timeout_ms",
    ]
}
