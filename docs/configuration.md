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
- `human_actions`
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
and optional front-matter keys for `hooks`, `prompts`, `verification`, `validation`, and
`auto_review.playbooks` overrides, and `human_actions.enabled` to turn human-action updates off for
that repository.

Relative repository workflow paths resolve from the directory containing `symphony.yml`.

## Settings in the macOS app

Every `symphony.yml` setting gets a control in the macOS app, or a person's exemption. When a
ticket adds a setting, its plan includes the control: in the same PR, or in a sub-ticket that
blocks the parent's final verification, with a `## User walkthrough` for the new control.

CI enforces it. `mix settings.ui_coverage`, part of `mix lint` (so of `make all` and the `lint`
job), lists every setting as a dotted key path from the config schema
(`SystemSchema.operator_key_paths/0`), such as `auto_review.acceptance_gate.mode` or
`repositories[].route.team` for a key of every repository. It fails, naming each key, when a key is
in neither of these:

- **The app's manifest**, `SettingsUIManifest.keyPaths` in
  `macos/Sources/SymphonyBarCore/SettingsUIManifest.swift`: the keys the Settings, Models and
  Repos sections read and write, one string literal per line. A key holding a free-form map, such
  as `agent.run_profiles`, covers everything under it. A Swift test runs every line-editor write
  and fails when one writes a key the manifest doesn't list, or the manifest lists a key no editor
  writes. The task also fails when the manifest lists a key that is not a setting.
- **The exemption file**, `config/settings_ui_exempt.yml`: entries with a `key` (a key path, or
  `prefix.*` for every key under the prefix, including later ones) or a `keys` list, a `reason`,
  and an optional `ticket` for the planned control. The task warns about an exemption that matches
  no setting or covers a key the manifest now lists, so a person can remove it.

Only a person can exempt a setting. The exemption file is an agent-protected path: the agent
sandbox denies writing it, and the `protected paths` check fails a Symphony PR whose own commits
change it until a person other than the author adds the `protected-paths-approved` label. The
acceptance gate's `:settings_ui` rule also sends a PR to a person when it adds a field to the config
schema without changing the manifest (see `docs/acceptance_gate.md`).

To add a setting: add its control to the app, list its key in the manifest, and extend the line
editor and its tests. To exempt one, a person adds it to the exemption file with the reason, in the
same PR, and labels the PR. `WORKFLOW.md` front matter (repo-owned settings) is not covered.

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
    human_review: Human Review
```

- `provider`: `linear` or `memory`. `memory` is a fake Linear for tests: it reads its issues from
  `memory.issues_file` (relative to the folder holding `symphony.yml`), a JSON list of
  `{"id", "identifier", "state", "title", "description", "labels"}` objects, on every fetch, so a test
  can change them while Symphony runs. Comments and state changes go nowhere.
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
- `states.waiting_on_sub_issues`: the state a plan ticket (label `plan`, or `breakdown`, its older
  name) waits in while its sub-tickets are
  worked, default `Waiting on sub-tickets`; `null` turns it off. It counts as active without being
  listed in `states.active`, but an issue in it is dispatched only for the close-out run, once it is
  a plan ticket whose sub-tickets are all terminal. Any other ticket whose PR merges with a
  sub-ticket still open moves here instead of `Done`, and its `Backlog` sub-tickets move to `Todo`;
  Symphony moves it to `Done` itself, with no run and a comment listing how each sub-ticket ended,
  once every sub-ticket is terminal; one a person moves here waits for them. With the state off it
  goes to `Done` on merge as before. Tickets that went `Done` before this wait existed are not
  revisited: `mix symphony.done_with_open_subtickets --config /path/to/symphony.yml` lists every
  parent in a terminal state with sub-tickets still open, without changing anything. When it cannot
  read a repository, it names that repository above the list and exits non-zero. The plan
  run ends with the parent in `In Review` and its sub-tickets in `Backlog`. A human approves the
  plan by moving the parent
  from `In Review` to this state, and on the next poll Symphony moves every sub-ticket still in
  `Backlog` to `Todo` (blocked-by links keep the order); moving the parent to `Rework` instead
  cancels the sub-tickets the rejected plan run created and re-plans. Each batch is listed
  in one comment on the parent. Agents cannot move an issue here
  (`linear_update_state` refuses it). On every poll Symphony also moves a plan ticket it
  finds `In Progress` with open sub-tickets of an approved plan here (some sub-ticket left
  `Backlog`), so `In Progress` only holds issues an agent is working, after a fresh read confirms it is still `In Progress`; that move is not an approval and
  promotes nothing, even if Symphony and the reviewer share one Linear user. Create it in Linear as a started state just
  after In Progress. At startup Symphony checks the configured teams have it; when it is missing,
  Symphony logs a warning and parents keep waiting `In Progress` until restart.

  Three ways a plan moves forward besides approval, and when each applies:
  - **Resume:** a parent in `Todo` or `In Progress` whose open sub-tickets are all still in
    `Backlog` (and none `Done`) was never approved, so it is neither held nor moved here: it gets
    a plan run that picks the plan up from its workpad, keeps every artifact and sub-ticket
    already made, files what is left and moves the parent to `In Review`. Use it after a plan run
    stopped midway, for example on Linear's usage limit.
  - **Revise:** a person's comment on a parent in `In Review` whose plan is not approved moves it
    to `In Progress`, and the plan run edits the plan in place: it rewrites the artifact
    comments, updates, files or cancels `Backlog` sub-tickets (`linear_update_subissue` refuses
    any other), replies under each comment and moves the parent back to `In Review`. Only
    `In Review` triggers it: a comment on a parent in `Human Review` starts nothing (move it to
    `Rework` or back to `In Review` instead). Symphony's own comments, a supervisor's notes
    (starting `Supervisor review:` or `Supervisor note:`) and integration bots' comments start
    nothing. A comment made while the run works
    is picked up once the parent is back in `In Review`, unless the run answered it. A comment on
    an approved plan changes nothing: under a new top-level comment Symphony replies once that, if
    it asks for a plan change, `Rework` re-plans it.
  - **Re-plan:** moving the parent to `Rework` makes the plan again from scratch, as above.

- `states.human_review`: the state a ticket waits in when only a person can move it on, default
  `Human Review`; `null` turns it off, and every such ticket goes to `In Review` as before. It
  keeps those tickets apart from the supervisor's `In Review` queue. Create it in Linear as a
  started state just after In Review; at startup Symphony checks the configured teams have it, and
  when it is missing logs a warning and sends those tickets to `In Review` until restart. It must
  not be one of `states.active`: Symphony never dispatches a ticket in it. The CI and PR review
  pollers watch its PR as they do in `In Review`, and a person's move out of it counts like one out
  of `In Review`: to `Merging` (approve), `Rework`, `states.waiting_on_sub_issues` (approve a
  plan) or `Done` (sign off a final verification). Symphony puts a ticket there instead of
  `In Review` when:
  - Auto Review QA is `blocked` and the QA agent says only a person can clear it
    (`needs_person`: a missing secret or key, a check by hand or on a device); a block the
    factory can fix (a tool missing on the QA host, a dev server that fails) still goes to
    `In Review`;
  - a `Final verification:` parent walkthrough passes, or is blocked with no failing step, and the
    QA agent says the checks left are manual;
  - an agent moves a plan ticket to `In Review` and its ticket says a human reviews the plan:
    an `auto_review.acceptance_gate.escalate.labels` label other than `plan` and `breakdown` (`needs-human`)
    or a title or description matching one of its `ticket_patterns` ("must not auto-approve",
    "human review"; naming the `Human Review` state doesn't count, see
    [What escalates](acceptance_gate.md#what-escalates));
  - an agent that posted a `linear_request_human_action` request (or found it still open) moves
    its issue to `Backlog` or `In Review`, as the blocked-access escape hatch does.

  The dashboard, `/api/v1/state` (`counts.human_review` and a `human_review` list of the watched
  tickets in it) and the menu bar show how many tickets wait there, and the human-action update
  lists them first. A supervisor moves a ticket there when it needs the operator, and never moves
  one out of it on the operator's behalf.

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
    agent:
      provider: openrouter
      model: anthropic/claude-sonnet-4.5
      run_profiles:
        breakdown: { provider: anthropic, model: claude-opus-5-5, effort: xhigh }
```

- `key`: unique repo key used in dashboards, run records, and prompt context. Keys must also remain
  unique after workspace path sanitization.
- `workflow`: path to that repo's `WORKFLOW.md`; defaults to `WORKFLOW.md`.
- `workflow_source`: where the workflow is read from; `ref` (default) or `local`.
  - `ref` reads the file committed on the fetched remote base branch of the git checkout that
    contains `workflow` (`origin/<base_branch>`, or `origin/HEAD` then `origin/main` then
    `origin/master` when `base_branch` is unset). Uncommitted or unpulled edits in that checkout
    never reach a run. Symphony reads the ref at startup, again on every dispatch after the
    pre-dispatch `git fetch origin` (it fetches the checkout itself when
    `fetch_before_dispatch` is on and the checkout is not the worktree source it already
    fetched), and before every Auto Review QA pass, after the same fetch. The committed file is copied to `<state root>/workflows/<key>/`. If the file is
    missing or invalid on the ref, Symphony logs an error and keeps the last good workflow, and
    `GET /api/v1/repos` reports the workflow as `missing` or `invalid` with that error until the
    ref loads again.
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
- `workspace`: per-repo override for workspace population (`strategy`, `repo`,
  `fetch_before_dispatch`), or `source` for a repo Symphony clones itself (see below).
- `agent`: per-repo `provider`, `model`, `effort` and `run_profiles` for issues routed to this
  repo. They take the same values as the `agent` keys and win over them field by field; see
  **Run profiles** under `agent`. Errors name the key, e.g. `repositories[web].agent.effort`.
- `acceptance_gate`: per-repo acceptance gate `mode`, `max_turns`, `timeout_ms` and `escalate`
  rules. The mode and numbers replace the global `auto_review.acceptance_gate` ones; lists add to
  them. See [`docs/acceptance_gate.md`](acceptance_gate.md).

Routing validation rejects duplicate keys, workspace-sanitized key collisions, identical routes,
ambiguous team catch-alls, multiple defaults, and multi-repo global worktree settings that do not
provide per-repo workspace overrides.

`GET /api/v1/repos` lists every repository with its source (local checkout or Symphony's clone, and
whether the clone exists yet), its GitHub repository, its route, whether its `WORKFLOW.md` is
valid, missing or invalid, its last fetch before a dispatch and the worktrees of its running agents.
See `SPEC.md` (section 13.8.2) for the response shape.

#### A repo Symphony clones itself

A repo does not need a local checkout. Set `workspace.source` to the GitHub repository instead of
`workspace.repo`, and Symphony keeps its own clone of it:

```yaml
repositories:
  - key: web
    workflow: WORKFLOW.md   # a path inside the repository
    workspace:
      source: acme/web      # or https://github.com/acme/web, git@github.com:acme/web.git
```

- The clone lives at `<workspaces.clones_root>/<owner>/<repo>`, by default
  `~/.local/share/symphony/repos/acme/web`. It has no working tree of its own. Agent worktrees and
  their `auto/<issue>` branches are made from it the way `strategy: worktree` makes them from a
  local checkout, so they live in the clone, never in a folder of yours. Symphony never reads or
  writes your own checkout of the repo, if you have one.
- Symphony clones it at startup when it is missing (and again on the next dispatch if it is
  deleted), then fetches it before every dispatch (`fetch_before_dispatch`, on by default).
  Dispatches for the same repo wait for each other's clone or fetch.
- Symphony clones over SSH, `git@github.com:<owner>/<repo>.git`, whatever form `source` is written
  in, with the SSH keys your own git uses. It runs git with credential helpers turned off, so an
  HTTPS remote could not push.
- `WORKFLOW.md` is read from the clone's fetched base branch, as with `workflow_source: ref`.
  Without `base_branch`, new worktrees branch off the fetched `origin/HEAD`.
- A failed clone or fetch fails that dispatch with an error naming the repo key, and the issue is
  retried; other repos keep running. A clone that cannot be made the first time Symphony starts
  stops startup, because the repo has no `WORKFLOW.md` to read yet. The startup error names the repo,
  the URL and folder it cloned, and git's error, and the log file keeps it too.
- `symphony check` does not clone. Before the first clone it checks the rest of the config, skips
  the repo's `WORKFLOW.md` and prints a warning saying Symphony clones the repo when it starts, so a
  repo added while Symphony runs can be applied with a restart.

Symphony rejects `source` when it is not `owner/repo` or a github.com URL, and together with
`workspace.repo`, `workspace.strategy: clone`, `workflow_source: local`, a `workflow` path outside
the repository (absolute, `~` or `..`), or `workers.ssh_hosts` (the clone stays on this machine).

