# Symphony Configuration Reference

Symphony reads operator configuration from `symphony.yml` and repo-local prompt policy from
`WORKFLOW.md`.

`symphony.yml` is plain YAML. It has no version key, no front-matter fences, and no compatibility
aliases for the pre-release schema. Old top-level keys such as `tracker`, `repos`, `workspace`,
`pr_review`, `ci`, `quality_gate`, `review_agent`, `dependencies`, `observability`, and `server`
are rejected with migration guidance.

## At A Glance

Required sections:

- `issues`
- `repositories`
- `agent`

Common optional sections:

- `workspaces`
- `pull_requests`
- `pre_push_review`
- `auto_review`
- `dashboard`
- `issue_gate`
- `watchdog`
- `dependency_audit`
- `notifications`
- `verification`
- `workers`
- `github`

Minimal config:

```yaml
issues:
  provider: linear

repositories:
  - key: my-repo
    workflow: ./WORKFLOW.md

workspaces:
  root: ~/code/workspaces

agent:
  runtime: codex
  command: codex app-server
```

## File Split

`symphony.yml` owns operator concerns: issue source, repository routing, workspaces, agent runtime,
pollers, gates, dashboard, notifications, and worker hosts.

Each repository listed in `repositories` has a `WORKFLOW.md`. That file owns repo-local prompt text
and optional front-matter keys for `hooks`, `prompts`, and `verification` overrides.

Relative repository workflow paths resolve from the directory containing `symphony.yml`.

## Top-Level Sections

### `issues`

Issue-source configuration.

```yaml
issues:
  provider: linear
  poll_interval_ms: 30000
  linear:
    endpoint: https://api.linear.app/graphql
    api_key: $LINEAR_API_KEY
    assignee: me
    scope:
      project_slug: my-project
      team: ENG
      labels: [backend]
  states:
    active: [Todo, In Progress]
    terminal: [Closed, Cancelled, Canceled, Duplicate, Done]
    waiting_on_sub_issues: Waiting on sub-tickets
```

- `provider`: `linear` or `memory`.
- `poll_interval_ms`: issue candidate polling cadence. Each scheduler tick costs roughly one Linear
  request per running, watched, and due-repo lookup (about 3 per tick with work in flight), so the
  default `30000` spends about 360 of a personal key's 2,500 requests/hour before agent tool calls.
  The dashboard's refresh line shows requests since the last poll and the budget Linear reports left.
  Below 10% of the hourly limit Symphony stretches this interval 2x (4x below 5%) until the budget
  recovers. When Linear answers `RATELIMITED`, Symphony pauses all Linear calls (polling, retries,
  agent tools) for one minute, then sends one probe request: if it succeeds, Linear calls resume; if
  not, the pause doubles, up to five minutes.
- `linear.scope`: default Linear scope. Repo routes can narrow or replace this per repo.
- `states.active`: issue states eligible for dispatch.
- `states.terminal`: states that stop active runs and allow cleanup.
- `states.waiting_on_sub_issues`: the state a `breakdown` parent waits in while its sub-tickets are
  worked, default `Waiting on sub-tickets`; `null` turns it off. It counts as active without being
  listed in `states.active`, but an issue in it is dispatched only for the close-out run, once it is
  a `breakdown` parent whose sub-tickets are all terminal. The breakdown run ends by moving the
  parent there (`linear_update_state` allows the state only for `breakdown` issues), and on every
  poll Symphony moves a `breakdown` parent it finds `In Progress` with open sub-tickets there, so
  `In Progress` only holds issues an agent is working. Create it in Linear as a started state just
  after In Progress. At startup Symphony checks the configured teams have it; when it is missing,
  Symphony logs a warning and parents keep waiting `In Progress` until restart.

For Linear, configure at least one global scope under `issues.linear.scope` or repo-level route
selector under `repositories[].route`.

### `repositories`

Repository routing and repo workflow resolution. At least one repository is required.

```yaml
repositories:
  - key: web
    workflow: ./workflows/web.md
    default: true
    base_branch: main
    route:
      team: ENG
      projects: [web-platform]
      labels: [frontend]
      assignee: me
    workspace:
      strategy: worktree
      repo: ~/code/web
      fetch_before_dispatch: true
```

- `key`: unique repo key used in dashboards, run records, and prompt context. Keys must also remain
  unique after workspace path sanitization.
- `workflow`: path to that repo's `WORKFLOW.md`; defaults to `WORKFLOW.md`.
- `workflow_source`: where the workflow is read from; `ref` (default) or `local`.
  - `ref` reads the file committed on the fetched remote base branch of the git checkout that
    contains `workflow` (`origin/<base_branch>`, or `origin/HEAD` then `origin/main` then
    `origin/master` when `base_branch` is unset). Uncommitted or unpulled edits in that checkout
    never reach a run. Symphony reads the ref at startup and again on every dispatch, after the
    pre-dispatch `git fetch origin` (it fetches the checkout itself when
    `fetch_before_dispatch` is on and the checkout is not the worktree source it already
    fetched). The committed file is copied to `<state root>/workflows/<key>/`. If the file is
    missing or invalid on the ref, Symphony logs an error and keeps the last good workflow.
    Until the ref has been read once (for example a local-only checkout with no `origin`
    remote, or an `origin` whose default branch is not `HEAD`, `main` or `master` while
    `base_branch` is unset), Symphony logs a warning and reads `workflow` from disk instead, then
    switches to the ref without a restart once it resolves. Set `base_branch`, or
    `workflow_source: local`, to settle it.
  - `local` reads `workflow` from disk and reloads it when it changes. Use it while developing
    a workflow. A `workflow` path outside any git checkout is always read this way.
