# Symphony Service Reference

Status: Reference v1 for the current Elixir/OTP service

Purpose: Document the behavior, configuration, and operational boundaries of the current Symphony
service.

## Normative Language

The key words `MUST`, `MUST NOT`, `REQUIRED`, `SHOULD`, `SHOULD NOT`, `RECOMMENDED`, `MAY`, and
`OPTIONAL` in this document are to be interpreted as described in RFC 2119.

`Implementation-defined` is retained from the original specification language. In this repository,
it records behavior selected by the current Symphony service rather than inviting separate runtime
implementations.

## 1. Problem Statement

Symphony is a long-running automation service that continuously reads work from an issue tracker
(Linear in this specification version), accepts explicit operator requests for existing pull
requests, creates an isolated workspace for each run, and runs a coding agent session inside the
workspace.

The service solves four operational problems:

- It turns issue execution into a repeatable service workflow instead of manual scripts.
- It isolates agent execution in per-issue workspaces so agent commands run only inside per-issue
  workspace directories.
- It keeps operator-owned runtime settings in `symphony.yml` and repo-owned agent policy/prompt in
  each repo's `WORKFLOW.md`.
- It provides enough observability to operate and debug multiple concurrent agent runs.

This reference documents Symphony's trust and safety posture explicitly. The current service targets
operator-controlled, trusted environments and relies on the configured coding agent plus host or
container controls for the final approval and sandbox boundary.

Important boundary:

- Symphony is a scheduler/runner and tracker reader.
- Ticket writes (state transitions, comments, PR links) are typically performed by the coding agent
  using tools available in the workflow/runtime environment.
- A successful run can end at a workflow-defined handoff state (for example `Human Review`), not
  necessarily `Done`.

## 2. Goals and Non-Goals

### 2.1 Goals

- Poll the issue tracker on a fixed cadence and dispatch work with bounded concurrency.
- Accept explicit PR dispatch requests without going through tracker candidate polling.
- Maintain a single authoritative orchestrator state for dispatch, retries, and reconciliation.
- Create deterministic per-issue workspaces and preserve them across runs.
- Stop active runs when issue state changes make them ineligible.
- Recover from transient failures with exponential backoff.
- Load runtime behavior from `symphony.yml` plus repo-owned `WORKFLOW.md` contracts.
- Expose operator-visible observability (at minimum structured logs).
- Support tracker/filesystem-driven restart recovery without requiring a persistent database; exact
  in-memory scheduler state is not restored.

### 2.2 Non-Goals

- Rich web UI or multi-tenant control plane.
- Prescribing a specific dashboard or terminal UI implementation.
- General-purpose workflow engine or distributed job scheduler.
- Built-in business logic for how to edit tickets, PRs, or comments. (That logic lives in the
  workflow prompt and agent tooling.)
- Mandating strong sandbox controls beyond what the coding agent and host OS provide.
- Mandating a single default approval, sandbox, or operator-confirmation posture for all
  implementations.

## 3. System Overview

### 3.1 Main Components

1. `Workflow Loader`
   - Reads operator config from `symphony.yml`.
   - Reads repo-local `WORKFLOW.md` files.
   - Parses repo workflow YAML front matter and prompt body.
   - Returns `{config, prompt_template}` for each repo workflow.

2. `Config Layer`
   - Exposes typed getters for effective runtime config values.
   - Parses and validates `symphony.yml`.
   - Merges operator config with the selected repo workflow front matter for repo-scoped runtime
     settings.
   - Applies defaults and environment variable indirection.
   - Performs validation used by the orchestrator before dispatch.

3. `Issue Tracker Client`
   - Fetches candidate issues in active states.
   - Fetches current states for specific issue IDs (reconciliation).
   - Fetches terminal-state issues during startup cleanup.
   - Normalizes tracker payloads into a stable issue model.

4. `Orchestrator`
   - Owns the poll tick.
   - Owns the in-memory runtime state.
   - Decides which issues to dispatch, retry, stop, or release.
   - Dispatches explicit PR runs from PR metadata and bypasses tracker polling for those runs.
   - Tracks session metrics and retry queue state.

5. `Workspace Manager`
   - Maps issue identifiers to workspace paths.
   - Ensures per-issue workspace directories exist.
   - For PR runs using worktrees, creates the workspace from the PR head branch/ref.
   - Runs workspace lifecycle hooks.
   - Cleans workspaces for terminal issues.

6. `Agent Runner`
   - Creates workspace.
   - Builds prompt from issue + workflow template.
   - Launches the configured coding-agent adapter.
   - Streams agent updates back to the orchestrator.

7. `Status Surface` (OPTIONAL)
   - Presents human-readable runtime status (for example terminal output, dashboard, or other
     operator-facing view).

8. `Logging`
   - Emits structured runtime logs to one or more configured sinks.

### 3.2 Abstraction Levels

Symphony is easiest to port when kept in these layers:

1. `Policy Layer` (repo-defined)
   - `WORKFLOW.md` prompt body.
   - Team-specific rules for ticket handling, validation, and handoff.

2. `Configuration Layer` (typed getters)
   - Parses `symphony.yml` into typed operator/runtime settings.
   - Parses repo workflow front matter into repo-local settings.
   - Handles defaults, environment tokens, and path normalization.

3. `Coordination Layer` (orchestrator)
   - Polling loop, issue eligibility, concurrency, retries, reconciliation.

4. `Execution Layer` (workspace + agent subprocess)
   - Filesystem lifecycle, workspace preparation, coding-agent protocol.

5. `Integration Layer` (Linear adapter)
   - API calls and normalization for tracker data.

6. `Observability Layer` (logs + OPTIONAL status surface)
   - Operator visibility into orchestrator and agent behavior.

### 3.3 External Dependencies

- Issue tracker API (Linear for `issues.provider: linear` in this specification version).
- Local filesystem for workspaces and logs.
- OPTIONAL workspace population tooling (for example Git CLI, if used).
- Coding-agent executable that supports the configured `agent.runtime` (`codex` app-server or
  `claude` CLI adapter in the Elixir implementation).
- Host environment authentication for the issue tracker and coding agent.

## 4. Core Domain Model

### 4.1 Entities

#### 4.1.1 Issue

Normalized issue record used by orchestration, prompt rendering, and observability output.

Fields:

- `id` (string)
  - Stable tracker-internal ID.
- `identifier` (string)
  - Human-readable ticket key (example: `ABC-123`).
- `title` (string)
- `description` (string or null)
- `priority` (integer or null)
  - Lower numbers are higher priority in dispatch sorting.
- `state` (string)
  - Current tracker state name.
- `team` (object or null)
  - Normalized tracker team metadata when available.
- `project` (object or null)
  - Normalized tracker project metadata when available.
- `branch_name` (string or null)
  - Tracker-provided branch metadata if available.
- `url` (string or null)
- `pull_request_url` (string or null)
- `pr_urls` (list of strings)
- `assignee_id` (string or null)
- `repo_key` (string or null)
  - Matched Symphony repo route name. Conflict rows use `null`.
- `conflict_repo_keys` (list of strings)
  - Repo route names that matched the same issue when routing was ambiguous.
- `labels` (list of strings)
  - Normalized to lowercase.
- `blocked_by` (list of blocker refs)
  - Each blocker ref contains:
    - `id` (string or null)
    - `identifier` (string or null)
    - `state` (string or null)
- `sub_issues` (list of sub-issue refs)
  - Direct children of the issue, each with `id`, `identifier`, and `state` (string or null).
- `created_at` (timestamp or null)
- `updated_at` (timestamp or null)
- `comments` (list)
  - Recent tracker comments when issue enrichment is enabled.
- `linked_issues` (list)
  - Normalized linked issue refs when issue enrichment is enabled.
- `assigned_to_worker` (boolean)
  - Implementation field used by quality/dispatch helpers.

#### 4.1.2 Workflow Definition

Parsed `WORKFLOW.md` payload:

- `config` (map)
  - YAML front matter root object.
- `prompt_template` (string)
  - Markdown body after front matter, trimmed.

#### 4.1.3 Service Config (Typed View)

Typed runtime values derived from `WorkflowDefinition.config` plus environment resolution.

Examples:

- poll interval
- workspace root
- active and terminal issue states
- concurrency limits
- optional per-issue and per-day token budget limits
- coding-agent executable/args/timeouts
- running-agent no-progress watchdog timing
- workspace hooks

#### 4.1.4 Workspace

Filesystem workspace assigned to one issue identifier.

Fields (logical):

- `path` (absolute workspace path)
- `workspace_key` (sanitized issue identifier)
- `created_now` (boolean, used to gate `after_create` hook)

#### 4.1.5 Run Attempt

One execution attempt for one issue.

Fields (logical):

- `issue_id`
- `repo_key`
- `issue_identifier`
- `attempt` (integer or null, `null` for first run, `>=1` for retries/continuation)
- `workspace_path`
- `started_at`
- `status`
- `error` (OPTIONAL)

#### 4.1.6 Live Session (Agent Session Metadata)

State tracked while a coding-agent subprocess is running.

Fields:

- `session_id` (string, `<thread_id>-<turn_id>`)
- `repo_key` (string)
- `thread_id` (string)
- `turn_id` (string)
- `codex_app_server_pid` (string or null)
- `last_codex_event` (string/enum or null)
- `last_codex_timestamp` (timestamp or null)
- `last_event_at` (timestamp or null)
  - Updated for every transcript event and initialized when runtime dispatch metadata is received.
  - Used by no-progress watchdog detection.
- `last_codex_message` (summarized payload)
- `input_tokens` (integer, legacy total input bucket)
- `uncached_input_tokens` (integer)
- `cached_input_tokens` (integer)
- `cache_creation_input_tokens` (integer)
- `output_tokens` (integer)
- `total_tokens` (integer)
- `last_reported_uncached_input_tokens` (integer)
- `last_reported_cached_input_tokens` (integer)
- `last_reported_cache_creation_input_tokens` (integer)
- `last_reported_output_tokens` (integer)
- `last_reported_total_tokens` (integer)
- `codex_*_tokens` compatibility aliases for older callers
- `turn_count` (integer)
  - Number of coding-agent turns started within the current worker lifetime.

#### 4.1.7 Retry Entry

Scheduled retry state for an issue.

Fields:

- `issue_id`
- `repo_key`
- `identifier` (best-effort human ID for status surfaces/logs)
- `attempt` (integer, 1-based for retry queue)
- `due_at_ms` (monotonic clock timestamp)
- `due_at` (wall-clock timestamp for durable persistence and restart hydration)
- `timer_handle` (runtime-specific timer reference)
- `error` (string or null)
- `worker_host` (string or null)
- `workspace_path` (string or null)
- `reason` (string/enum or null)
- `elapsed_ms` (integer or null)

#### 4.1.8 Orchestrator Runtime State

Single authoritative in-memory state owned by the orchestrator.

Fields:

- `poll_interval_ms` (current effective poll interval)
- `repo_key` (primary repo route name for default/fallback state)
- `max_concurrent_agents` (current effective global concurrency limit)
- `running` (map `issue_id -> running entry`)
- `claimed` (set of issue IDs reserved/running/retrying)
- `retry_attempts` (map `issue_id -> RetryEntry`)
- `completed` (set of issue IDs; bookkeeping only, not dispatch gating)
- `conflicts` (map `issue_id -> conflict issue`)
- `repo_poll_cache` (map `repo_key -> last candidate issues / cache status`)
- `repo_poll_due_at_ms` (map `repo_key -> next monotonic poll due time`)
- `codex_totals` (aggregate tokens + runtime seconds)
- `codex_rate_limits` (latest rate-limit snapshot from agent events)
- `budget_day_started_on` (UTC date used for daily token budget accounting)
- `budget_daily_used` (tokens counted toward the current UTC day budget)
- `budget_exhausted` (set of issue IDs stopped by per-issue budget enforcement)

#### 4.1.9 Durable Run Store

Implementations MAY persist orchestrator records outside the live GenServer state. When present,
the durable store SHOULD record:

- `repo_key` on partitioned records so colliding issue/run identifiers in different repos do not
  overwrite each other.
- per-run status (`running`, `success`, `failure`, `timeout`, or implementation-defined stopped
  states)
- issue ID, identifier, title, tracker state, attempt number, start/end time, error
- workspace path, worker host, session ID, transcript path when available
- per-run token totals and runtime seconds
- retry queue rows with issue ID, attempt, due time, error, reason/elapsed metadata, worker host,
  and workspace path
- aggregate token/runtime totals
- budget-exhausted run status for issues stopped without retry by token budget enforcement

Elixir implementation note: partitioned run-store writes require an explicit `repo_key`. Read APIs
are repo-scoped by default, with selected aggregate helpers for cross-repo accounting.

Live scheduler state still owns dispatch decisions. Durable records are used for restart recovery
and observability, not as a second concurrent scheduler.

### 4.2 Stable Identifiers and Normalization Rules

- `Issue ID`
  - Use for tracker lookups and internal map keys.
- `Issue Identifier`
  - Use for human-readable logs and workspace naming.
- `Workspace Key`
  - Derive from `issue.identifier` by replacing any character not in `[A-Za-z0-9._-]` with `_`.
  - Use the sanitized value for the issue workspace directory name.
- `Repo Workspace Key`
  - Derive from `repo_key` with the same sanitization.
  - The Elixir implementation nests issue workspaces under `workspaces.root/<repo_key>/<issue_key>`.
- `Normalized Issue State`
  - Compare states after `lowercase`.
- `Session ID`
  - Compose from coding-agent `thread_id` and `turn_id` as `<thread_id>-<turn_id>`.

## 5. Configuration and Workflow Specification

The current Elixir implementation splits service configuration across two files:

- `symphony.yml` is the operator config. It is plain YAML and owns issue-source settings, polling,
  global workspace root/lifecycle settings, per-repo workspace population settings, agent
  command/runtime settings, dashboard settings, pull-request pollers, notification settings, gates,
  and the supervised `repositories:` list.
- `WORKFLOW.md` is repo-local policy. It is Markdown with optional YAML front matter and owns the
  issue prompt body plus optional mode-specific prompt branches in repo-local front matter.

### 5.1 File Discovery and Path Resolution

Operator config path precedence:

1. Explicit application/runtime setting (set by CLI `--config`).
2. Default: `symphony.yml` in the current process working directory.

Repo workflow path precedence:

1. The CLI does not accept a workflow path. The orchestrator resolves repo workflows from
   `symphony.yml` once it loads.
2. After `symphony.yml` loads, each repo workflow path is resolved from its `repositories:` entry.

Loader behavior:

- If `symphony.yml` cannot be read, return `missing_symphony_file`.
- If a repo workflow cannot be read, return `missing_workflow_file`.
- `repositories[].workflow` defaults to `WORKFLOW.md`. Absolute workflow paths are used directly.
  Relative workflow paths are resolved relative to the directory containing `symphony.yml`.
- `repositories[].workflow_source` selects what is read at that path. With `ref` (the default) and
  a workflow path inside a git checkout, the workflow is the file committed at that path on
  `origin/<base_branch>` (`origin/HEAD`, `origin/main`, then `origin/master` when no base branch
  is set), not the checkout's working tree. With `local`, or a path outside any git checkout, the
  file is read from disk. With `ref`, the file is also read from disk, with a warning, until the
  ref has been read once (for example a checkout with no `origin` remote or no resolvable base
  branch ref).
- The application selects a primary repo as the one marked `default: true`, otherwise the first
  repo in `repositories:`.

Runtime selection:

- `Config.settings()` and no-repo fallback behavior use the primary repo.
- A routed issue MUST use its matched `repo_key` to select the repo workflow for prompt rendering
  and repo-local settings such as `hooks` and `verification`.
- Non-primary repo workflows are supervised and reloadable independently.

### 5.2 `symphony.yml` File Format

`symphony.yml` is plain YAML and MUST decode to a map/object. Empty files decode to an empty map,
but startup validation will fail unless required fields such as `repositories:` are supplied.

Top-level keys accepted by the Elixir implementation:

- `issues`
- `repositories`
- `workspaces`
- `workers`
- `github`
- `agent`
- `pre_push_review`
- `auto_review`
- `pull_requests`
- `verification`
- `dashboard`
- `issue_gate`
- `watchdog`
- `dependency_audit`
- `notifications`

Unknown top-level keys in `symphony.yml` are rejected. Pre-release aliases such as `tracker`,
`repos`, `workspace`, `pr_review`, `ci`, `quality_gate`, `review_agent`, `dependencies`,
`observability`, and `server` are also rejected with migration guidance.

### 5.3 Repo `WORKFLOW.md` File Format

`WORKFLOW.md` is a Markdown file with OPTIONAL YAML front matter.

Parsing rules:

- If file starts with `---`, parse lines until the next `---` as YAML front matter.
- Remaining lines become the prompt body.
- If front matter is absent, treat the entire file as prompt body and use an empty config map.
- YAML front matter MUST decode to a map/object; non-map YAML is an error.
- Prompt body is trimmed before use.

Returned workflow object:

- `config`: normalized repo-local front matter map.
- `prompt_template`: trimmed Markdown body used for issue runs.

Allowed repo-local front matter keys:

- `hooks`
- `prompts`
- `verification`
- `validation`

Unknown repo workflow keys are rejected with an error that directs the operator to move
operator-owned configuration to `symphony.yml`.

### 5.4 Config Schema

Unless explicitly called out as repo-local, fields in this section live in `symphony.yml` and become
part of the merged runtime config. Repo-local front matter contributes `hooks` and `verification`
values to the runtime settings for that repo. Nested repo-local maps are merged over the operator
config so repos can override only their dev-server command while inheriting process-wide
verification defaults such as port allocation.

#### 5.4.1 `repositories` (list)

Each entry under `repositories:` declares a repository supervised by this Symphony process. At least
one entry is required.

Fields:

- `key` (string)
  - REQUIRED.
  - Unique repo route name.
  - Surfaced as `repo_key` in run-store records, dashboard/API payloads, transcript URLs, and
    workspace paths.
- `workflow` (path string)
  - Default: `WORKFLOW.md`.
  - Resolved relative to the directory containing `symphony.yml`, unless absolute.
- `workflow_source` (string)
  - Default: `ref`. Allowed: `ref`, `local`.
  - `ref` reads the committed workflow from the fetched remote base branch; `local` reads the
    file from disk (workflow development override). See Section 5.1.
- `workspace` (object)
  - OPTIONAL per-repo workspace population settings.
  - `strategy` MAY be `clone` or `worktree`.
  - `repo` is REQUIRED when the effective strategy is `worktree`; it points at that repo's primary
    clone used for `git worktree add`.
  - `fetch_before_dispatch` controls whether the primary clone fetches `origin` before worktree
- `route` (object)
  - OPTIONAL Linear selectors for this repo route.
  - `team`: Linear team key or team ID.
  - `projects`: Linear project names, slugs, or IDs.
  - `labels`: Linear label names. Per-repo route labels use AND semantics.
  - `assignee`: Linear user ID, email/name value supported by the implementation, or `me`.
- `default` (boolean)
  - Default: `false`.
  - At most one repo can be default.
  - The default repo acts as an explicit catch-all for otherwise unscoped routing and is also the
    primary repo when computing runtime settings.

Validation:

- Repo names MUST be unique, including after workspace path sanitization.
- `repositories:` MUST contain at least one entry.
- At most one repo may set `default: true`.
- With multiple repos, unscoped non-default repos are rejected.
- Identical match rules across repos are rejected.
- Ambiguous team catch-all routing is rejected unless the catch-all route is explicitly marked
  `default: true`.
- More than one default repo for the same team is rejected.
- With multiple repos, a global `workspaces.strategy: worktree` is invalid unless every repo
  provides an explicit `repositories[].workspace.strategy` override.

#### 5.4.2 `issues` (object)

Fields:

- `provider` (string)
  - REQUIRED for dispatch.
  - Current supported values: `linear`, `memory`
- `poll_interval_ms` (integer)
  - Default: `30000`
  - Changes SHOULD be re-applied at runtime and affect future tick scheduling without restart.
- `linear.endpoint` (string)
  - Default for `provider == "linear"`: `https://api.linear.app/graphql`
- `linear.api_key` (string)
  - MAY be a literal token or `$VAR_NAME`.
  - Canonical environment variable for `provider == "linear"`: `LINEAR_API_KEY`.
  - If `$VAR_NAME` resolves to an empty string, treat the key as missing.
- `linear.scope.project_slug` (string)
  - OPTIONAL when `provider == "linear"`.
- `linear.scope.team` (string)
  - OPTIONAL Linear team key or team ID.
- `linear.scope.labels` (list of strings)
  - OPTIONAL Linear label names. Candidate issue polling treats multiple labels
    with OR semantics.
- `linear.assignee` (string)
  - OPTIONAL Linear user ID, user match value, or `me` to resolve the current API viewer.
- `states.active` (list of strings)
  - Default: `Todo`, `In Progress`
- `states.terminal` (list of strings)
  - Default: `Closed`, `Cancelled`, `Canceled`, `Duplicate`, `Done`

For Linear, at least one of `linear.scope.project_slug`, `linear.scope.team`, non-empty
`linear.scope.labels`, or repo-level route selectors is REQUIRED for dispatch.

Elixir implementation note: when `repositories` is configured, Linear candidate polling is performed per
repo with one server-side issue filter per repo. The service does not widen this into a team-union
query. Duplicate issue IDs across repo result sets are classified as conflicts and excluded from
dispatch. Repo-level route selectors are optional; a single unscoped repo, or an explicit default
repo, can rely on the issue-level Linear scope. Repo polls are staggered across the configured
`issues.poll_interval_ms`, so the scheduler ticks roughly every `interval_ms / repo_count` while
each healthy repo is still polled once per full interval. Dispatch
stays empty until every repo cache has warmed once; after three consecutive cold failures for a repo,
that repo is treated as warmed with an empty result so healthy repos can keep dispatching.

