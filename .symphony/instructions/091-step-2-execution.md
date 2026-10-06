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
    - Targeted pre-push checks: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix specs.check`, `mix credo --strict <changed files>`, `mix cover.changed`, and every new or changed test file plus the test files of the modules you changed.
    - Do not run `make all`, `make check`, `make coverage`, the full `mix test`, `mix test --stale` or Dialyzer before a push (see `Command and output hygiene` for the optional `make all` on shared infrastructure). CI is the gate for the full suite, the 100% coverage report and Dialyzer.
    - `git push` runs the repo's `.githooks/pre-push` hook, which reruns the format, compile and credo checks on the Elixir files the push changes and rejects the push when one fails. Never use `git push --no-verify`. When the hook fails, fix the issue it names (it prints the fixing command, such as `mix format`), commit, and push again.
    - `github_push_branch` skips repo hooks, so when the push changes an Elixir file it needs the result of `.githooks/pre-push --head` for the commit it pushes. Run that command in your shell after your last commit: it runs the same checks in your sandbox and records the result in `tmp/push-check`. The tool refuses the push when the result is missing, is for another commit, or names a failed check; fix what it names, commit, run the command again and push. A push that changes no Elixir file needs no result.
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
      - Never launch an app, an `NSApplication`, or a window on the host to get them, not even a throwaway harness. The host is the operator's desktop: windows and "quit unexpectedly" dialogs land on their screen. The agent sandbox also blocks the window server, so such a harness crashes inside AppKit instead of drawing.
      - Render SwiftUI views offscreen with `ImageRenderer` instead (no `NSApplication`, no window), write the PNG with ImageIO, and attach that. Compile it with plain `swiftc -module-cache-path <workspace dir>`.
      - When a view can't be rendered offscreen, or the ticket wants the running app, leave the screenshots to the QA pass, which runs the app on the QA VM, and say so in the workpad.
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
    - If `linear_update_state` refuses `In Review` or `Human Review` because Auto Review is on, leave the state as it is and end the turn; Symphony moves the issue to `Auto Review` itself.
    - After the PR is attached and the issue is moved to `In Review`, end the turn. Do not continue ordinary implementation work unless Symphony injects reviewer, CI, or operator rework context.
13. For `Todo` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Ensure branch was pushed with any required updates.
    - Then move to `In Review`.
