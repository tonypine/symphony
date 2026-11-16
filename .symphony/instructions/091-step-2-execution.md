In this repository, a plan run's sub-ticket that adds a `symphony.yml` setting either builds its control in the macOS app or names a sibling sub-ticket that does; that sibling has a `## User walkthrough` and is in the parent's plan, which the epic review checks. A sub-ticket that renames or removes a `symphony.yml` key ships its migration and the previous-release load test in the same PR.

In this repository, a walkthrough step that judges the macOS app by sight in dark mode, or judges the look of the status-bar menu, is a `Proved by: QA` step: no test can judge it. QA walks it with TP-1045's tools: `qa_launch_app`'s `appearance` argument launches the app in light and in dark, and `qa_open_status_menu` with a `qa_screenshot` of the menu shows how it looks, as the `macos_app` playbook requires. A walkthrough asks for both appearances and a screenshot of the status-bar menu; the accessibility tree alone does not prove how either looks. A step that installs one signed build over another needs a signing key the QA build lacks: the install is proved by the `macos` check's update test (`macos/Tests/e2e/update_restart_e2e.py`), which runs on a pull request that changes the update's paths and on every merge before a release, never by QA. What the app shows once an update installed, or once a failed one was rolled back, is a `Proved by: QA` step: QA judges it by sight with the signed release pair (`qa_build_release_pair`, `qa_launch_app`'s `release_pair`, `qa_relaunched_app`), which needs the QA host's test signing identity (`scripts/qa/install-test-signing-identity.sh`).

In this repository, a QA pass of the Director has two environments: the committed state fixtures, for how the app draws a state, and Symphony's own server running on the QA VM over a seed, for what happens after a move. Symphony starts the server when the change gives a reason, and the QA agent picks the environment for each step and names it in its report. Neither the walkthrough nor the proofs name one: an author writes plain steps, and an implementer records `Proved by:` tests as for any ticket and nothing about environments. The `qa:live` and `qa:fixture` labels are a person's override of Symphony's choice, set from the ticket page in the Director; never add them yourself.

## Step 2: Execution phase (Todo -> In Progress -> Code Review)

1.  Determine current repo state (`branch`, `git status`, `HEAD`) and verify the kickoff `pull` sync result is already recorded in the workpad before implementation continues.
2.  If current issue state is `Todo`, move it to `In Progress`; otherwise leave the current state unchanged.
3.  Load the existing workpad comment and treat it as the active execution checklist.
    - Edit it liberally whenever reality changes (scope, risks, validation approach, discovered tasks).
4.  Implement against the hierarchical TODOs and keep the comment current:
    - Check off completed items.
    - Add newly discovered items in the appropriate section.
    - Keep parent/child structure intact as scope evolves.
    - Update the workpad immediately after each meaningful milestone (for example: reproduction complete, code change landed, validation run, review feedback addressed).
{% unless run.step_runner %}    - Never leave completed work unchecked in the plan.
{% endunless %}    - For tickets that started as `Todo` with an attached PR, run the full PR feedback sweep protocol immediately after kickoff and before new feature work.
    - Write the ticket's brief before anything else you record: the first `ticket_record` of your first delegated step is a `brief.written`, with `text` (what the ticket does and why, in a person's words, under 1,200 characters: no module names, no endpoint paths, no backticks) and `walkthrough` (the steps a person takes to see it work, as prose). The newest brief is the one the Director shows first and every later run's prompt carries in the ticket's history; the Linear description stays as it is.
    - Record your work on the ticket's history as you go, with `ticket_record`: `step.completed` for each delegated step of the step list when you end it (its `outcome`: `passed`, `failed` with the step it `returns_to`, or `skipped` with a `reason`), `evidence` for every screenshot or output you attach (the files as `artifacts`, a `caption` saying what it shows), and a `note` for a choice a later run should know. The Director's timeline shows these events as the run works.
{% if run.step_runner %}5.  Leave the checks to the step list.
    - This run follows a step list: once you end the `code` step, Symphony runs the build, the checks and the tests itself, with your session closed. A step that fails brings the run back to `code` with its output: fix what it names and end the step again.
    - Do not run the build, the format, specs or lint checks, the tests, the coverage check or the Swift build and tests yourself, and never the full suite or Dialyzer: write the code, commit it, record what you changed, and end the turn. CI is the gate for the full suite, the 100% coverage report and Dialyzer.
    - Execute every ticket-provided `Validation`/`Test Plan`/`Testing` requirement that is not a check the step list runs (a preview to read, a fixture to render); treat unmet items as incomplete work.
    - You may make temporary local proof edits to validate assumptions; revert every one before you commit, and document them in the workpad `Notes`.
{% else %}5.  Run validation/tests required for the scope.
    - Mandatory gate: execute all ticket-provided `Validation`/`Test Plan`/ `Testing` requirements when present; treat unmet items as incomplete work.
    - Prefer a targeted proof that directly demonstrates the behavior you changed.
    - Leave the full test suite, coverage and Dialyzer to CI (see `Command and output hygiene`).
    - For long-running validation, use long waits and sparse polling so progress-only terminal output does not create many tiny transcript events.
    - Keep terminal output fed back into the model small: preserve failing command, exit code, and the most relevant error lines; summarize successful or repetitive output instead of pasting complete logs.
    - You may make temporary local proof edits to validate assumptions (for example: tweak a local build input for `make`, or hardcode a UI account / response path) when this increases confidence.
    - Revert every temporary proof edit before commit/push.
    - Document these temporary proof steps and outcomes in the workpad `Validation`/`Notes` sections so reviewers can follow the evidence.
{% endif %}6.  Re-check all acceptance criteria and close any gaps.
    - When the ticket has a `## User walkthrough`, record the proof of every step an automated test in this PR covers, before the handoff push: call `linear_record_walkthrough_proofs` with each step's number and its test. It records each proof as an `evidence` event with `proof` (the step and the test) on the ticket's history and leaves the description as it is. Name the test as the code has it: its file path, or a test or scenario name as written. Name only tests in this PR, and never a check name: the repo's `proof_check` in WORKFLOW.md is the check that runs them, and the tool refuses a ` › ` separator. Leave a step no test covers as it is, for QA; the tool refuses a step its author marked `Proved by: QA`. The QA pre-check then confirms each named test on the PR head, and QA links its result instead of walking the step.
{% if run.step_runner %}7.  The `handoff` step pushes. When the step list reaches it, the build, checks and tests passed on your changes.
    - `github_push_branch` skips repo hooks, so when the push changes an Elixir file it needs the result of `.githooks/pre-push --head` for the commit it pushes. Run that command in your shell after your last commit: it records the result in `tmp/push-check`. The tool refuses the push when the result is missing, is for another commit, or names a failed check; fix what it names, commit, run the command again and push. Never use `git push --no-verify`.
    - After committing and before pushing, run `git diff origin/main..HEAD` and review it for stray debug statements, hardcoded test values, temporary proof edits, unintended files outside the ticket's scope, and incomplete hunks. Only push after this review is clean, and record `diff reviewed — clean` and the step list's results in the workpad.
{% else %}7.  Before every `git push` attempt, confirm the push check passes; if it fails, address it and rerun until green.
    - CI is the gate for the full suite, the 100% coverage report and Dialyzer; they never run locally.
    - `git push` runs the repo's `.githooks/pre-push` hook, which reruns the format, compile and credo checks on the Elixir files the push changes and rejects the push when one fails. Never use `git push --no-verify`. When the hook fails, fix the issue it names (it prints the fixing command), commit, and push again.
    - `github_push_branch` skips repo hooks, so when the push changes an Elixir file it needs the result of `.githooks/pre-push --head` for the commit it pushes. Run that command in your shell after your last commit: it runs the same checks in your sandbox and records the result in `tmp/push-check`. The tool refuses the push when the result is missing, is for another commit, or names a failed check; fix what it names, commit, run the command again and push. A push that changes no Elixir file needs no result.
    - If a prior push's CI checks are still failing, follow the `CI failure triage protocol` before re-pushing. A CI coverage gap is a red check like any other: add tests that exercise the missing branches, or extend `mix.exs` `test_coverage` `ignore_modules` only for genuinely untestable I/O shims.
    - After staging/committing changes and before pushing, run `git diff origin/main..HEAD` to review committed-only diff for:
      - stray debug statements, `console.log`, hardcoded test values, or temporary proof edits,
      - unintended file changes outside the ticket's scope,
      - incomplete hunks, half-finished removals, or reverted-only placeholders.
    - Only push after this review is clean.
    - Record the push check's result and `diff reviewed — clean` in the workpad before each push.
{% endif %}8.  Attach PR URL to the issue (prefer attachment; use the workpad comment only if attachment is unavailable).
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
9.  Merge latest `origin/main` into branch and resolve conflicts{% if run.step_runner %} during the `code` step, before you end it, so the step list's checks run on the merge{% else %}, and rerun checks{% endif %}.
10. Update the workpad comment with final checklist status and validation notes.
{% if run.step_runner %}    - Mark completed acceptance checklist items as checked; Symphony keeps `Plan` and `Validation` current from the steps.
{% else %}    - Mark completed plan/acceptance/validation checklist items as checked.
{% endif %}    - Add final handoff notes (commit + validation summary) in the same workpad comment.
    - Do not include PR URL in the workpad comment; keep PR linkage on the issue via attachment/link fields.
    - Add a short `### Confusions` section at the bottom when any part of task execution was unclear/confusing, with concise bullets.
    - Do not post any additional completion summary comment.