#### 5.4.3 `workspaces` (object)

Fields:

- `root` (path string or `$VAR`)
  - Default: `<system-temp>/symphony_workspaces`
  - `~` is expanded.
  - Relative paths are expanded according to the host runtime's path rules; in the Elixir
    implementation this is relative to the current process working directory.
  - Workspace containment checks normalize paths to absolute paths before use.
  - For SSH workers, `root` SHOULD be an absolute path on the remote host; orchestrator-side remote
    path validation MUST reject relative and `~` roots because their expansion would occur on a
    different host.
- `strategy`, `repo`, `fetch_before_dispatch`
  - Defaults for `repositories[].workspace`.
  - Multi-repo configs SHOULD set worktree population under each repo instead of globally.
  - `strategy` defaults to `clone`; `fetch_before_dispatch` defaults to `true`.
- `cleanup` (object)
  - Optional workspace lifecycle guardrails.
  - `enabled` defaults to `true`.
  - `max_age_days` defaults to `14`; local workspaces older than this MAY be reclaimed even when
    their associated issue is not terminal, except for currently running workspaces.
  - `interval_ms` defaults to `3600000` and controls how often the running service scans for
    stale workspaces.
  - `min_free_bytes` is unset by default. When set to a positive integer, new dispatch SHOULD pause
    while `workspaces.root` free space is below that threshold or cannot be checked.
  - `orphan_action` defaults to `log`; supported values are `log`, `delete`, and `trash`.
  - `trash_dir` defaults to `.trash` and is interpreted under `workspaces.root`.
- `attachments.allowed_hosts` (list of hostnames)
  - Default: `["github.com"]`.
  - Used by scoped Linear attachment URL tools to allow exact HTTP(S) attachment hosts.
  - Hosts are trimmed, lowercased, deduplicated, and reset to the default when the normalized list is
    empty.
- `attachments.public_upload_extensions` (list of file extensions)
  - Default: `[".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".pdf"]`.
  - Used by scoped Linear file-upload tools when an explicit public upload is requested.
  - Extensions are trimmed, lowercased, normalized to include a leading `.`, deduplicated, and
    rejected if they contain path separators or control characters.
  - Elixir evidence: `lib/symphony_elixir/config/schema.ex` and
    `test/symphony_elixir/workspace_and_config_test.exs`.

#### 5.4.4 `agent.permissions.filesystem.allow_read_paths` (list)

Fields:

- `allow_read_paths` (list of strings)
  - Default: `[]`.
  - Advanced escape hatch for exact sandbox path entries that should be subtracted from the shared
    default read-deny list when the implementation renders agent sandbox settings.
  - Empty, blank, duplicate, and non-string entries are normalized away by the Elixir implementation.
  - This MUST NOT override the Codex runtime auth/config read denies for `~/.codex/auth.json`,
    `~/.codex/config.toml`, and `~/.codex/AGENTS.md`.
  - Elixir evidence: `lib/symphony_elixir/config/schema.ex`,
    `lib/symphony_elixir/agent_sandbox_config.ex`, and
    `test/symphony_elixir/agent_sandbox_config_test.exs`.

#### 5.4.5 `verification` (object)

Opt-in orchestration for UI verification runs that need a per-issue dev-server port.

Fields:

- `enabled` (boolean)
  - Default: `false`.
  - When false or omitted, no verification port allocation or dev-server supervision is active.
- `port_allocation.range` (two-integer list)
  - Default: `[4000, 4099]`.
  - The implementation allocates the first free port in the inclusive range for each dispatched
    issue.
  - The range is global to the Symphony process across all worker hosts. Operators using SSH worker
    pools should size the range for total verification-enabled concurrency, not per-host
    concurrency.
- `dev_server.start_cmd` (string, OPTIONAL)
  - Long-lived shell command run in the issue workspace after `hooks.before_run` and before the
    first agent turn.
  - The command receives `SYMPHONY_VERIFICATION_PORT` in its environment.
  - The implementation MUST NOT auto-set `PORT`; operators explicitly wire the Symphony port into
    their tool, for example `PORT=$SYMPHONY_VERIFICATION_PORT pnpm dev` or
    `pnpm dev --port $SYMPHONY_VERIFICATION_PORT`.
  - The supervised process-group launcher requires `python3` or `python` so the child command can
    be started via `setsid()`; if no Python executable is available, the run fails with
    `verification_failed` before the first agent turn.
- `dev_server.health_check_url` (string, REQUIRED when `start_cmd` is set)
  - Supports `$SYMPHONY_VERIFICATION_PORT` and `${SYMPHONY_VERIFICATION_PORT}` substitution.
  - The dev server is considered healthy only on HTTP `200`.
- `dev_server.health_timeout_ms` (integer)
  - Default: `30000`.
- `dev_server.stop_signal` (string)
  - Default: `TERM`.
- `dev_server.stop_timeout_ms` (integer)
  - Default: `10000`.

Allocation records are durable run-store data so restart reconciliation can preserve ports while a
previously started dev-server process is still alive and reclaim them once that process is verified
gone.

#### 5.4.6 `pull_requests` (object)

Fields:

- `enabled` (boolean)
  - Default: `false`.
  - `false` preserves tracker-state-driven review behavior.
  - `true` starts a PR review poller alongside the orchestrator.
- `poll_interval_ms` (integer)
  - Default: falls back to `issues.poll_interval_ms`.
  - Shared by PR review polling and CI polling when checks are enabled.
- `review_comments.rework_delay_minutes` (integer)
  - Polling-mode default: `10`.
  - Applies only in `polling` mode before moving an issue back to an active state for requested changes.
- `review_comments.stale_after_days` (integer)
  - Polling-mode default: `7`.
  - Applies only in `polling` mode before reclaiming idle tracked PR workspaces.
- `review_comments.ignored_reviewers` (list of strings)
  - Polling-mode default: `[]`.
  - Extra GitHub accounts whose comments are skipped entirely — they trigger neither
    PR review rework dispatch nor an auto-reply. Use it to silence bots that post
    automated, non-actionable status (e.g. `github-actions[bot]`, `jp-launch-control[bot]`).
    Do not list review bots such as `copilot-pull-request-reviewer[bot]`, whose comments
    are actionable reviews.
  - The PR author returned by `gh pr view` and the auto-detected current `gh` user (when
    `gh api user` succeeds) are Symphony's own account, which on a solo setup is also the
    human reviewer. Their comments count as reviewer feedback unless they are blank or
    Symphony posted them. Every PR comment and reply Symphony posts ends with the hidden
    marker `<!-- symphony:agent -->`; comments opening with `Symphony AI` or `Automated note
    from Symphony AI` (replies from before the marker) are also treated as Symphony's.
    Do not list your own account here, or your review comments stop triggering rework.
- `review_comments.reply_after_addressing` (boolean)
  - Polling-mode default: `false`.
  - When enabled, the rework agent may mark clearly non-actionable bot comments (author
    ending in `[bot]`) as skip by writing their ids to `.symphony-skip-comments.json` at
    the workspace root; the poller suppresses the auto-reply for those ids (bot authors
    only) and removes the file. The file is git-excluded so it is never committed.
- `review_comments.request_review_after_push` (boolean)
  - Polling-mode default: `false`.
- `checks.enabled` (boolean)
  - Default: `false`.
- `checks.log_excerpt_lines` (integer)
  - Default: `200`.
- `checks.retry_failed_once` (boolean)
  - Default: `true`.
- `checks.max_fix_attempts` (integer)
  - Default: `3`.
- `checks.escalate_to_state` (string)
  - Default: `In Review`.
- `checks.landing_wait_timeout_ms` (integer)
  - Default: `1800000` (30 minutes).
  - How long a `Merging` issue whose landing run ended on pending checks stays held before the
    landing agent is dispatched again anyway.

Review-comment options are ignored when `enabled` is not `true`. CI failure dispatch is driven only
by failed status checks and ignores comment authorship; the ignored reviewer set above does not
affect CI escalation.

#### 5.4.7 `github` (object)

Fields:

- `enterprise_hosts` (list of strings)
  - Default: `[]`.
  - Exact host allowlist for GitHub Enterprise PR and repository URLs.
  - `github.com` and `www.github.com` are always accepted.
- `open_pull_requests_as_draft` (boolean)
  - Default: `true`.
  - Draft state applied when the PR-creation tool is called without an explicit
    draft argument. An explicit argument from the agent always takes precedence.
  - Keeps PR review-state independent of whether the first-turn prompt carried a
    draft directive (which a compacted bootstrap prompt would not).

#### 5.4.8 `hooks` (object)

Fields:

- `after_create` (multiline shell script string, OPTIONAL)
  - Runs only when a workspace directory is newly created.
  - Failure aborts workspace creation.
- `before_run` (multiline shell script string, OPTIONAL)
  - Runs before each agent attempt after workspace preparation and before launching the coding
    agent.
  - Failure aborts the current attempt.
- `after_run` (multiline shell script string, OPTIONAL)
  - Runs after each agent attempt (success, failure, timeout, or cancellation) once the workspace
    exists.
  - Failure is logged but ignored.
- `before_remove` (multiline shell script string, OPTIONAL)
  - Runs before workspace deletion if the directory exists.
  - Failure is logged but ignored; cleanup still proceeds.
- `timeout_ms` (integer, OPTIONAL)
  - Default: `60000`
  - Applies to all workspace hooks.
  - Invalid values fail configuration validation.
  - Changes SHOULD be re-applied at runtime for future hook executions.

#### 5.4.8 `agent` (object)

Fields:

- `runtime` (string)
  - REQUIRED.
  - Supported values: `codex`, `claude`.
- `command` (string shell command)
  - REQUIRED.
  - For Codex, the command is expected to launch a compatible app-server over stdio.
  - For Claude, the command is parsed as a CLI invocation and the runtime appends Claude Code
    stream-json arguments for each turn.
  - Launch semantics are adapter-specific; see Section 10.1.
- `concurrency.max_total` (integer)
  - Default: `10`
  - Changes SHOULD be re-applied at runtime and affect subsequent dispatch decisions.
- `limits.max_turns` (positive integer)
  - Default: `20`
  - Limits the number of coding-agent turns within one worker session.
  - Invalid values fail configuration validation.
- `limits.retry_backoff_max_ms` (integer)
  - Default: `300000` (5 minutes)
  - Changes SHOULD be re-applied at runtime and affect future retry scheduling.
- `limits.max_consecutive_identical_tool_failures` (integer)
  - Default: `5`.
  - `0` disables consecutive identical tool failure detection.
  - Codex app-server turns SHOULD abort when the same command execution or dynamic tool call fails
    this many times consecutively within one turn. The signature MUST include execution kind,
    command/tool name, and a stable hash of arguments. Any successful execution or different
    execution signature resets the count.
- `concurrency.epic_lanes` (integer)
  - Default: `concurrency.max_total`.
  - How many slots active epics may reserve as lanes (Section 8.3). Must be between `0` and
    `concurrency.max_total`; other values fail configuration validation.
- `concurrency.finishing_max` (positive integer)
  - Default: `2`.
  - Landing runs (issues in `Merging`) that may run at once outside `max_total` and the epic lanes
    (Section 8.3). Auto Review QA passes are also capped by it. Values below `1` fail configuration
    validation.
- `concurrency.max_by_issue_state` (map `state_name -> positive integer`)
  - Default: empty map.
  - State keys are normalized (`lowercase`) for lookup.
  - Invalid entries (blank state names, non-positive, or non-integer values) fail configuration
    validation.
- `limits.tokens_per_issue` (integer or null)
  - Default: `500000`.
  - Explicit `null` disables the per-issue cap.
- `limits.tokens_per_day` (integer or null)
  - Default: `5000000`.
  - Explicit `null` disables the daily cap.
- `prompts.include_project_guides` (boolean)
  - Default: `true`.
  - When enabled, implementations MAY append a `## Project conventions` section to the rendered
    workflow prompt using workspace-local prose guide files.
- `prompts.project_guide_files` (list of relative paths or null)
  - Default: `null`, meaning adapter defaults apply.
  - Elixir adapter defaults: `["CLAUDE.md"]` for Claude, `[]` for Codex.
  - Entries MUST be relative workspace paths, MUST NOT contain parent directory segments, and
    missing files are skipped.
  - Implementations that resolve `@path` import lines MUST reject absolute, home-relative, and
    workspace-escaping imports and enforce bounded size/depth/file-count limits.

#### 5.4.9 Agent Protocol Fields

These fields live under `agent.permissions`. For Codex-owned config values such as
`approval_policy`, `filesystem.sandbox`, and `filesystem.turn_policy`, supported values are defined by the targeted Codex
app-server version. Implementors SHOULD treat them as pass-through Codex config values rather than
relying on a hand-maintained enum in this spec. To inspect the installed Codex schema, run
`codex app-server generate-json-schema --out <dir>` and inspect the relevant definitions referenced
by `v2/ThreadStartParams.json` and `v2/TurnStartParams.json`. Implementations MAY validate these
fields locally if they want stricter startup checks.

- `approval_policy` (Codex `AskForApproval` value)
  - Default for Codex is an implementation-owned reject-map policy.
  - Default for Claude is `never`.
  - Elixir Codex default:
    `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}`.
  - Elixir accepts Codex string/object values supported by the targeted app-server, except
    `agent.permissions.approval_policy="never"` is rejected for Codex. Use `auto_approve_all` for unattended
    auto-approval.
  - Elixir evidence: `lib/symphony_elixir/config/schema.ex` and
    `test/symphony_elixir/workspace_and_config_test.exs`.
- `filesystem.sandbox` (Codex `SandboxMode` value)
  - Default: `workspace-write`.
- `filesystem.turn_policy` (Codex `SandboxPolicy` value)
  - Default: implementation-defined.
  - Runtime note: when the policy type is `workspaceWrite`, implementations MUST ensure the
    current issue workspace remains writable (when a workspace path is available) even when callers
    add extra `writableRoots` for linked worktree Git metadata or similar adjunct paths.
  - Implementations MUST include the minimal Git metadata roots needed for branch, fetch,
    commit, and push operations: always the issue workspace `.git` path (when a workspace path
    is available), plus the workspace's actual Git metadata roots when discoverable from Git
    itself (for example `git rev-parse --git-dir --git-common-dir`). For linked worktree workspace
    strategies where those roots are not discoverable at runtime, implementations MUST include the
    primary clone `.git` metadata root as a fallback.
- `network` (object)
  - Default `mode`: `allowlist`.
  - `mode`: one of `allowlist`, `open`, or `block`.
    - `allowlist`: network is denied by default and implementations MUST pass the effective
      allowed-domain list through the targeted Codex app-server domain-level network mechanism.
    - `open`: unrestricted outbound network, matching legacy `networkAccess: true` behavior.
    - `block`: no outbound network, matching legacy `networkAccess: false` behavior.
  - `allowed_domains`: additional domains appended to the implementation's built-in allowlist.
  - `denied_domains`: domains removed from both the built-in allowlist and `allowed_domains`.
  - Effective allowlist: `built_in_allowed_domains + allowed_domains - denied_domains`.
  - `denied_domains` MUST take precedence over both built-in and user-provided domains.
  - The Elixir Claude adapter writes equivalent sandbox/network settings to `.claude/settings.json`
    in the issue workspace for the duration of a session.
- `outer_sandbox` (object, Codex-only)
  - Default `kind`: `none`.
  - `kind`: one of `none` or `srt`.
    - `none`: no outer sandbox wrapper.
    - `srt`: wrap local Codex launch with Anthropic Sandbox Runtime (`srt`) using a temporary
      settings file generated from the effective network policy and shared filesystem deny lists.
  - `command`: shell-like command string used to invoke SRT, default `srt`.
  - `enable_weaker_network_isolation`: boolean, default `false`, passed through to SRT settings.
  - Implementations MAY emit SRT compatibility settings required by the targeted runtime version,
    such as enabling weaker nested sandbox compatibility for Linux/Docker paths.
  - When SRT owns command sandboxing, implementations SHOULD use the targeted Codex
    `externalSandbox` turn policy or equivalent to avoid nesting platform sandboxes.
  - SRT settings SHOULD allow the configured Codex runtime to write its own runtime state directory
    while deny-writing static or sensitive Codex config files such as auth, config, and global
    instructions.
  - SRT wraps the whole Codex process tree and therefore SHOULD be documented as an additional OS
    guardrail rather than a complete credential isolation boundary for the Codex runtime itself.
  - Implementations MUST reject `runtime: srt` with `network.mode: open` unless the targeted
    SRT version provides a valid unrestricted-network representation.
  - Implementations MUST reject `kind: srt` for non-Codex adapters and MAY reject it for remote
    worker launch modes that cannot access the generated temporary settings file.
  - With `kind: none`, implementations MAY continue using the targeted Codex app-server's native
    thread and turn sandbox fields for compatibility. Known Codex app-server versions fail shell
    execution when Symphony relies only on injected managed permission profiles, while native
    thread/turn sandbox fields can cause Codex to drop or bypass those injected profile deny rules.
    Treat native Codex profile deny-listing as best-effort unless the targeted runtime is verified
    to preserve it while running shell commands.
  - Use `kind: srt` when the implementation needs the shared sensitive filesystem deny list to be
    enforced outside Codex while keeping shell command execution available.
  - Elixir evidence: `lib/symphony_elixir/config/schema.ex`,
    `lib/symphony_elixir/agent_sandbox_config.ex`,
    `test/symphony_elixir/workspace_and_config_test.exs`, and
    `test/symphony_elixir/agent_sandbox_config_test.exs`.
- `turn_timeout_ms` (integer)
  - Default: `3600000` (1 hour)
- `read_timeout_ms` (integer)
  - Default: `30000`
- `stall_timeout_ms` (integer)
  - Default: `300000` (5 minutes)
  - If `<= 0`, stall detection is disabled.
- `command_timeout_ms` (integer)
  - Default: `600000` (10 minutes)

#### 5.4.10 `watchdog` (object)

Fields:

- `enabled` (boolean)
  - Default: `true`
  - When `false`, watchdog ticks still run but do not terminate sessions.
- `tick_interval_ms` (positive integer)
  - Default: `60000` (1 minute)
  - Controls how often the orchestrator evaluates running-agent no-progress state.
- `no_progress_threshold_ms` (positive integer)
  - Default: `600000` (10 minutes)
  - If a running agent has not emitted a transcript event since this threshold, terminate the
    agent session, run `after_run`, record the run as timed out, emit a `run_stuck` semantic event,
    and schedule retry through the normal retry queue/backoff.

#### 5.4.11 `workers` (object)

Fields:

- `ssh_hosts` (list of strings)
  - Default: `[]`.
  - Empty list means local execution.
- `max_concurrent_agents_per_host` (positive integer, OPTIONAL)
  - Shared per-host cap for configured SSH hosts.

#### 5.4.12 `dashboard` (object)

Fields:

- `enabled` (boolean)
  - Default: `true`.
- `refresh_ms` (positive integer)
  - Default: `1000`.
- `render_interval_ms` (positive integer)
  - Default: `16`.
- `snapshot_publish_ms` (positive integer)
  - Default: `500`.
- `transcript_buffer_size` (non-negative integer)
  - Default: `200`.

Listener fields also live under `dashboard`:

Fields:

- `port` (non-negative integer, OPTIONAL)
  - `0` requests an OS-assigned port.
- `host` (string)
  - Default: `127.0.0.1`.

#### 5.4.13 `pull_requests.checks` (object)

Fields:

- `enabled` (boolean)
  - Default: `false`.
- `log_excerpt_lines` (positive integer)
  - Default: `200`.
- `retry_failed_once` (boolean)
  - Default: `true`.
- `max_fix_attempts` (non-negative integer)
  - Default: `3`.
- `escalate_to_state` (string)
  - Default: `In Review`.
  - Blank values normalize back to `In Review`.

#### 5.4.14 `issue_gate` (object)

Fields:

- `enabled` (boolean)
  - Default: `false`.
- `provider` (`anthropic` or `openai`)
  - Default: `anthropic`.
- `model` (string)
  - Default: `claude-haiku-4-5-20251001`.
- `pass_threshold` (integer 1..10)
  - Default: `6`.
- `clarification_floor` (integer 1..10, OPTIONAL)
  - When set, it MUST be lower than the effective pass threshold.
- `max_clarification_rounds` (positive integer)
  - Default: `2`.
- `on_error` (`pass` or `skip`)
  - Default: `pass`.

#### 5.4.15 `pull_requests.learnings` (object)

Fields:

- `enabled` (boolean)
  - Default: `false`.
- `provider` (`anthropic` or `openai`)
  - Default: `anthropic`.
- `model` (string)
  - Default: `claude-haiku-4-5-20251001`.
- `max_total_per_repo` (positive integer)
  - Default: `500`.
- `max_per_run` (integer 0..3)
  - Default: `3`.

#### 5.4.16 `pre_push_review` (object)

Fields:

- `enabled` (boolean)
  - Default: `false`.
- `runtime` (`codex` or `claude`)
  - REQUIRED when `enabled` is true.
- `command` (string)
  - REQUIRED when `enabled` is true.
