# Acceptance gate

The acceptance gate is a step in Auto Review, after QA. It decides whether a PR can merge without
a human. A gate agent reads the ticket and the PR. Before the agent's verdict counts, fixed
escalation rules check the ticket and the diff, and any rule that triggers sends the PR to a human.

Auto Review runs CI, then QA, then the gate. The gate runs in `shadow` mode: it records an
advisory verdict and the issue moves to In Review as before. `enforce` doesn't apply verdicts
yet and behaves like `shadow`.

## How a gate pass runs

With `mode` other than `off`, a QA `pass`, `skip` or `blocked` doesn't move the issue to In Review
straight away. Auto Review asks `SymphonyElixir.AcceptanceGate.Runner` for a gate pass on the PR
head, and the issue moves on once the gate has a verdict for that SHA. A QA `fail` goes back to
In Progress as before and never reaches the gate.

- **The runner.** Like the QA runner, it runs passes in the background, one per issue and at most
  `max_concurrent` at once. A forced ticket goes first. While the gate agent's provider is held by
  a usage limit, nothing starts; the next green CI poll asks again.
- **The pass** (`AcceptanceGate.run/3`) builds the context (below), checks the escalation rules,
  then runs the gate agent in a throwaway worktree at the merge result. The session is read-only:
  the read-only Linear and GitHub tools only, a read-only Codex sandbox, and for Claude no
  file-editing tool and no shell write in its working directory. Pushing and the `gh` CLI stay
  denied. A merge conflict with current main skips the agent.
- **What the agent judges**, in this order: each acceptance criterion (the checklist items under
  the ticket's `Acceptance` or `Acceptance Criteria` headings, then the workpad's
  `### Acceptance Criteria`) as `met`, `unmet` or `unclear` with `file:line` evidence; conflicts and
  overlaps with the other open PRs; scope (anything the ticket asks for that is missing, and any
  unrelated change); and judgment calls for a human (a product or UX decision, ambiguous criteria).
  It doesn't review code style or bugs, which the pre-push reviewer covers, unless a bug makes a
  criterion unmet. It answers with JSON: `verdict` (`approve`, `rework` or `escalate`),
  `criteria[]`, `overlaps[]`, `scope[]`, `escalation_reasons[]` and `follow_ups[]` (gaps outside
  the ticket). An answer without a readable JSON object gets one follow-up turn.
- **The final verdict.** Any escalation rule that triggers forces `escalate`, and the agent's own
  verdict is kept as `agent_verdict`. A QA `blocked` adds the reason `qa_blocked`. A PR that
  conflicts with current main is `rework` (reason `conflict`). An inconclusive pass (an unreadable
  answer, an agent or context error) records no verdict, and the next green poll runs the gate
  again. The `escalate.inconclusive_limit`-th inconclusive pass on the same SHA escalates with the
  reason `inconclusive`.
- **Storage.** The verdict is stored per head SHA on the issue's CI check record: `gate_sha`,
  `gate_verdict`, `gate_agent_verdict`, `gate_reasons`, `gate_run_id` (and `gate_mode`,
  `gate_inconclusive`). The run is stored with `kind: "acceptance_gate"` and its tokens. A green
  poll on a SHA that already has a verdict applies it again and starts no new run.
- **Visibility.** Each pass rewrites one `## Symphony Acceptance Gate` comment on the Linear issue,
  as the QA report is rewritten. It shows the mode (advisory in `shadow`), the verdict, the agent's
  verdict, a table with one row per acceptance criterion (criterion, result, evidence), the
  overlaps, the scope findings, the escalation reasons, the proposed follow-ups (listed, not
  filed), the tokens and the runtime.
- **Audit log.** Each verdict writes one `acceptance_gate_verdict` event with the issue, the SHA,
  the mode, the verdict, the agent's verdict, the reasons, the run id and the tokens.

## Where it is configured

