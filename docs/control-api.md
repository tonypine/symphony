# The ticket read

What `GET /api/v1/:issue_identifier` serves about one ticket, and what each entry of
`GET /api/v1/state`'s `issues` shares with it. The older fields (`status`, `pause`, `watch`) stay for
the pages that read them.

## `ticket`

The ticket itself, as its record holds it: the same values the ticket list's `title`, `phase`,
`priority` and `labels` columns serve (`GET /api/v1/tickets`, below), so a client reads one ticket's
title without listing every ticket.

```json
{ "title": "Undo a Director move within ten seconds", "phase": "Rework", "priority": 1, "labels": ["qa:live"] }
```

| Field | What it holds |
| --- | --- |
| `title` | The ticket's title; null when Symphony holds no record of it. |
| `phase` | The phase (state) the record says it is in, also when its ledger holds no `phase.entered` and `phase_path.current` is null. |
| `priority` | Linear's priority: 0 none, 1 urgent, 2 high, 3 medium, 4 low; null when unknown. |
| `labels` | The ticket's labels; `[]` when it has none. |

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
| `current` | The phase the ticket is in, as the last `phase.entered` names it; null before any (`ticket.phase` says it from the record). |
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

## `connected`

Where the ticket sits among the others, for the Connected panel (facts 15, 16 and 21 of
`docs/design/director-ticket-page.md`). A ticket with a record, or one the orchestrator tracks, has it;
it reads the records, the ledgers, what the orchestrator holds and the cached Initiatives, never Linear
(`SymphonyElixir.Connected.Read`).

| Field | What it holds |
| --- | --- |
| `epic` | The plan the ticket is part of, below; null when it has none, and on a plan ticket itself. |
| `parent` | The parent as the run's read saw it: `identifier`, `title`, `done`, `total` and `children`, the sub-tickets' state types. Null before a read gave it. |
| `sub_tickets` | The ticket's own sub-tickets: `identifier`, `title` and `state`. |
| `blocked_by` | Every blocker ever linked, below. |
| `blocks` | The tickets it holds up, below. |
| `related` | The related links of a tracked ticket: `identifier`, `title` and `state`. A ticket the orchestrator no longer tracks has none: its record does not keep them. |

A `title` and a `state` come from the other ticket's record when Symphony has one, otherwise from the
link, where each may be null.

### `epic`

| Field | What it holds |
| --- | --- |
| `identifier`, `title` | The plan ticket. |
| `done`, `total` | Its progress: sub-tickets completed, of all of them but the canceled ones. It equals the same plan's count on `GET /api/v1/initiatives`, which reads the same cache. |
| `incomplete` | Whether Linear had more sub-tickets than the read returned, as on the Initiatives. |
| `tickets` | The sub-tickets in chain order: `identifier`, `title`, `state`, `situation` (the kind of its `situation`, null without a record) and `current`, true on this ticket. |

A plan the Initiatives don't hold (done more than 7 days ago, without the `plan` label, or right after a
start, before their first read) comes from the parent's record: its sub-issues in creation order,
counted by state, where `Done` is done and any other terminal state leaves it out. With no record of the
parent, `done` and `total` are the parent's own and `tickets` is empty.

### `blocked_by`

Each entry is one blocker, in the order they were first linked:

| Field | What it holds |
| --- | --- |
| `identifier`, `title`, `state` | The blocker. |
| `status` | `open` or `resolved`. |
| `resolved_at` | When it resolved: the time its dependency reason left the pause; null while `open`, and on a blocker that was already done when it was linked. |

It comes from the ledger: a dependency reason's `pause.set` or `pause.reason_added` opens the blocker, and
`pause.reason_cleared` or `pause.cleared` resolves it. The record's `blockers` keep holding only the open
ones, for dispatch, so a Done blocker stays here and the page can strike it through. Three cases go beyond
the events:

- A link the ticket has with no reason (it was linked while no active phase held the ticket) reads `open`
  until its blocker ends.
- A reason still set reads `open` even when its blocker landed: the ticket still waits, for the app to
  include it.
