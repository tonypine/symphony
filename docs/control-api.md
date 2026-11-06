# The ticket read

What `GET /api/v1/:issue_identifier` serves about one ticket, and what each entry of
`GET /api/v1/state`'s `issues` shares with it. The older fields (`status`, `pause`, `watch`) stay for
the pages that read them.

## `situation`

Where the ticket stands now: one kind from the closed vocabulary of the ticket page
(`docs/design/director-ticket-page.md`, section 3). `SymphonyElixir.Situation` computes it from the
ticket's record, its ledger and what the orchestrator holds in memory, never from Linear.

```json
{
  "kind": "waiting_for_ci",
  "word": "Waiting for CI",
  "cause": "Checks are running on PR #741.",
  "next": "Code Review starts when they pass.",
  "since": "2026-10-30T16:39:00Z",
  "waits_on": { "pr": 741, "check": null },
  "and_more": 0,
  "step": null,
  "run": null,
  "retry": null
}
```

| Field | What it holds |
| --- | --- |
| `kind` | One of the kinds below. |
| `word` | The pattern's first words, as the situation line shows them. |
| `cause` | One sentence of fact, at most 300 characters. |
| `next` | What moves it next; null once the ticket ended. |
| `since` | When this situation began, ISO 8601; null when no fact says. |
| `waits_on` | What it waits on, by kind (below); null when nothing names it. |
| `and_more` | The pause's further reasons, which `pause` lists. |
| `step` | For `working` when a step is open: `id`, `title`. |
| `run` | For `working`: `id`, `kind`, `number`, `label` (`Implementation run 2`). |
| `retry` | For `retrying`: `try`, `of` (null past the limit), `at` (ISO 8601). |

When more than one holds, the first in this order is the situation:

| `kind` | `word` | `waits_on` |
| --- | --- | --- |
| `waiting_on_you` | Waiting on you | `question_id`, or `phase` for a plan in review |
| `retrying` | Retrying | null |
| `blocked_by_ticket` | Blocked by TP-n | `ticket` |
| `paused_by_rule` | Paused | the pause reason's own |
| `waiting_for_ci` | Waiting for CI | `pr`, `check` |
| `waiting_for_build` | Waiting for a build | the pause reason's own |
| `waiting_for_slot` | Waiting for a slot | `slot`: why the slot is taken |
| `working` | Working on the *step* step | `step`, `run_id` |
| `done` | Shipped | null |
| `cancelled` | Cancelled | null |

Some tickets have no kind of their own in the design, and read the closest one:

- A ticket nothing holds and no run works on reads `waiting_for_slot`, with the PR watcher's reason
  as its cause when it has one.
- A plan in `Plan Review` reads `waiting_on_you`.
- A parent in `Waiting on sub-tickets` reads `blocked_by_ticket` on its first open sub-ticket.
- A ticket in `Backlog`, or one a rule passed over at dispatch (Symphony's or its repository's pause,
  the usage limit, a spent token budget, the priority filter, a reviewer turned off), reads
  `paused_by_rule`, unless a run works on it. Any other skip (a run on it, CI, its own pause) is told
  by what it waits on.
- A ticket waiting for a slot while Symphony is paused reads `paused_by_rule`.
- A `Merging` ticket held until CI settles reads `waiting_for_ci`.

## The `situation.changed` event

When the kind changes, Symphony records one `situation.changed` event on the ticket's ledger, never
on a read: `from` (none on the first), `to`, `word`, `cause` and `since`. A timeline tells how long a
situation lasted from the time of this event and of the next.

## `lifecycle`

Where the ticket is on its way to landing: the five stages in order and its tokens against its cap.
`SymphonyElixir.Lifecycle` computes it from the `phase.entered`, `run.started` and `run.ended` events
of the ticket's ledger, never from Linear's state history.

