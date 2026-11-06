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