- `default`: at most one repo can be the fallback route.
- `base_branch`: optional branch used for review-agent diff context and as the base a
  new worktree branches off (preferring `origin/<base_branch>`); when unset, a new
  worktree branches off the source repo's current HEAD.
- `route`: Linear team, project, label, or assignee selectors.
- `workspace`: per-repo override for workspace population.

Routing validation rejects duplicate keys, workspace-sanitized key collisions, identical routes,
ambiguous team catch-alls, multiple defaults, and multi-repo global worktree settings that do not
provide per-repo workspace overrides.

### `workspaces`

Workspace root, population defaults, attachments, and cleanup.

```yaml
workspaces:
  root: ~/code/symphony-workspaces
  strategy: clone
  repo: ~/code/source-repo
  fetch_before_dispatch: true
  attachments:
    allowed_hosts: [github.com]
    public_upload_extensions: [.png, .jpg, .jpeg, .gif, .webp, .svg, .pdf]
  cleanup:
    enabled: true
    max_age_days: 14
    interval_ms: 3600000
    min_free_bytes: 10737418240
    orphan_action: log
    trash_dir: .trash
```

Issue workspaces are created under `workspaces.root/<repo_key>/<issue_key>`. The agent cwd is always
the issue workspace, never the source repository. For SSH workers, configure `workspaces.root` as an
absolute path on the remote host; remote workspace validation rejects relative and `~` roots because
they cannot be expanded safely on the orchestrator host.

**Storage inventory and cleanup planning** are read-only today. Use the dry-run task to inspect
estimated storage use before deciding whether to archive or remove anything manually:

```bash
mix symphony.cleanup --dry-run --config /path/to/symphony.yml
```

The report includes app log usage, audit usage by day, run-store usage, workspace-root usage, the
run-store core dump directory, and known Symphony temp directory patterns such as MCP socket dirs
and per-session agent homes. Override roots explicitly when inspecting an offline install:

```bash
mix symphony.cleanup --dry-run \
  --state-root /path/to/state-root \
  --logs-root /path/to/logs-root \
  --workspace-root /path/to/workspaces \
  --temp-root /path/to/tmp
```

When `--temp-root` is omitted, Symphony scans the system temp directory and `/tmp` for known
per-session Symphony temp patterns. The task does not delete files; `--apply` is rejected until
explicit deletion controls exist.

### `agent`

Agent runtime, limits, timeouts, prompts, permissions, and MCP settings.

```yaml
agent:
  runtime: codex
  command: codex app-server
  model:
  effort:
  provider: anthropic
  run_profiles: {}
  concurrency:
    max_total: 10
    epic_lanes:
    max_by_issue_state:
      rework: 2
  limits:
    max_turns: 20
    retry_backoff_max_ms: 300000
    tokens_per_issue:
    tokens_per_day:
  prompts:
    include_project_guides: true
    project_guide_files: [AGENTS.md]
    codex_stdio_soft_limit_bytes: 65536
  permissions:
    approval_policy:
      reject:
        sandbox_approval: true
        rules: true
        mcp_elicitations: true
    filesystem:
      sandbox: workspace-write
      turn_policy:
        type: workspaceWrite
      allow_read_paths: []
      allow_write_paths: []
    network:
      mode: allowlist
      allowed_domains: []
      denied_domains: []
    outer_sandbox:
      runtime: srt
      command: srt
      enable_weaker_network_isolation: false
  mcp:
    inherit: none
    allowed_servers: []
    servers: {}
  timeouts:
    turn_ms: 3600000
    read_ms: 30000
    stall_ms: 300000
    command_ms: 600000
```

- `runtime`: `codex` or `claude`.
- `command`: command used to start the runtime adapter. For the Claude runtime,
  prefer pinning a Sonnet model (e.g. `claude --model sonnet`) over Opus when
  available — Opus burns Agent-SDK credit much faster and Sonnet is usually
  sufficient for orchestration turns. Treat this as guidance; revisit when
  Anthropic's model lineup or credit policy changes.
- `model`, `effort`, `provider`, `run_profiles`: the model, effort and provider per kind of run;
  see **Run profiles** below. Model and effort are unset by default, which leaves `command` as it
  is; the provider defaults to `anthropic`.
- `concurrency.max_total`: maximum concurrent issue workers.
- `limits.tokens_per_issue` and `limits.tokens_per_day`: explicit `null` disables that cap.
- `permissions.filesystem.allow_read_paths`: extra read-only host paths rendered into Codex
  filesystem permissions.
- `permissions.filesystem.allow_write_paths`: extra writable host paths emitted to the Claude
  runtime as `sandbox.filesystem.allowWrite`. Use it to broaden Claude Code's default writable
  set (workspace + `/tmp`) — e.g. to grant test runs access to a configured MCP socket root.
- `permissions.outer_sandbox`: optional outer sandbox wrapper, currently used for Codex SRT.

**Run profiles:**

Symphony classifies each run by kind so a cheap run (landing, a CI fix) need not use the same
model and effort as an implementation run. With the Claude runtime, each run starts Claude with
`--model <model>` / `--effort <effort>` for its kind, appended after Symphony's own flags; a field
that resolves to nothing adds no flag, so with nothing set the command is unchanged.

```yaml
agent:
  model: claude-sonnet-5-5
  effort: medium
  run_profiles:
    breakdown: { model: claude-opus-5-5, effort: xhigh }
    landing: { effort: low }
    ci_fix: { provider: openrouter, model: anthropic/claude-haiku-4.5 }
```