The gate is configured in `symphony.yml`, the operator config: a global
`auto_review.acceptance_gate` block, and a `repositories[].acceptance_gate` override per repository.
A repository's `WORKFLOW.md` can't set it. Its only allowed `auto_review` key is `playbooks`, and
anything else fails that workflow. A PR can't change the rules that gate it.

## The block

Every key is optional. These are the defaults:

```yaml
auto_review:
  acceptance_gate:
    mode: off              # off | shadow | enforce (the kill switch)
    # runtime: claude      # codex | claude
    # command: claude --dangerously-skip-permissions
    # model: claude-opus-5-5   # else agent.run_profiles.acceptance_gate, then agent.model
    # effort: high             # else agent.run_profiles.acceptance_gate, then agent.effort
    max_turns: 12
    timeout_ms: 900000
    max_concurrent: 2
    escalate:
      labels: [needs-human, breakdown]
      ticket_patterns:
        - '(?i)\b(human|manual(ly)?)\s+review'
        - '(?i)must not (auto-?approve|auto-?merge)'
        - '(?i)\bneeds?[- ]human\b'
      paths: []            # added to the built-in paths below
      diff_patterns:
        - '(?i)\bdrop\s+(table|column|index)\b'
        - '(?i)\btruncate\s+table\b'
        - '(?i)\bdelete\s+from\b'
        - '\brm\s+-rf\b'
      dependencies: major  # off | major | any
      max_changed_lines: 1500
      busy_files: { top: 10, window_days: 14, max_lines: 300 }
      inconclusive_limit: 2
```

Quote regular expressions with single quotes in YAML, so a backslash stays a backslash.

| Key | Default | Meaning |
| --- | --- | --- |
| `mode` | `off` | The kill switch. `off`: the gate doesn't run. `shadow`: the gate runs and records its verdict, and the PR goes to a human as usual. `enforce`: the gate's verdict counts (not applied yet: it behaves like `shadow`). |
| `runtime` | `null` | The gate agent's runtime, `codex` or `claude`. The key is `runtime`, as in `auto_review.runtime`. `kind` is rejected, and the error points at `runtime`. |
| `command` | `null` | The gate agent's command. |
| `model` | `null` | The gate agent's model. Unset, it falls back to the `acceptance_gate` run profile: `repositories[].agent.run_profiles.acceptance_gate`, `repositories[].agent.model`, `agent.run_profiles.acceptance_gate`, then `agent.model` (`Config.acceptance_gate_profile/1`). |
| `effort` | `null` | `low`, `medium`, `high`, `xhigh` or `max`. Falls back like `model`. |
| `max_turns` | `12` | Turns the gate agent gets. |
| `timeout_ms` | `900000` (15 minutes) | How long a gate run may take. |
| `max_concurrent` | `2` | Gate runs at once, across all repositories. |
| `escalate.labels` | `needs-human`, `breakdown` | An issue with one of these labels escalates. Matching ignores case and surrounding spaces. |
| `escalate.ticket_patterns` | the three above | Regular expressions matched against the issue title and description. |
| `escalate.paths` | the built-in paths below | Globs matched against each changed path outside docs and tests. `**` spans directories, `*` and `?` don't. |
| `escalate.diff_patterns` | the four above | Regular expressions matched against each added line of the diff, in every file. Removed lines don't count. |
| `escalate.dependencies` | `major` | `off`: dependency changes don't escalate. `major`: a new dependency or a major version change in `mix.lock` or `package.json` escalates. `any`: any added, changed or removed dependency escalates. |
| `escalate.max_changed_lines` | `1500` | More changed lines (added plus deleted) outside docs and tests escalates. |
| `escalate.busy_files.top` | `10` | How many of the files changed most often on the default branch count as busy. |
| `escalate.busy_files.window_days` | `14` | How many days of the default branch's history pick the busy files. |
| `escalate.busy_files.max_lines` | `300` | More changed lines than this in one busy file escalates. |
| `escalate.inconclusive_limit` | `2` | How many inconclusive gate verdicts a PR gets before it goes to a human. |

