# PR and CI decisions

What the PR and CI watcher does for a ticket in each phase and PR situation. The upkeep rules act
first, each one that matches; then the flow rules are checked in order and the first that matches
decides.

Upkeep keeps a PR's branch on its base (U1) and reruns a run GitHub cancelled (U2). It is not a
step in the decision chain: a Needs Decision or Blocked hold, a question, a CI wait or a competitor
wait says nothing about whether the branch should follow main, so none of them stops it, and it
never changes the flow decision taken on the same read. It waits only on a run: a verdict binds to
the head it judged, and a rework or CI Fix run pushes to the branch, so while a run is active the
upkeep is deferred and fires on the read that sees the run end (the orchestrator asks the watcher
to read at once when a run ends). The landing order stays: a PR with a PR ahead of it that changes
the same files is not updated until that one lands or leaves the race. A Code Review approval
survives the update: merging main in leaves the diff against main as it was, and a red merged head
takes the usual red paths. A GitHub merge queue may later do the final update for `Merging`; the
between-runs upkeep of the earlier phases stays useful under one.

A workflow run counts by its newest attempt only. A run with a check still queued or running is
pending, even when an earlier attempt's checks were cancelled: a rerun waiting for a runner reads
as checks running (R24, or R32 in Merging), never as a cancelled run, so U2 never reruns it.

<!-- BEGIN mix pr_decision.table: generated from SymphonyElixir.PrDecision.rules/0, do not edit by hand -->

## Upkeep

Checked first on every read of a PR, by poll or by a delivery. Every upkeep rule that matches acts, and none stops the chain: the flow rule below still decides on the same read, from the same facts. Upkeep never waits on a hold or a flow wait, only on a run: while one is active it is deferred, and it fires on the read that sees the run end.

| Rule | Phases | When | Then |
| --- | --- | --- | --- |
| U1 | all | The PR is behind main, no run is active, no PR ahead in the landing order shares its files, and the head is not red on a failure or a cancelled run; whatever the flow rule (a hold, a question, a CI or competitor wait) | `update_branch`, once per head; a conflict GitHub reports goes to the conflict rules on the next read |
| U2 | Code Review, QA, Rework, CI Fix, Merging | Red only because every run of a workflow was cancelled, its newest attempt with nothing queued or running, that run rerun fewer than 2 times on the head, and no run is active; whatever the flow rule | `rerun_failed` each new cancellation, no attempt spent |

## Rules

The flow decision: the first rule that matches decides what happens to the ticket.

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
| R18 | Code Review, QA, Rework, CI Fix, Merging | Only a check a person must clear is red (`protected paths`) | `decision`: allow the change (the option unlocks the protected paths the PR changes for the ticket), or drop the change in Rework |
| R19 | Code Review, QA, Rework, CI Fix, Merging | Red only because every run of a workflow was cancelled, its newest attempt with nothing queued or running, and that run was rerun fewer than 2 times on the head | `wait` on `ci`: the upkeep (U2) reruns each new cancellation, no attempt spent |
| R19a | Code Review, QA, Rework, CI Fix, Merging | Red only because a workflow run was cancelled again after 2 reruns on the head | `decision`: keep retrying it, or wait |
| R20 | Code Review, QA, Rework, CI Fix, Merging | Red, and the same failure 3 fix runs in a row or `red_attempts` at `max_red_attempts` | `file_fix_ticket` for the failing check, waiting on `symphony` until it is terminal |
| R21 | Code Review, QA, Rework, CI Fix, Merging | Red after a rerun | `ci_fix` for the red head, back to the phase it came from |
| R22 | Code Review, QA, Rework, CI Fix, Merging | Red, not rerun yet | `rerun_failed` once |
| R23 | Code Review, QA, Rework, CI Fix, Merging | Red, and the same check is red on the base branch | `wait` on `ci` until the base goes green |
| R24 | Code Review, QA, CI Fix | Checks are running on the head | `wait` on `ci` |
| R25 | CI Fix | Green (or no CI) and conflict-free | `return_to_origin`, approvals carried forward |
| R26 | Rework | Not red, not conflicting, no run | `dispatch` the rework run |
| R27 | Code Review, QA | Green, or no CI configured (counts as green), and not behind main with nothing ahead (the upkeep, U1, updates that one) | `dispatch` the reviewer or the QA agent |
| R28 | Code Review, QA, Merging | The PR is behind main (in Code Review and QA: with no PR ahead sharing its files) | a PR ahead shares its files: `wait` on `symphony`; otherwise `wait` on `symphony` while the upkeep (U1) updates the branch |
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
| `cancel_reruns` | `1`, `2` | `ci` is `red` and `red_kind` is `cancelled` |
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

