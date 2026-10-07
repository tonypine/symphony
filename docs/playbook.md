# Playbook partials

Symphony owns the generic orchestration playbook as a set of Solid partials. A
repo `WORKFLOW.md` pulls the blocks it wants into its own structure with the
Solid `{% render %}` tag, so the shared prose lives in one place
(`priv/playbook/*.liquid`) and stops drifting across repos. Repo-specific
structure — status map, step ordering, completion bar, conventions — stays
authored by the repo, either in its `WORKFLOW.md` or, with
[the whole playbook in one line](#the-whole-playbook-in-one-line), in instruction
files an agent may edit.

## How to use

Place a render tag wherever that block belongs in your flow:

```liquid
{% render "pr_feedback_sweep" %}
{% render "workpad_bootstrap", agent: agent %}
{% render "dependency_guardrail", lockfile: "pnpm-lock.yaml" %}
```

`{% render %}` uses **isolated scope**: a partial only sees the variables you pass
to it, not the surrounding template's `issue` / `agent` / `pr`. Pass every
variable listed in the partial's `Vars` column explicitly. Because rendering runs
with `strict_variables`, a missing variable fails the prompt build loudly rather
than rendering blank, and an unknown partial name raises `template_render_error`.

This catalog is a menu, not a checklist: a repo renders only the blocks it wants.
Some partials are intentionally left unrendered by a given repo — for example,
symphony's own `WORKFLOW.md` authors richer, repo-specific versions of
`workpad_bootstrap` and `reproduce_and_blast_radius` inline in its Step 1 (with
coverage-gate and `pull`-evidence detail), so it skips those two renders while
leaner repos still use them. An unrendered partial is available, not dead.

This catalog is kept in sync with `priv/playbook/` by
`test/symphony_elixir/playbook_catalog_test.exs` — edit the partial's
`{% comment %}` header and this table together.

## The whole playbook in one line

A repo can also take every standard partial at once and keep its own instructions out
of `WORKFLOW.md`. Its body is then one line:

```liquid
{% render "playbook" %}
```

Symphony expands that line when it loads the workflow, before Solid parses it. It
becomes the partials below, each on its slot, with the repo's instruction files
between them by number:

| Slot | Partial |
| --- | --- |
| 10 | `continuation_context` |
| 20 | `issue_context` |
| 30 | `default_posture` |
| 40 | `scoped_tools` |
| 50 | `status_map` |
| 52 | `ticket_types` (left-trimmed; nothing for an untyped ticket) |
| 60 | `pr_feedback_sweep` |
| 70 | `ci_triage` |
| 80 | `escape_hatches` |
| 90 | `parent_tickets` |
| 94 | `plan_pipeline` (left-trimmed; only for a plan ticket with an `Artifacts wanted` section) |
| 95 | `review_brief` |
| 100 | `completion_bar` |
| 110 | `guardrails` |
| 120 | `out_of_scope_backlog` |
| 130 | `dependency_guardrail` (only with `playbook.lockfile`) |
| 140 | `workpad_template` |

The instruction files are the `NNN-name.md` files in `.symphony/instructions/`, next to
`WORKFLOW.md`. `NNN` places the file: `041-command-and-output-hygiene.md` comes after
`scoped_tools` (40) and before `status_map` (50), and a file on a partial's own number
comes right after that partial. Other files in the directory, such as a `README.md`,
are left out, and so are symlinks and directories with such a name: an instruction
file must be a regular file. Each file goes in as written, with a blank line between sections, so it
uses the same Liquid variables as a `WORKFLOW.md` body (`{{ issue.identifier }}`,
`{{ agent.workpad_heading }}`) and may render a partial itself. A file must not hold
the `{% render "playbook" %}` line.

The front matter's `playbook` map shapes the rest. It stays in `WORKFLOW.md`, so a
change to it stays a person's call:

```yaml
playbook:
  instructions: .symphony/instructions   # the default; relative to WORKFLOW.md
  lockfile: mix.lock                     # the lock file dependency_guardrail cites
  partials:
    ci_triage: false                     # drop a partial
    status_map: 45                       # move one to another slot
    workpad_bootstrap: 52                # add one the playbook leaves out
```

A partial Symphony adds to this list reaches every repo that uses the line, with no
`WORKFLOW.md` edit. A new partial takes a free slot, so the repo text around it stays
where it was. A repo that keeps its instructions inline in `WORKFLOW.md`, with its own
`{% render %}` lines, renders exactly as before.

Symphony reads the instruction files from the same place as `WORKFLOW.md`: the
fetched base branch, `origin/<base_branch>` (see `workflow_source` in
[configuration](configuration.md)). An agent may edit them, since they are not
write-protected, but its edits reach runs only once their pull request is merged.
The run's own branch and checkout never change its prompt. With `workflow_source: local`
they are read from disk next to `WORKFLOW.md`, and an edit to one reloads the workflow
like an edit to `WORKFLOW.md`. See [security](security.md#workflow-and-instruction-files).

`symphony workflow preview` shows the assembled prompt, instruction files included,
read from the disk next to the `WORKFLOW.md` it renders.

## Available partials

| Partial | Vars | Description |
| --- | --- | --- |
| `ci_triage` | — | Triage protocol for red CI checks at any push gate. |
| `completion_bar` | — | Baseline bar that must be satisfied before moving an issue to In Review; repos append their own criteria after the render. |
| `continuation_context` | `attempt` | Retry-attempt guidance shown when Symphony re-activates an issue that is still in an active state. |
| `default_posture` | — | General operating posture for an unattended issue run: autonomy, status-first routing, single workpad, planning rigor, and when to stop. |
| `dependency_guardrail` | `lockfile` | Justify dependency changes and keep the lock file diff scoped to the current ticket. |
| `escape_hatches` | — | What goes to a person (decisions with options) and what goes to the supervisor (checks an agent can't run), then the blocked-access and in-execution clarification escape hatches. |
| `guardrails` | — | Cross-cutting safety and process guardrails for an issue run; repos append repo-specific guardrails after the render. |
| `issue_context` | `issue` | Standard Linear issue fields, description, recent comments, linked issues, and sub-issues for the agent to act on. |
| `out_of_scope_backlog` | — | Split work and file out-of-scope improvements as Backlog sub-issues of the current issue with linear_create_subissue instead of expanding scope. |
| `parent_tickets` | — | Plan tickets (label plan, or breakdown, its older name) are groomed into sub-tickets; plan (new, resumed, revised, re-planned), final verification, and close-out runs never open a PR. |
| `plan_pipeline` | `issue` | The stages a plan ticket with an Artifacts wanted section produces before its split (domain brief, journeys, Kano map, screens, decisions, implementation plan), one Linear document each, checked against a rubric per stage and handed over in one review; renders nothing for any other ticket. |
| `pr_feedback_sweep` | — | Required sweep of all PR feedback channels; every actionable comment must be resolved or answered before In Review. |
| `reproduce_and_blast_radius` | — | Capture a reproduction/acceptance signal and a blast-radius analysis before the first code edit. |
| `review_brief` | — | One human-facing review brief per ticket, edited in place at every handoff: what to review, what changed, the decisions needed and the move that approves, changes or rejects. |
| `scoped_tools` | — | How to discover and use the scoped linear_* and github_* tools Symphony injects for the current issue. |
| `status_map` | — | Canonical Symphony issue state machine and what each state means for the agent. |
| `ticket_types` | `issue` | Per-type steps for a ticket labelled type:bug, type:feature or plan, with a readiness check that sends a bug or feature missing a required section back to Backlog; renders nothing for an untyped ticket. |
| `workpad_bootstrap` | `agent` | Find, reuse, or create the single persistent Linear workpad comment and reconcile it before new work. |
| `workpad_template` | `agent` | Canonical structure for the persistent workpad comment. |

The plan flow in `parent_tickets` (plan run, single plan review, approval
through `Waiting on sub-tickets`, close-out) is the base of the Director workflow:
[ADR 0001](adr/0001-director-workflow.md) records the ticket types, the plan stages
and where a plan's artifacts live.

`parent_tickets`, `escape_hatches`, `completion_bar` and `default_posture` ask for the
review brief at their handoffs, so render `review_brief` in any workflow that renders
them; `{% render "playbook" %}` already does. The brief is the one comment written for
the person reviewing; the workpad stays the agent's log.

`plan_pipeline` adds the plan stages to `parent_tickets` for a plan ticket written from the
Plan template: a domain brief, user journeys, a Kano feature map, screens (a Linear document plus
one self-contained HTML file) and decisions, each produced only when the ticket checks it under
`Artifacts wanted`, then the implementation plan. It loads the
[house standards](standards/house-standards.md), checks each artifact against a rubric and hands
everything over in one review. [`ticket-templates/examples/plan.md`](ticket-templates/examples/plan.md)
shows a filled plan ticket and what the run produces. It renders nothing for any other ticket,
including a plan ticket with no `Artifacts wanted` section, which keeps today's plain split; render
it with a left-trimming tag right after `parent_tickets`:

```liquid
{%- render "plan_pipeline", issue: issue %}
```

`ticket_types` routes a ticket by its type label (`type:bug`, `type:feature` or `plan`) and runs
the readiness check on bugs and features. The templates the operator writes those tickets from,
and the steps to create them in Linear, are in [`ticket-templates/`](ticket-templates/README.md).
It renders nothing for a ticket with no type label; render it with a left-trimming tag right after
your Step 0 routing, so an untyped ticket's prompt stays byte-identical. `{% render "playbook" %}`
already does, on slot 52: number your Step 0 file 51 or lower and your Step 1 file 52 or higher:

```liquid
{%- render "ticket_types", issue: issue %}
```

## Recommended composition

A repo `WORKFLOW.md` owns the *structure* — the status routing, the numbered
steps, and their ordering — and pulls the shared *prose* blocks in around that
skeleton. A sensible default order, with the repo-authored parts called out:

```liquid
You are working on a Linear ticket `{{ issue.identifier }}`

{% render "continuation_context", attempt: attempt %}
{% render "issue_context", issue: issue %}

{% render "default_posture" %}
{% render "scoped_tools" %}

<!-- repo-authored: command/output hygiene, available skills -->

{% render "status_map" %}

## Step 0   <!-- repo-authored routing -->
{%- render "ticket_types", issue: issue %}

## Step 1 … Step 4   <!-- repo-authored execution skeleton -->
{% render "pr_feedback_sweep" %}
{% render "ci_triage" %}
{% render "escape_hatches" %}

{% render "completion_bar" %}
<!-- repo-authored: extra completion criteria, e.g. coverage gate -->

{% render "guardrails" %}
<!-- repo-authored: extra guardrails, e.g. lock-file rule -->

{% render "parent_tickets" %}
{%- render "plan_pipeline", issue: issue %}
{% render "review_brief" %}
{% render "out_of_scope_backlog" %}
{% render "dependency_guardrail", lockfile: "<your-lock-file>" %}
{% render "workpad_template", agent: agent %}
```

Leaner repos can also render `workpad_bootstrap` and `reproduce_and_blast_radius`
instead of authoring those steps inline; repos with richer, repo-specific Step 1
detail (pull/sync evidence, coverage planning) keep them inline and interleave the
repo-specific prose.

## Extending a block

Solid partials have no inheritance, so you *extend* a block by rendering it and
appending your own lines immediately after — the partial emits a clean baseline
list, and the repo adds repo-specific bullets below it:

```liquid
{% render "completion_bar" %}
- Coverage is at the repo threshold and the coverage CI job is green.
```

`completion_bar` and `guardrails` are designed for this render-then-append
pattern.

## Keep repo-authored routing in sync with `status_map`

`status_map` is the canonical state machine, but a repo's `WORKFLOW.md` authors its
own Step 0 routing table and execution steps around it. The two can drift: a fork
that hand-edits its routing table can silently omit a state (`Rework`, `Merging`)
that `status_map` still lists, leaving the agent with no route when it lands on
that state. When you author routing in a repo `WORKFLOW.md`:

- cover every state `status_map` renders, or state explicitly which ones the repo
  doesn't use and why;
- prefer "route per the Status map above" over restating each state's meaning, so
  the canonical text lives in one place;
- when repo prose names a protocol — e.g. "run the PR feedback sweep" — render the
  matching partial (`pr_feedback_sweep`) in the same workflow. `strict_variables`
  fails the build on an unknown *render*, but it cannot catch a prose reference to
  a block you forgot to render, so those dangling references slip through silently.