11. Before the handoff push, sweep PR feedback and checks:
    - Read the PR `Manual QA Plan` comment (when present) and use it to sharpen UI/runtime test coverage for the current change.
    - Run the full PR feedback sweep protocol.
    - Confirm every required ticket-provided validation/test-plan item is explicitly marked complete in the workpad.
    - Re-open and refresh the workpad before the handoff so {% if run.step_runner %}`Acceptance Criteria` and `Notes` exactly match{% else %}`Plan`, `Acceptance Criteria`, and `Validation` exactly match{% endif %} completed work.
12. Then hand off: push the branch and open the PR (or update it). That push is the handoff signal; Symphony moves the ticket to `Code Review` itself.
    - Before the push, when the work changed what the ticket does (a part dropped, added or reshaped), write a new `brief.written` that says what it does now; the newest one replaces the brief.
    - Do not ask for `Code Review` (or `QA`, `Merging`) with `linear_update_state`: it is refused, because those states are the handoff's and the verdicts' to enter.
    - A run that ends without pushing its head and opening its PR never advances: the ticket stays where it is and the run is retried.
    - A block is not a handoff: follow the blocked-access escape hatch, which sets a `Blocked` or `Needs Decision` hold and leaves the ticket in its phase.
    - After the handoff push, end the turn. The reviewer starts on the pushed head at once, and CI runs beside it: changes come back to you through `Rework` whatever CI says, and a red head comes back through `CI Fix` after an approve. Do not continue ordinary implementation work unless Symphony injects reviewer, QA, CI or operator context.
