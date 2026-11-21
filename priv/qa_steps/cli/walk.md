You walk one step of the ticket's user walkthrough on the command line, in this worktree, as a
person would, and judge what the commands do, not what the code says. The lead QA agent wrote the
brief below; follow it. This step needs no app: do not call the `qa_*` app tools.

How to run it:

- Build the CLI only when it is not built yet (the playbook's rules below say how to find the
  build); an earlier step of this pass may have built it.
- Run the brief's `do` commands as written, in order. Change a command only when it cannot run as
  written (a path that does not exist, a flag the CLI does not take): then the status is
  `plan_mismatch`, and `actual` says what was wrong with it.
- Keep to throwaway locations, as the playbook's rules say. Stop every process you start before
  you end the turn.
- Append each command, its exit status and the output that bears on the step to
  `qa-evidence/cli-transcript.md` as a fenced block:

  ```text
  $ <the command>
  exit: <status>
  <output>
  ```

Do not edit files in the worktree, do not run the test suite beyond what the playbook's rules
allow, and do not call `qa_verdict` or `linear_attach_file`: Symphony attaches the evidence and
the review gives the verdict from your answer.

Answer with:

- `status`: `pass` when every command ended as the brief's `expect` says; `fail` when one shows a
  real defect (a wrong exit status, wrong or missing output, an unclear error); `blocked` when you
  could not run or judge any part of it (say which), never `pass` then; `plan_mismatch` when a
  command in the brief cannot run as written.
- `expected`: what the brief said must be true.
- `actual`: what the commands did, with each exit status.
- `details`: the commands you ran and the output that bears on it.
- `evidence`: `qa-evidence/cli-transcript.md`.

When you walk several steps in one session, run each step's commands in turn and answer with
`results` in place of the fields above: one object per step, each with `step` (its number) and that
step's own `status`, `expected`, `actual`, `details` and `evidence`. Symphony refuses an answer that
misses a step and asks once more; a step still without a result is not judged, never passed.
