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
   - `Human Review` -> waiting on the operator only; do not change the issue or PR, stop and wait.
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