- `model` (string), `effort` (`low`, `medium`, `high`, `xhigh`, or `max`)
  - Optional. Each resolves to this field, else the `pre_push_review` run profile resolved as for
    `agent.run_profiles` (the routed repository's `repositories[].agent` first), else null
    (nothing added). `command` MUST NOT pass `--model` /
    `--effort` while any of them resolves.
- `max_iterations` (positive integer)
  - Default: `1`.

When enabled, Symphony SHOULD run an executor + reviewer flow in the same workspace. The executor
SHOULD stop before pushing, the reviewer SHOULD receive issue context plus the committed diff, and
the reviewer MUST return a structured verdict of `approve`, `request_changes`, or `block`. Reviewer
sessions SHOULD expose only read-only scoped Linear/GitHub tools. An `approve` verdict SHOULD keep
later executor continuations in push/PR handoff mode rather than reintroducing the pre-push reviewer
gate. `request_changes` and `block` verdicts SHOULD include evidence-backed findings with file,
line range, quoted snippet, summary, and suggested fix; Symphony SHOULD reject verdicts whose
findings cannot be verified against the reviewer diff/context, and SHOULD run one bounded
self-check turn before accepting blocking findings. Reviewer token usage SHOULD be tracked
separately from the aggregate run token total.

Reviewer outcome handling MUST distinguish terminal blocks from inconclusive reviewer runs.
Verified `block` verdicts with at least one grounded finding SHOULD terminate the worker with a
dedicated `review_agent_blocked` exit, post the block reason/findings to the tracker, move the issue
to the configured human-review escalation state (`pull_requests.checks.escalate_to_state`), and avoid
scheduling another orchestrator retry. If that tracker transition fails, Symphony SHOULD still release
its local issue claim rather than leaving the issue stuck as running. Reviewer parse failures,
turn-budget failures, or validation/self-check paths that remove all findings SHOULD be classified as
`review_agent_inconclusive`; Symphony SHOULD retry the reviewer once with a fresh reviewer session,
then downgrade to `request_changes` with a non-convergence note instead of retrying the full executor
run.

#### 5.4.17 `auto_review` (object)

Fields:

- `enabled` (boolean)
  - Default: `false`.
- `state` (non-empty string)
  - Default: `Auto Review`. The tracker state issues wait in between the PR opening and human review.
- `runtime` (`codex` or `claude`, default `agent.runtime`), `command` (string, default
  `agent.command`), `max_turns` (positive integer, default `20`), `timeout_ms` (positive integer,
  default `1800000`)
  - The QA agent session.
- `max_concurrent` (positive integer, default `1`): QA passes running at once.
- `max_fix_attempts` (non-negative integer, default `2`): QA failures sent back to `In Progress`
  before the issue is handed to `In Review` anyway.
- `run_on` (`every_push` or `first_pass`, default `every_push`): with `first_pass`, once a push
  has passed QA, later pushes on the PR skip it.
- `skip_globs` (list of strings, default `[]`): extra paths that, like docs and tests, never need
  QA.
- `playbooks` (map, default `{}`): per-kind overrides. A built-in kind takes `paths` and
  `enabled`; a new kind needs `paths` and `prompt`. The built-in `macos_app` kind also takes
  `build` (shell command run in the QA worktree), `app` (the `.app` bundle path relative to the
  repo root) and `build_timeout_ms` (default `900000`), and is off unless `build` and `app` are
  set.

When enabled:

- At startup Symphony SHOULD check that the configured Linear teams (`issues.linear.scope.team`
  and `repositories[].route.team`; any team when none is configured) have a workflow state named
  `state`. When the state is missing, or when `pull_requests.enabled` or
  `pull_requests.checks.enabled` is off (nothing would move issues out of the state), Symphony MUST
  log a warning and behave as if Auto Review were disabled until restart. When the check itself
  fails, Auto Review stays on.
- The post-PR transition (an active issue whose completed run opened a PR and has no rework signal)
  MUST target `state` instead of `In Review`.
- The post-PR transition MUST NOT apply to an issue in `Merging`: that state is a human's merge
  approval, so Symphony MUST keep the issue in `Merging` and leave it with the landing agent.
- `linear_update_state` MUST refuse `In Review` from agent sessions with a clear error telling the
  agent that Symphony moves the issue once the PR is open, rather than redirecting the target
  state. A `breakdown` parent and a ticket whose title starts with `Final verification:` open no
  PR, so they MAY move to `In Review`.
- The CI poller MUST discover issues in `state` as well as `In Review`. Red CI follows the normal
  `In Progress` fix loop and escalation. Green CI on an issue in `state` starts a QA pass for the
  PR head SHA, at most one per issue and `max_concurrent` overall.
- QA selection is deterministic and runs before any agent: a `qa:skip` label skips; a
  `qa:<kind>` label selects that playbook; a diff that only touches docs, tests or `skip_globs`
  skips; otherwise playbooks are selected by their trigger paths, and the `cli` playbook also by a
  `## User walkthrough` section in the issue. No selected playbook means skip. The built-in `cli`
  playbook triggers on `bin/**`, `lib/symphony_elixir/cli.ex` and `lib/mix/tasks/**`; the built-in
  `macos_app` playbook on `**/*.swift`, `**/Info.plist`, `**/*.xib`, `**/*.storyboard` and
  `**/*.xcassets/**`.
- A pass that runs the `macos_app` playbook also gets host-side `qa_*` tools, executed by Symphony
  outside the agent sandbox: `qa_build` (only the configured `build`, refused when the worktree has
  changes outside `qa-evidence/`, including gitignored files that were not there after the last
  build), `qa_launch_app` / `qa_quit_app` (only the configured bundle,
  resolved inside the worktree, launched from a copy the last successful `qa_build` made in a
  directory the agent sandbox cannot write, refused under the same worktree check, always with
  `SYMPHONY_BAR_QA_ROOT` set to a private directory), `qa_screenshot` (new files in `qa-evidence/`, never replacing or following an existing entry), and
  `qa_ax_tree`, `qa_ax_press`, `qa_ax_set_value`. Every tool that takes a PID MUST refuse a PID
  the pass did not launch. Apps still running when the pass ends MUST be quit. A missing Screen
  Recording or Accessibility grant MUST surface as a `qa_permission_missing` tool error that tells
  the agent to answer `blocked`. Other tool scopes MUST NOT list or run the `qa_*` tools.
- The QA agent MUST run in a fresh detached worktree at the PR head SHA, outside the issue
  workspace, removed afterwards, with a tool scope limited to read-only Linear/GitHub tools and
  `linear_attach_file`. It answers with JSON: `verdict` (`pass`, `fail` or `blocked`), `summary`,
  `steps` (`name`, `status`, `details`, `evidence`), `findings`, and `reason`. An answer with no
  verdict object SHOULD get one follow-up turn in the same session asking for it. A run error or
  an answer still unreadable after that counts as `blocked`. The session stops at `agent.limits.tokens_per_issue`.
- Symphony applies the verdict: `pass`, `blocked` and skip move the issue to `In Review`; `fail`
  moves it to `In Progress` with the findings in the next run's prompt, or to `In Review` once
  `max_fix_attempts` failures were sent back. Results are stored per head SHA; a failed move is
  retried on the next poll, and an issue back in `state` on the same SHA after a `fail` counts as
  another failure.
- Each pass rewrites one `## Symphony QA Report` issue comment (an exception to the
  single-workpad rule, written by Symphony only), records a run with `kind: "qa"`, tokens and
  runtime in the run store, and emits `qa_passed` or `qa_failed`.
- Parent walkthrough: a run of kind `final_verification` on a local worker with the Linear tracker,
  for a ticket with a parent and no `qa:skip` label, MUST NOT start an executor agent. Symphony
  runs the QA agent instead, with no PR, in a fresh worktree at the head of
  `origin/<base_branch>`, with the parent as the issue under test and the verification ticket's
  description as an extra checklist. Playbooks come from `qa:<kind>` labels on the ticket or the
  parent, else every enabled playbook. The `## Symphony QA Report` is written on the parent and on
  the verification ticket. `pass` and `blocked` move the verification ticket to `In Review`;
  `fail` creates one `Backlog` child of the verification ticket per failing step (per finding when
  no step failed), naming the step and holding its details and evidence, lists them in the report,
  and moves the verification ticket to `Backlog`. There is no fix loop. Any other final
  verification ticket gets the executor run.

When disabled, behaviour is unchanged.

#### 5.4.18 `notifications` (object)

Fields:

- `enabled` (boolean)
  - Default: `false`.
- `redact_titles` (boolean)
  - Default: `false`.
- `channels` (list)
  - Each channel requires `kind`.
  - Supported `kind` values: `slack`, `webhook`.
  - Slack channels require `webhook_url` when notifications are enabled.
  - Webhook channels require `url` when notifications are enabled.
  - `events` is an OPTIONAL list drawn from: `pr_opened`, `awaiting_review`, `run_failed`,
    `issue_completed`, `budget_exceeded`, `reviewer_commented`, `rework_pushed`, `ci_failed`,
    `ci_escalated`, `qa_passed`, `qa_failed`.
  - `headers` is an OPTIONAL map of webhook headers.

### 5.5 Prompt Template Contract

The Markdown body of `WORKFLOW.md` is the per-issue prompt template. Repo-local front matter MAY
also define `prompts.pr` as a PR-mode prompt template for explicit PR runs.

Rendering requirements:

- Use a strict template engine (Liquid-compatible semantics are sufficient).
- Unknown variables MUST fail rendering.
- Unknown filters MUST fail rendering.
- Before the rendered issue template or PR template, prepend a managed Symphony runtime context.
  That context MUST cover workspace-only execution, untrusted Linear/GitHub/CI/tool-output
  handling, scoped Linear/GitHub tool preference, workpad usage, obvious secret paths, and final
  response expectations. Repo `WORKFLOW.md` templates SHOULD NOT be required to restate these
  Symphony-owned rules.

Template input variables:

- `issue` (object)
  - Includes all normalized issue fields, including labels and blockers.
- `pr` (object)
  - Present for PR-mode runs.
  - Includes normalized PR fields such as `number`, `url`, `title`, `body`, `state`, `base_ref`,
    `head_ref`, and operator `intent`.
- `attempt` (integer or null)
  - `null`/absent on first attempt.
  - Integer on retry or continuation run.
- `agent` (object)
  - `kind`: configured `agent.runtime` (`codex` or `claude`).
  - `display_name`: human-facing agent name (`Codex` or `Claude`).
  - `update_label`: dashboard/update label such as `Codex update` or `Claude update`.
  - `workpad_heading`: Linear workpad heading such as `## Codex Workpad` or
    `## Claude Workpad`.
- `repo_key` (string or null)
  - Matched repo route name when known.
- `reviewer_comments` (list)
  - Normalized reviewer comment context injected by PR review polling when available.
- `ci_failure` (object or null)
  - CI failure context injected by CI polling when available.

Fallback prompt behavior:

- If the workflow prompt body is empty, the runtime MAY use a minimal default prompt
  (`You are working on an issue from Linear.`), still preceded by the managed runtime context.
- If a PR run is dispatched and `prompts.pr` is absent or blank, the runtime MAY use a built-in PR
  prompt that treats PR fields as untrusted data and instructs the agent to push to the PR head
  branch without creating a new PR, still preceded by the managed PR runtime context.
- Workflow file read/parse failures are configuration/validation errors and SHOULD NOT silently fall
  back to a prompt.
- If project guides are enabled and at least one configured guide is present, the runtime MAY append
  a `## Project conventions` section after the rendered workflow prompt. If no configured guide is
  present, the section SHOULD be omitted rather than rendering an empty heading.
- When settings are known, the runtime SHOULD append a poller-aware PR-feedback/CI posture derived
  from config so repo `WORKFLOW.md` templates need not restate it. When the PR-review poller is
  active (`pr_review.mode == "polling"`), the agent is told PR review feedback arrives via Symphony
  re-activation (continuation prompt) and to wait rather than poll `github_*` itself; otherwise the
  agent is told to gather review feedback itself. The CI half follows the CI poller's enablement
  (`pr_review.mode == "polling"` and `ci.enabled`) independently. When settings are unavailable the
  section SHOULD be omitted.

### 5.6 Workflow Validation and Error Surface

Error classes:

- `missing_symphony_file`
- `symphony_parse_error`
- `symphony_file_not_a_map`
- `invalid_symphony_config`
- `missing_workflow_file`
- `workflow_parse_error`
- `workflow_front_matter_not_a_map`
- `invalid_repo_workflow_config`
- `template_parse_error` (during prompt rendering)
- `template_render_error` (unknown variable/filter, invalid interpolation)

Dispatch gating behavior:

- Workflow file read/YAML errors block new dispatches until fixed.
- Template errors fail only the affected run attempt.

## 6. Configuration Specification

### 6.1 Configuration Resolution Pipeline

Configuration is resolved in this order:

1. Select and load `symphony.yml` (explicit runtime setting, otherwise cwd default).
2. Parse YAML into a raw operator config map.
3. Coerce and validate the operator config with the system schema, including `repositories:` routing
   validation.
4. Select the repo for this settings lookup:
   - explicit `repo_key` for routed issue work;
   - primary repo (`default: true`, otherwise first repo) for no-repo fallback.
5. Load the selected repo's `WORKFLOW.md` from its workflow source (Section 5.1).
6. Parse repo workflow front matter into a repo-local config map and prompt template.
7. Merge system config with the selected repo-local config.
8. Apply built-in defaults for missing OPTIONAL fields.
9. Resolve `$VAR_NAME` indirection only for config values that explicitly contain `$VAR_NAME`.
10. Coerce and validate typed values and semantic requirements.

Environment variables do not globally override YAML values. They are used only when a config value
explicitly references them.

Value coercion semantics:

- Path/command fields support:
  - `~` home expansion
  - `$VAR` expansion for env-backed path values
  - Apply expansion only to values intended to be local filesystem paths; do not rewrite URIs or
    arbitrary shell command strings.
- Relative local paths are expanded by the implementation's path expansion rules, which in the
  Elixir runtime means relative to the current process working directory.

### 6.2 Dynamic Reload Semantics

Dynamic reload behavior:

- The Elixir implementation polls repo `WORKFLOW.md` files and keeps each `WorkflowStore` on the
  last known good workflow when reload fails.
- For `workflow_source: ref`, the workflow is re-read from the remote base branch at startup and
  on every dispatch after the pre-dispatch fetch, so a change pushed to the base branch applies to
  the next dispatch without restart. A missing or invalid workflow on the ref is logged and the
  last known good workflow is kept. Until the ref has been read once, the local file is read
  with a warning, and readers switch to the ref without restart once it resolves.
- `symphony.yml` is re-read through the config layer during runtime operations such as dispatch,
  watchdog handling, and snapshots.
- Changes to `symphony.yml` values that affect OTP child topology, including the `repositories:` list,
  primary repo selection, PR/CI poller enablement, verification supervisors, and HTTP listener
  binding, require restart unless the implementation explicitly supports live rebind/re-supervision.
- The orchestrator refreshes selected live state from config, including polling cadence and global
  concurrency limit.
- Other settings are read at point of use by their owning modules and apply to future dispatch,
  retry scheduling, reconciliation decisions, hook execution, and agent launches where applicable.
- Implementations are not REQUIRED to restart in-flight agent sessions automatically when config
  changes.
- Extensions that manage their own listeners/resources (for example an HTTP server port change) MAY
  require restart unless the implementation explicitly supports live rebind.
- Implementations SHOULD also re-validate/reload defensively during runtime operations (for example
  before dispatch) in case filesystem watch events are missed.
- Invalid reloads MUST NOT crash the service; keep operating with the last known good effective
  configuration and emit an operator-visible error.

### 6.3 Dispatch Preflight Validation

This validation is a scheduler preflight run before attempting to dispatch new work. It validates
the workflow/config needed to poll and launch workers, not a full audit of all possible workflow
behavior.

Startup validation:

- Validate configuration before starting the scheduling loop.
- If startup validation fails, fail startup and emit an operator-visible error.

Per-tick dispatch validation:

- Re-validate before each dispatch cycle.
- If validation fails, skip dispatch for that tick, keep reconciliation active, and emit an
  operator-visible error.

Validation checks:

- `symphony.yml` can be loaded and parsed.
- The primary repo workflow file can be loaded and parsed.
- For routed dispatch, the matched repo workflow file can be loaded and parsed.
- Repo routing rules are valid.
- `issues.provider` is present and supported.
- `agent.runtime` is present and supported.
- `agent.command` is present and non-empty.
- `agent.effort` and every `agent.run_profiles.<kind>.effort` are known effort values, and every
  `agent.run_profiles` key is a known run kind.
- `agent.provider` and every `agent.run_profiles.<kind>.provider` are `anthropic` or `openrouter`.
  Every run kind that resolves to `openrouter` also resolves a model, and `openrouter` is only
  used with `agent.runtime == "claude"` and without `workers.ssh_hosts`.
- `agent.command` does not already pass `--model` or `--effort` when `agent.model`,
  `agent.effort`, or `agent.run_profiles` is set.
- Every `repositories[].agent` block passes the same checks with the `agent` section beneath it,
  and its errors name `repositories[<key>].agent...`.
- `issues.linear.api_key` is present after `$` resolution when `issues.provider == "linear"`.
- At least one Linear scoping filter is present when `issues.provider == "linear"`. Core scope comes
  from `issues.linear.scope.project_slug`, `issues.linear.scope.team`, or non-empty
  `issues.linear.scope.labels`; implementations with per-repo polling MAY also count repo-level
  route selectors.
- Blank issue-level scope entries do not count as configured Linear scoping filters.
- `agent.permissions.approval_policy="never"` is invalid when `agent.runtime == "codex"`; use
  `auto_approve_all` for unattended auto-approval.
- `agent.permissions.outer_sandbox.runtime == "srt"` is valid only when `agent.runtime == "codex"`
  and `agent.permissions.network.mode != "open"`.
- `workspaces.attachments.public_upload_extensions` entries must be plain file extensions.

### 6.4 Core Config Fields Summary (Cheat Sheet)

This section is intentionally redundant so a coding agent can implement the config layer quickly.
Extension fields are documented in the extension section that defines them. Core conformance does
not require recognizing or validating extension fields unless that extension is implemented.

- `repositories`: non-empty list of repo route entries, REQUIRED
- `repositories[].key`: unique string, REQUIRED
- `repositories[].workflow`: path string, default `WORKFLOW.md`
- `repositories[].workflow_source`: optional `ref` (default) or `local`
- `repositories[].workspace.strategy`: optional `clone` or `worktree`
- `repositories[].workspace.repo`: optional path string, required when the effective strategy is
  `worktree`
- `repositories[].workspace.fetch_before_dispatch`: optional boolean
- `repositories[].route.team`: optional Linear team key or team ID
- `repositories[].route.projects`: optional list of Linear project names/slugs/IDs
- `repositories[].route.labels`: optional list of Linear label names with route-level AND semantics
- `repositories[].route.assignee`: optional Linear assignee selector
- `repositories[].default`: boolean, default `false`
- `repositories[].agent`: optional `{provider, model, effort, run_profiles}` with the same values as
  the `agent` keys, applied to issues routed to that repository (see `agent.run_profiles`)
- `issues.provider`: string, REQUIRED, currently `linear` or `memory`
- `issues.linear.endpoint`: string, default `https://api.linear.app/graphql` when provider is linear
- `issues.linear.api_key`: string or `$VAR`, canonical env `LINEAR_API_KEY` when provider is linear
- `issues.linear.scope.project_slug`: string, OPTIONAL when provider is linear
- `issues.linear.scope.team`: optional Linear team key or team ID
- `issues.linear.scope.labels`: optional list of Linear label names
- At least one issue-level or repository route selector is REQUIRED when provider is linear.
- `issues.linear.assignee`: optional string or `$VAR`, canonical env `LINEAR_ASSIGNEE`;
  `"me"` resolves the current Linear viewer
- `issues.states.active`: list of strings, default `["Todo", "In Progress"]`
- `issues.states.terminal`: list of strings, default `["Closed", "Cancelled", "Canceled", "Duplicate", "Done"]`
- `issues.states.waiting_on_sub_issues`: string or null, default `Waiting on sub-tickets`; added to
  the active states when set
- `issues.poll_interval_ms`: integer, default `30000`
- `poller.backoff_base_ms`: positive integer or null; null uses the effective poll interval
- `poller.max_backoff_ms`: positive integer, default `300000`
- `poller.degraded_threshold`: positive integer, default `3`
- `workspaces.root`: path resolved to absolute, default `<system-temp>/symphony_workspaces`
- `repositories[].workspace.strategy`: `clone` or `worktree`, defaulting through global
  `workspaces.strategy`
  or `clone`
- `repositories[].workspace.repo`: path to that repo's primary clone when the effective strategy is
  `worktree`
- `repositories[].workspace.fetch_before_dispatch`: boolean, defaulting through global
  `workspaces.fetch_before_dispatch` or `true`
- `verification.enabled`: boolean, default `false`
- `verification.port_allocation.range`: two-integer inclusive range, default `[4000, 4099]`
- `verification.dev_server.start_cmd`: shell command or null
- `verification.dev_server.health_check_url`: URL template or null
- `verification.dev_server.health_timeout_ms`: integer, default `30000`
- `verification.dev_server.stop_signal`: signal name, default `TERM`
- `verification.dev_server.stop_timeout_ms`: integer, default `10000`
- `hooks.after_create`: shell script or null
- `hooks.before_run`: shell script or null
- `hooks.after_run`: shell script or null
- `hooks.before_remove`: shell script or null
- `hooks.timeout_ms`: integer, default `60000`
- `agent.concurrency.max_total`: integer, default `10`
- `agent.concurrency.max_by_issue_state`: map of positive integers, default `{}`
- `agent.concurrency.epic_lanes`: integer between `0` and `max_total`, default `max_total`
- `agent.concurrency.finishing_max`: integer `>= 1`, default `2`
- `agent.limits.max_turns`: integer, default `20`
- `agent.limits.retry_backoff_max_ms`: integer, default `300000` (5m)
- `agent.limits.max_consecutive_identical_tool_failures`: integer, default `5`; `0` disables
- `agent.limits.tokens_per_issue`: integer or null, default `500000`; explicit null disables the cap
- `agent.limits.tokens_per_day`: integer or null, default `5000000`; explicit null disables the cap
- `agent.runtime`: `codex` or `claude`, REQUIRED
- `agent.command`: shell command string, REQUIRED
- `agent.model`: model name string or null, default `null`
- `agent.effort`: `low`, `medium`, `high`, `xhigh`, `max`, or null, default `null`
- `agent.provider`: `anthropic` or `openrouter`, default `anthropic`. The provider that serves the
  run's model; `openrouter` requires a resolved model and `agent.runtime == "claude"`.
- `agent.run_profiles`: map of run kind to `{model, effort, provider}`, default `{}`. Run kinds:
  `implementation`, `breakdown`, `close_out`, `final_verification`, `rework`, `landing`, `ci_fix`,
  `review_feedback`, `pre_push_review`, `qa`. Each field resolves, for the issue's routed
  repository, to `repositories[].agent.run_profiles.<kind>`, else `repositories[].agent.<field>`,
  else `agent.run_profiles.<kind>`, else `agent.model` / `agent.effort` / `agent.provider`, else
  null (nothing added) for model and effort and `anthropic` for provider. Repo workflow front
  matter is not a source. The run kind and profile are resolved
  once per dispatch from the current config and kept for every continuation turn of that run. The
  Claude runtime appends `--model <model>` and `--effort <effort>` to its argv; the Codex runtime
  ignores both and logs a warning. A Claude run whose provider is `openrouter` also starts with
  `ANTHROPIC_BASE_URL=https://openrouter.ai/api`, `ANTHROPIC_AUTH_TOKEN` set from the
  `OPENROUTER_API_KEY` environment variable of the Symphony process, an empty
  `ANTHROPIC_API_KEY`, and `CLAUDE_CODE_SUBAGENT_MODEL=<model>`. If `OPENROUTER_API_KEY` is unset
  or blank, the run fails before the agent starts with an error naming the run kind and the
  variable. The key MUST NOT be written to config, logs, the audit log, the run store, or
  transcripts. Before an OpenRouter run starts, the implementation looks the model up in
  OpenRouter's models catalog (`GET https://openrouter.ai/api/v1/models`, cached in process with
  a TTL). A model whose `supported_parameters` lacks `tools` fails the run before the agent starts,
  with an error naming the model, the run kind, and the missing capability. A model without
  `reasoning` starts without `--effort`, with a warning logged once per model. If the catalog
  cannot be read, or does not list the model, the run starts and a warning is logged.