- `model`: default model for every run kind (string).
- `effort`: default effort: `low`, `medium`, `high`, `xhigh`, or `max`.
- `provider`: default provider that serves the model: `anthropic` (default) or `openrouter`.
  `openrouter` needs a model for every run it serves (an OpenRouter model id such as
  `anthropic/claude-haiku-4.5`) and works only with `runtime: claude`. An `openrouter` run
  starts `claude` with `ANTHROPIC_BASE_URL=https://openrouter.ai/api`,
  `ANTHROPIC_AUTH_TOKEN=<OPENROUTER_API_KEY>`, an empty `ANTHROPIC_API_KEY`, `--model <id>`, and
  `CLAUDE_CODE_SUBAGENT_MODEL=<id>` so subagents use the same model. `anthropic` runs start as
  before.
- `OPENROUTER_API_KEY` (environment variable, read from Symphony's own environment): the
  OpenRouter API key. It is never written to `symphony.yml` and reaches the agent only through
  the subprocess env, as `ANTHROPIC_AUTH_TOKEN`. When it is unset, an `openrouter` run fails
  before `claude` starts and logs `OpenRouter run cannot start: OPENROUTER_API_KEY is not set
  run_kind=<kind>`; retries work as for any other failed start. `symphony check` prints a
  warning naming the run kinds that use `openrouter` while the variable is unset.
- Model capabilities: Symphony agents need tool use, so an OpenRouter model must list `tools` in
  `supported_parameters` on OpenRouter's models API (`GET https://openrouter.ai/api/v1/models`,
  read without the key and cached in process for an hour). When `OPENROUTER_API_KEY` is set,
  `symphony check` asks that API and reports, naming the key that set the model or effort
  (`agent.run_profiles.<kind>.model`, `agent.model`, `pre_push_review.model`,
  `auto_review.model`, and the matching `effort` keys):
  - an error for a model id OpenRouter does not list, for example
    `` agent.run_profiles.landing.model: OpenRouter has no model `acme/typo` ``;
  - an error for a model without `tools`, for example
    `` agent.run_profiles.landing.model: OpenRouter model `acme/chat-only` does not support tools ``;
  - a warning when `effort` is set for a model that does not list `reasoning`.

  When the API cannot be reached, `check` prints a warning and does not fail. Before an
  OpenRouter run starts, Symphony looks the model up the same way: a model without `tools` fails
  the run before `claude` starts and logs `OpenRouter run cannot start: model <id> does not
  support tools run_kind=<kind>`; a model without `reasoning` starts without `--effort` and logs
  a warning once per model. If the lookup fails, or OpenRouter does not list the model, the run
  starts anyway and logs a warning, so an OpenRouter outage does not block work.
- `run_profiles.<kind>`: `model`, `effort` and/or `provider` for one kind of run. Kinds, first match wins:
  `final_verification` (title starts with `Final verification:`), `close_out` (`breakdown` parent
  whose sub-issues are all terminal), `breakdown` (other `breakdown` parent), `landing` (`Merging`),
  `rework` (`Rework`), `ci_fix` (continuation after red CI), `review_feedback` (continuation after
  PR review comments), and `implementation` (everything else). `pre_push_review` and `qa` name the
  pre-push reviewer and QA agent runs.
- Resolution per field: `run_profiles.<kind>` value, else `agent.model` / `agent.effort` /
  `agent.provider`, else nothing is added (provider: `anthropic`). The pre-push reviewer and the
  QA agent check their own section first: `pre_push_review.model` / `.effort` and
  `auto_review.model` / `.effort`.
- Config errors: an unknown kind under `run_profiles`, an unknown effort or provider, an unknown
  profile key, `--model` / `--effort` already in `command` while any of `model`, `effort`, or
  `run_profiles` is set, `openrouter` for a run that resolves no model, `openrouter` with a
  runtime other than `claude`, or `openrouter` with `workers.ssh_hosts` (OpenRouter runs start
  on the local host only). `symphony check` reports them and names the key that picked
  `openrouter` (`agent.run_profiles.<kind>.provider`, else `agent.provider`).
- The kind and profile are chosen once, when the run is dispatched, from the current workflow
  config: an edit applies to the next dispatch without a restart. Every continuation turn of a run
  keeps its profile. A CI fix or review feedback re-activation is a new run with its own kind.
- The run history record keeps `run_kind`, `model` and `effort`, and the dispatch log line shows
  `run_kind=… model=… effort=…` (`default` when nothing is added). The pre-push reviewer runs
  inside the run it reviews, so that run's record also keeps `reviewer_profile` next to
  `reviewer_tokens`. A QA run's record keeps its own `run_kind: qa`, `model` and `effort`.
