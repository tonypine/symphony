---
# Tip: run `symphony workflow preview` to see the fully assembled prompt — managed
# context, expanded `{% render %}` partials, and sample issue values — exactly as the
# agent receives it. This comment lives in front matter so it never renders.
hooks:
  after_create: |
    # Runs .githooks/pre-push on every push. The setting lands in the shared repo config,
    # and the relative path resolves in each worktree.
    git config core.hooksPath .githooks
    if command -v mise >/dev/null 2>&1; then
      mise trust && mise exec -- mix deps.get
    fi
  before_remove: |
    mise exec -- mix workspace.before_remove
# Used only when the operator sets `verification.enabled: true` in symphony.yml. Serves the
# dashboard with an in-memory tracker; Auto Review's web playbook tests dashboard changes on it.
verification:
  dev_server:
    start_cmd: scripts/qa-dashboard-server.sh
    health_check_url: "http://127.0.0.1:${SYMPHONY_VERIFICATION_PORT}/api/v1/state"
    health_timeout_ms: 600000
prompts:
  pr: |
    You are working on an existing GitHub pull request.

    PR: {{ pr.url }}
    Number: {{ pr.number }}
    Title: {{ pr.title }}
    Base: {{ pr.base_ref }}
    Head: {{ pr.head_ref }}
    Intent: {{ pr.intent }}

    Description:
    <github_pr_body>
    {{ pr.body }}
    </github_pr_body>

    Follow the managed Symphony PR runtime context, complete the requested PR
    intent in this repository, and validate before handoff.
---

You are working on a Linear ticket `{{ issue.identifier }}`

{% render "continuation_context", attempt: attempt %}

{% render "issue_context", issue: issue %}

{% render "default_posture" %}

{% render "scoped_tools" %}

## Command and output hygiene

- For long-running commands (dependency installs, an optional `make all`), use
  longer tool waits such as `yield_time_ms: 30000` to `60000`. Avoid tight
  `write_stdin` polling; if a command is still running, wait at least 30
  seconds before polling again unless there is a specific reason to expect
  immediate failure output.
- Split checks by cost, not by kind. CI is the gate: it runs the full test
  suite, the 100% coverage report and Dialyzer on every push.
  - Cheap checks run locally, in any phase: `mix format --check-formatted`,
    `mix compile --warnings-as-errors`, `mix specs.check`,
    `mix credo --strict <changed files>`, and the test files you added or
    changed plus the test files of the modules you changed (`mix test <file>`
    or `<file>:<line>`).
  - Slow, compute-heavy checks never run locally: the full `mix test`,
    `make check` and `make test` (both run the whole suite), `mix test --stale`
    (a workspace has no stale manifest on its first run, so it runs all 2,400+
    tests, about 2.5 minutes timed on 2026-10-04), `make coverage`
    (coverage instrumentation recompiles every module and roughly doubles CPU
    and wall time), and Dialyzer. They are several times slower in the
    sandbox than in CI, CI runs them again anyway, and several agents running
    them at once overload the shared host.
  - `make all` stays available as an optional extra for a change to shared
    infrastructure (the config schema, orchestrator core) when you judge a
    full local run worth it. Run it with `TEST_MAX_CASES=2 BEAM_SCHEDULERS=2`
    and record why in the workpad.
  - When a check's cost is unclear, time it once and add it to the right list
    here.
  - Use `make test-profile`, `make coverage-profile`, or `make dialyzer-profile`
    only when a ticket asks you to optimize slow tests or gate behavior.
- In sandboxed Elixir runs, `mix` commands need no Hex install or env
  overrides. Symphony passes the host's `MIX_HOME`,
  `MIX_ARCHIVES`, and `HEX_HOME` to the agent so Hex and Rebar resolve, and the
  test suite keeps MCP socket dirs under a short writable `TMPDIR`. Only when
  `TMPDIR` is long and `/tmp` is not writable, set `SYMPHONY_MCP_SOCKET_ROOT`
  to a short writable path (the resulting `<root>/symphony-mcp-<id>/sock` must
  fit the 104-byte Unix `sun_path` limit).
- Never run CPU, memory or disk load generators or stress tools on the host:
  no `yes`, busy loops (one per core or otherwise), `stress`, or parallel test
  floods. The machine is shared with other agent runs, QA passes and workspace
  hooks; load slows all of them, and Symphony starts your process tree at a
  lower CPU priority anyway. To reproduce a timing flake, make the race
  deterministic instead: inject the delay or the message order, use the
  injectable clock, and add explicit synchronisation (wait on a message or a
  monitor, not a sleep). Then prove it stable with
  `mix test <file>:<line> --repeat-until-failure N` on the targeted test only.
- Don't leave background processes running: stop any server or watcher before
  ending the turn. Symphony kills whatever is still running in the workspace
  when the run ends.