- `agent.prompts.include_project_guides`: boolean, default `true`
- `agent.prompts.project_guide_files`: list of relative paths or null, default `null`
- `agent.permissions.approval_policy`: agent approval policy, default depends on `agent.runtime`
- `agent.permissions.filesystem.sandbox`: Codex `SandboxMode` value, default `workspace-write`
- `agent.permissions.filesystem.turn_policy`: Codex `SandboxPolicy` value, default implementation-defined
- `agent.permissions.network.mode`: `allowlist`, `open`, or `block`, default `allowlist`
- `agent.permissions.network.allowed_domains`: list of additional allowed domains, default `[]`
- `agent.permissions.network.denied_domains`: list of domains removed from the effective allowlist, default `[]`
- `agent.permissions.outer_sandbox.runtime`: `none` or `srt`, default `none`
- `agent.permissions.outer_sandbox.command`: SRT command string, default `srt`
- `agent.timeouts.turn_ms`: integer, default `3600000`
- `agent.timeouts.read_ms`: integer, default `30000`
- `agent.timeouts.stall_ms`: integer, default `300000`
- `agent.timeouts.command_ms`: integer, default `600000`
- `watchdog.enabled`: boolean, default `true`
- `watchdog.tick_interval_ms`: integer, default `60000`
- `watchdog.no_progress_threshold_ms`: integer, default `600000`
- `workers.ssh_hosts`: list of strings, default `[]`
- `workers.max_concurrent_agents_per_host`: positive integer or null
- `dashboard.enabled`: boolean, default `true`; turns the terminal dashboard on or off. It does not stop
  the HTTP server or control API. The terminal dashboard is drawn only when standard output is a terminal.
- `dashboard.refresh_ms`: integer, default `1000`
- `dashboard.render_interval_ms`: integer, default `16`
- `dashboard.snapshot_publish_ms`: integer, default `500`
- `dashboard.transcript_buffer_size`: integer, default `200`
- `pull_requests.enabled`: boolean, default `false`
- `pull_requests.poll_interval_ms`: positive integer or null; falls back to `issues.poll_interval_ms`
- `pull_requests.review_comments.rework_delay_minutes`: polling-mode integer, default `10`
- `pull_requests.review_comments.stale_after_days`: polling-mode integer, default `7`
- `pull_requests.review_comments.ignored_reviewers`: polling-mode list of strings, default `[]`; comments from
  the auto-detected current `gh` user and PR author are skipped only when Symphony posted them
- `pull_requests.review_comments.reply_after_addressing`: polling-mode boolean, default `false`
- `pull_requests.review_comments.request_review_after_push`: polling-mode boolean, default `false`
- `pull_requests.checks.enabled`: boolean, default `false`
- `pull_requests.checks.log_excerpt_lines`: integer, default `200`
- `pull_requests.checks.retry_failed_once`: boolean, default `true`
- `pull_requests.checks.max_fix_attempts`: integer, default `3`
- `pull_requests.checks.escalate_to_state`: string, default `In Review`
- `dashboard.port`: non-negative integer or null
- `dashboard.host`: string, default `127.0.0.1`
- `issue_gate.enabled`: boolean, default `false`
- `issue_gate.provider`: `anthropic` or `openai`, default `anthropic`
- `issue_gate.model`: string, default `claude-haiku-4-5-20251001`
- `issue_gate.pass_threshold`: integer, default `6`
- `issue_gate.clarification_floor`: integer or null
- `issue_gate.max_clarification_rounds`: integer, default `2`
- `issue_gate.on_error`: `pass` or `skip`, default `pass`
- `pull_requests.learnings.enabled`: boolean, default `false`
- `pull_requests.learnings.provider`: `anthropic` or `openai`, default `anthropic`
- `pull_requests.learnings.model`: string, default `claude-haiku-4-5-20251001`
- `pull_requests.learnings.max_total_per_repo`: integer, default `500`
- `pull_requests.learnings.max_per_run`: integer, default `3`
- `pre_push_review.enabled`: boolean, default `false`
- `pre_push_review.runtime`: `codex` or `claude`, required when enabled
- `pre_push_review.command`: string, required when enabled
- `pre_push_review.model`: string or null, default `null`
- `pre_push_review.effort`: `low`, `medium`, `high`, `xhigh`, `max`, or null, default `null`
- `pre_push_review.max_iterations`: integer, default `1`
- `auto_review.enabled`: boolean, default `false`
- `auto_review.state`: string, default `Auto Review`
- `auto_review.runtime`: `codex` or `claude`, optional
- `auto_review.command`: string, optional
- `auto_review.model`: string or null, default `null`; else the `qa` run profile's model (see
  `agent.run_profiles`)
- `auto_review.effort`: `low`, `medium`, `high`, `xhigh`, `max`, or null, default `null`; else the
  `qa` run profile's effort
- `auto_review.max_turns`: integer, default `20`
- `auto_review.timeout_ms`: integer, default `1800000`
- `auto_review.max_concurrent`: integer, default `1`
- `auto_review.max_fix_attempts`: integer, default `2`
- `auto_review.run_on`: `every_push` or `first_pass`, default `every_push`
- `auto_review.skip_globs`: list of strings, default `[]`
- `auto_review.playbooks`: map, default `{}`
- `notifications.enabled`: boolean, default `false`
- `notifications.redact_titles`: boolean, default `false`
- `notifications.channels`: list of Slack/webhook channel configs, default `[]`

## 7. Orchestration State Machine

The orchestrator is the only component that mutates scheduling state. All worker outcomes are
reported back to it and converted into explicit state transitions.

### 7.1 Issue Orchestration States

This is not the same as tracker states (`Todo`, `In Progress`, etc.). This is the service's internal
claim state.

1. `Unclaimed`
   - Issue is not running and has no retry scheduled.

2. `Claimed`
   - Orchestrator has reserved the issue to prevent duplicate dispatch.
   - In practice, claimed issues are either `Running` or `RetryQueued`.

3. `Running`
   - Worker task exists and the issue is tracked in `running` map.

4. `RetryQueued`
   - Worker is not running, but a retry timer exists in `retry_attempts`.

5. `Released`
   - Claim removed because issue is terminal, non-active, missing, or retry path completed without
     re-dispatch.

Important nuance:

- A successful worker exit does not mean the issue is done forever.
- The worker MAY continue through multiple back-to-back coding-agent turns before it exits.
- After each normal turn completion, the worker re-checks the tracker issue state.
- If the issue is still in an active state, the worker SHOULD start another turn on the same live
  coding-agent thread in the same workspace, up to `agent.max_turns`.
- An issue in `Rework` whose attached PR's head is the workspace `HEAD`, with no pending review,
  CI, QA or conflict signal, MUST end the run and move to the post-PR state (the Auto Review state,
  or `In Review` when Auto Review is off) once that `HEAD` differs from the head the `Rework` started
  from. That start head MUST be recorded by the first run dispatched in `Rework` and kept across
  re-dispatched runs until the issue leaves `Rework`, so rework an earlier run pushed counts and a
  fresh `Rework` on an unchanged PR does not. Nothing else moves it out of `Rework`.
- When the workspace `HEAD` is readable, two consecutive turns with no new commit, no issue state
  change, no newly attached PR and no reviewer-agent verdict MUST end the run, move the issue to
  `Backlog` and post a comment saying why. This does not apply in `Merging`.
- The first turn SHOULD use the full rendered task prompt. Implementations MAY use a compact
  bootstrap prompt when the target agent transport cannot safely carry the full rendered prompt as a
  single startup message, provided the compact prompt preserves hard security rules and directs the
  agent to load scoped issue details through trusted tools.
- A compact bootstrap prompt MUST also preserve the dispatch context that triggered the run
  (reviewer comments, CI failure details, or PR conflict metadata), truncating bulky payloads such
  as CI log excerpts instead of dropping them.
- Continuation turns SHOULD send only continuation guidance to the existing thread, not resend the
  original task prompt that is already present in thread history.
- Once the worker exits normally, the orchestrator still schedules a short continuation retry
  (about 1 second) so it can re-check whether the issue remains active and needs another worker
  session.

### 7.2 Run Attempt Lifecycle

A run attempt transitions through these phases:

1. `PreparingWorkspace`
2. `BuildingPrompt`
3. `LaunchingAgentProcess`
4. `InitializingSession`
5. `StreamingTurn`
6. `Finishing`
7. `Succeeded`
8. `Failed`
9. `TimedOut`
10. `Stalled`
11. `CanceledByReconciliation`

Distinct terminal reasons are important because retry logic and logs differ.

### 7.3 Transition Triggers

- `Poll Tick`
  - Reconcile active runs.
  - Validate config.
  - Fetch candidate issues.
  - Dispatch until slots are exhausted.