```json
{
  "current": "code_review",
  "stages": [
    { "id": "coding", "name": "Coding", "state": "passed", "visits": 1, "time_ms": 2340000, "agent_time_ms": 2280000, "tokens": 2400000 },
    { "id": "code_review", "name": "Code Review", "state": "current", "visits": 2, "time_ms": 3120000, "agent_time_ms": 1020000, "tokens": 1200000 },
    { "id": "qa", "name": "QA", "state": "not_yet", "visits": 0, "time_ms": 0, "agent_time_ms": 0, "tokens": 0 },
    { "id": "merging", "name": "Merging", "state": "not_yet", "visits": 0, "time_ms": 0, "agent_time_ms": 0, "tokens": 0 },
    { "id": "done", "name": "Done", "state": "not_yet", "visits": 0, "time_ms": 0, "agent_time_ms": 0, "tokens": 0 }
  ],
  "tokens": { "total": 3600000, "cap": 8000000 }
}
```

| Field | What it holds |
| --- | --- |
| `current` | The `id` of the stage the ticket is in; null in a phase outside the stages and once it is Done. |
| `stages[].id`, `name` | `coding` (In Progress), `code_review`, `qa`, `merging`, `done`, always these five in this order. |
| `stages[].state` | `current`; `passed`: a stage behind the current one that it entered; `skipped`: a stage behind the current one that it never entered; `not_yet`: the stages ahead. Done reads `passed` once reached. |
| `stages[].visits` | How many times the ticket entered the stage. |
| `stages[].time_ms` | Wall time in the stage, summed over its visits, up to now for the phase it is in. Pauses count. Done takes none. |
| `stages[].agent_time_ms` | How long the ended runs of the stage ran. |
| `stages[].tokens` | The tokens of the ended runs of the stage. |
| `tokens.total` | The tokens of the ticket's ended runs: the stages' `tokens` add up to it. |
| `tokens.cap` | The ticket's cap, `agent.limits.tokens_per_issue`; null when there is none. |

Rework and CI Fix have no stage of their own; they count as visits of the stage they serve:

- Rework serves Code Review, the stage it hands back to, whichever stage sent it back. A ticket in
  Rework for the first time reads Code Review as `current` with `visits` 2.
- CI Fix serves the stage it interrupted: Code Review, QA or Merging.
- Each move into Rework or CI Fix is one visit. The move back out of them into the stage they serve
  is the same visit going on.
- A stage the ticket left going backwards reads by where it is now: QA reads `not_yet`, with its
  earlier visits, while the ticket is back in Code Review.

A run belongs to the stage the ticket was in when it started, so the work a Rework run does counts in
Code Review. A run that started outside any stage counts in Coding: a first run starts just before
its move out of Todo, and a plan run or an epic review never enters a stage. A run still working joins
the numbers when it ends.

Code Review, QA and CI Fix go by the names the repository configures (`issues.states.code_review`,
`qa` and `ci_fix`); In Progress, Rework, Merging and Done are fixed. A stage's `id` and `name` stay the
same under a renamed phase, and `phase_path` shows the phase's own name. An event naming a phase by a
name it no longer has counts as a phase outside the stages.

