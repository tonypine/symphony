---
name: pull
description:
  Pull the repo's default/integration branch into the current local branch and
  resolve merge conflicts (aka update-branch). Use when Codex needs to sync a
  feature branch with origin, perform a merge-based update (not rebase), and
  guide conflict resolution best practices.
---

# Pull

## Workflow

1. Verify git status is clean or commit/stash changes before merging.
2. Under Symphony, sync with the `github_sync_base` tool (no arguments; Claude
   sees it as `mcp__symphony__github_sync_base`). It runs outside the agent
   sandbox, so it can merge base-branch changes to write-protected files such
   as `.ai/skills` or `WORKFLOW.md`, which a `git merge` in the sandbox cannot.
   It fetches `origin`, fast-forwards to the branch's remote copy when that is
   ahead, then merges the repo's base branch (e.g. `origin/main`) with rerere
   and `zdiff3` conflict markers, without committing. Act on its `status`:
   - `synced`: the branch already contains the base branch; nothing to commit.
   - `merge_staged`: no conflicts; run `git commit --no-edit`.
   - `conflicts`: resolve the listed files (see conflict guidance below),
     `git add` them, then `git -c rerere.enabled=true commit --no-edit`.
   - It refuses a branch that changes a write-protected path itself; drop that
     change from the branch rather than working around the refusal.
   Then go to step 8. Use the manual steps 3-7 only when the tool is not
   available (for example on an SSH worker, or outside Symphony).
3. Confirm remotes and branches:
   - Ensure the `origin` remote exists.
   - Ensure the current branch is the one to receive the merge.
   - Determine the repo's default/integration branch rather than assuming
     `main`. Different repos use different defaults (e.g. `main` vs `trunk`).
     Resolve it from Symphony's injected runtime context if present, otherwise
     discover it locally, for example:
     - `git symbolic-ref --short refs/remotes/origin/HEAD` (yields
       `origin/<branch>`), or
     - `gh repo view --json defaultBranchRef --jq .defaultBranchRef.name`.
     Use that branch name in place of `main` in the commands below.
4. Fetch latest refs:
   - `git fetch origin`
5. Sync the remote feature branch first:
   - `git pull --ff-only origin $(git branch --show-current)`
   - This pulls branch updates made remotely (for example, a GitHub auto-commit)
     before merging the integration branch.
6. Merge in order, with rerere turned on for this command only (do not write
   git config; the sandbox denies it):
   - `git -c rerere.enabled=true -c rerere.autoupdate=true -c merge.conflictstyle=zdiff3 merge origin/<integration-branch>`
     (e.g. `origin/main` or `origin/trunk`, depending on the repo).
7. If conflicts appear, resolve them (see conflict guidance below), then:
   - `git add <files>`
   - `git -c rerere.enabled=true commit` (or
     `git -c rerere.enabled=true merge --continue` if the merge is paused), so
     rerere records the resolution.
8. Verify with project checks (follow repo policy in `AGENTS.md`).
9. Summarize the merge:
   - Call out the most challenging conflicts/files and how they were resolved.
   - Note any assumptions or follow-ups.

## Conflict Resolution Guidance (Best Practices)

- Inspect context before editing:
  - Use `git status` to list conflicted files.
  - Use `git diff` or `git diff --merge` to see conflict hunks.
  - Use `git diff :1:path/to/file :2:path/to/file` and
    `git diff :1:path/to/file :3:path/to/file` to compare base vs ours/theirs
    for a file-level view of intent.
  - With `merge.conflictstyle=zdiff3`, conflict markers include:
    - `<<<<<<<` ours, `|||||||` base, `=======` split, `>>>>>>>` theirs.
    - Matching lines near the start/end are trimmed out of the conflict region,
      so focus on the differing core.
  - Summarize the intent of both changes, decide the semantically correct
    outcome, then edit:
    - State what each side is trying to achieve (bug fix, refactor, rename,
      behavior change).
    - Identify the shared goal, if any, and whether one side supersedes the
      other.
    - Decide the final behavior first; only then craft the code to match that
      decision.
    - Prefer preserving invariants, API contracts, and user-visible behavior
      unless the conflict clearly indicates a deliberate change.
  - Open files and understand intent on both sides before choosing a resolution.
- Prefer minimal, intention-preserving edits:
  - Keep behavior consistent with the branch’s purpose.
  - Avoid accidental deletions or silent behavior changes.
- Resolve one file at a time and rerun tests after each logical batch.
- Use `ours/theirs` only when you are certain one side should win entirely.
- For complex conflicts, search for related files or definitions to align with
  the rest of the codebase.
- For generated files, resolve non-generated conflicts first, then regenerate:
  - Prefer resolving source files and handwritten logic before touching
    generated artifacts.
  - Run the CLI/tooling command that produced the generated file to recreate it
    cleanly, then stage the regenerated output.
- For import conflicts where intent is unclear, accept both sides first:
  - Keep all candidate imports temporarily, finish the merge, then run lint/type
    checks to remove unused or incorrect imports safely.
- After resolving, ensure no conflict markers remain:
  - `git diff --check`
- When unsure, note assumptions and ask for confirmation before finalizing the
  merge.

## When To Ask The User (Keep To A Minimum)

Do not ask for input unless there is no safe, reversible alternative. Prefer
making a best-effort decision, documenting the rationale, and proceeding.

Ask the user only when:

- The correct resolution depends on product intent or behavior not inferable
  from code, tests, or nearby documentation.
- The conflict crosses a user-visible contract, API surface, or migration where
  choosing incorrectly could break external consumers.
- A conflict requires selecting between two mutually exclusive designs with
  equivalent technical merit and no clear local signal.
- The merge introduces data loss, schema changes, or irreversible side effects
  without an obvious safe default.
- The branch is not the intended target, or the remote/branch names do not exist
  and cannot be determined locally.

Otherwise, proceed with the merge, explain the decision briefly in notes, and
leave a clear, reviewable commit history.
