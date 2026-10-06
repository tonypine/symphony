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
    - new branches and error/edge paths introduced by the change, and the exact test that will exercise each. The repo enforces a 100% coverage threshold in CI; an unexercised branch will fail the CI `coverage report` job, so plan the test now and check it before push with `mix cover.changed`. If a path is genuinely unreachable from tests (boundary I/O shim), call it out here and plan to extend `mix.exs` `test_coverage` `ignore_modules` rather than skipping the gate.
    - Do not write the first code edit until this analysis is recorded.
11. Compact context and proceed to execution.
