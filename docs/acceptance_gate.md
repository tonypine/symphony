# The retired acceptance gate and its escalation rules

The acceptance gate is retired (`docs/design/state-machine.md` §Retired). It ran after the
retired `Auto Review` QA pass, judged each PR against its ticket with its own agent, and approved,
reworked or escalated it. Its duties now live in the ticket state machine: the `Code Review` run
judges the PR against the ticket's acceptance criteria, scope and intent; the `QA` state tests it
from the user's point of view; and its deterministic **escalation rules** were migrated per
decision D12 of the state-machine plan:

| Rule | Home |
| --- | --- |
| `labels` (an escalation label other than `plan` / `breakdown`) | person rule: an approved Code Review pauses on a **Needs Decision** hold recommending QA |
| `ticket_patterns` | person rule: the same Needs Decision hold |
| `paths` | risk rule: deepens the Code Review (a second reviewer pass on the same head, recorded with no move; the next dispatch performs its verdict) |
| `diff_patterns` | risk rule: deepens the Code Review |
| `dependencies` | risk rule: deepens the Code Review |
| `max_changed_lines` | risk rule: deepens the Code Review |
| `busy_files` | risk rule: deepens the Code Review |
| `inconclusive_limit` | dropped: Code Review retries an inconclusive review twice on the same head, then asks a person |
| the `settings_ui` rule | dropped: CI's `mix settings.ui_coverage` already fails a new setting without a control or an exemption |
| the gate agent's own `escalate` verdict | the Code Review reviewer's `block`: a Needs Decision hold recommending `Rework` |
| `human_action` (an issue waiting on a person) | dropped: an open decision is already a Needs Decision hold, which keeps the ticket from dispatching |

A Needs Decision hold never moves the ticket: it stays in `Code Review` until a person decides.
Confirming continues into the QA state; Send to Rework moves it to `Rework`.

## The deprecated block

`auto_review.acceptance_gate` and `repositories[].acceptance_gate` still load during the
deprecation window, each key with one warning per loaded config:

- `escalate` is still read, by Code Review, until the block is removed and the rules move with it;
- `mode` only derives a repo's `manual_review` when that is unset (`shadow` → `on`; `off`,
  `enforce` and `decide` → `off`);
- `runtime`, `command`, `model`, `effort`, `max_turns`, `timeout_ms`, `max_concurrent`,
  `escalate.inconclusive_limit` and `agent.run_profiles.acceptance_gate` do nothing.

```yaml
auto_review:
  acceptance_gate:
    escalate:
      labels: [needs-human, plan, breakdown]
      ticket_patterns:
        # a ticket that asks for a person's review, not one that names the state
        - '(?i)\b(requires?|needs?|wants?|asks?\s+for|asking\s+for|requests?|gets?|getting|send\s+(it|this)\s+for|after)\s+(an?\s+)?(human|manual)\s+review\b'
        - '(?i)\b(human|manual)\s+review\s+(is\s+)?(required|needed)\b'
        - '(?i)\b(must|should|has\s+to|needs?\s+to)\s+be\s+(manually\s+reviewed|reviewed\s+by\s+an?\s+(human|person))\b'
        - '(?i)\b(please\s+manually|(want|need)s?\s+to\s+manually|have\s+an?\s+(human|person)|an?\s+(human|person)\s+(must|should|needs?\s+to))\s+review\b'
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
```

Quote regular expressions with single quotes in YAML, so a backslash stays a backslash.

| Key | Default | Meaning |
| --- | --- | --- |
| `escalate.labels` | `needs-human`, `plan`, `breakdown` | An issue with one of these labels needs a person. Matching ignores case and surrounding spaces. |
| `escalate.ticket_patterns` | the six above | Regular expressions matched against the issue title and description, after code and the review states' names are blanked (see [What escalates](#what-escalates)). |
| `escalate.paths` | the built-in paths below | Globs matched against each changed path outside docs and tests. `**` spans directories, `*` and `?` don't. |
| `escalate.diff_patterns` | the four above | Regular expressions matched against each added line of the diff, in every file. Removed lines don't count. |
| `escalate.dependencies` | `major` | `off`: dependency changes don't count. `major`: a new dependency or a major version change in `mix.lock` or `package.json` counts. `any`: any added, changed or removed dependency counts. |
| `escalate.max_changed_lines` | `1500` | More changed lines (added plus deleted) outside docs and tests counts. |
| `escalate.busy_files.top` | `10` | How many of the files changed most often on the base branch count as busy. |
| `escalate.busy_files.window_days` | `14` | How many days of the base branch's history pick the busy files. |
| `escalate.busy_files.max_lines` | `300` | More changed lines than this in one busy file counts. |

The built-in `labels`, `ticket_patterns`, `paths` and `diff_patterns` always apply. A list you
configure adds to them, and a `repositories[].acceptance_gate.escalate` override adds to the
global lists and replaces its numbers for that repository. A run on an SSH worker reads no
dependency manifests and no busy files, since both come from git in the local workspace.

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

## What escalates

`EscalationRules.check(issue, diff_summary, busy_files, rules, opts)` returns one reason per rule
that triggers, as `%{rule: atom, detail: String.t()}`, or `[]` when nothing does.
`EscalationRules.person_rules/0` and `risk_rules/0` split them. The rules are checked in this
order:

| `rule` | Kind | Triggers when |
| --- | --- | --- |
| `:label` | person | the issue has an `escalate.labels` label. |
| `:ticket_pattern` | person | the issue title or description matches an `escalate.ticket_patterns` regex. |
| `:path` | risk | a changed path outside docs and tests matches an `escalate.paths` glob. |
| `:diff_pattern` | risk | an added line matches an `escalate.diff_patterns` regex. |
| `:dependency` | risk | `mix.lock` or a `package.json` adds a dependency or changes a major version (`major`), or changes any dependency (`any`). A manifest that can't be parsed also counts. |
| `:size` | risk | more than `escalate.max_changed_lines` lines change outside docs and tests. |
| `:busy_file` | risk | more than `escalate.busy_files.max_lines` lines change in one busy file. |

A ticket that asks for a person's review escalates; one that only names a review state, or
discusses manual review as a topic, doesn't. The built-in `ticket_patterns` match request
phrasing only ("needs a human review", "human review required", "must be manually reviewed",
"have a human review this", "must not auto-approve"), not "human review" on its own. Before
`ticket_patterns` match, the rule blanks fenced code blocks and backticked spans, then the retired
`In Review` and `Human Review` states' names wherever the text names them: bare, in bold or in
quotes. The names match case-sensitively, so "Merge it after a human review" still escalates;
before `state` or `states` they match in any case ("the human review state"). A name right after
`need`, `require` or `want` ("Needs Human Review") stays, since it asks for one. The Symphony
summary block at the end of a description is never read.

A version's major is its first number. When that number is `0`, the first two numbers count,
so `0.4.0` to `0.5.0` is a major change. Only a leading version is read, after any `^`, `~`,
`>`, `=`, `<` or `v`: a value that doesn't start with one (`latest`, a git ref such as
`git:3f2a…`, a URL, a `file:` path) counts as a major change whenever it changes. `mix.lock` is read with
`DependencyAudit.MixParser.parse_lock/1` and `package.json` with `DependencyAudit.NpmParser`
(`dependencies` and `devDependencies`).