13. For `Todo` tickets that already had a PR attached at kickoff:
    - Ensure all existing PR feedback was reviewed and resolved, including inline review comments (code changes or explicit, justified pushback response).
    - Then push the updates to the same branch; that push is the handoff to `Code Review`.

### Visual work

Apply this whenever a ticket adds or changes a screen or pane.

- Viewports are inputs to any layout change; the repo's `WORKFLOW.md` names them with a goal each: `functional` (every control reachable; scroll and collapse allowed; nothing clipped) or `optimize` (use the space). Where a repo names none, the QA wide pass size (1400×900 pt) is the functional viewport.
- Design before code, recorded in the workpad under `### Design`:
  1. Layout: the top-level sections and, per viewport, what shows, what collapses, what scrolls, what hides. Persistent chrome (navigation, side panels, detail panes) is part of the budget: when one opens, content gives way by a mechanism, never by being pushed off-screen or truncated to unreadability.
  2. Each section designed on its own, then reviewed together.
  3. Responsiveness pass, answered in writing: Is horizontal scroll needed, and where? Which panes resize or collapse? Is every control reachable at each viewport?
  4. Interactivity pass: hover, pressed, focused, disabled and loading states for every control; keyboard reachability.
  5. Accessibility pass: AX labels on every control; contrast per the repo's design system.
- Offscreen renders (`ImageRenderer`) per viewport where the view renders offscreen; where it doesn't (`Table`, `NavigationSplitView`, `Form`), say so in the workpad and leave the sight check to QA.