## How to read a wait

Every decision that leaves a ticket where it is names who acts next (its owner) and what ends the
wait, so a waiting ticket is never a mystery. The app's PR and CI section, the Inbox and the
`watch` block in `/api/v1/state` show both (`owner` and `clears_when`), with the rule that decided
and since when it stands.

| Owner | Who acts next | The wait ends when |
| --- | --- | --- |
| `agent` | A run that is working, or the agent that opens the PR (R5, R8, R9) | The run ends, or the PR is opened |
| `ci` | GitHub Actions running the head's checks, or the base branch's (R19, R23, R24, R32) | The checks report, or the base goes green |
| `github` | GitHub itself: its rate limit, a mergeability it hasn't computed, branch protection (R1, R16, R33) | The limit resets, GitHub computes it, or the merge wait passes |
| `person` | A person: a Needs Decision hold, a draft PR, a question the watcher asked (R4, R6, R7, R10, R17, R18, R19a) | The decision is recorded, or the PR is marked ready |
| `symphony` | Symphony itself: a Blocked hold, a fix ticket it filed, a competing PR it waits on (R4, R14a, R15, R20, R28) | The fix ticket or the competitors are done, and the hold clears by itself |

An action Symphony carries out at once (`dispatch`, `ci_fix`, `update_branch` and the like) names
`symphony` until it is done, so the block always says who acts next. A wait with no owner that
nothing follows, or one past its bound, is reported as a silent wait (see
[Silent waits](#silent-waits)). Only `person` waits ask anything of a person, and only R6, R7, R17,
R18 and R19a ask a question. A conflict never does, and a check that keeps failing gets a fix ticket
instead (see [When CI keeps failing](#when-ci-keeps-failing)).

## Where the facts come from

The watcher reads them by polling, one watcher per repository whose pull requests are polled,
every `pull_requests.poll_interval_ms`. Each read takes the watched tickets from Linear: every
ticket in `Code Review`, `QA`, `Rework`, `CI Fix` or `Merging`, and in `In Progress` once it has a
PR, whether or not Symphony ran it. It then reads each ticket's PR in one GitHub query, the checks
its base branch requires (kept 10 minutes), whether the base branch has workflow files (only for a
head with no check at all, kept 10 minutes), the base branch's workflow runs only to tell a red head
that is also red on the base (with the jobs of a run that failed there, and the two failed logs when
the job of the same name failed too, kept 10 minutes per head job and base job), a red head's failed
log once per head (its first error line), and,
when two or more watched PRs are open or one conflicts or waits on its competitors, the
repository's open PRs and their files once: the landing order fills `ahead`, and `competing` lists
every open PR that shares a file with the ticket's, with its ticket when the watcher watches it,
leaving out one on a hold or idle two hours. Neither names a PR whose wait would close a cycle of
blocked-by links, nor one a person's `Unblock` released the ticket from, and a forced ticket has
neither.

The facts are kept on the ticket's state record and listed under each ticket's `watch.facts` in
`/api/v1/state`. A GitHub error doubles the wait between reads, up to 5 minutes; GitHub's rate
limit marks the tickets it left unread `github: rate_limited` and waits for the reset.

Before deciding, the watcher completes the read with what it keeps between reads (`attempts` on the
ticket's record): the CI Fix runs counted, the heads whose failed checks it reran, whether a rerun's
checks have reported yet (a head whose rerun hasn't reported reads as running), since when a
`Merging` head has been blocked by branch protection on green checks (the merge wait), and the last
head Symphony put on a `Merging` PR (any other one is a person's push). A failed check only a person
clears (`protected paths`) doesn't make a head red before `Merging`: when it is the only failure,
the head reads as its other checks (green once they passed, running while one runs), so the
reviewer, QA and the rework run go on and a CI Fix head returns to its origin. In `Merging`, that
check holds the head back unless the ticket's unlock decisions cover it. A check the base branch
doesn't require that GitHub cancelled beside it is set aside at once, so the head is never sent to
CI Fix or R22's rerun for the person's check; a cancelled check the base requires beside it is
rerun as a cancellation (U2). A check the base branch
doesn't require, cancelled again after U2's reruns, is set aside the same way (see
[Cancelled checks](#cancelled-checks)). The
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

A head whose only failure is `protected paths`, which only a person clears, is not red: the CI
poller records it `green` with the check under `failed_checks`, the ticket's label is `CI green`, and
the reviewer and QA run on it. Only the landing asks (R18, reached in `Merging`): **Allow the
change**, whose option unlocks the protected paths the PR changes for the ticket (the watcher reads
them with git in the ticket's workspace, and asks only once it has), or **Drop the change in
Rework**. Once the ticket's decisions cover every protected path the PR changes, the head reads as
green in `Merging` too and lands. A head with another failed check beside it is red as usual, and
its CI Fix prompt names `protected paths` as not the agent's to fix. A check that is red on the base
branch too (R23) is a wait on CI, with no CI Fix spent:
logged once per base and check, listed under `red_bases` in `/api/v1/state`, and cleared once the
base is green. A failing check counts as red on the base only when the job of the same name failed
in its workflow's latest finished run there, not when another job of that workflow did; and when the
head's failed log names failing tests (ExUnit, XCTest or pytest), only when the base's job failed
every one of them too. A head log that names no test, or a log that can't be read, leaves the
comparison by name only. The wait's reason and its log line name the base run and commit compared
and whether by tests or by name only.

### Cancelled checks

A check GitHub cancelled is never a failure: GitHub cancels a job it finds no runner for (its
annotation reads "The job was not acquired by Runner of type hosted even after multiple attempts"),
and a capacity shortage on macOS runners can cancel several workflows of one head minutes apart. A
head red only on cancelled runs is rerun by the upkeep (U2), each cancellation once, whatever hold
or wait the ticket is on: the watcher keeps, per head
and workflow run, how many times it reran the run and which cancelled jobs those reruns answered.
A second workflow cancelled on the same head is rerun as the first was, and so is a rerun GitHub
cancels again, whose new attempt has new job ids. No CI Fix attempt is spent, and R22's one rerun of
a failure is left for a real failure. While a rerun hasn't reported (its checks still cancelled, or
gone from the rollup until the new attempt queues them), the head waits on CI for it rather than
rerunning it twice, and the silent-wait detector reports that wait past its bound.

A run is rerun twice on a head. Cancelled a third time, it asks a person (R19a), naming the check
and the cause, with the ticket held in its phase: **Keep retrying** reruns the check and gives it two
more reruns before asking again; **Wait** stops rerunning it on that head, and the ticket waits until
a person reruns it on GitHub or a new head is pushed. A check the base branch doesn't require is
never a reason to hold a ticket: cancelled again after its two reruns, it is set aside, the head
reads as its other checks, and the reviewer's or QA's dispatch reason names it. A failure on such a
check still goes to CI Fix like any other, since those checks catch real regressions. Beside a real
failure, a cancelled check is rerun with it (R22) but never named as the failure, and a CI Fix run
reads only the failed checks and their logs.

The epic review reads the default branch's CI the same way: a cancelled run on the commit under
review is rerun and waited on, twice per run and commit, never spending the one rerun of a failed
run, and the review agent reads a cancelled run as not run, never as a defect to file.

## What the watcher does

Every read first applies the upkeep the facts call for, then decides and applies the flow action
(`SymphonyElixir.PrDecision.Apply`), from the same facts. The upkeep applied joins the record's last
actions, before the flow action of the same read, and logs one `pr_watch.upkeep` line. Linear moves go
through the transition guard, holds through the Needs Decision hold and the self-heal lane, GitHub
calls through `SymphonyElixir.AutoMerge`. The record keeps the decision (its rule, reason, who a
wait is on and what ends it) and the actions applied in the ticket's stay in its phase. An action is
applied once per head and rule in a stay, so a repeated read never repeats a move, a rerun, an
update-branch or a fix-ticket filing (a cancelled run's rerun, U2, is kept per cancellation instead); one that fails is not recorded, and the next read decides
again. An upkeep action GitHub refuses stays on the record (`upkeep_failure`: its rule, the head,
the error and when) until a read applies it or no longer calls for it. The ticket's CI label (`CI green`, `CI red`, `CI running`) follows the facts.

The CI and PR review pollers decide nothing in the watched phases: the CI poller keeps the head it
last read for a landing agent's CI wait, and the PR review poller keeps a PR's reviewer comments for
the run's prompt and cleans up after a merged or closed PR. The orchestrator starts a `Code Review`
or `QA` run only on the decision `dispatch`, and, with auto-merge on, a `Merging` landing agent only
on `land_agent`.

Some rows are recorded without an action: the CI rows (R17 to R22, and R18 outside `Merging`) with
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

### Silent waits

Each tick also looks for a ticket that waits with nothing under way and no reason anybody can act
on (`SymphonyElixir.PrWatch.SilentWait`). A watched ticket with an active run or a hold is never
silent, nor one the watcher acted on in this tick (a move, a rerun, a GitHub call), nor one whose
decision, made within the last two ticks, leaves it waiting on an owner
until something happens (`owner` and `clears_when`). Any other ticket is quiet: a decision with no
owner (such as `dispatch`) that nothing followed, no decision, or one older than two ticks. A ticket
quiet for two poll cycles in a row is silent; quiet ticks count poll intervals, not polls, so a
`poll_now` or Check Now inside an interval adds none. A wait that outlived its bound is silent too: on `ci` past
`ci.merging_wait_timeout_ms`, or on `github` still rate limited one tick past the reset. A ticket
whose upkeep GitHub refused on its head (`upkeep_failure`) is quiet whatever its decision waits on,
since only the next read retries the upkeep and no wait ends while it fails: an update-branch
refused on every read (a token without the `workflow` scope, for main's changes under
`.github/workflows/`) is listed after two ticks, its reason naming the rule and the error.

A silent ticket is listed in `silent_waits` in `GET /api/v1/state` (its phase, since when, the last
rule, the bound that passed and why) and logs one `pr_watch.silent_wait` line when it turns silent.
It leaves the list on the first tick a run is active, a hold is set or a wait is recorded.

### The watch block and Check Now

`GET /api/v1/state` lists each watched ticket under `issues` with its `watch` block, and
`GET /api/v1/<identifier>` carries the same block: the phase, the PR `head`, how the facts arrived
(`source`), the decision (`rule`, `action`, `reason`, who acts next (`owner`) and what clears it
(`clears_when`), since when it stands, its `outcome`), the facts in one line (`summary`) and in full (`facts`), the last five actions
applied (`actions`, each with its `source`) and the ticket's `silent` wait. `facts.protected_files`
lists the protected paths the PR's own commits change when only the `protected paths` check is red
on the head (R18), in any phase: the watcher reads them in the ticket's workspace once per head, as
`mix protected_paths.check` does, and a read that fails lists none and logs why. It is empty for any
other head. A wait names its own owner and
clearing condition; an action Symphony carries out names `symphony` until it is done (for
`dispatch`, `a run starts on the ticket`), so the block always says who acts next. The silent-wait
detector still counts only waits as recorded: a `dispatch` that no run followed stays quiet.
`test/fixtures/api/watch_block.json` is an example of the block, which the API's tests compare
against. `GET /api/v1/state` also carries GitHub's `rate_limit` (`remaining`, `limit`, `reset`) as the
newest read left it; with under a tenth left, the watcher's next tick waits up to four intervals, or
until the reset when that comes sooner.

`POST /api/v1/issues/<identifier>/watch/check` (Check Now) makes the ticket's watcher read and
decide at once and returns its new `watch` block; 404 when the watcher doesn't watch the ticket.
A client that sends no `Origin` header (curl, the app) may call it; a browser on another origin is
refused.

## When CI keeps failing

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
count ("3 of 10 CI Fix runs"), the PR and its head as evidence, links it as a blocker and holds the
ticket on it, in place, and logs `pr_watch.ci_fix_ticket`. No question is asked and the ticket
doesn't move: the wait is on `symphony` ("CI keeps failing: waiting on TP-90, a fix ticket for the
`specs` check"). The hold clears by itself once the fix ticket is terminal, the red count restarts,
and the head gets CI Fix runs again. The same failure reaching the backstop again after its fix
landed is the self-heal lane's own escalation to a person, as for any fix ticket that didn't fix
its component.

## Competing PRs

Two open PRs compete when they change a file in common. The watcher finds them in the read
described under [Where the facts come from](#where-the-facts-come-from): when two or more watched
PRs are open, or one conflicts or waits on its competitors, it lists the repository's open PRs and
their files once per tick. The landing order (`SymphonyElixir.LandingOrder`, below the table in
SPEC.md) puts the PRs that share files in line: `ahead` lists the competitors ahead of this one,
and `competing` every open PR sharing a file, with its ticket when the watcher watches it. A PR on a
hold or idle two hours drops out of both, and neither names a PR whose wait would close a cycle of
blocked-by links.

A conflict while a PR that shares its files is ahead in the landing order waits for that one to
land (R14a); a conflict back after its 3 fix runs while open PRs share its files waits on all of
them and steps behind them in the landing order, so none of them waits for it (R15). With nobody
competing, the same conflict goes to `Rework` (R15a, D16), where a run can change as much as the
conflict needs. None of them asks a person.

The wait is a visible dependency (`SymphonyElixir.PrWatch.Competitors`): auto-merge off in
`Merging`, a `Blocked` hold of the landing kind in place ("Waiting on TP-1 and PR #12 (Docs pass)
to land: they change the same files (SPEC.md)"), never a move, and a Linear blocked-by link from
each competitor's ticket that Linear doesn't have yet. A person's PR gets no link. The ticket's
record keeps the competitors under `links`, with whether Symphony added each link, and
`/api/v1/state` lists them under `watch.waits_on`. Linking logs `pr_watch.competitors_linked`.

Each read judges the wait before deciding. A competitor that lands stays linked, as history; one
that leaves the race (its PR closed, on a hold, idle two hours, or no longer sharing a file) is
unlinked when Symphony added the link, which logs `pr_watch.competitors_unlinked`. The hold clears
once no competitor is left, and the same read decides on the conflict: CI Fix, with the approvals
carried forward. The R15 wait restarts the conflict count. A person's `Unblock` clears the hold and
removes Symphony's links, and the ticket no longer waits on those PRs while they stay open; a
forced ticket waits on none.

## Replayed incidents and the skip-reason sweep

The tickets the old pollers parked until a person noticed (TP-896, TP-920/TP-892, TP-921/TP-891,
TP-886, TP-903, TP-917), two tickets racing for the same files (D14) and a check that keeps
failing (D15 (c)) are replayed as facts in `test/symphony_elixir/pr_watch/incidents_test.exs`, once
by polling only and once by GitHub's deliveries (`SymphonyElixir.PrWatchParity`). Both runs make
the same calls in the same order, and every ticket ends Done, in an action Symphony carries out, a
wait with an owner, a hold that clears by itself or a person's decision, with no person's move on
the way.

`mix pr_watch.sweep [--since 7d]` checks the table against the live log: it lists every `Skipping
dispatch` / `Not dispatching` line and `pr_watch.silent_wait` line in Symphony's log (and the
silent waits listed now), maps each to its rule, to a dispatch gate that is no PR case (`gate:
blocked by a ticket`, `gate: paused` and the like), or to `no rule`, and prints the count per rule,
then `no rule: N` and each line no rule covers. A `no rule` line is a case for a new table row.
`--log PATH` sweeps a saved log instead of this host's (`SymphonyElixir.PrWatch.Sweep`).