- `Worker Exit (normal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule continuation retry (attempt `1`) after the worker exhausts or finishes its in-process
    turn loop.

- `Worker Exit (abnormal)`
  - Remove running entry.
  - Update aggregate runtime totals.
  - Schedule exponential-backoff retry.

- `Agent Update Event`
  - Update live session fields, token counters, and rate limits.

- `Retry Timer Fired`
  - Re-fetch active candidates and attempt re-dispatch, or release claim if no longer eligible.

- `Reconciliation State Refresh`
  - Stop runs whose issue states are terminal or no longer active.

- `First-Turn Stall Timeout`
  - Kill a worker that has not emitted its first coding-agent event and schedule retry.

- `Watchdog Tick`
  - Detect running agents with no transcript event for the configured no-progress threshold.
  - Stop the wedged agent session, run `after_run`, emit `run_stuck`, and schedule retry.

### 7.4 Idempotency and Recovery Rules

- The orchestrator serializes state mutations through one authority to avoid duplicate dispatch.
- `claimed` and `running` checks are REQUIRED before launching any worker.
- Reconciliation runs before dispatch on every tick.
- Restart recovery is tracker-driven and filesystem-driven (without a durable orchestrator DB).
- Startup terminal cleanup removes stale workspaces for issues already in terminal states.

### 7.5 PR Review Poller

When `pull_requests.enabled` is `false`, Symphony uses only the tracker-state review loop. When
`pull_requests.enabled` is `true`, the application additionally starts a `PrReviewPoller`
GenServer. In multi-repository configurations, one poller process may serve all repositories, but
each poll cycle MUST process every configured repository route with repo-scoped run-store reads and
writes.

The poller:

- discovers issues in `In Review` with attached GitHub PR URLs (attachments whose Linear metadata
  reports the PR as `closed` or `merged` do not count as an attached PR anywhere in Symphony, so a
  reopened issue whose only PR was closed runs the normal pre-PR flow);
- records each PR URL, issue id, and workspace path in the durable run store;
- polls GitHub for review decisions and PR closure;
- waits `pull_requests.review_comments.rework_delay_minutes` after requested-change activity before moving the issue
  back to `In Progress` for orchestrator-owned rework handling;
- records the PR head observed when review comments enter pending rework, and only marks those
  comments addressed after the remote PR head advances past that recorded head;
- tracks the last addressed reviewer comment by id; if that comment is later deleted (its id is no
  longer present), falls back to the recorded addressed-at timestamp so already-addressed comments
  are not re-surfaced as fresh rework, and retains a bounded ledger of replied comment ids so an
  already-answered comment is not replied to twice;
- detects GitHub merge conflict signals (`mergeable == "CONFLICTING"` or
  `mergeStateStatus == "DIRTY"`), deduplicates by head/base identity, stores conflict context,
  and moves the issue back to `In Progress` for agent-owned conflict resolution;
- moves the issue back to `In Progress` when GitHub reports approval so the orchestrator starts
  the merge/landing workflow through the normal run path;
- removes tracked workspaces and durable review records when PRs merge, close, or remain idle
  beyond `pull_requests.review_comments.stale_after_days`; while the run store still reports a
  `running` agent run for the issue, it defers that cleanup to a later poll so a live turn (for
  example the agent merging its own PR) keeps its workspace until the run ends.
- when `pull_requests.checks.enabled` is true, polls CI status for tracked PRs in every configured
  repository route, preserving the same retry, dispatch, and escalation behavior used for the
  primary repository. With `auto_review` on, it also tracks PRs of issues in `auto_review.state`
  and starts a QA pass on green CI (see `auto_review`). It also tracks PRs of issues in
  `Merging`, so a held landing run (below) sees its head settle and a red head takes the normal
  CI-failure dispatch.

When a landing run (issue in `Merging` with an attached PR) finishes a turn while the PR head's
checks are pending, the agent runner MUST end the run instead of starting another continuation
turn, and the orchestrator MUST hold the issue in `Merging` without a continuation retry and
without dispatching it. The hold ends, and the landing agent is dispatched again through the normal
poll, when the CI poller has observed that same head SHA with green checks, or when
`pull_requests.checks.landing_wait_timeout_ms` has passed. The hold is dropped without a landing
dispatch when the issue leaves `Merging` (for example the CI-failure dispatch moves it to
`In Progress`). Holds live in orchestrator memory; after a restart the landing agent runs again and
re-establishes the hold if checks are still pending.

The orchestrator continues to own active-state dispatch, retry, run-store run records, and
dashboard-visible agent execution. The PR review poller owns only polling-mode GitHub polling,
state transitions, and tracked PR cleanup. Pending review-comment, merge-conflict, and CI-failure
prompt context lookups use the issue's repository scope when one is known, and otherwise search the
configured repositories.

## 8. Polling, Scheduling, and Reconciliation

### 8.1 Poll Loop

At startup, the service validates config, performs startup cleanup, schedules an immediate tick, and
then repeats every `issues.poll_interval_ms`.

The effective poll interval SHOULD be updated when config changes are re-applied.

Tick sequence:

1. Reconcile running issues.
2. Run workspace lifecycle preflight, including throttled age GC and free-space quota checks.
3. Run dispatch preflight validation.
4. Fetch candidate issues from tracker using active states.
5. Sort issues by dispatch priority.
6. Dispatch eligible issues while slots remain.
7. Notify observability/status consumers of state changes.

If per-tick validation fails, dispatch is skipped for that tick, but reconciliation still happens
first.

### 8.2 Candidate Selection Rules

An issue is dispatch-eligible only if all are true:

- It has `id`, `identifier`, `title`, and `state`.
- Its state is in `active_states` and not in `terminal_states`.
- It is not already in `running`.
- It is not already in `claimed`.
- Global concurrency slots are available.
- Per-state concurrency slots are available.
- Blocker rule for `Todo` state passes:
  - If the issue state is `Todo`, do not dispatch when any blocker is non-terminal.
- Parent rule passes:
  - If the issue has the `breakdown` label, do not dispatch while any sub-issue is non-terminal
    (a sub-issue with an unknown state counts as non-terminal). The parent waits while its
    sub-issues are worked and becomes eligible again for close-out once every sub-issue is
    terminal. The same rule ends a running parent's continuation turns and its retries.
  - A `breakdown` parent in `Rework` is exempt: a human rejected its plan, so it is eligible for a
    re-plan (run kind `breakdown`) whatever its sub-issues' states, once its rejected sub-issues
    are cancelled (see the review rule below).
- Waiting rule passes:
  - An issue in the `issues.states.waiting_on_sub_issues` state is dispatched only when it is a
    `breakdown` parent with at least one sub-issue and every sub-issue is terminal (the close-out
    run). Any other issue in that state waits for a human.
  - On each poll, a `breakdown` parent in `In Progress` with a non-terminal sub-issue that is not
    running or claimed is moved to the waiting state, so `In Progress` only holds issues an agent
    is working. Agents cannot move an issue there: `linear_update_state` refuses the state,
    because a human moving a parent there approves its plan (next rule).
- Plan review rule:
  - The breakdown run leaves its sub-issues in `Backlog` and moves the parent to `In Review`
    (`linear_update_state` allows `In Review` for a `breakdown` parent even with Auto Review on).
  - Approval: on each poll, for a `breakdown` parent in the waiting state with a sub-issue in
    `Backlog` that is not running or claimed, the service reads the parent's state history. When
    its latest state change is `In Review` to the waiting state, every sub-issue that has been in
    `Backlog` since before that change (created before it, no state change after it) moves to
    `Todo` in one batch. Blocked-by links keep the order. A parent the service parked from
    `In Progress` was not approved, so nothing moves.
  - Rejection: for a `breakdown` parent in `Rework` with a sub-issue in `Backlog`, the sub-issues
    in `Backlog` since the parent's latest move to `Rework` are cancelled (`Canceled`, else
    `Cancelled`) before the re-plan is dispatched; until that succeeds the parent is not
    dispatched. Sub-issues created by the re-plan are left alone.
  - Both actions are idempotent across polls and restarts: a sub-issue a human (or a final
    verification run) moves back to `Backlog` later is not moved again. The service remembers the
    `Backlog` sub-issues it last acted on per parent and skips the history read while they are
    unchanged; a failed read or move is retried on the next poll.
  - At startup the service checks the configured teams have the waiting state. When it is
    missing, it logs a warning and stops moving parents there until restart; parents then wait in
    `In Progress` as before. When the check itself fails, the state stays on.

Sorting order (stable intent), closest to done first:

1. stage: `Merging`, then the Auto Review state, then `Rework`, then any other active state
   (a resume, such as `In Progress`), then `Todo`
2. `priority` ascending (1..4 are preferred; null/unknown sorts last)
3. `created_at` oldest first
4. `identifier` lexicographic tie-breaker

While an issue in `Merging` or the Auto Review state is waiting for a slot (or an Auto Review QA
pass is queued), no `Todo` issue is dispatched. `Rework` and resumes still are.

### 8.3 Concurrency Control

Global limit:

- `available_slots = max(max_concurrent_agents - running_count, 0)`, where `running_count`
  leaves out landing runs.

Finishing limit:

- A landing run (an issue in `Merging` that is not a parent ticket) does not use `available_slots`
  or an epic lane. It needs `landing_running_count < finishing_max` instead.
- Auto Review QA passes run outside the orchestrator's slots, at most
  `min(auto_review.max_concurrent, finishing_max)` at once.

Per-state limit:

- `max_concurrent_agents_by_state[state]` if present (state key normalized)
- otherwise fallback to global limit

The runtime counts issues by their current tracked state in the `running` map.

Epic lanes:

- An active epic is a `breakdown` parent waiting on its sub-issues with at least one sub-issue
  approved and not finished (any state other than `Backlog`, `Triage` or a terminal state).
- Active epics are ordered by the parent's priority, then the parent's creation time. The first
  `min(epic_lanes, max_concurrent_agents)` of them each reserve one slot (a lane); the rest wait
  for a lane. `epic_lanes` defaults to `max_concurrent_agents`.
- `shared_slots = max_concurrent_agents - lane_count`.
- A sub-issue of an epic with a lane runs in that lane when no other sub-issue of the epic is
  running; otherwise it, and every other issue, needs a free shared slot.
- A lane with nothing running stays reserved, so the epic's next sub-issue starts there as soon as
  its blocker merges, even when the shared slots are full.
- Lanes are recomputed from the candidate issues on every poll tick.

### 8.4 Retry and Backoff

Retry entry creation:

- Cancel any existing retry timer for the same issue.
- Store `attempt`, `identifier`, `error`, `due_at_ms`, and new timer handle.

Backoff formula:

- Normal continuation retries after a clean worker exit use a short fixed delay of `1000` ms.
- Failure-driven retries use `delay = min(10000 * 2^(attempt - 1), agent.max_retry_backoff_ms)`.
- Power is capped by the configured max retry backoff (default `300000` / 5m).

Retry handling behavior:

1. Fetch active candidate issues (not all issues).
2. Find the specific issue by `issue_id`.
3. If not found, release claim.
4. If found and still candidate-eligible:
   - Dispatch if slots are available.
   - Otherwise release the claim and record the issue as waiting for a slot, keeping its
     `attempt`. Waiting for a slot is not a failure: no backoff applies. The poll dispatches the
     issue in the Section 8.2 order as soon as a slot is free, and a run ending triggers an
     immediate poll tick while anything waits. A retry deferred because a dispatch readiness task
     is already in flight waits the same way.
5. If found but no longer active, release claim.

Note:

- Terminal-state workspace cleanup is handled by startup cleanup and active-run reconciliation
  (including terminal transitions for currently running issues).
- Retry handling mainly operates on active candidates and releases claims when the issue is absent,
  rather than performing terminal cleanup itself.

### 8.5 Active Run Reconciliation

Reconciliation runs every poll tick and has two reconciliation parts plus an independent watchdog
tick.

Part A: First-turn stall detection

- For each running issue that has not emitted any coding-agent event, compute `elapsed_ms` since
  `started_at`.
- If `elapsed_ms > agent.stall_timeout_ms`, terminate the worker and queue a retry.
- If `stall_timeout_ms <= 0`, skip stall detection entirely.

Part B: Tracker state refresh

- Fetch current issue states for all running issue IDs.
- For each running issue:
  - If tracker state is terminal: terminate worker and clean workspace.
    - Exception: when the worker was last seen in `Merging` (landing its own PR), an
      integration such as "PR merged -> Done" can make the issue terminal before the agent
      posts its final workpad update. Implementations SHOULD let that worker keep running for
      a bounded grace period (5 minutes in this implementation) and only then terminate and
      clean up. A worker that exits on its own during the grace follows the normal exit path,
      whose continuation check sees the terminal state and cleans the workspace.
  - If tracker state is still active: update the in-memory issue snapshot.
  - If tracker state is neither active nor terminal: terminate worker without workspace cleanup.
- If state refresh fails, keep workers running and try again on the next tick.

Part C: No-progress watchdog

- Independently of the poll tick, a watchdog tick runs every `watchdog.tick_interval_ms`.
- If `watchdog.enabled == false`, the tick performs no session termination.
- For each running issue, compute `elapsed_ms` since `last_event_at`.
- If `elapsed_ms >= watchdog.no_progress_threshold_ms`, terminate the agent session, run
  `after_run`, record the run as `timeout`, emit `run_stuck`, and queue a retry through the normal
  retry helper/backoff path.

### 8.6 Startup Terminal Workspace Cleanup

When the service starts:

1. Query tracker for issues in terminal states.
2. For each returned issue identifier, remove the corresponding workspace directory.
3. Query tracked active/terminal issues plus durable run/retry records and scan `workspaces.root`
   for local orphan directories.
4. For each orphan directory, log the selected action and then log, delete, or move it to
   `workspaces.cleanup.trash_dir` according to `workspaces.cleanup.orphan_action`.
5. Run age-based GC for local workspaces older than `workspaces.cleanup.max_age_days`.
6. If any tracker, run-store, or filesystem read required for startup cleanup fails, log a warning
   and continue startup without deleting workspaces whose ownership could not be determined.

This prevents stale terminal workspaces from accumulating after restarts.

## 9. Workspace Management and Safety

### 9.1 Workspace Layout

Workspace root:

- `workspaces.root` (normalized absolute path)

Per-issue workspace path:

- `<workspaces.root>/<repo_key>/<sanitized_issue_identifier>`

Workspace persistence:

- Workspaces are reused across runs for the same issue.
- Successful runs do not auto-delete workspaces immediately.
- Age-based workspace GC MAY later remove successful, failed, crashed, or sideways-state workspaces
  once their directory age exceeds the configured lifecycle threshold.
- With effective workspace strategy `worktree`, cleanup removes the registered worktree with
  `git worktree remove --force` and deletes Symphony's `auto/<issue.identifier>` branch.
  Forced worktree removal also deletes the working directory on disk, including any
  uncommitted changes inside that worktree.

### 9.2 Workspace Creation and Reuse

Input: `issue.identifier`

Algorithm summary:

1. Sanitize identifier to `workspace_key`.
2. Compute workspace path under workspace root.
3. Resolve the issue's repo route and effective `repositories[].workspace` settings.
4. If the effective workspace strategy is `clone`, ensure the workspace path exists as a directory.
5. If the effective workspace strategy is `worktree`:
   - Validate that repo route's primary clone is configured for the current host.
   - Fetch `origin` in that primary clone when `fetch_before_dispatch == true`.
   - Ensure the workspace is a registered git worktree for branch `auto/<issue.identifier>`,
     creating it with `git worktree add` when absent.
   - When the issue's attached PR is open, same-repo, and its head branch differs from
     `auto/<issue.identifier>` (for example after a Linear team-key rename changed the
     identifier), use that PR head branch instead and sync the worktree to `origin/<head>`, so the
     existing PR stays reachable from the workspace's current branch.
   - If that branch is still checked out in a sibling workspace under the same repo workspace
     directory (the issue's pre-rename workspace) that no other running or retrying issue owns and
     that has no uncommitted or unpushed work, detach the sibling's HEAD to release the branch;
     otherwise refuse with a branch-collision error.
6. Mark `created_now=true` only if the directory or worktree was created during this call; otherwise
   `created_now=false`.
7. If `created_now=true`, run `hooks.after_create` if configured.

Notes:

- `before_run`, `after_run`, and `before_remove` use the same top-level `hooks` configuration
  as `after_create`.
- The `clone` strategy does not assume any specific repository/VCS workflow.
- The `worktree` strategy owns branches named `auto/<issue.identifier>` and removes those branches
  during workspace cleanup.
- Workspace preparation beyond directory creation (for example dependency bootstrap, checkout/sync,
  code generation) is implementation-defined and is typically handled via hooks.

### 9.3 OPTIONAL Workspace Population (Implementation-Defined)

The spec does not require any built-in VCS or repository bootstrap behavior.

Implementations MAY populate or synchronize the workspace using implementation-defined logic and/or
hooks (for example `after_create` and/or `before_run`).

Failure handling:

- Workspace population/synchronization failures return an error for the current attempt.
- If failure happens while creating a brand-new workspace, implementations MAY remove the partially
  prepared directory.
- Reused workspaces SHOULD NOT be destructively reset on population failure unless that policy is
  explicitly chosen and documented.

### 9.4 Workspace Hooks

Supported hooks:

- `hooks.after_create`
- `hooks.before_run`
- `hooks.after_run`
- `hooks.before_remove`

Execution contract:

- Execute in a local shell context appropriate to the host OS, with the workspace directory as
  `cwd`.
- On POSIX systems, `sh -lc <script>` (or a stricter equivalent such as `bash -lc <script>`) is a
  conforming default.
- When verification is enabled for the run, `hooks.before_run` and `hooks.after_run` receive
  `SYMPHONY_VERIFICATION_PORT` in their environment. If a project starts its dev server from a hook
  instead of `verification.dev_server.start_cmd`, it is responsible for backgrounding and cleanup.
- Hook timeout uses `hooks.timeout_ms`; default: `60000 ms`.
- Log hook start, failures, and timeouts.

Failure semantics:

- `after_create` failure or timeout is fatal to workspace creation.
- `before_run` failure or timeout is fatal to the current run attempt.
- `after_run` failure or timeout is logged and ignored.
- `before_remove` failure or timeout is logged and ignored.

### 9.5 Safety Invariants

This is the most important portability constraint.

Invariant 1: Run the coding agent only in the per-issue workspace path.

- Before launching the coding-agent subprocess, validate:
  - `cwd == workspace_path`

Invariant 2: Workspace path MUST stay inside workspace root.

- Normalize both paths to absolute.
- Require `workspace_path` to have `workspace_root` as a prefix directory.
- Reject any path outside the workspace root.

Invariant 3: Workspace key is sanitized.

- Only `[A-Za-z0-9._-]` allowed in workspace directory names.
- Replace all other characters with `_`.

### 9.6 Agent Sandbox and Sensitive Path Safety

Implementations that render filesystem policy for coding agents SHOULD use one shared policy source
for all supported adapters so hardening does not drift by runtime.

Current Elixir sandbox behavior:

- Shared read denies cover mounted volumes and common credential/config stores, including
  `/Volumes`, `~/.ssh`, `~/.config/gh`, `~/.claude/.credentials.json`, `~/.claude/projects`,
  `~/.claude/file-history`, `/etc/sudoers`, `/private/etc/sudoers`, `/var/root`, `~/.aws`,
  `~/.gnupg`, `~/Library/Application Support`, `~/Library/Keychains`,
  `~/Library/Preferences`, `~/.docker`, `~/.netrc`, `~/.git-credentials`, `~/.npmrc`,
  `~/.cargo/credentials`, `~/.config/op`, `~/.config/gcloud`, `~/.azure`, `~/.kube`, shell
  startup files, and shell or REPL history files.
- Shared write denies protect workflow and runtime guardrail files such as `WORKFLOW.md`,
  `symphony.yml`, `symphony.local.yml`, `.claude/settings.json`, `.git`, `mise.toml`,
  `.tool-versions`, shell startup files, `~/.gitconfig`, and macOS launch agent roots.
- Rendered Claude, SRT, and Codex native sandbox settings include both tilde and expanded absolute
  forms for home-relative deny paths as defense in depth.
- Codex native `workspace_write` config renders command-sandbox read denies for
  `~/.codex/auth.json`, `~/.codex/config.toml`, and `~/.codex/AGENTS.md`; operator
  `agent.permissions.filesystem.allow_read_paths` entries cannot re-allow these runtime auth/config
  files. With `agent.permissions.outer_sandbox.runtime: none`, enforcement of the native profile deny list is
  best-effort as described in Section 5.4.9.
- SRT sandbox settings allow Codex to write its runtime state directory under `~/.codex`, but
  deny-write the sensitive/static Codex files `auth.json`, `config.toml`, and `AGENTS.md`.
  Shell startup files are also read-denied and write-denied; non-fatal PATH update warnings from
  Codex MUST NOT be resolved by granting access to those files.
- SRT Git write model:
  - For each writable Git metadata root (workspace `.git`, plus any discovered linked-worktree
    `--git-dir` / `--git-common-dir`), SRT settings MUST deny writes to `config`,
    `config.worktree`, `hooks`, `info`, `packed-refs`, and the per-worktree `worktrees/*/config`
    and `worktrees/*/config.worktree` patterns. These deny rules apply regardless of layout.
  - SRT settings MUST allow writes to `<git_dir>/objects` for clone workspaces and linked
    worktrees. This keeps `git add`, `git commit`, and similar staging operations working under
    SRT. Under the default linked-worktree layout (`workspaces.strategy: worktree`,
    `workspaces.repo: <source>`), those writes target the source repository's shared
    `<source>/.git/objects` database. This is an explicit cleanup/blast-radius tradeoff: object
    writes may outlive workspace cleanup until Git GC, while higher-risk mutable Git metadata
    remains write-protected.
- Sensitive-path detection for command/audit safeguards also treats mounted volumes, admin paths,
  selected Codex runtime files, common credential basenames, `.env*`, `*.pem`, and `*.key` as
  sensitive.

Elixir evidence: `lib/symphony_elixir/agent_sandbox_config.ex`,
`lib/symphony_elixir/codex/app_server.ex`,
`lib/symphony_elixir/sensitive_path.ex`,
`test/symphony_elixir/agent_sandbox_config_test.exs`,
`test/symphony_elixir/app_server_test.exs`, and
`test/symphony_elixir/sensitive_path_test.exs`.

## 10. Agent Runner Protocol (Coding Agent Integration)

This section defines Symphony's language-neutral responsibilities when integrating the configured
coding-agent adapter. The Elixir implementation selects the adapter from `agent.runtime`:

- `codex` uses the Codex app-server JSON-RPC stream over stdio.
- `claude` uses the Claude Code CLI stream-json output format and writes temporary
  `.claude/settings.json` sandbox settings into the issue workspace.

Protocol source of truth:

- Implementations MUST send messages that are valid for the configured adapter's protocol.
- For `agent.runtime: codex`, implementations MUST consult the targeted Codex app-server
  documentation or generated schema instead of treating this specification as a protocol schema.
- For `agent.runtime: claude`, implementations MUST consume Claude Code stream-json events and map
  them into Symphony runtime events.
- If this specification appears to conflict with the targeted agent protocol, the agent protocol
  controls protocol shape and transport behavior.
- Symphony-specific requirements in this section still control orchestration behavior, workspace
  selection, prompt construction, continuation handling, and observability extraction.

### 10.1 Launch Contract

Subprocess launch parameters:

- Command: `agent.command`
- Working directory: workspace path
- Transport/framing: the protocol transport required by the configured adapter

An agent subprocess MUST NOT outlive its session or the Symphony process. When the subprocess's
transport closes, or Symphony stops (for example on SIGTERM), the implementation SHOULD send SIGTERM
to the subprocess's process group and SIGKILL after a short grace period. Closing stdin alone is not
enough: an agent may ignore EOF.

A SIGKILL or crash of Symphony skips that cleanup, so the implementation SHOULD record each agent's
process group id, its leader's start time, and its workspace durably. On startup, before
dispatching, it SHOULD stop recorded groups whose leader still has the recorded start time, MUST NOT
signal a pid whose start time differs (the pid was reused), and SHOULD NOT dispatch issues in the
workspace of a group it cannot confirm stopped until that group is gone, logging why.

Notes:

- The Elixir implementation requires explicit `agent.runtime` and `agent.command`.
- Codex local launch invokes `bash -lc <agent.command>` in the workspace. When
  `agent.permissions.outer_sandbox.runtime: srt`, the local command is wrapped as
  `<srt command> --settings <temporary-settings.json> sh -c <prelude-and-agent.command>` and
  launched with `bash --noprofile --norc -c` so operator shell startup files are not read under SRT.
  The SRT prelude rewrites localhost HTTP(S) proxy environment values to `127.0.0.1` and sets
  `SSL_CERT_FILE=/etc/ssl/cert.pem` only when the variable is unset. Codex remote launch runs the
  configured command after `cd <workspace>` over SSH stdio.
- Codex local SRT launch prefers the managed Unix socket for Symphony's implicit MCP server and
  writes that per-session socket directory into SRT `network.allowUnixSockets`. The MCP server
  remains token-authenticated.
- Codex local launch prefers a managed Unix socket for Symphony's implicit MCP server. If the OS
  denies managed Unix socket binding with `EPERM`, the implementation falls back to a random
  `127.0.0.1` TCP listener. Explicit Unix socket paths remain strict and surface the bind error.
- The implicit MCP server logs transport/framing failures with method, tool, request ID, payload
  byte size, MCP session ID, and transport when available. Malformed newline-delimited JSON returns
  a structured JSON-RPC parse error when the request ID can be recovered, and response-send failures
  are logged instead of silently closing the connection.
- Codex launch preserves the configured command while injecting `--config` overrides for
  `default_permissions="workspace_write"` and the generated `permissions.workspace_write.*`
  profile. Runtime launch paths render workspace-local filesystem entries with the validated
  workspace path so current Codex versions do not have to rely on the legacy `:project_roots`
  placeholder key, which current Codex CLI versions silently ignore.
  Existing user-provided Codex args, such as model overrides before `app-server`, remain present.
- Claude local launch parses `agent.command` with shell-like word splitting and runs Claude with
  `--verbose --output-format stream-json --print`, feeding prompt input over stdin from a private
  temporary file. Claude remote launch streams the prompt over SSH stdin into a remote `0600`
  temporary file before running the equivalent escaped shell command.
- Claude prompt text MUST NOT be embedded in local process argv or remote SSH argv. The Elixir
  adapter writes a local prompt file with directory mode `0700` and file mode `0600`, redirects it
  to stdin, and removes it after the turn; remote launch uses stdin to create a remote `0600`
  prompt file and cleans it up with a trap.
- Approval policy, sandbox policy, cwd, prompt input, and OPTIONAL tool declarations are supplied
  using fields supported by the configured adapter.
- The Codex adapter opts out of `turn/diff/updated`,
  `item/commandExecution/outputDelta`, and `item/fileChange/outputDelta` notifications during
  initialize so broad aggregated diffs and streaming command/file output do not overload the
  app-server stdio stream. Executor sessions also opt out of `item/agentMessage/delta`; read-only
  reviewer sessions keep those deltas enabled because Codex reviewer JSON may only be available
  through streamed text. Codex launches also receive `tool_output_token_limit=4096` so completed
  command lifecycle payloads do not echo broad command output back into the app-server stream.
  Terminal `item/completed` notifications remain enabled for command tracking, but known noisy
  string fields are compacted before forwarding to Symphony's transcript/audit pipeline. Linear
  comment create/update dynamic tools return compact acknowledgements instead of echoing full
  comment bodies back into the Codex app-server stream.

Elixir evidence: `lib/symphony_elixir/codex/app_server.ex`,
`lib/symphony_elixir/claude_code/app_server.ex`,
`test/symphony_elixir/app_server_test.exs`,
`test/symphony_elixir/core_test.exs`,
`test/symphony_elixir/claude_code/app_server_test.exs`, and
`test/symphony_elixir/ssh_test.exs`.

RECOMMENDED additional process settings:

- Max line size: 10 MB (for safe buffering)

### 10.2 Session Startup Responsibilities

Codex reference: https://developers.openai.com/codex/app-server/

Startup MUST follow the configured adapter contract. Symphony additionally requires the client to:

- Start the agent process in the per-issue workspace.
- Initialize the agent session using the configured adapter protocol when that adapter has a
  separate session startup phase.
- Create or resume a coding-agent thread according to the targeted protocol when the adapter
  supports persistent threads.
- Supply the absolute per-issue workspace path as the thread/turn working directory wherever the
  targeted protocol accepts cwd.
- Start the first turn with the rendered issue prompt.
- If the rendered first-turn prompt exceeds an implementation-defined safe transport size, the
  implementation MAY send a compact bootstrap prompt that preserves hard security instructions,
  references the current issue identifier, and instructs the agent to fetch issue description and
  comments through scoped tracker tools before planning. The compact prompt MUST keep the dispatch
  context that triggered the run (reviewer comments, CI failure details, or PR conflict metadata),
  truncating bulky payloads such as CI log excerpts instead of dropping them.
- Before the first issue-mode turn, the runtime MUST perform deterministic tracker bootstrap outside
  the model turn: move `Todo` issues to `In Progress`, then ensure a single workpad comment exists
  using `agent.workpad_heading`. If a `## Codex Workpad` or `## Claude Workpad` comment already
  exists, the runtime MUST reuse it instead of creating a duplicate.
- Start later in-worker continuation turns on the same live thread when the configured adapter
  exposes persistent thread/session context. Adapters without persistent continuation support SHOULD
  send continuation guidance and rely on workspace, workpad, and tracker state instead of assuming
  model-thread history is available.
- Supply the implementation's documented approval and sandbox policy using fields supported by the
  targeted protocol.
- Include issue-identifying metadata, such as `<issue.identifier>: <issue.title>`, when the targeted
  protocol supports turn or session titles.
- Advertise implemented client-side tools using the targeted protocol.

Session identifiers:

- Codex: extract `thread_id` from the thread identity and `turn_id` from each turn identity, then
  emit `session_id = "<thread_id>-<turn_id>"`.
- Claude: extract `session_id` from the stream-json `system` event when present.
- Reuse persistent thread/session context for continuation turns when the adapter supports it.

Current Elixir adapter behavior:

- Codex starts one app-server thread per worker run and reuses that thread for continuation turns
  until the worker run ends.
- Claude Code is launched as a CLI stream-json `--print` turn with prompt input on stdin. The current
  adapter does not pass a Symphony-managed resume/thread id between continuation turns, so
  continuation quality depends on workspace state, the issue workpad, tracker state, and the
  continuation prompt.

### 10.3 Streaming Turn Processing

The client processes agent updates according to the configured adapter protocol until the active
turn terminates.

Completion conditions:

- Targeted-protocol turn completion signal -> success
- Targeted-protocol turn failure signal -> failure
- Targeted-protocol turn cancellation signal -> failure
- turn timeout (`turn_timeout_ms`) -> failure
- repeated identical failed Codex tool/command execution threshold -> terminal human-attention block
- subprocess exit -> failure

Continuation processing:

- If the worker decides to continue after a successful turn, it SHOULD start another turn using the
  configured adapter.
- Adapters with persistent app-server sessions SHOULD keep the subprocess alive across continuation
  turns and stop it only when the worker run is ending.

Transport handling requirements:

- Follow the transport and framing rules of the configured adapter.
- For stdio-based transports, keep protocol stdout draining separate from event processing, and
  keep both separate from diagnostic stderr handling unless the targeted protocol specifies
  otherwise.

### 10.4 Emitted Runtime Events (Upstream to Orchestrator)

The agent adapter emits structured events to the orchestrator callback. Each event SHOULD
include:

- `event` (enum/string)
- `timestamp` (UTC timestamp)
- `codex_app_server_pid` (if available)
- OPTIONAL `usage` map (token counts)
- payload fields as needed

Important emitted events include, for example:

- `session_started`
- `startup_failed`
- `turn_completed`
- `turn_failed`
- `turn_cancelled`
- `turn_ended_with_error`
- `turn_input_required`
- `approval_auto_approved`
- `unsupported_tool_call`
- `notification`
- `other_message`
- `malformed`

