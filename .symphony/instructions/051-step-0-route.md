## Step 0: Determine current ticket state and route

1. Fetch the issue by explicit ticket ID.
2. Read the current state.
3. Route to the matching flow:
   - `Backlog` -> do not modify issue content/state; stop and wait for human to move it to `Todo`.
   - `Todo` -> immediately move to `In Progress`, then ensure bootstrap workpad comment exists (create if missing), then start execution flow.
     - If PR is already attached, start by reviewing all open PR comments and deciding required changes vs explicit pushback responses.
   - `In Progress` -> continue execution flow from current scratchpad comment.{% if state_machine == "designed" %}
   - `Code Review` -> the reviewer agent judges the PR on its green head; do not change the issue or PR, stop and wait for the verdict.
   - `QA` -> a QA agent walks the change's user journeys end to end; do not change the issue or PR, stop and wait for the verdict.
   - `CI Fix` -> run the mechanical lane in the `CI failure triage protocol`: minimal repair on the same branch, or `Rework` when the repair is substantive.
   - `Plan Review` -> a person reviews the plan; do nothing and stop.
   - `Waiting on sub-tickets` -> a plan ticket waiting on its sub-tickets; do nothing and stop. Symphony moves it to `Epic Review` itself once every sub-ticket is terminal.
   - `Epic Review` -> Symphony's epic review checks the epic against what shipped; do nothing and stop.
   - `Merging` -> Symphony lands the PR with GitHub auto-merge and does not start an agent. If you are running in `Merging`, auto-merge could not be used: open and follow `.agents/skills/land/SKILL.md`; do not call `gh pr merge` directly.
   - `Rework` -> continue the existing PR with the rework flow (Step 4; for a plan ticket, the plan revision or re-plan run in `Parent tickets` below).
   - `Done` -> do nothing and shut down.
   - A `Blocked` or `Needs Decision` label on the ticket -> a hold pauses it in its phase; do not change the issue or PR, stop and wait for it to clear.{% else %}
   - `Waiting on sub-tickets` -> a plan ticket waiting on its sub-tickets; do nothing and stop while any sub-ticket is open. Once every sub-ticket is terminal, run the close-out in `Parent tickets` below.
   - `In Review` -> wait and poll for decision/review updates.
   - `Human Review` -> waiting on the operator only; do not change the issue or PR, stop and wait.
   - `Merging` -> Symphony normally lands the PR with GitHub auto-merge and does not start an agent. If you are running in `Merging`, auto-merge could not be used: open and follow `.agents/skills/land/SKILL.md`; do not call `gh pr merge` directly.
   - `Rework` -> run rework flow (for a plan ticket, the re-plan run in `Parent tickets` below).
   - `Done` -> do nothing and shut down.{% endif %}
4. Check whether a PR already exists for the current branch and whether it is closed.
   - If a branch PR exists and is `CLOSED` or `MERGED`, treat prior branch work as non-reusable for this run.
   - Create a fresh branch from `origin/main` and restart execution flow as a new attempt.
5. For `Todo` tickets, do startup sequencing in this exact order. The state transition must be the first tool call of the run, before any other reads, planning, or analysis:
   - `linear_update_state("In Progress")`
   - find/create `{{ agent.workpad_heading }}` bootstrap comment
   - only then begin analysis/planning/implementation work.
6. Add a short comment if state and issue content are inconsistent, then proceed with the safest flow.
7. If the ticket has the `plan` label (or `breakdown`, its older name, still accepted){% if state_machine != "designed" %}, or its title starts with `Final verification:`{% endif %}, follow `Parent tickets` below in place of the implementation steps (Step 1 items 8-11 and Step 2). The `Todo` -> `In Progress` transition and the workpad still apply.