An unknown key, a `mode`, `runtime`, `effort` or `dependencies` value that isn't listed, a number
that isn't positive, or a regular expression that doesn't compile fails `symphony check`. The error
names the key, for example
`auto_review.acceptance_gate.mode must be one of: off, shadow, enforce`.

### Built-in paths

Every repository gets these path rules:

- `**/*auth*/**`, `**/*auth*`, `**/*token*`, `**/*secret*`, `**/*credential*`,
  `**/*permission*`, `**/*sandbox*`, `**/*.entitlements`;
- `**/migrations/**`, `**/*migration*`;
- `.github/workflows/**`, `.github/CODEOWNERS`.

Path rules and the size limit skip docs and tests. These are the same globs that let QA skip a
docs- or tests-only diff: `**/*.md`, `**/*.mdx`, `**/*.rst`, `**/*.txt`, `docs/**`, `**/LICENSE*`,
`test/**`, `**/test/**`, `tests/**`, `**/tests/**`, `spec/**`, `**/__tests__/**`, `**/*_test.exs`,
`**/*_test.go`, `**/*.test.*`, `**/*.spec.*` and `macos/Tests/**`.

## Overrides add rules, they don't remove them

The built-in `labels`, `ticket_patterns`, `paths` and `diff_patterns` always apply. A list you
configure adds to them, and there's no way to remove a built-in entry: `paths: []` still has
every built-in path.

`repositories[].acceptance_gate` can set `mode`, `max_turns`, `timeout_ms` and `escalate`. For
issues routed to that repository:

- its `mode` and numbers (`max_turns`, `timeout_ms`, `escalate.dependencies`,
  `escalate.max_changed_lines`, `escalate.busy_files.*`, `escalate.inconclusive_limit`) replace
  the global ones;
- its lists add to the built-in and global lists.

A repository can add rules but can't remove a built-in one. The gate agent's `runtime`, `command`,
`model`, `effort` and `max_concurrent` are global. Set a model per repository under
`repositories[].agent.run_profiles.acceptance_gate`. Errors in an override name the repository,
for example `repositories[symphony].acceptance_gate.mode must be one of: off, shadow, enforce`.

## What escalates

`Escalation.check(issue, diff_summary, busy_files, rules)` returns one reason per rule that
triggers, as `%{rule: atom, detail: String.t()}`, or `[]` when nothing does. The rules are
checked in this order:

| `rule` | Triggers when |
| --- | --- |
| `:label` | the issue has an `escalate.labels` label. |
| `:ticket_pattern` | the issue title or description matches an `escalate.ticket_patterns` regex. |
| `:path` | a changed path outside docs and tests matches an `escalate.paths` glob. |
| `:diff_pattern` | an added line matches an `escalate.diff_patterns` regex. |
| `:dependency` | `mix.lock` or a `package.json` adds a dependency or changes a major version (`major`), or changes any dependency (`any`). A manifest that can't be parsed also escalates. |
| `:size` | more than `escalate.max_changed_lines` lines change outside docs and tests. |
| `:busy_file` | more than `escalate.busy_files.max_lines` lines change in one busy file. |

A version's major is its first number. When that number is `0`, the first two numbers count,
so `0.4.0` to `0.5.0` is a major change. Only a leading version is read, after any `^`, `~`,
`>`, `=`, `<` or `v`: a value that doesn't start with one (`latest`, a git ref such as
`git:3f2a…`, a URL, a `file:` path) counts as a major change whenever it changes. `mix.lock` is read with
`DependencyAudit.MixParser.parse_lock/1` and `package.json` with `DependencyAudit.NpmParser`
(`dependencies` and `devDependencies`).

## What the gate agent reads

