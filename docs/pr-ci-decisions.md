# PR and CI decisions

What the PR and CI watcher does for a ticket in each phase and PR situation. Rules are checked
in order and the first that matches decides.

<!-- BEGIN mix pr_decision.table: generated from SymphonyElixir.PrDecision.rules/0, do not edit by hand -->

## Rules

| Rule | Phases | When | Then |
| --- | --- | --- | --- |
| R1 | all | GitHub's rate limit is spent, so the facts can't be read | `wait` on `github` until the limit resets |
| R2 | all | The PR is merged, by Symphony or anyone else | `close_out` |
| R3 | In Progress, Code Review, QA, Rework, CI Fix | Auto-merge is armed and the ticket is not in Merging | `disarm` |
| R4 | all | A Needs Decision or Blocked hold is set | `wait` on `person` (Needs Decision) or `symphony` (Blocked) until the hold clears |
| R5 | In Progress | No PR yet | `wait` on `agent` until it opens one |
| R6 | Code Review, QA, Rework, CI Fix, Merging | No PR on the ticket and no run | `decision`: attach the PR, Restart, or cancel the ticket |
| R7 | all | The PR's base is not the repo's base branch, and no run | `decision`: put the base back, or accept the new base |
| R8 | all | The PR was closed without merging (or its branch deleted) | run active: `wait` on `agent`; In Progress or Rework: `dispatch`; otherwise `to_rework` |
| R9 | all | A run is active | `wait` on `agent` until the run ends |
| R10 | Code Review, QA, Merging | The PR is a draft | `wait` on `person` until it is marked ready for review |
| R11 | Merging | A person pushed the PR's head | `to_code_review` (auto-merge goes off by R3) |
| R12 | In Progress | The PR is open and no run | `dispatch` the agent |
| R13 | Code Review, QA, Merging | Review comments or requested changes are unaddressed | `to_in_progress` on the same PR |
| R14a | Code Review, QA, Rework, CI Fix, Merging | The PR conflicts with main and a PR sharing its files is ahead in the landing order | `wait_for_competitors` on the PRs ahead |
| R14 | Code Review, QA, Rework, CI Fix, Merging | The PR conflicts with main, fewer than 3 conflict fix runs | `ci_fix` for the conflict |
| R15 | Code Review, QA, Rework, CI Fix, Merging | The conflict is back after 3 fix runs and open PRs share its files | `wait_for_competitors` on every competing PR, stepping behind them |
| R15a | Code Review, QA, Rework, CI Fix, Merging | The conflict is back after 3 fix runs and no open PR competes | `to_rework` (Rework: `dispatch`) |
| R16 | Merging | GitHub has not computed whether the PR can merge | `wait` on `github` |
| R17 | Code Review, QA, Rework, CI Fix, Merging | A required check never reported within `landing_wait_timeout_ms` | `decision`: proceed without it for this PR (this head only), rerun, or fix the workflow in Rework |
| R18 | Code Review, QA, Rework, CI Fix, Merging | Only a check a person must clear is red (`protected paths`) | `decision`: add the waiver label, or drop the change in Rework |
| R19 | Code Review, QA, Rework, CI Fix, Merging | Red only because every run of a workflow was cancelled | `rerun_failed`, no attempt spent |
| R20 | Code Review, QA, Rework, CI Fix, Merging | Red, and the same failure 3 fix runs in a row or `red_attempts` at `max_red_attempts` | `file_fix_ticket` for the failing check, waiting on `symphony` until it is terminal |
| R21 | Code Review, QA, Rework, CI Fix, Merging | Red after a rerun | `ci_fix` for the red head, back to the phase it came from |
| R22 | Code Review, QA, Rework, CI Fix, Merging | Red, not rerun yet | `rerun_failed` once |
| R23 | Code Review, QA, Rework, CI Fix, Merging | Red, and the same check is red on the base branch | `wait` on `ci` until the base goes green |
| R24 | Code Review, QA, CI Fix | Checks are running on the head | `wait` on `ci` |
| R25 | CI Fix | Green (or no CI) and conflict-free | `return_to_origin`, approvals carried forward |
| R26 | Rework | Not red, not conflicting, no run | `dispatch` the rework run |
| R27 | Code Review, QA | Green, or no CI configured (counts as green) | `dispatch` the reviewer or the QA agent |
| R28 | Merging | The PR is behind main | a PR ahead shares its files: `wait` on `symphony`; otherwise `update_branch` |
| R29 | Merging | Green (or no CI) and mergeable now | `merge_now` |
| R30 | Merging | Auto-merge off, and checks running or branch protection still blocking | `arm` auto-merge |
| R31 | Merging | Branch protection blocked the merge past the merge wait | `land_agent` |
| R32 | Merging | Auto-merge armed and checks running | `wait` on `ci`; auto-merge lands it |
| R33 | Merging | Auto-merge armed and branch protection still blocking | `wait` on `github` until it is satisfied or the merge wait passes |

## Facts