- A reason cleared while its blocker is still open and no longer linked was unlinked, not resolved, and the
  entry leaves the list.

### `blocks`

The links the run read and the tickets whose records name this one as an open blocker: `identifier`,
`title`, `state` and `situation`, the kind of the held ticket's `situation`, null without a record. A ticket
that ended holds nothing up.

## Marks

What is new since the person last looked, and the note for the next run (facts 6 and 18 of
`docs/design/director-ticket-page.md`; `SymphonyElixir.Marks`):

| Field | What it holds |
| --- | --- |
| `looked_at` | When the person last looked at the ticket, set by `POST /api/v1/control/looked`; null when they never did. |
| `new_since_looked` | How many of the ticket's events are later than `looked_at`; every event when it is null. |
| `note` | The note for the next run, null when no person left one: the newest `note` event a person wrote, as `id`, `text`, `at` (when it was set), `by` and `read_by`. |
| `note.read_by` | The first run whose prompt carried the note, as `run_id` and `at`; null until a run read it. A newer note replaces the note, and its `read_by` starts null again. |

`POST /api/v1/control/looked` takes `issue_identifier` and an optional `repo_key`, and needs the control
token. It writes the mark on the ticket's record, keyed by person (the Director, the one person the token
names today). It is a view mark, not history: no ledger event records it. It answers `200`
`{"issue_identifier", "looked_at", "new_since_looked": 0}`, `404` `ticket_not_found` for a ticket with no
record (also when the record goes before the mark is written), `502` `store_error` when the store refuses
the write, and `422` without `issue_identifier`.

Each event of the events feed (`GET /api/v1/repos/:repo_key/tickets/:issue_identifier/events`, with or
without `group=run`) carries `new`: `true` when it is later than the mark, or the person never looked.

The Director sends the look when the person leaves a ticket page they had in front for at least two
seconds: another place in the window, the window closing, or the app quitting. It never sends it on
opening the page or from a read, so a page kept open keeps the `looked_at` it opened with: its line
"Since you last looked" stays where it was for the visit, while each new event still comes `new` and gets
its dot. A first visit (`looked_at` null) shows no line, no dots and no count, although the feed calls
every event new then.

A run reads the note when the prompt it builds carries the ticket's history summary, which holds every
note in full. Symphony then records a machine `note.read` event naming the note (`note_id`) and the run
(`run_id`), keyed by the note, so only the first read is kept. A preview of the prompt records nothing.

## `brief`

What the ticket does and why, in a person's words, with its walkthrough (fact 25 of
`docs/design/director-ticket-page.md`; `SymphonyElixir.TicketBrief`). Null until a run wrote one.

| Field | What it holds |
| --- | --- |
| `brief.id` | The id of the `brief.written` event it comes from. |
| `brief.text` | What the ticket does and why, in plain words: at most 1,200 characters, no backtick. |
| `brief.walkthrough` | The steps a person takes to see it work, as prose: at most 4,000 characters, no backtick. |
| `brief.at` | When it was written. |
| `brief.by` | Who wrote it: `kind` (`agent`), `run_kind` and `run_id`. |

An implementation, rework or review-feedback run writes it with `ticket_record` as a `brief.written` event:
at its first delegated step, and again at its handoff when the work changed what the ticket does. The newest
`brief.written` is the brief; the earlier ones stay in the ticket's history. The catalog refuses a brief
over its bounds or holding a backtick, and from any other run kind, the machine or a person. Linear's
description is left as it is. The summary of the ticket's history that every run's prompt carries opens
with the brief, in full, under `Brief`.

## `running`

The live run, null when none is. Beside the run's session, workspace and tokens, it says what the run is
doing now, for the run in place on the ticket page (facts 4, 8 and 13 of
`docs/design/director-ticket-page.md`; `SymphonyElixir.PhaseSteps.Transcript`):