`Context.build(issue, record, sha, settings, opts)` prepares the gate agent's input, so the agent
doesn't spend turns collecting it. `record` is the issue's CI check record and `sha` the PR head.
Its `diff_summary` feeds the escalation rules: each changed file's numstat and added lines, read
from the whole diff before it is cut, and the content of a changed `mix.lock` or `package.json` on
the base tip and in the merge result.

- **The PR merged onto current main.** Symphony fetches the base branch (`repositories[].base_branch`,
  else `main`) from `origin` once per build, checks it out in a throwaway worktree under
  `<workspace.root>/.acceptance-gate/<repo>/`, and merges the PR head into it without committing.
  A conflict returns `{:conflict, files}` and the gate doesn't run. Otherwise the merge result is
  kept as a commit (`merged_sha`) that no branch points to, and the diff is the merge result against
  the base tip, not against the merge-base. The diff is cut at 120 KB, like the reviewer's; the
  per-file numstat is always whole. The worktree is removed after the build, also on error.
- **Busy files.** The `escalate.busy_files.top` paths with the most commits on the base branch over
  the last `escalate.busy_files.window_days` days, most commits first. The `:busy_file` rule uses them.
- **Overlap with other open PRs.** The open PRs Symphony tracks come from its CI check and PR review
  records, for issues in Auto Review, In Review and Merging. Their changed files and hunks are read
  from the local object database, which worktree workspaces share; a head missing locally is
  fetched. The open PRs Symphony doesn't track, such as a human's, come from one GitHub GraphQL
  query per build (the 100 most recently updated, with their first 100 paths), cached by the base
  tip and the PR head, so a build on the same heads doesn't ask again. Each overlap is
  `%{pr_url, issue_identifier, files, functions}`: the files both PRs change, and the functions
  both change, named from git's hunk headers. `*.ex` and `*.exs` use git's built-in `elixir` diff
  driver and other files git's default heuristic. An untracked PR gives only its paths, so its
  `functions` list is always empty.

## Example blocks

### symphony

The gate can't approve changes to itself, to the agent sandbox and safety code, or to the code
that receives outside input:

```yaml
repositories:
  - key: symphony
    acceptance_gate:
      mode: shadow
      escalate:
        paths:
          # the gate, Auto Review, auto-merge and the pre-push reviewer
          - lib/symphony_elixir/auto_review.ex
          - lib/symphony_elixir/auto_review/**
          - lib/symphony_elixir/acceptance_gate.ex
          - lib/symphony_elixir/acceptance_gate/**
          - lib/symphony_elixir/auto_merge.ex
          - lib/symphony_elixir/review_agent.ex
          - lib/symphony_elixir/review_agent/**
          # sandbox and safety
          - lib/symphony_elixir/agent_sandbox_config.ex
          - lib/symphony_elixir/path_safety.ex
          - lib/symphony_elixir/prompt_safety.ex
          - lib/symphony_elixir/sensitive_path.ex
          - lib/symphony_elixir/secret.ex
          # agent tools and inbound requests
          - lib/symphony_elixir/agent_tools/**
          - lib/symphony_elixir/agent_mcp.ex
          - lib/symphony_elixir/github/webhook.ex
          - lib/symphony_elixir_web/plugs/**
```

The gate's built-in defaults live in `lib/symphony_elixir/acceptance_gate/settings.ex`, so these
paths cover them too.

### cycle (macOS app)

There's no Swift lockfile parser yet, so a `Package.resolved` change escalates as a path:

```yaml
repositories:
  - key: cycle
    acceptance_gate:
      escalate:
        paths:
          - '**/Info.plist'
          - '**/*Keychain*'
          - '**/Package.resolved'
```

### job-search-hub (web app)

```yaml
repositories:
  - key: job-search-hub
    acceptance_gate:
      escalate:
        paths:
          - '**/middleware*'
          - '**/api/auth/**'
          - '**/prisma/migrations/**'
          - '**/supabase/migrations/**'
          - '**/*.sql'
```

Check the cycle and job-search-hub paths against each repository's layout before you turn the
gate on for it.
