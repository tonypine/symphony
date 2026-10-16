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
| R17 | Code Review, QA, Rework, CI Fix, Merging | A required check never reported within the timeout | `decision`: proceed without it for this head, rerun, or fix the workflow in Rework |
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
its base branch requires (kept 10 minutes), the base branch's workflow runs only to tell a red head
that is also red on the base, and, when two or more watched PRs are open, the repository's open PRs
and their files once, for the landing order that fills `ahead`.

The facts are kept on the ticket's state record and listed under each ticket's `watch.facts` in
`/api/v1/state`. A GitHub error doubles the wait between reads, up to 5 minutes; GitHub's rate
limit marks the tickets it left unread `github: rate_limited` and waits for the reset.

Before deciding, the watcher completes the read with what it keeps between reads (`attempts` on the
ticket's record): the CI Fix runs counted, the heads whose failed checks it reran, whether a rerun's
checks have reported yet (a head whose rerun hasn't reported reads as running), since when a
`Merging` head has been blocked by branch protection on green checks (the merge wait), and the last
head Symphony put on a `Merging` PR (any other one is a person's push). In `Merging`, a failed
`protected paths` check that the ticket's unlock decisions cover doesn't hold the head back.

## What the watcher does

Every read decides and applies the action (`SymphonyElixir.PrDecision.Apply`): Linear moves go
through the transition guard, holds through the Needs Decision hold and the self-heal lane, GitHub
calls through `SymphonyElixir.AutoMerge`. The record keeps the decision (its rule, reason, who a
wait is on and what ends it) and the actions applied in the ticket's stay in its phase. An action is
applied once per head and rule in a stay, so a repeated read never repeats a move, a rerun, an
update-branch or a fix-ticket filing; one that fails is not recorded, and the next read decides
again. The ticket's CI label (`CI green`, `CI red`, `CI running`) follows the facts.

The CI and PR review pollers decide nothing: the CI poller keeps the head it last read for a landing
agent's CI wait, and the PR review poller sends a ticket with reviewer comments back to work and
cleans up after a merged or closed PR. The orchestrator starts a `Code Review` or `QA` run only on
the decision `dispatch`, and, with auto-merge on, a `Merging` landing agent only on `land_agent`.

Some rows are recorded without an action until a later ticket applies them: a missing PR (R6), a
changed base (R7), a closed PR (R8), review comments (R13), stepping behind competing PRs (R15), a
required check that never reports (R17), a check only a person clears outside `Merging` (R18) and a
check red on the base (R23). So are the CI rows with `pull_requests.checks` off and the landing rows
(and a conflict in `Merging`) with `pull_requests.auto_merge` off.

### Silent waits

Each tick also looks for a ticket that waits with nothing under way and no reason anybody can act
on (`SymphonyElixir.PrWatch.SilentWait`). A watched ticket with an active run or a hold is never
silent, nor is one whose decision, made within the last two ticks, leaves it waiting on an owner
until something happens (`owner` and `clears_when`). Any other ticket is quiet: a decision with no
owner (such as `dispatch`) that nothing followed, no decision, or one older than two ticks. A ticket
quiet for two poll cycles in a row is silent; quiet ticks count poll intervals, not polls, so a
`poll_now` or Check Now inside an interval adds none. A wait that outlived its bound is silent too: on `ci` past
`ci.merging_wait_timeout_ms`, or on `github` still rate limited one tick past the reset.

A silent ticket is listed in `silent_waits` in `GET /api/v1/state` (its phase, since when, the last
rule, the bound that passed and why) and logs one `pr_watch.silent_wait` line when it turns silent.
It leaves the list on the first tick a run is active, a hold is set or a wait is recorded.

### The watch block and Check Now

`GET /api/v1/state` lists each watched ticket under `issues` with its `watch` block, and
`GET /api/v1/<identifier>` carries the same block: the phase, the PR `head`, how the facts arrived
(`source`), the decision (`rule`, `action`, `reason`, `owner`, `clears_when`, since when it stands,
its `outcome`), the facts in one line (`summary`) and in full (`facts`), the last five actions
applied (`actions`, each with its `source`) and the ticket's `silent` wait.
`test/fixtures/api/watch_block.json` is an example of the block, which the API's tests compare
against. `GET /api/v1/state` also carries GitHub's `rate_limit` (`remaining`, `limit`, `reset`) as the
newest read left it; with under a tenth left, the watcher's next tick waits up to four intervals, or
until the reset when that comes sooner.

`POST /api/v1/issues/<identifier>/watch/check` (Check Now) makes the ticket's watcher read and
decide at once and returns its new `watch` block; 404 when the watcher doesn't watch the ticket.
A client that sends no `Origin` header (curl, the app) may call it; a browser on another origin is
refused.

### Fix runs and their limits

A CI Fix run sent for a red head spends a **red** attempt, held against
`pull_requests.checks.max_fix_attempts` (default 10). A run sent for a conflict spends a
**conflict** attempt, against a fixed 3. A run never spends the other kind, and the run a ticket
entered CI Fix for spends no second attempt while it works there. Both counts reset only once the
PR is green **and** conflict-free: a conflicting PR keeps its last green checks, because GitHub runs
no workflow on it while it conflicts.

At the red backstop (R20) the watcher turns auto-merge off and hands the failing check to the
self-heal lane, which files one fix ticket per failing check per repo (component `ci:<check>`) or
reuses the open one, attaches each fix run's failing check and first error line, the PR and its head
as evidence, links it as a blocker and holds the ticket on it, in place. No question is asked and
the ticket doesn't move. The hold clears by itself once the fix ticket is terminal, the red count
restarts, and the head gets CI Fix runs again. The same failure reaching the backstop again after its
fix landed is the self-heal lane's own escalation to a person.

A conflict back after its 3 fix runs with no open PR ahead of it goes to `Rework` (R15a), where a
run can change as much as the conflict needs. A conflict while a PR that shares its files is ahead
in the landing order waits for that one to land (R14a), auto-merge off in `Merging`.