### 10.5 Approval, Tool Calls, and User Input Policy

Approval, sandbox, and user-input behavior is implementation-defined.

Policy requirements:

- Each implementation MUST document its chosen approval, sandbox, and operator-confirmation
  posture.
- Approval requests and user-input-required events MUST NOT leave a run stalled indefinitely. An
  implementation MAY either satisfy them, surface them to an operator, auto-resolve them, or
  fail the run according to its documented policy.

Example high-trust behavior:

- Auto-approve command execution approvals for the session.
- Auto-approve file-change approvals for the session.
- Treat user-input-required turns as hard failure.

Unsupported dynamic tool calls:

- Supported dynamic tool calls that are explicitly implemented and advertised by the runtime SHOULD
  be handled according to their extension contract.
- If the agent requests a dynamic tool call that is not supported, return a tool failure response
  using the targeted protocol and continue the session.
- This prevents the session from stalling on unsupported tool execution paths.

Optional client-side tool extension:

- An implementation MAY expose a limited set of client-side tools to the agent session.
- Current standardized optional tools: scoped Linear tools whose protocol-facing names match
  `^[a-zA-Z0-9_-]+$`, such as `linear_get_current_issue`, `linear_get_comments`, and
  `linear_update_state`, and scoped GitHub tools such as `github_get_pull_request`,
  `github_fetch_origin`, `github_push_branch`, and `github_merge_pull_request`.
- If implemented, supported tools SHOULD be advertised to the agent session during startup using the
  protocol mechanism supported by the configured adapter.
- Unsupported tool names SHOULD still return a failure result using the targeted protocol and
  continue the session.

Scoped Linear tool extension contract:

- Purpose: expose narrow, current-issue Linear reads and writes using Symphony's configured tracker
  auth for the current session.
- Availability: only meaningful when `issues.provider == "linear"` and valid Linear auth is configured.
- Tool names MUST be safe for the targeted protocol's tool-name schema; dotted names such as
  `linear.get_current_issue` MUST NOT be advertised to Codex Responses API sessions.
- Tools MUST be scoped server-side to the current issue; prompt-supplied issue id arguments MUST be
  rejected.
- Suggested baseline tools: `linear_get_current_issue`, `linear_get_subissues`,
  `linear_get_parent_issue`, `linear_get_comments`, `linear_get_related_issues`,
  `linear_update_state`, `linear_add_comment`, `linear_update_comment`, `linear_delete_comment`,
  `linear_attach_url`, `linear_attach_file`, `linear_create_subissue`, and
  `linear_create_project_update`.
- `linear_update_state` MUST refuse `Merging` as a target, whether given by name or by state id,
  with an error saying a human has to approve. Moving an issue to `Merging` is how a human approves
  a merge (see `github_merge_pull_request`), so an agent cannot approve its own merge. Humans keep
  setting `Merging` from Linear. Other transitions are unaffected.
- `linear_create_subissue` MUST only create a child of the current issue: same team and project,
  parent set to the current issue, and the current issue's assignee, all resolved server-side. It
  MUST accept only `title`, `description`, an optional `priority`, and an optional `blocked_by`
  list of issue identifiers, and MUST reject team, project, parent, assignee, and state arguments.
  Each `blocked_by` identifier MUST name a sub-issue of the current issue (an existing child, or
  one the run created earlier); otherwise the call MUST fail with an explicit error before the
  issue is created. Accepted identifiers become `blocks` relations on the new issue, created right
  after it. The new issue MUST land in the team's `Backlog`
  state (falling back to a `backlog`-type state), never an active state, so an agent cannot start
  other agents; a human promotes it. Title and description MUST pass the same secret scan as
  comments before any Linear call. Creation MUST be capped per run (the Elixir cap is 10) with an
  explicit error past the cap, and MUST be refused when the run has no state to count against.
  The read-only reviewer scope MUST NOT advertise or execute it.
- `linear_create_project_update` MUST only post to the current issue's project, resolved
  server-side, and MUST accept only `body` and an optional `health` (`onTrack`, `atRisk`,
  `offTrack`). It MUST fail with an explicit error when the current issue has no project. The body
  MUST pass the same secret scan as comments before any Linear call. Posting MUST be capped per run
  (the Elixir cap is 1) and refused when the run has no state to count against. The read-only
  reviewer scope MUST NOT advertise or execute it.
- The standardized Linear tool surface does not include an assignee mutation tool. Implementations
  MUST NOT advertise removed legacy names such as `linear_set_assignee`.
- Linear read tools SHOULD wrap issue/comment fields in prompt-safety boundary tags before
  returning them to the agent. Comment bodies SHOULD be scanned for high-confidence secret patterns
  and redacted before wrapping.
- `linear_attach_file` uploads MUST be private by default. A prompt-facing public upload option, if
  exposed, MUST be explicit and documented as producing a world-readable CDN URL.
- Public `linear_attach_file` uploads MUST be restricted to configured safe extensions; the Elixir
  default is `.png`, `.jpg`, `.jpeg`, `.gif`, `.webp`, `.svg`, and `.pdf`.
- `linear_attach_file` MUST only read regular files inside the current workspace, reject
  secret-bearing file contents/titles before upload, and reject sensitive basenames such as `.env*`,
  `*.pem`, and `*.key` even for private uploads.
- `linear_attach_url` MUST restrict attachment URLs to configured exact HTTP(S) hosts; the Elixir
  default host allowlist is `github.com`.
- Reuse the configured Linear endpoint and auth from the active Symphony workflow/runtime config.
- Tool result semantics:
  - successful operation -> `success=true`
  - invalid input, missing auth, or transport failure -> `success=false` with an error payload
- Return the operation response or error payload as structured tool output that the model can inspect
  in-session.

Elixir evidence: `lib/symphony_elixir/agent_tools/linear.ex`,
`lib/symphony_elixir/mcp_server.ex`,
`test/symphony_elixir/agent_tools_linear_test.exs`, and
`test/symphony_elixir/mcp_server_test.exs`.

Scoped GitHub tool extension contract:

- Purpose: expose narrow, current-workspace GitHub and Git operations without
  giving the agent direct access to host GitHub or SSH credential files.
- Tools MUST derive repository, branch, remote, and PR scope server-side from
  the Symphony session context; prompt-supplied repo, branch, remote, ref, or
  refspec arguments MUST be rejected.
- `github_fetch_origin`, if exposed, MUST fetch only the verified `origin`
  remote for the current workspace and MUST NOT accept prompt-supplied refspecs
  or remote names.
- `github_merge_pull_request`, if exposed, MUST merge only the current
  workspace branch's pull request, MUST refuse unless the current issue is in
  the human-approved `Merging` state, MUST refuse while any check is failing or
  pending, and MUST pin the merge to the head commit whose checks were read.
- GitHub read-only review sessions SHOULD hide GitHub tools that mutate local
  workspace Git metadata or remote GitHub state.

Elixir evidence: `lib/symphony_elixir/agent_tools/github.ex`,
`lib/symphony_elixir/codex/dynamic_tool.ex`,
`test/symphony_elixir/agent_tools_github_test.exs`, and
`test/symphony_elixir/dynamic_tool_test.exs`.

User-input-required policy:

- Implementations MUST document how targeted-protocol user-input-required signals are handled.
- A run MUST NOT stall indefinitely waiting for user input.
- A conforming implementation MAY fail the run, surface the request to an operator, satisfy it
  through an approved operator channel, or auto-resolve it according to its documented policy.
- The example high-trust behavior above fails user-input-required turns immediately.

### 10.6 Timeouts and Error Mapping

Timeouts:

- `agent.timeouts.read_ms`: request/response timeout during startup and sync requests
- `agent.timeouts.turn_ms`: total turn stream timeout
- `agent.timeouts.stall_ms`: enforced by orchestrator for runs that have not emitted a first event
- `agent.timeouts.command_ms`: Claude command/tool-use timeout after a streamed tool-use event
- `watchdog.no_progress_threshold_ms`: enforced by orchestrator based on last transcript event time

Codex app-server implementations SHOULD classify repeated consecutive identical failed
`commandExecution` completions and dynamic tool results as a terminal human-attention block rather
than a retryable run failure when `agent.limits.max_consecutive_identical_tool_failures` is greater
than zero.

Error mapping (RECOMMENDED normalized categories):

- `agent_command_not_found`
- `bash_not_found`
- `codex_not_found`
- `command_timeout`
- `empty_agent_command`
- `invalid_workspace_cwd`
- `invalid_agent_command`
- `no_result_event`
- `response_timeout`
- `turn_timeout`
- `port_exit`
  - Local Codex launch/stream exits SHOULD include a bounded tail of redirected stderr when available
    before temporary runtime-home cleanup removes the log.
  - Remote Codex launch/stream exits SHOULD include a bounded tail fetched from redirected stderr on
    the worker host when available before remote runtime-home cleanup removes the log.
- `exit_status`
  - Claude Code launch exits before a terminal stream-json result SHOULD include a bounded tail of
    non-protocol output lines when available.
- `response_error`
- `turn_failed`
- `turn_cancelled`
- `turn_input_required`

### 10.7 Agent Runner Contract

The `Agent Runner` wraps workspace + prompt + configured agent adapter.

Behavior:

1. Create/reuse workspace for issue.
2. Build prompt from workflow template.
3. Start agent session.
4. Forward agent events to orchestrator.
5. On any error, fail the worker attempt (the orchestrator will retry).

Note:

- Workspaces are intentionally preserved after successful runs.

## 11. Issue Tracker Integration Contract (Linear-Compatible)

### 11.1 REQUIRED Operations

An implementation MUST support these tracker adapter operations:

1. `fetch_candidate_issues()`
   - Return issues in configured active states for a configured project.

2. `fetch_issues_by_states(state_names)`
   - Used for startup terminal cleanup.

3. `fetch_issue_states_by_ids(issue_ids)`
   - Used for active-run reconciliation.

An implementation that reviews `breakdown` plans (Section 8, plan review rule) also supports:

4. `fetch_breakdown_history(issue_id)`
   - Return the issue's state changes (time, from state, to state) and each sub-issue's id,
     identifier, state, creation time, and latest state-change time. The Linear adapter reads up to
     50 history entries of the parent and 20 of each of up to 50 sub-issues.

### 11.2 Query Semantics (Linear)

Linear-specific requirements for `issues.provider == "linear"`:

- `issues.provider == "linear"`
- GraphQL endpoint (default `https://api.linear.app/graphql`)
- Auth token sent in `Authorization` header
- `issues.linear.scope.project_slug` maps to Linear project `slugId` when set
- `issues.linear.scope.team` maps to Linear team `key` or `id`, chosen by whether the value
  has canonical UUID shape, case-insensitively
- `issues.linear.scope.labels` maps to `labels: { some: { name: { in: [...] } } }`
- Candidate issue queries build one GraphQL `IssueFilter` variable dynamically,
  omitting unconfigured keys instead of sending null operands.
- If `issues.linear.assignee` is set, `fetch_candidate_issues()` returns only issues whose Linear
  assignee matches the configured value by adding `assignee: { id: { in: [...] } }`
  to the server-side candidate filter. The special value `"me"` resolves the current viewer ID.
- Issue-state refresh still uses the by-id query without an assignee filter and returns requested
  issues that no longer match `issues.linear.assignee`, with normalized `assigned_to_worker=false`, so
  reassignment can stop active workers.
- Issue-state refresh query uses GraphQL issue IDs with variable type `[ID!]`
- Pagination REQUIRED for candidate issues
- Page size default: `50`
- Network timeout: `30000 ms`

Important:

- Linear GraphQL schema details can drift. Keep query construction isolated and test the exact query
  fields/types REQUIRED by this specification.

A non-Linear implementation MAY change transport details, but the normalized outputs MUST match the
domain model in Section 4.

### 11.3 Normalization Rules

Candidate issue normalization SHOULD produce fields listed in Section 4.1.1.

Additional normalization details:

- `labels` -> lowercase strings
- `blocked_by` -> derived from inverse relations where relation type is `blocks`
- `sub_issues` -> derived from the issue's `children` connection (bounded page)
- `priority` -> integer only (non-integers become null)
- `created_at` and `updated_at` -> parse ISO-8601 timestamps

### 11.4 Error Handling Contract

RECOMMENDED error categories:

- `unsupported_tracker_kind`
- `missing_tracker_api_key`
- `missing_linear_scoping_filter`
- `linear_api_request` (transport failures)
- `linear_api_status` (non-200 HTTP)
- `linear_rate_limited` (Linear answered `RATELIMITED` or HTTP 429; carries the time the next probe is due)
- `linear_graphql_errors`
- `linear_unknown_payload`
- `linear_missing_end_cursor` (pagination integrity error)

Orchestrator behavior on tracker errors:

- Candidate fetch failure: log and skip dispatch for this tick.
- Running-state refresh failure: log and keep active workers running.
- Startup terminal cleanup failure: log warning and continue startup.
- Rate limit: once Linear answers `RATELIMITED` (or HTTP 429), pause all Linear requests
  process-wide for a short backoff (one minute, doubling on each consecutive rate limit up to five
  minutes). When the pause ends, let exactly one request through as a probe: if Linear accepts it,
  resume and reset the backoff; if it is rate-limited again, start the next pause. Linear's limit is
  a rolling hour, so the `x-ratelimit-*-reset` headers are shown but do not set the pause length.
  While paused, skip poll cycles, defer retries to the probe without counting an attempt, refuse
  tracker calls locally, and surface the pause in the status snapshot.
- Soft brake: record `x-ratelimit-requests-remaining` from every response and stretch the issue-poll
  interval 2x below 10% of `x-ratelimit-requests-limit` (4x below 5%) until the budget recovers.

### 11.5 Tracker Writes (Important Boundary)

Symphony does not require first-class tracker write APIs in the orchestrator.

- Ticket mutations (state transitions, comments, PR metadata) are typically handled by the coding
  agent using tools defined by the workflow prompt.
- The service remains a scheduler/runner and tracker reader.
- Workflow-specific success often means "reached the next handoff state" (for example
  `Human Review`) rather than tracker terminal state `Done`.
- If scoped Linear client-side tool extensions are implemented, they are still part of the agent
  toolchain rather than orchestrator business logic.

## 12. Prompt Construction and Context Assembly

### 12.1 Inputs

Inputs to prompt rendering:

- `workflow.prompt_template`
- normalized `issue` object
- OPTIONAL `attempt` integer (retry/continuation metadata)

### 12.2 Rendering Rules

- Render with strict variable checking.
- Render with strict filter checking.
- Convert issue object keys to strings for template compatibility.
- Preserve nested arrays/maps (labels, blockers) so templates can iterate.

### 12.3 Retry/Continuation Semantics

`attempt` SHOULD be passed to the template because the workflow prompt can provide different
instructions for:

- first run (`attempt` null or absent)
- continuation run after a successful prior session
- retry after error/timeout/stall

### 12.4 Failure Semantics

If prompt rendering fails:

- Fail the run attempt immediately.
- Let the orchestrator treat it like any other worker failure and decide retry behavior.

## 13. Logging, Status, and Observability

### 13.1 Logging Conventions

REQUIRED context fields for issue-related logs:

- `issue_id`
- `issue_identifier`

REQUIRED context for coding-agent session lifecycle logs:

- `session_id`

Message formatting requirements:

- Use stable `key=value` phrasing.
- Include action outcome (`completed`, `failed`, `retrying`, etc.).
- Include concise failure reason when present.
- Avoid logging large raw payloads unless necessary.

### 13.2 Logging Outputs and Sinks

The spec does not prescribe where logs are written (stderr, file, remote sink, etc.).

Requirements:

- Operators MUST be able to see startup/validation/dispatch failures without attaching a debugger.
- Implementations MAY write to one or more sinks.
- If a configured log sink fails, the service SHOULD continue running when possible and emit an
  operator-visible warning through any remaining sink.

### 13.3 Audit Trail

Implementations SHOULD keep a separate append-only audit stream for side effects caused on behalf
of an issue. This stream is distinct from human-readable application logs and SHOULD allow
operators to query by issue ID and date range.

Audit records SHOULD include:

- `issue_id`
- `run_id`
- `timestamp`
- `event_type`
- event-specific details for prompts, tool calls, file changes, PR actions, tracker state/comment
  actions, and token usage when available

Prompt audit records MUST NOT store full prompt bodies. They SHOULD store a prompt hash and a
short redacted preview. Configured secrets and secret environment values MUST be scrubbed before
records are written.

### 13.4 Runtime Snapshot / Monitoring Interface (OPTIONAL but RECOMMENDED)

If the implementation exposes a synchronous runtime snapshot (for dashboards or monitoring), it
SHOULD return:

- `running` (list of running session rows)
- each running row SHOULD include `turn_count`
- each running row SHOULD include `repo_key`
- `watching` (list of recently completed issues now in non-active, non-terminal states)
- each watching row SHOULD include issue identifier, current state, issue URL, last-run time, and
  final transcript replay metadata while the watch remains open
- `retrying` (list of retry queue rows)
- each retry row SHOULD include `repo_key`
- `repos` (list of repo keys observed in current snapshot rows)
- `conflicts` (list of issues that matched multiple repo routes and are excluded from dispatch)
- `awaiting_clarification` and `skipped` quality-gate rows when quality gating is enabled
- `run_history` (recent durable run records, if a durable store is enabled)
- each run-history row SHOULD include `repo_key`
- `codex_totals`
  - `input_tokens` (legacy total input bucket)
  - `uncached_input_tokens`
  - `cached_input_tokens`
  - `cache_creation_input_tokens`
  - `output_tokens`
  - `total_tokens`
  - `seconds_running` (aggregate runtime seconds as of snapshot time, including active sessions)
- `rate_limits` (latest coding-agent rate limit payload, if available)
- `pause`, `budget`, `dispatch_state`, and `workspace_lifecycle` when those extensions are enabled

Elixir implementation note: the current snapshot's `run_history` is read from the primary repo
partition, while budget hydration reads runs across all repo partitions.

RECOMMENDED snapshot error modes:

- `timeout`
- `unavailable`

### 13.4 OPTIONAL Human-Readable Status Surface

A human-readable status surface (terminal output, dashboard, etc.) is OPTIONAL and
implementation-defined.

If present, it SHOULD draw from orchestrator state/metrics only and MUST NOT be REQUIRED for
correctness. It SHOULD show the run kind, model and effort of each running and recent run.

### 13.5 Session Metrics and Token Accounting

Token accounting rules:

- Agent events can include token counts in multiple payload shapes.
- Prefer absolute thread totals when available, such as:
  - `thread/tokenUsage/updated` payloads
  - `total_token_usage` within token-count wrapper events
- Ignore delta-style payloads such as `last_token_usage` for dashboard/API totals.
- Extract token counts leniently from common field names within the selected payload.
- Track provider-neutral buckets with consistent semantics:
  - `uncached_input_tokens`: new input processed by the model
  - `cached_input_tokens`: input served from cache or cache read
  - `cache_creation_input_tokens`: input written into cache
  - `output_tokens`: generated output
- `input_tokens` MAY be exposed as a legacy total input value, but callers SHOULD prefer the
  provider-neutral buckets.
- For Codex/OpenAI payloads where `input_tokens` includes cached input, derive uncached input as
  `max(input_tokens - cached_input_tokens, 0)` unless an explicit uncached field is present.
- For Anthropic payloads, treat `input_tokens` as uncached input and preserve
  `cache_read_input_tokens` as cached input plus `cache_creation_input_tokens`.
- For absolute totals, track deltas relative to last reported totals to avoid double-counting.
- Do not treat generic `usage` maps as cumulative totals unless the event type defines them that
  way.
- Accumulate aggregate totals in orchestrator state.
- When a reviewer-agent phase is enabled, count reviewer token deltas in the aggregate run total and
  also expose reviewer-specific token totals separately for dashboards and run metadata.

Runtime accounting:

- Runtime SHOULD be reported as a live aggregate at snapshot/render time.
- Implementations MAY maintain a cumulative counter for ended sessions and add active-session
  elapsed time derived from `running` entries (for example `started_at`) when producing a
  snapshot/status view.
- Add run duration seconds to the cumulative ended-session runtime when a session ends (normal exit
  or cancellation/termination).
- Continuous background ticking of runtime totals is not REQUIRED.

Rate-limit tracking:

- Track the latest rate-limit payload seen in any agent update.
- Any human-readable presentation of rate-limit data is implementation-defined.

### 13.6 Token Budget Guardrails

The Elixir implementation supports token budget limits under `agent` in `symphony.yml`:

- `agent.max_tokens_per_issue` (positive integer or null)
  - Default: `500000`.
  - Explicit `null` disables the per-issue cap.
  - When configured, an active agent whose cumulative issue token total reaches the limit SHOULD be
    stopped without scheduling a retry.
  - The run SHOULD be recorded with an implementation-defined budget-exhausted status and enough
    issue/session/token context for operators to understand why it stopped.
  - The Elixir implementation rehydrates budget-exhausted status across restarts from durable runs
    across every repo partition. It ignores persisted budget-exhausted records when the current
    limit is raised above the recorded token total.
- `agent.max_tokens_per_day` (positive integer or null)
  - Default: `5000000`.
  - Explicit `null` disables the daily cap.
  - When configured, new dispatch SHOULD pause once the UTC-day token total reaches the limit.
  - Already-running agents SHOULD continue; the daily guardrail only gates new dispatch.
  - Daily usage SHOULD reset at the UTC day boundary.
  - The Elixir implementation rehydrates the current UTC day usage from durable runs across every
    repo partition.

Token budget enforcement depends on coding-agent token reporting. Implementations SHOULD warn, not
error, when a configured budget may not be enforceable with the configured coding-agent command.