- The web dashboard and the terminal status dashboard show the kind, model and effort of each
  running run (and its reviewer's, when the pre-push review is on) and of the recent runs.
- Codex runtime: `model` and `effort` are ignored; Codex keeps the model and reasoning effort
  from its own config (set them in `command`, for example `codex -c model_reasoning_effort=high
  app-server`). Symphony logs one warning when a run starts with a profile that resolves to a model or effort.

**Concurrency and turns:**

- `concurrency.max_total` is the global dispatch cap.
- `concurrency.epic_lanes` (default: `max_total`) is how many of those slots in-progress epics may
  reserve. An epic is a `breakdown` parent in `Waiting on sub-tickets` with at least one
  sub-ticket approved and not finished (anything but Backlog, Triage or a terminal state). Each
  one, in parent priority then age order, holds one lane: its sub-tickets run there one after
  another, and the lane stays reserved while the current part is in review or landing, so the next
  part starts as soon as it is unblocked. Epics beyond the lane count wait their turn. The slots
  left over are shared, by priority then age, for standalone tickets and for an epic's extra
  parallel sub-tickets. Set it to `max_total - 1` to always keep a slot for standalone work, or
  `0` to turn lanes off. Values outside `0..max_total` fail `symphony check`. The dashboard and
  `/api/v1/state` (`epic_lanes`) show each lane and the shared pool, and the dispatch log line
  ends with `slot=lane:<epic>` or `slot=shared`.
- `concurrency.max_by_issue_state` can cap work independently for specific issue states such as
  `rework`.
- `limits.max_turns` caps how many back-to-back turns Symphony will run in a single worker
  invocation when a turn completes but the issue is still active. Codex reuses one `threadId`
  across these turns; Claude relaunches per turn (workspace + prompt provide continuation).
- `timeouts.command_ms` caps a single shell command. Set `0` to disable.

**Token budgets:**

- `limits.tokens_per_issue` (default `500000`) and `limits.tokens_per_day` (default `5000000`,
  UTC-aligned) are guardrails. Raise either to a larger positive integer, or set to `null` to
  disable.
- The per-issue cap stops only the over-budget issue without retrying; the daily cap pauses new
  dispatch for the day while already-running agents continue.
- Codex app-server and Claude stream-json usage events are normalized into uncached input, cached
  input, cache-creation input, and output buckets. Symphony warns if a budget is active with a
  command that may not report token usage.
- The dashboard surfaces daily usage, daily remaining headroom, and per-issue usage. Cached,
  cache-created, fresh input, and output tokens are shown separately when reported.

**Project guides:**

- `prompts.include_project_guides` defaults to `true`. Set it to `false` to omit the injected
  `## Project conventions` prompt section.
- `prompts.project_guide_files: null` uses the runner default: `["CLAUDE.md"]` for Claude, `[]`
  for Codex. Codex keeps relying on native workspace `AGENTS.md` discovery unless an explicit list
  is configured.
- Explicit entries must be relative workspace paths and cannot contain `..`. Missing files are
  skipped. `@path` import lines are resolved recursively inside the workspace with size, depth, and
  file-count caps.
- `prompts.codex_stdio_soft_limit_bytes` defaults to `65536`. Codex first-turn prompts larger than
  this (in bytes) are replaced by a compact bootstrap prompt (see **Codex prompt transport** below).
  Lower it if SRT-sandboxed Codex sessions still hit app-server stdout transport failures; the value
  must be greater than `0`.

**Network access:**

| `permissions.network.mode` | Behavior |
| --- | --- |
| `allowlist` (default) | Codex sandbox network switch on, with a thread-level allow map: Symphony built-in dev domains + `allowed_domains` - `denied_domains`. |
| `open` | Codex sandbox network switch on without a Symphony-managed overlay (broad `networkAccess: true`). Rejected when SRT is enabled. |
| `block` | Codex sandbox network switch off (`networkAccess: false`). |

`denied_domains` always wins over built-in and user-provided `allowed_domains`.

#### Codex-specific: sandbox

These keys are Codex-only and use safer defaults when omitted:

| Key | Default | Notes |
| --- | --- | --- |
| `agent.permissions.approval_policy` | `{"reject":{"sandbox_approval":true,"rules":true,"mcp_elicitations":true}}` | String values supported by the local Codex schema: `untrusted`, `on-failure`, `on-request`, `auto_approve_all`. Object-form `reject` is the Codex default in Symphony. The wire value `never` is **not** supported here; use `auto_approve_all` for unattended mode. |
| `agent.permissions.filesystem.sandbox` | `workspace-write` | Supported values: `read-only`, `workspace-write`, `danger-full-access`. |
| `agent.permissions.filesystem.turn_policy` | `workspaceWrite` rooted at the issue workspace | When set explicitly, Symphony still ensures the issue workspace stays in `writableRoots`, and adds the `.git` directory plus Git's `--git-dir` and `--git-common-dir` (so branch/commit/fetch/push work for clones and linked worktrees). Other policy fields depend on the targeted Codex app-server version. |
| `agent.permissions.network.mode` | `allowlist` | See table above. |
| `agent.permissions.outer_sandbox.runtime` | `none` | Optional outer SRT wrapper. |

Codex native `workspace-write` sandboxing is the default compatibility path. Symphony injects a
managed permission profile containing the sensitive read-deny list, but current Codex versions can
either fail shell execution when only that profile is used or drop it when legacy thread/turn
sandbox fields are sent. **Treat native Codex deny-list enforcement as best-effort** unless your
Codex runtime has been verified with a shell-execution probe. Use
`agent.permissions.outer_sandbox.runtime: srt` when deny rules must be enforced while shell
commands remain available.

#### Codex-specific: `outer_sandbox: srt`

An optional outer-sandbox wrapper using `@anthropic-ai/sandbox-runtime`.

- `runtime: srt` wraps the launch as
  `srt --settings <temp-settings.json> sh -c <prelude-and-agent.command-with-codex-config>`.
  The prelude rewrites localhost HTTP(S) proxy environment values to `127.0.0.1` and sets
  `SSL_CERT_FILE=/etc/ssl/cert.pem` only when it is unset.
- `command` defaults to `srt`; can be a shell-like string when a wrapper such as `mise exec -- srt`
  is needed.
- With SRT enabled, Symphony sends Codex an `externalSandbox` turn policy so SRT owns command
  sandbox enforcement (avoids nesting `sandbox-exec` inside `sandbox-exec`).
- With SRT enabled, Symphony keeps its implicit local MCP server on a managed Unix socket and
  grants SRT access only to that per-session socket directory through `network.allowUnixSockets`.
  The MCP server still requires the per-session token before accepting messages.
- Symphony prefers a managed Unix socket. If the OS denies that managed socket bind with `EPERM`,
  Symphony falls back to a random `127.0.0.1` loopback TCP port. Explicit socket paths remain
  strict and report the bind error.
- Symphony emits `enableWeakerNestedSandbox: true` for Linux/Docker compatibility.
  `enable_weaker_network_isolation` maps directly to the same SRT setting; keep it `false`
  unless required.
- Symphony generates the temporary settings file from `agent.permissions.network`,
  `agent.permissions.filesystem.allow_read_paths`, the issue workspace, linked-worktree Git
  metadata roots, and the shared sensitive-path deny lists. The file is removed when the session
  stops.
- Shell startup files such as `~/.zshrc`, `~/.zshenv`, and `~/.bash_profile` are in both the
  read-deny and write-deny lists. For local SRT-wrapped Codex launches, Symphony disables shell
  startup files so the wrapper does not need profile access under SRT. Codex may still log a
  non-fatal PATH update warning when writes are blocked; Symphony does not grant access to silence
  that warning.
- `agent.permissions.network.mode: open` is **rejected** with SRT (no unrestricted domain
  wildcard). Use `allowlist` or `block`.
- **Local only:** remote SSH workers reject `runtime: srt` because the temp settings file is
  generated on the orchestrator host.
- SRT wraps the entire Codex process tree, so it cannot distinguish Codex's own credential reads
  from commands launched beneath Codex. Treat this as an additional OS guardrail, not a complete
  credential isolation boundary.

Known issue: Codex app-server stdio can fail under SRT with
`codex_app_server_transport::transport::stdio: Failed to write to stdout: Resource temporarily unavailable (os error 35)`.
This has been observed around bursty/larger app-server protocol frames, often while SRT-wrapped
Codex is also logging network-side failures. Symphony drains stdout in a dedicated process and
compacts noisy notification fields after decoding, but it cannot compact or retry a frame that
Codex fails to write before Symphony receives it. For stability-sensitive runs, prefer disabling
SRT for Codex until Codex/SRT stdio behavior is hardened. Debug logs include `Codex stdout frame`
entries with raw byte counts, method, item type/status, and noisy-field byte counts to correlate
the last successfully received frames before a stdio write failure.

#### `agent.mcp`

Controls which MCP servers the agent can reach. Symphony always exposes its built-in `symphony`
MCP server; every other server is gated by this section.

| Key | Description |
| --- | --- |
| `inherit` (default `none`) | `none` ignores the host runtime config. `allowlist` inherits servers named in `allowed_servers` (requires non-empty list). `all` inherits every host server except `symphony` - **Codex only**, rejected for Claude. |
| `allowed_servers` | Only meaningful with `inherit: allowlist`. Setting it with `none` or `all` is rejected. |
| `servers` | Map of `name` to declaration. Reserved name: `symphony`. |

Per-server declaration:

| Key | Type | Notes |
| --- | --- | --- |
| `transport` | string, default `stdio` | `stdio` \| `http` \| `sse`. **`http`/`sse` with `codex` in `runtimes` is rejected.** |
| `command`, `args`, `env` | strings / list / map | Required for `stdio`. `env` is a map of string keys/values. |
| `url`, `headers` | string / map | Required for `http` and `sse`. |
| `runtimes` | list, default `["claude", "codex"]` | Restricts which runtimes the server is published to. `runtimes: ["claude"]` is the typical way to expose HTTP/SSE MCP to Claude without violating Codex's stdio invariant. |

**Env-var expansion** in `env` and `headers`: a value that is exactly `$NAME` (where `NAME` matches
`[A-Za-z_][A-Za-z0-9_]*`) is resolved from the orchestrator's environment at config-load time.
A set var substitutes the value; an empty var drops the entry; a missing var keeps the literal
`$NAME` (so misconfigurations surface at the MCP server's own startup). Embedded references
(`"Bearer $TOKEN"`) are **not** expanded - use a whole-value reference or pre-compose the literal.

**Runtime-specific wiring:**

- **Codex:** Symphony writes a fresh `CODEX_HOME` per session containing a generated `config.toml`
  (symphony + inherited + declared servers) and a symlink to the operator's `~/.codex/auth.json`
  when present (skipped with a warning if missing). If the operator has a Codex
  `cloud-requirements-cache.json`, Symphony copies it into the temporary home so Codex can load
  workspace-managed policy requirements. If Codex refreshes that cache during the session, Symphony
  syncs the fresher copy back to the operator's Codex home before deleting the temporary home. The
  generated path is added to the sandbox filesystem deny-read list so the agent cannot read its own
  `auth.json`/`config.toml`/`AGENTS.md`/cloud requirements cache. Remote workers also receive a
  per-session `/tmp/symphony-codex-home-<id>` directory; Symphony tears both down at session stop.
- **Codex prompt transport:** when the fully rendered first-turn prompt is larger than Symphony's
  app-server stdio soft limit (`agent.prompts.codex_stdio_soft_limit_bytes`, default 65536),
  Symphony sends a compact bootstrap prompt instead. The compact
  prompt keeps the hard security rules and directs Codex to load issue details through scoped
  `linear_*` tools, preventing large echoed `userMessage` events from wedging the app-server
  stdout stream. Symphony also injects Codex-only guidance to run noisy validation commands
  through a log file and print only the exit status plus a short tail, reducing the chance that
  large `aggregatedOutput` events hit Codex app-server stdio write limits. Symphony also injects
  `tool_output_token_limit=4096` into Codex launches so completed command lifecycle payloads stay
  below the app-server's practical stdio frame size. During initialize, Symphony opts out of Codex
  `turn/diff/updated`, `item/commandExecution/outputDelta`, and `item/fileChange/outputDelta`
  notifications, whose aggregated diffs and streaming output can become too large for the stdio
  stream on broad changes. Symphony drains the app-server stdout port in a dedicated process before
  decoding and transcript/audit handling so slow event callbacks do not block the OS pipe. Executor
  sessions additionally opt out of `item/agentMessage/delta`; read-only reviewer sessions keep
  agent-message deltas enabled so reviewer JSON can still be reconstructed from streamed text.
  Terminal `item/completed` notifications remain enabled for command tracking, and Symphony
  compacts known noisy string fields before forwarding them to the transcript/audit pipeline.
  Linear comment create/update dynamic tools return compact acknowledgements rather than echoing
  full comment bodies back into Codex.
- **Codex remote workers:** `inherit: allowlist` and `inherit: all` are rejected (Symphony only
  reads the orchestrator's host config). Declare servers explicitly under `servers`.
- **Claude:** `inherit: allowlist` reads only the top-level `mcpServers` map in
  `~/.claude.json`. Plugin MCP (`~/.claude/plugins/*/.mcp.json`), project `.mcp.json`, and
  `.claude/settings.json` enable/disable semantics are excluded. Declare those servers explicitly
  when needed.

### `pull_requests`

PR review polling, review-comment handling, CI polling, and learning capture.

```yaml
pull_requests:
  enabled: true
  poll_interval_ms: 30000
  review_comments:
    rework_delay_minutes: 1
    stale_after_days: 7
    ignored_reviewers: []
    reply_after_addressing: true
    request_review_after_push: false
  checks:
    enabled: true
    log_excerpt_lines: 200
    retry_failed_once: true
    max_fix_attempts: 3
    escalate_to_state: In Review
  learnings:
    enabled: false
    provider: anthropic
    model: claude-haiku-4-5-20251001
    max_total_per_repo: 500
    max_per_run: 3
```

- `enabled: true` enables PR review polling.
- `enabled: false` keeps tracker-state-driven review behavior.
- `poll_interval_ms` is shared by PR review polling and CI polling when checks are enabled.
- PR polling detects GitHub merge-conflict signals, deduplicates by head/base identity, and injects
  conflict-resolution context into the next prompt. The agent still owns the merge resolution.
- `review_comments.ignored_reviewers` skips those accounts entirely. Comments from the PR author
  and the current `gh` user still count as review feedback, so your own review comments on an
  agent PR send the issue back to work on the same PR. Symphony ends every PR comment it posts
  with a hidden `<!-- symphony:agent -->` marker and skips those.
- `checks.retry_failed_once` retries one likely-flaky failure before escalating.
- `checks.max_fix_attempts` bounds automated CI rework.

### `pre_push_review`

Optional reviewer pass before pushing agent work.

```yaml
pre_push_review:
  enabled: true
  runtime: codex
  command: codex app-server
  model: claude-opus-5-5
  effort: high
  max_iterations: 1
  run_on: always
```

`model` and `effort` (optional) set the reviewer's `--model` / `--effort` with the Claude runtime.
Each one falls back to `agent.run_profiles.pre_push_review`, then `agent.model` / `agent.effort`;
with none set the reviewer command is unchanged. They take the same values as `agent.model` /
`agent.effort`, and `command` must not pass `--model` / `--effort` while any of them is set.

When enabled, Symphony runs an executor/reviewer loop in the same workspace before push.
`run_on` defaults to `always`; set it to `first_push` to skip the reviewer on PR follow-up runs while keeping it enabled for initial issue runs.
Follow-up runs include explicit PR dispatches (`symphony pr`) and automatic rework runs triggered by reviewer comments, CI failures, or PR conflicts; these also omit the review-agent gate from the prompt so the agent can push and exit in a single turn.

### `auto_review`

Optional step between the PR opening and human review. Off by default; nothing changes unless you
enable it.

```yaml
auto_review:
  enabled: true
  state: Auto Review
  runtime: claude
  command: claude --dangerously-skip-permissions
  model: claude-sonnet-5-5
  effort: medium
  max_turns: 20
  timeout_ms: 1800000
  max_concurrent: 1
  max_fix_attempts: 2
  run_on: every_push
  skip_globs: []
  playbooks: {}
```

`model` and `effort` (optional) set the QA agent's `--model` / `--effort` with the Claude runtime,
falling back to `agent.run_profiles.qa`, then `agent.model` / `agent.effort`. Validation is the same
as for `pre_push_review`; when `command` is not set the QA agent uses `agent.command`, which must
then not pass the flag that `auto_review.model` / `auto_review.effort` sets.

When enabled, Symphony moves an issue whose run opened a PR to `state` (default `Auto Review`)
instead of `In Review`, and the CI poller watches it there:

- red CI sends the issue back to `In Progress` through the usual CI fix loop;
- green CI starts a QA pass on the PR head.

Agents can no longer move the issue to `In Review` themselves: `linear_update_state("In Review")`
returns "Symphony moves the issue to Auto Review once the PR is open; leave the state as it is."

#### QA passes

Before any agent runs, Symphony decides whether the PR needs QA and which playbooks apply:

| Signal | Result |
| --- | --- |
| `qa:skip` label | skipped |
| `qa:<kind>` label (for example `qa:cli`) | that playbook runs |
| only docs, tests or `skip_globs` paths changed | skipped |
| `## User walkthrough` in the ticket | `cli` playbook runs |
| a playbook's trigger paths changed | that playbook runs |
| nothing else | skipped (internal changes rely on tests and the pre-push review) |

The built-in `cli` playbook triggers on `bin/**`, `lib/symphony_elixir/cli.ex` and
`lib/mix/tasks/**`. It builds the CLI, runs the walkthrough commands with throwaway config and
state under `$TMPDIR`, and attaches a command transcript. A CLI pass typically costs 1–4 minutes
and 50–150k tokens.

The QA agent (`runtime` and `command`, defaulting to `agent.runtime` and `agent.command`) runs in
a fresh worktree at the PR head under `<workspaces.root>/.qa/`, removed afterwards. It can read
the issue, its parent and the PR, and attach evidence files with `linear_attach_file`; it cannot
move the issue, comment, push or write to GitHub. The session stops at `timeout_ms`, `max_turns`,
or `agent.limits.tokens_per_issue`.

Symphony applies its verdict:

- `pass` → `In Review`;
- `fail` → back to `In Progress` on the same PR, with the findings in the next run's prompt; after
  `max_fix_attempts` failures the issue goes to `In Review` instead;
- `blocked` (the agent could not test, crashed, or gave an unreadable answer) → `In Review` with
  the reason;
- skipped → `In Review` with the reason.

Every pass rewrites one `## Symphony QA Report` comment on the issue (Symphony's only comment
besides the agent workpad) and records a run with `kind: "qa"`, its tokens and wall time in the
run store, which the dashboard's run history shows. `qa_passed` and `qa_failed` notifications are
available for `notifications.channels[].events`.

Results are kept per PR head SHA. With `run_on: first_pass`, once a push has passed QA, later
pushes on the PR skip it. `max_concurrent` caps how many QA passes run at once.

`playbooks` overrides playbooks per kind:

```yaml
auto_review:
  playbooks:
    cli:
      paths: ["bin/**", "lib/my_app/cli.ex"]
    web:
      paths: ["assets/**"]
      prompt: |
        ### Playbook: web
        Start the dev server and check the changed pages.
```

Set `enabled: false` on a kind to turn it off.

#### macOS app QA

The built-in `macos_app` playbook tests a macOS app by building it, launching it and using it
through accessibility, the way a user would. It is off until you name the build command and the
app bundle it produces:

```yaml
auto_review:
  playbooks:
    macos_app:
      build: make -C macos app            # run in the QA worktree
      app: macos/build/Symphony.app       # relative to the repo root
      build_timeout_ms: 900000            # optional, default 15 minutes
      # paths: ["macos/Sources/**"]       # optional, default: Swift, Info.plist, xib, storyboard, xcassets
```

The QA agent's sandbox cannot build Swift, open apps or read the screen, so Symphony runs these
tools for it on the host, outside the sandbox, and checks every argument:

| Tool | Does | Refuses |
| --- | --- | --- |
| `qa_build` | runs `build` in the QA worktree with the agent's scrubbed environment, then copies the `app` bundle into a private directory | a worktree with changes outside `qa-evidence/`, gitignored files included: none may exist before the first build, and none may appear or change after a build; a bundle that resolves (symlinks included) outside the worktree, or that holds an absolute symlink or one with `..` |
| `qa_launch_app` | starts the private copy of the bundle with `SYMPHONY_BAR_QA_ROOT` set to a private directory ([QA mode](../macos/README.md#qa-mode)), and returns its PID | an executable that changed since the last `qa_build`, or a worktree `qa_build` would refuse |
| `qa_quit_app` | quits a launched app and returns its recent output | a PID it did not launch |
| `qa_screenshot` | saves the app's on-screen windows to new files `qa-evidence/<name>.png` | a PID it did not launch, a window of another app, a name that already exists (file or symlink) |
| `qa_ax_tree` | reads the accessibility tree (role, title, value, frame), filtered by `role` or `text`, capped in depth, nodes and size | a PID it did not launch |
| `qa_ax_press`, `qa_ax_set_value` | press an element (or `AXRaise` a window) and set a field's value | a PID it did not launch |

At most three launched apps run at once, and every app still running is quit when the pass ends.
Only QA agents see these tools; executor and reviewer sessions cannot list or call them.

The playbook judges a window only after it settles: it waits about 10 seconds after the window
opens, changes focus once, and then checks the sizes of the content and scroll areas in the
accessibility tree, not just the window frame. A window that opens at full height and collapses
seconds later fails, with the AX tree quoted and a screenshot attached.

The screenshot and accessibility tools use a small Swift helper that Symphony compiles once with
`swiftc` (Xcode or the Command Line Tools) into `<state root>/qa-driver/`. Bundle copies,
screenshot staging and the app's QA root live in a `0700` directory per pass under
`<state root>/qa-driver/runs/`, outside every path the agent sandbox may write, and are removed
when the pass ends.

##### One-time macOS permissions

Screenshots need **Screen Recording** and the accessibility tools need **Accessibility**, both
granted to the process that runs Symphony: `Symphony.app` when the menu bar app runs it, or the
terminal app you start `symphony` from. Grant them once:

1. Open **System Settings → Privacy & Security → Screen & System Audio Recording** and turn on
   Symphony.app (or your terminal). Use **+** to add it when it is not listed.
2. Open **System Settings → Privacy & Security → Accessibility** and do the same.
3. Restart Symphony (and the terminal, when Symphony runs from one) so the grants apply.

Without a grant the tools return `qa_permission_missing`, the QA agent answers `blocked` with the
missing permission as the reason, and the issue goes to `In Review` with that reason in the QA
report.

Auto Review needs `pull_requests.enabled: true` and `pull_requests.checks.enabled: true`, because
the CI poller is what moves issues out of the state. A PR with no CI checks stays in Auto Review.

#### Adding the Linear state

Auto Review needs a workflow state with the configured name in every Linear team Symphony works in
(`issues.linear.scope.team` and each `repositories[].route.team`; any team when none is set):

1. In Linear, open **Settings → Teams → <team> → Workflow**.
2. Under **Started**, add a state named `Auto Review` (or your `auto_review.state`).
3. Drag it between `In Progress` and `In Review`.
4. Restart Symphony.

At startup Symphony checks that the state exists. If it is missing, or if the CI poller is off,
Symphony logs `Auto Review disabled: ...` and keeps moving issues to `In Review` until the next
restart. If Linear cannot be reached for the check, Auto Review stays on.

### `issue_gate`

Optional pre-dispatch clarity gate.

```yaml
issue_gate:
  enabled: true
  provider: anthropic
  model: claude-haiku-4-5-20251001
  pass_threshold: 6
  clarification_floor: 4
  max_clarification_rounds: 2
  on_error: pass
```

The gate is disabled by default. `pass_threshold` replaces the old `min_score` spelling.

The model scores clarity, scope, ambiguity, and sandbox dependency. A user-facing issue without a
`## User walkthrough` section (numbered steps, each with the expected visible result) scores lower; see
[Writing tickets](../README.md#writing-tickets).

### `dashboard`

Live dashboard and status snapshot settings.

```yaml
dashboard:
  enabled: true
  host: 127.0.0.1
  port: 0
  refresh_ms: 1000
  render_interval_ms: 16
  snapshot_publish_ms: 500
  transcript_buffer_size: 200
```

CLI `--host` and `--port` override these listener settings.

`enabled` switches only the terminal dashboard Symphony draws on its own output. The web dashboard, the
HTTP API and the control plane stay up when it is `false`. Symphony also skips the terminal dashboard when
its output isn't a terminal (a file or a pipe). `symphony dashboard [--url <control url>]` draws the same
view in another terminal by polling `GET /api/v1/state?format=terminal&columns=<n>` on the control plane.

The dashboard also serves an Audit tab at `/audit` (filters, per-record expansion, daily hash-chain
verification, NDJSON export); the same filtered stream is available from `/api/v1/audit`.
Per-issue transcripts are available in the dashboard and as JSON at
`/api/v1/repos/<repo_key>/issues/<issue_identifier>/transcript` (or
`/api/v1/issues/<issue_identifier>/transcript` for the default repository).

**Control plane.** CLI commands (`mix symphony.pause`, `symphony.resume`, `symphony.stop`,
`symphony.pr`) reach the running daemon over a loopback HTTP control plane on the dashboard port.
Discovery is automatic: on start the daemon writes `<state-root>/control_url` and a bearer token to
`<state-root>/control_token` (both `0600`). Override either with `SYMPHONY_CONTROL_URL` or
`SYMPHONY_CONTROL_TOKEN` for remote setups (e.g. when the daemon is reverse-proxied).

### `watchdog`

Progress watchdog for stalled runs.

```yaml
watchdog:
  enabled: true
  tick_interval_ms: 60000
  no_progress_threshold_ms: 600000
```

### `dependency_audit`

Dependency policy used by the dependency audit gate.

```yaml
dependency_audit:
  allow_registries: []
  allow_git_sources: []
  allow_path_sources: []
```

### `verification`

Optional dev-server orchestration for verification runs.

```yaml
verification:
  enabled: true
  port_allocation:
    range: [4000, 4099]
  dev_server:
    start_cmd: "pnpm dev --port $SYMPHONY_VERIFICATION_PORT"
    health_check_url: "http://localhost:${SYMPHONY_VERIFICATION_PORT}/healthz"
    health_timeout_ms: 30000
    stop_signal: TERM
    stop_timeout_ms: 10000
```

`WORKFLOW.md` can override `verification.dev_server` per repo while inheriting the operator-owned
port range.

### `workers`

Remote worker host settings. Runs whose provider is `openrouter` start on the local host only, so
`openrouter` is a config error while `ssh_hosts` is set.

```yaml
workers:
  ssh_hosts: []
  max_concurrent_agents_per_host: 2
```

### `github`

GitHub integration defaults.

```yaml
github:
  enterprise_hosts: []
  failed_run_log_max_bytes: 65536
  # When the agent opens a PR without specifying a draft state, open it as a
  # draft. A human reviewer marks it ready. Set to false to open PRs ready for
  # review by default. An explicit draft argument from the agent always wins.
  open_pull_requests_as_draft: true
```

### `notifications`

Notification channels.

```yaml
notifications:
  enabled: true
  redact_titles: false
  channels:
    - kind: slack
      webhook_url: $SLACK_WEBHOOK_URL
      events: [pr_opened, awaiting_review, run_failed]
```

## `WORKFLOW.md`

Repo workflows use Markdown with optional YAML front matter:

```md
---
hooks:
  after_create: |
    git status --short
prompts:
  pr: |
    You are working on PR {{ pr.url }}.
verification:
  dev_server:
    start_cmd: "pnpm dev --port $SYMPHONY_VERIFICATION_PORT"
    health_check_url: "http://localhost:${SYMPHONY_VERIFICATION_PORT}/healthz"
---

You are working on {{ issue.identifier }}.
```

The body is the repo-specific issue prompt template. `prompts.pr` is used for explicit PR runs.
Before either rendered template, Symphony injects a managed runtime context with workspace,
untrusted-input, scoped-tool, workpad, secret-handling, and final-response rules. `WORKFLOW.md`
should add repository commands, conventions, validation gates, and handoff policy rather than
duplicating those Symphony-owned rules. The repo workflow front matter is intentionally small;
operator/runtime settings belong in `symphony.yml`.
