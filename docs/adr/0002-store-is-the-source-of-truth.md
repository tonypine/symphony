# 0002. Symphony's store is the source of truth; Linear is its projection

- **Status:** Accepted, 2026-10-15
- **Decided in:** the operator's ruling of 2026-10-15, after
  [TP-1000](https://linear.app/tonypine/issue/TP-1000) and
  [TP-955](https://linear.app/tonypine/issue/TP-955) stayed paused for about 10 hours with their
  decisions already answered
- **Delivered by:** [TP-1020](https://linear.app/tonypine/issue/TP-1020),
  [TP-1019](https://linear.app/tonypine/issue/TP-1019),
  [TP-1023](https://linear.app/tonypine/issue/TP-1023) and
  [TP-1024](https://linear.app/tonypine/issue/TP-1024); see [Implementation](#implementation)

This ADR makes principle 10 of [the ticket state machine](../design/state-machine.md) ("Symphony
owns the state; Linear is a window") a rule that code is checked against.

## Context

Symphony keeps a record per ticket in its own store (`SymphonyElixir.TicketState`, persisted by
`SymphonyElixir.RunStore`): the phase, the holds with their reason or decision payload, the verdicts
bound to a PR head, the CI state of each head, the ticket's pull request, the self-heal record and
the runs dispatched. Linear shows the same facts as workflow states, machine labels (`Blocked`,
`Needs Decision`, `CI red`, `CI green`) and Symphony's description blocks.

The state machine design already says the store is canonical and Linear is a projection. The code
still treats Linear as the truth in places, and every one of those places breaks when the board
drifts from the store:

1. **The Inbox lists held tickets by their label.** On 2026-10-14 the `Needs Decision` label went
   missing from TP-1000 and TP-955 about a minute after each decision was answered; the store
   holds stayed. The Inbox lists holds by label, so it never read either ticket again, never saw
   the answers and never cleared the holds. The Inbox is also the only code that puts a missing
   `Needs Decision` label back, so nothing could recover. Both tickets waited about 10 hours, until
   the labels were added back by hand.
2. **Hold reads take their key from the Linear ticket.** Dispatch reads holds with the repo key of
   the ticket as it came from the poll. On some dispatch paths that key is missing, the read
   returns nothing, and the ticket is dispatched through its hold: TP-983 and TP-972 ran QA through
   25 Needs Decision holds between them.
3. **The phase follows the board.** `SymphonyElixir.TicketStateReconciler` adopts the Linear state
   when the two disagree ("the board wins while the migration is in flight"), and the dispatcher
   picks candidates by the Linear state of the polled ticket.
4. **Recorded answers live only in Linear.** A decision's answer is written into the Decisions
   section of the ticket's description (`SymphonyElixir.Decisions`), and the prompts read it from
   there. The store keeps the question while the hold is set, but not the answer.

Linear is also the scarcer resource. Symphony shares a budget of 2,500 Linear requests an hour, and
runs into Linear's rate limit and outages: the Inbox was rate-limited for the whole window in which
TP-1000 and TP-955 lost their labels. A store read costs nothing and doesn't fail that way.

## Decision

### The store decides

When the store holds a fact about a ticket, Symphony reads it from the store. Guards, the
dispatcher, the Inbox, the pollers and the prompts never ask Linear for something the store
already knows. This covers the phase, holds, verdicts, CI state, the pull request, self-heal and
dispatch records, and every attribute added later.

**A new attribute is written to the store first.** Linear gets it after, as a projection, if a
person needs to see it there.

### Linear is a projection

Symphony writes Linear from the store: the workflow state, the machine labels and its own blocks
in the description. When the board and the store disagree, the difference is drift. The store wins,
and Symphony repairs the projection. It never adopts the board's value.

Machine labels are owned by Symphony. A person removing or adding one by hand is drift, not an
action: the label is put back, or taken off, to match the store. A person lifts a hold the ways the
state machine gives them (answering the decision, Unblock, Restart), not by editing a label.

Every projection has a repair path that runs whatever else fails, and reads the store to find what
to repair. A repair that only reaches tickets it found through the projection is not a repair.

### Linear is an input for what people do there

People still work in Linear, and Symphony reads what they do as **requests**: a new ticket and its
text, a comment, a reply to a decision request, a ruling, a drag to another state, an assignment.
Symphony validates each one like any other signal, records the result in the store, and projects
it back. Reading Linear to learn a person's request is fine. Reading Linear to learn what Symphony
already knows is not.

### Indexes and keys come from the store

The list of tickets to look at for a store fact comes from the store: the held tickets come from
the store's holds, not from tickets carrying a hold label. Linear is then read by id for the
content a person wrote. A key needed to read a store record (the repo key) is resolved from the
store or the configuration, not taken from a field of the polled ticket.

**A store read that can't resolve its key fails closed.** It doesn't dispatch, and it says why. It
never reads as "nothing held".

### When the store doesn't have it yet

Where the store holds nothing yet (a ticket Symphony has never seen, the text of a ticket, a
person's comment), Symphony reads Linear and stamps what it needs into the store on that first
read. From then on, the store answers. The direction stays the one the state machine names: grow
the store until Linear is an optional view.

## Consequences

- A label or state that goes missing on the board no longer changes what Symphony does. The worst
  case is a board that is briefly wrong, and the repair path fixes it.
- Linear rate limits and outages delay what people see on the board and what Symphony learns from
  their comments. They no longer change what Symphony believes about its own state.
- Fewer Linear requests: lists and checks that read the store stop costing requests.
- Editing a machine label by hand stops working as a control. The Inbox, answers, Unblock and
  Restart are the controls. People used to fixing the board by hand need to know this.
- Every projection needs a repair path, and each one has to be tested both ways: a stray label and
  a missing one.
- The store becomes something to protect. Its migrations, backups and recovery after a lost store
  matter more, because Linear is no longer a full copy to rebuild from. A lost store can be
  re-stamped from Linear (the reconciler does this for a ticket with no record), but verdicts, CI
  history and self-heal records can't.
- Until the gaps below close, two places still answer some questions. Code review checks new code
  against this ADR so the gaps don't grow.

## Alternatives

- **Linear as the truth, the store as a cache.** The original design. Turned down: Linear can't
  hold machine facts such as a verdict bound to a head or CI state per head, every check costs a
  request against a shared budget, and every board drift changes behaviour. That drift caused the
  incident above.
- **Two-way sync, last writer wins.** Turned down: it makes every conflict a race, and the result
  depends on timing. A person's accidental label edit would silently change what the machine does.
- **The store as the truth, with the label-based listing kept as a fallback.** Turned down: a
  fallback that reads the projection hides drift instead of repairing it. The Inbox listing holds
  by label is exactly this fallback, and it is what stranded TP-1000 and TP-955.

## Implementation

| Gap | Ticket |
| --- | --- |
| The Inbox lists held tickets by their label | TP-1020 |
| Dispatch reads holds with a missing repo key and finds none | TP-1019 |
| The phase adopts the Linear state on disagreement; the dispatcher picks candidates by it | TP-1023 (plan) |
| Decision answers are recorded only in the Linear description | TP-1024 |