Symphony's own repository needs no setting. A released app knows the commit and repository it was
built from, so a `Todo` ticket blocked by a fix merged in that repository stays in `Todo` after the
fix is `Done`, until the running app includes the fix's merge commit. The dashboard and
`/api/v1/state` say why ("waiting for an app update: TP-419 merged in `9f54098`, running
`d3d301b`"), and the menu bar shows "Update to unblock N tickets". Put the `skip-update-hold` label
on the held ticket, or on a blocker that needs no app update (a docs-only or `WORKFLOW.md` change),
to release it at `Done`. Blockers merged in other repositories, and every blocker when Symphony runs
from a checkout, release their tickets at `Done`.

### `workspaces`

Workspace root, population defaults, attachments, and cleanup.

```yaml
workspaces:
  root: ~/code/symphony-workspaces
  clones_root: ~/.local/share/symphony/repos
  strategy: clone
  repo: ~/code/source-repo
  fetch_before_dispatch: true
  git_network_timeout_ms: 300000
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

`git_network_timeout_ms` (default `300000`, 5 minutes) is the wall-clock limit of each `git fetch`,
`pull`, `push` or `ls-remote` Symphony runs on this host. At the limit Symphony stops git and the
`ssh` it started, logs an error naming the repo and command, and the call fails. Settings in the
macOS app edits it as Git network timeout, in minutes.

`clones_root` is where Symphony keeps its clones of `repositories[].workspace.source` repos
(default `~/.local/share/symphony/repos`). An agent's git commands write into that clone, so keep
it out of the agent sandbox's denied folders: not under `~/Library/Application Support`, for
example.

Issue workspaces are created under `workspaces.root/<repo_key>/<issue_key>`. The agent cwd is always
the issue workspace, never the source repository. For SSH workers, configure `workspaces.root` as an
absolute path on the remote host; remote workspace validation rejects relative and `~` roots because
they cannot be expanded safely on the orchestrator host.

Each run on the local host gets a private temp folder, `/tmp/symphony-run-<hash of the workspace>`
(Symphony's own temp folder when it can't write to `/tmp`), passed to a Claude agent as
`CLAUDE_CODE_TMPDIR` and to a Codex agent as `TMPDIR`, and writable in its sandbox. The pre-push
reviewer of the run gets it too. So the agent's `$TMPDIR` is the run's own, and concurrent runs no
longer share the `/tmp/claude-<uid>` every Claude session uses or Symphony's own temp folder. The
folder is removed when the run succeeds and kept, with a log line naming it, when the run fails, so
you can look at what the agent left there; the issue's next run starts with an empty one. A run that
can't create it logs a warning and keeps the runtime's default temp folder. Runs on a remote worker
keep that host's temp folder.

On macOS a local Claude session also gets the env that lets `swift build` and `swift test` run in
its sandbox: `DIRHELPER_USER_DIR_SUFFIX=symphony/none` and
`SWIFTPM_MODULECACHE_OVERRIDE=<temp folder>/swiftpm-module-cache` (see `docs/security.md`).

When a run on the local host ends, after the `after_run` hook, Symphony stops every process still
running in the issue workspace or the run's temp folder or started from either (by working folder
or a path on the command line), including ones the agent detached with `&`, `nohup` or `setsid`,
and the ones tied to the agent's Claude Code task folder under `/tmp/claude-<uid>/`. It sends
SIGTERM, then SIGKILL after a grace period, and logs each one with its pid, CPU time and command.
Symphony itself, and commands it is still running, are never signalled.

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
    finishing_max: 2
    force_label: expedite
    forced_max: 1
    forced_stale_after_hours: 72
    max_by_issue_state:
      rework: 2
  limits:
    max_turns: 20
    retry_backoff_max_ms: 300000
    tokens_per_issue:
    tokens_per_day:
  usage_limit:
    auto_pause: true
    resume_margin_seconds: 120
    unknown_reset_retry_seconds: 900
    headroom_utilization:
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
    mcp_tool_ms: 600000
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
  For Gradle builds, add `~/.gradle` so builds share its caches. Daemons don't come with it:
  each local agent run in a Gradle project (`gradlew`, `settings.gradle` or
  `settings.gradle.kts` at the workspace root) starts with
  `GRADLE_OPTS="-Dorg.gradle.daemon.registry.base=<workspace>/.gradle-daemons"`, so its Gradle
  daemons register in its own workspace (git ignores the folder, and the Auto Review `qa_build`
  clean check skips it) rather than in
  `~/.gradle/daemon`, where a daemon started in one agent's sandbox would serve, and fail, builds
  in another workspace. A daemon's working folder is in that registry, so the run's end stops it
  (see `workspaces` above). If `.gradle-daemons` is a symlink or a file, the run gets no
  `GRADLE_OPTS`, and Symphony only ever creates the folder's `.gitignore`, never overwrites it, so
  it never writes outside the workspace. Local hooks run outside the sandbox and build without a daemon:
  Symphony appends `-Dorg.gradle.daemon=false` to the host's `GRADLE_OPTS`. Neither applies on SSH
  workers.
  Elixir's tool caches need no entry here. Each local agent run may write one cache folder,
  `~/Library/Caches/symphony/agent` on macOS (`$XDG_CACHE_HOME/symphony/agent` or
  `~/.cache/symphony/agent` elsewhere), shared by all runs, and starts with `HEX_HOME=<folder>/hex`,
  `ELIXIR_MAKE_CACHE_DIR=<folder>/elixir_make` and `SYMPHONY_AGENT_CACHE_DIR=<folder>` (for the
  repo's own tools, such as Dialyxir's `plt_core_path`). Before each launch, Symphony copies into it
  the Hex packages, Hex registry cache (`cache.ets`) and `elixir_make` archives the host's caches
  hold and it lacks, so deps the host fetched resolve offline; the host's caches stay read-only, and
  `hex.config` is never copied, so private Hex organizations resolve only from deps a hook fetched.
  Symphony only writes plain directories in the folder, never through a link, and when the folder
  itself is not a plain directory the run gets neither the env nor the write access. Hooks and SSH
  workers keep their own env.
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
  starts `claude` with `--model <id>` and this env:
  - `ANTHROPIC_BASE_URL=https://openrouter.ai/api`;
  - `ANTHROPIC_AUTH_TOKEN=<OPENROUTER_API_KEY>`;
  - `ANTHROPIC_API_KEY=` (empty);
  - `CLAUDE_CODE_SUBAGENT_MODEL=<id>`, so subagents use the same model;
  - `ANTHROPIC_DEFAULT_SONNET_MODEL=<id>` and `ANTHROPIC_DEFAULT_OPUS_MODEL=<id>`, so Claude
    Code's model aliases use the same model instead of Anthropic's own ids, which OpenRouter does
    not know;
  - `ANTHROPIC_DEFAULT_HAIKU_MODEL` and `ANTHROPIC_SMALL_FAST_MODEL`, the model for Claude Code's
    background calls (titles, summaries): `small_model` when it is set, else `<id>`.

  `anthropic` runs start as before: Symphony sets none of these. In QA mode the base URL is the QA
  stub's instead (see [OpenRouter in QA](#qa-passes)).
- `small_model`: optional OpenRouter model id for Claude Code's background calls on runs whose
  provider is `openrouter`, for example `anthropic/claude-haiku-4.5`. Titles and summaries are
  frequent, simple calls, so a cheap model keeps them from billing at the run's model's rate.
  Unset, they use the run's model. One value for every OpenRouter run; `anthropic` runs ignore it.
  When `OPENROUTER_API_KEY` is set and a run uses `openrouter`, `symphony check` reports an id
  OpenRouter does not list, for example
  `` agent.small_model: OpenRouter has no model `acme/typo` ``. The model needs no `tools`.
  Settings in the macOS app edits it as the Background calls row of Models.
- `OPENROUTER_API_KEY` (environment variable, read from Symphony's own environment): the
  OpenRouter API key. It is never written to `symphony.yml` and reaches the agent only through
  the subprocess env, as `ANTHROPIC_AUTH_TOKEN`. When it is unset, an `openrouter` run fails
  before `claude` starts and logs `OpenRouter run cannot start: OPENROUTER_API_KEY is not set
  run_kind=<kind>`; retries work as for any other failed start. `symphony check` prints a
  warning naming the run kinds that use `openrouter` while the variable is unset.
- Model capabilities: Symphony agents need tool use, so an OpenRouter model must list `tools` in
  `supported_parameters` on OpenRouter's models API (`GET https://openrouter.ai/api/v1/models`, the
  QA stub's in QA mode, read without the key and cached in process for an hour). When `OPENROUTER_API_KEY` is set,
  `symphony check` asks that API and reports, naming the key that set the model or effort
  (`pre_push_review.model`, `auto_review.model`, `repositories[<key>].agent.run_profiles.<kind>.model`,
  `repositories[<key>].agent.model`, `agent.run_profiles.<kind>.model`, `agent.model`, and the
  matching `effort` keys; the first one set, in the order a run resolves them):
  - an error for a model id OpenRouter does not list, for example
    `` agent.run_profiles.landing.model: OpenRouter has no model `acme/typo` ``;
  - an error for a model without `tools`, for example
    `` agent.run_profiles.landing.model: OpenRouter model `acme/chat-only` does not support tools ``;
  - a warning when `effort` is set for a model that does not list `reasoning`. When the effort
    comes from a key above the one that picked the model (for example
    `repositories[api].agent.run_profiles.breakdown: { provider: openrouter, model: acme/tools-only }`
    under `agent.run_profiles.breakdown.effort: xhigh`), the warning names the model key and the
    key the effort is inherited from:
    `` repositories[api].agent.run_profiles.breakdown.model: OpenRouter model `acme/tools-only` does not support reasoning; its runs start without --effort xhigh, inherited from agent.run_profiles.breakdown.effort ``.

  When a run's model is inherited from a key above the one that picked `openrouter` (for example
  `repositories[api].agent.run_profiles.landing: { provider: openrouter }` with only `agent.model`
  set), the error names that provider key, the key the model is inherited from, and the `model` key
  to set next to it:
  `` repositories[api].agent.run_profiles.landing.provider: OpenRouter has no model `claude-sonnet-5-5`, inherited from agent.model; set repositories[api].agent.run_profiles.landing.model to an OpenRouter model id ``.

  When the API cannot be reached, `check` prints a warning and does not fail. Before an
  OpenRouter run starts, Symphony looks the model up the same way: a model without `tools` fails
  the run before `claude` starts and logs `OpenRouter run cannot start: model <id> does not
  support tools run_kind=<kind>; set <key> to a model that lists tools`, where `<key>` is the
  model key `check` names; a model without `reasoning` starts without `--effort` and logs
  a warning once per model. If the lookup fails, or OpenRouter does not list the model, the run
  starts anyway and logs a warning, so an OpenRouter outage does not block work.
- `run_profiles.<kind>`: `model`, `effort` and/or `provider` for one kind of run. Kinds, first match wins:
  `final_verification` (title starts with `Final verification:`), `breakdown` (plan ticket in
  `Rework`), `close_out` (plan ticket whose sub-issues are all terminal), `breakdown` (other
  plan ticket: a new, resumed or revised plan), `landing` (`Merging`),
  `rework` (`Rework`), `ci_fix` (continuation after red CI), `review_feedback` (continuation after
  PR review comments), and `implementation` (everything else). `pre_push_review`, `qa` and
  `acceptance_gate` name the pre-push reviewer, QA agent and acceptance gate runs.
- Resolution per field, for the repository the issue is routed to:
  `repositories[].agent.run_profiles.<kind>`, then `repositories[].agent.<field>`, then
  `agent.run_profiles.<kind>`, then `agent.<field>`, else nothing is added (provider:
  `anthropic`). A repository without an `agent` block resolves from the `agent` section alone. The
  pre-push reviewer and the QA agent check their own section first: `pre_push_review.model` /
  `.effort` and `auto_review.model` / `.effort`.
- `WORKFLOW.md` front matter cannot set any of these: `symphony.yml` owns the agent runtime, so a
  per-repository profile goes under that repository's `repositories[].agent`.
- Config errors: an unknown kind under `run_profiles`, an unknown effort or provider, an unknown
  profile key, `--model` / `--effort` already in `command` while any of `model`, `effort`, or
  `run_profiles` is set, `openrouter` for a run that resolves no model, `openrouter` with a
  runtime other than `claude`, or `openrouter` with `workers.ssh_hosts` (OpenRouter runs start
  on the local host only). `symphony check` reports them and names the key that picked
  `openrouter` (`agent.run_profiles.<kind>.provider`, else `agent.provider`). A
  `repositories[].agent` block is checked the same way against the `agent` section, including the
  `--model` / `--effort` flags in `agent.command`, `pre_push_review.command` and
  `auto_review.command`, and its errors name `repositories[<key>].agent...`.
- The kind and profile are chosen once, when the run is dispatched, from the current workflow
  config: an edit applies to the next dispatch without a restart. Every continuation turn of a run
  keeps its profile. A CI fix or review feedback re-activation is a new run with its own kind.
- The run history record keeps `run_kind`, `model` and `effort`, and the dispatch log line shows
  `run_kind=… model=… effort=…` (`default` when nothing is added). A `review_feedback` dispatch
  also names the latest pending PR comment it answers: `trigger_comment_id=…
  trigger_comment_author=… trigger_comment="<first line>" pending_comments=<n>`. The pre-push
  reviewer runs inside the run it reviews, so that run's record also keeps `reviewer_profile` next to
  `reviewer_tokens`. A QA run's record keeps its own `run_kind: qa`, `model` and `effort`.
- The web dashboard and the terminal status dashboard show the kind, model and effort of each
  running run (and its reviewer's, when the pre-push review is on) and of the recent runs.
- Codex runtime: `model` and `effort` are ignored; Codex keeps the model and reasoning effort
  from its own config (set them in `command`, for example `codex -c model_reasoning_effort=high
  app-server`). Symphony logs one warning when a run starts with a profile that resolves to a model or effort.

**Concurrency and turns:**

- `concurrency.max_total` is the global dispatch cap.
- `concurrency.epic_lanes` (default: `max_total`) is how many of those slots in-progress epics may
  reserve. An epic is a plan ticket in `Waiting on sub-tickets` with at least one
  sub-ticket approved and not finished (anything but Backlog, Triage or a terminal state). Each
  one, in parent priority then age order, holds one lane: its sub-tickets run there one after
  another, and the lane stays reserved while the current part is landing, so the next part starts
  as soon as it is unblocked. An epic whose path only waits on people (every open ticket on it is in
  review, in Backlog or Triage, a parent waiting on its sub-tickets, or a Todo held by blockers)
  yields its lane to the next epic or the shared pool, and takes one again at the next poll once a
  ticket on its path can run. The lane also runs whatever is in the way of the next
  part: sub-tickets of sub-tickets at any depth, and tickets blocking any of those (transitively,
  until Done), even when they belong to another parent. The nearest one goes first, so the epic's
  next part beats a blocker of it, and priority and age only break ties. A ticket in the way of two
  epics runs once, in whichever lane is free first. Epics beyond the lane count wait their turn.
  The slots left over are shared, in dispatch order, for standalone tickets and for an epic's extra
  parallel tickets. Set it to `max_total - 1` to always keep a slot for standalone work, or `0` to
  turn lanes off. Values outside `0..max_total` fail `symphony check`. The dashboard and
  `/api/v1/state` (`epic_lanes`) show each lane and the shared pool, with the ticket a lane runs
  and why when it is not the epic's own sub-ticket (`MT-30 (In Progress), blocks MT-12`; `via` in
  the API), and each yielded epic with why (`status: "yielded"` and `reason` in the API). The dispatch log line carries `slot=lane:<epic>`, `slot=shared`, `slot=finishing` or `slot=forced`, and `forced=true|false`.
- `concurrency.finishing_max` (default: `2`) caps landing runs (tickets in `Merging`; with
  `pull_requests.auto_merge` on, only the ones that fell back to the landing agent). They only
  finish approved work, so they don't use `max_total` slots or epic lanes and start as soon as one
  of these is free. Auto Review QA passes are capped by it too, on top of
  `auto_review.max_concurrent`. Values below `1` fail `symphony check`.
- `concurrency.force_label` (default: `expedite`) is the label a human puts on a ticket to have it
  worked now, through to Done (matched case-insensitively). Symphony records when a poll first
  sees a ticket in an active state (`tracker.active_states`) carry it (`forced_since`, kept across
  restarts); a ticket labelled in another state, such as `Backlog` or `In Review`, joins once it
  moves into an active state. Once queued it stays listed in any non-terminal state (`In Review`,
  `Merging`, ...). `/api/v1/state` lists the forced tickets (`forced`), earliest first with their
  queue `position`, `forced_for_seconds`, `stale`, a `phase` (`implementation`, `rework`,
  `review_feedback`, `ci_fix`, `waiting_on_ci`, `auto_review`, `waiting_for_human`, `landing`,
  `breakdown`, `close_out`, `final_verification`), whether an agent or QA pass is `running` for it,
  what it `waiting_on` (`slot`, `human`, `ci`, `blocker` with the open `blockers`' identifiers,
  `usage_limit`, `paused`, `backlog`, or null) and a one-line `summary` such as
  `implementation · running` or `implementation · waiting on blocker TP-12`. A forced plan
  ticket's phase is its current part's. The terminal and web dashboards show a "Forced" section
  above the running agents (identifier, phase, waiting on, forced for), a ⚡ on forced rows elsewhere,
  and the forced count over `forced_max` in the header. When a forced ticket enters `In Review`
  (for a plan ticket, its plan), Symphony sends a `forced_human_gate` notification saying it
  is waiting for your review, again each time it comes back to `In Review`. A ticket leaves the list
  at the next poll after the label is removed, it reaches a terminal state, or Linear no longer
  returns it; one that reaches a terminal state has the label removed by Symphony. The audit log
  records `forced_start` and `forced_end` (with `reason`: `label_removed`, `done` or `missing`).
  `symphony force TP-123` adds the label through the running Symphony and `symphony force --clear TP-123`
  removes it; either way the queue changes at once, without waiting for a poll (see the README).
- `concurrency.forced_max` (default: `1`) is how many forced runs may run at once on their own
  allowance; `/api/v1/state` reports it under `concurrency`. Values below `1` fail
  `symphony check`. A forced ticket goes out first, in `forced_since` order, and while fewer than
  `forced_max` forced runs are going it starts even when `max_total`, the epic lanes,
  `finishing_max`, `max_by_issue_state` are full or a finish is waiting, at the next poll. This
  covers every phase: implementation, `Rework`, CI-fix and review-feedback continuations and
  landing, an Auto Review QA pass (see QA passes below) and a `Final verification:` parent
  walkthrough. Its run is marked `forced` (`/api/v1/state` `running[].forced`) and takes none of the
  normal slots; a run already going when the label is added stays a normal run, and no running
  agent is stopped. Once the label is removed (or a forced parent's is), a forced run already
  going gives the allowance back and goes on as a normal run, so a ticket still forced can take it;
  so does its Auto Review QA pass on the allowance.
  A forced ticket past `forced_max` gets no extra slot: it still goes first for a
  normal one, waits as `queued #2; forced slot taken by MT-1` in `slot_waiting`, and Symphony logs a
  warning and sends one `forced_waiting` notification naming the forced run holding the allowance.
  The daily token budget and a usage-limit headroom hold don't stop a forced ticket (a warning is
  logged when the budget would have); the per-issue token cap still does. The operator Pause, the
  Linear rate-limit pause, the workspace quota pause, `max_concurrent_agents_per_host`, blocked-by
  links, a failed setup, retry backoff, the post-PR quiet period, auto-merge and `Merging` CI waits,
  and a usage-limit pause still hold it; when a usage-limit pause resumes, a held forced ticket
  goes out first.
  A forced plan ticket is one forced unit. Its plan, re-plan and close-out runs use the
  allowance like any forced ticket. While it waits on its sub-tickets, one ticket on its epic path
  at a time (its sub-tickets at any depth and their open blockers, picked in epic-lane order, so
  blocked-by links keep their order; the `Final verification:` sub-ticket comes last) counts as
  forced in the parent's place in the queue, without the label being written on it. It keeps that
  until it leaves the path or stops running or waiting on a retry; a sub-ticket in Auto Review is
  the part too, so its QA pass is forced. The other sub-tickets use normal slots and the epic lane.
  `/api/v1/state` shows it as the parent's `forced[].sub_issue`. Forcing never approves a plan: a
  forced parent in `In Review` stays there, shown with
  `forced[].waiting_on_human: true` (as is any forced ticket in `Backlog`, `Triage` or `In Review`).
  Forcing a sub-ticket itself forces only that sub-ticket.
- `concurrency.forced_stale_after_hours` (default: `72`) is how long a ticket may stay forced before
  it counts as stale: `/api/v1/state` marks it `stale: true`, the dashboards flag it, and Symphony
  logs a warning and sends one `forced_stale` notification (once per forced ticket, also across
  restarts). Values below `1` fail `symphony check`.
- Dispatch goes forced tickets first, then closest to done: `Merging`, Auto Review, `Rework`,
  resumes such as `In Progress`, then `Todo`; priority and age only break ties within a stage.
  While a `Merging` ticket waits for a finishing slot, or a QA pass is queued because
  `finishing_max` is below `auto_review.max_concurrent`, no `Todo` ticket starts; `Rework`,
  resumes and a forced ticket on the forced allowance still do, and the held ticket's reason names
  what it waits for (`QA pass for MT-3 is waiting for a finishing slot`). A QA pass queued on
  `auto_review.max_concurrent` doesn't hold `Todo` tickets back. A ticket that finds no free slot
  is not retried with backoff: it keeps its
  attempt and starts on the first poll after a slot frees (a run ending triggers that poll). The
  dashboard and `/api/v1/state` show the landing runs (`finishing`) and what is waiting for a slot
  and why (`slot_waiting`). A `Merging` ticket held while CI runs on its head is listed there as
  `waiting for CI on <sha>`; it doesn't count as waiting for a slot, so it doesn't hold back `Todo`.
  `/api/v1/state` also lists the issue ids Symphony holds a claim on (`claimed`); a claim with no
  running agent, retry or slot wait is released at the end of the next poll.
- `concurrency.max_by_issue_state` can cap work independently for specific issue states such as
  `rework`.
- `limits.max_turns` caps how many back-to-back turns Symphony will run in a single worker
  invocation when a turn completes but the issue is still active. Codex reuses one `threadId`
  across these turns; Claude relaunches per turn (workspace + prompt provide continuation).
- `timeouts.command_ms` caps a single shell command. Set `0` to disable.
- `timeouts.mcp_tool_ms` (default `600000`, 10 minutes) caps one call of Symphony's own MCP tools
  (`linear_*`, `github_*`): a call still running then is stopped and answered with a
  `tool_timeout` error. QA tools keep their own timeouts. Settings in the macOS app edits it as
  MCP tool timeout, in minutes.

**Token budgets:**

- `limits.tokens_per_issue` (default `500000`) and `limits.tokens_per_day` (default `5000000`,
  UTC-aligned) are guardrails. Raise either to a larger positive integer, or set to `null` to
  disable.
- The per-issue cap stops only the over-budget issue without retrying; the daily cap pauses new
  dispatch for the day while already-running agents continue. Forced tickets
  (`concurrency.force_label`) still dispatch past the daily cap, with a warning in the log.
- Codex app-server and Claude stream-json usage events are normalized into uncached input, cached
  input, cache-creation input, and output buckets. Symphony warns if a budget is active with a
  command that may not report token usage.
- The dashboard surfaces daily usage, daily remaining headroom, and per-issue usage. Cached,
  cache-created, fresh input, and output tokens are shown separately when reported.

**Usage limits:**

- `usage_limit.auto_pause` (default `true`): when a run ends on the Claude or Codex usage limit, Symphony
  holds new runs of that provider until the limit resets instead of failing the run. The retry
  keeps its attempt, gets no backoff and no `run_failed` notification, and the run is recorded as
  `usage_limited`. Runs on another provider (for example an `openrouter` run profile) keep
  dispatching, and a weekly Opus limit holds only Opus runs. Codex runs (`agent.kind: codex`) are
  their own provider (`openai`): a Codex limit holds only Codex runs, and a Claude limit never
  holds them. `false` keeps the old behaviour: the
  run fails and retries with the normal backoff.
- `usage_limit.resume_margin_seconds` (default `120`, `>= 0`): added to the reset time the provider
  reports before runs resume.
- `usage_limit.unknown_reset_retry_seconds` (default `900`, `>= 60`): how long the hold lasts when
  no reset time is known (neither in the rejection nor remembered for that window). It also caps
  the wait between probes while Claude or Codex can't reach its API (a network or DNS outage): that hold
  starts whatever `auto_pause` says, probes after 60 seconds and doubles the wait after each
  failed probe. A released outage hold is remembered this long (at least 10 minutes), so a QA or
  acceptance-gate pass that finds the outage again keeps the backoff.
- At the resume time one held run (the first in dispatch order) goes out alone. If Claude accepts
  it, the other held runs follow; if it hits the limit again, the hold starts over from the new
  reset time (or `unknown_reset_retry_seconds`). New Claude work stays held meanwhile.
- The hold is kept across restarts and is separate from the operator pause: resuming never
  clears a pause you set.
- While a hold is in place, the dashboards show `Paused: Claude 5-hour limit, resumes ~14:05`
  (local time), `/api/v1/state` lists it under `usage_limits`, and `dispatch_state.blockers` has a
  `usage_limit` entry. The `usage_limit_paused` and `usage_limit_resumed` notifications go out once
  when a hold starts and once when it clears, not once per held run. A hold clears when the first
  run is accepted, not when it goes out, and a first run that hits the limit again sends nothing.
- `usage_limit.headroom_utilization` (default `null`, off; else `> 0` and `<= 1`, for example
  `0.9`): leaves the rest of the Claude limit for your own sessions. When a running Claude agent
  reports an `allowed_warning` at or above this share of a window, Symphony holds new Claude runs
  until that window resets (plus `resume_margin_seconds`); later warnings for the window raise the
  percentage shown. Runs in flight and their continuations
  keep going, and landing runs (`Merging`) and forced tickets still start. The hold is kept across restarts, logs
  `Usage limit headroom hold provider=… utilization=… threshold=…`, shows on the dashboards as
  `Holding new runs: Claude at 91%, resets ~14:05`, is listed under `usage_limits` with
  `phase: headroom`, and sends one `usage_limit_headroom` notification when it starts and one
  `usage_limit_resumed` when it clears. It clears at the reset time without a first run going
  out alone. A real usage limit hit meanwhile turns it into the pause above.
  - Limitation: the Claude CLI only reports utilization once it passes its own warning threshold
    (seen at `0.75`), so a lower setting behaves as if it were set at that point.

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
- Managed socket dirs live under `SYMPHONY_MCP_SOCKET_ROOT` when set, otherwise under `/tmp` when
  Symphony can write there, otherwise under `TMPDIR` (for example a sandbox's `/tmp/claude-501`).
  Symphony logs the root it chose at startup. When `<root>/symphony-mcp-<id>/sock` would not fit
  the 104-byte Unix `sun_path` limit, the dir is named after a short hash of the session ID.
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
  auto_merge: true
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
    landing_wait_timeout_ms: 1800000
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
  A conflict on an issue an agent parked for a person (outside `tracker.active_states`, with the
  `human_actions.label` label, `needs-human` or another `auto_review.acceptance_gate.escalate.labels`
  label other than `plan` and `breakdown`) gets no state move, conflict-fix run or escalation, and
  uses no retry, until a person removes the label or moves the issue to an active state.
- `review_comments.ignored_reviewers` skips those accounts entirely. The Linear GitHub
  integration's linkback comment is always skipped: comments by `linear-code`, `linear-code[bot]`
  or `linear[bot]`, and any comment whose body starts with `<!-- linear-linkback -->`. Comments
  from the PR author and the current `gh` user still count as review feedback, so your own review comments on an
  agent PR send the issue back to work on the same PR. Symphony ends every PR comment it posts
  with a hidden `<!-- symphony:agent -->` marker and skips those.
- `checks.retry_failed_once` retries one likely-flaky failure before escalating.
- `checks.max_fix_attempts` bounds automated CI rework.
- A red head on an issue an agent parked for a person (outside `tracker.active_states`, with the
  `human_actions.label` label, `needs-human` or another `auto_review.acceptance_gate.escalate.labels`
  label other than `plan` and `breakdown`) gets no re-run, CI-fix run, escalation or state move,
  and uses no fix attempt. The normal CI flow resumes once a person removes the label, moves the
  issue to an active state, or the head turns green.
- `checks.landing_wait_timeout_ms` bounds how long a `Merging` issue waits for CI. When a landing
  run ends with the PR head's checks pending, Symphony holds the issue in `Merging` and dispatches
  the landing agent again once the CI poller sees that head go green (a red head goes through the
  normal CI-failure fix loop), or after this timeout. With `auto_merge`, a PR that stays `BLOCKED`
  with auto-merge on and a green head for this long falls back to the landing agent.
- `auto_merge` (default: `true`, needs `enabled: true`) lands `Merging` tickets with GitHub
  auto-merge instead of a landing agent, so they take no agent slot:
  - Symphony turns on auto-merge (squash, the PR title and body) once per PR head. GitHub merges it
    when the required checks pass, and Symphony moves the ticket to `Done`. When GitHub refuses
    auto-merge (the PR can already merge, no branch protection, or the repository doesn't allow
    it) and the PR is `CLEAN` with green checks or none, Symphony squash-merges it right away.
    When the head moved between Symphony reading the PR and turning auto-merge on (a push or an
    update-branch), Symphony tries again with the new head on the next poll; only a head that
    moves 3 times in a row falls back to the landing agent.
  - A PR that is `BEHIND` the base branch gets one GitHub "Update branch" per head; CI runs on the
    merged code and auto-merge fires when it passes.
  - A merge conflict turns auto-merge off and moves the ticket to `In Progress` with the conflict
    context (an agent run). The approval covered the diff before the conflict, so the fix goes
    back through review, and moving the ticket to `Merging` again turns auto-merge back on. The
    audit log (`auto_merge_disabled`, `reason: conflict`) and a ticket comment record it.
  - A red head first gets one flaky rerun of the same commit (`ci.flaky_retry`), with auto-merge
    left on. The CI-fix run after that turns auto-merge off before it starts, like a conflict: the
    fix goes back through review, and moving the ticket to `Merging` again turns auto-merge back
    on. The audit log (`auto_merge_disabled`, `reason: ci_failure`) and a ticket comment record it.
  - When auto-merge can't be used (GitHub refuses it and the PR isn't clean and green, a
    permission error, or the PR stays blocked on a green head), Symphony logs the error, comments
    the reason on the ticket, and falls back to the landing agent for that stay in `Merging`.
  - `/api/v1/state` (`auto_merge`) and the dashboard show each PR's status, for example
    "auto-merge on, waiting for CI on `abc1234`", "updating branch" or "blocked: conflict".
  - With the acceptance gate in `enforce` mode (Auto Review on), a push to a `Merging` PR that
    changes its own diff (`git patch-id` of the diff against the merge-base) turns auto-merge off
    and moves the ticket back to Auto Review, where the gate judges the new head; Symphony's own
    update-branch keeps it. The conflict and CI-fix comments then say the gate's approve, not a
    person, moves the fix back to `Merging`. The audit log (`acceptance_gate_rereview`, with the
    old and new head) and a ticket comment record it. See `docs/acceptance_gate.md`.
  - Apart from a merge conflict, a CI fix or a re-review, moving a ticket out of `Merging` does not turn auto-merge off;
    disable it on the PR to stop the merge.
  - Repository requirements: **Allow auto-merge** on (`allow_auto_merge`), and branch protection on
    the base branch with required status checks. Requiring branches to be up to date before merging
    (`strict`) is recommended, so GitHub never merges stale code; Symphony keeps the branch updated.
    **Allow squash merging** must be on. Every required check must report on every PR (a
    path-filtered required check that never runs keeps the PR `BLOCKED` until the fallback).

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
Each one falls back to the `pre_push_review` run profile (the routed repository's
`repositories[].agent`, then `agent.run_profiles.pre_push_review`, then `agent.model` / `agent.effort`);
with none set the reviewer command is unchanged. They take the same values as `agent.model` /
`agent.effort`, and `command` must not pass `--model` / `--effort` while any of them is set.

When enabled, Symphony runs an executor/reviewer loop in the same workspace before push. The
reviewer reads the committed diff for code quality and bugs: correctness, tests for new branches,
error handling, and the repo's code rules from its `AGENTS.md` / `CLAUDE.md`. It doesn't judge the
ticket's acceptance criteria or scope; the acceptance gate does (see
[`acceptance_gate.md`](acceptance_gate.md#who-reviews-what)). Its prompt tells it not to run the
test suite, coverage or Dialyzer, which CI runs after the push. Checks are split by cost: agents run cheap, targeted checks
locally (format, compile, lint, the tests for the changed code; Symphony's own list is in its
`WORKFLOW.md`), and the full suite, coverage and Dialyzer run only in CI.
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
  # worker_host: qa@qa-vm.local   # optional: run macos_app QA on another macOS host
  # android:                      # optional: the emulator for Android QA
  #   avd: Pixel_3a_API_34
```

`model` and `effort` (optional) set the QA agent's `--model` / `--effort` with the Claude runtime,
falling back to the `qa` run profile (the routed repository's `repositories[].agent`, then
`agent.run_profiles.qa`, then `agent.model` / `agent.effort`). Validation is the same
as for `pre_push_review`; when `command` is not set the QA agent uses `agent.command`, which must
then not pass the flag that `auto_review.model` / `auto_review.effort` sets.

When enabled, Symphony moves an issue whose run opened a PR to `state` (default `Auto Review`)
instead of `In Review`, and the CI poller watches it there:

- red CI sends the issue back to `In Progress` through the usual CI fix loop;
- green CI starts a QA pass on the PR head;
- a PR that conflicts with its base and has no checks (GitHub runs no CI on it) goes to `Rework`
  with a comment saying which branch to merge in.

Agents can no longer move the issue to `In Review` or `Human Review` themselves (a plan
or a `Final verification:` ticket, which open no PR, still can): `linear_update_state("In Review")`
returns "Symphony moves the issue to Auto Review once the PR is open; leave the state as it is."

#### QA passes

Before any agent runs, Symphony decides whether the PR needs QA and which playbooks apply:

| Signal | Result |
| --- | --- |
| `qa:skip` label | skipped |
| `qa:<kind>` label (for example `qa:cli`) | that playbook runs |
| only docs, tests or `skip_globs` paths changed | skipped |
| `## User walkthrough` in the ticket | `cli` playbook runs |
| web paths changed and `verification.dev_server` configured | `web` playbook runs |
| Android paths changed, `android_app` configured and `auto_review.android.avd` set | `android_app` playbook runs |
| a playbook's trigger paths changed | that playbook runs |
| nothing else | skipped (internal changes rely on tests and the pre-push review) |

The built-in `cli` playbook triggers on `bin/**`, `lib/symphony_elixir/cli.ex` and
`lib/mix/tasks/**`. It builds the CLI, runs the walkthrough commands with throwaway config and
state under `$TMPDIR`, and attaches a command transcript. A CLI pass typically costs 1–4 minutes
and 50–150k tokens.

The QA agent (`runtime` and `command`, defaulting to `agent.runtime` and `agent.command`) runs in
a fresh worktree at the PR head under `<workspaces.root>/.qa/`, removed afterwards. Each pass
also gets a private temp folder, `/tmp/symphony-qa-<hash>` (Symphony's own temp folder when it
can't write to `/tmp`), passed to a Claude agent as `CLAUDE_CODE_TMPDIR` and to a Codex agent as
`TMPDIR`, and writable in its sandbox, so the agent's `$TMPDIR` is the pass's own and not the
`/tmp/claude-<uid>` every Claude session shares or Symphony's own temp folder. Before it removes the worktree and the temp folder, Symphony stops every process still
running in either or started from either (by working folder or a path on the command line),
including ones detached with `nohup` or `setsid`, such as a server the agent started from a copy
of the PR under `$TMPDIR`, and logs each one. It can read
the issue, its parent and the PR, and attach evidence files with `linear_attach_file`; it cannot
move the issue, comment, push or write to GitHub. The session stops at `timeout_ms`, `max_turns`,
or `agent.limits.tokens_per_issue`. An agent that ends its turn without the JSON verdict gets one
follow-up turn in the same session asking for it, and the QA report notes "verdict after 1
follow-up".

QA never runs the test suite, `make all`, coverage or Dialyzer: a pass starts only once CI is green
on the PR head, so the prompt and every built-in playbook tell the agent to rely on CI and to build
only what it needs to use the change. A parent walkthrough judges a criterion that asks for tests,
coverage or CI to pass by CI's runs on the base branch head it tests, read with `gh run list` where
the sandbox allows `gh`, else through GitHub's public API: green runs make the step `pass` with the
run URLs, a failed run makes it `fail` naming the failing job and the run (so it is filed as a gap),
and it is `skipped` only when no run can be read or a run is still in progress. The public API is
`api.github.com`, which is not in the built-in network allowlist; add it to
`agent.permissions.network.allowed_domains` for the fallback to work.

**OpenRouter in QA.** QA never uses a real, paid OpenRouter key. OpenRouter flows (Test connection
in the macOS app's Settings, its Models list and Effort note, `symphony check` on an `openrouter`
profile, an OpenRouter run) are tested against a stub OpenRouter, `SymphonyElixir.OpenRouter.Stub`,
which listens on `127.0.0.1` only and answers with canned data:

| Request | Answer |
| --- | --- |
| `GET /api/v1/key` | for the key `sk-or-v1-symphony-qa-stub`, the label `Symphony QA stub`, $1.25 used of a $10.00 limit, $8.75 left; any other key or none gets a 401, so Settings says the key is rejected |
| `GET /api/v1/models` | `symphony-qa/reasoning-tools` (tools and reasoning), `symphony-qa/tools-only` (tools, no reasoning) and `symphony-qa/no-tools` (no tools) |
| `POST /api/v1/messages` | with the valid key, a canned Anthropic message (JSON, or SSE when the request streams) naming the model it was asked for |

It logs each request (method, path, model, whether the key was accepted), never the key. The
`macos_app` QA driver starts one for each pass and launches every app with its URL; on a
`worker_host`, the app's SSH session forwards a loopback port on the QA host back to it (`ssh -R`,
so the QA host's `sshd` must allow TCP forwarding, as it does by default). The `cli` playbook starts
one with `symphony openrouter-stub [--port <port>]`, which prints its URL and the variables to export.

Symphony and the app use the stub only in QA mode: `SYMPHONY_QA_OPENROUTER_URL` (the stub's API
base, such as `http://127.0.0.1:4100/api`) counts only while `SYMPHONY_BAR_QA_ROOT` is set too, and
only for an `http` or `https` URL on a loopback host (`127.0.0.1`, `localhost`, `::1`). Otherwise a
run, `symphony check` and the app always talk to `https://openrouter.ai`, whatever the environment
says, so a stray variable cannot send a key to another host. Checks against the real API with a
real key (a real model list, a real run) are manual: a person runs them by hand, with a cheap
model, outside QA.

An agent cannot change the agent-protected paths (`WORKFLOW.md`, `symphony.yml`, `.ai/skills`, the
project `.claude` settings, hooks and skills, `mise.toml`, `.tool-versions`,
`config/settings_ui_exempt.yml`): its sandbox denies the
writes and the `protected-paths` CI job fails a PR whose own commits touch them. The executor hands
a criterion that only such a change can meet to a person, in a sub-issue or a follow-up ticket
named in its workpad. The PR QA prompt lists these paths, and the agent marks such a handed-off
criterion `skipped` with the follow-up ticket's identifier instead of failing the PR on it. Without
a hand-off it is still `fail`, and a criterion a change elsewhere could meet (under `docs/`, in
`README.md`) is never skipped this way. A parent walkthrough still fails a missing change to these
paths, since it tests the merged result.

Symphony applies its verdict:

- `pass` → `In Review`;
- `fail` → back to `In Progress` on the same PR, with the findings in the next run's prompt; after
  `max_fix_attempts` failures the issue goes to `In Review` instead;
- `blocked` (the agent could not test, crashed, or gave an unreadable answer) → `In Review` with
  the reason;
- skipped → `In Review` with the reason.

A pass whose QA agent runs into the Claude or Codex usage limit gets no verdict and no report: the
issue stays in Auto Review, Symphony holds that provider's runs until the limit resets (as for an
agent run, see `agent.usage_limit`), and the next green CI poll after that runs the pass again on
the same PR head. With `agent.usage_limit.auto_pause: false` it is `blocked` instead.

A `blocked` the QA agent didn't decide itself (it crashed, hit the usage limit with `auto_pause`
off, or its dev server, emulator or browser didn't start) isn't kept for the PR head: when the
issue is moved back to Auto Review on the same head, QA runs again before the acceptance gate
judges it, after the usage limit resets if one still holds. A `blocked` verdict from the agent
(a missing secret, a step only a person can do) is kept, and goes to the gate or human review
again as it did the first time. A `blocked` stored by an older Symphony, which didn't record who
decided it, is told apart by its reason: one Symphony gave for an error runs again too.

Every pass rewrites one `## Symphony QA Report` comment on the issue (Symphony's only comment
besides the agent workpad) and records a run with `kind: "qa"`, its tokens and wall time in the
run store, which the dashboard's run history shows. `qa_passed` and `qa_failed` notifications are
available for `notifications.channels[].events`.

Results are kept per PR head SHA. With `run_on: first_pass`, once a push has passed QA, later
pushes on the PR skip it. `max_concurrent` caps how many QA passes run at once, and
`agent.concurrency.finishing_max` caps it again. QA passes never use the agent slots, so a pass
queued on `max_concurrent` doesn't hold `Todo` tickets back; one queued because `finishing_max` is
lower does.

A forced ticket's pass (see `concurrency.force_label`, including a forced parent's current
sub-ticket) goes to the front of the queue: while it waits, a free QA slot is kept for it. The
slot is kept only while the ticket keeps asking: if
no request has come for it in two CI poll intervals (it left Auto Review, or its CI went red or
pending), other tickets take free slots again. When every QA slot is busy it starts on the forced
allowance instead, as long as fewer than `concurrency.forced_max` forced runs and forced passes
are going; such a pass takes no QA slot, counts toward `forced_max`, and is logged with
`forced=true`. Once the label is removed (`symphony force --clear`, or the forced parent's), or the
sub-ticket stops being the forced parent's current one, a pass on the allowance gives it back and
goes on as a normal pass (`forced: false`), so a ticket still forced can take the allowance. A
ticket labelled in Linear while it is in Auto Review (outside `active_states`) never joins the
forced queue, so its pass keeps the allowance until it ends. Past `forced_max` a forced request
waits at the front of the queue. The verdict is applied as for any pass: a failing pass still sends the ticket back for a fix. `/api/v1/state` lists the passes
under `qa.running` and the waiting requests under `qa.queued`, each with `forced`.

#### Parent walkthrough

A parent's `Final verification:` sub-ticket gets a QA-only run instead of an executor agent. Once
the other sub-tickets have merged and the ticket is dispatched, Symphony runs the QA agent in a
fresh worktree at the head of `origin/<base_branch>`, with the parent as the issue under test:
it walks the parent's acceptance criteria and `## User walkthrough` plus the verification
ticket's checklist (plan runs copy the walkthrough under `## Auto Review: parent
walkthrough`), and attaches its evidence to the parent. There is no PR to diff, so `qa:<kind>`
labels on the ticket or the parent choose the playbooks, and every enabled playbook runs without
one.

- the `## Symphony QA Report` is written on the parent and on the verification ticket;
- `pass` (or `blocked` with no failing step) → the verification ticket goes to `In Review` for a
  human to sign off;
- the QA agent reports each row of the verification ticket's checklist as its own step marked
  `"checklist": true`, with `pass` or `fail` (a gap) and the evidence, and splits a row that groups
  several IDs ("UC1 to UC8") into one step per ID. It may skip a row only for a reason it states,
  such as a check only a person or a device the QA host lacks can do. A `pass` that reports no
  checklist row while the ticket lists some, or skipped (or was blocked on) more than half of them,
  is not accepted: the report says `blocked`, names the unchecked rows, and the verification ticket
  goes to `Backlog` for a human instead of `In Review`, where it would look verified. Check the
  rows, or move it back to `Todo` to run the walkthrough again;
- `fail` (or `blocked` with a failing step) → each failing step (or each finding, when no step
  failed) is filed as a `Backlog` sub-ticket of the verification ticket that names the step and
  holds its details and evidence, the report lists them, and the verification ticket is marked
  blocked by each one and stays in `Todo`. Symphony holds it there and runs the walkthrough again
  once every gap is `Done` (or cancelled), with no human step. When a gap could not be filed or
  linked, the ticket goes to `Backlog` for a human instead. There is no fix loop.
- `blocked` in either case also lists the ticket in the parent project's human-action update
  (see `human_actions`), with the reason and the blocked steps, since only a person can provide
  what QA was missing.
- a QA agent that runs into the usage limit gets no verdict and no report: the ticket keeps its
  state and its run is held and started again once the limit resets, as for any agent run.

The ticket gets the usual executor run when the tracker is not Linear, the run is on a remote
worker, it has the `qa:skip` label, or it has no parent.

`playbooks` overrides playbooks per kind, and adds kinds of your own with `paths` and `prompt`:

```yaml
auto_review:
  playbooks:
    cli:
      paths: ["bin/**", "lib/my_app/cli.ex"]
    api:
      paths: ["api/**"]
      prompt: |
        ### Playbook: api
        Call the changed endpoints with curl and check the responses.
```

Set `enabled: false` on a kind to turn it off.

A repository's `WORKFLOW.md` can set `auto_review.playbooks` too, for settings that differ per
repository, such as a build command or trigger paths. It is the only `auto_review` key allowed
there; any other one fails the repository's workflow with an error pointing at `symphony.yml`.
For that repository's QA passes (and parent walkthroughs), each kind is merged over
`symphony.yml`'s `auto_review.playbooks` key by key, and the repository's value wins:

```yaml
# symphony.yml
auto_review:
  playbooks:
    macos_app:
      build: make -C macos app
      app: macos/build/App.app
```

```md
---
# the repository's WORKFLOW.md
auto_review:
  playbooks:
    macos_app:
      paths: ["macos/Sources/**"]
---
```

That repository's `macos_app` playbook builds with `make -C macos app` and triggers on
`macos/Sources/**`; other repositories keep the default paths. A kind only one repository sets
(`api` above, say) exists only for that repository.

Each QA pass re-reads the repository's `WORKFLOW.md` from its base branch first, after a
`git fetch origin` when `fetch_before_dispatch` is on, so a playbook merged since the last
dispatch applies to the next pass. It logs its selection at info level in one line:

```text
QA selection issue_id=… issue_identifier=MOT-32 sha=… decision=run playbooks=android_app not_selected="cli: not triggered; macos_app: needs `auto_review.playbooks.macos_app.build`, `auto_review.playbooks.macos_app.app`; web: needs `verification.dev_server`" workflow_refresh=:ok
```

`not_selected` names each playbook that did not run: `not triggered` when none of its paths
changed, otherwise the setting it is missing or `enabled: false`.

#### Acceptance gate

`auto_review.acceptance_gate` configures the acceptance gate: its kill switch (`mode`, default
`off`), the gate agent's run settings and the escalation rules that send a PR to a human. It is
operator config only: a repository's `WORKFLOW.md` can't set it, and `repositories[].acceptance_gate`
can only add rules. With `mode: shadow`, Auto Review runs a gate pass after QA, writes an advisory
`## Symphony Acceptance Gate` comment, and moves the issue to In Review as before. Every key, the
built-in rules and example blocks are in [`docs/acceptance_gate.md`](acceptance_gate.md).

#### Android settings

`auto_review.android` holds the host-side settings for Android QA. They are host settings, so they
live only in `symphony.yml`; the build command and APK path go in a repository's playbook.

```yaml
auto_review:
  android:
    avd: Pixel_3a_API_34          # the emulator to boot; required for Android QA
    sdk_root: ~/Library/Android/sdk
    boot_timeout_ms: 180000
    idle_timeout_ms: 600000
```

| Key | Default | Meaning |
| --- | --- | --- |
| `avd` | none | Name of the Android Virtual Device to boot (letters, digits, `.`, `_`, `-`). |
| `sdk_root` | `$ANDROID_HOME`, then `$ANDROID_SDK_ROOT`, then `~/Library/Android/sdk` | Android SDK directory; `~` is expanded. |
| `boot_timeout_ms` | `180000` (3 minutes) | How long the emulator may take to boot. |
| `idle_timeout_ms` | `600000` (10 minutes) | How long an idle emulator stays up. |

A non-string `avd` or `sdk_root`, or a timeout that is not a positive integer, fails `symphony
check`.

See [Android app QA](#android-app-qa) for the playbook, the emulator Symphony runs and the
one-time host setup.

#### Web app QA

The built-in `web` playbook tests a web app in a headless browser against the project's dev
server. It is on when `verification.enabled` is true and `verification.dev_server.start_cmd` is
set (see [`verification`](#verification)), and triggers on `lib/*_web/**`, `lib/*_web.ex`,
`priv/static/**`, `assets/**` and `.heex`, `.html`, `.css`, `.scss`, `.jsx`, `.tsx`, `.vue` and
`.svelte` files (override with `paths`, or force it with a `qa:web` label).

For a `web` pass Symphony:

1. takes a port from the verification port pool and starts `dev_server.start_cmd` with
   `SYMPHONY_VERIFICATION_PORT` set (and on macOS `SYMPHONY_VERIFICATION_SOCKET`, see
   [`verification`](#verification)), from a second worktree at the PR head (so its build output
   stays out of the agent's worktree), then waits for `health_check_url`. A server that
   does not start or fails its health check within `health_timeout_ms` makes the pass `blocked`
   ("the dev server failed its health check"), not `fail`, and no agent runs;
2. gives the QA agent the server's address and a `browser` MCP server that only this QA session
   gets. By default that is [Playwright MCP](https://github.com/microsoft/playwright-mcp) with
   headless Chromium and an in-memory profile, limited with `--allowed-origins` to the dev server
   on `localhost` / `127.0.0.1`, and saving files into `qa-evidence/`. With
   `agent.network_access.mode: allowlist` the QA session's sandbox also allows `localhost` and
   `127.0.0.1`;
3. stops the dev server, releases the port and removes its worktree when the pass ends.

The agent follows the ticket's `## User walkthrough` (or the changed pages), takes a screenshot per
step, saves the browser console to `qa-evidence/console.md`, and attaches both to the issue, so
the QA report links each step's screenshot and the console output. A console error from the
changed page fails the step.

The default browser server runs on the Symphony host, outside the agent sandbox, so it is pinned
to `@playwright/mcp@0.0.83` and started with `npx --no`, which never downloads a package during a
pass. Install it and Chromium once on the host:

```bash
npx -y @playwright/mcp@0.0.83 --version
npx playwright install chromium
```

Before the agent starts, Symphony checks that `npx` is on its `PATH` and that the pinned package is
installed. When either is missing, the pass is `blocked` and the report says what to install. The
version is `@playwright_mcp_package` in `lib/symphony_elixir/qa_agent.ex`; to bump it, change it
there, check the flags above against that release, and update the install command here. The
origin allowlist keeps the browser
on the dev server; Playwright documents it as a guard rather than a security boundary. To use
another browser server, such as Glance, set `browser_mcp` to its MCP server definition (the shape
of an [`agent.mcp.servers`](#agentmcp) entry); Symphony then starts it as given:

```yaml
auto_review:
  playbooks:
    web:
      browser_mcp:
        command: glance-mcp      # stdio server; or transport: http with url: (Claude runtime only)
        args: ["--headless"]
```

An invalid `browser_mcp` makes the pass `blocked` with the error.

Symphony's own `WORKFLOW.md` points `verification.dev_server` at `scripts/qa-dashboard-server.sh`,
which builds Symphony from the PR head and serves the status dashboard with an in-memory tracker,
so dashboard changes get a `web` pass once the operator sets `verification.enabled: true`.

#### macOS app QA

The built-in `macos_app` playbook tests a macOS app by building it, launching it and using it
through accessibility, the way a user would. It is off until you name the build command and the
app bundle it produces:

```yaml
auto_review:
  playbooks:
    macos_app:
      build: make -C macos qa-app         # run in the QA worktree
      app: macos/build/Symphony.app       # relative to the repo root
      build_timeout_ms: 900000            # optional, default 15 minutes
      # paths: ["macos/Sources/**"]       # optional, default: Swift, Info.plist, xib, storyboard, xcassets
```

For Symphony's own app, build with `make -C macos qa-app`, not `make -C macos app`. The app runs
`symphony check` on every Settings Save, and a plain `make` build has no Symphony to run it with,
so each Save would stop at the check. `qa-app` builds the PR head's Symphony from the same copy
(`mix deps.get`, then `mix escript.build`) and embeds it at
`Symphony.app/Contents/Resources/symphony`, where releases embed theirs, so the QA app checks with
the PR's code and never with an installed release. The embedded escript's first line points at
the build host's Erlang (`<code:root_dir()>/bin/escript`), so the app runs it without `mise` or
`PATH`. The build host needs `mix` and `erl` on the build's `PATH` (Erlang and Elixir as in
`mise.toml`; set `MIX=` and `ERL=` on the make line to use others) and network access for
`mix deps.get`. With `mise` shims on a QA host, add `~/.symphony-qa` to the QA user's
`MISE_TRUSTED_CONFIG_PATHS`, since each pass copies the repository into a new directory there.
The QA app has no update key, so it never updates itself.

`symphony check` prints the build it runs first, on stderr: `Symphony <version> (<commit>)`. In QA
mode the app writes each check's exit status and output to its own stderr, which `qa_quit_app`
returns, so a QA report can quote the commit the check ran and compare it with the PR head. A
build in a checkout takes the commit from `git rev-parse HEAD`; on a `worker_host`, where the copy
has no `.git`, `git archive` writes it into `macos/source-commit` (an `export-subst` file).

The QA agent's sandbox cannot build Swift, open apps or read the screen, so Symphony runs these
tools for it on the host, outside the sandbox, and checks every argument:

| Tool | Does | Refuses |
| --- | --- | --- |
| `qa_build` | runs `build` in the QA worktree with the agent's scrubbed environment, then copies the `app` bundle into a private directory | a worktree with changes outside `qa-evidence/` and `.gradle-daemons/` (Symphony's own), gitignored files included: none may exist before the first build, and none may appear or change after a build; a bundle that resolves (symlinks included) outside the worktree, or that holds an absolute symlink or one with `..` |
| `qa_launch_app` | starts the private copy of the bundle with `SYMPHONY_BAR_QA_ROOT` set to a private directory ([QA mode](../macos/README.md#qa-mode)) and `SYMPHONY_QA_OPENROUTER_URL` set to the pass's [OpenRouter stub](#qa-passes), and returns its PID | an executable that changed since the last `qa_build`, or a worktree `qa_build` would refuse |
| `qa_quit_app` | quits a launched app and returns its recent output | a PID it did not launch |
| `qa_screenshot` | saves the app's on-screen windows to new files `qa-evidence/<name>.png` | a PID it did not launch, a window of another app, a name that already exists (file or symlink) |
| `qa_ax_tree` | reads the accessibility tree (role, title, value, frame; never a secure field's value), filtered by `role` or `text`, capped in depth, nodes and size | a PID it did not launch |
| `qa_ax_press`, `qa_ax_set_value` | press an element (or `AXRaise` a window) and set a field's value: a text field gets it typed in with key events sent to the app alone (brought to the front, focused, text selected, then Tab), so the app sees the edit; other controls get `AXValue` set | a PID it did not launch, a tab or line break for a single-line field |
| `qa_resize_window` | the wide pass: moves the app's main window (or the `AXWindow` at `path`) to the top left of the screen and resizes it to `width`×`height` points (1400×900 by default), or the screen's usable area when that is smaller, with `AXSize` or else the window's zoom button; returns the window frame it reached, the screen and its usable area, and `limited` when that area is under 1400×900 pt | a PID it did not launch, a size under 1400×900 or over 8192 pt, a `path` that is not a window |
| `qa_check_app` | says whether a launched app still runs (also after it exited), answers an accessibility request within 10 seconds (else it is hung), and has written a new `~/Library/Logs/DiagnosticReports/<executable>*` crash report since launch (read on the QA host for a `worker_host`), with each problem naming the `page` the agent passes and the window size `qa_resize_window` set | a PID it did not launch |
| `qa_put_file` | puts a fixture file the agent wrote (a test `symphony.yml`, a `WORKFLOW.md`) where the app can open it and returns that path: the file's own path on this host, a copy in the run directory's `files/` on a `worker_host` | a file that resolves outside the worktree and the pass's `$TMPDIR`, a symlink, a directory or other non-regular file, a file with other hard links, a file over 1 MB, and a file replaced while it is read |

At most three launched apps run at once, and every app still running is quit when the pass ends.
Only QA agents see these tools; executor and reviewer sessions cannot list or call them.

The playbook judges a window only after it settles: it waits about 10 seconds after the window
opens, changes focus once, and then checks the sizes of the content and scroll areas in the
accessibility tree, not just the window frame. A window that opens at full height and collapses
seconds later fails, with the AX tree quoted and a screenshot attached.

After the walkthrough at the app's default size, the playbook runs a **wide pass**, because some
layout crashes only happen in wide windows: `qa_resize_window` makes the main window at least
1400×900 pt, then on each page the PR changes, and on its inspector or side panel, the agent waits 30
seconds with the app running and calls `qa_check_app`. The pass fails when the app exits, hangs (no
accessibility answer for 10 seconds) or writes a new crash report, and the report names the page and
the window size. The report's `Wide pass` step gives the window size, the screen size and the
pages it covered. A QA screen whose usable area is under 1400×900 pt (a VM with a 1024×768 display)
cannot run it at full size: the step says the wide pass was limited, and Symphony reports a `pass`
from that screen as `blocked` for a person, so the acceptance gate escalates it (`qa_blocked`)
instead of approving it. A `pass` with no `qa_resize_window` call at all is `blocked` too, with the
reason that the wide pass did not run. Give the QA VM a larger display, for example
`tart set symphony-qa --display 1920x1200`, and restart it. The resize needs no grant beyond the
helper's Accessibility.

The screenshot and accessibility tools run in a small helper app, `SymphonyQADriver.app`, which
holds the Screen Recording and Accessibility grants. Symphony opens it through LaunchServices
(`open -a`) and talks to it over a Unix socket in one fixed `0700` directory,
`~/Library/Application Support/symphony/qa-driver/run/`, whatever the state root. The helper
answers only the Symphony process that opened it, only for apps that process launched, and quits
when Symphony does.

The helper does not trust the process tree to tell Symphony from an agent: an agent can leave it,
for example with a double fork or `nohup … &`. Before it opens the helper, Symphony leaves an
owner file, `qa-<pid>.owner`, in the run directory. The helper serves only an owner whose file it
finds there and that is under 30 seconds old (it removes the file; an older one, left by a Symphony
that crashed, names no one), only on that owner's socket in the same directory, and only an
Erlang VM (`beam.smp`) that no other Erlang VM started. Agent sandboxes cannot write the run
directory, so an agent cannot make itself the owner, nor put its own socket where Symphony
connects. This holds only while the run directory stays out of the sandbox's writable paths: do
not add it, or a parent of it, to `permissions.filesystem.allow_write_paths`, and do not run agents
without a sandbox on a Mac where the helper has its grants. When the run directory path is longer
than a Unix socket path allows (a very long home directory), the QA tools fail with
`socket_path_too_long`.

The helper also refuses its screenshot and accessibility commands when it is opened with them directly,
for example `open -a SymphonyQADriver.app --args screenshot …`: it runs them only for its own
`serve` process. `Symphony.app` ships it signed at
`Symphony.app/Contents/Helpers/SymphonyQADriver.app`. When Symphony runs from a terminal, it
compiles the helper once with `swiftc` (Xcode or the Command Line Tools) and signs it ad hoc at
`<state root>/qa-driver/<hash>/SymphonyQADriver.app`. Bundle copies, screenshot staging and the
app's QA root live in a `0700` directory per pass under `<state root>/qa-driver/runs/`, outside
every path the agent sandbox may write, and are removed when the pass ends.

##### One-time macOS permissions

Screenshots need **Screen Recording** and the accessibility tools need **Accessibility**. Grant
both to **Symphony QA Driver** (`SymphonyQADriver.app`) and to nothing else.

> [!WARNING]
> Do not grant Screen Recording or Accessibility to `Symphony.app`, or to the terminal you run
> `symphony` from. macOS passes an app's grants to every process it starts, and Symphony starts
> the coding agents, which run with `--dangerously-skip-permissions`. With such a grant, any agent
> could run `screencapture` or an AppleScript to read your screen (mail, browser, password
> prompts) and drive any app, including clicking "Always Allow" on a Keychain prompt. Symphony
> opens the helper through LaunchServices, so the helper's grants stay with the helper. If you
> already granted `Symphony.app` or your terminal, turn those grants off.

1. Open the helper once so macOS lists it. With the menu bar app:

   ```bash
   open ~/Applications/Symphony.app/Contents/Helpers/SymphonyQADriver.app
   ```

   When Symphony runs from a terminal, the helper only exists after the first QA pass builds it.
   Open it from `<state root>/qa-driver/<hash>/SymphonyQADriver.app` instead. macOS asks for
   Accessibility and Screen Recording.
2. Open **System Settings → Privacy & Security → Screen & System Audio Recording** and turn on
   Symphony QA Driver. Use **+** to add `SymphonyQADriver.app` when it is not listed.
3. Open **System Settings → Privacy & Security → Accessibility** and do the same.
4. Check that `Symphony.app` and your terminal are off in both lists.

Symphony opens the helper again for the next QA pass, so you don't need to restart anything. A
release `Symphony.app` signs the helper with the same certificate every time, so the grants survive
app updates. A locally built app (`make` in `macos/`) and the helper built from a terminal are
signed ad hoc: macOS asks again after each rebuild, and after each Symphony version that changes
the helper. Both are signed with the hardened runtime, so code injected with
`DYLD_INSERT_LIBRARIES` does not load into the helper and can't use its grants.

Without a grant the tools return `qa_permission_missing`. The QA agent marks the app steps
`blocked`, still runs the steps of the other playbooks offered (`cli`, `web`) and reports each as
`pass` or `fail`, then answers `blocked` with the missing permission as the reason. The issue goes
to `In Review` with that reason in the QA report; in a parent walkthrough, a failing step from the
other playbooks is filed as a gap as usual.

##### Running QA on a separate macOS host

`qa_build` runs the PR's build and app unsandboxed, as a person building the PR would. To keep
that away from your credentials, point `auto_review.worker_host` at a dedicated macOS VM or a
separate macOS user:

```yaml
auto_review:
  worker_host: qa@qa-vm.local     # user@host or host:port, as in workers.ssh_hosts
```

Symphony reaches it with the same SSH transport as `workers.ssh_hosts` (`SYMPHONY_SSH_CONFIG`
applies), non-interactively, so key authentication must already work. Do not list it in
`workers.ssh_hosts`: that list also receives coding runs. The QA agent still runs on the Symphony
host and the worktree checks still apply there. Then:

- `qa_build` copies the worktree's `HEAD` (`git archive`, so gitignored files and submodules stay
  behind) into a fresh `src/` in a `0700` run directory under `~/.symphony-qa/runs/` on the QA
  host, runs `build` there with the QA user's login environment, and copies the bundle into the
  run directory;
- `qa_launch_app` starts that copy with only `SYMPHONY_BAR_QA_ROOT` and `SYMPHONY_QA_OPENROUTER_URL`
  set, over an SSH session that forwards the URL's loopback port on the QA host back to the
  OpenRouter stub on the Symphony host;
- at the start of the pass Symphony picks three free loopback ports on the Symphony host and
  hands them to the QA agent as `QA_HOST_PORTS` (in the prompt and its environment). It opens one
  SSH session to the QA host that forwards each of them from the QA host's loopback to the same
  port on the Symphony host (`ssh -o ExitOnForwardFailure=yes -R <port>:127.0.0.1:<port>`), and
  closes it when the pass ends. The agent serves the app's stubs and proxies on `127.0.0.1` at
  those ports, and the app uses `http://localhost:<port>`. Loopback works whatever address the QA
  VM has (a bridged VM cannot reach the NAT address `bridge100` still has) and needs no macOS
  Local Network permission, which an app connecting to a LAN address asks a person for. A port
  the QA host refuses is retried with fresh ports; a tunnel that still cannot open makes the pass
  `blocked` with the reason, and one that closes during the pass is reopened at the next
  `qa_launch_app`, which fails with `qa_host_tunnel_failed` when it cannot;
- the Swift helper is compiled there with `swiftc` on first use in each pass, into the run
  directory's `helper/`. Passes never share it: each PR's build runs as the QA user, and a helper
  it replaced could answer the permission, window and accessibility calls of later passes. There it
  runs its commands directly over SSH, with the grant on `sshd-keygen-wrapper` (step 4 below), and
  no `SymphonyQADriver.app` is opened or granted;
- screenshots are captured there and copied back into `qa-evidence/` in the local QA worktree, so
  the agent attaches them as before;
- `qa_put_file` copies the fixture over SSH into the run directory's `files/` and returns that
  path, since the app cannot read files on the Symphony host;
- the run directory is removed when the pass ends. A build that times out is stopped on the
  Symphony side; on the QA host it may run until it finishes.

At the start of each pass Symphony checks that the QA host cannot reach your credentials and
refuses it otherwise. The `qa_*` tools then fail with `qa_worker_unsafe` naming each problem, and
the QA agent answers `blocked`. The check fails when the QA host:

- can open your `~/.ssh`, or read your `~/.config/gh/hosts.yml` or login Keychain
  (`~/Library/Keychains/login.keychain-db`), at your home path;
- can read a file in Symphony's private state directory, which means it runs as you;
- has a private key in its own `~/.ssh`, GitHub CLI credentials in `~/.config/gh`, or a global git
  credential helper;
- has a forwarded SSH agent (`ForwardAgent yes` for that host in your SSH config).

An unreachable host gives `qa_worker_unreachable` and a `blocked` verdict.

One QA host keeps state across passes. Removing the run directory removes the pass's source,
bundles and helper, but anything a build or app leaves behind as the QA user stays on the host: a
build that timed out and is still running, a background process, or changes to that user's files,
caches and login environment. Any of these can tamper with a later pass. Symphony does not reset
the host between passes. For full isolation, reset the VM between passes by running QA from a
fresh throwaway clone of a clean image (see step 6 below); with a separate macOS user, treat its
home as shared by every PR it has built.

**A dedicated VM (recommended).** With [tart](https://tart.run):

1. `tart clone ghcr.io/cirruslabs/macos-sequoia-xcode:latest symphony-qa` (an image with Xcode,
   so `swiftc` and your build tools are there), then `tart run symphony-qa`.
2. In the VM, sign in as its user (tart images use `admin`), turn on **System Settings → General →
   Sharing → Remote Login** and **Users & Groups → Automatically log in as** that user. QA needs a
   logged-in desktop session to open windows.
3. Do not sign in to an Apple Account, copy SSH keys, run `gh auth login` or store passwords in the
   VM. Add your public key to the VM user's `~/.ssh/authorized_keys` only.
4. Grant TCC once, in the VM: **Privacy & Security → Screen & System Audio Recording** and
   **Accessibility**, use **+**, press **⌘⇧G**, enter `/usr/libexec/sshd-keygen-wrapper` and turn it
   on. Commands started over SSH are attributed to it, so this covers `screencapture` and the
   helper. Restart the VM.
5. Install whatever `build` needs (for example the repo's toolchain) and run the build once by hand
   over SSH to confirm it works.
6. Stop the VM and keep it as a clean image. To reset it between passes, delete the working copy
   and clone it again: `tart delete symphony-qa-run; tart clone symphony-qa symphony-qa-run;
   tart run --no-graphics symphony-qa-run`. Point `worker_host` at the clone (`tart ip
   symphony-qa-run` prints its address); it keeps the image's login and TCC grants.

**A separate macOS user** on the Symphony Mac works the same way: create a standard user, turn on
Remote Login for it, keep it logged in (Fast User Switching), grant the TCC permissions above, and
use `qa@localhost` as `worker_host`. macOS keeps your `~/.ssh`, `~/Library` and Keychain closed to
other standard users by default; the start-of-pass check confirms it.

To check a host by hand, run the same tests as the QA user:

```sh
ssh qa@qa-vm.local 'ls ~/.ssh; ls ~/.config/gh; git config --global credential.helper; echo "agent=$SSH_AUTH_SOCK";
  ls /Users/<you>/.ssh /Users/<you>/Library/Keychains 2>&1 | head'
```

Only `authorized_keys` (and `known_hosts`) should show, the next three should be empty, and the
last command should fail with `Permission denied` or `No such file or directory`.

Auto Review needs `pull_requests.enabled: true` and `pull_requests.checks.enabled: true`, because
the CI poller is what moves issues out of the state. A PR with no CI checks stays in Auto Review.

#### Android app QA

The built-in `android_app` playbook tests an Android app on an emulator: the QA agent builds the
APK in its own sandbox, Symphony installs it on an emulator it runs on the host, and the agent
uses the app through the screen's UI tree, the way a user would. It is off until a repository
names the build, the APK and the app's IDs, and `symphony.yml` names the emulator:

```md
---
# the app repository's WORKFLOW.md
auto_review:
  playbooks:
    android_app:
      build: ANDROID_HOME="$HOME/Library/Android/sdk" ./gradlew :app:assembleDebug
      apk_path: app/build/outputs/apk/debug/app-debug.apk   # relative to the repo root
      application_ids: ["com.example.app"]
      # paths: ["app/src/main/**"]   # optional, default below
---
```

A repository that ships more than one app, say the product and a design-system catalog, lists
every APK in `apk_paths` and every app in `application_ids`, and builds them all in one `build`:

```yaml
auto_review:
  playbooks:
    android_app:
      build: ANDROID_HOME="$HOME/Library/Android/sdk" ./gradlew --no-daemon :app:assembleDebug :app-catalog:assembleDebug
      apk_paths:
        - app/build/outputs/apk/debug/app-debug.apk
        - app-catalog/build/outputs/apk/debug/app-catalog-debug.apk
      application_ids: ["com.example.app", "com.example.app.catalog"]
```

`apk_path` is a one-item `apk_paths`; a playbook may set both, and `apk_path` comes first.

```yaml
# symphony.yml
auto_review:
  android:
    avd: Pixel_3a_API_34_extension_level_7_arm64-v8a   # the name `emulator -list-avds` prints
```

The playbook is on only when `build`, `apk_path` or a non-empty `apk_paths`, a non-empty `application_ids` and
`auto_review.android.avd` are all set (the [Android settings](#android-settings) hold the rest of
the host side). It then triggers on `**/*.kt`, `**/*.java`, `**/AndroidManifest.xml`,
`**/src/main/res/**`, `**/*.gradle.kts` and `**/*.gradle`, and a `qa:android_app` label forces
it. A change only under `**/src/test/**` or `**/src/androidTest/**` counts as tests and is
skipped. The QA prompt gives the agent the build command, every APK path and the application IDs.

`build` runs in the QA agent's sandbox with the agent's scrubbed environment, so name what it
needs in the command itself: `ANDROID_HOME` (or `ANDROID_SDK_ROOT`) and, when the JDK is not the
one `/usr/libexec/java_home` finds, `JAVA_HOME`. Add `~/.gradle` to
`permissions.filesystem.allow_write_paths` so the build can use Gradle's caches (see
[`agent`](#agent)); Maven Central, Google's Maven and the Gradle plugin portal are
in the built-in network allowlist. A fresh QA worktree has no `local.properties`.

The agent follows the ticket's `## User walkthrough` and acceptance criteria. It lets each screen
settle (a few seconds after every navigation) before it reads `qa_android_ui_tree`, and judges
the tree: the controls and text the ticket describes are there, their bounds have a real size,
nothing is clipped under the status bar, the navigation bar or the keyboard, and the app is still
in the foreground. It checks back, the keyboard action, rotation and dark mode where the walkthrough
touches them, takes a screenshot per judged step and after each action that changes the UI, and
attaches them to the issue. A missing or broken component, or a crash (`qa_app_exited`), fails the
step, with the tree excerpt and the screenshot.

A pass that runs the playbook takes the emulator when it starts and gets these tools. Symphony
runs them on the host and checks every argument. No `qa_android_*` tool runs the build, Gradle or
any other repository command on the host; they only call Symphony's adb.

| Tool | Does | Refuses |
| --- | --- | --- |
| `qa_android_install` | copies every APK in `apk_paths`, or only the one its optional `apk` argument names, into a private directory, uninstalls every `application_ids` app (which wipes its data) and every package installed since the pass's first install, runs `adb install -r` from each copy in turn and reports the application IDs each APK installed. Each install starts from no configured app, so a walkthrough that uses two apps installs both at once | an `apk` that is not one of the APK paths; a worktree with changes to tracked files outside `qa-evidence/`; an APK path that resolves (symlinks included) outside the worktree, is a symlink, is not a file or is over 512 MB, checked for every APK before the device changes; an APK that installs or replaces a package not in `application_ids`, which is uninstalled again, as is anything a failed install left behind |
| `qa_android_launch` | starts the app's launcher activity and waits until it is in the foreground; reports recent logcat when the app exits | an application ID not in `application_ids`, or not installed by `qa_android_install` in this pass |
| `qa_android_stop` | force-stops the app | an application ID not in `application_ids` |
| `qa_android_screenshot` | saves the screen to a new file `qa-evidence/<name>.png`, at most 50 per pass | a name that already exists (file or symlink) |
| `qa_android_ui_tree` | reads the screen with `uiautomator dump` through `adb exec-out` as a flat list of nodes: a path such as `0.2.1`, class, text, content-desc, resource-id, bounds and the clickable, focused, enabled, checked and scrollable flags; filters by `text`, `resource_id` and `class`; caps the depth (`max_depth`, default 30), the nodes (`max_nodes`, default 300) and the JSON (100 KB) and says when nodes were left out; reports the foreground package and warns when it is not one of `application_ids` | |
| `qa_android_tap` | taps the centre of a node `path` from the last tree, or a point `x`, `y` | a point off the display, a path not in the last tree's result |
| `qa_android_type` | types `text` (up to 500 characters) into the focused field; a newline presses Enter. Each part is single-quoted for the device's shell, so no character can run a command | anything but printable ASCII and newlines |
| `qa_android_key` | presses `back`, `enter`, `ime_action`, `tab`, `del`, `dpad_up`, `dpad_down`, `dpad_left`, `dpad_right` or `escape` | any other key |
| `qa_android_rotate` | turns off auto-rotate and locks `portrait` or `landscape` (`cmd window user-rotation lock`, or the `user_rotation` setting on Android 9 and older), then waits up to 5 s for the display to turn; fails with `qa_android_rotate_failed` when it does not, for example when the app locks its orientation | any other orientation |
| `qa_android_dark_mode` | turns the night theme `on` or `off` (`cmd uimode night`) | |
| `qa_android_font_scale` | sets the font scale to 0.85, 1.0, 1.15, 1.3, 1.5, 1.8 or 2.0 | any other scale |
| `qa_android_put_file` | puts a fixture file the agent wrote (a CSV to import, a malformed file) into the emulator's shared Downloads: copies the checked bytes into the private directory, runs `adb push` to `/sdcard/Download/<name>` and a media scan, so the system file picker lists it under Downloads. `dest` is `Download/<name>`, by default the file's own name. `qa_android_install` wipes app data, not Downloads, so the file survives a reinstall | a file that resolves outside the worktree and the pass's `$TMPDIR`, a symlink, a directory or other non-regular file, a file with other hard links, a file over 1 MB, a file replaced while it is read; a `dest` outside `Download/`, in a subfolder, or with a name other than letters, digits, `.`, `_` and `-` |

`qa_android_ui_tree` through `qa_android_font_scale` work only once `qa_android_install` installed
one of the `application_ids` in this pass.

When the pass ends, or crashes, Symphony resets what the pass changed (portrait with auto-rotate
off, dark mode off, font scale 1.0) and removes the files it put in Downloads, so the next pass
starts clean on the same emulator, then
uninstalls the `application_ids` apps and every package installed in the pass, gives the emulator back and removes the private directory. Only QA
agents see these tools; executor and reviewer sessions cannot list or call them.

When the emulator cannot start, every tool fails with `qa_android_unavailable`. The agent marks the
app steps `blocked`, still runs the steps of the other playbooks offered (`cli`, `web`) and reports
each as `pass` or `fail`, then answers `blocked` with the tool's message as the reason.

Every QA prompt tells the agent never to start an emulator, a simulator or a device tool itself
(`emulator`, `qemu-*`, `xcrun simctl boot`, `adb start-server`): its sandbox cannot run them, and
each attempt leaves crash reports on the host. In a pass without the `android_app` playbook, the
`qa_android_*` tools fail with `qa_android_driver_unavailable`, and the agent marks each step that
needs an Android device `blocked` with "no Android QA playbook configured for this repo".

##### The emulator

Symphony runs the emulator on the host, because the QA agent's sandbox cannot (it needs the
hypervisor, Mach ports, adb sockets and a lot of memory). The agent sandbox does not change.

- At most one emulator runs. A QA pass that needs it while another holds it waits its turn, and
  gives up with a clear error after 30 minutes.
- It boots `avd` with `-no-window -no-audio -no-boot-anim -read-only -no-snapshot-save`, so QA
  never changes the AVD, and waits up to `boot_timeout_ms` for it to finish booting. An unset
  `avd`, a missing `emulator/emulator` or `platform-tools/adb` under `sdk_root`, an AVD the
  emulator does not list and a boot timeout each fail with their own message.
- Symphony starts its own adb server on port `15037` and the emulator on console port `5600`
  (serial `emulator-5600`), and sends every adb call there. Your own adb server (port `5037`),
  emulators and phones are left alone, and your adb server does not see Symphony's emulator: it
  only scans console ports 5554 to 5584.
- It stops `idle_timeout_ms` after the last QA pass gives it back (or exits), and when Symphony
  stops. An emulator that crashes is booted again by the next QA pass.
- The emulator's and adb server's process ids are recorded in
  `<state root>/qa-android/emulator-processes.json`. If Symphony crashes, its next start stops
  those processes, only when they still run with the same start time.

##### One-time Android host setup

1. Install the emulator and platform tools, with a system image. From Android Studio, use
   **Settings → Languages & Frameworks → Android SDK → SDK Tools** and tick **Android Emulator**
   and **Android SDK Platform-Tools**. Without Android Studio, use the command-line tools:

   ```bash
   sdkmanager "emulator" "platform-tools" "system-images;android-34;google_apis;arm64-v8a"
   ```

   Symphony looks for `emulator/emulator` and `platform-tools/adb` under `sdk_root` (default
   `$ANDROID_HOME`, then `$ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`).
2. Create or choose an AVD. List the ones you have with
   `~/Library/Android/sdk/emulator/emulator -list-avds` and put the exact name it prints in
   `auto_review.android.avd`. Prefer a small phone image with Google APIs but no Play Store. On the
   maintainer's Mac that is `Pixel_3a_API_34_extension_level_7_arm64-v8a` (API 34, 1.5 GB of guest
   RAM, 4.3 GB on disk), not `Pixel_9` (API 36.1 with the Play Store, 2 GB of guest RAM, 9.9 GB on
   disk). To create one:

   ```bash
   avdmanager create avd -n Pixel_3a_API_34 -d pixel_3a \
     -k "system-images;android-34;google_apis;arm64-v8a"
   ```

3. Cold-boot it once by hand to check that it works, then close it:

   ```bash
   ~/Library/Android/sdk/emulator/emulator -avd Pixel_3a_API_34_extension_level_7_arm64-v8a -no-snapshot-load
   ```

   It should reach the home screen within a few minutes. When it does not boot by hand, Symphony
   cannot boot it either; when it boots slowly, raise `boot_timeout_ms`. Close it before the first
   QA pass.
4. Plan the memory. While it runs, the emulator takes its guest RAM plus about 1 GB for itself
   (2.5 to 3 GB for the Pixel 3a AVD above), on top of the QA agent and the Gradle build. It stops
   `idle_timeout_ms` after the last pass; lower that on a Mac with little memory to spare.

> [!WARNING]
> Keep the emulator out of the agent sandbox. Do not add the Android SDK, `~/.android` (it holds
> the AVDs and the key adb uses) or Symphony's state root to
> `permissions.filesystem.allow_write_paths`, and do not give agents Mach-port or hypervisor
> allowances to run an emulator themselves. Symphony runs the emulator and adb outside the sandbox
> and checks every tool call; an agent that could write those paths could change the emulator or
> the tools Symphony runs.

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

Progress watchdog for stalled runs. A run waiting out a Linear rate limit or outage is not stalled:
its no-progress clock (and the first-turn `agent.timeouts.stall_ms` clock) starts again when the
wait ends.

```yaml
watchdog:
  enabled: true
  tick_interval_ms: 60000
  no_progress_threshold_ms: 600000
  stray_process_cpu_minutes: 10
  pending_tool_report_after_ms: 60000
```

`pending_tool_report_after_ms` (default `60000`, one minute; a positive integer) is how long one of
Symphony's own MCP tool calls (`linear_*`, `github_*`, `qa_*`) must run before Symphony's state and
the dashboard show the run as waiting on it. Settings in the macOS app edits it as "Show a pending
tool call after", in minutes.

On every tick the watchdog also reads the host's process table and warns about stray processes.
A stray process runs in, or names on its command line, a folder under `workspaces.root`,
`/tmp/claude-<uid>/` or a Symphony temp folder (`symphony-*` under `$TMPDIR` or `/tmp`). It has
used more than `stray_process_cpu_minutes` of CPU time, and no agent run or QA pass is running in
its workspace or temp folder. Examples are a process a remote worker run or an interactive Claude session left
behind, or one that escaped the cleanup at the end of a run. The dashboard shows each one with
its pid, command, working folder and CPU time, and the log records it once. The warning clears on
the first tick after the process is gone. Symphony never signals these processes. Set
`stray_process_cpu_minutes: null` to turn the check off. `enabled: false` only stops the
watchdog from restarting stuck runs.

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

`start_cmd` gets `SYMPHONY_VERIFICATION_PORT`. On macOS it also gets `SYMPHONY_VERIFICATION_SOCKET`
and must listen on that unix socket instead of the port: the dev server's sandbox allows no TCP
listener there, since Seatbelt can't keep one off the network, and Symphony serves the socket on
`127.0.0.1:$SYMPHONY_VERIFICATION_PORT`, where `health_check_url` and the QA browser reach it (see
[security.md](security.md#macos-the-dev-server-listens-on-a-unix-socket)). Many servers take a
socket path (`uvicorn --uds`, `gunicorn --bind unix:`, Puma's `-b unix://`, Node's
`server.listen(path)`, Bandit's `ip: {:local, path}`, Symphony's own `--host unix:<path>`), so one
command can serve both ways:

```yaml
    start_cmd: >-
      if [ -n "${SYMPHONY_VERIFICATION_SOCKET:-}" ];
      then exec uvicorn app:app --uds "$SYMPHONY_VERIFICATION_SOCKET";
      else exec uvicorn app:app --host 127.0.0.1 --port "$SYMPHONY_VERIFICATION_PORT"; fi
```

A server that can only listen on a TCP port does not run on macOS: when its health check times out
with nothing at the socket, the run fails with `dev_server_not_on_socket`, and an Auto Review
`web` pass is `blocked` with that reason. An Elixir dev server can't run Mix inside the sandbox at
all: every task that loads deps starts `Mix.PubSub` on an ephemeral `127.0.0.1` port, and Mix's
build lock takes one too, both refused by the no-TCP-listener profile. Build the escript or release
outside the sandbox first (`mix build`) and point `start_cmd` at that prebuilt artifact, so the
sandbox only starts the artifact and never Mix (`scripts/qa-dashboard-server.sh` does this).

Auto Review's `web` playbook starts the same dev server, from a worktree at the PR head, for each web QA pass
(see [Web app QA](#web-app-qa)).

`start_cmd` runs the checkout's code, which the agent can change, so Symphony runs it with
`sh -lc` under macOS Seatbelt, or bubblewrap (`bwrap`) on Linux, with the agent's credential
read-deny list, writes limited to the
checkout, a temp folder of its own and the agent cache folder, the agent's environment, no
listener the network reaches (on macOS no TCP listener at all, only its unix socket), and
connections limited to loopback and, through a proxy Symphony sets as `HTTPS_PROXY`, the dependency
hosts on `agent.permissions.network`'s allowlist, an allowlist of mach services like the agent's
(no window server, no pasteboard), and no way to have launchd start a process outside the
sandbox (Apple Events, `open`, `launchctl submit`) (see
[security](security.md#verification-dev-server-runs-in-a-sandbox)). On Linux the network is a
namespace of its own, bridged by `socat` to the host's loopback for the server's port and the
proxy only, and the mach service and launchd limits don't apply. Without `bwrap` and `socat`, or
on another system, the dev server does not start.

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
  # GitHub webhooks through a relay; they speed up the CI poll, which stays on.
  webhooks:
    enabled: false
    relay: smee # smee | cloudflare_tunnel | gh_webhook_forward
    secret: $GITHUB_WEBHOOK_SECRET # unset: read <state-root>/github_webhook_secret
    events: [check_suite, check_run, workflow_run, pull_request]
```

`webhooks` lets GitHub tell Symphony that a pull request's checks finished, so a CI result lands in
seconds instead of up to one `pull_requests.poll_interval_ms`. Symphony listens on
`127.0.0.1`, so the deliveries come through a relay to `POST /api/v1/github/webhook` on the
dashboard port. A delivery about a PR the CI poller already watches runs the CI poll for that
repository at once, and a `ping` (sent when a hook is created) runs a full poll. Deliveries whose
`X-Hub-Signature-256` does not verify get `401` and are logged without their payload. The timed
poll keeps running and catches up on anything the relay drops while the Mac sleeps or Symphony
restarts. The dashboard's GitHub webhooks card shows whether webhooks are on, when the last
delivery arrived, and how many CI results came through the relay and how many by polling. See
[github-webhooks.md](github-webhooks.md) for relay setup on macOS.

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

### `human_actions`

Posts a Linear project update listing everything only a person can do in a project, with the steps
to do it, so the person finds out from Linear (on a phone too) rather than from scattered comments.
On by default with a Linear tracker.

```yaml
human_actions:
  enabled: true
  label: human-action
  interval_ms: 300000
  min_update_interval_ms: 900000
```

- `enabled` (default `true`): `false` turns it off for every repository. A repository can turn it
  off for its own issues in its `WORKFLOW.md` front matter:

  ```md
  ---
  human_actions:
    enabled: false
  ---
  ```

  With it off, Symphony reads none of that repository's issues for human actions, and
  `linear_request_human_action` refuses with `human_actions_disabled` so the agent writes a plain
  blocker comment instead.
- `label` (default `human-action`): the label that marks an issue as needing a person. The agent
  tool adds it, creating it in the issue's team the first time when the workspace has none.
- `interval_ms` (default `300000`): how often Symphony reads the open actions. A read is one Linear
  request per repository route, plus one per project the first time Symphony sees it, plus one per
  update posted. They show as `human_actions` in the dashboard's Linear usage table.
- `min_update_interval_ms` (default `900000`): the least time between two updates to one project. A
  change inside that window is posted once the window has passed, with whatever is open by then.

**Where actions come from.** On each read, in the scope each repository route polls, Symphony
lists:

- each open `## Action needed:` comment on an issue with the label. Agents post one with
  `linear_request_human_action` (`title`, `why`, `steps`, optional `unblocks` and `est_minutes`)
  when they hit something only a person can do: a missing secret or permission, an account to set
  up, a product decision, a check on a device. Then they follow the blocked-access escape hatch as
  usual, and its move to `Backlog` lands in `issues.states.human_review`. A request whose title
  matches one still open on the issue is not posted again. An agent that finds its request is not
  needed after all withdraws it with `linear_withdraw_human_action` (`reason`, optional `title`):
  Symphony replies `## Action withdrawn` with the reason under the request, which closes it, and
  removes the label once no open request is left on the issue, and then the run's move to
  `Backlog` stays in `Backlog`;
- an issue with the label and no such comment, as a task in itself (its description's list items
  become the steps);
- a plan ticket in `In Review` or `Human Review`, waiting for its plan to be approved;
- an issue in `In Review` or `Human Review` whose `## Symphony QA Report` has the verdict `blocked`;
- a `Final verification:` ticket whose Auto Review parent walkthrough had the verdict `blocked`,
  such as a QA host without the macOS app's Screen Recording and Accessibility permissions. It is
  listed in the update of the parent's project, as "Grant the QA host's permissions for the final
  verification of <parent>" when the report's reason or blocked steps name a permission (with the
  System Settings steps) and "Unblock the final verification of <parent>" otherwise, with the
  reason and the blocked steps from the QA report, and how the walkthrough runs again. Failing
  steps the walkthrough could still run are filed as gap tickets as before; a walkthrough that
  fails on defects alone (verdict `fail`) adds no action. Reading these tickets adds them to the
  same query, at no extra request;
- any other issue in `Human Review`, as "Review <issue>", with the moves that approve it, send it
  back or sign it off;
- with `pull_requests.checks.enabled`, a GitHub Actions workflow on the repository's base branch
  (`repositories[].base_branch`, default `main`) that keeps failing on a missing secret: its two
  latest finished runs failed (cancelled and skipped runs aside), and the failed-step log of the
  latest names a secret as missing, as an empty `${{ secrets.X }}` or a message such as
  `secret X is not set`, `Missing secret: X` or `the X secret is empty`. Each secret named becomes
  one action, "Add the `X` secret", with the steps to add it in the repository's Settings → Secrets
  and variables → Actions, the failed run to re-run, and the workflow it unblocks. It belongs to no
  issue, so it is listed in the update of every project the repository routes (its `projects`, else
  `issues.linear.scope.project_slug`); a repository routed by team or label alone has no project to
  post to, and its workflow runs are not read. Only the secret's name is taken from the log, never a
  value.

  Each read costs one `gh run list` per repository, plus one `gh run view --log-failed` per
  workflow whose latest run is newly red twice in a row: a run's log is read once, as the CI poller
  reads a PR's. Finding the repository's projects costs one Linear request per repository, the
  first time one of its workflows fails this way. When GitHub or Linear cannot be read, the
  repository's last actions stay listed.

A supervisor or a person adds an action by hand the same way: put the label on the issue, and
optionally a comment in the request format:

```md
## Action needed: Turn on the pre-push hook

**Why:** Pushes skip the format and credo checks without it.
**Unblocks:** clean pushes from your laptop
**Time:** about 2 min

**Steps:**
1. In your checkout, run `git config core.hooksPath .githooks`.
```

Only the heading is required.

**When an action closes.** A request closes when its issue moves on: after the request, the issue
leaves a state a person moves it out of (anything but `issues.states.active`, the waiting state and
the Auto Review state), such as `Backlog` back to `Todo`. The agent's own move to `Backlog` keeps it
open. Removing the label closes every action on the issue, and so does a terminal state. A plan
review closes when the parent leaves its review state, and a blocked QA pass when the issue leaves
its review state or its next QA report is not `blocked`. A blocked final verification closes when
its next walkthrough is not `blocked`, or when the ticket leaves the state the walkthrough moved it
to (`In Review`, `Human Review` when only a person can do the steps left, or `Todo` while gap
tickets for its failing steps block it). A Human Review action closes when the issue leaves
`Human Review`. A missing secret closes when the next run of
its workflow on the base branch is green. Closed actions drop out of the next update.

**When Symphony posts.** A project gets an update only when its set of open actions differs from
the set in the last update Symphony posted there, never just because a poll ran. When the last
action closes, one short "Nothing needs you" update says so, and nothing more is posted until a new
action opens. Each new action is also sent as a `human_action_needed` notification on the
configured `notifications` channels. After a restart Symphony reads the list id back from the
project's recent updates, so it does not post the same list again. A project whose every action
closed while Symphony was stopped keeps its last update until a new action opens.

**The update.** It is written to be read on a phone and acted on without opening anything else:

- one numbered heading per action, so the list scans on a narrow screen;
- under it, how long it takes and what it unblocks, so the reader can pick what to do first;
- the why, then the steps as a numbered list, one instruction per line (no tables, which scroll
  sideways on a phone);
- a closing **Done when** line, saying how the action leaves the list;
- actions on tickets in `Human Review` first, marked with the state, since only the reader can move
  those on; then quickest first, so a short session clears the small ones;
- a footer with the list id, which is how Symphony recognises its own last update.

The update sets the project health: `atRisk` while any action is open, `onTrack` when none is.
Symphony cannot judge the schedule beyond that, so it never sets `offTrack`; this replaces the
health set by the project's previous update. No secret value reaches an update:
`linear_request_human_action` refuses any field that holds a secret pattern, and the whole update
is redacted again before it is posted, which covers secrets pasted into an issue or comment by hand.

A rendered example, for a mix of a missing secret, a plan, a hand-labelled task and a
blocked QA pass:

```md
**4 actions need you.** Quickest first.

### 1. Add the release signing secrets

**~10 min** · Unblocks [MOT-24](https://linear.app/acme/issue/MOT-24): the Release workflow on `main`

**Why:** Every Release run on `main` fails at the signing step without them.

1. Open github.com/acme/cycle → Settings → Secrets and variables → Actions.
2. Add `MACOS_CERTIFICATE` with the base64 of the Developer ID certificate (.p12).
3. Add `MACOS_CERTIFICATE_PASSWORD` with its password.
4. Move MOT-24 to Todo.

**Done when:** you remove the `human-action` label from MOT-24, or move it on once it is unblocked.

### 2. Approve the plan for MOT-40

**~10 min** · Unblocks [MOT-40](https://linear.app/acme/issue/MOT-40): its sub-tickets, waiting in Backlog

**Why:** MOT-40 is split into sub-tickets, and none of them starts before you approve the plan.

1. Read the plan in the `## Symphony Workpad` comment on MOT-40.
2. To approve, move MOT-40 to `Waiting on sub-tickets`; Symphony moves its sub-tickets to Todo.
3. To reject it, comment what to change and move MOT-40 to `Rework`.

**Done when:** MOT-40 leaves In Review.

### 3. Turn on the pre-push hook on your laptop

Tracked in [MOT-31](https://linear.app/acme/issue/MOT-31)

1. Run `git config core.hooksPath .githooks` in your cycle checkout.

**Done when:** you close MOT-31, or remove its `human-action` label.

### 4. Unblock QA for MOT-52

Unblocks [MOT-52](https://linear.app/acme/issue/MOT-52): the review of its PR

**Why:** Auto Review could not test the PR: the QA host has no Screen Recording permission for the app.

1. Fix the cause above, on the machine QA runs on.
2. Then test the PR yourself and move MOT-52 to `Merging` to approve it, or to `Rework` to send it back.

**Done when:** MOT-52 leaves In Review, or its next QA report is not blocked.

---
_Symphony posts a new update when this list changes · list `6b00e3cd`_
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
push_check:
  command: scripts/push-check
verification:
  dev_server:
    start_cmd: "pnpm dev --port $SYMPHONY_VERIFICATION_PORT"
    health_check_url: "http://localhost:${SYMPHONY_VERIFICATION_PORT}/healthz"
validation:
  - mix test
auto_review:
  playbooks:
    macos_app:
      paths: ["macos/Sources/**"]
---

You are working on {{ issue.identifier }}.
```

The front matter accepts only `hooks`, `prompts`, `verification`, `validation` and
`auto_review.playbooks`; any other key fails the repository's workflow. `hooks`, `verification`
and `auto_review.playbooks` are merged over `symphony.yml` key by key, with the repository's value
winning (see [`auto_review`](#auto_review) for playbooks).

The body is the repo-specific issue prompt template. `prompts.pr` is used for explicit PR runs.
Before either rendered template, Symphony injects a managed runtime context with workspace,
untrusted-input, scoped-tool, workpad, secret-handling, and final-response rules. `WORKFLOW.md`
should add repository commands, conventions, validation gates, and handoff policy rather than
duplicating those Symphony-owned rules. The repo workflow front matter is intentionally small;
operator/runtime settings belong in `symphony.yml`.

### Workspace hooks

`hooks` runs shell scripts in the workspace at four points: `after_create` (when the
workspace is new), `before_run` and `after_run` (around every run), and `before_remove` (before the
workspace is deleted). A failing `after_create` or `before_run` fails the run; `after_run` and
`before_remove` failures are logged and ignored.

```yaml
hooks:
  after_create: |
    mise exec -- mix deps.get
  timeout_ms: 60000                 # every hook; default 1 minute
  after_create_timeout_ms: 900000   # after_create only; optional
```

- `timeout_ms` bounds each hook run. It defaults to 60000 (1 minute).
- `after_create_timeout_ms` bounds `after_create`, which usually installs dependencies. When it is
  unset, `after_create` gets the larger of `timeout_ms` and 600000 (10 minutes).
- When a hook times out, Symphony logs its last 20 output lines (`output_tail=`), so a hang can be
  told apart from a slow install. A hook on this machine is stopped, with everything it started.
  For a hook on an SSH worker, Symphony closes the `ssh` session, but the hook can keep running on
  the worker.
- A timed-out `after_create` on this machine is run once more, in the same run and the same
  workspace, so it can pick up whatever the first try got done; the retry doesn't count as an agent
  attempt. Write `after_create` so it is safe to run twice. A second timeout fails the run.
- When `after_create` on this machine fails or times out, the workspace is kept, and the next run
  runs `after_create` again in it before the agent starts. Until it succeeds once, Symphony keeps
  an empty `.<issue>.after_create_pending` file beside the workspace.
- A timed-out `after_create` on an SSH worker is not retried, and the next run doesn't run it again
  either, since the first try may still be running there. The timeout fails the run.
- While `after_create` or `before_run` runs, the agent stall timeout (`agent.timeouts.stall_ms`, 5
  minutes) and the watchdog (`watchdog.no_progress_threshold_ms`) wait for the hook's own timeout,
  so a long install isn't ended as a stalled run. Their clocks start again when the hook ends.
- A run that is stopped while a hook runs on this machine stops the hook too.
- Hooks run outside the agent sandbox, so a worktree's `after_create`, on this machine or an SSH
  worker, runs on the base branch's tree: even when the worktree is created on a branch an agent
  already pushed to (a rework, a PR run, a workspace made again), Symphony detaches it at the base commit for the hook
  and checks the branch out again afterwards. The worktree's ignored files (`deps/`, `_build/`) are
  removed before the hook, which installs them again. A worktree with uncommitted changes skips the
  hook with a warning. `before_run`, `after_run` and `before_remove` run in the agent's checkout, so
  they should run nothing from it. See [security](security.md#workspace-hooks-run-outside-the-sandbox).
- A hook on this machine runs Gradle without a daemon: Symphony appends `-Dorg.gradle.daemon=false`
  to the host's `GRADLE_OPTS`. Gradle then never hands the hook's build to a daemon an agent
  started inside its sandbox, and the hook leaves no daemon behind.

Each repository's `WORKFLOW.md` sets its own hooks and timeouts.

### Push check

`github_push_branch` pushes through Symphony, outside the agent sandbox, with repo git hooks turned
off: Symphony never runs a script the agent can edit. `push_check` holds those pushes to the
repo's own checks instead. The agent runs `command` in its sandbox; the command writes
`<sha> pass`, or `<sha> fail` followed by one failure per line, to `result_file`. Symphony only
reads that file.

```yaml
push_check:
  command: .githooks/pre-push --head  # shown to the agent; Symphony never runs it
  result_file: tmp/push-check         # workspace-relative; default tmp/push-check
  paths: ["*.ex", "*.exs", "mix.lock"] # git pathspecs; default [] means any file
```

- A push changes the files between the branch's `origin/<branch>` ref, or else its merge-base with
  `origin/HEAD` (`origin/main`, `origin/master`), and the commit it pushes. When none of them
  matches `paths`, the push goes ahead without a result, after a couple of `git` reads.
- Otherwise the tool refuses the push until `result_file` records `pass` for the exact commit it
  pushes. The refusal says whether the result is missing, is for another commit, or failed, and
  passes on the recorded failures and the command to run again.
- `result_file` is read only when it is a regular file of at most 16 KiB; a symlink is not
  followed. Keep it out of git (for example under an ignored `tmp/`).
- The check is off while `command` is unset. It doesn't apply to `git push` from the agent's shell,
  where the repo's own `pre-push` hook can run.
