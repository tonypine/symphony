## Priority vs expedite

- A ticket's priority means how important it is, not its place in the queue. Symphony uses it only to order tickets waiting for a normal slot.
- Never raise a ticket's priority (this ticket, a sub-ticket or a blocker) to get it picked sooner. Set a new sub-ticket's `priority` by importance only.
- Jumping the queue is a person's call: they add the `expedite` label or run `symphony force <ticket>`. Do not add or remove that label yourself. A forced ticket skips the slot limits (`max_total`, per-state caps, epic lanes, `finishing_max`, the daily token budget) but still waits for the operator's Pause, the Linear rate-limit and usage-limit pauses, its blocked-by links and the per-issue token cap.
- Forcing never moves a ticket or skips a review. `Backlog` -> `Todo`, `In Review` -> `Merging`, approving a plan, `Rework` and signing off a `Final verification:` stay with a person, and the review-agent verdict and Auto Review QA still apply: follow the status map as usual.