Each fact a rule decides on, the values the table test enumerates, and when the fact is read. Counts list the value under the limit and the limit (`max_red_attempts` is 10 by default; a conflict gets 3 fix runs).

| Fact | Values | Read when |
| --- | --- | --- |
| `phase` | `in_progress`, `code_review`, `qa`, `rework`, `ci_fix`, `merging` | always |
| `github` | `ok`, `rate_limited` | always |
| `hold` | `none`, `needs_decision`, `blocked` | always |
| `run` | `none`, `active` | always |
| `auto_merge` | `off`, `armed` | always |
| `pr` | `missing`, `open`, `draft`, `closed`, `merged` | always |
| `base` | `ok`, `changed` | `pr` is `open` or `draft` |
| `head_origin` | `symphony`, `person` | `pr` is `open` or `draft` |
| `review_comments` | `none`, `unaddressed` | `pr` is `open` or `draft` |
| `ci` | `pending`, `green`, `none`, `red`, `required_missing` | `pr` is `open` or `draft` |
| `red_kind` | `failure`, `cancelled`, `human_only`, `also_red_on_base` | `ci` is `red` |
| `rerun_done` | `false`, `true` | `ci` is `red` and `red_kind` is `failure` |
| `red_attempts` | `9`, `10` | `ci` is `red` and `red_kind` is `failure` |
| `same_failure_streak` | `2`, `3` | `ci` is `red` and `red_kind` is `failure` |
| `mergeable` | `clean`, `behind`, `dirty`, `unstable`, `blocked`, `unknown` | `pr` is `open` or `draft` |
| `ahead` | empty, not empty | `mergeable` is `dirty` or `behind` |
| `conflict_attempts` | `2`, `3` | `mergeable` is `dirty` |
| `competing` | empty, not empty | `mergeable` is `dirty` |
| `landing_timed_out` | `false`, `true` | `mergeable` is `blocked` |

## Waits

These actions leave the ticket waiting, so each names who it waits on and what ends the wait: `wait`, `wait_for_competitors`, `file_fix_ticket`, `decision`.

Owners: `agent`, `ci`, `github`, `person`, `symphony`.

<!-- END mix pr_decision.table -->

## Where the facts come from

The watcher reads them by polling, one watcher per repository whose pull requests are polled,
every `pull_requests.poll_interval_ms`. Each read takes the watched tickets from Linear: every
ticket in `Code Review`, `QA`, `Rework`, `CI Fix` or `Merging`, and in `In Progress` once it has a
PR, whether or not Symphony ran it. It then reads each ticket's PR in one GitHub query, the checks
its base branch requires (kept 10 minutes), whether the base branch has workflow files (only for a
head with no check at all, kept 10 minutes), the base branch's workflow runs only to tell a red head
that is also red on the base, a red head's failed log once per head (its first error line), and,
when two or more watched PRs are open, the repository's open PRs and their files once, for the
landing order that fills `ahead`.

The facts are kept on the ticket's state record and listed under each ticket's `watch.facts` in
`/api/v1/state`. A GitHub error doubles the wait between reads, up to 5 minutes; GitHub's rate
limit marks the tickets it left unread `github: rate_limited` and waits for the reset.

