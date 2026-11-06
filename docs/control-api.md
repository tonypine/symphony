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