### 13.7 Humanized Agent Event Summaries (OPTIONAL)

Humanized summaries of raw agent protocol events are OPTIONAL.

If implemented:

- Treat them as observability-only output.
- Do not make orchestrator logic depend on humanized strings.

### 13.8 OPTIONAL HTTP Server Extension

This section defines an OPTIONAL HTTP interface for observability and operational control.

If implemented:

- The HTTP server is an extension and is not REQUIRED for conformance.
- The implementation MAY serve server-rendered HTML or a client-side application for the dashboard.
- The dashboard/API MUST be observability/control surfaces only and MUST NOT become REQUIRED for
  orchestrator correctness.

Extension config:

- `dashboard.port` (integer, OPTIONAL)
  - Enables or pins the HTTP server extension, depending on implementation defaults.
  - `0` requests an ephemeral port for local development and tests.
  - CLI `--port` overrides `dashboard.port` when both are present.

Enablement (extension):

- Implementations MAY start the HTTP server by default.
- Start the HTTP server when a CLI `--port` argument is provided.
- Start the HTTP server when `dashboard.port` is present in `symphony.yml`.
- The `dashboard` top-level key owns this extension's listener settings.
- Positive `dashboard.port` values bind that port.
- Implementations SHOULD bind loopback by default (`127.0.0.1` or host equivalent) unless explicitly
  configured otherwise.
- Changes to HTTP listener settings (for example `dashboard.port`) do not need to hot-rebind;
  restart-required behavior is conformant.

#### 13.8.1 Human-Readable Dashboard (`/`)

- Host a human-readable dashboard at `/`.
- The returned document SHOULD depict the current state of the system (for example active sessions,
  retry delays, token consumption, runtime totals, recent events, and health/error indicators).
- It is up to the implementation whether this is server-generated HTML or a client-side app that
  consumes the JSON API below.

#### 13.8.2 JSON REST API (`/api/v1/*`)

Provide a JSON REST API under `/api/v1/*` for current runtime state and operational debugging.

Minimum endpoints:

- `GET /api/v1/state`
  - Returns a summary view of the current system state (running sessions, retry queue/delays,
    aggregate token/runtime totals, latest rate limits, and any additional tracked summary fields).
  - Suggested response shape:

    ```json
    {
      "generated_at": "2026-02-24T20:15:30Z",
      "counts": {
        "running": 2,
        "watching": 1,
        "conflicts": 0,
        "retrying": 1
      },
      "repos": ["web", "api"],
      "running": [
        {
          "repo_key": "web",
          "issue_id": "abc123",
          "issue_identifier": "MT-649",
          "state": "In Progress",
          "session_id": "thread-1-turn-1",
          "turn_count": 7,
          "last_event": "turn_completed",
          "last_message": "",
          "started_at": "2026-02-24T20:10:12Z",
          "last_event_at": "2026-02-24T20:14:59Z",
          "tokens": {
            "input_tokens": 1200,
            "uncached_input_tokens": 900,
            "cached_input_tokens": 250,
            "cache_creation_input_tokens": 50,
            "output_tokens": 800,
            "total_tokens": 2000
          }
        }
      ],
      "retrying": [
        {
          "repo_key": "api",
          "issue_id": "def456",
          "issue_identifier": "MT-650",
          "attempt": 3,
          "due_at": "2026-02-24T20:16:00Z",
          "error": "agent exited: turn timeout"
        }
      ],
      "finishing": {
        "slots": 2,
        "used": 1,
        "running": [{"issue_id": "jkl012", "identifier": "MT-652", "state": "Merging"}]
      },
      "slot_waiting": [
        {
          "issue_id": "mno345",
          "issue_identifier": "MT-653",
          "title": "Add the export button",
          "state": "Todo",
          "reason": "a Merging or Auto Review issue is waiting for a slot",
          "attempt": null,
          "since": "2026-02-24T20:15:30Z"
        }
      ],
      "watching": [
        {
          "repo_key": "web",
          "issue_id": "ghi789",
          "issue_identifier": "MT-651",
          "state": "In Review",
          "url": "https://linear.app/example/issue/MT-651",
          "last_ran_at": "2026-02-24T18:15:00Z",
          "seconds_since_last_run": 7230
        }
      ],
      "conflicts": [],
      "run_history": [
        {
          "repo_key": "web",
          "run_id": "abc123-1771963830000000-1",
          "issue_id": "abc123",
          "issue_identifier": "MT-649",
          "status": "success",
          "attempt": 1,
          "started_at": "2026-02-24T20:10:12Z",
          "ended_at": "2026-02-24T20:14:59Z",
          "session_id": "thread-1-turn-1",
          "workspace_path": "/tmp/symphony_workspaces/web/MT-649",
          "tokens": {
            "input_tokens": 1200,
            "uncached_input_tokens": 900,
            "cached_input_tokens": 250,
            "cache_creation_input_tokens": 50,
            "output_tokens": 800,
            "total_tokens": 2000
          }
        }
      ],
      "codex_totals": {
        "input_tokens": 5000,
        "uncached_input_tokens": 4100,
        "cached_input_tokens": 700,
        "cache_creation_input_tokens": 200,
        "output_tokens": 2400,
        "total_tokens": 7400,
        "seconds_running": 1834.2
      },
      "budget": {
        "per_issue_limit": 500000,
        "daily_limit": 5000000,
        "daily_used": 1230000,
        "daily_remaining": 3770000,
        "daily_paused": false
      },
      "rate_limits": null
    }
    ```

- `GET /api/v1/<issue_identifier>`
  - Returns issue-specific runtime/debug details for the identified issue, including any information
    the implementation tracks that is useful for debugging.
  - Issues in the `watching` list SHOULD resolve here with `status: "watching"` and a lightweight
    `watching` object containing `state`, `url`, and `last_ran_at`; they do not have active session
    fields.
  - Suggested response shape:

    ```json
    {
      "repo_key": "web",
      "issue_identifier": "MT-649",
      "issue_id": "abc123",
      "status": "running",
      "workspace": {
        "path": "/tmp/symphony_workspaces/web/MT-649"
      },
      "attempts": {
        "restart_count": 1,
        "current_retry_attempt": 2
      },
      "running": {
        "repo_key": "web",
        "session_id": "thread-1-turn-1",
        "turn_count": 7,
        "state": "In Progress",
        "started_at": "2026-02-24T20:10:12Z",
        "last_event": "notification",
        "last_message": "Working on tests",
        "last_event_at": "2026-02-24T20:14:59Z",
        "tokens": {
          "input_tokens": 1200,
          "uncached_input_tokens": 900,
          "cached_input_tokens": 250,
          "cache_creation_input_tokens": 50,
          "output_tokens": 800,
          "total_tokens": 2000
        }
      },
      "retry": null,
      "logs": {
        "codex_session_logs": [
          {
            "label": "latest",
            "path": "/var/log/symphony/codex/MT-649/latest.log",
            "url": null
          }
        ]
      },
      "recent_events": [
        {
          "at": "2026-02-24T20:14:59Z",
          "event": "notification",
          "message": "Working on tests"
        }
      ],
      "last_error": null,
      "tracked": {}
    }
    ```

  - If the issue is unknown to the current in-memory state, return `404` with an error response (for
    example `{\"error\":{\"code\":\"issue_not_found\",\"message\":\"...\"}}`).

- `GET /api/v1/repos/<repo_key>/issues/<issue_identifier>/transcript`
  - Returns transcript metadata and events for a running, retrying, or watched issue in the selected
    repository.
  - Implementations SHOULD include persisted transcript-file events plus any retained in-memory
    transcript buffer, in chronological order where possible.
  - `GET /api/v1/issues/<issue_identifier>/transcript` MAY be supported as a current/default-repository
    shortcut.
  - If no matching issue/transcript is known to the current state, return `404` with an error response.

- `POST /api/v1/refresh`
  - Queues an immediate tracker poll + reconciliation cycle (best-effort trigger; implementations
    MAY coalesce repeated requests).
  - Suggested request body: empty body or `{}`.
  - Suggested response (`202 Accepted`) shape:

    ```json
    {
      "queued": true,
      "coalesced": false,
      "requested_at": "2026-02-24T20:15:30Z",
      "operations": ["poll", "reconcile"]
    }
    ```

API design notes:

- The JSON shapes above are the RECOMMENDED baseline for interoperability and debugging ergonomics.
- Implementations MAY add fields, but SHOULD avoid breaking existing fields within a version.
- Endpoints SHOULD be read-only except for operational triggers like `/refresh`.
- Unsupported methods on defined routes SHOULD return `405 Method Not Allowed`.
- API errors SHOULD use a JSON envelope such as `{"error":{"code":"...","message":"..."}}`.
- If the dashboard is a client-side app, it SHOULD consume this API rather than duplicating state
  logic.

## 14. Failure Model and Recovery Strategy

### 14.1 Failure Classes

1. `Workflow/Config Failures`
   - Missing `symphony.yml`
   - Missing `WORKFLOW.md`
   - Invalid YAML or YAML front matter
   - Unsupported tracker kind or missing tracker credentials/project slug
   - Missing coding-agent executable

2. `Workspace Failures`
   - Workspace directory creation failure
   - Workspace population/synchronization failure (implementation-defined; can come from hooks)
   - Invalid workspace path configuration
   - Hook timeout/failure

3. `Agent Session Failures`
   - Startup handshake failure
   - Turn failed/cancelled
   - Turn timeout
   - User input requested and handled as failure by the implementation's documented policy
   - Subprocess exit
   - Stalled session (no activity)

4. `Tracker Failures`
   - API transport errors
   - Non-200 status
   - GraphQL errors
   - malformed payloads

5. `Observability Failures`
   - Snapshot timeout
   - Dashboard render errors
   - Log sink configuration failure

### 14.2 Recovery Behavior

- Dispatch validation failures:
  - Skip new dispatches.
  - Keep service alive.
  - Continue reconciliation where possible.

- Worker failures:
  - Convert to retries with exponential backoff.

- Tracker candidate-fetch failures:
  - Skip this tick.
  - Try again on next tick.

- Reconciliation state-refresh failures:
  - Keep current workers.
  - Retry on next tick.

- Dashboard/log failures:
  - Do not crash the orchestrator.

### 14.3 Partial State Recovery (Restart)

Scheduler decisions remain owned by the live orchestrator process, but implementations MAY persist
retry queue rows, run history, session metadata, and aggregate totals in a durable store.
Restart recovery means the service can resume useful operation by polling tracker state, reusing
preserved workspaces, and rehydrating persisted retry queue entries. It does not mean live worker
processes survive process restart.

After restart:

- Retry timers SHOULD be re-created from durable retry queue rows when a durable store is enabled.
- Previously running sessions are not assumed recoverable; they SHOULD remain visible in run history
  and MAY be marked failed/interrupted.
- Run history records SHOULD include the run kind and the model and effort the run started with.
  QA runs record `qa`; the pre-push reviewer runs inside the run it reviews, whose record SHOULD
  also include the reviewer's kind, model and effort.
- Service recovers by:
  - startup terminal workspace cleanup
  - durable retry queue hydration
  - fresh polling of active issues
  - re-dispatching eligible work

### 14.4 Operator Intervention Points

Operators can control behavior by:

- Editing `symphony.yml` (operator/runtime settings).
- Editing `WORKFLOW.md` (repo prompt and repo-local front matter). With the default
  `workflow_source: ref`, edits take effect once pushed to the repo's base branch; with
  `workflow_source: local`, local edits apply directly.
- `WORKFLOW.md` changes are detected by repo workflow stores and re-applied automatically without
  restart according to Section 6.2.
- Changing issue states in the tracker:
  - terminal state -> running session is stopped and workspace cleaned when reconciled
  - non-active state -> running session is stopped without cleanup
- Restarting the service for process recovery, deployment, or settings that require listener or
  supervisor rebinding.

## 15. Security and Operational Safety

### 15.1 Trust Boundary Assumption

Each implementation defines its own trust boundary.

Operational safety requirements:

- Implementations SHOULD state clearly whether they are intended for trusted environments, more
  restrictive environments, or both.
- Implementations SHOULD state clearly whether they rely on auto-approved actions, operator
  approvals, stricter sandboxing, or some combination of those controls.
- Workspace isolation and path validation are important baseline controls, but they are not a
  substitute for whatever approval and sandbox policy an implementation chooses.

### 15.2 Filesystem Safety Requirements

Mandatory:

- Workspace path MUST remain under configured workspace root.
- Coding-agent cwd MUST be the per-issue workspace path for the current run.
- Workspace directory names MUST use sanitized identifiers.

RECOMMENDED additional hardening for ports:

- Run under a dedicated OS user.
- Restrict workspace root permissions.
- Mount workspace root on a dedicated volume if possible.

### 15.3 Secret Handling

- Support `$VAR` indirection in supported `symphony.yml` and repo workflow config values.
- Do not log API tokens or secret env values.
- Validate presence of secrets without printing them.

### 15.4 Hook Script Safety

Workspace hooks are arbitrary shell scripts from `WORKFLOW.md`.

Implications:

- Hooks are fully trusted configuration.
- Hooks run inside the workspace directory.
- Hook output SHOULD be truncated in logs.
- Hook timeouts are REQUIRED to avoid hanging the orchestrator.

### 15.5 Harness Hardening Guidance

Running coding agents against repositories, issue trackers, and other inputs that can contain
sensitive data or externally-controlled content can be dangerous. A permissive deployment can lead
to data leaks, destructive mutations, or full machine compromise if the agent is induced to execute
harmful commands or use overly-powerful integrations.

Implementations SHOULD explicitly evaluate their own risk profile and harden the execution harness
where appropriate. This specification intentionally does not mandate a single hardening posture, but
implementations SHOULD NOT assume that tracker data, repository contents, prompt inputs, or tool
arguments are fully trustworthy just because they originate inside a normal workflow.

Possible hardening measures include:

- Tightening agent approval and sandbox settings described elsewhere in this specification instead
  of running with a maximally permissive configuration.
- Adding external isolation layers such as OS/container/VM sandboxing, network restrictions, or
  separate credentials beyond the built-in agent policy controls.
- Filtering which Linear issues, projects, teams, labels, or other tracker sources are eligible for
  dispatch so untrusted or out-of-scope tasks do not automatically reach the agent.
- Narrowing scoped Linear tools so they can only read or mutate data for the current issue, rather
  than exposing general workspace-wide tracker access.
- Reducing the set of client-side tools, credentials, filesystem paths, and network destinations
  available to the agent to the minimum needed for the workflow.
- Keeping agent runtime credentials/configuration readable only by the runtime process when needed,
  while denying command/tool reads of those same files through sandbox profiles.
- Preventing prompts, tracker text, and comments from becoming process-list or audit-log leaks by
  using stdin/private temporary files, redaction, truncation, and untrusted-input wrappers.
- Restricting public artifact uploads and externally visible tracker attachments by host,
  extension, path containment, and secret scanning before network transfer.

The correct controls are deployment-specific, but implementations SHOULD document them clearly and
treat harness hardening as part of the core safety model rather than an optional afterthought.

## 16. Reference Algorithms (Language-Agnostic)

### 16.1 Service Startup

```text
function start_service():
  configure_logging()
  start_observability_outputs()
  system_config = load_and_validate_symphony_yml()
  start_repo_workflow_stores(system_config.repos)
  start_repo_workflow_watchers(on_change=reload_repo_workflow)

  state = {
    repo_key: primary_repo_key(system_config.repos),
    poll_interval_ms: get_config_poll_interval_ms(),
    max_concurrent_agents: get_config_max_concurrent_agents(),
    running: {},
    claimed: set(),
    retry_attempts: {},
    completed: set(),
    completed_run_metadata: {},
    watching: {},
    conflicts: {},
    repo_poll_cache: {},
    repo_poll_due_at_ms: {},
    codex_totals: {input_tokens: 0, output_tokens: 0, total_tokens: 0, seconds_running: 0},
    codex_rate_limits: null
  }

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    fail_startup(validation)

  startup_terminal_workspace_cleanup()
  schedule_tick(delay_ms=0)

  event_loop(state)
```

### 16.2 Poll-and-Dispatch Tick

```text
on_tick(state):
  state = reconcile_running_issues(state)
  state = reconcile_watching_issues(state)

  validation = validate_dispatch_config()
  if validation is not ok:
    log_validation_error(validation)
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  buckets = tracker.poll_candidate_issue_buckets(config.repos, state.repo_poll_cache)
  if buckets failed:
    log_tracker_error()
    notify_observers()
    schedule_tick(state.poll_interval_ms)
    return state

  state.conflicts = index_by_issue_id(buckets.conflicts)

  for issue in sort_for_dispatch(buckets.dispatchable):
    if no_available_slots(state):
      break

    if should_dispatch(issue, state):
      state = dispatch_issue(issue, state, attempt=null)

  notify_observers()
  schedule_tick(state.poll_interval_ms)
  return state
```

```text
function reconcile_watching_issues(state):
  issue_ids = keys(state.completed_run_metadata) union keys(state.watching)
  issue_ids = issue_ids excluding keys(state.retry_attempts)
  if issue_ids is empty:
    return state

  refreshed = tracker.fetch_issue_states_by_ids(issue_ids)
  if refreshed failed:
    log_warning("keep watched issues")
    return state

  for issue in refreshed:
    if issue.state in terminal_states:
      state.completed.remove(issue.id)
      state.completed_run_metadata.remove(issue.id)
      state.watching.remove(issue.id)
    else if issue.state in active_states:
      state.watching.remove(issue.id)
    else if issue.state not in active_states:
      metadata = state.completed_run_metadata[issue.id] or state.watching[issue.id] or {}
      state.watching[issue.id] = {
        identifier: issue.identifier or metadata.identifier or issue.id,
        state: issue.state,
        url: issue.url or metadata.url,
        last_ran_at: metadata.last_ran_at or now_utc(),
        transcript_buffer: metadata.transcript_buffer or []
      }

  remove missing issue IDs from completed_run_metadata and watching
  return state
```

### 16.3 Reconcile Active Runs

```text
function reconcile_running_issues(state):
  state = reconcile_stalled_runs(state)

  running_ids = keys(state.running)
  if running_ids is empty:
    return state

  refreshed = tracker.fetch_issue_states_by_ids(running_ids)
  if refreshed failed:
    log_debug("keep workers running")
    return state

  for issue in refreshed:
    if issue.state in terminal_states:
      state = terminate_running_issue(state, issue.id, cleanup_workspace=true)
    else if issue.state in active_states:
      state.running[issue.id].issue = issue
    else:
      state.completed.add(issue.id)
      state.completed_run_metadata[issue.id] = {last_ran_at: now_utc()}
      state = terminate_running_issue(state, issue.id, cleanup_workspace=false)

  return state
```

```text
function watchdog_tick(state):
  if watchdog.enabled is false:
    return state

  for each (issue_id, running_entry) in state.running:
    elapsed_ms = now_utc() - running_entry.last_event_at
    if elapsed_ms >= watchdog.no_progress_threshold_ms:
      agent.stop_session(running_entry.agent_session)
      run_hook_best_effort("after_run", running_entry.workspace_path)
      emit_event("run_stuck", issue_id, {elapsed_ms})
      state = terminate_running_issue(state, issue_id, status="timeout")
      state = schedule_retry(state, issue_id, next_attempt_from(running_entry), {
        reason: "stuck",
        elapsed_ms: elapsed_ms
      })

  return state
```

### 16.4 Dispatch One Issue

```text
function dispatch_issue(issue, state, attempt):
  repo_key = issue.repo_key or state.repo_key
  run_id = new_run_id(issue.id)
  verification = null
  if config.verification.enabled:
    verification = verification_port_pool.allocate(issue, run_id, config.verification.port_allocation.range)
    if verification exhausted:
      log_warning("verification port range exhausted")
      return schedule_retry(state, issue.id, next_attempt(attempt), {
        identifier: issue.identifier,
        error: "verification port allocation exhausted"
      })

  worker = spawn_worker(
    fn -> run_agent_attempt(issue, attempt, parent_orchestrator_pid, verification, repo_key) end
  )

  if worker spawn failed:
    return schedule_retry(state, issue.id, next_attempt(attempt), {
      identifier: issue.identifier,
      error: "failed to spawn agent"
    })

  state.running[issue.id] = {
    worker_handle,
    monitor_handle,
    repo_key: repo_key,
    identifier: issue.identifier,
    issue,
    session_id: null,
    codex_app_server_pid: null,
    last_codex_message: null,
    last_codex_event: null,
    last_codex_timestamp: null,
    input_tokens: 0,
    uncached_input_tokens: 0,
    cached_input_tokens: 0,
    cache_creation_input_tokens: 0,
    output_tokens: 0,
    total_tokens: 0,
    last_reported_uncached_input_tokens: 0,
    last_reported_cached_input_tokens: 0,
    last_reported_cache_creation_input_tokens: 0,
    last_reported_output_tokens: 0,
    last_reported_total_tokens: 0,
    retry_attempt: normalize_attempt(attempt),
    started_at: now_utc()
  }

  state.claimed.add(issue.id)
  state.retry_attempts.remove(issue.id)
  return state
```

### 16.5 Worker Attempt (Workspace + Prompt + Agent)

