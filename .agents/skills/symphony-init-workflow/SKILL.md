---
name: symphony-init-workflow
description: Author a repo-specific WORKFLOW.md for Symphony after `symphony init` has created symphony.yml.
---

# Symphony WORKFLOW.md Init

Use this skill after `symphony init` has created the operator-owned `symphony.yml`.
Your job is to inspect the repository and write a tailored repo-owned `WORKFLOW.md`;
do not generate generic language templates.

## 1. Inspect The Repo

Read only files in the target repository. Prefer these signals:

- `mix.exs`, `package.json`, `Gemfile`, `pyproject.toml`, `go.mod`, `Cargo.toml`
- `Makefile`, `justfile`, `Taskfile.yml`, `bin/*`, `scripts/*`
- `.github/workflows/*`
- existing agent or contributor docs such as `AGENTS.md`, `CLAUDE.md`, or `CONTRIBUTING.md`

Identify the real commands for:

- dependency setup or bootstrap
- targeted or fast local validation for iteration
- tests
- lint/format checks
- the full validation gate that CI runs
- any profiling command that exposes slow tests or checks
- any hook that should run after Symphony creates a fresh workspace

Prefer repository-owned aggregate commands over language defaults. For example,
choose `make all`, `pnpm test:unit`, or `bundle exec rspec` when the repo
declares those commands; do not guess `mix test`, `npm test`, `pytest`,
`go test ./...`, `cargo test`, or `bundle exec rake test` unless repo evidence
points there.

Split the checks by cost, not by kind. Cheap ones (format, compile or type
check, lint, and the tests of the changed code) run locally before every push.
Slow, compute-heavy ones (the full test suite, the global coverage report,
static analysis such as Dialyzer, full builds of every module) run only in CI,
which is the gate. The generated `WORKFLOW.md` should list the cheap checks as
the pre-push step and name the CI gate, rather than asking agents to run the
full gate locally. If a check's cost is unclear, time it once and put it on the
right side of the line.

## 2. Resolve Ambiguity

If multiple plausible commands exist and the repo does not show a clear primary
gate, ask one or two concise clarifying questions before writing `WORKFLOW.md`.
Do not ask questions when the repo has an obvious aggregate command or CI gate.

## 3. Write WORKFLOW.md

Create or update `WORKFLOW.md` with YAML front matter and a prompt body.

The front matter should include only repo-local settings, especially:

- `hooks.after_create` for workspace bootstrap commands when needed
- `validation` or other repo-supported validation keys already accepted by
  Symphony's runtime parser
- repo-specific verification dev-server settings when applicable

Keep operator-wide settings in `symphony.yml`; do not move `tracker`, `repos`,
`workspace.root`, `agent.command`, polling, CI, notification, or quality-gate
operator settings into `WORKFLOW.md`.

The prompt body should tell the agent how to work in this repository:

- respect existing conventions and docs
- use the discovered validation commands before handoff
- explain any repo-specific status, review, or handoff rules

Do not duplicate Symphony's managed runtime context in `WORKFLOW.md`. Symphony
already prepends platform-owned guidance for workspace isolation, untrusted
Linear/GitHub/CI/tool-output handling, scoped tools, workpad usage, obvious
secret paths, and final-response shape.

### Compose from shared playbook blocks instead of re-authoring them

Symphony owns the generic orchestration playbook as Solid partials so the shared
prose lives in one place and stops drifting across repos. The author's job is to
pick which blocks to include and where to place them — not to rewrite the prose.
Start from the default scaffold below, then prune/reorder/replace blocks and fill
in the repo-specific parts marked `<repo: …>`:

```liquid
You are working on a Linear ticket `{{ issue.identifier }}`

{% render "continuation_context", attempt: attempt %}
{% render "issue_context", issue: issue %}

{% render "default_posture" %}
{% render "scoped_tools" %}

## Command and output hygiene
<repo: long-running-command waits, the test/lint/gate commands you discovered>

## Related skills
<repo: which skills this repo ships (linear, commit, push, pull, land, …)>

{% render "status_map" %}

## Step 0: Determine current ticket state and route
<repo: routing skeleton — the order and any repo-specific kickoff steps>

## Step 1: Start/continue execution
<repo: plan/workpad steps. Render "workpad_bootstrap" and
 "reproduce_and_blast_radius" here if you don't author richer inline versions.>

## Step 2: Execution phase
<repo: implement/validate/push/handoff steps and the repo's validation gate>

{% render "pr_feedback_sweep" %}
{% render "ci_triage" %}
{% render "escape_hatches" %}

## Step 3 / Step 4
<repo: in-review polling and rework reset>

{% render "completion_bar" %}
- <repo: extra completion criteria, e.g. coverage gate — appended after the render>

{% render "guardrails" %}
- <repo: extra guardrails, e.g. the lock-file rule — appended after the render>

{% render "out_of_scope_backlog" %}
{% render "dependency_guardrail", lockfile: "<your-lock-file>" %}
{% render "workpad_template", agent: agent %}
```

`{% render %}` uses isolated scope, so pass every variable the partial needs
(`agent`, `lockfile`, …) explicitly. `completion_bar` and `guardrails` are
designed to be *extended*: render the baseline, then add repo-specific bullets on
the lines right after. See [`docs/playbook.md`](../../docs/playbook.md) for the
full catalog (names, variables) and the recommended composition. Author only the
repo-specific structure — step ordering, repo conventions, validation commands —
directly in `WORKFLOW.md`.

## 4. Validate

Before declaring done, validate with the same parser the runtime uses:

```bash
mix run -e 'case SymphonyElixir.Workflow.load("WORKFLOW.md") do {:ok, _} -> :ok; {:error, reason} -> raise inspect(reason) end'
```

`Workflow.load` only parses the front matter; it does not render the body, so it
cannot catch a typo'd `{% render %}` partial name. Confirm the prompt actually
composes by building it once with a stub issue — a bad partial name raises
`template_render_error`:

```bash
mix run -e 'SymphonyElixir.Workflow.set_workflow_file_path(Path.expand("WORKFLOW.md")); SymphonyElixir.PromptBuilder.build_prompt(%SymphonyElixir.Linear.Issue{identifier: "VALIDATE-0", title: "validate", state: "In Progress"}); IO.puts("prompt render ok")'
```

Also run the discovered targeted or fast local validation when it is practical
for the current change. Leave the full gate to CI.

## Manual Check For This Repo

In the Symphony repository, `make all` is CI's full gate: the whole suite, the
100% coverage report and Dialyzer. `make check` runs the whole suite too. A
correct `WORKFLOW.md` for this repo teaches the targeted pre-push checks
(`mix format --check-formatted`, `mix compile --warnings-as-errors`,
`mix specs.check`, `mix credo --strict <changed files>`, and the test files of
the changed code). It names `make all` as CI's gate, and as an optional local
run only for shared-infrastructure changes. It points at the profiling targets
(`make test-profile`, `make coverage-profile`, `make dialyzer-profile`) for
work on slow tests, instead of guessing a generic `mix test` command.
