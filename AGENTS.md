# Symphony

This repository contains the Elixir agent orchestration service that polls Linear, creates per-issue workspaces, and runs Codex in app-server mode.

## Environment

- Elixir: `1.19.x` (OTP 28) via `mise`.
- Install deps: `mix setup`.
- Local pre-push checks: format, compile with warnings as errors, lint, targeted tests, and
  the coverage of the changed modules (see below).
- CI gate: `make all` (format check, lint, full test suite with 100% coverage, Dialyzer).


## Codebase-Specific Conventions

- Runtime config is loaded from `WORKFLOW.md` front matter via `SymphonyElixir.Workflow` and `SymphonyElixir.Config`.
- Keep the implementation aligned with [`SPEC.md`](SPEC.md) where practical.
  - The implementation may be a superset of the spec.
  - The implementation must not conflict with the spec.
  - If implementation changes meaningfully alter the intended behavior, update the spec in the same
    change where practical so the spec stays current.
- Prefer adding config access through `SymphonyElixir.Config` instead of ad-hoc env reads.
- Workspace safety is critical:
  - Never run Codex turn cwd in source repo.
  - Workspaces must stay under configured workspace root.
- Orchestrator behavior is stateful and concurrency-sensitive; preserve retry, reconciliation, and cleanup semantics.
- Follow `docs/logging.md` for logging conventions and required issue/session context fields.

## Tests and Validation

Split checks by cost. Cheap checks run locally before every push; the full test suite, the
coverage report and Dialyzer run in CI, which is the gate.

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix specs.check
mix credo --strict <changed files>
mix test <new or changed test files, and the test files of changed modules>
mix cover.changed
```

CI fails a push when any module is below 100% line coverage, so check the modules you changed
before pushing: `mix cover.changed` runs the tests for the `lib/` modules changed since
`origin/main` once with `--cover` and fails, naming the uncovered lines, when one of them is below
100%. It skips `mix.exs`'s `ignore_modules`, as CI does. It picks the changed test files, the
`test/<path>_test.exs` of each changed `lib/<path>.ex` and the test files that name a changed
module; when the tests that cover a module don't name it, pass them:
`mix cover.changed <test files>`. It cover-compiles every module, so it takes a few seconds more
than the same `mix test`.

Do not run `make all`, `make check`, `make coverage`, the full `mix test`, `mix test --stale` (it
runs the whole suite in a fresh workspace) or Dialyzer locally;
`make all` is an optional extra for changes to shared infrastructure (config schema, orchestrator
core). A coverage gap CI reports is fixed like any other red check.

To profile slow validation work before optimizing tests, use:

```bash
make test-profile
make coverage-profile
make dialyzer-profile
```

## Required Rules

- Public functions (`def`) in `lib/` must have an adjacent `@spec`.
- `defp` specs are optional.
- `@impl` callback implementations are exempt from local `@spec` requirement.
- Keep changes narrowly scoped; avoid unrelated refactors.
- Follow existing module/style patterns in `lib/symphony_elixir/*`.

Validation command:

```bash
mix specs.check
```

## PR Requirements

- PR body must follow `.github/pull_request_template.md`. There is no test plan
  section; validation evidence lives in the Linear workpad.
- `## References` (required, bullets): only links that exist: Ticket, design
  decision thread, design review, Loom. Drop a line rather than write "n/a".
- `## This PR` (required): short, behaviour in plain words. Open with
  `Nothing changes on screen.` when nothing user-visible changes. Use a list only
  when the PR adds more than one distinct piece.
- `### Important facts` (optional subsection of `## This PR`, bullets) is a closed
  list. Use it only for: a new feature flag and its default; another flag or
  setting that must also be on; a migration or backfill; a new dependency; a new
  environment variable. Risks, caveats, design rationale and follow-ups do not go
  there.
- `## Stack` (optional): what all the parts of a stack deliver together, written
  once and repeated verbatim on every PR in the stack. Omit it when the PR stands
  alone. It is not a list of PRs; don't describe or number the parts.
- Validate PR body locally when needed:

```bash
mix pr_body.check --file /path/to/pr_body.md
```

## Docs Update Policy

If behavior/config changes, update docs in the same PR:

- `README.md` for project concept, goals, and run instructions.
- `WORKFLOW.md` for workflow/config contract changes.
