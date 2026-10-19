# Symphony

## This Fork at a Glance

`tonypine/symphony` is my fork of Symphony and the base of a personal AI software
factory — Linear tickets in, reviewed pull requests out — used for personal projects and
professional work.

**Lineage:** [openai/symphony](https://github.com/openai/symphony) →
[Automattic/symphony](https://github.com/Automattic/symphony) →
[tonypine/symphony](https://github.com/tonypine/symphony).

**Direction:** run agents from more than one model provider (Claude already runs alongside Codex),
bring in improvements from community forks, and shape the workflow to fit how I work.

**Changes so far:** once an issue reaches `Merging`, Symphony lands its PR with GitHub auto-merge, without an agent. When auto-merge can't be used, an agent merges it through the scoped
`github_merge_pull_request` tool.

Symphony runs coding agents (Codex or Claude) on your Linear issues and GitHub pull requests, so
your team manages the work instead of babysitting the agents.

It watches Linear for issues to pick up, creates an isolated workspace for each one, runs the agent
against a workflow prompt you define per repo, and keeps the run moving — retrying failures and
recovering stalled sessions — until there is a pull request to review. You can also point it at an
existing PR from the CLI to address review comments, fix failing CI, or resolve conflicts.

[Demo video](.github/media/symphony-demo.mp4)

> [!WARNING]
> Symphony is an engineering preview for operator-controlled, trusted environments. It includes
> operational guardrails, but it is not a hardened multi-tenant service and should run behind trusted
> network and authentication boundaries.

![Symphony dashboard screenshot](.github/media/elixir-screenshot.png)

## How It Works

```text
Linear issue or PR -> Symphony -> workspace -> agent -> pull request
```

1. **Pick up work.** Symphony polls Linear and claims eligible issues (or you hand it a PR directly).
2. **Isolate it.** Each run gets a fresh workspace — a clean checkout or worktree, never your source repo.
3. **Run the agent.** It launches the configured agent against that repo's `WORKFLOW.md` prompt.
4. **Keep it moving.** Failed runs retry with backoff, stalled agents are detected and recovered, and
   results are reported back to Linear — so a long queue does not need constant supervision.

Issue runs end with a pull request and validation evidence. PR runs push back to the existing PR head
branch instead of opening a second one. If a claimed issue moves to a terminal state (`Done`,
`Closed`, `Cancelled`, `Duplicate`), Symphony stops its agent and cleans up the workspace.

Symphony keeps its own record of each ticket's pull request. A PR you open by hand on a ticket is
found within one poll when its branch is the ticket's Symphony branch (`auto/<identifier>`) or the
branch name Linear suggests for the ticket; a PR on a branch with any other name is not found.

<details>
<summary>Glossary</summary>

- **Workflow**: the repo-owned policy and prompt that tells Symphony what to run.
- **Run**: one attempt to make progress on a Linear issue.
- **Workspace**: the isolated checkout or worktree for a run.
- **Tracker**: the system Symphony polls for work, currently Linear.
- **Repo route**: an entry under `repositories:` in `symphony.yml` that pairs a repo (a local checkout,
  or a GitHub repo Symphony clones itself) with its `WORKFLOW.md` and optional Linear selectors. One
  Symphony process can supervise many repo routes.
- **Quality gate**: the optional pre-dispatch check that decides whether an issue is clear enough
  for an agent.
- **Harness engineering**: the practice of preparing a codebase with scripts, tests, docs, and
  guardrails so coding agents can work safely.

</details>

## Features

- **Multi-repo orchestration** — one process supervises several repositories from a single
  `symphony.yml`, with per-repo Linear selectors and conflict detection.
- **LiveView dashboard** — active runs, watched issues, the retry queue, quality-gate state,
  per-issue transcripts with JSON access, and an audit timeline.
- **Operator controls** — pause, resume, and stop, persisted across restarts.
- **PR-driven runs** — work an existing pull request from the CLI for review comments, failing CI, and
  conflict fixes.
- **Recovery** — a watchdog and retry queue handle stalled or failed sessions.
- **Durable run store** — run history, retry backoff, captured learnings, token totals, and
  notification dedupe.
- **Workspace guardrails** — age-based cleanup, startup orphan removal, and disk free-space pauses.
- **Shared-host CPU priority** — local agents and everything they start run at a lower CPU priority
  (`nice -n 10`) than Symphony, so one run's busy loop can't starve Symphony, QA passes, or other runs.
- **Scoped agent tools** — current-issue Linear updates, GitHub PR evidence, and attachment handling.
- **Quality gate** — optionally scores issue clarity before dispatch so unclear work is held back.
- **Ticket state machine** — every repo runs one ticket flow: `In Progress` → `Code Review` (a
  reviewer agent, on a green head) → `QA` (a journey-driven QA agent) → `Merging` → `Done`, with
  `Rework` continuing the same PR, `CI Fix` repairing red heads and conflicts, and epic parents
  going `Plan Review` → `Waiting on sub-tickets` → `Epic Review`. `Blocked` and `Needs Decision`
  are labels that pause a ticket in place; a person only decides, and `Restart` from the Director
  app is the full reset. The `Auto Review`, `In Review` and `Human Review` states are retired: the
  transition guard refuses every move into them, and Symphony logs any ticket still found in one at
  startup, at error level, and lists it in the dashboard's Drain report. The acceptance gate is
  retired too: its QA moved to the `QA` state, its judgment to `Code Review`, and its escalation
  rules to a Needs Decision hold or a deeper Code Review. Supervisor checks and
  `Final verification:` tickets are retired as well: an epic closes in its epic review. See
  [docs/design/state-machine.md](docs/design/state-machine.md) and SPEC §7.6.
- **Parent tickets** — label a large ticket `plan` (`breakdown`, the label's older name, still works)
  and the agent splits this plan ticket into sub-tickets instead of opening a PR, then hands the
  parent over to `Plan Review`. Approve the plan by moving the parent to `Waiting on sub-tickets`
  and Symphony promotes every `Backlog` sub-ticket to `Todo`; comment on the plan while it is in
  `Plan Review` to have it revised in place (artifact comments edited, `Backlog` sub-tickets
  updated, each comment answered); move it to `Rework` to have the plan made again. A plan run that
  stopped midway resumes from its workpad when the parent is moved to `In Progress`, keeping the
  sub-tickets already filed. The approved parent waits without being re-dispatched until every
  sub-ticket is closed, then Symphony moves it to `Epic Review`, which checks the epic against what
  shipped. Any other ticket whose PR merges with a sub-ticket still open outside
  `Backlog` waits in `Waiting on sub-tickets` too instead of closing, and Symphony moves it to `Done`
  once every such sub-ticket is `Done`, `Canceled` or `Duplicate`, with a comment listing how each
  ended. Its `Backlog` sub-tickets (ones an agent filed) stay
  there for a person to promote and never hold it: with only those open it goes to `Done` on merge.
  The design this flow
  is moving to (bug, feature and `plan` ticket types, one review of a whole plan, artifacts in
  Linear documents) is recorded in
  [ADR 0001: the Director workflow](docs/adr/0001-director-workflow.md).

  To move a workspace from `breakdown` to `plan`, rename the `breakdown` label to `plan` in Linear
  (Settings → Labels). Linear renames it on every ticket, so parents already in flight keep their
  state and Symphony starts no new run for them.
- **Actions for a human** — when work waits on something only a person can decide (a missing
  secret, a product call), the ticket stays in its phase on a `Needs Decision` hold, and Symphony
  posts a Linear project update listing each one, and posts again only when that list changes.
  Agents add requests with `linear_request_human_action` and withdraw them with
  `linear_withdraw_human_action`; see `human_actions` in
  [docs/configuration.md](docs/configuration.md).
- **Executor + reviewer runs** — an optional read-only reviewer agent gates the executor's push.
- **QA** — the `QA` state's agent uses each PR the way a user would, with
  built-in playbooks for CLIs (`cli`), web apps in a headless browser (`web`), macOS apps through
  accessibility in a QA VM (`macos_app`) and Android apps on a host-side emulator (`android_app`). See
  [`auto_review`](docs/configuration.md#auto_review), which keeps the QA settings. The `Auto Review`
  state and the acceptance gate are retired; the gate's escalation rules now act in Code Review
  (see [docs/acceptance_gate.md](docs/acceptance_gate.md)).
- **Docker runner** — host Symphony with mounted repos, state, logs, and agent credentials.
- **macOS menu bar app** — start, stop, pause, and resume Symphony from the menu bar, with its status in
  the icon, the Linear key in a file only you can read, optional launch at login, and updates from the menu. See
  [macos/README.md](macos/README.md).

![Symphony Web dashboard screenshot](.github/media/elixir-screenshot-web.png)

## Quickstart

Symphony works best in codebases that have adopted
[harness engineering](https://openai.com/index/harness-engineering/): scripts, tests, docs, and
workflow prompts that let coding agents work safely.

### On macOS: the menu bar app

On a Mac with Apple silicon, Symphony is an app you download: `Symphony.app` carries a self-contained
Symphony, so you need no checkout, `mise` or Elixir.

1. **Install the app** to `~/Applications` and open it:

   ```bash
   curl -fsSL https://raw.githubusercontent.com/tonypine/symphony/main/scripts/install-macos.sh | bash
   ```

   The script verifies the release before installing it. To download it by hand instead, see
   [Install](macos/README.md#install).
2. **Scaffold operator config.** From your operator repo, run
   `~/Applications/Symphony.app/Contents/Resources/symphony init` to create `symphony.yml`, then edit the
   issue scope, agent command, workspace root, and `repositories:`.
3. **Write a workflow per repo.** Connect each repo with **Add Repo…** in the app's Repos window: for a
   repo without a `WORKFLOW.md`, it drafts one from the repo's files for you to edit, then opens a pull
   request that adds it (or writes it into a local checkout). For a more tailored file, invoke the
   `symphony-init-workflow` skill from Codex or Claude in the target repo; the agent inspects the repo and
   writes one.
4. **Start Symphony.** In the app's Settings window, choose your `symphony.yml` and paste a Linear
   personal API key (Settings → Security & access → Personal API keys); the app keeps it in a file
   only you can read. Click Save, then choose **Start Symphony** from the menu.

The app updates itself from the menu and keeps the version it replaced for rollback. See
[macos/README.md](macos/README.md) for first run, Restart, Update, Rollback, and Development mode.

### From a checkout (development and Linux)

Run Symphony from a checkout to work on Symphony itself, or on a platform without the app.

1. **Get a Linear token** from Settings → Security & access → Personal API keys, and export it as
   `LINEAR_API_KEY`. Symphony reads all secrets from the environment — to avoid plaintext `.env`
   files on disk, load them through a secrets manager such as
   [1Password Environments](https://1password.com/blog/1password-environments-env-files-public-beta),
   `op run`, or `direnv` (see [docs/security.md](docs/security.md)).
2. **Install the toolchain and build:**

   ```bash
   cd symphony
   mise trust && mise install
   mise exec -- mix setup
   mise exec -- mix build
   ```

3. **Scaffold operator config.** Run `mise exec -- ./bin/symphony init` from your operator repo to
   create `symphony.yml`, then edit the issue scope, agent command, workspace root, and
   `repositories:`.
4. **Write a workflow per repo**, as above.
5. **Start Symphony:**

   ```bash
   mise exec -- ./bin/symphony
   ```

   The menu bar app can run a checkout too: turn on Development mode in its Settings. See
   [Development mode](macos/README.md#development-mode).

The LiveView dashboard runs at `http://127.0.0.1:4000` by default. It has no built-in authentication
and binds to loopback only — to expose it remotely, front it with a reverse proxy that handles auth
(Tailscale, Cloudflare Access, nginx). See [docs/security.md](docs/security.md) for details.

## Configuration

Symphony reads two files:

- **`symphony.yml`** — operator config: issue source, workspaces, agents, pollers, gates,
  notifications, and the `repositories:` list. Plain YAML.
- **`WORKFLOW.md`** — repo-local prompt and per-repo hooks. YAML front matter, then the prompt
  template. Each repo under `repositories:` has its own. Symphony reads the version committed on
  the repo's fetched base branch (`origin/<base_branch>`), so edit it by pushing. Set
  `workflow_source: local` on the repo to read the file on disk while you develop a workflow.
- **No local checkout needed.** Set `workspace.source: owner/repo` (or a github.com URL) on a repo
  and Symphony keeps its own clone under `~/.local/share/symphony/repos`, fetches it before each
  dispatch, and makes agent worktrees from it. Your own checkout, if you have one, is never touched.
  See [docs/configuration.md](docs/configuration.md#a-repo-symphony-clones-itself).

Minimal `symphony.yml`:

```yaml
issues:
  provider: linear
  linear:
    scope:
      project_slug: "..."
workspaces:
  root: ~/code/workspaces
agent:
  runtime: codex
  command: codex app-server
repositories:
  - key: my-repo
    workflow: ./WORKFLOW.md
# issue_gate is omitted here, so issues are dispatched without LLM scoring.
```

Minimal `WORKFLOW.md`:

```md
---
hooks:
  after_create: |
    git clone git@github.com:your-org/your-repo.git .
prompts:
  pr: |
    You are working on PR {{ pr.url }}.
    Intent: {{ pr.intent }}
---

You are working on a Linear issue {{ issue.identifier }}.

Follow this repository's conventions and validation commands before handoff.

Title: {{ issue.title }}
Body: {{ issue.description }}
```

The Markdown body is the issue prompt; `prompts.pr` is the optional PR-mode template. Symphony
prepends a managed runtime context (workspace isolation, untrusted-input handling, scoped tools,
secret handling, response shape) before either, so keep `WORKFLOW.md` focused on repo-specific
commands, conventions, and validation gates.

To run a kind of run's model through OpenRouter, set `provider: openrouter` and an OpenRouter
model id under `agent` or `agent.run_profiles.<kind>` (Claude runtime, local host only), and export
`OPENROUTER_API_KEY` in Symphony's environment (the macOS app sets it from the OpenRouter section of
its Settings). The key reaches `claude` only through its process env. The model must support tool
use: `symphony check` asks OpenRouter's models API and rejects an unknown model id or one without
`tools`.

For the full reference — every supported key, defaults, prompt variables, CLI flags, and the issue
gate — see [docs/configuration.md](docs/configuration.md).

## Running

Start the service from a directory containing `symphony.yml` (or pass `--config` to point elsewhere):

```bash
./bin/symphony                       # start the service
./bin/symphony --config ./other.yml  # use a different operator config
```

Validate `symphony.yml` and every repo `WORKFLOW.md` it points at without starting the service
(exit 0 with `Config OK: <path>`, or exit 1 with the error on stderr). It first prints the build it
runs on stderr, `Symphony <version> (<commit>)`. It checks the same
`WORKFLOW.md` startup reads: with `workflow_source: ref`, the committed copy on the last fetched
base branch, not uncommitted edits. A `strategy: worktree` repo
fails when its `workspaces.repo` is missing or isn't a git repository. A `workspace.source` repo
Symphony hasn't cloned yet passes with a warning, as Symphony clones it when it starts:

```bash
./bin/symphony check                       # checks ./symphony.yml
./bin/symphony check --config ./other.yml
```

Watch a running Symphony's terminal dashboard from another terminal. It polls the control API at
`<state-root>/control_url` (or `--url`) with the token in `<state-root>/control_token`, reading the URL
again on every poll so it finds a restarted Symphony on its new port; press `q` or Ctrl-C to quit:

```bash
./bin/symphony dashboard
./bin/symphony dashboard --url http://127.0.0.1:4000
```

Symphony draws the terminal dashboard itself only when its output is a terminal, so a Symphony whose
output goes to a file (as under the menu bar app) logs no dashboard frames.

Run a single issue synchronously, without the poll loop or dashboard:

```bash
./bin/symphony run ACME-123 --timeout 30m --no-retry
```

Work an existing PR:

```bash
./bin/symphony pr 123 --intent "address review comments"
```

Force a ticket, or stop forcing it. `symphony force` adds the `agent.concurrency.force_label` label
(default `expedite`) to the ticket in Linear through the running Symphony's control API
(`POST /api/v1/control/force`, with the token in `<state-root>/control_token` or
`SYMPHONY_CONTROL_TOKEN`), and prints the ticket's place in the forced queue:

```bash
./bin/symphony force TP-123          # TP-123 forced (slot 1 of 1)
./bin/symphony force TP-124          # TP-124 forced (queued #2; TP-123 holds the forced slot)
./bin/symphony force --clear TP-124  # TP-124 no longer forced
```

Forcing never changes a ticket's state: a ticket in `Backlog` stays there
(`TP-125 forced (it is in Backlog; forcing doesn't promote it)`) and joins the queue once it moves to
an active state. An unknown ticket, a missing or rejected control token, an unreachable Symphony and
a Linear error each print a message and exit non-zero.

The terminal and web dashboards list forced tickets in a "Forced" section above the running agents,
with the phase each is in and what it waits on (`implementation · running`,
`waiting for a human`, `implementation · waiting on blocker TP-12`), and mark forced rows elsewhere
with ⚡. Once a forced ticket is done, Symphony removes the label.

Test OpenRouter flows without a real key: `symphony openrouter-stub` serves a stub OpenRouter on
`127.0.0.1` with a made-up valid key and three models, prints its URL and the variables that point a
QA-mode Symphony or app at it, and runs until stopped (see
[OpenRouter in QA](docs/configuration.md#qa-passes)):

```bash
./bin/symphony openrouter-stub --port 4100
```

### Priority vs expedite

A ticket's Linear priority means how important it is. Symphony uses it only to order work that waits
for the same kind of normal slot: after the stage (`Merging`, `Rework`, a resume,
`Todo`) and before age. Raising a ticket to Urgent does not get it a slot any sooner when the slots
are full, and a board full of Urgents stops saying which work matters. To have a ticket worked now,
force it: add the `expedite` label (`agent.concurrency.force_label`) or run `symphony force TP-123`.
Remove the label (`symphony force --clear TP-123`) to stop; it also ends when the ticket is done.
A run already going then finishes as a normal run and gives the forced slot to the next forced ticket.

| Forcing bypasses | Forcing still respects |
| --- | --- |
| `max_total` and the per-state caps (`max_by_issue_state`) | the operator's **Pause** |
| the epic lanes | the Linear rate-limit pause and the workspace quota pause |
| `finishing_max`, and the hold on `Todo` while a finish waits | a Claude or Codex usage-limit pause (the runs would just fail) |
| priority and age ordering (forced tickets go first, oldest forced first) | blocked-by links: a blocked ticket waits for its blocker |
| the daily token budget (with a warning) and a usage-limit headroom hold | the per-issue token cap and the per-host worker cap |
| | a failed setup, retry backoff, and the CI waits before merging |

`agent.concurrency.forced_max` (default `1`) forced runs go at once, on top of the normal slots. A
second forced ticket queues behind the first, shows `queued #2` on the dashboard, and sends one
`forced_waiting` notification. Forcing never stops a running agent. Forcing a plan ticket
forces its sub-tickets one at a time, in blocked-by order. See `concurrency.force_label` in
[docs/configuration.md](docs/configuration.md) for the details.

Forcing only removes the wait for a slot. These transitions stay with a person:

| Transition | Who |
| --- | --- |
| `Backlog` → `Todo` | a person promotes the ticket; forcing doesn't |
| `Plan Review` → `Waiting on sub-tickets` | a person approves a plan |
| a `Needs Decision` hold | a person records the decision |
| any state → `Restart` | a person resets the approach |

The review-agent verdict and the Code Review and QA verdicts are still required: forcing never
skips or changes them.

### Preview the assembled prompt

`symphony workflow preview` renders the exact base-issue prompt the agent would receive for the
repo-local `WORKFLOW.md`, using deterministic sample issue data — no Linear access, network, or
running orchestrator required. When the body is `{% render "playbook" %}`, the preview includes the
instruction files next to that `WORKFLOW.md` (`.symphony/instructions/` by default; see
[playbook](docs/playbook.md#the-whole-playbook-in-one-line)). Use it to confirm your template and
`{% render %}` partials resolve correctly before a real run:

```bash
./bin/symphony workflow preview                       # renders ./WORKFLOW.md
./bin/symphony workflow preview --file path/to/WORKFLOW.md
./bin/symphony workflow preview --agent claude        # default: codex
./bin/symphony workflow preview --repo my-repo        # that repo's settings
```

With `--repo`, the preview renders the prompt with that configured repo's settings.

An unknown `{% render %}` partial or undefined variable is reported as an error, so the command
doubles as a quick workflow lint.

### Operator controls

The dashboard exposes **Pause**, **Resume**, and per-issue **Stop** at `/`. The same controls are
available from the CLI over a loopback HTTP control plane on the dashboard port — no distributed
Erlang setup required:

```bash
mise exec -- mix symphony.pause "deploy window"
mise exec -- mix symphony.resume
mise exec -- mix symphony.stop ACME-123
mise exec -- mix symphony.pr 123 --intent "fix failing CI"
```

`Pause` stops new dispatches while in-flight agents continue; `Stop` ends one issue's session and
records it as `stopped` without changing the Linear issue state.

**Waiting on you.** The Mac app's Inbox (`/api/v1/inbox`), the dashboard's `Waiting on you`
section, `/api/v1/state`'s `waiting_on_you` list and the menu bar app list everything only you can
move on, oldest first: a plan in `Plan Review`, a ticket with an open
`linear_request_human_action` decision (and, with manual review on, a merge to confirm), and a
ticket the quality gate holds or skipped. Each entry shows its kind, its one-line ask (the `**What to
review:**` line of its `## Review brief`) and how long it has waited; the Inbox also shows the brief
in its parts, the PR's checks and size, the request's steps or what the quality gate found. The
menu bar icon shows a dot while the list is not empty, and the app notifies each new entry once.
Symphony reads the list on its poll and serves it from that read, re-reading a ticket's comments only
when the ticket changed, so a new ticket shows after the next poll.

**Initiatives.** The Mac app's Initiatives (`/api/v1/initiatives`) follow each plan ticket (`plan`
or `breakdown`) to done: the active ones, those in review and those done in the last 7 days, each
with its sub-tickets in landing order (blocked-by order, then creation order), what each waits on
(you, a blocker, CI, a slot), counts by stage and its lane in
`epic_lanes`. Symphony reads the plan tickets on its poll and serves them from that read, so a GET
makes no Linear request; the reads show as `initiatives` in the Linear usage table.

You answer from the Inbox too. A plan offers **Approve Plan…** and **Send Decisions** (once a pick
differs from the brief's recommendation), and each **Send to Rework…** with a required reason. An action that asks a decision
offers **Send Decision…**: the option you pick is recorded as a reply under the request and the
ticket continues in its phase, with **Send to Rework…** under ⋯ answering it as a redirect. Every
action opens a sheet that says what happens in Linear before anything changes; the move goes through
Symphony's control API
(`POST /api/v1/control/approve_plan`, `rework`, `restart`, `decisions`, `backlog`, `decide`,
`undo`), which checks the ticket's state, makes the Linear move and writes a
`director_move` audit record. A banner offers **Undo** for 10 seconds after a move. The decisions
comment counts as yours,
so it starts the plan revision run like any comment of yours.

Every ticket row opens the ticket's page: what runs now, a timeline of its runs and of your moves, its
facts and the agent's last message, with **View Transcript** (the run's events, grouped by turn, in their
own window) and **Stop Run…**. Stop Run says what a stop does before it does it, and can also move the
ticket to Backlog with a note; a stop writes a `run_stopped` audit record, so the timeline says "Stopped by
you".

A run that reports an external block leaves its ticket in place with the `Blocked` machine label and
what it waits on recorded. The machine lifts a dependency hold on its own; an access hold is a
person's to lift, and `POST /api/v1/control/unblock` clears it by hand: no Linear state moves and
the ticket continues where it stopped.

A run that needs a person's call asks for it as a decision — one question, 2 to 4 options, one
recommended — and the ticket keeps its phase with the `Needs Decision` machine label: no state
moves, and Symphony dispatches it again the moment the decision is recorded. Answer it in the Inbox
(**Send Decision…**) or with a reply under the request in Linear; either clears the label and the
run continues from where it stopped, and **Send to Rework…** answers it as a redirect that moves the
ticket through the guard.

Away from the Mac, keep the same list as a saved Linear view, **Waiting on me**: in Linear, open
**Views → New view**, filter **Status** is `Plan Review` or **Labels** include `Needs Decision`,
and **Assignee** is `Me`, order it by **Updated**, and save it as `Waiting on me`. It shows on the phone app
too. It does not show the brief headline; open the ticket and read its `## Review brief` comment.

When a run hits the Claude or Codex usage limit, Symphony holds new runs of that agent on its own
and resumes them when the limit resets (plus `agent.usage_limit.resume_margin_seconds`), keeping each held issue's
attempt. One held run goes first; the rest follow only once it is accepted, and the hold starts
again if the limit is still in force. Runs on other providers keep going, and an operator pause is never cleared by it.
A QA run that hits the limit is held the same way: it records no verdict, the issue stays where it
is, and the run goes again after the hold. Set
`agent.usage_limit.auto_pause: false` to fail and retry such runs as before.

While Claude runs are held, the web and terminal dashboards show a banner such as
`Paused: Claude 5-hour limit, resumes ~14:05` (local time, with the date when it isn't today), and
`/api/v1/state` lists each hold under `usage_limits` with its window, reset and resume times, next to
a `usage_limit` entry in `dispatch_state.blockers`. `dispatch_state.active?` turns false only when
every provider in use is held. Slack and webhook channels get one `usage_limit_paused` message when
the hold starts and one `usage_limit_resumed` message when it clears, which is once Claude accepts
the first run, not when it starts.

When Claude or Codex can't reach its API at all (the network or DNS is down, so a Claude turn ends
on `API Error: Can't reach the API server … (ENOTFOUND)` or Codex gives up on
`error sending request … dns error`), Symphony holds that provider's runs the same way,
`auto_pause` or not, instead of reading the turn as finished: no idle turn is counted and no issue
is parked. The pre-push reviewer and QA hold too, so a push never goes ahead
without a review and no verdict is recorded. One held run probes the API after a minute, then after
twice as long each time it still fails (up to `unknown_reset_retry_seconds`). The log says
`Model API unreachable (ENOTFOUND); holding dispatch` once, and the dashboards show
`Paused: Claude API unreachable (ENOTFOUND), retries ~14:05`; `/api/v1/state` lists the hold
under `usage_limits` with `reason: model_api_unreachable`.

To leave part of the Claude limit for your own sessions, set
`agent.usage_limit.headroom_utilization` (for example `0.9`; off by default). Once Claude reports
that share of a window used, Symphony holds new Claude runs until the window resets, while runs in
flight finish and landing runs still start. The dashboards show
`Holding new runs: Claude at 91%, resets ~14:05`. Claude only reports utilization from about 75%,
so a lower setting acts as if set there.

### Docker

The Docker runtime mounts your operator config, repositories, credentials, and agent command into
the service. See [docker/README.md](docker/README.md).

## Writing tickets

Give each ticket a short description of the problem, a scope, and acceptance criteria. A ticket that
changes something a user sees or does (a screen, a menu, a CLI command, a dashboard page) also needs a
`## User walkthrough` section: numbered steps a user takes, each with the result they should see. The
agent copies these steps into its acceptance criteria, and the issue gate scores user-facing tickets
lower when the section is missing. For example, for a fix to the menu bar app's Settings window:

```markdown
## User walkthrough

1. Start the menu bar app. Its icon appears in the menu bar.
2. Click the icon and choose **Settings…** (or press ⌘,). The Settings window opens, and every field
   is visible: checkout folder, `symphony.yml`, command prefix, and `LINEAR_API_KEY`.
3. Leave the window open for a few seconds. It stays the same size and the fields stay visible.
4. Change the command prefix and click **Save**. The window closes; reopen Settings and the new
   prefix is shown.
```

Write each result as something a person can check on screen or in the terminal, not as an
implementation detail. Tickets with no user-facing change can leave the section out.

## Documentation

- [docs/configuration.md](docs/configuration.md) — full config reference for `symphony.yml`,
  `WORKFLOW.md`, CLI flags, and defaults.
- [docs/security.md](docs/security.md) — threat model, built-in protections, and best practices.
- [docs/development.md](docs/development.md) — toolchain, testing, packaging, and fork notes.
- [docs/releasing.md](docs/releasing.md) — how to version and publish a release.
- [docs/github-webhooks.md](docs/github-webhooks.md) — relay GitHub check results to Symphony on
  macOS so CI results land in seconds.
- [macos/README.md](macos/README.md) — the macOS menu bar app: install, first run, controls, update,
  rollback, development mode, and troubleshooting.
- [docs/logging.md](docs/logging.md),
  [docs/quality_gate_security.md](docs/quality_gate_security.md), and
  [docs/token_accounting.md](docs/token_accounting.md) — operational deep-dives.
- [WORKFLOW.md](WORKFLOW.md) — the example in-repo workflow contract and agent prompt.
- [docs/adr/](docs/adr/README.md) — architecture decision records, starting with
  [0001: the Director workflow](docs/adr/0001-director-workflow.md) for ticket types, plan review
  and artifacts.

## About This Fork

This repository is a fork of [Automattic/symphony](https://github.com/Automattic/symphony), which
is itself a fork of OpenAI's [openai/symphony](https://github.com/openai/symphony), introduced in
OpenAI's [open-source Codex orchestration Symphony post](https://openai.com/index/open-source-codex-orchestration-symphony/).
This fork keeps Symphony as the Elixir/OTP service at the repository root and includes local
operational changes. `SPEC.md` is retained as a behavior reference for this service, not as
instructions for building a separate implementation from scratch.

## License

This project is licensed under the [Apache License 2.0](LICENSE).