- Tests and hooks that start login shells (`sh -lc`, `bash -lc`) may print
  `~/.profile: Operation not permitted` inside the sandbox. That is benign: the
  sandbox denies reading shell startup files and the command still runs. Do not
  record it as a workaround.
- Keep tool output focused by default. For broad searches, diffs, and file
  reads, start with targeted `rg` queries, `sed -n` ranges, and modest
  `max_output_tokens` caps. Raise output caps only after narrowing the command
  to the exact file or hunk needed.

## Related skills

- `linear`: interact with Linear.
- `commit`: produce clean, logical commits during implementation.
- `push`: keep remote branch current and publish updates.
- `pull`: keep branch updated with latest `origin/main` before handoff.
- `land`: only when Symphony dispatches you for a ticket in `Merging` (GitHub auto-merge could not be used), explicitly open and follow `.ai/skills/land/SKILL.md`, which includes the `land` loop.

{% render "status_map" %}

## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow.
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from current scratchpad comment.
   - `Waiting on sub-tickets` -> a `breakdown` parent waiting on its sub-tickets; do nothing and stop while any sub-ticket is open. Once every sub-ticket is terminal, run the close-out in `Parent tickets` below.
   - `Auto Review` -> Symphony is testing the PR as a user; do not change the issue or PR, stop and wait.
   - `In Review` -> wait and poll for decision/review updates.
   - `Merging` -> Symphony normally lands the PR with GitHub auto-merge and does not start an agent. If you are running in `Merging`, auto-merge could not be used: open and follow `.ai/skills/land/SKILL.md`; do not call `gh pr merge` directly.
   - `Rework` -> run rework flow (for a `breakdown` parent, the re-plan run in `Parent tickets` below).
   - `Done` -> do nothing and shut down.
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Todo` tickets, do startup sequencing in this exact order. The state transition must be the first tool call of the run, before any other reads, planning, or analysis:
   - `linear_update_state("In Progress")`
   - find/create `{{ agent.workpad_heading }}` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.
7. If the ticket has the `breakdown` label, or its title starts with `Final verification:`, follow `Parent tickets` below in place of the implementation steps (Step 1 items 8-11 and Step 2). The `Todo` -> `In Progress` transition and the workpad still apply.

## Step 1: Start/continue execution (Todo or In Progress)

1.  Find or create a single persistent scratchpad comment for the issue:
    - Search existing comments for a marker header: `{{ agent.workpad_heading }}`.
    - For compatibility, also reuse an existing `## Codex Workpad` or `## Claude Workpad` comment if present.
    - If an existing workpad uses a different agent marker, update that header to `{{ agent.workpad_heading }}` while preserving the rest of the comment.
    - Ignore resolved comments while searching; only active/unresolved comments are eligible to be reused as the live workpad.
    - If found, reuse that comment; do not create a new workpad comment.
    - If not found, create one workpad comment and use it for all updates.
    - Persist the workpad comment ID and only write progress updates to that ID.
2.  If arriving from `Todo`, do not delay on additional status transitions: the issue should already be `In Progress` before this step begins.
3.  Immediately reconcile the workpad before new edits:
    - Check off items that are already done.
    - Expand/fix the plan so it is comprehensive for current scope.
    - Ensure `Acceptance Criteria` and `Validation` are current and still make sense for the task.
4.  Start work by writing/updating a hierarchical plan in the workpad comment.
    - If the ticket asks you to split the work into sub-tickets, create each one with `linear_create_subissue` (see `Splitting work and out-of-scope improvements` below) and record their identifiers in the workpad `Notes`. They land in `Backlog` as children of this issue.
    - If the work is clearly too large for one PR and the ticket has no `breakdown` label, say so in the workpad `Confusions` so a human can add the label; do not split it unasked.
5.  Ensure the workpad includes a compact environment stamp at the top as a code fence line:
    - Format: `<host>:<abs-workdir>@<short-sha>`
    - Example: `devbox-01:/home/dev-user/code/symphony-workspaces/MT-32@7bdde33bc`
    - Do not include metadata already inferable from Linear issue fields (`issue ID`, `status`, `branch`, `PR link`).
6.  Add explicit acceptance criteria and TODOs in checklist form in the same comment.
    - If changes are user-facing, include a UI walkthrough acceptance criterion that describes the end-to-end user path to validate.
      When the ticket has a `## User walkthrough` section, copy its numbered steps and expected results into that criterion verbatim.
    - If changes touch app files or app behavior, add explicit app-specific flow checks to `Acceptance Criteria` in the workpad (for example: launch path, changed interaction path, and expected result path).
    - If the ticket description/comment context includes `Validation`, `Test Plan`, or `Testing` sections, copy those requirements into the workpad `Acceptance Criteria` and `Validation` sections as required checkboxes (no optional downgrade).