Before deciding, the watcher completes the read with what it keeps between reads (`attempts` on the
ticket's record): the CI Fix runs counted, the heads whose failed checks it reran, whether a rerun's
checks have reported yet (a head whose rerun hasn't reported reads as running), since when a
`Merging` head has been blocked by branch protection on green checks (the merge wait), and the last
head Symphony put on a `Merging` PR (any other one is a person's push). In `Merging`, a failed
`protected paths` check that the ticket's unlock decisions cover doesn't hold the head back. The
review comments still to address come from the PR review poller's record: reviewer comments left on
the current head, once `pull_requests.review_comments.rework_delay_minutes` has passed since the
latest one (a push that addresses them moves the head, so they never send the fix back twice).

### Checks that never report, and no CI

A head with no check at all on a base branch with no workflow files has no CI: `ci: none`, which
counts as green (D2), and the decision says so ("No CI configured on main"). With workflow files on
the base, the head waits for its first check; past `pull_requests.checks.landing_wait_timeout_ms`
with none, it reads as having no CI too ("No check reported on the head within the wait"), so a
workflow that never runs on pull requests doesn't park the ticket.

A check the base branch requires that hasn't reported reads as running until the same wait passes,
in any phase. Past it, R17 asks a person (D3), with the ticket held in its phase: **Proceed without
it for this PR** waives the check for that head only (a new head waits for it again), **Rerun the
checks** reruns the head's workflow runs and starts the wait over, and **Fix the workflow in
Rework** moves the ticket to Rework, where nothing is asked again on that head. The watcher reads
the answer from the ticket's recorded decisions once the hold clears; an answer that picks no option
starts the wait over, and the question comes again.

A red head whose only failure is `protected paths`, which only a person clears, asks in every phase
(R18): add the waiver label to the PR (the check runs again and passes), or drop the change in
Rework. A check that is red on the base branch too (R23) is a wait on CI, with no CI Fix spent:
logged once per base and check, listed under `red_bases` in `/api/v1/state`, and cleared once the
base is green.

## What the watcher does

Every read decides and applies the action (`SymphonyElixir.PrDecision.Apply`): Linear moves go
through the transition guard, holds through the Needs Decision hold and the self-heal lane, GitHub
calls through `SymphonyElixir.AutoMerge`. The record keeps the decision (its rule, reason, who a
wait is on and what ends it) and the actions applied in the ticket's stay in its phase. An action is
applied once per head and rule in a stay, so a repeated read never repeats a move, a rerun, an
update-branch or a fix-ticket filing; one that fails is not recorded, and the next read decides
again. The ticket's CI label (`CI green`, `CI red`, `CI running`) follows the facts.

The CI and PR review pollers decide nothing in the watched phases: the CI poller keeps the head it
last read for a landing agent's CI wait, and the PR review poller keeps a PR's reviewer comments for
the run's prompt and cleans up after a merged or closed PR. The orchestrator starts a `Code Review`
or `QA` run only on the decision `dispatch`, and, with auto-merge on, a `Merging` landing agent only
on `land_agent`.

Some rows are recorded without an action until a later ticket applies them: stepping behind
competing PRs (R15). So are the CI rows (R17 to R22, and R18 outside `Merging`) with
`pull_requests.checks` off, and the landing rows (R18 in `Merging` too, and a conflict and review
comments there) with `pull_requests.auto_merge` off.

### A PR's life

The facts follow the ticket's PR from open to merged or closed, and then the new PR a rework run
opens:

- **Merged**, by Symphony or by a person on GitHub, in any watched phase (R2): the ticket moves to
  Done, or waits on its started sub-tickets. A PR merged before the watcher followed it (a ticket
  reopened after its merge) is not followed: that ticket has no PR yet.
- **Closed without merging**, or its branch deleted (R8, D5): a run that is working is left to end;
  in In Progress or Rework the next run opens a new PR from main; in Code Review, QA, CI Fix or
  Merging auto-merge goes off and the ticket moves to Rework with the reason "PR #N was closed
  without merging", with no question. The rework run is dispatched on the closed PR and never moved
  again for it; once it opens its new PR, the facts describe that one.
- **Draft** in Code Review, QA or Merging (R10): a wait on a person until it is marked ready for
  review. In `Merging` auto-merge goes off while it is a draft, and the landing resumes once it is
  ready.
- **On another base** than the repo's `base_branch` (else GitHub's default branch) (R7): a person is
  asked. "Put the base back" retargets the PR once; "Accept the new base" lets it go on, for that
  base only.
- **No PR** past In Progress (R6): a person is asked to attach it, restart or cancel the ticket.
  In Progress without a PR waits for the agent to open one (R5). A plan parent never has one and
  isn't watched without it.
- **Review comments** to address in Code Review, QA or Merging (R13, D8): auto-merge goes off and
  the ticket goes back to In Progress on the same PR, where the run reads the comments.

### Fix runs and their limits

A CI Fix run sent for a red head spends a **red** attempt, held against
`pull_requests.checks.max_fix_attempts` (default 10). Its prompt lists the earlier runs' failures
(the check, its first error line and the head), so it knows what was tried. A run sent for a
conflict spends a **conflict** attempt, against a fixed 3. A run never spends the other kind, and the run a ticket
entered CI Fix for spends no second attempt while it works there. Both counts reset only once the
PR is green **and** conflict-free: a conflicting PR keeps its last green checks, because GitHub runs
no workflow on it while it conflicts.

The red backstop also stops **the same failure in a row** (`same_failure_streak`, D15 (c)). A red
head's signature is its failed check and the first error line of its failed log. Each CI Fix run
that pushed a head failing with the same signature as the run before adds 1; a different failure, a
green head, a green and conflict-free PR, or a cleared fix-ticket hold starts it again. At 3 the
backstop fires, whatever the red count: twice in a row still gets another CI Fix run. The signature
is the self-heal lane's own for the fix ticket, so the lane's check for the same failure after a fix
lands compares like with like.

At the red backstop (R20) the watcher turns auto-merge off and hands the failing check to the
self-heal lane, which files one fix ticket per failing check per repo (component `ci:<check>`) or
reuses the open one, attaches each fix run's failing check, first error line and head, the red
count ("3 of 10 CI Fix runs"), the PR and its head as evidence, links it as a blocker and holds the ticket on it, in place. No question is asked and
the ticket doesn't move. The hold clears by itself once the fix ticket is terminal, the red count
restarts, and the head gets CI Fix runs again. The same failure reaching the backstop again after its
fix landed is the self-heal lane's own escalation to a person.

A conflict back after its 3 fix runs with no open PR ahead of it goes to `Rework` (R15a), where a
run can change as much as the conflict needs. A conflict while a PR that shares its files is ahead
in the landing order waits for that one to land (R14a), auto-merge off in `Merging`.