| Field | What it holds |
| --- | --- |
| `current_step` | The step the run started and has not ended, from its `step.started` on the ledger: `id`, `title`, `mode` and `started_at`. Null between steps and on a run with no step list. |
| `recent_lines` | The newest lines of that step, oldest first and at most 20, from the session stream the orchestrator buffers for the run (the transcript window reads the same stream and is unchanged). Each is a line as below; a tool line carries only the tool's name, since the stream holds no arguments. Empty when `current_step` is null. |

Once a step ends, its whole slice of the session transcript is a `transcript` artifact on its
`step.completed`, served by `GET /api/v1/artifacts/:id` like any other, so the Director's timeline unfolds
the step from the ledger. It is JSON lines (`text/x-ndjson`), one object a line:

| Field | What it holds |
| --- | --- |
| `kind` | `say` (what the agent said), `tool` (a call: the tool's name and its arguments summarised, the command, path, pattern or query when it has one, else its input as JSON) or `result` (what the call returned, summarised). |
| `text` | The line, its whitespace folded and bounded: 4,000 characters for what the agent said, 300 for a call's arguments, 500 for a result. |
| `at` | When the entry was written; absent when the transcript gave no time. |
| `duration_ms` | On a result, how long its call took. |
| `failed` | `true` on a result whose call failed. |

A step's slice holds the lines of every turn it ran (a retry adds to them), cut only at whole entries, so a
session's slices concatenated are the lines of its whole transcript. A machine step has no slice, a turn that
said nothing leaves none, and a session Symphony reads no transcript of (Codex's, or one on another host)
has none.

# The dispatch order

`GET /api/v1/dispatch/order`, and `order` on `GET /api/v1/state`: every open ticket Symphony works,
grouped by the kind of its `situation`, and the dispatch candidates in the order the dispatcher starts
them, each with the reason it is or is not next (`SymphonyElixir.Dispatch.Order`).

The orchestrator walks the poll's candidates at the end of each poll cycle, after the cycle's dispatch
pass, in the order the pass walks them (forced first, then closest to done, each epic lane's tickets
nearest the epic, then priority and age) and through the pass's own gates and slot decision. A ticket a
pass run now would start takes its slot for the tickets after it. The read is recomputed on the
triggers a poll cycle runs on and never on a timer of its own; it
makes no Linear request.

```json
{
  "generated_at": "2026-11-09T22:00:00Z",
  "computed_at": "2026-11-09T21:59:58.120Z",
  "next": "TP-1401",
  "slots": {
    "concurrency": { "max_total": 2, "finishing_max": 1, "forced_max": 1 },
    "work_used": 1,
    "work_free": 1,
    "forced_used": 0,
    "finishing": { "slots": 1, "used": 0, "running": [] },
    "epic_lanes": { "max_total": 2, "lanes": [], "queued_epics": [], "shared": { "slots": 2, "used": 1 } }
  },
  "queue": [
    { "identifier": "TP-1401", "position": 1, "outcome": "starts", "reason": "next: a slot is free", "slot": "shared", "starts_now": true, "...": "..." },
    { "identifier": "TP-1402", "position": 2, "outcome": "waits", "reason": "2nd: behind TP-1401", "wait": "work slots full", "starts_now": false, "...": "..." }
  ],
  "groups": [
    { "kind": "blocked_by_ticket", "count": 1, "tickets": [{ "identifier": "TP-1408", "outcome": "held", "reason": "Waiting for TP-1399 to finish", "...": "..." }] },
    { "kind": "waiting_for_slot", "count": 2, "tickets": ["..."] }
  ]
}
```

| Field | What it holds |
| --- | --- |
| `computed_at` | When the orchestrator walked the candidates; null before its first poll cycle. |
| `next` | The identifier of the ticket first in line; null when none is. |
| `slots` | The slot and lane facts the walk read: `concurrency` (the limits), `work_used` and `work_free` (of `max_total`), `forced_used`, `finishing` and `epic_lanes` as the state gives them. |
| `queue` | The tickets in line, by `position`. |
| `groups` | Every open ticket exactly once: each walked candidate, and every ticket record neither removed nor in a terminal state. The groups follow the situation kinds' precedence and hold only kinds some ticket has; within one, tickets in line come first by `position`, then the rest by identifier. |

Each ticket, in `queue` and in `groups`:

| Field | What it holds |
| --- | --- |
| `issue_id`, `identifier`, `title`, `state`, `repo_key` | The ticket. |
| `outcome` | `starts` (a pass run now starts it), `waits` (it waits for a slot), `paused` (its gates are open but the whole pass is paused), `held` (a gate keeps it out of the pass), `running` (a run works on it) or `not_a_candidate` (an open ticket the poll does not offer for dispatch: Backlog, a plan in review, a parent waiting on its sub-tickets). |
| `position` | Its place in line, 1 for the next one; null for `held`, `running` and `not_a_candidate`. |
| `reason` | `next: a slot is free`; `next: ` and why it waits (`next: work slots full`); `2nd: a slot is free` for a later one a pass run now starts too; `2nd: behind TP-n` for a later one that waits; `forced` for a forced ticket that starts on its own allowance; the pause's line for a paused one (`dispatch is paused: updating to v0.0.1.825`); the gate's reason for a held one (`Waiting for TP-1399 to finish`); `already running` for a running one; the situation's `cause` for one that is not a candidate. |
| `wait` | For `waits`: why it waits (`work slots full`, `finishing slots full`, `TP-n (Merging) is waiting for a finishing slot`). |
| `rule` | The rule behind a `held` or `paused` ticket (`priority`, `usage_limit`, `symphony_pause`, `daily_budget`...), as `dispatch_skipped` names it; null when no rule is. |
| `slot` | For `starts` and `running`: the slot it takes (`forced`, `finishing`, `shared` or its epic lane). |
| `forced` | Whether the ticket is forced. |
| `starts_now` | `true` for `starts`. |
| `situation` | The ticket's `situation`, as the ticket read gives it. |

The read answers `200` with `error` (`snapshot_timeout`, `snapshot_unavailable`) when the orchestrator
can't be read, as `GET /api/v1/state` does.

# The events across tickets (the Journal)

`GET /api/v1/events?since=&until=&repo=&epic=&classes=&notable=&limit=`: the events of every ticket,
and of Symphony's own stream (its pauses and questions), newest first and paged
(`SymphonyElixir.TicketEvents.Journal`). It reads Symphony's store only and makes no Linear request.

```json
{
  "events": [
    {
      "id": "01JC…", "at": "2026-11-09T14:02:11Z", "type": "rule.action", "phase": "Code Review",
      "summary": { "title": "PR watcher R22 reran the failed checks", "detail": "A check failed on PR #741…" },
      "ticket": { "repo_key": "symphony", "identifier": "TP-1401", "title": "The situation read model" },
      "class": "rule", "notable": true, "by": { "kind": "rule", "name": "PR watcher R22" },
      "...": "the ticket feed's other fields"
    }
  ],
  "next_until": "2026-11-09T13:40:00Z"
}
```

| Parameter | What it does |
| --- | --- |
| `since`, `until` | ISO 8601; keep the events after `since` and before `until` (both exclusive). |
| `repo` | A repository's key: its tickets' events, and Symphony's own (they hold every repository). |
| `epic` | An epic's identifier: the epic's own events and its sub-tickets'. Symphony's own are left out. |
| `classes` | Comma-separated: `finding`, `move`, `note`, `pause`, `person`, `question`, `rule`, `run`, `situation`, `ticket`, `verdict`. |
| `notable` | `true` (the default): the notable events only; `false`: every event. |
| `limit` | Default 50, at most 200. A page never ends inside a group of events that share one `at`. |

Each event is the ticket feed's event (`GET /api/v1/repos/:repo_key/tickets/:id/events`) with:

| Field | What it holds |
| --- | --- |
| `ticket` | `repo_key`, `identifier` and `title` from the ticket's record; null fields on Symphony's own stream. |
| `class` | The event's class, as `classes` filters it; `other` for a type no class names. |
| `notable` | Whether a rule of the notable rule set holds for it (below). |
| `by` | Who did it: `{kind, name}`, `kind` one of `symphony`, `rule` (`name` the rule: `CI wait`, `PR watcher R22`, `Self-heal`), `person` (the Director) or `run` (`name` its kind, with its `run_id`). |

`next_until` is the `at` the next, older page passes as `until`; null on the last page. A `since` or
`until` that is not ISO 8601, an unknown class, a `notable` other than `true` or `false` or a `limit`
that is not a positive integer answers `400` `invalid_query`.

## The notable rule set

An event is notable when one rule holds for it (`SymphonyElixir.TicketEvents.Notable`): a verdict; a
phase entered, or a person's move or cancel; a question asked or answered; a ticket's pause that
lasted at least 15 minutes (or has, so far); a `rule.action`; a fix ticket self-heal filed or a ticket
split off (`ticket.filed`); a ticket shipped (entered Done) or cancelled; a release installed
(Symphony's pause lost an update's build reason); the factory paused or resumed (Symphony's own pause
set or cleared); a `situation.changed` to `waiting_on_you`, `retrying` or `blocked_by_ticket`.

## The `rule.action` event

Each time a rule of Symphony's acts on a ticket, the ledger records one `rule.action`
(`SymphonyElixir.RuleActions`): `rule` (its name), `action` (`rerun`, `paused`, `parked`,
`filed_ticket`, `lifted_pause`, `moved`, `updated_branch`, `auto_merge`, `asked`, `other`), `text`
(its line in plain words) and `filed` (the ticket it filed). The writers are each action the PR and CI
watcher applied (`PR watcher R22`), a pause reason a rule set or lifted (`CI wait`, `Release build
watch`, `Blocked-by links`, `Self-heal`, the update and instructions holds), the dispatch-loop guard,
the idle park and self-heal's new fix ticket. Its summary names the rule: "CI wait paused the
ticket". The audit records the rules write stay as they are.

# The aggregation read (Insights)

`GET /api/v1/aggregate?from=&to=&unit=30m|1h|6h|day|week&repo=&epic=&series=`: the numbers the
Insights pages (Quality, Usage and Shipped) draw, as series bucketed by period and unit, kept to a
repository and an epic (`SymphonyElixir.Aggregate`). It reads the run records' token counts and the
tickets' events from Symphony's store, writes nothing and makes no Linear request. The pages' older
reads (`/api/v1/history`, `/api/v1/shipped`, `/api/v1/runs`) stay until the pages move to this one.

```json
{
  "generated_at": "2026-11-09T20:00:00Z",
  "from": "2026-11-03T00:00:00Z",
  "to": "2026-11-10T00:00:00Z",
  "unit": "day",
  "repo": null,
  "epic": "TP-1400",
  "series": {
    "tokens": {
      "total": 477,
      "by": { "anthropic": 427, "openai": 50 },
      "tickets": { "TP-1401": 420, "TP-1402": 50, "TP-1400": 7 },
      "buckets": [
        { "start": "2026-11-03T00:00:00Z", "end": "2026-11-04T00:00:00Z", "value": 0, "by": {} },
        { "start": "2026-11-04T00:00:00Z", "end": "2026-11-05T00:00:00Z", "value": 120, "by": { "anthropic": 120 } }
      ]
    },
    "shipped": {
      "total": 1, "by": { "symphony": 1 }, "tickets": { "TP-1401": 1 },
      "buckets": [{ "start": "2026-11-06T00:00:00Z", "end": "2026-11-07T00:00:00Z", "value": 1, "by": { "symphony": 1 }, "tickets": ["TP-1401"] }]
    }
  }
}
```

| Parameter | What it does |
| --- | --- |
| `from`, `to` | ISO 8601 times or dates. A date `from` starts at its midnight; a date `to` takes in its whole day; a time `to` is exclusive. The period widens to whole buckets, and `from` and `to` in the answer are its bounds. Default: the 7 days that end with the bucket holding now. At most 366 days and 5000 buckets. |
| `unit` | `30m`, `1h`, `6h` (from UTC midnight), `day` (UTC midnight, the day the daily token budget resets on) or `week` (from Monday's UTC midnight). Default `day`. |
| `repo` | A repository's key: its runs and its tickets. |
| `epic` | An epic's identifier: the epic and the tickets whose record names it as parent (a run whose ticket has no record counts when its identifier is the epic's). |
| `series` | Comma-separated names (below); default all of them. |

Every series has its `total` over the period, that total `by` the series' key and by ticket
identifier (`tickets`), and one bucket per unit of the period, empty ones at `value` 0 with an empty
`by`:

| Series | Value | `by` | Source |
| --- | --- | --- | --- |
| `tokens` | Tokens (the run's and its reviewer's), at the run's start. | Provider: the run's, else the one its model names. | Run records, as `/api/v1/history`'s `tokens_per_day`: a day's bucket equals that day's `total_tokens` and `providers`. |
| `time_by_stage` | Milliseconds tickets spent in a stage, a stay split across the buckets it overlaps; the phase a ticket is in runs to now. | Stage id (`coding`, `code_review`, `qa`, `merging`), as the ticket read's `lifecycle` counts them. | The ledger's `phase.entered`. |
| `runs` | Runs started. | The status the run record ends with (`success`, `failure`, `timeout`, `stopped`...; `unknown`). | Run records. |
| `verdicts` | Verdicts recorded. | `kind:outcome` (`code_review:approve`, `qa:fail`). | The ledger's `verdict.recorded`. A day's `code_review:approve` is the approvals `/api/v1/history`'s `review` judges that day. |
| `shipped` | Tickets merged: one per ticket, at its latest completion Symphony noted, on its UTC day (Shipped's own read counts the host's local day). Each bucket also lists its `tickets`. | Repository. | Run records, with the 30 days before the period for runs that started before the merge. |
| `findings` | QA findings recorded. | Class. | The ledger's `finding.recorded`. |

A `from` or `to` that is neither an ISO 8601 time nor a date, a `from` not before `to`, an unknown
unit or series, or a period over 366 days or 5000 buckets answers `400` `invalid_query`. Like the
other reads of `/api/v1`, it needs no token.

# Saved views and the tickets read (the Tickets page)

The Tickets page's views live on the server (`SymphonyElixir.Views`, in the run store), so a view
saved on one client is listed by every other. A view is a name, filters, columns and a sort over the
ticket entity, and nothing more. Its columns and filters come from one catalog
(`SymphonyElixir.TicketColumns`), and every write is validated against it.

## The column catalog

| Column | Type | What it holds |
| --- | --- | --- |
| `identifier` | `identifier` | The ticket's identifier. |
| `title` | `string` | The ticket's title. |
| `repo` | `string` | The key of the repository the ticket lives in. |
| `epic` | `identifier` | The identifier of the epic the ticket is a sub-ticket of (its record's parent). |
| `phase` | `string` | The phase (state) the ticket is in. |
| `situation` | `situation` | The kind of the ticket's situation (the ticket read's `situation.kind`). |
| `situation_since` | `time` | Since when the situation holds. |
| `labels` | `list` | The ticket's labels. |
| `priority` | `integer` | Linear's priority: 0 none, 1 urgent, 2 high, 3 medium, 4 low. |
| `assignee` | `string` | Who the ticket is assigned to. |
| `url` | `string` | The ticket's page in Linear. |
| `created_at` | `time` | When the ticket was created. |
| `phase_at` | `time` | When the ticket entered its phase. |
| `updated_at` | `time` | When Symphony last wrote the ticket's record. |

| Filter | Column | Matches |
| --- | --- | --- |
| `repo` | `repo` | Any of its values, in any case. |
| `epic` | `epic` | The epic itself and the tickets whose record names it as parent, as the Journal's and the aggregation read's `epic`. |
| `phase` | `phase` | Any of its values, in any case. |
| `situation` | `situation` | Any of its kinds (`waiting_on_you`, `retrying`, `blocked_by_ticket`, `paused_by_rule`, `waiting_for_ci`, `waiting_for_build`, `waiting_for_slot`, `working`, `done`, `cancelled`). |
| `label` | `labels` | A ticket holding any of its labels, in any case. |
| `priority` | `priority` | Any of its values, integers from 0 to 4. |
| `since` | `updated_at` | The tickets whose record was written after its one ISO 8601 time. |

A ticket passes when every filter lets it through. A filter's `value` is a list (a single value is
read as a list of one), except `since`'s.

## `GET /api/v1/views`

```json
{
  "views": [
    {
      "id": "view-3f9a1c2b7d4e",
      "name": "Epic 6, waiting",
      "filters": [
        { "column": "epic", "value": ["TP-1400"] },
        { "column": "situation", "value": ["waiting_on_you", "waiting_for_ci", "waiting_for_build", "waiting_for_slot"] }
      ],
      "columns": ["identifier", "title", "situation", "priority"],
      "sort": { "column": "priority", "direction": "asc" },
      "created_at": "2026-11-10T04:00:00.000000Z",
      "updated_at": "2026-11-10T04:00:00.000000Z"
    }
  ],
  "columns": [{ "name": "identifier", "type": "identifier", "description": "The ticket's identifier." }],
  "filters": ["repo", "epic", "phase", "situation", "label", "priority", "since"]
}
```

The views by name, with the catalog's columns and filter names. Like the other reads of `/api/v1`, it
needs no token.

## `POST /api/v1/control/view` and `DELETE /api/v1/control/view/:id`

`POST` takes `name` (required, at most 120 bytes), `filters` (default none), `columns` (default
`identifier`, `title`, `phase`, `situation`) and `sort` (default `identifier`, `asc`), and creates a
view; with an `id` it replaces that view's name, filters, columns and sort and keeps its
`created_at`. It answers `200` `{"view": view}`. `DELETE` answers `200` `{"deleted": id}`.

An unknown column, sort column or filter, an unknown situation, a priority outside 0 to 4, a `since`
that is not ISO 8601, an empty value list, an empty `columns`, a direction other than `asc` or
`desc`, or a missing name is `400` `invalid_view` with the reason; an unknown name's reason lists the
catalog's names (`Unknown column(s): colour. The columns are: identifier, title, …`). An `id` no
view has is `404` `view_not_found`. Both need the control token, and neither writes a ticket event.

## `GET /api/v1/tickets`

    GET /api/v1/tickets?view=<id>
    GET /api/v1/tickets?epic=TP-1400&situation=waiting_on_you,waiting_for_slot&columns=identifier,situation&sort=priority&direction=desc

The tickets a saved view selects, or the same grammar inline: each filter by its name with
comma-separated values, `columns` comma-separated, `sort` a column and `direction`. `view` and inline
parameters don't mix.

```json
{
  "view": { "id": "view-3f9a1c2b7d4e", "name": "Epic 6, waiting", "...": "..." },
  "filters": [{ "column": "epic", "value": ["TP-1400"] }],
  "columns": [{ "name": "identifier", "type": "identifier", "description": "The ticket's identifier." }],
  "sort": { "column": "priority", "direction": "asc" },
  "count": 2,
  "tickets": [
    { "issue_id": "4b1c…", "identifier": "TP-1402", "situation": "waiting_on_you", "priority": 1 },
    { "issue_id": "9e2d…", "identifier": "TP-1403", "situation": "waiting_for_slot", "priority": 2 }
  ]
}
```

A ticket is a record with an identifier that no webhook removed and that Linear still has. Each row
is its `issue_id` and the columns asked for, times in ISO 8601. The sort puts the tickets without a
value last, either way, and breaks ties by identifier (`TP-9` before `TP-10`). The situations are
computed from the ledger and what the orchestrator holds now, only when the view shows, filters or
sorts by one; when the orchestrator's snapshot can't be read they come from the records alone and the
answer carries an `error` (`snapshot_timeout` or `snapshot_unavailable`). An unknown view is `404`
`view_not_found`; a malformed query, or `view` with inline parameters, is `400` `invalid_query`. It
reads Symphony's store only, makes no Linear request and needs no token.