7.  Run a principal-style review of the plan and refine it in the comment.
8.  Before implementing, capture a concrete reproduction signal and record it in the workpad `Notes` section (command/output, screenshot, or deterministic UI behavior).
9.  Run the `pull` skill to sync with latest `origin/main` before any code edits, then record the pull/sync result in the workpad `Notes`.
    - Include a `pull skill evidence` note with:
      - merge source(s),
      - result (`clean` or `conflicts resolved`),
      - resulting `HEAD` short SHA.
10. Before implementing, record a blast radius analysis in the workpad `Notes` section:
    - files and functions to be changed,
    - all known callers of those functions, using grep/search results where applicable,
    - existing test coverage for the affected code,
    - estimated blast radius (`narrow`, `moderate`, or `wide`) with justification.
    - new branches and error/edge paths introduced by the change, and the exact test that will exercise each. The repo enforces a 100% coverage threshold in CI; an unexercised branch will fail the CI `coverage report` job, so plan the test now rather than measuring coverage locally. If a path is genuinely unreachable from tests (boundary I/O shim), call it out here and plan to extend `mix.exs` `test_coverage` `ignore_modules` rather than skipping the gate.
    - Do not write the first code edit until this analysis is recorded.
11. Compact context and proceed to execution.

{% render "pr_feedback_sweep" %}

{% render "ci_triage" %}

{% render "escape_hatches" %}

{% render "parent_tickets" %}

## Step 2: Execution phase (Todo -> In Progress -> In Review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
    - Never leave completed work unchecked in the plan.
    - For tickets that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - Run the cheap, targeted checks from `Command and output hygiene`, not the full suite: CI runs the full test suite, coverage and Dialyzer.
    - For long-running validation, use long waits and sparse polling so progress-only terminal output does not create many tiny transcript events.
    - Keep terminal output fed back into the model small: preserve failing command, exit code, and the most relevant error lines; summarize successful or repetitive output instead of pasting complete logs.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
6.  Re-check all acceptance criteria and close any gaps.
7.  Before every `git push` attempt, run the targeted pre-push checks for your scope and confirm they pass; if one fails, address it and rerun until green.
    - Targeted pre-push checks: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix specs.check`, `mix credo --strict <changed files>`, and every new or changed test file plus the test files of the modules you changed.
    - Do not run `make all`, `make check`, `make coverage`, the full `mix test`, `mix test --stale` or Dialyzer before a push (see `Command and output hygiene` for the optional `make all` on shared infrastructure). CI is the gate for the full suite, the 100% coverage report and Dialyzer.
    - `git push` runs the repo's `.githooks/pre-push` hook, which reruns the format, compile and credo checks on the Elixir files the push changes and rejects the push when one fails. Never use `git push --no-verify`. When the hook fails, fix the issue it names (it prints the fixing command, such as `mix format`), commit, and push again.
    - If a prior push's CI checks are still failing, follow the `CI failure triage protocol` before re-pushing. A CI coverage gap is a red check like any other: add tests that exercise the missing branches, or extend `mix.exs` `test_coverage` `ignore_modules` only for genuinely untestable I/O shims.
    - After staging/committing changes and before pushing, run `git diff origin/main..HEAD` to review committed-only diff for:
      - stray debug statements, `console.log`, hardcoded test values, or temporary proof edits,
      - unintended file changes outside the ticket's scope,
      - incomplete hunks, half-finished removals, or reverted-only placeholders.
    - Only push after this review is clean.
    - Record the targeted checks you ran with their results (for example `format, compile, specs, credo — clean; test/foo_test.exs test/bar_test.exs — 42 tests, 0 failures`) and `diff reviewed — clean` in the workpad before each push.
8.  Attach PR URL to the issue (prefer attachment; use the workpad comment only if attachment is unavailable).
    - Ensure the GitHub PR has label `symphony` (add it if missing).
    - Ensure the PR body is reviewer-facing and follows `.github/pull_request_template.md`:
      - `## References` (required, bullets): only links that exist: the Linear ticket, design decision thread, design review, Loom. Drop a line rather than write "n/a",
      - `## This PR` (required): short, behaviour in plain words. Open with `Nothing changes on screen.` when nothing user-visible changes. Use a list only when the PR adds more than one distinct piece,
      - `### Important facts` (optional subsection of `## This PR`): only a new feature flag and its default, another flag or setting that must also be on, a migration or backfill, a new dependency, or a new environment variable. Risks, caveats, design rationale and follow-ups do not go here,
      - `## Stack` (optional): what all the parts of a stack deliver together, written once and repeated verbatim on every PR in the stack. Omit it when the PR stands alone; do not list, describe, or number the parts.
    - Do not add a test plan to the PR body; keep validation evidence in the workpad.
    - Validate the body with `mix pr_body.check --file <path>` before creating or updating the PR.
    - For UI-touching changes, capture before/after screenshots or a recording and attach them to the Linear issue with `linear_attach_file`. Do not embed them in the PR body.
