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

For now the watcher only gathers facts: no rule is applied, and the CI and PR review pollers still
decide and act.