```text
function run_agent_attempt(issue, attempt, orchestrator_channel, verification, repo_key):
  workspace = workspace_manager.create_for_issue(issue.identifier, repo_key)
  if workspace failed:
    fail_worker("workspace error")

  hook_env = verification_env(verification)

  if run_hook("before_run", workspace.path, env=hook_env) failed:
    fail_worker("before_run hook error")

  dev_server = null
  if verification and config.verification.dev_server.start_cmd:
    dev_server = dev_server.start(
      command=config.verification.dev_server.start_cmd,
      cwd=workspace.path,
      env=hook_env,
      process_group=true
    )
    if dev_server failed health check:
      run_hook_best_effort("after_run", workspace.path, env=hook_env)
      verification_port_pool.release(verification)
      fail_worker("verification_failed")

  session = agent_adapter.start_session(workspace=workspace.path)
  if session failed:
    run_hook_best_effort("after_run", workspace.path, env=hook_env)
    dev_server.stop_best_effort(dev_server)
    verification_port_pool.release(verification)
    fail_worker("agent session startup error")

  max_turns = config.agent.max_turns
  turn_number = 1

  while true:
    prompt = build_turn_prompt(workflow_template, issue, attempt, turn_number, max_turns)
    if prompt failed:
      agent_adapter.stop_session(session)
      run_hook_best_effort("after_run", workspace.path, env=hook_env)
      dev_server.stop_best_effort(dev_server)
      verification_port_pool.release(verification)
      fail_worker("prompt error")

    turn_result = agent_adapter.run_turn(
      session=session,
      prompt=prompt,
      issue=issue,
      on_message=(msg) -> send(orchestrator_channel, {agent_update, issue.id, msg})
    )

    if turn_result failed:
      agent_adapter.stop_session(session)
      run_hook_best_effort("after_run", workspace.path, env=hook_env)
      dev_server.stop_best_effort(dev_server)
      verification_port_pool.release(verification)
      fail_worker("agent turn error")

    refreshed_issue = tracker.fetch_issue_states_by_ids([issue.id])
    if refreshed_issue failed:
      agent_adapter.stop_session(session)
      run_hook_best_effort("after_run", workspace.path, env=hook_env)
      dev_server.stop_best_effort(dev_server)
      verification_port_pool.release(verification)
      fail_worker("issue state refresh error")

    issue = refreshed_issue[0] or issue

    if issue.state is not active:
      break

    if turn_number >= max_turns:
      break

    turn_number = turn_number + 1

  agent_adapter.stop_session(session)
  run_hook_best_effort("after_run", workspace.path, env=hook_env)
  dev_server.stop_best_effort(dev_server)
  verification_port_pool.release(verification)

  exit_normal()
```

### 16.6 Worker Exit and Retry Handling

```text
on_worker_exit(issue_id, reason, state):
  running_entry = state.running.remove(issue_id)
  verification_port_pool.release(running_entry.verification)
  state = add_runtime_seconds_to_totals(state, running_entry)

  if reason == normal:
    state.completed.add(issue_id)  # bookkeeping only
    state.completed_run_metadata[issue_id] = {
      identifier: running_entry.identifier,
      url: running_entry.issue.url,
      last_ran_at: now_utc()
    }
    state = schedule_retry(state, issue_id, 1, {
      identifier: running_entry.identifier,
      delay_type: continuation
    })
  else:
    state = schedule_retry(state, issue_id, next_attempt_from(running_entry), {
      identifier: running_entry.identifier,
      error: format("worker exited: %reason")
    })

  notify_observers()
  return state
```

```text
on_retry_timer(issue_id, state):
  retry_entry = state.retry_attempts.pop(issue_id)
  if missing:
    return state

  candidates = tracker.fetch_candidate_issues()
  if fetch failed:
    return schedule_retry(state, issue_id, retry_entry.attempt + 1, {
      identifier: retry_entry.identifier,
      error: "retry poll failed"
    })

  issue = find_by_id(candidates, issue_id)
  if issue is null:
    state.claimed.remove(issue_id)
    state.completed.remove(issue_id)
    state.completed_run_metadata.remove(issue_id)
    state.watching.remove(issue_id)
    return state

  if issue.state in terminal_states:
    state.claimed.remove(issue_id)
    state.completed.remove(issue_id)
    state.completed_run_metadata.remove(issue_id)
    state.watching.remove(issue_id)
    return state

  if issue.state not in active_states:
    state.claimed.remove(issue_id)
    metadata = state.completed_run_metadata[issue_id] or state.watching[issue_id] or {}
    state.watching[issue_id] = {
      identifier: issue.identifier or metadata.identifier or issue_id,
      state: issue.state,
      url: issue.url or metadata.url,
      last_ran_at: metadata.last_ran_at or now_utc()
    }
    return state

  if available_slots(state) == 0:
    state.claimed.remove(issue_id)
    state.slot_waiting[issue_id] = {
      attempt: retry_entry.attempt,
      reason: "no available orchestrator slots"
    }
    return state

  return dispatch_issue(issue, state, attempt=retry_entry.attempt)
```

## 17. Test and Validation Matrix

A conforming implementation SHOULD include tests that cover the behaviors defined in this
specification.

Validation profiles:

- `Core Conformance`: deterministic tests REQUIRED for all conforming implementations.
- `Extension Conformance`: REQUIRED only for OPTIONAL features that an implementation chooses to
  ship.
- `Real Integration Profile`: environment-dependent smoke/integration checks RECOMMENDED before
  production use.

Unless otherwise noted, Sections 17.1 through 17.7 are `Core Conformance`. Bullets that begin with
`If ... is implemented` are `Extension Conformance`.

### 17.1 Workflow and Config Parsing

- Operator config path precedence:
  - explicit `--config`/runtime path is used when provided
  - cwd default is `symphony.yml` when no explicit runtime path is provided
- Repo workflow path resolution uses `repositories[].workflow`. The CLI does not
  accept a workflow path; it is read only from `symphony.yml`.
- Repo workflow file changes are detected and trigger re-read/re-apply without restart
- Repo-scoped settings and prompt rendering select the workflow for the routed `repo_key`
- Invalid workflow reload keeps last known good effective configuration and emits an
  operator-visible error
- Missing `symphony.yml` returns typed error
- Missing `WORKFLOW.md` returns typed error
- Invalid `symphony.yml` YAML returns typed error
- Invalid YAML front matter returns typed error
- Front matter non-map returns typed error
- Config defaults apply when OPTIONAL values are missing
- `issues.provider` validation enforces currently supported kinds (`linear`, `memory`)
- `issues.linear.api_key` works (including `$VAR` indirection)
- `$VAR` resolution works for issue provider API key and path values
- `~` path expansion works
- `agent.runtime` and `agent.command` are required
- `agent.command` is preserved as a shell command string
- Codex `agent.permissions.approval_policy="never"` is rejected; `auto_approve_all` is the unattended
  auto-approval switch
- `agent.permissions.outer_sandbox.runtime="srt"` is rejected for non-Codex agents and with open network mode
- Workspace attachment public-upload extensions are normalized and validated as extensions
- Per-state concurrency override map normalizes state names and rejects invalid values
- Prompt template renders `issue`, `attempt`, `agent`, and `repo_key`
- Prompt rendering fails on unknown variables (strict mode)

### 17.2 Workspace Manager and Safety

- Deterministic workspace path per issue identifier
- Missing workspace directory is created
- Existing workspace directory is reused
- Existing non-directory path at workspace location is handled safely (replace or fail per
  implementation policy)
- OPTIONAL workspace population/synchronization errors are surfaced
- `after_create` hook runs only on new workspace creation
- `before_run` hook runs before each attempt and failure/timeouts abort the current attempt
- `after_run` hook runs after each attempt and failure/timeouts are logged and ignored
- `before_remove` hook runs on cleanup and failures/timeouts are ignored
- Workspace path sanitization and root containment invariants are enforced before agent launch
- Agent launch uses the per-issue workspace path as cwd and rejects out-of-root paths
- Shared sandbox read/write deny lists include mounted volumes, host credential stores, macOS
  admin/persistence/keychain paths, and selected agent runtime auth/config files
- Sensitive-path detection rejects obvious secret paths, mounted-volume paths, `.env*`, `*.pem`,
  and `*.key`

### 17.3 Issue Tracker Client

- Candidate issue fetch uses active states plus tracker-level and repo-level Linear selectors.
- Linear project slug queries use the specified project filter field (`slugId`).
- Per-repo candidate fetch tags returned issues with `repo_key`.
- Duplicate issue IDs across repo candidate result sets become conflict rows and are excluded from
  dispatch.
- Empty `fetch_issues_by_states([])` returns empty without API call
- Pagination preserves order across multiple pages
- Blockers are normalized from inverse relations of type `blocks`
- Labels are normalized to lowercase
- Issue state refresh by ID returns minimal normalized issues
- Issue state refresh query uses GraphQL ID typing (`[ID!]`) as specified in Section 11.2
- Error mapping for request errors, non-200, GraphQL errors, malformed payloads

### 17.4 Orchestrator Dispatch, Reconciliation, and Retry

- Dispatch sort order is stage (`Merging`, Auto Review, `Rework`, resume, `Todo`), then priority,
  then oldest creation time
- A landing run starts while every `max_total` slot and epic lane is busy, up to `finishing_max`
- No `Todo` issue is dispatched while a `Merging` issue waits for a finishing slot
- A retry that finds no slot keeps its attempt, gets no backoff, and starts on the first poll after
  a slot frees
- Each active epic reserves one lane out of `max_total`; a standalone issue cannot take a reserved
  lane while the epic's current sub-issue is in review, and the next sub-issue starts in it
- `Todo` issue with non-terminal blockers is not eligible
- `Todo` issue with terminal blockers is eligible
- `breakdown` issue with a non-terminal sub-issue is not eligible; once every sub-issue is
  terminal it is eligible
- `breakdown` parent in `In Progress` with a non-terminal sub-issue moves to the waiting state;
  an issue in the waiting state is eligible only as a `breakdown` parent whose sub-issues are all
  terminal
- `breakdown` parent moved from `In Review` to the waiting state has its `Backlog` sub-issues moved
  to `Todo` within one poll; sub-issues in other states, or moved back to `Backlog` after the
  approval, are left alone, and a re-poll moves nothing
- `breakdown` parent parked from `In Progress` to the waiting state has nothing promoted
- `breakdown` parent in `Rework` has its pre-`Rework` `Backlog` sub-issues cancelled, is not held
  by its open sub-issues, and is not dispatched until the cancel succeeds
- Active-state issue refresh updates running entry state
- Non-active state stops running agent without workspace cleanup
- Terminal state stops running agent and cleans workspace
- Reconciliation with no running issues is a no-op
- Normal worker exit schedules a short continuation retry (attempt 1)
- Abnormal worker exit increments retries with 10s-based exponential backoff
- Retry backoff cap uses configured `agent.max_retry_backoff_ms`
- Retry queue entries include attempt, due time, identifier, and error
- Completed issues in non-active, non-terminal states appear as watching rows
- Terminal completed issues are removed from watching rows
- First-turn stall detection kills never-started sessions and schedules retry
- Watchdog no-progress detection stops stuck sessions, runs `after_run`, emits `run_stuck`, and
  schedules retry
- Slot exhaustion requeues retries with explicit error reason
- If a snapshot API is implemented, it returns running rows, watching rows, retry rows, token totals,
  and rate limits
- If a snapshot API is implemented, timeout/unavailable cases are surfaced

### 17.5 Coding-Agent Adapter Client

- Launch command uses workspace cwd and follows the `agent.runtime` adapter launch semantics.
- Codex launch invokes `bash -lc <agent.command>` locally. If wrapped by SRT through
  `agent.permissions.outer_sandbox`, the local wrapper uses `bash --noprofile --norc -c`.
- Codex launch preserves configured args while injecting the generated `workspace_write`
  permission profile
- Claude launch parses `agent.command`, appends stream-json print arguments and then the run
  profile's `--model` / `--effort` (when set), feeds prompt input over
  stdin from a private temporary file, and enforces `agent.timeouts.command_ms` after streamed
  tool-use events.
- Claude prompt text is not present in local process argv or remote SSH argv
- Session startup follows the configured adapter protocol.
- Client identity/capability payloads are valid when the configured adapter protocol requires them.
- Policy-related startup payloads use the implementation's documented approval/sandbox settings
- Thread and turn identities exposed by the targeted protocol are extracted and used to emit
  `session_started`
- Request/response read timeout is enforced
- Turn timeout is enforced
- Transport framing required by the targeted protocol is handled correctly
- For stdio-based transports, stdout draining is kept separate from protocol event processing, and
  diagnostic stderr handling is kept separate from the protocol stream
- Command/file-change approvals are handled according to the implementation's documented policy
- Unsupported dynamic tool calls are rejected without stalling the session
- User input requests are handled according to the implementation's documented policy and do not
  stall indefinitely
- Usage and rate-limit telemetry exposed by the targeted protocol is extracted
- Approval, user-input-required, usage, and rate-limit signals are interpreted according to the
  targeted protocol
- If client-side tools are implemented, session startup advertises the supported tool specs using
  the configured adapter protocol
- If scoped Linear client-side tool extensions are implemented:
  - tool specs are advertised with protocol-safe names
  - removed legacy tool names such as `linear_set_assignee` are not advertised
  - prompt-supplied issue ids are rejected because tools are scoped to the current issue
  - current-issue reads, state changes, comments, and attachments execute against configured Linear
    auth
  - comment bodies returned to the agent are secret-redacted before prompt-safety wrapping
  - public file uploads require an explicit option and a configured safe extension
  - URL attachments are restricted to configured exact HTTP(S) hosts
  - invalid arguments, missing auth, and transport failures return structured failure payloads
  - unsupported tool names still fail without stalling the session

### 17.6 Observability

- Validation failures are operator-visible
- Structured logging includes issue/session context fields
- Logging sink failures do not crash orchestration
- Token/rate-limit aggregation remains correct across repeated agent updates
- If a human-readable status surface is implemented, it is driven from orchestrator state and does
  not affect correctness
- If humanized event summaries are implemented, they cover key wrapper/agent event classes without
  changing orchestrator behavior

### 17.7 CLI and Host Lifecycle

- Service CLI takes no positional arguments. Repo workflow paths are read only from `symphony.yml`.
- CLI accepts a `symphony init [--force]` subcommand that scaffolds a deterministic
  `symphony.yml`, refuses to overwrite an existing file without `--force`, and exits without
  starting the runtime.
- CLI accepts a `symphony check [--config path]` subcommand that loads `symphony.yml` and every
  configured repo `WORKFLOW.md` through the same validation the service runs at startup, without
  starting the runtime or contacting the tracker or GitHub. It exits `0` and prints
  `Config OK: <path>` when valid, and exits `1` with the error on stderr when the file is missing
  or invalid. Errors name the file and key and never print secret values.
- CLI accepts `--config path-to-symphony.yml` to select an alternate operator config.
- CLI defaults to `./symphony.yml` when `--config` is omitted.
- CLI errors when the resolved `symphony.yml` (explicit or default) does not exist.
- CLI surfaces startup failure cleanly.
- Service CLI exits with success when application starts and shuts down normally.
- Service CLI exits nonzero when startup fails or the host process exits abnormally.
- One-shot CLI mode is `symphony run <issue-identifier> [--config path] [--timeout duration] [--no-retry]`.
- One-shot mode loads `symphony.yml` and the matched repo `WORKFLOW.md` through the normal config
  and repo-route resolution path, resolves the issue through the tracker, and runs exactly one
  synchronous issue lifecycle.
- One-shot mode starts only the runtime dependencies needed by the agent path, durable run store,
  scoped tools, and verification support. It MUST NOT start the polling loop, HTTP server,
  dashboard, PR review poller, CI poller, or durable retry-queue dispatch loop.
- One-shot mode writes durable run history records with the same core fields as orchestrator-owned
  runs. It does not persist retry queue rows between attempts.
- One-shot failure retries use the same exponential backoff formula capped by
  `agent.max_retry_backoff_ms`, but are bounded within the process lifetime so exhausted retries can
  return an exit code.
- One-shot exit codes are `0` for successful run completion, `1` for agent failure after bounded
  retries, `2` for configuration or validation errors, and `124` for timeout.

### 17.8 Real Integration Profile (RECOMMENDED)

These checks are RECOMMENDED for production readiness and MAY be skipped in CI when credentials,
network access, or external service permissions are unavailable.

- A real tracker smoke test can be run with valid credentials supplied by `LINEAR_API_KEY` or a
  documented local bootstrap mechanism (for example `~/.linear_api_key`).
- Real integration tests SHOULD use isolated test identifiers/workspaces and clean up tracker
  artifacts when practical.
- A skipped real-integration test SHOULD be reported as skipped, not silently treated as passed.
- If a real-integration profile is explicitly enabled in CI or release validation, failures SHOULD
  fail that job.

## 18. Implementation Checklist (Definition of Done)

Use the same validation profiles as Section 17:

- Section 18.1 = `Core Conformance`
- Section 18.2 = `Extension Conformance`
- Section 18.3 = `Real Integration Profile`

### 18.1 REQUIRED for Conformance

- Operator config path selection supports explicit runtime path and cwd default
- `symphony.yml` loader with plain YAML map parsing
- `WORKFLOW.md` loader with YAML front matter + prompt body split
- Typed config layer with defaults and `$` resolution
- Dynamic `WORKFLOW.md` watch/reload/re-apply for config and prompt
- `repositories:` schema supports multi-repo route definitions and validation
- Polling orchestrator with single-authority mutable state
- Issue tracker client with candidate fetch + state refresh + terminal fetch
- Workspace manager with sanitized per-issue workspaces
- Workspace lifecycle hooks (`after_create`, `before_run`, `after_run`, `before_remove`)
- Hook timeout config (`hooks.timeout_ms`, default `60000`)
- Coding-agent adapter client for configured `agent.runtime`
- Agent launch command config (`agent.runtime`, `agent.command`)
- Strict prompt rendering with `issue`, `attempt`, `agent`, and `repo_key` variables
- Exponential retry queue with continuation retries after normal exit
- Configurable retry backoff cap (`agent.limits.retry_backoff_max_ms`, default 5m)
- Reconciliation that stops runs on terminal/non-active tracker states
- Workspace cleanup for terminal issues (startup sweep + active transition)
- Structured logs with `issue_id`, `issue_identifier`, and `session_id`
- Operator-visible observability (structured logs; OPTIONAL snapshot/status surface)

### 18.2 RECOMMENDED Extensions (Not REQUIRED for Conformance)

- HTTP server extension honors CLI `--port` over `dashboard.port`, uses a safe default bind host, and
  exposes the baseline endpoints/error semantics in Section 13.8 if shipped.
- Scoped Linear client-side tool extensions expose current-issue Linear reads and writes through the
  agent session using configured Symphony auth.
- Durable run store extension persists retry queue rows, run history, session metadata, and aggregate
  totals across process restarts.
- TODO: Add first-class tracker write APIs (comments/state transitions) in the orchestrator instead
  of only via agent tools.
- TODO: Add pluggable issue tracker adapters beyond Linear.

### 18.3 Operational Validation Before Production (RECOMMENDED)

- Run the `Real Integration Profile` from Section 17.8 with valid credentials and network access.
- Verify hook execution and workflow path resolution on the target host OS/shell environment.
- If the OPTIONAL HTTP server is shipped, verify the configured port behavior and loopback/default
  bind expectations on the target environment.

## Appendix A. SSH Worker Extension (OPTIONAL)

This appendix describes a common extension profile in which Symphony keeps one central
orchestrator but executes worker runs on one or more remote hosts over SSH.

Extension config:

- `workers.ssh_hosts` (list of SSH host strings, OPTIONAL)
  - When omitted, work runs locally.
- `workers.max_concurrent_agents_per_host` (positive integer, OPTIONAL)
  - Shared per-host cap applied across configured SSH hosts.

### A.1 Execution Model

- The orchestrator remains the single source of truth for polling, claims, retries, and
  reconciliation.
- `workers.ssh_hosts` provides the candidate SSH destinations for remote execution.
- Each worker run is assigned to one host at a time, and that host becomes part of the run's
  effective execution identity along with the issue workspace.
- `workspaces.root` is interpreted on the remote host, not on the orchestrator host.
- The coding-agent app-server is launched over SSH stdio instead of as a local subprocess, so the
  orchestrator still owns the session lifecycle even though commands execute remotely.
- Continuation turns inside one worker lifetime SHOULD stay on the same host and workspace.
- A remote host SHOULD satisfy the same basic contract as a local worker environment: reachable
  shell, writable workspace root, coding-agent executable, and any required auth or repository
  prerequisites.

### A.2 Scheduling Notes

- SSH hosts MAY be treated as a pool for dispatch.
- Implementations MAY prefer the previously used host on retries when that host is still
  available.
- `workers.max_concurrent_agents_per_host` is an OPTIONAL shared per-host cap across configured SSH
  hosts.
- When all SSH hosts are at capacity, dispatch SHOULD wait rather than silently falling back to a
  different execution mode.
- Implementations MAY fail over to another host when the original host is unavailable before work
  has meaningfully started.
- Once a run has already produced side effects, a transparent rerun on another host SHOULD be
  treated as a new attempt, not as invisible failover.

### A.3 Problems to Consider

- Remote environment drift:
  - Each host needs the expected shell environment, coding-agent executable, auth, and repository
    prerequisites.
- Workspace locality:
  - Workspaces are usually host-local, so moving an issue to a different host is typically a cold
    restart unless shared storage exists.
- Path and command safety:
  - Remote path resolution, shell quoting, and workspace-boundary checks matter more once execution
    crosses a machine boundary.
- Startup and failover semantics:
  - Implementations SHOULD distinguish host-connectivity/startup failures from in-workspace agent
    failures so the same ticket is not accidentally re-executed on multiple hosts.
- Host health and saturation:
  - A dead or overloaded host SHOULD reduce available capacity, not cause duplicate execution or an
    accidental fallback to local work.
- Cleanup and observability:
  - Operators need to know which host owns a run, where its workspace lives, and whether cleanup
    happened on the right machine.