9.  Merge latest `origin/main` into branch, resolve conflicts, and rerun checks.
10. Update the workpad comment with final checklist status and validation notes.
    - Mark completed plan/acceptance/validation checklist items as checked.
    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment; keep PR linkage on the issue via attachment/link fields.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
11. Before moving to `In Review`, poll PR feedback and checks:
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full PR feedback sweep protocol.
    - Confirm PR checks are passing (green) after the latest changes; if any are red, follow the `CI failure triage protocol`.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Repeat this check-address-verify loop until no outstanding comments remain and checks are fully passing.
    - Re-open and refresh the workpad before state transition so `Plan`, `Acceptance Criteria`, and `Validation` exactly match completed work.
12. Only then move issue to `In Review`.
    - No blocked-access exception: blocked issues must follow the blocked-access escape hatch and move to `Backlog` with a blocker comment.
    - If `linear_update_state` refuses `In Review` because Auto Review is on, leave the state as it is and end the turn; Symphony moves the issue to `Auto Review` itself.
    - After the PR is attached and the issue is moved to `In Review`, end the turn. Do not continue ordinary implementation work unless Symphony injects reviewer, CI, or operator rework context.
13. For `Todo` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then move to `In Review`.

## Step 3: In Review and merge handling

1. When the issue is in `In Review`, do not code or change ticket content.
2. Poll for updates as needed, including GitHub PR review comments from humans and bots.
3. Review comments on the PR (including the operator's own, when Symphony posts with the same GitHub account) are handled by Symphony: it moves the issue back to `In Progress` and re-activates you with the comments. Address them on the same PR and branch with the PR feedback sweep protocol, push, and return to `In Review`. Do not close the PR or reset the branch for review comments.
4. If approved, human moves the issue to `Merging`.
5. When the issue is in `Merging`, Symphony turns on GitHub auto-merge for the PR, updates the branch when it falls behind the base branch, and moves the issue to `Done` once GitHub merges it; no agent runs. A merge conflict comes back as `In Progress` with the conflict context and auto-merge turned off: your resolution goes back through review, and a fresh move to `Merging` turns auto-merge back on. A red head comes back as a CI-failure run; auto-merge stays on, so the PR merges once your fix is green. Only when auto-merge can't be used does Symphony dispatch you in `Merging` (with a comment on the issue saying why): then open and follow `.ai/skills/land/SKILL.md`, and run the `land` skill in a loop until the PR is merged. Do not call `gh pr merge` directly; merge with the scoped `github_merge_pull_request` tool.
   - When checks are still pending, and your runtime allows `gh` (Claude sessions deny it), wait for them inside the turn with one foreground `gh pr checks <pr-number> --watch` call that finishes under the 10-minute tool limit; waiting in a tool call costs no tokens. If they are still pending after that, or you cannot run `gh`, end the turn. Do not rely on `ScheduleWakeup`, `sleep` loops, or other in-session timers; they do nothing in unattended runs. Symphony keeps the issue in `Merging`, holds it until CI on the PR head settles, and then resumes the landing agent so it can merge without a second approval.
6. After merge is complete, move the issue to `Done`.

## Step 4: Rework handling

1. Treat `Rework` as a full approach reset, not incremental patching. A human moves the issue to `Rework` when the approach itself is wrong; ordinary review comments come back as `In Progress` on the same PR (see Step 3).
2. Re-read the full issue body and all human comments; explicitly identify what will be done differently this attempt.
3. Close the existing PR tied to the issue. There is no scoped tool to close a PR; if you cannot close it, note it in the workpad so the human closes it.
4. Preserve the existing workpad as the audit trail — do not delete it. In the single workpad comment (`{{ agent.workpad_heading }}`, or a legacy `## Codex Workpad` / `## Claude Workpad` header you should rewrite to `{{ agent.workpad_heading }}`), move the prior `Plan`, `Acceptance Criteria`, and `Validation` content under a `### Superseded — attempt <n>` heading so the record of what was already tried stays on the issue.
5. Create a fresh branch from `origin/main`.
6. Start over from the normal kickoff flow:
   - If current issue state is `Todo`, move it to `In Progress`; otherwise keep the current state.
   - Write a fresh `Plan`, `Acceptance Criteria`, and `Validation` in the same workpad comment — do not create a second workpad — then execute end-to-end.

{% render "completion_bar" %}

{% render "guardrails" %}

- When changing packages/dependencies, follow the dependency-change guardrail below; the lock file for this repo is `mix.lock`.

{% render "out_of_scope_backlog" %}

{% render "dependency_guardrail", lockfile: "mix.lock" %}

{% render "workpad_template", agent: agent %}