A phase outside the stages (Backlog, Todo, Plan Review, Waiting on sub-tickets, Epic Review, a
cancelled ticket's) adds to no stage. With nothing current, the stages up to the last one entered
read `passed` or `skipped`.

## `phase_path`

The phases the ticket went through, for the Phase path component and the timeline's phase moves.

```json
{
  "current": "Rework",
  "phases": [
    { "phase": "In Progress", "count": 1, "time_ms": 2340000, "first_entered_at": "2026-10-30T15:23:00Z" },
    { "phase": "Code Review", "count": 1, "time_ms": 2160000, "first_entered_at": "2026-10-30T16:02:00Z" },
    { "phase": "Rework", "count": 1, "time_ms": 960000, "first_entered_at": "2026-10-30T16:38:00Z" }
  ],
  "moves": [
    { "from": "Todo", "to": "In Progress", "at": "2026-10-30T15:23:00Z" },
    { "from": "In Progress", "to": "Code Review", "at": "2026-10-30T16:02:00Z" },
    { "from": "Code Review", "to": "Rework", "at": "2026-10-30T16:38:00Z" }
  ]
}
```

| Field | What it holds |
| --- | --- |
| `current` | The phase the ticket is in, as the last `phase.entered` names it; null before any. |
| `phases` | Each phase once, in the order it first entered each. |
| `phases[].count` | How many `phase.entered` events name it, so a return from CI Fix counts. A second event naming the phase it is already in is no move. |
| `phases[].time_ms` | Wall time in the phase, summed, up to now for the phase it is in. A terminal phase takes none. |
| `moves` | Every move, oldest first, with its time. `from` is what the event says, else the phase before it; null on a first move that does not say. |

## `moves`

What the Director can do with the ticket now, each move saying why when it can't, so the app disables
it with a tooltip and computes nothing. `SymphonyElixir.TicketMoves` answers from the record and what
the orchestrator holds in memory, never from Linear, and the control call refuses with the same guard
and the same words. The older `start` field is `moves.start`, with the same shape.

```json
{
  "start": { "allowed": false, "reason": "A run is already working on it." },
  "stop": { "allowed": true, "reason": null },
  "move_to": { "allowed": true, "reason": null, "states": ["Backlog", "Todo", "Rework", "Done"] }
}
```

| Field | What it holds |
| --- | --- |
| `allowed` | Whether the move may be made now. |
| `reason` | Why it may not, in the app's words, verbatim as the call refuses; null when allowed. |
| `states` | On `move_to` only: the phases the free move may name now, every phase of the workflow but the one the ticket is in; empty when refused. |

| Move | Control call | Refused when | Example `reason` |
| --- | --- | --- | --- |
| `answer` | `/decide` with the `question_id` of one of `open_questions` | no Question is open | TP-1 is not waiting on a decision |
| `start` | `/start` | Backlog, closed, its plan waits on a person, it waits on its sub-tickets, Symphony or the repository is paused, a Question is open, a run works on it | A run is already working on it. |
| `stop` | `/stop` | no run works on it | No run is working. |
| `restart` | `/restart` | closed, or no record | The ticket is done. |
| `cancel` | `/cancel` | closed, or no record | The ticket is done. |
| `move_to` | `/move` | in no repository, or no record | The ticket is not one Symphony tracks. |
| `force` | `/force` | closed, already forced, or no record | It is already forced. |
| `unforce` | `/force` with `clear` | not forced, or no record | It isn't forced. |
| `unblock` | `/unblock` | nothing a person can release | TP-1 has nothing a person can unblock |
| `note` | `/note` | no record | No ticket TP-1 in symphony |
| `blocker` | `/blocker` | no record, or removed in Linear | Symphony doesn't track TP-1, so it can't be linked as a blocker or be given one. |
| `priority` | `/priority` | no record, or removed in Linear | Symphony doesn't track TP-1, so it can't set its priority. |
| `labels` | `/label` | no record, or removed in Linear | Symphony doesn't track TP-1, so it can't change its labels. |
| `ruling` | `/decision` | no record, or removed in Linear | Symphony doesn't track TP-1, so it can't record a decision on it. |
| `approve_plan` | `/approve_plan` | not a plan, not in Plan Review, or the waiting state is off | TP-1 is not a plan; approve_plan is for a plan |
| `rework` | `/rework` | not in Plan Review | TP-1 is In Progress; the Director answers it only from Plan Review |
| `decisions` | `/decisions` | not a plan, or not in Plan Review | TP-1 is not a plan; decisions is for a plan |
| `changes` | `/changes` | not a plan, or not in Plan Review | TP-1 is not a plan; changes is for a plan |
| `backlog` | `/backlog` | closed, already in Backlog, or no record | TP-1 is already in Backlog |

A closed ticket's reason names its phase: `The ticket is done.`, `The ticket is cancelled.`

What the read and the call each answer for:

- A move the read allows is not refused for the ticket's state. A call may still fail on what no
  record says: Linear refusing a write, a label or state the team doesn't have.
- `stop`, `force` and `unforce` never refuse the state the read calls not allowed: the call answers
  200 with nothing done (`stopped: false`, the label as it was). A closed ticket's `force` is refused.
- A call refuses on its own argument, which is no fact of the ticket: a phase the workflow doesn't
  name (`states` lists those it does), a blocker that is the ticket itself, already linked, finished
  or making a cycle, a label already on or off, the priority it already has, a ruling already recorded,
  a Question closed since. Empty input (`Write a note first.`) is the app's own.
- A call judges the ticket as Linear last answered it where it reads Linear, the read as the record
  holds it, so the two can part only while Linear lags a move.
- `/undo` is no entry: the move it takes back answers with its `undo_window_ms`, and the app offers it
  for that long.

## `pull_request`

The ticket's pull request and its checks, for the Pull request panel (facts 9 and 10 of
`docs/design/director-ticket-page.md`); null before the watcher has read one. It makes no GitHub read
of its own: the PR and CI watcher keeps what its one read of the PR says
(`SymphonyElixir.PrWatch.Snapshot`) on the ticket's record, so it changes on the watcher's triggers
(a webhook delivery's confirm read, the timed poll, Check Now) and it stays once the watch ends: a
merged ticket still reads its PR.

```json
{
  "number": 741,
  "url": "https://github.com/acme/app/pull/741",
  "title": "TP-1244 The paused line on the ticket page",
  "state": "open",
  "draft": false,
  "head_sha": "8b03e51c0ffee0123456789abcdef0123456789a",
  "head_short": "8b03e51",
  "base": "main",
  "mergeable": "clean",
  "behind_base": false,
  "review_state": "changes_requested",
  "review_rounds": 2,
  "files_changed": 9,
  "additions": 486,
  "deletions": 52,
  "checks": [
    {
      "workflow": "CI",
      "checks": [
        {
          "name": "Tests",
          "state": "failed",
          "started_at": "2026-11-06T10:00:00Z",
          "duration_ms": 372000,
          "url": "https://github.com/acme/app/actions/runs/100/job/1",
          "required": true
        }
      ]
    }
  ],
  "red_kind": "failure",
  "next_action": {
    "rule": "R22",
    "action": "rerun_failed",
    "reason": "Tests failed on PR #741: rerunning it once before CI Fix",
    "owner": "symphony",
    "clears_when": "the failed checks run again",
    "since": "2026-11-06T10:06:30Z",
    "outcome": "applied"
  },
  "read_at": "2026-11-06T10:06:30Z"
}
```

| Field | What it holds |
| --- | --- |
| `state` | `open`, `merged` or `closed`. A PR Symphony saw close or merge after the last read says so. |
| `draft` | Whether an open PR is a draft. |
| `head_sha`, `head_short` | The head the read saw, in full and its first seven characters. |
| `base` | The branch it merges into. |
| `mergeable` | `clean`, `behind`, `dirty` (conflicts), `unstable`, `blocked` or `unknown`. |
| `behind_base` | Whether GitHub reads it as behind its base (`mergeable` is `behind`). |
| `review_state` | `merged` or `closed`, else GitHub's review decision (`approved`, `changes_requested`), else the newest Code Review verdict, else `open`. |
| `review_rounds` | How many heads Code Review judged. |
| `files_changed`, `additions`, `deletions` | The PR's size. |
| `checks` | The head's checks grouped by workflow, in the order GitHub lists them. `workflow` is null for a status from outside GitHub Actions. |
| `red_kind` | Why the head is red, as the watcher reads it: `failure`, `cancelled`, `human_only`, `also_red_on_base` or `run_in_progress` (`docs/pr-ci-decisions.md`); null when it isn't, or the watcher doesn't watch the ticket. |
| `next_action` | What the watcher decided on its last read, with the `watch` block's words: `rule`, `action`, `reason`, `owner`, `clears_when`, `since`, `outcome`. Null without a decision, or when the watcher doesn't watch the ticket. |
| `read_at` | When the watcher read it. |

Each check is the newest run of that name in its workflow: the watcher's dedupe has already dropped
superseded runs and earlier attempts, and a check every run of the workflow left cancelled is listed
once.

| Field | What it holds |
| --- | --- |
| `name` | The check. |
| `state` | `passed` (also a neutral result), `failed`, `running`, `waiting`, `skipped` or `cancelled_no_machine`. |
| `started_at` | When it started; null before it does. |
| `duration_ms` | How long it took; null until it finishes. |
| `url` | Its log. |
| `required` | Whether the base branch requires it; null while the watcher doesn't know: it reads what a base requires only once a head has no real failure, and keeps it 10 minutes. |

GitHub says only `CANCELLED` of a job that never got a machine, and the watcher treats every cancelled
check that way (reruns it, spends no fix run), so `cancelled_no_machine` never reads as `failed`.
