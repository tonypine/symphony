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

- `tickets`
- `workspaces`
- `pull_requests`
- `code_review`
- `auto_review`
- `dashboard`
- `issue_gate`
- `watchdog`
- `dependency_audit`
- `notifications`
- `human_actions`
- `ledger`
- `dispatch`
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

Symphony reloads both files when they change. An edit it rejects (an unknown or removed key, an
invalid value, YAML that doesn't parse) does not stop it: it keeps running the last settings that
loaded, logs the reason, and lists the rejected file under `problems` in `GET /api/v1/setup`
(the key or line, the reason, and since when) until the file loads again. The same list warns
about each deprecated key the file still sets, with what replaced it and, for a key that does
nothing now, a fix that removes it. It also checks each repo's `route` against the tickets its
last poll fetched: tickets that don't route back to the repo (with a fix that adds their project
id to `route.projects`), a route value Linear has no project or team for, two repos taking the same
tickets, and a route that has matched nothing for 24 hours. It flags each repository with no Linear
team (an error), and one whose team is found only through its projects or tickets (a warning,
with a fix that sets `route.team`). In each routed Linear team it checks the labels Symphony
applies or reads (`Blocked`, `Needs Decision`, the CI labels, `plan`, `qa:skip`, the
`agent.concurrency.force_label`, each `escalate.labels` entry and the others), with a fix that
creates a missing one; a label one typo away from one of them; the deprecated `human-action`
label in `escalate.labels` (a fix removes it) or on open tickets; and tickets whose `Blocked` or
`Needs Decision` label disagrees with the hold Symphony keeps, with a fix that re-syncs the label.
It reports a repo that runs the
`macos_app` playbook with no QA VM set, and a QA VM that is this Mac (see
[Running QA in a QA VM](#running-qa-in-a-qa-vm)). `POST /api/v1/setup/fixes` runs a Linear fix the last check proposed, and
`POST /api/v1/setup/refresh` checks again at once; with `?repo=<key>`, either one keeps the
problems of that repo and the global ones. See [SPEC.md](../SPEC.md) for the problem shape.

## Settings in the macOS app

Every `symphony.yml` setting gets a control in the macOS app, or a person's exemption. When a
ticket adds a setting, its plan includes the control: in the same PR, or in a sibling sub-ticket
in the parent's plan, which the epic review checks, with a `## User walkthrough` for the new control.

CI enforces it. `mix settings.ui_coverage`, part of `mix lint` (so of `make all` and the `lint`
job), lists every setting as a dotted key path from the config schema
(`SystemSchema.operator_key_paths/0`), such as `auto_review.playbooks` or
`repositories[].route.team` for a key of every repository. It fails, naming each key, when a key is
in neither of these:

- **The app's manifest**, `SettingsUIManifest.keyPaths` in
  `macos/Sources/SymphonyBarCore/SettingsUIManifest.swift`: the keys the Settings, Models and
  Repos sections read and write, one string literal per line. A key holding a free-form map, such
  as `agent.run_profiles`, covers everything under it. A Swift test runs every line-editor write
  and fails when one writes a key the manifest doesn't list, or the manifest lists a key no editor
  writes. The task also fails when the manifest lists a key that is not a setting. It may list a
  path inside a setting that holds a map, such as `auto_review.playbooks.macos_app.requires`, when
  the app edits that one entry; the setting itself still needs its own entry or exemption.
- **The exemption file**, `config/settings_ui_exempt.yml`: entries with a `key` (a key path, or
  `prefix.*` for every key under the prefix, including later ones) or a `keys` list, a `reason`,
  and an optional `ticket` for the planned control. The task warns about an exemption that matches
  no setting or covers a key the manifest now lists, so a person can remove it.

Only a person can exempt a setting. The exemption file is an agent-protected path: the agent
sandbox denies writing it, and the `protected paths` check fails a Symphony PR whose own commits
change it. A person's decision that allows the change clears it for Symphony.

To add a setting: add its control to the app, list its key in the manifest, and extend the line
editor and its tests. To exempt one, a person adds it to the exemption file with the reason, in the
same PR; when the ticket reaches Merging Symphony asks them to allow the change, one pick in the Inbox. A person can
also let the ticket's next agent run edit the file by picking an option that allows it in the
ticket's decision request (see [Allowing a change to a protected path](security.md#allowing-a-change-to-a-protected-path)). `WORKFLOW.md` front matter (repo-owned settings) is not covered.

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
    code_review: Code Review
    qa: QA
    plan_review: Plan Review
    epic_review: Epic Review
    ci_fix: CI Fix
```

- `provider`: `linear` or `memory`. `memory` is a fake Linear for tests: it reads its issues from
  `memory.issues_file` (relative to the folder holding `symphony.yml`), a JSON list of
  `{"id", "identifier", "state", "title", "description", "labels"}` objects (with an optional
  `"team": {"key", "name"}` and `"project": {"id", "name", "slug_id"}`), on every fetch, so a test
  can change them while Symphony runs. Entries with `"kind": "project"` (`id`, `name`, `slug_id`) or
  `"kind": "team"` (`id`, `key`, `name`) are the fake workspace's projects and teams: a route that
  names a project by any of them polls its issues, as Linear does. A project's optional `"teams"`
  lists its team keys; without it, the project is in the teams of its issues. Comments and state
  changes go nowhere.
- `poll_interval_ms`: issue candidate polling cadence. Each scheduler tick costs roughly one Linear
  request per running, watched, and due-repo lookup (about 3 per tick with work in flight), so the
  default `30000` spends about 360 of a personal key's 2,500 requests/hour before agent tool calls.
  The dashboard's refresh line shows requests since the last poll and the budget Linear reports left.
  Below 10% of the hourly limit Symphony stretches this interval 2x (4x below 5%) until the budget
  recovers. When Linear answers `RATELIMITED`, Symphony pauses all Linear calls (polling, retries,
  agent tools) for one minute, then sends one probe request: if it succeeds, Linear calls resume; if
  not, the pause doubles, up to five minutes. A state move Symphony or the Director makes polls that
  ticket's repo at once, ahead of its stagger, so what the move unblocks dispatches within seconds.
  Moves made before that poll starts share it; a move made after it started, within two seconds of
  the first, is polled once more two seconds after the first.
- `linear.scope`: default Linear scope. Repo routes can narrow or replace this per repo.
- `states.active`: issue states eligible for dispatch.
- `states.terminal`: states that stop active runs and allow cleanup.
- `states.waiting_on_sub_issues`: the state a plan ticket (label `plan`, or `breakdown`, its older
  name) waits in while its sub-tickets are
  worked, default `Waiting on sub-tickets`; `null` turns it off. It counts as active without being
  listed in `states.active`, but an issue in it is dispatched only for the epic review, once it is
  a plan ticket whose sub-tickets are all terminal: Symphony moves it to `states.epic_review` and
  runs the review there. Any other ticket whose PR merges with a
  sub-ticket still open outside `Backlog` moves here instead of `Done`; Symphony moves it to `Done`
  itself, with no run and a comment listing how each sub-ticket ended, once every sub-ticket outside
  `Backlog` is terminal; one a person moves here waits for them. `Backlog` sub-tickets stay there for a person to promote and hold nothing: with only those
  open the ticket goes to `Done` on merge. With the state off it
  goes to `Done` on merge as before. Tickets that went `Done` before this wait existed are not
  revisited: `mix symphony.done_with_open_subtickets --config /path/to/symphony.yml` lists every
  parent in a terminal state with sub-tickets still open, without changing anything. When it cannot
  read a repository, it names that repository above the list and exits non-zero. The plan
  run ends with the parent in `states.plan_review` and its sub-tickets in `Backlog`. A human
  approves the plan by moving the parent
  from `states.plan_review` to this state, and on the next poll Symphony moves every sub-ticket still in
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
    already made, files what is left and hands the parent over to `states.plan_review`. Use it after a plan run
    stopped midway, for example on Linear's usage limit.
  - **Revise:** a person's comment on a parent in `states.plan_review` whose plan is not approved
    moves it to `Rework`, and the plan run edits the plan in place: it rewrites the artifact
    comments, updates, files or cancels `Backlog` sub-tickets (`linear_update_subissue` refuses
    any other), replies under each comment and hands the parent back to `states.plan_review`. Only
    `states.plan_review` triggers it. Symphony's own comments (the review brief, headed
    `## Review brief`, among them), a supervisor's notes
    (starting `Supervisor review:` or `Supervisor note:`) and integration bots' comments start
    nothing. A comment made while the run works
    is picked up once the parent is back in `states.plan_review`, unless the run answered it. A comment on
    an approved plan changes nothing: under a new top-level comment Symphony replies once that, if
    it asks for a plan change, `Rework` re-plans it.
  - **Re-plan:** moving the parent to `Rework` makes the plan again from scratch, as above.

- `states.human_review`: retired with the `Human Review` state. A config that still sets it loads
  with a deprecation warning and the key is dropped: a decision request pauses the ticket in its
  phase on a **Needs Decision** hold, and a plan waits in `states.plan_review`. `In Review` and
  `Human Review` are retired states (`TransitionGuard.retired_states/0`): the guard refuses every
  move into them, and at startup Symphony logs each ticket still in one at error level and lists
  it in the dashboard's **Drain report** with the move that frees it.

- `states.code_review`, `states.qa`, `states.plan_review`, `states.epic_review` and `states.ci_fix`:
  the machine-owned phase states — the board columns — defaulting to `Code Review`, `QA`,
  `Plan Review`, `Epic Review` and `CI Fix`; `null` turns one off. At startup Symphony finds each
  one in the configured teams (the `issues` team and each repository's: its `route.team`, else the
  teams of the projects its route names, else the teams of the tickets it polls) and creates it as a started state when it is missing, logging what
  it created; a second start finds them all and creates nothing. A state renamed or deleted in
  Linear is reported at startup with its exact name and the `issues.states.*` key to point at the
  new name, and is then recreated, so a name is never silently duplicated. The
  machine enters them and dispatch picks them up — `Code Review` for the reviewer run, `QA` for the
  QA pass, `CI Fix` for mechanical repair, and `Epic Review` for the automatic close of a plan
  parent whose sub-issues are all terminal (pass -> `Done`; gaps -> each defect filed as a follow-up
  sub-ticket in `Todo` under the same epic with the epic's priority, with the parent back in
  `Waiting on sub-tickets`). They sit in Linear's `started` group, beside `In Progress`, so they
  read as active columns;
  `states.plan_review` is the one person-owned state of the five: it is never dispatched, and an
  issue in it waits for the person reviewing the plan.

For Linear, configure at least one global scope under `issues.linear.scope` or repo-level route
selector under `repositories[].route`.

### `tickets`

Which tickets may start new work, by Linear priority. Empty (the default) lets every priority
start.

```yaml
tickets:
  priorities: [urgent, high]
```

- `priorities`: the Linear priorities allowed to start new work: `urgent` (1), `high` (2),
  `medium` (3), `low` (4) and `none` (0, Linear's "No priority"). The numbers `0`–`4` and
  `no priority` are accepted too, and an issue Linear reports with no priority reads as `none`.
  An issue whose priority is not listed is not dispatched: Symphony waits with free lanes even
  when it sits in an active state such as `Todo`. Use it to focus a limited API budget, for
  example on `[urgent, high]` only. It never stops a forced ticket (`agent.concurrency.force_label`)
  or a run already under way (a retry waiting for a slot), so it only gates fresh picks. Empty or
  `null` turns the filter off. `/api/v1/state` lists each ticket it holds back under
  `dispatch_skipped` (`priority medium is not in tickets.priorities (urgent, high)`).

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
    fetched). The committed file is copied to `<state root>/workflows/<key>/`.
    A workflow whose body is `{% render "playbook" %}` takes its instruction files from the same
    ref, and the copy holds the expanded text (see [playbook](playbook.md#the-whole-playbook-in-one-line)). If the file is
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
- `base_branch`: optional branch used for the Code Review reviewer's diff context and as the
  base a new worktree branches off (preferring `origin/<base_branch>`); when unset, a new
  worktree branches off the source repo's current HEAD.
- `route`: Linear team, project, label, or assignee selectors.
- `workspace`: per-repo override for workspace population (`strategy`, `repo`,
  `fetch_before_dispatch`), or `source` for a repo Symphony clones itself (see below).
- `agent`: per-repo `provider`, `model`, `effort` and `run_profiles` for issues routed to this
  repo. They take the same values as the `agent` keys and win over them field by field; see
  **Run profiles** under `agent`. Errors name the key, e.g. `repositories[web].agent.effort`.
- `acceptance_gate`: deprecated with the retired acceptance gate (see
  [`auto_review`](#the-retired-acceptance-gates-escalation-rules)). Its `escalate` rules add to the
  global ones and feed this repo's Code Review; its `mode` sets `manual_review` when that is unset;
  `max_turns` and `timeout_ms` do nothing.
- `state_machine`: retired. Every repo runs the one ticket state machine of
  [`docs/design/state-machine.md`](design/state-machine.md); a config that still sets the key loads
  with a deprecation warning and the key is dropped. Dispatch picks up `states.active` and the
  phase states (`states.code_review`, `states.qa`, `states.epic_review`, `states.ci_fix`), never
  `states.plan_review`: it is the epic path's person-owned plan review — where a plan parent's
  handoff lands, and where the person reviewing the plan approves it or sends it back. Work is
  reviewed in the `Code Review` state, so the reviewer must be on: with `code_review.enabled`
  off, `Code Review` tickets are parked (a `code_review_reviewer_disabled` signal is recorded)
  instead of being dispatched. A
  `Code Review` run also checks the repo's `auto_review.acceptance_gate.escalate` rules before its
  reviewer starts, and runs the reviewer once per head. A risk rule (`paths`, `diff_patterns`,
  `dependencies`, `max_changed_lines`, `busy_files`) puts its finding in plain words in the
  reviewer's instructions and in the verdict's summary — the size as added, changed and removed
  lines — so the one review weighs it. On an approval, a person rule (`labels`,
  `ticket_patterns`), and a risk rule whose `escalate.on_match` key is `ask` (default `inform`),
  pauses the ticket on a **Needs Decision** hold whose confirmation continues into QA; otherwise the
  approval routes at once. A reviewer block, or a review still
  inconclusive after two retries, pauses the ticket on a Needs Decision hold too. See
  [`docs/design/state-machine.md`](design/state-machine.md).
- `manual_review`: who decides that a verified ticket merges, `off` (the default) or `on`
  ([`docs/design/state-machine.md`](design/state-machine.md), **Manual review**). It controls
  decision authority on the ticket path, not verification: the machine verifies the same way either
  way. `off` moves the ticket on its verdicts — Code Review approve → QA, QA pass → Merging. `on`
  pauses the last step into Merging on a person: the verdict carries a **Needs Decision** hold whose
  request is the summary to decide from (the recommendation, the Code Review reasons, the QA result
  and the PR link), and confirming continues into Merging exactly as when `off`, while a redirect
  (Send to Rework) directs a move instead. Rework verdicts, CI Fix and holds behave the same in both
  modes, and the epic path is unaffected. The macOS Repos edit sheet sets it with a Manual review
  picker.

  The retired `auto_review.acceptance_gate.mode` (and a repo's `acceptance_gate.mode`) is deprecated
  and maps onto this setting, with a warning logged once per config: `shadow` → `on`, and `off`,
  `enforce` and `decide` → `off`; `watch` was operator monitoring, not a person stopping the ticket,
  so it is `off` too. A repo's own `manual_review` wins over whichever mode applies to it, and a
  repo that sets no `manual_review` keeps the mode's answer.

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
`CLAUDE_CODE_TMPDIR` and to a Codex agent as `TMPDIR`, and writable in its sandbox. A Code Review
run's reviewer gets it too. So the agent's `$TMPDIR` is the run's own, and concurrent runs no
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
  daemons register in its own workspace (git ignores the folder, and the QA `qa_build`
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
  (`code_review.model`, `auto_review.model`, `repositories[<key>].agent.run_profiles.<kind>.model`,
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
  `breakdown` (plan ticket in `Rework`), `epic_review` (a plan ticket whose sub-issues are all
  terminal: the epic review), `breakdown` (other plan ticket: a new, resumed or revised plan),
  `landing` (`Merging`), `code_review` (`Code Review`), `qa` (`QA`), `rework` (`Rework`), `ci_fix`
  (continuation after red CI), `review_feedback` (continuation after PR review comments), and
  `implementation` (everything else). `close_out` named the retired legacy machine's close-out
  run: it still loads and matches no run. `code_review` names the Code Review run and its
  reviewer, and `qa` the QA agent's runs. `pre_push_review` named the removed pre-push reviewer:
  it is refused at load (see [`code_review`](#code_review)). `acceptance_gate` is deprecated with
  the retired gate, and `final_verification` with the retired `Final verification:` tickets: each
  loads with a warning and does nothing.
- Resolution per field, for the repository the issue is routed to:
  `repositories[].agent.run_profiles.<kind>`, then `repositories[].agent.<field>`, then
  `agent.run_profiles.<kind>`, then `agent.<field>`, else nothing is added (provider:
  `anthropic`). A repository without an `agent` block resolves from the `agent` section alone. Code
  Review's reviewer and the QA agent check their own section first: `code_review.model` /
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
  `--model` / `--effort` flags in `agent.command`, `code_review.command` and
  `auto_review.command`, and its errors name `repositories[<key>].agent...`.
- The kind and profile are chosen once, when the run is dispatched, from the current workflow
  config: an edit applies to the next dispatch without a restart. Every continuation turn of a run
  keeps its profile. A CI fix or review feedback re-activation is a new run with its own kind.
- The run history record keeps `run_kind`, `model` and `effort`, and the dispatch log line shows
  `run_kind=… model=… effort=…` (`default` when nothing is added). A `review_feedback` dispatch
  also names the latest pending PR comment it answers: `trigger_comment_id=…
  trigger_comment_author=… trigger_comment="<first line>" pending_comments=<n>`. Code
  Review's reviewer runs inside the Code Review run, so that run's record also keeps
  `reviewer_profile` next to `reviewer_tokens`; other runs record no reviewer profile. A QA run's
  record keeps its own `run_kind: qa`, `model` and `effort`.
- The Mac app and the terminal status dashboard show the kind, model and effort of each
  running run (and its reviewer's, for a Code Review run) and of the recent runs.
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
  of these is free. Values below `1` fail `symphony check`.
- `concurrency.force_label` (default: `expedite`) is the label a human puts on a ticket to have it
  worked now, through to Done (matched case-insensitively). Symphony records when a poll first
  sees a ticket in an active state (`tracker.active_states`) carry it (`forced_since`, kept across
  restarts); a ticket labelled in another state, such as `Backlog` or `Plan Review`, joins once it
  moves into an active state. Once queued it stays listed in any non-terminal state (`Plan Review`,
  `Merging`, ...). `/api/v1/state` lists the forced tickets (`forced`), earliest first with their
  `title`, `repo_key`, queue `position`, `forced_for_seconds`, `stale`, a `phase` (`implementation`, `rework`,
  `review_feedback`, `ci_fix`, `waiting_on_ci`, `waiting_for_human`, `landing`, `code_review`, `qa`,
  `breakdown`, `epic_review`), whether an agent is `running` for it,
  what it `waiting_on` (`slot`, `human`, `ci`, `blocker` with the open `blockers`' identifiers,
  `usage_limit`, `paused`, `backlog`, or null) and a one-line `summary` such as
  `implementation · running` or `implementation · waiting on blocker TP-12`. A forced plan
  ticket's phase is its current part's. The terminal dashboard and the Mac app show a "Forced" section
  above the running agents (identifier, phase, waiting on, forced for), a ⚡ on forced rows elsewhere,
  and the forced count over `forced_max` in the header. When a forced plan ticket enters
  `Plan Review`, Symphony sends a `forced_human_gate` notification saying it
  is waiting for your review, again each time it comes back to `Plan Review`. A ticket leaves the list
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
  landing, and the `Code Review`, `QA` and epic review runs. Its run is marked `forced` (`/api/v1/state` `running[].forced`) and takes none of the
  normal slots; a run already going when the label is added stays a normal run, and no running
  agent is stopped. Once the label is removed (or a forced parent's is), a forced run already
  going gives the allowance back and goes on as a normal run, so a ticket still forced can take it.
  A forced ticket past `forced_max` gets no extra slot: it still goes first for a
  normal one, waits as `queued #2; forced slot taken by MT-1` in `slot_waiting`, and Symphony logs a
  warning and sends one `forced_waiting` notification naming the forced run holding the allowance.
  The daily token budget and a usage-limit headroom hold don't stop a forced ticket (a warning is
  logged when the budget would have); the per-issue token cap still does. The operator Pause, the
  Linear rate-limit pause, the workspace quota pause, `max_concurrent_agents_per_host`, blocked-by
  links, a failed setup, retry backoff, auto-merge and `Merging` CI waits, and a usage-limit pause
  still hold it; when a usage-limit pause resumes, a held forced ticket goes out first.
  A forced plan ticket is one forced unit. Its plan, re-plan and epic review runs use the
  allowance like any forced ticket. While it waits on its sub-tickets, one ticket on its epic path
  at a time (its sub-tickets at any depth and their open blockers, picked in epic-lane order, so
  blocked-by links keep their order) counts as
  forced in the parent's place in the queue, without the label being written on it. It keeps that
  until it leaves the path or stops running or waiting on a retry. The other sub-tickets use normal slots and the epic lane.
  `/api/v1/state` shows it as the parent's `forced[].sub_issue`. Forcing never approves a plan: a
  forced parent in `Plan Review` stays there, shown with
  `forced[].waiting_on_human: true` (as is any forced ticket in `Backlog`, `Triage` or `Plan Review`).
  Forcing a sub-ticket itself forces only that sub-ticket.
- `concurrency.forced_stale_after_hours` (default: `72`) is how long a ticket may stay forced before
  it counts as stale: `/api/v1/state` marks it `stale: true`, the dashboards flag it, and Symphony
  logs a warning and sends one `forced_stale` notification (once per forced ticket, also across
  restarts). Values below `1` fail `symphony check`.
- Dispatch goes forced tickets first, then closest to done: `Merging`, `Rework`,
  resumes such as `In Progress`, then `Todo`; priority and age only break ties within a stage.
  While a `Merging` ticket waits for a finishing slot no `Todo` ticket starts; `Rework`,
  resumes and a forced ticket on the forced allowance still do, and the held ticket's reason names
  what it waits for (`MT-2 (Merging) is waiting for a finishing slot`). A ticket that finds no free slot
  is not retried with backoff: it keeps its
  attempt and starts on the first poll after a slot frees (a run ending triggers that poll). The
  dashboard and `/api/v1/state` show the landing runs (`finishing`) and what is waiting for a slot
  and why (`slot_waiting`). A `Merging` ticket held while CI runs on its head is listed there as
  `waiting for CI on <sha>`; it doesn't count as waiting for a slot, so it doesn't hold back `Todo`.
  `/api/v1/state` also lists the issue ids Symphony holds a claim on (`claimed`); a claim with no
  running agent, retry or slot wait is released at the end of the next poll. Every other candidate
  the last poll passed over is listed under `dispatch_skipped` with the gate that held it (`blocked
  by MT-2`, `on a Needs Decision hold`, a usage limit, the `tickets.priorities` filter, ...) and
  since when.
- `concurrency.max_by_issue_state` can cap work independently for specific issue states such as
  `rework`.
- `limits.max_turns` caps how many back-to-back turns Symphony will run in a single worker
  invocation when a turn completes but the issue is still active. Codex reuses one `threadId`
  across these turns; Claude relaunches per turn (workspace + prompt provide continuation).
- `timeouts.command_ms` caps a single shell command. Set `0` to disable.
- `timeouts.stall_ms` (default `300000`, 5 minutes) restarts a run whose agent has not produced its
  first transcript event for that long. Like the watchdog, it acts only on a run whose silence is
  proven: one with no session id and no agent event is unobserved and never restarted (see
  [`watchdog`](#watchdog)). Set `0` to disable.
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
  dispatching, and a weekly Opus limit holds only Opus runs. A limit for another provider that a
  run itself sees also leaves that run alone: an OpenRouter run through the Claude runtime can see
  the Claude subscription's window, which records the Claude hold but lets the OpenRouter run retry
  with the normal backoff instead of waiting for the Claude reset. Codex runs (`agent.kind: codex`) are
  their own provider (`openai`): a Codex limit holds only Codex runs, and a Claude limit never
  holds them. `false` keeps the old behaviour: the
  run fails and retries with the normal backoff.
- `usage_limit.resume_margin_seconds` (default `120`, `>= 0`): added to the reset time the provider
  reports before runs resume.
- `usage_limit.unknown_reset_retry_seconds` (default `900`, `>= 60`): how long the hold lasts when
  no reset time is known (neither in the rejection nor remembered for that window). It also caps
  the wait between probes while Claude or Codex can't reach its API (a network or DNS outage): that hold
  starts whatever `auto_pause` says, probes after 60 seconds and doubles the wait after each
  failed probe. A released outage hold is remembered this long (at least 10 minutes), so a QA run
  that finds the outage again keeps the backoff.
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
  `## Project conventions` prompt section. A prompt that ends in an output contract, such as the
  reviewer's verdict, gets the section above that contract, so the contract stays last.
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
`$NAME` (so misconfigurations surface at the MCP server's own startup), and Setup
(`GET /api/v1/setup`) reports it as a `secrets` error naming the key and the variable. Embedded
references (`"Bearer $TOKEN"`) are **not** expanded - use a whole-value reference or pre-compose
the literal.

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
    max_fix_attempts: 10
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
- PR polling runs the PR and CI watcher ([PR and CI decisions](pr-ci-decisions.md)): each poll it
  reads every watched ticket's PR, decides what its phase and PR call for, and acts. A PR that
  conflicts with its base branch sends the ticket to `CI Fix` with the conflict's context in the
  next prompt; the agent still owns the merge resolution. A ticket on a `Blocked` or `Needs
  Decision` hold is never moved by its PR: it waits for the hold to clear.
- `review_comments.ignored_reviewers` skips those accounts entirely. The Linear GitHub
  integration's linkback comment is always skipped: comments by `linear-code`, `linear-code[bot]`
  or `linear[bot]`, and any comment whose body starts with `<!-- linear-linkback -->`. Comments
  from the PR author and the current `gh` user still count as review feedback, so your own review comments on an
  agent PR send the issue back to work on the same PR. Symphony ends every PR comment it posts
  with a hidden `<!-- symphony:agent -->` marker and skips those.
- `checks.retry_failed_once` reruns the failed jobs of a red head once before a `CI Fix` run.
- `checks.max_fix_attempts` (default 10) is a backstop for the `CI Fix` runs sent for failed
  checks, not a budget. Once that many were sent for red heads, or 3 runs in a row met the same
  failure (the same check and first error line) whatever the count, the backstop stops them: it
  files a fix ticket for the failing check (self-heal component `ci:<check>`), or reuses the open
  one, and holds the ticket on it with a `Blocked` hold, in place, instead of asking anyone (D15).
  The hold clears by itself once the fix ticket is done, and the count restarts. Conflicts have no
  limit that asks: a conflict gets 3 fix runs whatever this says; back after those, the ticket waits
  on the open PRs that share its files, as a `Blocked` hold and Linear blocked-by links (D14), or
  goes to `Rework` when none does (D16). Both counts reset once the PR is green and conflict-free.
  See [When CI keeps failing](pr-ci-decisions.md#when-ci-keeps-failing) and
  [Competing PRs](pr-ci-decisions.md#competing-prs). `checks.escalate_to_state` is deprecated: it
  loads with a warning and does nothing.
- `checks.landing_wait_timeout_ms` bounds how long a `Merging` PR may stay `BLOCKED` by branch
  protection on a green head before a landing agent takes it over, and how long a landing run that
  ended on pending checks waits for its head to settle. In any phase it is also how long a head waits
  for a check its base branch requires before a person is asked whether to go on without it, and
  how long a head with no check at all waits for its first one when the base branch has workflows
  (a base without workflow files has no CI, which counts as green).
- `auto_merge` (default: `true`, needs `enabled: true`) lands `Merging` tickets with GitHub
  auto-merge instead of a landing agent, so they take no agent slot:
  - A ticket Symphony moves into `Merging` is looked at right away. A PR that is already `CLEAN`
    with green checks (or none) is squash-merged at once, before the base branch can move on and
    leave it behind; otherwise auto-merge takes it.
  - Symphony turns on auto-merge (squash, the PR title and body) once per PR head. GitHub merges it
    when the required checks pass, and Symphony moves the ticket to `Done` (or to the waiting state
    when started sub-tickets are open). When GitHub refuses auto-merge (the PR can already merge, no
    branch protection, or the repository doesn't allow it), the PR is squash-merged once it is
    green and can merge. A head that moved under the call is read again on the next poll.
  - A PR that is `BEHIND` the base branch gets one GitHub "Update branch" per head; CI runs on the
    merged code and auto-merge fires when it passes. The CI runs still going on the head it
    replaced are cancelled. A PR that waits for another to land first (see the landing order below)
    is updated once that one has landed. This branch upkeep is not a landing step: it runs for an
    open PR in every phase, whatever this setting says, whenever no run is working on the ticket
    (U1 in `docs/pr-ci-decisions.md`).
  - A red head first gets one rerun of its failed jobs, with auto-merge left on. A `CI Fix` run
    after that, or one for a merge conflict, turns auto-merge off before it starts: the fix goes
    back through review, and the ticket's return to `Merging` turns auto-merge back on. Auto-merge
    is never turned on while the PR conflicts. The audit log (`auto_merge_disabled`) and a ticket
    comment record it.
  - A failed `protected paths` check holds the PR back even though the base branch doesn't require
    it: auto-merge goes off and the ticket waits in `Merging` on a Needs Decision hold, unless a
    decision on the ticket unlocks every protected path the PR changes. See
    [Security](security.md#what-blocks-the-merge).
  - A person's push to the PR while it is in `Merging` turns auto-merge off and sends the ticket back
    to `Code Review`: the approval covered the diff before that push.
  - A PR that stays `BLOCKED` by branch protection on a green head past
    `checks.landing_wait_timeout_ms` goes to the landing agent, with a comment on the ticket.
  - `/api/v1/state` (`auto_merge`) and the dashboard show each `Merging` PR, whether auto-merge is on
    and what the watcher decided, for example "Checks are running on PR #12: auto-merge lands it
    when they pass".
  - Landing order: when open PRs change the same files, each merge would reopen a conflict on the
    others. So Symphony reads the files of every open PR on each poll and lands PRs that share a
    file one after another: PRs that conflict with the base branch after the ones that don't, then
    the ticket furthest along first (`Merging`, QA, Code Review, `Rework`; a ticket in `CI Fix`
    keeps the place of the state it returns to), then the one longest in its state. The others keep working, but get no conflict fix and no
    "Update branch" until the PR ahead of them lands; then each merges the base branch once, with
    its changes. A PR on a hold, or one whose state and head haven't moved for two hours, holds no
    one up, and a forced ticket never waits. A PR that conflicts while one ahead shares its files,
    or whose conflict came back after its 3 fix runs while other open PRs share them, waits on them
    as a Linear blocked-by link and a `Blocked` hold ("Waiting on MT-1 to land: they change the
    same files (SPEC.md)"), which clears by itself once they land or leave the race; Symphony
    removes only the links it added. `/api/v1/state` lists the waits under `landing_waits`
    ("Lands after MT-1: they change the same files (lib/a.ex)"), the Mac app's ticket page shows
    them as Lands after, and the agent's first prompt names the open PRs that share files with its
    own, so it can stack on one instead. Nothing to configure.
  - Moving a ticket out of `Merging` to any state but `Done` (by hand in Linear, or with the
    Director's Undo) turns auto-merge off on the next poll, with a ticket comment and an
    `auto_merge_disabled` audit event (`reason: "left_merging"`), so the PR doesn't merge without
    the approval. Moving it back to `Merging` turns auto-merge on again.
  - Repository requirements: **Allow auto-merge** on (`allow_auto_merge`), and branch protection on
    the base branch with required status checks. Requiring branches to be up to date before merging
    (`strict`) is recommended, so GitHub never merges stale code; Symphony keeps the branch updated.
    **Allow squash merging** must be on. Every required check must report on every PR (a
    path-filtered required check that never runs keeps the PR `BLOCKED` until the fallback).

### `code_review`

Code Review's reviewer: the read-only agent the `Code Review` state runs on the pull request's
diff (see [`design/state-machine.md`](design/state-machine.md)).

```yaml
code_review:
  enabled: true
  runtime: codex
  command: codex app-server
  model: claude-opus-5-5
  effort: high
```

`model` and `effort` (optional) set the reviewer's `--model` / `--effort` with the Claude runtime.
Each one falls back to the `code_review` run profile (the routed repository's
`repositories[].agent.run_profiles.code_review`, then `repositories[].agent`, then
`agent.run_profiles.code_review`, then `agent.model` / `agent.effort`); with none set the reviewer
command is unchanged. They take the same values as `agent.model` / `agent.effort`, and `command`
must not pass `--model` / `--effort` while any of them resolves. With `enabled: false` no reviewer
exists, so Symphony parks the repo's `Code Review` tickets with the reason recorded
(`code_review_reviewer_disabled`) and dispatches no run.

The reviewer reads the pull request's committed diff for code quality and bugs: correctness, tests
for new branches, error handling, and the repo's code rules from its `AGENTS.md` / `CLAUDE.md`. It
also judges the change against the ticket: each acceptance criterion, its scope and its intent, and
it follows the decisions a person recorded on the ticket. Its prompt tells it not to run the test
suite, coverage or Dialyzer, which CI runs. Checks are split by cost: agents run cheap, targeted
checks locally (format, compile, lint, the tests for the changed code; Symphony's own list is in
its `WORKFLOW.md`), and the full suite, coverage and Dialyzer run only in CI. An implementation run
writes its code, runs its checks and pushes; no reviewer runs before the push.

The reviewer records its verdict with the `review_verdict` tool, whose input schema is the verdict
contract (`approve`, `request_changes` or `block`, and findings with file, line range, quoted
snippet, summary and suggested fix). A reviewer that ends its turn without calling it is read from
the JSON in its final message instead. Both are read leniently (`Approved`, `changes_requested`, a
line range `"12-15"`, a reversed pair), and a verdict Symphony still cannot read gets one repair
turn in the same session, with the error, before the review counts as inconclusive. A finding
whose quote cannot be found in the diff or the file is kept as a comment marked "could not be
placed" and the verdict stands; only a change request none of whose findings can be placed is
unverifiable. `/api/v1/state` counts inconclusive Code Review runs per cause
(`counts.review_inconclusive`), and the Mac app's ticket page shows the cause on the run's row.

The pre-push reviewer that used to review an implementation run's commits before its first push
is removed. A `symphony.yml` that still has `pre_push_review:` is refused at load: "`pre_push_review`
is not valid; the pre-push reviewer is removed and Code Review owns the review of the code now; set
Code Review's reviewer in `code_review` (enabled, runtime, command, model, effort) and its run
profile in `agent.run_profiles.code_review`". The same reason refuses
`agent.run_profiles.pre_push_review` and `repositories[].agent.run_profiles.pre_push_review`.

### `auto_review`

The QA agent's settings: the agent the `QA` state runs on a green PR head (see
[`design/state-machine.md`](design/state-machine.md)), and its epic review runs on the base branch.
The block keeps its name from the retired `Auto Review` state, which bundled the CI wait, a QA pass
and the acceptance gate; that state and the gate are gone.

```yaml
auto_review:
  runtime: claude
  command: claude --dangerously-skip-permissions
  model: claude-sonnet-5-5
  effort: medium
  max_turns: 20
  timeout_ms: 1800000
  skip_globs: []
  playbooks: {}
  # worker_host: qa@qa-vm.local   # required for macos_app: the QA VM it runs in
  # android:                      # optional: the emulator for Android QA
  #   avd: Pixel_3a_API_34
```

`model` and `effort` (optional) set the QA agent's `--model` / `--effort` with the Claude runtime,
falling back to the `qa` run profile (the routed repository's `repositories[].agent`, then
`agent.run_profiles.qa`, then `agent.model` / `agent.effort`). Validation is the same
as for `code_review`; when `command` is not set the QA agent uses `agent.command`, which must
then not pass the flag that `auto_review.model` / `auto_review.effort` sets.

The old Auto Review keys still load, each with one deprecation warning per config naming what
replaced it, and do nothing: `enabled`, `state` (the `QA` state's name is `issues.states.qa`),
`max_concurrent` (QA runs take agent slots), `max_fix_attempts` (a QA fail returns the ticket to
`Rework` on the same PR) and `run_on`. They leave the schema once the deprecation window ends. No
ticket can enter the `Auto Review` state any more; one still sitting there is named in an error at
startup, for a person to move it on by hand.

#### QA passes

Before any agent runs, Symphony decides whether the PR needs QA and which playbooks apply:

| Signal | Result |
| --- | --- |
| `qa:skip` label | skipped |
| `qa:<kind>` label (for example `qa:cli`) | that playbook runs |
| only docs, tests or `skip_globs` paths changed | skipped |
| `## User walkthrough` in the ticket | `cli` playbook runs |
| web paths changed, `verification.enabled` on and `verification.dev_server` configured | `web` playbook runs |
| Android paths changed, `android_app` configured and `auto_review.android.avd` set | `android_app` playbook runs |
| a playbook's trigger paths changed | that playbook runs |
| nothing else | skipped (internal changes rely on tests and Code Review) |

The built-in `cli` playbook triggers on `bin/**`, `lib/symphony_elixir/cli.ex` and
`lib/mix/tasks/**`. Every built-in playbook also triggers on its own instructions,
`priv/qa_playbooks/<kind>.md`, and the `macos_app` and `android_app` playbooks on the host driver
behind their tools (`lib/symphony_elixir/qa_driver.ex`, `lib/symphony_elixir/qa_driver/**` and
`priv/qa_driver/**`; `lib/symphony_elixir/qa_android/**`), so a change to how QA drives the app
gets a pass that drives it. The `cli` playbook builds the CLI, runs the walkthrough commands with
throwaway config and state under `$TMPDIR`, and attaches a command transcript. A CLI pass
typically costs 1–4 minutes and 50–150k tokens.

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
or `agent.limits.tokens_per_issue`.

The QA agent records its verdict with the `qa_verdict` tool, offered to QA passes (and epic
reviews) only, as its last act. Its input schema is the verdict contract: `pass`, `fail` or
`blocked`, the steps, `findings` (each with the step, the viewport, what was expected, what
happened and the evidence, rendered to one line of the report's `### Findings`), a `reason` for a
block, and `needs_person`, `needs_dev_server`, `covered_by` and `scope` as before. The call is the
verdict, recorded the moment it arrives: a pass whose agent then ends its turn without a word
still has it, and the QA report and the rework run read its findings. A verdict the tool cannot
read comes back with the error, so the agent fixes it and calls again. It is read leniently
(`PASS`, `failed`, a single finding object instead of a list). An agent that ends its turn without
the call is read from the JSON in its final message instead, for one release. A turn with neither
gets one follow-up turn in the same session asking for the `qa_verdict` call, and the QA report
notes "verdict after 1 follow-up". When that follow-up comes back empty (the agent process
exited, or its turn was finalised with no answer), the pass runs again once in the same run, as
the same attempt: the log says `qa_verdict_missing: ... retrying the pass as the same attempt`, no
blocked attempt is spent, and the report notes "pass run again once after a missing verdict". A
pass that misses its verdict again is `blocked` as before.

**The design QA judges a UI against.** A plan keeps its Screens document and `screens.html` on
the parent, so a QA pass (and an epic review) reads more than the ticket's own documents:
`linear_get_document` lists and reads, read-only, the documents the parent's runs created as well
(listed under `parentDocuments`); any other issue's documents stay refused, and writing stays
limited to the ticket's own. Every other run reads only its own issue's documents. Before the agent
starts, Symphony downloads the HTML files and images attached to the ticket and to its parent (only
files on `uploads.linear.app`, the newest attachment of each title, up to 20 per issue and 20 MB
per file) into `design/` in the pass's temp folder, and the prompt names each file's path, or says
none is attached. A file it cannot download is logged and left out. The prompt names where the
design comes from, in order: the ticket's and the parent's Screens documents and HTML screens, then
`docs/design/design-system.md` and `docs/design/director-app-screens.md` in the worktree.

QA never runs the test suite, `make all`, coverage or Dialyzer: a pass starts only once CI is green
on the PR head, so the prompt and every built-in playbook tell the agent to rely on CI and to build
only what it needs to use the change. The epic review judges a criterion that asks for tests,
coverage or CI to pass by CI's runs on the base branch head it tests, read with `gh run list` where
the sandbox allows `gh`, else through GitHub's public API: green runs make the step `pass` with the
run URLs, a failed run makes it `fail` naming the failing job and the run (so it is filed as a gap),
and it is `skipped` only when no run can be read or a run is still in progress. Symphony waits for
CI before it starts the epic review's agent: while a run on that commit is unfinished, the review
starts again a minute later, without a verdict or a retry attempt, so a review that starts the
moment the last sub-ticket merges does not judge a commit CI is still testing. A run still
unfinished after two hours is not waited on, and these restarts don't count as a dispatch loop. The
wait on one commit is bounded: once it has lasted an hour, Symphony starts the review no more and
puts the epic on a `Blocked` hold whose reason names the commit and the workflows still running; the
Inbox lists it, and `Unblock` starts the wait again from zero. The public API is
`api.github.com`, which is not in the built-in network allowlist; add it to
`agent.permissions.network.allowed_domains` for the fallback to work.

A commit whose runs finished with a failed one is not judged at once: Symphony reruns the failed
jobs of each failed run once per commit (`gh run rerun <id> --failed`, as the PR watcher reruns a
red PR head before CI Fix) and waits for the rerun the same way, the hour starting again. A run
green on its rerun is a flake: Symphony records a `ci_flake` signal on the epic with the commit, the
runs and the failed job and test names it read before the rerun, files nothing, and the review
judges a green commit. A run red again is judged as before, and its follow-up quotes the second
failure's log. The review's report names what the rerun found in its `ci_rerun` pre-check. A commit
is never rerun twice: the rerun is recorded on the epic before it is made, and a review that cannot
record it does not rerun.

**One follow-up per defect.** The epic review's agent names, for each failing step, the defect it
rests on (`"defect"` in its answer: a few words saying what is broken). Steps that fail for the same
cause carry the same defect, matched without regard to case or surrounding spaces, and a plan-level
step that fails only because a design-check step failed names that step's defect. Symphony files one
follow-up per defect: titled `Epic review fails: <defect>`, its description lists every step that
rests on it, each with its details and evidence, and its acceptance criteria list every one of those
steps, so the next review marks them. A failing step that names no defect is a follow-up of its own,
titled after the step. A defect's follow-up answers to every `gap` label of its steps and waits on
what any of them waits on, except on one another.

**Which steps QA walks.** Each step of a `## User walkthrough` is proved in one place
([ADR 0003](adr/0003-automated-tests-first-qa-last-resort.md)), and three parties share the work:

- the person writing the ticket describes the user's flow in plain steps, each with `Expected:`,
  and names no test and no check;
- the implementer, who writes the tests, ends each step a test of the PR covers with
  `Proved by: <test>`, through the `linear_record_walkthrough_proofs` tool, which edits only those
  steps' proof lines in the description and refuses a check name;
- the repo names the check that runs its tests, `proof_check` in its WORKFLOW.md front matter (this
  repository: `make-all`), and Symphony confirms every named test on the PR head before QA.

A proof is the line at the end of a step:

| Line | Proof | QA |
| --- | --- | --- |
| `Proved by: <test>` | the named automated test, run by the repo's `proof_check`, as the code or `mix test` names it: a test file (`test/foo_test.exs`), a test or scenario name (`does X`), a describe plus a test name (`foo/1 does X`), or a file and a name (`test/foo_test.exs: does X`, `test/foo_test.exs does X`); backticks, surrounding quotes and a `:line` are dropped, and the `proof_check`'s own name alone names the check without a test | does not walk the step: Symphony's QA pre-check confirms it on the PR head before the agent starts (below), and the agent links the result |
| `Proved by: <check> › <test>` | the older form, still read: the GitHub check run (or workflow) the step names, then the test; a plain ` > ` works as the separator | as above |
| `Proved by: QA` | the QA pass: a judgment by sight the author keeps for QA | walks the step |
| no `Proved by:` line | read as `Proved by: QA` | walks the step |

A `Proved by:` inside inline code (between backticks) is a quotation, not a proof: a step that
describes proof lines quotes them, keeps its text whole, and is proved by its own last unquoted
`Proved by:`, or is a QA step when it has none.

A repo without `proof_check` has no named-test proofs: QA walks every step of its walkthroughs,
whatever their `Proved by:` lines say. `SymphonyElixir.Walkthrough` parses the walkthrough into steps
with their proof, and the QA prompt lists the steps to link and the steps to walk when the
walkthrough names at least one test.

**The QA pre-check.** Before the QA agent starts, Symphony confirms each step a named test proves
itself (`SymphonyElixir.QaPreCheck`), so whether a named test ran is never left to the agent reading
check runs: a green head does not prove it, since a path-filtered workflow such as `macos-e2e` may
not run on a PR at all. For each step it:

- looks for the test in the PR's checkout: a part with a `/` (or a file name such as
  `check_test.exs`, with or without a `:line`) must be a tracked file or folder, and any other part,
  such as a test or scenario name, must appear in the tracked files, within the file named before it
  when there is one (`test/foo_test.exs › "does X"`, `test/foo_test.exs: does X` or
  `test/foo_test.exs does X`). A part that opens with a file the rest is not in is also read as one
  name, so a test named `WORKFLOW.md front matter cannot set the agent` is found. A name is found
  as text (a test name or a describe alone) or as ExUnit's full test name, the describe and the
  test joined by a space, as `mix test` prints it (with its leading `test ` and trailing `(Module)`
  too), though the two sit on different lines. A name found nowhere fails naming the file it
  narrowed to (or the checkout) and the forms tried;
- reads the PR head's status checks with `gh` and finds the ones the step's check names (the
  `proof_check` for `Proved by: <test>`): a check run, a whole workflow, or `workflow / job`.

First the QA run brings its workspace to the PR's current head (GitHub's `refs/pull/<number>/head`),
so a branch that upkeep updated after the approve is judged at its new head: the workspace is reset
only when it holds no local change and no unpushed commit, a workspace with either is `blocked`
naming it, and a PR head that moves during the run is synced once more before it blocks the pass.

| What the pre-check finds | Step | The pass |
| --- | --- | --- |
| the check passed and the test is in the checkout | `pass`, linked to the check run | the agent starts; the prompt lists the step as confirmed, with its link, and tells the agent not to walk it |
| the check failed, did not run on the head, reported only `skipped`, or the named test is not in the checkout | `fail`, naming the step and what is missing | `fail` to `Rework` with no agent run: the ticket's proof is part of its work |
| the step names a check that is neither the `proof_check` nor a check on the head (a check name copied from another repo, such as `ci`) | `fail`, saying so and naming the repo's `proof_check` | as above |
| the check is still running | waiting | waits like the epic review waits for CI (above): the pass starts again a minute later, with no verdict; after an hour on the same head it is `blocked` with the reason, retried like any blocked pass, then a person decides (no QA tool raised it, so it never reaches the self-heal lane) |
| CI on the PR head cannot be read, or the PR head is not the commit QA judges | — | `blocked` with the reason |

The QA report lists every result under `### Pre-checks`, one line per step with the check run's
link, and a failed step is also one of the report's findings. A walkthrough with no named-test step
reads nothing, and QA walks it whole. The epic review does not run the pre-check: its agent reads
CI's runs on the base branch head, as above.

The instructions that write walkthroughs (the plan pipeline, the plan run, new issues filed during a
run, and the ticket templates) ask for plain steps that name no test and no check. A step that needs
an environment QA lacks (a signed build, a device, real credentials) is an acceptance criterion
asking for an automated harness; a judgment by sight, or a step that needs a QA tool, ends with
`Proved by: QA`. A plan never puts one journey both in a sub-ticket's walkthrough and in an
end-to-end ticket: the end-to-end ticket owns it. The implementation instructions (the feature
ticket type, the start, execution and rework steps) have the implementer plan a test for every step
code can drive and record each with `linear_record_walkthrough_proofs` before the handoff push,
naming only tests in its PR.

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
`macos_app` QA driver starts one for each pass and launches every app with its URL; the app's SSH
session forwards a loopback port on the QA VM back to it (`ssh -R`,
so the QA host's `sshd` must allow TCP forwarding, as it does by default). The `cli` playbook starts
one with `symphony openrouter-stub [--port <port>]`, which prints its URL and the variables to export.

Symphony and the app use the stub only in QA mode: `SYMPHONY_QA_OPENROUTER_URL` (the stub's API
base, such as `http://127.0.0.1:4100/api`) counts only while `SYMPHONY_BAR_QA_ROOT` is set too, and
only for an `http` or `https` URL on a loopback host (`127.0.0.1`, `localhost`, `::1`). Otherwise a
run, `symphony check` and the app always talk to `https://openrouter.ai`, whatever the environment
says, so a stray variable cannot send a key to another host. Checks against the real API with a
real key (a real model list, a real run) are manual: a person runs them by hand, with a cheap
model, outside QA.

An agent cannot change the agent-protected paths (`WORKFLOW.md`, `symphony.yml`, `.agents/skills`, the
project `.claude` settings, hooks and skills, `mise.toml`, `.tool-versions`,
`config/settings_ui_exempt.yml`): its sandbox denies the
writes and the `protected-paths` CI job fails a PR whose own commits touch them. The executor hands
a criterion that only such a change can meet to a person, in a sub-issue or a follow-up ticket
named in its workpad. The PR QA prompt lists these paths, and the agent marks such a handed-off
criterion `skipped` with the follow-up ticket's identifier instead of failing the PR on it. Without
a hand-off it is still `fail`, and a criterion a change elsewhere could meet (under `docs/`, in
`README.md`) is never skipped this way. The epic review still fails a missing change to these
paths, since it tests the merged result.

Every pass rewrites one `## Symphony QA Report` comment on the issue (Symphony's only comment
besides the agent workpad) and records a run with `kind: "qa"`, its tokens and wall time in the
run store, which the dashboard's run history shows. The `QA` state applies the verdict; see
[`design/state-machine.md`](design/state-machine.md):

| Verdict | What it means | What happens |
| --- | --- | --- |
| `pass` | every step behaved as the ticket describes, the wide pass included | `Merging` |
| `pass` with `scope: none` | the change has nothing on screen to judge: neither the diff nor the ticket names a walkthrough step or a screen, by the agent's answer or by the QA policy (below) | `Merging` with the reason in the report, but only when the pass ran `qa_build`, `qa_launch_app` and a `qa_check_app` that found the app healthy, so the merge still waits on the app starting; without them it is `inconclusive` |
| `fail` | a step shows a defect in the change | `Rework` |
| `inconclusive` | the QA run itself fell short: a `macos_app` pass that judged screens but never ran the wide pass, or a `scope: none` pass that never started the app | QA runs once more on the same head, then the ticket pauses in `QA` on a Needs Decision hold. Nothing in the environment is broken, so no fix ticket is filed |
| `blocked` | the pass could not test the change | retried once on the same head, then: the self-heal lane when the QA tools raised the block themselves (`qa_worker_*`, `qa_host_missing_tool`, `qa_host_tool_check_failed`, `qa_host_tunnel_failed`, `qa_dev_server_failed`), when only a person can clear it (`needs_person`, an access hold), or when the agent named the open ticket that covers it (`covered_by`) or the project's missing dev server (`needs_dev_server`, unless the repository rules a dev server out: below); a block whose only open steps are `unprovable` (below) asks a person at once; any other block (the agent's own account, a crash, the token limit, a check that never finished) pauses the ticket in `QA` on a Needs Decision hold instead of filing a fix ticket for a problem nothing names |

**Steps QA cannot prove here.** A step can need what no playbook of the pass gives: the running app
on a pass the diff did not select the app's playbook for (a server-only fix whose walkthrough
watches the Mac app), or the project's own server on a repository that rules a dev server out
(below). Such a step can neither pass nor be repaired, so the agent marks it `unprovable` with the
reason, and the report lists it as **unprovable here**. The prompt names the enabled playbooks the
diff did not select, so the agent knows which steps fall there; a `qa:<kind>` label on the ticket
selects the playbook instead. Only a pass whose prompt offered the status (an enabled playbook the
diff did not select, or a server the repository rules out for this pass) reads it: on any other
pass an `unprovable` step is the agent's own block, reported `blocked` and retried as one. The pass
is then decided by the other steps, the pre-checks and CI:

| The other steps | The pass |
| --- | --- |
| one is `blocked`, or the block names its own cause (`needs_person`, `covered_by`, `needs_dev_server`, a QA tool's own failure, a wide pass a small QA screen limited) | `blocked`, as before |
| one fails | `fail` → `Rework` |
| one passes, or a pre-check passed | `pass` → `Merging`, the report naming each unprovable step and its reason |
| none is left | `blocked` with no retry and no fix ticket: the ticket pauses in `QA` on the "QA could not finish" Needs Decision hold at once, with its three options and **Merge without a QA result** recommended |

The QA policy gives a pass `scope: none` up front when a `macos_app` pass is selected (by a
`qa:macos_app` label) although no changed path matches any selected playbook's `paths`, and the
ticket has no `## User walkthrough`: the agent is told that building and launching the app are the
whole check.

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

Set `dev_server: true` on a kind of your own when its pass needs the project's server running,
such as an API and the Postgres it stores in that the app under test talks to. Symphony then
starts `verification.dev_server` for that pass as it does for `web` (from its own worktree at the
PR head, on a pooled port, outside the agent's sandbox), gives the agent its URL and lets the
agent's sandbox reach `localhost`; only a `web` pass also gets the `browser` MCP server. The
`macos_app` playbook takes `dev_server: true` too: its server runs on the QA VM, beside the app,
never on the Symphony host (see [macOS app QA](#macos-app-qa)). Each path reads its own flags:

| Playbook with a dev server | Needs |
| --- | --- |
| `macos_app` with `dev_server: true` | `verification.dev_server.start_cmd` only; `verification.enabled` may be `false` |
| `web`, a kind of your own with `dev_server: true` | `verification.enabled: true` and `verification.dev_server.start_cmd` |

`verification.enabled` also starts the dev server on the Symphony host for every agent run (see
[`verification`](#verification)), so a repository whose server only runs on the QA host, beside a
Mac app, leaves it `false`. Without the flags it needs the kind is off, and the `QA selection` log
line says which one is missing: `` needs `verification.dev_server` `` without a start command,
`` needs `verification.enabled` `` with one but verification off:

```yaml
auto_review:
  playbooks:
    server:
      paths: ["server/**"]
      dev_server: true
      prompt: |
        ### Playbook: server
        Call the changed endpoints on the dev server and check the responses.
```

The QA agent's own sandbox cannot run a database such as Postgres: it lets a process create a
System V shared memory segment but not look it up again or remove it, so `initdb` fails with
`could not create shared memory segment: Operation not permitted`. The dev server's sandbox leaves
System V IPC alone. Start the database from the dev server's `start_cmd`, listening only on a unix
socket in the dev server's temp folder (`listen_addresses=''`, `unix_socket_directories` set to the
folder of `$SYMPHONY_VERIFICATION_SOCKET`), since on macOS that sandbox allows no TCP listener.

The QA agent never stands in for the system under test: a stand-in it serves replaces only an
outside service (a paid AI service, real credentials, a third-party API). When the project's own
server cannot build or start, the steps that need it are `blocked`, never judged against a stub
the agent wrote. When they are blocked because the pass had no dev server at all, the agent says
so (`needs_dev_server`), and the self-heal fix ticket lands in the project's own repository, asking
it to set `verification.dev_server` and `dev_server: true` on the playbook.

A repository that sets `verification.dev_server` but keeps `verification.enabled: false` has ruled
that repair out: its server exists and must not start on the Symphony host, where every agent run
would start it inside its sandbox (a hub whose server only runs beside its Mac app on the QA VM,
through `macos_app` with `dev_server: true`, say). On such a repository, a pass none of whose
playbooks runs the server (a server-only diff that selects only `cli`) files no fix ticket for a
`needs_dev_server` block and sets no hold: the steps it blocked become `unprovable` with the
repository's reason ("this repo runs its own server only beside the app on the QA host…"), and the
pass is decided by the rest, as above. A pass whose playbook runs the server itself (that
`macos_app` pass, or `web`) has it: its prompt never calls the server unprovable, and its
`needs_dev_server` block gets the fix ticket as before. A repository without
`verification.dev_server`, or with verification on, still gets the fix ticket.

A repository's `WORKFLOW.md` can set `auto_review.playbooks` too, for settings that differ per
repository, such as a build command or trigger paths. It is the only `auto_review` key allowed
there; any other one fails the repository's workflow with an error pointing at `symphony.yml`.
For that repository's QA passes (and epic reviews), each kind is merged over
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
dispatch applies to the next pass. Each QA decision, at Code Review's approve and again when the
QA state runs, logs its selection at info level in one line:

```text
QA selection issue_id=… issue_identifier=MOT-32 sha=… decision=run playbooks=android_app not_selected="cli: not triggered; macos_app: needs `auto_review.playbooks.macos_app.build`, `auto_review.playbooks.macos_app.app`; web: needs `verification.enabled`"
```

`not_selected` names each playbook that did not run: `not triggered` when none of its paths
changed, otherwise the setting it is missing or `enabled: false`.

#### The retired acceptance gate's escalation rules

The acceptance gate is retired, and `auto_review.acceptance_gate` is deprecated: every key in it
loads with a warning. Its agent settings (`runtime`, `command`, `model`, `effort`, `max_turns`,
`timeout_ms`, `max_concurrent`), `escalate.inconclusive_limit` and
`agent.run_profiles.acceptance_gate` do nothing. `mode` only sets a repo's `manual_review` when the
repo sets none. Its `escalate` rules (and a `repositories[].acceptance_gate.escalate` override) are
still read, by Code Review, until the block is removed. Each rule's new home:

| Rule | Home |
| --- | --- |
| `labels` (an escalation label other than `plan` / `breakdown`) | Needs Decision hold on an approved Code Review |
| `ticket_patterns` | Needs Decision hold on an approved Code Review |
| `paths` | informs the Code Review reviewer; asks a person on approval with `on_match.paths: ask` |
| `diff_patterns` | informs the Code Review reviewer, or asks (`on_match.diff_patterns`) |
| `dependencies` | informs the Code Review reviewer, or asks (`on_match.dependencies`) |
| `max_changed_lines` | informs the Code Review reviewer, or asks (`on_match.max_changed_lines`); `size_counts: added` leaves removed lines out |
| `busy_files` | informs the Code Review reviewer, or asks (`on_match.busy_files`) |
| `inconclusive_limit` | dropped: Code Review retries an inconclusive review twice, then asks a person |
| the gate's `settings_ui` rule | dropped: CI's `mix settings.ui_coverage` fails such a PR |

The built-in lists stay in force, and a configured list adds to them; only
`escalate.ticket_patterns_builtin: false` drops the built-in `ticket_patterns`. `escalate.on_match`
and `escalate.size_counts` are set in the global block only; Settings → Code Review in the macOS app
sets both. See
[`docs/acceptance_gate.md`](acceptance_gate.md) for the rules' syntax.

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

1. takes a port from the verification port pool and, in a second worktree at the PR head (so its
   build output stays out of the agent's worktree), runs `dev_server.build_cmd` when it is set,
   then starts `dev_server.start_cmd` with `SYMPHONY_VERIFICATION_PORT` set (and on macOS
   `SYMPHONY_VERIFICATION_SOCKET`, see [`verification`](#verification)) and waits for
   `health_check_url`. A build that fails or times out, or a server that does not start or fails
   its health check within `health_timeout_ms`, makes the pass `blocked` ("the dev server did not
   start", "the dev server failed its health check"), not `fail`, and no agent runs;
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
which serves the status dashboard from the PR head's escript with an in-memory tracker, so
dashboard changes get a `web` pass once the operator sets `verification.enabled: true`. That
script needs the escript built first: set `build_cmd: scripts/qa-dashboard-build.sh` next to it,
or the dev server stops because `bin/symphony` is missing.

#### macOS app QA

The built-in `macos_app` playbook tests a macOS app by building it, launching it and using it
through accessibility, the way a user would. It runs only in a QA VM, never on the Symphony Mac:
set one up first ([Running QA in a QA VM](#running-qa-in-a-qa-vm)). It is off until you name the
build command and the app bundle it produces:

```yaml
auto_review:
  playbooks:
    macos_app:
      build: make -C macos qa-app         # run in the QA worktree
      app: macos/build/Symphony.app       # relative to the repo root
      build_timeout_ms: 900000            # optional, default 15 minutes
      # requires: [go, pg_ctl]          # optional: tools the QA host must have (see below)
      # paths: ["macos/Sources/**"]       # optional, default: Swift, Info.plist, xib, storyboard, xcassets
      # dev_server: true                  # optional, default false: run verification.dev_server for the pass
      # dev_server_port: 8090             # optional, default 8090: its port on the QA host
      # launch_env:                       # optional, default {}: extra variables for the app under test
      #   HUB_OWNER_TOKEN: qa-owner-token
```

| Key | Default | Does |
| --- | --- | --- |
| `build` | none (required) | the command `qa_build` runs in `src/` on the QA VM, the copy of the QA worktree it ships there |
| `app` | none (required) | the `.app` bundle the build writes, relative to the repo root |
| `build_timeout_ms` | `900000` | how long `qa_build` waits for `build` |
| `paths` | Swift, `Info.plist`, xib, storyboard, xcassets | the changed paths that select the playbook |
| `dev_server` | `false` | the pass starts `verification.dev_server` on the QA VM, beside the app (see [Running QA in a QA VM](#running-qa-in-a-qa-vm)), never on the Symphony host: without a `worker_host` no server starts and the `qa_*` tools say to set up the QA VM |
| `dev_server_port` | `8090` | the port the QA-host dev server listens on, as `SYMPHONY_VERIFICATION_PORT` |
| `launch_env` | `{}` | extra variables `qa_launch_app` sets on the app, after Symphony's own, with `$SYMPHONY_VERIFICATION_PORT` replaced by `dev_server_port`. Names match `^[A-Z][A-Z0-9_]*$`; the variables Symphony sets itself (`SYMPHONY_BAR_QA_ROOT`, `SYMPHONY_QA_OPENROUTER_URL`, `SYMPHONY_BAR_QA_API_FIXTURES` and the stand-ins below), `PATH`, `HOME` and `DYLD_*` fail the config check, naming the key |

`launch_env` values are written in plain text, in `symphony.yml` or a repository's `WORKFLOW.md`,
which is often public: put only documented QA values there (a QA owner token such as the Job
Search Hub's `HUB_OWNER_TOKEN`), never a secret. The Director's **Settings → macOS app QA** edits
`dev_server`, `dev_server_port` and `launch_env` in `symphony.yml`.

For Symphony's own app, build with `make -C macos qa-app`, not `make -C macos app`. The app runs
`symphony check` on every Settings Save, and a plain `make` build has no Symphony to run it with,
so each Save would stop at the check. `qa-app` builds the PR head's Symphony from the same copy
(`mix deps.get`, then `mix escript.build`) and embeds it at
`Symphony.app/Contents/Resources/symphony`, where releases embed theirs, so the QA app checks with
the PR's code and never with an installed release. The embedded escript's first line points at
the build host's Erlang (`<code:root_dir()>/bin/escript`), so the app runs it without `mise` or
`PATH`. The build host needs `mix` and `erl` on the build's `PATH` (Erlang and Elixir as in
`mise.toml`; set `MIX=` and `ERL=` on the make line to use others) and network access for
`mix deps.get`. With `mise` shims on the QA VM, add `~/.symphony-qa` to the QA user's
`MISE_TRUSTED_CONFIG_PATHS`, since each pass copies the repository into a new directory there.
The QA app has no update key, so it never updates itself.

`symphony check` prints the build it runs first, on stderr: `Symphony <version> (<commit>)`. In QA
mode the app writes each check's exit status and output to its own stderr, which `qa_quit_app`
returns, so a QA report can quote the commit the check ran and compare it with the PR head. A
build in a checkout takes the commit from `git rev-parse HEAD`; the QA VM's copy has no `.git`, so
`git archive` writes it into `macos/source-commit` (an `export-subst` file).

The QA agent's sandbox cannot build Swift, open apps or read the screen, so Symphony runs these
tools for it on the QA VM, outside the sandbox, and checks every argument:

| Tool | Does | Refuses |
| --- | --- | --- |
| `qa_build` | runs `build` in the QA worktree with the agent's scrubbed environment plus `QA_HOST_PORTS` (the pass's [host ports](#qa-passes), comma-separated; unset when their tunnel could not open), then copies the `app` bundle into a private directory | a worktree with changes outside `qa-evidence/` and `.gradle-daemons/` (Symphony's own), gitignored files included: none may exist before the first build, and none may appear or change after a build; a bundle that resolves (symlinks included) outside the worktree, or that holds an absolute symlink or one with `..` |
| `qa_launch_app` | starts the private copy of the bundle with `SYMPHONY_BAR_QA_ROOT` set to a private directory ([QA mode](../macos/README.md#qa-mode)) and `SYMPHONY_QA_OPENROUTER_URL` set to the pass's [OpenRouter stub](#qa-passes), and returns its PID. With `api_fixtures`, a directory relative to the PR checkout (such as `macos/Tests/Fixtures/director-app/running`), it copies that directory's files into a fresh `api-fixtures-<n>/` in the pass's private directory (the run directory on the QA VM) and sets `SYMPHONY_BAR_QA_API_FIXTURES` to the copy, so the app reads Symphony's local API from those JSON files. Optional stand-ins: `gh_stub_port` sets `SYMPHONY_BAR_GH` to Symphony's own fake `gh` (written into the run directory's `bin/`) and `SYMPHONY_QA_GH_URL` to `http://localhost:<port>`; the fake POSTs each call's arguments there as form fields (`argc`, then one `arg` per argument, in order) and prints the answer, a 200 on stdout with exit status 0 and anything else on stderr with exit status 1. `linear_stub_port` sets `SYMPHONY_QA_LINEAR_URL` to `http://localhost:<port>/graphql`, where the Add Repo sheet sends its Linear queries. The QA agent serves both with the shared stubs, `python3 -B test/support/stubs/gh.py` and `python3 -B test/support/stubs/linear.py`, which answer from committed answers files, give an unknown call a clear error and log every request (see [`test/support/README.md`](../test/support/README.md#the-gh-and-linear-stubs)). `open_panel_dir` sets `SYMPHONY_BAR_QA_OPEN_PANEL_DIR`, the folder the Add Repo sheet's folder picker opens in. `update_feed_port` sets `SYMPHONY_BAR_UPDATE_URL` to `http://localhost:<port>/releases/latest`, the release feed the app's update checks read instead of GitHub's; the QA agent serves it there with the shared feed server, `python3 -B test/support/stubs/update_feed.py` (a made-up newer release, a release pair's feed, nothing newer or a 403, every request logged; see [`test/support/README.md`](../test/support/README.md#the-update-feed)). `update_check_interval_seconds` sets `SYMPHONY_BAR_UPDATE_CHECK_INTERVAL`, the seconds between the app's background update checks. `appearance`, `light` or `dark`, makes the app draw in that appearance whatever the QA host's: it sets `SYMPHONY_BAR_QA_APPEARANCE`, which Symphony's own app reads, and injects Symphony's appearance library (`priv/qa_driver/symphony-qa-appearance.m`, built with `clang` on the machine the app runs on, once per source under the state root or once per pass in the QA host's run directory) with `DYLD_INSERT_LIBRARIES`, which reads the same variable and sets any AppKit app's appearance as it finishes launching, printing `symphony-qa-appearance: <light|dark>` to the app's output. AppKit reads the system appearance from the global defaults only, so a launch argument such as `-AppleInterfaceStyle Dark` cannot do it; a light launch also passes `-NSRequiresAquaSystemAppearance YES`. An app built with the hardened runtime ignores the library. Without `appearance` the app follows the host. The host's own appearance is never switched: a pass that died would leave it switched for the next pass, and switching it needs Apple Events, which the QA host blocks. With `release_pair: true` it starts a fresh copy of the [signed release pair](#the-signed-release-pair)'s N instead of the `qa_build` bundle, with the pair's update feed beside it. Every launch of the pass shares one QA root, root 1 (`app-root/` in the run directory on the QA VM), so its settings carry from one launch to the next. `fresh_root: true` (default `false`) starts the app in a new, empty QA root instead, `qa-root-<n>/` beside the first and numbered from 2, with the same `api_fixtures`, stand-ins and `launch_env`, for a first-launch step, a step that resets the app, or a scenario that must not see earlier settings; `root: <n>` starts it in a root the pass already has (`root: 1` is the first). The result names the app's `root`; a release pair's app is relaunched in its root, and `qa_open_status_menu` writes into it | `fresh_root` that is not a boolean, or with `root`; a `root` the pass does not have (`qa_unknown_root`, naming the pass's roots); a fresh root that cannot be made; an executable that changed since the last `qa_build`, or a worktree `qa_build` would refuse; an `api_fixtures` path that is absolute or resolves (symlinks followed) outside the checkout or into its `.git`, or not a directory, a directory holding a symlink, a special file or a file with other hard links, over 5 MB or over 1000 files, and a file replaced while it is read; a stub port that is not one of `QA_HOST_PORTS`; an `open_panel_dir` that `qa_put_checkout` did not return in the pass; an `update_check_interval_seconds` that is not a positive integer; an `appearance` other than `light` or `dark`, or an appearance library that cannot be built (`qa_appearance_unavailable`); `release_pair` before a successful `qa_build_release_pair`, or with `update_feed_port` |
| `qa_quit_app` | quits a launched app and returns its recent output | a PID it did not launch |
| `qa_screenshot` | saves the app's on-screen windows to new files `qa-evidence/<name>.png` | a PID it did not launch, a window of another app, a name that already exists (file or symlink) |
| `qa_ax_tree` | reads the accessibility tree (role, title, value, frame; never a secure field's value), filtered by `role` or `text`, capped in depth, nodes and size | a PID it did not launch |
| `qa_ax_press`, `qa_ax_set_value` | press an element (or `AXRaise` a window) and set a field's value: a text field gets it typed in with key events sent to the app alone (brought to the front, focused, text selected, then Tab), so the app sees the edit; other controls get `AXValue` set | a PID it did not launch, a tab or line break for a single-line field |
| `qa_ax_select` | selects a table or outline row (an `AXRow`, or a cell inside one), which answers no `AXPress`: sets the table's `AXSelectedRows` to that row, or the row's `AXSelected`, checks the row reports itself selected, then brings the app forward and focuses the table so `qa_key` acts on the selection | a PID it did not launch, a `path` that is not a row or inside one |
| `qa_click` | clicks the centre of an element's frame (`clicks: 2` for a double click) after bringing the app and the element's window forward and moving the pointer there, with mouse events sent to the app alone; returns the element under the pointer and whether the tree or windows changed, and when a single click changed nothing and the element answers `AXPress`, presses it that way (`fallback: "AXPress"`). SwiftUI buttons and links check where the pointer is when the mouse goes up, so a click away from it does nothing | a PID it did not launch, an element with no frame, off screen, or under another app's window |
| `qa_hover` | moves the pointer over an element's centre (`path`) or a point on screen (`x`, `y`) after the same checks, and waits up to 2 seconds for the app's accessibility tree to settle, so a hover state can be screenshotted; the pointer stays there | what `qa_click` refuses, a point outside the app's windows, both or neither of `path` and `x`/`y` |
| `qa_context_menu` | right-clicks an element's centre or a point after the same checks and returns the menu that opened (each item's path, title, enabled state and shortcut) and its pop-up `window_id`, for rows and controls whose `AXShowMenu` is unsupported | what `qa_hover` refuses; no menu opening within 2 seconds (`no_menu`) |
| `qa_scroll` | scrolls the `AXScrollArea` at an element (`path`, the area or anything inside it) or a point (`x`, `y`) as a trackpad does, after the same checks: moves the pointer to the middle of the area and posts scroll-wheel events to the app alone, aimed at its window there (when those move nothing, posts them again where the pointer is, over the app's own window: `via: "hid"`). By `dx`/`dy` in `unit` `pixel` (default) or `line`, positive `dy` down, or to an `edge` (`top`, `bottom`, `left`, `right`): rounds of 3000 pt until two in a row move nothing (`at_edge`), so rows a page load adds at the end are reached too, for at most 15 seconds. Returns the rows on screen (`visible`: `count`, `first`, `last`, and a table's `visible_rows`/`rows`), the `scroll_bars` values and, for a delta, how far the content `moved`. A SwiftUI `ScrollView` or `List` answers no scrolling key and its overlay scroll bar takes no `AXValue` | what `qa_hover` refuses, both or neither of `edge` and `dx`/`dy`, a zero delta, more than 20000 pt or 2000 lines; nothing scrolling there (`no_scroll_area`) |
| `qa_key` | presses a named key (`return`, `escape`, arrows, …) or one character key, with `command`, `shift`, `option` or `control`, in the app's focused window, with key events sent to the app alone; returns the focused window and element | a PID it did not launch, a key or modifier outside that list, an app with no focused window |
| `qa_resize_window` | the wide pass: moves the app's main window (or the `AXWindow` at `path`) to the top left of the screen and resizes it to `width`×`height` points (1400×900 by default), or the screen's usable area when that is smaller, with `AXSize` or else the window's zoom button; returns the window frame it reached, the screen and its usable area, and `limited` when that area is under 1400×900 pt | a PID it did not launch, a size under 1400×900 or over 8192 pt, a `path` that is not a window |
| `qa_open_status_menu` | opens a launched app's status-bar menu on screen, as a click on its menu bar item would, and returns the menu's `window_id` and `frame` once it shows, for `qa_screenshot`; `qa_key` with `escape` closes it. It writes an empty `status-menu/open-<pid>` under the app's QA root on the QA VM, which the app takes in [QA mode](../macos/README.md#qa-mode) only, then waits up to 10 seconds for a pop-up menu window (layer 101) in the app's window list. It goes around Accessibility because `AXPress` on the status item blocks until the menu closes (AXError -25204) and a click on it is refused as covered | a PID it did not launch; a menu that does not show within 10 seconds (`qa_status_menu_not_opened`), after which it removes the request so the menu does not open later |
| `qa_check_app` | says whether a launched app still runs (also after it exited), answers an accessibility request within 10 seconds (else it is hung), and has written a new `~/Library/Logs/DiagnosticReports/<executable>*` crash report since launch (read on the QA VM), with each problem naming the `page` the agent passes and the window size `qa_resize_window` set, and names the app's QA `root` | a PID it did not launch |
| `qa_put_file` | puts a fixture file the agent wrote (a test `symphony.yml`, a `WORKFLOW.md`) where the app can open it and returns that path: a copy in the run directory's `files/` on the QA VM | a file that resolves outside the worktree and the pass's `$TMPDIR`, a symlink, a directory or other non-regular file, a file with other hard links, a file over 1 MB, and a file replaced while it is read |
| `qa_put_checkout` | puts a git checkout where the app can open it: clones a `git bundle` the agent made into `checkouts/<remote_name>` in the driver's directory (the run directory on the QA VM) with no hooks, sets its `origin` to `remote_url`, and returns its path. Nothing is fetched from GitHub | the bundle files `qa_put_file` refuses, a `remote_url` that is not `https://github.com/<owner>/<repo>`, a `remote_name` that is not a plain file name, a checkout name already taken in the pass |
| `qa_build_release_pair` | builds the [signed release pair](#the-signed-release-pair) (`make -C macos release-pair`) where the app runs, signed with the QA host's test signing identity, into the pass's private directory, and returns its `manifest.json` | a worktree `qa_build` would refuse; a QA host without the identity (`qa_signing_identity_missing`) or whose identity is not trusted for code signing (`qa_signing_identity_untrusted`), which the QA agent reports as `blocked`, unless a `worker_host` with passwordless `sudo` lets Symphony install it first (`signing_identity_installed: true`) |
| `qa_relaunched_app` | waits up to `wait_seconds` (default 60) for the update helper of a release pair's app to ask for the app to start again, after an install or a rollback, starts that bundle in QA mode with the launch's environment and returns its PID, `version` and `build` | a pass that launched no `release_pair` app; a bundle no `release_pair` launch made; no request in time (`qa_no_relaunch`) |
| `qa_update_feed` | returns the release pair's feed's `mode`, `url` and the app's `requests` to it (oldest first, at most 200), after switching it to `mode` when given: `publish` offers N+1, `none` nothing newer, `forbidden` answers 403 | a pass whose feed is not running; another `mode` |
| `qa_api_requests` | returns the requests the apps launched with `api_fixtures` in one QA root logged to `api-requests.jsonl` there since the last call (each POST's `method`, `path` and `body`), oldest first, at most the last 500 with `dropped` counting the rest, and takes the log away so the next call returns only newer ones; it reads the log on the QA VM. `root: <n>` names the root (a number `qa_launch_app` returned); without it, the root of the last launch. The result names the `root` it read | a `root` the pass does not have (`qa_unknown_root`), a log that cannot be read |

At most three launched apps run at once, and every app still running is quit when the pass ends.
Only QA agents see these tools; executor and reviewer sessions cannot list or call them.

The playbook judges a window only after it settles: it waits about 10 seconds after the window
opens, changes focus once, and then checks the sizes of the content and scroll areas in the
accessibility tree, not just the window frame. A window that opens at full height and collapses
seconds later fails, with the AX tree quoted and a screenshot attached.

QA does three things, in this order, in every app playbook (`macos_app`, `web`, `android_app`):
the walkthrough steps marked `Proved by: QA`, a **Design check** of every UI deliverable, then the
playbook's other checks of the running app (on macOS the wide pass below). The Design check judges
each window, page, screen or menu the change adds or changes by sight: screenshots of the real app
in light and in dark, at the sizes the design names, compared with the ticket's or the parent's
Screens and with `docs/design/design-system.md` (the design system alone when no Screens cover it)
for layout, spacing, alignment, truncation, contrast, symbols, wording and whether it looks
finished. The report has one `Design check: <deliverable>` step per UI deliverable, with both
screenshots and the design it compared with; a visible mismatch fails it, even when every
structural check passes. On macOS the app is launched once per appearance with `qa_launch_app`'s
`appearance`, and a status-bar menu is opened on screen with `qa_open_status_menu` and judged from
its screenshot. Android switches with `qa_android_dark_mode`; the web playbook uses the page's theme
control or the browser's emulated `prefers-color-scheme`, and says when dark is not applicable.

After the walkthrough at the app's default size, the playbook runs a **wide pass**, because some
layout crashes only happen in wide windows: `qa_resize_window` makes the main window at least
1400×900 pt, then on each page the PR changes, and on its inspector or side panel, the agent waits 30
seconds with the app running and calls `qa_check_app`. The pass fails when the app exits, hangs (no
accessibility answer for 10 seconds) or writes a new crash report, and the report names the page and
the window size. The report's `Wide pass` step gives the window size, the screen size and the
pages it covered. A QA screen whose usable area is under 1400×900 pt (a VM with a 1024×768 display)
cannot run it at full size: the step says the wide pass was limited, and Symphony reports a `pass`
from that screen as `blocked` for a person instead of passing it. A `pass` with no `qa_resize_window`
call at all is `inconclusive`, with the reason that the wide pass did not run: QA runs once more,
then a person decides. A `pass` with `scope: none` owes no wide pass, since it has nothing on screen
to judge. An epic review gets every enabled playbook whatever the epic shipped, so it owes the wide
pass only when it launched an app: an epic review of a backend-only epic that launched none keeps
its `pass`, and one that launched an app without the wide pass is `blocked`. Give the QA VM a larger display, for example
`tart set symphony-qa --display 1920x1200`, and restart it. The resize needs no grant beyond the
helper's Accessibility.

The screenshot and accessibility tools run Symphony's Swift helper on the QA VM, under the Screen
Recording and Accessibility grants on its `sshd-keygen-wrapper` (step 4 below), so neither grant
is ever made on the Symphony Mac, to `Symphony.app` or to the terminal you run `symphony` from.
macOS passes an app's grants to every process it starts, and Symphony starts the coding agents,
which run with `--dangerously-skip-permissions`. Without a grant the tools return
`qa_permission_missing`. The QA agent marks the app steps `blocked`, still runs the steps of the
other playbooks offered (`cli`, `web`) and reports each as `pass` or `fail`, then answers
`blocked` with the missing permission as the reason, which the QA report records.

##### Running QA in a QA VM

`qa_build` runs the PR's build and app unsandboxed, as a person building the PR would. To keep
that away from your credentials, `macos_app` QA runs only in a dedicated macOS VM, which
`auto_review.worker_host` names:

```yaml
auto_review:
  worker_host: qa@qa-vm.local     # user@host or host:port, as in workers.ssh_hosts
```

Symphony never builds or runs the PR's app on its own Mac, as you or as another macOS user there:

- with no `worker_host`, a `macos_app` pass builds and launches nothing. Each `qa_*` tool fails
  with `qa_worker_missing`, naming this section, and the QA agent answers `blocked`;
- a `worker_host` that is this Mac under any name (`localhost`, `127.0.0.1`, `::1`, its `.local`
  name, a LAN address, any user) is refused at the start of each pass with
  `qa_worker_same_machine`, before anything runs there. Symphony compares the hardware: the
  `IOPlatformUUID` that `ioreg -rd1 -c IOPlatformExpertDevice` prints on the QA host over SSH, and
  here. A VM has its own. A QA host whose UUID can't be read is refused as unreachable.

Setup reports both: a repo whose playbooks include `macos_app` while no `worker_host` is set, and a
`worker_host` that is this Mac, each with a button that opens this section.

Symphony reaches the QA VM with the same SSH transport as `workers.ssh_hosts` (`SYMPHONY_SSH_CONFIG`
applies), non-interactively, so key authentication must already work. Do not list it in
`workers.ssh_hosts`: that list also receives coding runs. The QA agent still runs on the Symphony
host and the worktree checks still apply there. Then:

- `qa_build` copies the worktree's `HEAD` (`git archive`, so gitignored files and submodules stay
  behind) into a fresh `src/` in a `0700` run directory under `~/.symphony-qa/runs/` on the QA
  host, runs `build` there with the QA user's login environment plus `QA_HOST_PORTS`, and copies
  the bundle into the run directory;
- `qa_launch_app` starts that copy with only `SYMPHONY_BAR_QA_ROOT` and `SYMPHONY_QA_OPENROUTER_URL`
  set, plus `SYMPHONY_BAR_QA_API_FIXTURES` when the agent passes `api_fixtures` (the checked files
  go over SSH as a tar into a fresh `api-fixtures-<n>/` in the run directory) and the stand-ins the
  agent asks for, over an SSH session that forwards the URL's loopback port on the QA host back to the
  OpenRouter stub on the Symphony host;
- at the start of the pass Symphony picks three free loopback ports on the Symphony host and
  hands them to the QA agent as `QA_HOST_PORTS` (in the prompt and its environment) and to `build`
  in its environment, so a QA build can write a stub's URL into the app. It opens one
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
  it replaced could answer the permission, window and accessibility calls of later passes. It
  runs its commands directly over SSH, with the grant on `sshd-keygen-wrapper` (step 4 below);
- screenshots are captured there and copied back into `qa-evidence/` in the local QA worktree, so
  the agent attaches them as before;
- `qa_put_file` copies the fixture over SSH into the run directory's `files/` and returns that
  path, since the app cannot read files on the Symphony host;
- `qa_api_requests` moves the app's `api-requests.jsonl` aside in the run directory and copies it
  back over SSH;
- `qa_launch_app` with `fresh_root: true` makes the new QA root, `qa-root-<n>/`, in the run
  directory there with `mkdir` over SSH, and the app runs in it;
- with `dev_server: true` on the `macos_app` playbook and `verification.dev_server.start_cmd` set,
  whatever `verification.enabled` says (leave it `false` so agent runs start no server on the
  Symphony host), the project's dev server runs on the QA host, beside the app, which cannot reach a server on the
  Symphony host. When the pass starts, before the agent does, Symphony copies the worktree's `HEAD`
  into `dev-server/src/` in the run directory (a copy of its own, since each `qa_build` unpacks
  `src/` afresh), runs `verification.dev_server.build_cmd` and then `start_cmd` there as the QA user,
  unsandboxed like `qa_build`, with `SYMPHONY_VERIFICATION_PORT` set to the playbook's
  `dev_server_port` (default `8090`), `HOME` set to a fresh `dev-server/home/` (so the QA user's
  config files are never read) and `TMPDIR` to `dev-server/tmp/`. `start_cmd` runs in a process
  group of its own and logs to `dev-server/server.log`. The QA host polls `health_check_url` with
  `curl` until it answers 200 or `health_timeout_ms` passes, and after each answer checks that
  `start_cmd` still runs, in the foreground as on the Symphony host: a 200 from another server on
  the port never counts. A build
  that fails, a server that exits (one that could not bind its port, say), or a health check that
  times out makes the pass `blocked` before the agent starts, with the reason
  `qa_dev_server_failed: …` and the log's last 20 lines; self-heal files its fix ticket, component
  `dev_server`, in the project's repository. The QA prompt names the server's URL. When the pass
  ends Symphony sends the group `stop_signal`, waits `stop_timeout_ms` and kills what is left,
  then removes the run directory. The Symphony host starts no dev server of its own for that
  playbook.

  One pass at a time runs a dev server on a QA host's port, since the app under test reads its
  hub URL from its own defaults and the port is fixed. Before it starts its server (so before any
  `qa_build`), a pass takes a lease on the `worker_host` and `dev_server_port`; a second pass
  waits for it, first come first served, and starts once the first pass stopped its own server
  at its end. While it waits, `GET /api/v1/state` lists it under `dispatch_skipped` with
  `waiting for the QA host's dev server port: 8090 on … is held by TP-…'s QA pass`. Passes
  without a QA-host dev server never wait. The lease lives in Symphony, so it covers the passes of
  one Symphony. Before `start_cmd`, a port something already listens on (a server another pass or
  a crashed Symphony left behind) makes the pass `blocked` with
  `qa_dev_server_port_busy: 8090 held by pid <n> (<ticket>)`: the listener's pid, from `lsof` on the
  QA host, and the ticket of the pass whose server it is, read from its run directory.

  The log lines are `QA dev server started issue_id=… issue_identifier=… worker_host=… port=…
  pid=… lease=<worker_host>:<port>` and `QA dev server stopped … outcome=…`; a pass that has to
  wait logs `QA dev server lease busy: <ticket> waits worker_host=… port=… held_by=<ticket>`, and
  the hand-over `QA dev server lease passed from <ticket> to <ticket> …`;
- `qa_launch_app` adds the playbook's `launch_env` after Symphony's own variables;
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

Next, Symphony looks for each executable the playbook lists in `requires` with `command -v`, in
the shell and environment the build gets (a non-login shell over SSH on the QA VM):

```yaml
auto_review:
  playbooks:
    macos_app:
      requires: [go, pg_ctl, initdb]   # default none
```

A missing one makes the pass `blocked` before the agent starts, with the reason
`qa_host_missing_tool: <name>`. The fix belongs to the QA host, not to the project, so self-heal
files it under the `worker_host` component in Symphony's repo, where
[`scripts/qa-vm/provision.sh`](../scripts/qa-vm/provision.sh) installs the toolchain. A repo's
`WORKFLOW.md` may set its own list; the app's Settings edits the one in `symphony.yml`, under
**macOS app QA**.

One QA host keeps state across passes. Removing the run directory removes the pass's source,
bundles and helper, but anything a build or app leaves behind as the QA user stays on the host: a
build that timed out and is still running, a background process, or changes to that user's files,
caches and login environment. Any of these can tamper with a later pass. Symphony does not reset
the host between passes. For full isolation, reset the VM between passes by running QA from a
fresh throwaway clone of a clean image (see step 6 below).

**Setting up the QA VM.** With [tart](https://tart.run):

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
5. Install what `build` needs, then run the build once by hand over SSH to confirm it works. For
   Go, Postgres 18 and jq, run `scripts/qa-vm/provision.sh admin@<vm>` from the Symphony Mac: it
   installs Go from go.dev (`--go-version`, default `1.26`) and Homebrew's `postgresql@18` and
   `jq`, links them into `/usr/local/bin` and puts that first on the non-login SSH `PATH` in
   `~/.zshenv`, and prints each tool's version from a fresh SSH session. It never starts Postgres
   or creates a cluster, refuses a VM that holds push credentials, and installs nothing when run
   again. List the tools in the playbook's `requires` so a pass on a VM without them says so. The [signed release pair](#the-signed-release-pair)'s test
   signing identity needs nothing here: the tart image's `admin` has passwordless `sudo`, so QA
   installs it the first time a pass builds the pair, and again on a clone reset from an image
   without it.
6. Stop the VM and keep it as a clean image. To reset it between passes, delete the working copy
   and clone it again: `tart delete symphony-qa-run; tart clone symphony-qa symphony-qa-run;
   tart run --no-graphics symphony-qa-run`. Point `worker_host` at the clone (`tart ip
   symphony-qa-run` prints its address); it keeps the image's login and TCC grants.

To check a host by hand, run the same tests as the QA user:

```sh
ssh qa@qa-vm.local 'ls ~/.ssh; ls ~/.config/gh; git config --global credential.helper; echo "agent=$SSH_AUTH_SOCK";
  ls /Users/<you>/.ssh /Users/<you>/Library/Keychains 2>&1 | head'
```

Only `authorized_keys` (and `known_hosts`) should show, the next three should be empty, and the
last command should fail with `Permission denied` or `No such file or directory`.

##### The signed release pair

The `qa_build` app (`make -C macos qa-app`) embeds no update key and is signed ad hoc, so it refuses
every update (`UpdateInstaller.checkSigner`), and QA could never see what the app shows once an
update installed, or once a failed one was rolled back. For those steps QA builds the signed
release pair of the [shared test helpers](../test/support/README.md#the-release-pair): release N of
the app and its update N+1, signed with one code-signing identity. That the install works is the
`macos-e2e` check's to prove, in its job
update, restart and rollback (QA does not re-walk the install);
QA only judges by sight what the app shows afterwards.

- `qa_build_release_pair` runs, on the QA VM, the
  checkout's `scripts/qa/install-test-signing-identity.sh --use`, which unlocks the QA host's test
  signing identity and names it, then `make -C macos release-pair` with
  `SYMPHONY_E2E_SIGNING_IDENTITY` and `SYMPHONY_E2E_KEYCHAIN` set to it and `RELEASE_PAIR_OUT` set
  to the pass's run directory. N+1 is signed with a throwaway minisign key the build makes. The
  pair builds in a clone of a `git bundle` of the worktree's `HEAD` and tags
  (`pair-src/` in the run directory), because its release notes and manifest read git history,
  which `git archive` leaves out. It takes several minutes; after 30 it fails with
  `qa_release_pair_timeout`.
- `qa_launch_app` with `release_pair: true` copies N afresh for each launch (`pair-launches/<n>/`)
  and starts the shared update feed (`test/support/stubs/update_feed.py`, copied from the checkout
  at build time) beside it, on a free loopback port of the same machine, serving the pair's `feed/`.
  The app gets `SYMPHONY_BAR_UPDATE_URL` pointing at it, so N finds, verifies and installs N+1 into
  its own copy, and `SYMPHONY_UPDATE_OPEN` pointing at Symphony's relaunch stand-in in the run
  directory's `bin/`.
- After the install (or a rollback) the app's update helper runs that stand-in instead of starting
  the app: it leaves the bundle's path under the app's QA root, and `qa_relaunched_app` starts the
  bundle as Symphony's own child, so the QA tools may drive it and it stops with the pass. An app
  the update helper started itself would run outside Symphony's process tree, which the QA helper
  app does not drive.
- `qa_update_feed` reads the feed's request log and switches its mode.
- Everything stays in the pass's run directory on the QA VM: the
  operator's installed `Symphony.app`, its settings and the real update feed are never touched.
  When the pass ends Symphony stops the feed and any process whose command line names the pass's
  directory, such as an update helper still waiting.

**One-time setup on the QA host.** A persistent test identity, installed and trusted once, rather
than a throwaway one trusted for each pass: a pass that died would leave its trust setting behind.

On a `worker_host` whose QA user has passwordless `sudo` (`sudo -n true` succeeds there, as for
the tart VM's `admin`), QA installs it itself: when `--use` finds no identity, or one that is not
trusted, `qa_build_release_pair` runs the installer below on the QA host, with `sudo -n` for the
trust step, then `--use` again, and builds the pair in the same call. It runs Symphony's own copy
of the script, built into the running Symphony, never the PR checkout's, which the PR under test
may change. Symphony logs the install with the issue's context, and the tool's result says
`signing_identity_installed: true`, so the QA report shows it. The next pass finds the identity
and installs nothing.

On a `worker_host` whose `sudo` asks for a password, run it by
hand as the QA user on the QA host (the clean image, for a VM you reset), from a checkout of this
repository:

```sh
scripts/qa/install-test-signing-identity.sh          # asks for sudo once, to trust the certificate
scripts/qa/install-test-signing-identity.sh --check  # says whether it is installed and trusted; no sudo
```

It creates a self-signed code-signing identity named `Symphony QA Test Signing`, never Symphony's
release certificate, in a keychain of its own,
`~/Library/Keychains/symphony-qa-signing.keychain-db`, whose password it keeps beside it in
`symphony-qa-signing.password`. It puts that keychain on the user's keychain search list (codesign
only finds an identity there) and trusts the certificate for code signing only
(`sudo security add-trusted-cert -d -r trustRoot -p codeSign`). Running it again changes nothing
once the identity is installed and trusted, and finishes an install that stopped half way. The
pair's build also needs `minisign` and `jq` (`brew install minisign jq`) and the repository's
toolchain for `make release`. Without the identity, where QA cannot install it,
`qa_build_release_pair` fails with `qa_signing_identity_missing` or
`qa_signing_identity_untrusted`, and the QA agent answers `blocked` with that message.

QA needs `pull_requests.enabled: true` and `pull_requests.checks.enabled: true`: the `QA` run only
dispatches on a head the PR and CI watcher reads as green ([rule R27](pr-ci-decisions.md)).

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

`enabled` switches only the terminal dashboard Symphony draws on its own output. The HTTP API and the
control plane stay up when it is `false`. Symphony also skips the terminal dashboard when
its output isn't a terminal (a file or a pipe). `symphony dashboard [--url <control url>]` draws the same
view in another terminal by polling `GET /api/v1/state?format=terminal&columns=<n>` on the control plane.

Symphony serves no web dashboard: its UI is the Mac app, which reads the JSON API. The filtered
audit stream (NDJSON) is available from `/api/v1/audit`, and each day's chain verification from
`/api/v1/audit/verify?date=YYYY-MM-DD` (see SPEC §13.8.2). Per-issue transcripts are available in
the Mac app and as JSON at
`/api/v1/repos/<repo_key>/issues/<issue_identifier>/transcript` (or
`/api/v1/issues/<issue_identifier>/transcript` for the default repository).

**Control plane.** CLI commands (`mix symphony.pause`, `symphony.resume`, `symphony.stop`,
`symphony.pr`) reach the running daemon over a loopback HTTP control plane on the dashboard port.
Discovery is automatic: on start the daemon writes `<state-root>/control_url` and a bearer token to
`<state-root>/control_token` (both `0600`). Override either with `SYMPHONY_CONTROL_URL` or
`SYMPHONY_CONTROL_TOKEN` for remote setups (e.g. when the daemon is reverse-proxied).

**Stop** (`POST /api/v1/control/stop`, `mix symphony.stop`, the Director's Stop Run) ends one
ticket's run and leaves its Linear state as it is, but the ticket is not dispatched again: Symphony's
copy of it still reads the old state until a poll, so the stop pauses it on a reason that waits on
you, lists it under `dispatch_skipped` with the reason's text (`Stopped by you at <time>. Unblock runs
it again; Restart starts it over from main.`), and asks for a poll at once. The pause is in the run
store (it survives a restart); beside it the stop sets a `Blocked` hold of type `operator_stop`, its
Linear label, shown in the Inbox as "Stopped by you". A poll that finds the ticket closed or out of
the active states clears both; otherwise the ticket waits for a person: **Unblock** runs it again in
place, **Restart** starts it over from main, and moving it to another state on the board clears the
stop too.

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
  dispatch_loop_runs: 4
  dispatch_loop_window_ms: 600000
  dispatch_loop_long_runs: 8
  dispatch_loop_long_window_ms: 3600000
```

A run is restarted only on proven silence: the orchestrator has heard from its agent (a session id,
a transcript event or a Claude Code `tool_progress` heartbeat) and then nothing for the whole bound,
`no_progress_threshold_ms` (default `600000`, 10 minutes) or, before the first transcript event,
`agent.timeouts.stall_ms`, while the run's process lives. Every run kind reports the same way:
implementation, Code Review and QA runs all forward their streamed events to the orchestrator, so
each running entry, `/api/v1/state` and the ticket page show the run's session and its latest
activity. A run the orchestrator never heard from is unobserved, not silent: the watchdog logs
`watchdog.unobserved_run` once per run at warning level, with `issue_id=`, `issue_identifier=`,
`run_kind=` and `age_ms=`, and keeps it. Such a run ends through the exit path: the agent's own
`agent.timeouts` (`turn_ms`, `read_ms`), a hook's timeout, or its process exiting.

Before Code Review runs reported their events, every review longer than the bound was restarted
while it worked, and operators raised `agent.timeouts.stall_ms` (to 20 minutes) and
`watchdog.no_progress_threshold_ms` to cope. Those raised values are no longer needed: remove them
from your `symphony.yml` to go back to the defaults.

`pending_tool_report_after_ms` (default `60000`, one minute; a positive integer) is how long one of
Symphony's own MCP tool calls (`linear_*`, `github_*`, `qa_*`) must run before Symphony's state and
the dashboard show the run as waiting on it. Settings in the macOS app edits it as "Show a pending
tool call after", in minutes.

The `dispatch_loop_*` keys (positive integers; the two `runs` at most 50) bound how often one ticket is dispatched without
progress, whatever `enabled` says. Symphony records every run it starts in the ticket's store record
and, before the next one, counts the runs of the same kind since the ticket last made progress: a
state move, a new PR head, a recorded verdict, or a hold that lifted. A run stopped by a usage limit
or an unreachable model API isn't counted, nor an epic review that found CI still running on the
commit it reviews (that wait has its own one-hour bound, see the epic review). When those runs already reach `dispatch_loop_runs` within
`dispatch_loop_window_ms` (4 in 10 minutes by default) or `dispatch_loop_long_runs` within
`dispatch_loop_long_window_ms` (8 in an hour), Symphony starts no more. It puts the ticket on a
`Blocked` hold whose reason names the run kind, the count, the window and how the last runs ended
(exit, whether they left a new PR head, the handoff signal or its absence), logs one error line, and
lists the ticket in the Inbox and in `waiting_on_you` of `/api/v1/state`. `Unblock` or `Restart`
lifts the hold, and the count starts again. Settings in the macOS app edits the limits in its
Dispatch loops section, as "Hold a ticket after" and "Or after", each a number of runs in minutes.

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
    range: [4100, 4199]
  dev_server:
    build_cmd: "pnpm install"   # optional, runs before start_cmd
    start_cmd: "pnpm dev --port $SYMPHONY_VERIFICATION_PORT"
    health_check_url: "http://localhost:${SYMPHONY_VERIFICATION_PORT}/healthz"
    health_timeout_ms: 30000
    stop_signal: TERM
    stop_timeout_ms: 10000
```

`WORKFLOW.md` can override `verification.dev_server` per repo while inheriting the operator-owned
port range.

`enabled: true` starts `dev_server` on the Symphony host before the first turn of every agent run
(implementation, review and fix runs alike) on a port from `port_allocation.range`, and turns on the
QA `web` playbook and other `dev_server: true` kinds, whose server runs on this host too. With
`enabled: false` no agent run starts a dev server or takes a port. A `macos_app` QA pass with
`dev_server: true` reads only `dev_server`, whatever `enabled` says: its server runs on the QA VM,
never on this host (see [macOS app QA](#macos-app-qa)).

`dev_server` set with `enabled: false` is a decision Symphony reads: the server must not start on
this host. QA's self-heal lane then never files the fix ticket that would turn `enabled` on for a
pass that has no server; a QA step that needed the server on such a pass is `unprovable` there, with
that reason, and the pass is decided by its other steps (see [QA passes](#qa-passes)). A `macos_app`
pass with `dev_server: true` runs the server on the QA host and is judged as before.

The pool hands out the first port in `range` that no other run holds and nothing on the host already
listens on (on `127.0.0.1`), so a port another program took is skipped rather than failing the run.
The default range, `[4100, 4199]`, leaves out `4000`, Symphony's own API port. When every port is
taken the dispatch waits for one, logging `Verification port range exhausted`.

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
with nothing at the socket, the run fails with `dev_server_not_on_socket`, and a QA
`web` pass is `blocked` with that reason. An Elixir dev server can't run Mix inside the sandbox at
all: every task that loads deps starts `Mix.PubSub` on an ephemeral `127.0.0.1` port, and Mix's
build lock takes one too, both refused by the no-TCP-listener profile. Build the escript or release
in `build_cmd` and point `start_cmd` at that prebuilt artifact, so the dev server's sandbox only
starts the artifact and never Mix (`scripts/qa-dashboard-server.sh` does this).

The health check asks `health_check_url` every 250 ms and gives each request 250 ms, until one
answers 200 or `health_timeout_ms` passes. Point it at a route that answers at once, not a page the
server builds on each request: in the sandbox, on a shared runner, a page that takes 300 ms fails
every probe. Symphony's own API has `GET /api/v1/health` for this.

`build_cmd` (optional) runs with `sh -lc` in the same checkout before `start_cmd`, every time the
dev server starts: in an agent run before the first turn, and in a QA `web` pass in its
fresh worktree at the PR head, which has no `deps/`, `_build/` or build output yet. It gets the dev
server's environment (`SYMPHONY_VERIFICATION_PORT`, the agent cache folder, the egress proxy, its
own `$TMPDIR`; no `SYMPHONY_VERIFICATION_SOCKET`) and runs in the agent's confinement rather than
on the host: the dev server's sandbox, but allowed to listen on loopback as the agent's sandbox
is, so Mix can run (see
[security](security.md#the-build-command-runs-in-the-agents-confinement)). A build that exits
non-zero (`dev_server_build_failed`) or runs past 15 minutes (`dev_server_build_timeout`) keeps
the dev server from starting and releases its port: the agent run fails with
`verification_failed`, and a QA `web` pass is `blocked`. Symphony's own repo builds its
dashboard escript with it when `WORKFLOW.md` sets:

```yaml
verification:
  dev_server:
    build_cmd: scripts/qa-dashboard-build.sh   # mix deps.get && mix build, through mise when present
    start_cmd: scripts/qa-dashboard-server.sh
```

The QA `web` playbook starts the same dev server, from a worktree at the PR head, for each web QA pass
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
  # GitHub webhooks through a relay; they feed the PR and CI watcher, whose poll stays on.
  webhooks:
    enabled: false
    relay: smee # smee | cloudflare_tunnel | tailscale_funnel | gh_webhook_forward
    secret: $SYMPHONY_GITHUB_WEBHOOK_SECRET # unset: read <state-root>/github_webhook_secret
    events: [check_suite, check_run, workflow_run, pull_request, push, release]
    fallback_poll_interval_ms: 300000 # the safety-net poll while deliveries are healthy
    silence_alert_minutes: 10 # warn after this long without a delivery
```

`webhooks` lets GitHub tell Symphony at once that a pull request's checks finished, its head moved,
it closed, or its base branch moved, so a red head or a conflict reaches its CI Fix run within
seconds instead of up to one `pull_requests.poll_interval_ms`. Symphony listens on `127.0.0.1`, so
the deliveries come through a relay to `POST /api/v1/github/webhook` on the dashboard port. Each
delivery patches the facts the PR and CI watcher keeps for the PRs it names (`watch.source` reads
`webhook`), and the watcher reads those PRs 3 seconds later, once a CI run's burst of deliveries
settled; only that read decides and acts, as the timed poll does, and only a read calls a head
green. A `push` to a base branch marks every open watched PR on it as of unknown mergeability and
reads them one by one, 1 second apart; a PR that closed by merging does the same for its base. A
`ping` (sent when a hook is created) reads every watched PR. A `release` published on
`tonypine/symphony`, the repository the macOS app updates from, records its newest release; the
watcher of the first repository also reads it on each timed tick, with one conditional
`gh api` request. `/api/v1/state` reports it to the macOS app under `app_update.latest_release`. Deliveries whose `X-Hub-Signature-256` does not verify get `401` and are logged
without their payload.

Polling stays on and catches up on anything the relay drops while the Mac sleeps or Symphony
restarts. While deliveries are healthy (one arrived, and no read since found a change none
reported) the watcher's timed poll is only a safety net, every `fallback_poll_interval_ms`; a read
that finds a change no delivery reported marks them unhealthy, and the watcher polls every
`pull_requests.poll_interval_ms` again until the next delivery. Each repository's health (last
delivery, signature failures in the last 24 hours, deliveries missed) is kept across restarts. A
repository with no delivery for `silence_alert_minutes` is reported as silent. The dashboard's
GitHub webhooks card shows whether webhooks are on, when the last delivery arrived, and how many CI
results came through the relay and how many by polling. Both intervals are in the app's Settings
window, under **GitHub updates**. See [github-webhooks.md](github-webhooks.md) for relay setup on
macOS.

Symphony can set webhooks up itself (`GET /api/v1/setup` → `github_updates`, and
`POST /api/v1/setup/github_updates/<action>`): turning them on writes `enabled` and `relay`, the
secret step writes `secret: $SYMPHONY_GITHUB_WEBHOOK_SECRET` (never the value), and the port step
pins `dashboard.port`; turning them off writes `enabled: false`. With `relay: gh_webhook_forward`
Symphony runs one `gh webhook forward` per connected repository and restarts it when it drops; the
other relays need their public URL, and Symphony adds a hook to each repository with
`gh api repos/:repo/hooks`.
The app's Setup page drives it from its **GitHub updates** card: **Turn On Instant Updates…** and
**Turn Off…** (`enabled`), **Change Relay…** (`relay`), **Re-create Secret…** (`secret`), and the
events (`events`) listed under Details; the two intervals there are the same as in Settings.

### `linear`

Linear's workspace webhook, and how often the poll reconciles the ticket records with Linear.

```yaml
linear:
  reconcile_interval_ms: 300000
  webhooks:
    enabled: false
    secret: $SYMPHONY_LINEAR_WEBHOOK_SECRET # the webhook's signing secret, or a literal
```

`webhooks` describes the one webhook the operator creates for the Linear workspace, so Linear can
tell Symphony of every ticket change the moment it happens, as GitHub's webhooks do for pull
requests. Symphony receives its deliveries at `POST /api/v1/linear/webhook` and only counts them
for now (`linear_webhooks` in `/api/v1/state`): it still learns of Linear changes only by polling. `enabled` defaults to `false`. `secret` is the signing secret Linear shows when the webhook
is created, as a literal or an `$ENV` reference resolved like `github.webhooks.secret`; turning
`enabled` on without a `secret` is refused, naming `linear.webhooks.secret`. A reference to an unset
variable loads, and every delivery is then refused as having no secret. A delivery is Linear's when
its `Linear-Signature` header is the HMAC-SHA256 of the raw body with the secret, and its
`webhookTimestamp` is within sixty seconds of now. See [linear-webhooks.md](linear-webhooks.md).
Neither key has a control in the macOS app yet.

`reconcile_interval_ms` (default `300000`, five minutes) is how often each repository's poll of
Linear runs while `dispatch.source` is `record`, in place of `issues.poll_interval_ms`. A whole
number of at least `60000` (one minute); a lower value is refused, naming
`linear.reconcile_interval_ms`. Under `poll` it does nothing. See the reconciler under
[`dispatch`](#dispatch). It has no control in the macOS app yet (TP-1228).

### `dispatch`

Where the dispatcher reads its candidates from, and the shadow report that proves the ticket
records give the same answer as the poll before the dispatcher trusts them.

```yaml
dispatch:
  source: poll
  shadow_window: 20
```

- `source` (default `poll`): `poll` dispatches from the poll cache, the tickets each repository's
  last poll of Linear returned. `record` dispatches from Symphony's ticket records, which the polls,
  the by-id reads, the PR and CI watcher, Linear's webhook and Symphony's own moves keep (see
  below).
- `shadow_window` (default `20`): how many poll cycles the report's window covers. A whole number
  above 0.

Symphony reads both on each poll cycle, so a change applies without a restart. In the macOS app,
Settings' Dispatch group holds both: a "Dispatch from" picker (Linear poll, Symphony's record) and
the window as a number of cycles, which Save refuses below 1. Setup's Dispatch shadow line shows the
report below: the cycles compared, the differences in the window and when the last one appeared,
with the last ten differences under a disclosure. Against a Symphony without the report the line
says it is not available.

**Dispatching from the record.** With `source: record`, each poll cycle builds its candidates from
every repository's ticket records instead of the poll cache: a record that says the ticket is in an
active state, assigned to the worker (the route's `assignee`, else `tracker.assignee`) and not
terminal is a candidate, rebuilt with the record's state, priority, labels, assignee, open blockers,
sub-issues and parent. The record keeps no comments, so a candidate the last poll also returned
takes its text from the poll, with its team, project, branch and the `updatedAt` they were read at:
the dispatch gates (holds, the review flow, the slots), the plan-comment reader and the quality gate
then run on it as on a polled ticket. Just before its run starts the ticket is checked against its
record instead of being read again from Linear: it starts only while its record is still observed,
assigned to the worker, not removed and in the phase it was chosen in, with a Linear `updatedAt` no
older than the candidate's, and its blockers and the other dispatch gates still let it through;
otherwise it is skipped as a stale dispatch, as a read from Linear would skip it. The run starts with
the record's fields over the candidate's text. With `quality_gate.enabled`, a candidate only the
record has waits for its repository's poll to read its text, which a change to its record asks for
at once, rather than being scored without a description. The polls keep running and keep the
records up to date; a ticket the record has and the last poll did not return is dispatched, and
one the poll returned whose record is gone is not. Nothing dispatches
after a start until every repository's first poll has answered, so a record left from before the
restart is refreshed first. A repository whose records can't be read gives no candidates that cycle.

A change to a record outside the poll cycle (a webhook delivery, the PR and CI watcher's read, a
removal) asks for a cycle of the ticket's repository at once while `source` is `record`, as a move
Symphony or the Director makes there always does, so a ticket the change frees starts within
seconds instead of at the next timed poll. Under `poll` the change waits for the repository's poll.

**The poll cycle's own reads under `record`.** Each cycle also refreshes the tickets Symphony is
running, watching after a run, forcing and holding for an operator's stop. Under `record` it takes
them from their records in one store read instead of reading each group from Linear by id: a running
ticket whose record left the active states stops its run, a forced ticket keeps its place outside
them, and a stopped ticket stays skipped while its record is a candidate. A record a webhook marked
removed reads as a ticket Linear no longer returns; a ticket with no observed record is not judged
that cycle, as when a read fails. Each keeps the text Symphony already holds for it (the poll's, else
its run's). The one exception is a watched plan parent in Plan Review with the `plan` label: no poll
reads that state and the record keeps no comments, so it is still read by id, and the plan-comment
reader, which acts on watched tickets only, sees a person's new comment as under `poll`. A forced or
stopped plan parent that is not watched is taken from its record like any other. A retry's own read
of its ticket is written into the record, so the check before its start is never older than that
read.

**The PR and CI watcher under `record`.** Each watcher's tick takes its watched tickets (those in
`In Progress`, the code-review state, the QA state, `Rework`, the CI-fix state and `Merging`) from
its repository's records, by the same filter as dispatch with the watched states in place of the
active ones, instead of reading those states from Linear: neither its tick nor the confirm read
after a GitHub delivery makes a Linear request, and a ticket Symphony or the Director moved, which
writes the record first, is watched from the next tick. Its GitHub reads are unchanged. Each
watched ticket carries its record's description, team and project, and the decisions and rulings
Symphony recorded on it, read from its store: the question about a PR that changes protected files
([rule R18](pr-ci-decisions.md)) recommends allowing a change the ticket asked for, a person's Allow
lets the PR land, and a fix ticket the self-heal lane files goes to the ticket's own team and
project, as under `poll`, with no Linear read. With `assignee: me`, the watcher waits for a poll to
learn whose tickets are the worker's: until then its tick fails and keeps what it watched. Under
`poll` it reads Linear each tick, as before.

**The PR review poller and the CI poller under `record`.** Each poll takes its tickets (those in the
code-review state, the QA state, `Rework` and, where it watches it, `Merging`) from every
repository's records, by the same filter as dispatch with its states in place of the active ones,
instead of reading those states from Linear: a poll makes no Linear request, and a record a webhook
marked removed is never listed. Review comments and CI results still reach their tickets: the
GitHub reads are unchanged. With `assignee: me` the pollers, like the watcher, wait for a poll to
learn whose tickets are the worker's, and fail that poll until then. Under `poll` each poll reads
those states from Linear, as before.

**Hand moves under `record`.** The phase Symphony owns is not read back from Linear. A ticket's
phase is Symphony's once Symphony or the Director moved it (a claim, a handoff, a verdict, a move
from the app, an agent's own move through its Linear tool, such as a CI Fix run sending its ticket
to Rework or a plan run handing its plan to Plan Review); each of those writes the record before
Linear is asked. A phase only an observation wrote, such as a new ticket's Todo, is Linear's. When a
read of Linear (the poll, a by-id read, the PR and CI watcher or a webhook delivery) finds a ticket
whose phase is Symphony's in another state, someone moved it by hand: the record keeps its phase,
the ticket's timeline records `drift.detected` with both states, Symphony moves the ticket back in
Linear to the record's phase and records `drift.reverted` ("Moved back to Code Review: it was moved
to Done in Linear by hand"), or `drift.revert_failed` with the error. The move back runs on its own,
after the read that found the drift, so a slow Linear never holds that read up (a webhook delivery
answers Linear at once) and the outcome is always recorded; a ticket has one move back under way at
a time. Nobody is asked: no question reaches the Inbox. A failed move back is tried again by the
next read that finds the same difference, never on a timer of its own, and each event is written
once for the same Linear change. A Linear state read before Symphony wrote the phase is an older
fact: the phase is kept and nothing is moved. The ticket's other facts (title, description, labels,
priority, assignee, blockers) are Linear's and apply as before. A ticket whose phase is Linear's
follows Linear: a new Todo ticket a person moves to Backlog stays there, and the record follows.
Startup keeps a phase Symphony owns too: a ticket moved by hand while Symphony was down is moved
back when Symphony starts, with the same events. Under `poll` every hand move applies, as before.
`/api/v1/state` counts the drift since Symphony started as `reconcile`: `detected`, `reverted`,
`revert_failed`, and `recent`, the last ten, newest first, each with `identifier`, `record_phase`,
`linear_phase`, `outcome` (`reverted` or `revert_failed`) and `at`.

**The poll becomes the reconciler under `record`.** Nothing waits on the repository poll any more:
webhooks and Symphony's own moves keep the records, dispatch and the watchers read them, and a
record change asks for its repository's cycle at once. So the poll runs every
`linear.reconcile_interval_ms` (five minutes by default) instead of `issues.poll_interval_ms`, one
Linear request per repository per run. The first poll of each repository after a start keeps the
usual stagger over `issues.poll_interval_ms`, as dispatch waits for it, and a poll that fails is
tried again after `issues.poll_interval_ms`. Each run:

- observes the repository's tickets as any poll does: a change made in Linear while a webhook was
  lost (Symphony was down, the webhook was off) or that Linear does not deliver is applied, a new
  ticket gets its record, and drift on a phase Symphony owns is moved back;
- makes again each write to Linear that failed: a move of Symphony's or the Director's whose Linear
  write failed leaves the record moved and marked (`pending_projection`), and so does a hold's label
  that could not be set or cleared; the run reads the record again just before the write, writes its
  phase, or sets or clears the label as it holds the hold, and drops that mark (a newer one, from a
  write that failed meanwhile, stays for the next run). A ticket the poll already shows as the record says
  is not written again; a mark whose phase is no longer Symphony's, or whose ticket was removed, is
  dropped; a write that fails again stays marked for the next run;
- reads by id, in one request, up to 50 of the repository's records no read of Linear observed yet
  and the poll did not return, and fills them. A record Linear does not return (its ticket was
  archived or deleted) is marked `not_found_at` and never read again, so once they are all read a run
  makes no request beyond the poll's.

The second and third steps run on their own after the poll, so the cycle never waits on them. The
reconciler never decides a phase: it only projects the record's own. Under `poll` the repository
poll runs every `issues.poll_interval_ms` and only observes, as before.

`/api/v1/state`'s `reconcile` also carries `last_run_at`, `interval_ms`, `applied` (changes made in
Linear its observations applied), `reapplied` (failed writes it made again) and
`unobserved_filled` (records it filled), counted since Symphony started.

Setting `source` back to `poll` is the rollback: the next cycle dispatches from the poll cache
again, and no run is stopped or restarted.

**The shadow report.** Every poll cycle, whatever `source` says, Symphony also works out each
repository's candidates from the side it doesn't dispatch from and compares the two sets: a ticket
only the poll has, a ticket only the record has, and a ticket both have with a different state or
priority. The report names the poll and the record sides the same way whichever is in use. A
repository whose poll has not answered yet is left out of the cycle. The comparison reads
Symphony's store, never Linear, and writes nothing. `/api/v1/state` returns the report as
`dispatch_shadow`:

- `source` and `window`: the two settings;
- `cycles_compared` and `cycles_with_differences`: the cycles since Symphony started;
- `window_cycles` and `window_differences`: the last `window` cycles, and how many differences
  they found together (a difference that lasts three cycles counts three times);
- `recent`: the last ten differences that appeared, newest first, each with `repo_key`,
  `issue_id`, `identifier`, `side` (`poll` or `record` for a ticket only that side has, `both` for
  a ticket both have), `field` (`candidate` for a ticket only one side has, else `state` or
  `priority`), what each side has (`poll`, `record`: the state for `candidate`, nothing on the side
  without the ticket) and `at`.

- `record_newer`: the differences the record being newer explains, counted apart: `count` since
  Symphony started, and `recent`, the last five, newest first, each with `identifier` and `side`.

A difference means the two sides disagree on a snapshot at least as new as the record: Linear was
read for the poll cache no earlier than the record last changed, so one side is behind. A
difference in a ticket's state, or in whether it is a candidate at all, whose record changed after
that read is the record being the fresher side, not drift: Symphony's own move, which writes the
record before Linear (a ticket the poll still lists in Merging that Symphony closed once its PR
merged, or one Symphony promoted that the poll doesn't list yet), a person's move or a removal a
webhook delivered, or a newer read of the ticket while the poll ran. It counts under `record_newer`
instead, once while it lasts, and the repository's next poll compares the two again on a fresh
snapshot, so a lag that is real still shows. A priority difference, a ticket the record has never
observed, and a ticket whose record has no phase time yet (written before Symphony kept one) are
always differences.

A difference is logged at warning level once while it lasts (`Dispatch shadow difference:`), and
once more if it comes back after it cleared. `window_differences` staying at zero across a window
of tickets is the sign that `source: record` will dispatch what the poll would; `record_newer`
ticking up meanwhile is Symphony's own moves landing between a poll and the comparison.

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
- `label` is retired: a request pauses the ticket in its phase on the **Needs Decision** hold,
  whose label Symphony sets itself, and `linear_request_human_action` adds no label of its own. A
  config that still sets `human_actions.label` fails to load as an unknown key.
- `interval_ms` (default `300000`): how often Symphony reads the open actions. A read is one Linear
  request per repository route, plus one per project the first time Symphony sees it, plus one per
  update posted. They show as `human_actions` in the dashboard's Linear usage table.
- `min_update_interval_ms` (default `900000`): the least time between two updates to one project. A
  change inside that window is posted once the window has passed, with whatever is open by then.

### `ledger`

The largest artifact file (a QA screenshot, a run transcript) the ticket ledger stores, and the
summary of a ticket's history that agents start from. Each has a control in the Mac app's Settings,
under Ledger. Symphony keeps every artifact file for good, so a ticket's history stays whole; a
file found missing from the store is answered as unavailable (the artifacts API's 410).

```yaml
ledger:
  artifact_max_bytes: 26214400
  prompt_brief_enabled: true
  prompt_brief_max_tokens: 50000
```

- `artifact_max_bytes` (default `26214400`, 25 MB): the largest file Symphony stores as an
  artifact; a larger one is refused.

- `prompt_brief_enabled` (default `true`): every agent prompt that carries the ticket's state also
  carries a summary of the ticket's whole history, read from its ledger, after the ticket state:
  its phase and holds; every decision (each request with its answer or withdrawal, every open
  request, every ruling); every open finding, grouped by class with a count, each with its
  viewport, commit, when it was last seen and its whole description; every note, a person's shown
  as the Director's; one line per run, with the latest run's events in full; and every other event
  outside a run, newest first. Nothing is left out to fit a size, and the same ledger renders the
  same summary. The summary replaces the ticket state's "Recent signals" lines, and it is wrapped
  as untrusted input, since it carries agents' and people's text. `false` leaves the prompt as it
  was before the summary existed. `symphony workflow preview` shows it for a sample ticket.
- `prompt_brief_max_tokens` (default `50000`, about 200 decisions and open findings with their whole
  text): a guard against a summary that grew absurdly, not a budget. Nothing is ever left out of a
  summary to fit it. A ticket whose summary is over it (its size in tokens is its bytes / 4) starts
  no agent: Symphony asks the Director how it goes on, with what the summary holds and its size, and
  the ticket waits on that decision in its phase. **Go on with the whole summary** lets it continue,
  and every later run on it gets the whole summary whatever its size; **Cancel the ticket** moves it
  to `Canceled`; an answer in the Director's own words lets it continue, and its next run asks again
  while the summary is still over. The answer is read from the ticket's ledger. With
  `prompt_brief_enabled: false` the limit is never checked.

`prompt_brief_enabled` is `true` or `false`; the other two must each be a whole number above 0.
Symphony reads them on each run, each prompt and each stored file, so a change applies without a
restart. `artifact_retention_days` was removed: a `symphony.yml` that still sets it is refused, and
the fix is to delete the line.

**Waiting on you.** The list `/api/v1/state` returns as `waiting_on_you`, which the dashboard and
the menu bar app show, is the Mac app's Inbox (`GET /api/v1/inbox`) in short. Symphony builds it on
its own poll, not on this read: every `polling.interval_ms` it lists the tickets in
`issues.states.plan_review` in each route's scope plus the ones Symphony's store holds `Blocked`
or `Needs Decision` (a hold pauses a ticket in its phase, wherever it sits; the label is only its
projection, so a ticket whose label went missing is still read), reads a ticket's
comments again only when the ticket changed, and adds the quality gate's holds and skips. Each entry has
`issue_identifier`, `repo_key`, `title`, `url`, `state`, `kind` (`action` for an open request,
`plan` for a `plan` or `breakdown` parent in `Plan Review`; `clarify` for a quality gate hold or
skip; `blocked` for a ticket an access hold pauses in place, with the reason the hold
recorded and what clears it), `decision` (true for a request with options, which the app calls a
Decision as the Inbox does; false for an older hand-written request with steps and every other
kind), `headline` (its one-line ask: the text after `**What to review:**` in the latest
`## Review brief` comment, the request's title, or what the quality gate asks), `waiting_since` and
`waiting_seconds`; `counts.waiting_on_you` is their number. A ticket the orchestrator sees running,
or watches outside `Plan Review`, is dropped — unless a hold pauses it, which is what waits on the
Director. A plan that leaves `Plan Review` (approved, or sent to `Rework`) drops out on the next
read. It doesn't depend on `human_actions.enabled`.
`inbox_read` is false while Symphony has not yet read Linear for the list (the first read starts a
second after startup), and true from its first successful read on, or when the tracker isn't Linear.
The Mac app waits for it before it remembers what already waits, so nothing that was there notifies.

**Where actions come from.** On each read, in the scope each repository route polls, Symphony
lists:

- each open `## Decision needed:` comment. Agents post one with `linear_request_human_action`
  (`title`, `why`, a `decision` with one `question` and 2 to 4 `options`, each with a `label`
  and an `effect`, up to three `tradeoffs` and exactly one `recommended`, an optional
  `decision.recommendation_reason`, and optional `if_unanswered` and `unblocks`) when only a
  person can decide: a product call, a missing secret or permission (add it, or drop what needs
  it), an account to set up. Every field is written in the Director's words
  ([the decision writing standard](standards/decision-writing.md)): a request holding backticks,
  template syntax, a path or file name, a commit hash or an `auto/` or `origin/` branch is refused,
  with each token and its field named. A request without options is refused, and a person never gets a check
  to run: a check an agent can't run (launching the app, a host crash check, a check on a device)
  belongs to CI or a QA playbook. The update lists the question and the options, the recommended
  one marked. The tool leaves the issue in its phase and sets the **Needs Decision** hold; the hold
  ends the run shortly after, so the agent first pushes its committed work (and opens or updates
  the PR when the rest of the ticket is done) and updates its workpad. A request whose title
  matches one still open on the issue is not posted again. An agent that finds its request is not
  needed after all withdraws it with `linear_withdraw_human_action` (`reason`, optional `title`):
  Symphony replies `## Action withdrawn` with the reason under the request, which closes it. A
  person's reply under the request (or **Send Decision…** in the Inbox) answers it and closes it
  too. Once no open request is left on the issue, the hold clears and the ticket continues where
  it stopped;
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

Only Symphony opens a decision request: an agent's `linear_request_human_action`, or one of
Symphony's own checks. Each records the **Needs Decision** hold in the run store first and adds the
label after it, and the Inbox finds held tickets through the store, never by label. A
`Needs Decision` label added by hand, with no hold in the store, is cleared on the next poll, and a
request comment posted by hand on a ticket with no hold is never read. The request comment Symphony
posts has this format:

```md
## Decision needed: Turn on the pre-push hook

**Question:** Turn on the pre-push hook on your laptop?
**Why:** Pushes from your laptop skip the format and lint checks without it.
**If unanswered:** CI keeps catching what the hook would, a few minutes later.
**Unblocks:** clean pushes from your laptop

**Options:**
1. **Turn it on** (recommended): pushes from your laptop run the checks first.
   - Good: A broken push never reaches CI.
   - Cost: Each push takes a few seconds longer.
2. **Leave it off**: CI keeps catching what the hook would.

**Why recommended:** It catches the mistake before anyone waits on CI.
```

Write it in the Director's words ([the decision writing standard](standards/decision-writing.md)).
`**If unanswered:**`, `**Why recommended:**` and an option's indented `- Good:`, `- Cost:` and
`- Risk:` lines are optional. The older `## Action needed: <title>` heading, with a `**Steps:**`
list, is still read, and so is an older `**Time:**` line, which is ignored. Only the heading is
required.

**When an action closes.** A request closes when a person replies under it (or answers it in the
Inbox), when the agent withdraws it, or when its issue reaches a terminal state. A blocked QA
cause closes when every issue blocked on it leaves its phase or its next QA report is not
`blocked`. A missing secret closes when the next run of
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
- under it, what it unblocks, so the reader can pick what to do first;
- the why and what waits until it is answered, then the steps as a numbered list, one instruction
  per line (no tables, which scroll sideways on a phone);
- a closing **Done when** line, saying how the action leaves the list;
- ordered by issue, so the list stays put between updates;
- a footer with the list id, which is how Symphony recognises its own last update.

The update sets the project health: `atRisk` while any action is open, `onTrack` when none is.
Symphony cannot judge the schedule beyond that, so it never sets `offTrack`; this replaces the
health set by the project's previous update. No secret value reaches an update:
`linear_request_human_action` refuses any field that holds a secret pattern, and the whole update
is redacted again before it is posted, which covers secrets pasted into an issue or comment by hand.

A rendered example, for a mix of a decision on release signing and an older hand-written
`## Action needed:` request with steps:

```md
**2 actions need you.**

### 1. Add the release signing secrets

Unblocks [MOT-24](https://linear.app/acme/issue/MOT-24): the Release workflow on main

**Why:** Every Release run on main fails at the signing step without them.

**If unanswered:** Every Release run on main keeps failing, so no build ships.

**Decide:** Add the signing secrets, or ship unsigned builds?

1. **Add the secrets** (recommended): you add the signing certificate and its password to the repository's Actions secrets; releases are signed again.
2. **Ship unsigned**: the agent drops the signing step; Gatekeeper warns on first launch.

**Done when:** you reply with your pick (or answer it in the Symphony Inbox), or the agent withdraws the request.

### 2. Turn on the pre-push hook on your laptop

Unblocks [MOT-31](https://linear.app/acme/issue/MOT-31): clean pushes from your laptop

1. Run `git config core.hooksPath .githooks` in your cycle checkout.

**Done when:** you reply to the request, or the agent withdraws the request.

---
_Symphony posts a new update when this list changes · list `b1712c40`_
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
proof_check: make-all
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

The front matter accepts only `hooks`, `prompts`, `push_check`, `proof_check`, `verification`,
`validation`, `human_actions.enabled`, `playbook` and `auto_review.playbooks`; any other key fails
the repository's workflow.

`proof_check` is the GitHub check run or workflow name that proves the repository's automated tests
ran (this repository: `make-all`). A walkthrough step the implementer ends with `Proved by: <test>`
names a test it runs, and the QA pre-check confirms that check passed on the PR head and the test is
in the checkout (see [Which steps QA walks](#auto_review)). Without it the repository has no
named-test proofs: QA walks every walkthrough step. It is a non-empty string, read through
`SymphonyElixir.Config` as the repository's `proof_check` setting; `symphony.yml` has no such key. `hooks`, `verification`
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
- `before_remove` gets the branch in `SYMPHONY_BRANCH`, its GitHub repo in `SYMPHONY_REPO`, and
  why the workspace goes in `SYMPHONY_REMOVE_REASON`: `terminal` when the ticket reached a
  terminal state, which `SYMPHONY_ISSUE_STATE` names; `stop` when the operator stopped its run
  (Stop Run, `mix symphony.stop`); `cleanup` for any other removal, such as a restart or the workspace
  lifecycle sweep. `SYMPHONY_ISSUE_STATE` is empty for the last two. A hook that closes the
  branch's pull requests should close them only for `terminal`: a stopped ticket is still worked.
  A move to a state that isn't terminal, such as Backlog, removes no workspace.
- A hook on this machine runs Gradle without a daemon: Symphony appends `-Dorg.gradle.daemon=false`
  to the host's `GRADLE_OPTS`. Gradle then never hands the hook's build to a daemon an agent
  started inside its sandbox, and the hook leaves no daemon behind.

Each repository's `WORKFLOW.md` sets its own hooks and timeouts.

### Scoped GitHub tools

Agents reach GitHub only through Symphony's scoped `github_*` tools: `gh` itself is refused in the
agent sandbox. Each tool acts on the session's `origin` repository and refuses repo, remote, branch
and ref arguments. The read tools are given to every run kind, the reviewer and QA included; the
others to the implementation runs.

| Tool | What it does |
| --- | --- |
| `github_get_pull_request` | Reads the current branch's pull request. |
| `github_get_pr_checks` | Reads its checks: names, status and conclusions. |
| `github_list_pr_comments`, `github_list_pr_review_comments`, `github_list_pr_reviews` | Read its comments and reviews. |
| `github_get_failed_run_log` | Reads the failed log of its latest failing run, clamped to `github.failed_run_log_max_bytes`. |
| `github_ci_log` | Reads a failed job's log: pass `run_id` (a run's failed jobs), `job_id` (one job) or `pr_number` (a pull request's failed checks). Each job comes with its failed steps, its annotations and the last 400 lines of its failed steps' log, each line clipped, at most 10 jobs. `failed_only` (default true) refuses a job that did not fail; `false` reads every job and step. A run or job of another repository is refused. |
| `github_fetch_origin`, `github_sync_base` | Fetch `origin`, and merge the base branch outside the sandbox. |
| `github_create_pull_request`, `github_update_pull_request_body`, `github_add_pr_comment`, `github_reply_to_review_comment` | Open the pull request and write on it. |
| `github_push_branch` | Pushes the branch (see [Push check](#push-check)). |
| `github_merge_pull_request` | Squash-merges it, only in `Merging` with every check green. |

The epic review uses `github_ci_log` to name why CI failed on the commit it reviews, and Symphony
quotes the same log (failed steps, annotations, the last 60 lines of each failed job) in the
follow-up it files for that CI. The CI Fix run gets the failed log in its prompt, as before.

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
