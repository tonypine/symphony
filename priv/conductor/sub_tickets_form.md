Changing the sub-tickets and the plan. This ticket has sub-tickets (`sub_tickets` in the facts),
and on this turn, as on every turn you get on it, you may change them and write this ticket's plan
again, as a person can with the Director: one form, read the same way on every turn.

`tree`: a list of at most 10 operations, carried out in order, each with a `reason` (one or two
sentences in plain words, at most 1000 characters). Each is recorded on the sub-ticket it touches,
with your reason, for the person to read, and together they give this ticket's plan a new version.
An operation without a reason, or one that misses a field, is left out; you and the person are told.
- `{"op": "add", "title": ..., "ask": ..., "after": [<identifiers>], "before": <identifier>, "key": <a name>, "repo": ..., "reason": ...}`:
  a new sub-ticket. Write the `ask` as a complete request for someone who has read nothing else: it
  gets its own Grooming. `after` names the sub-tickets whose merged code it builds on; leave it out
  when there is none. `before` puts it in front of that sub-ticket in the queue; without it, it goes
  last. `key` is a name the later operations of this answer may use for it in place of an
  identifier. `repo` only when it belongs to another repository.
- `{"op": "rewrite", "ticket": <identifier>, "ask": ..., "stop": true or false, "reason": ...}`: a
  sub-ticket keeps its place but is asked for something else, whatever it was asked before. The new
  `ask` is complete, not a correction of the old one. `"stop": true` stops its working run first;
  without it the run goes on and the new ask is read at the sub-ticket's next turn.
- `{"op": "cancel", "ticket": <identifier>, "reason": ...}`: a sub-ticket that is no longer needed.
  Its run is stopped and its pull request closed.
- `{"op": "stop", "ticket": <identifier>, "reason": ...}`: stop a sub-ticket's working run and
  change nothing else.
- `{"op": "reorder", "ticket": <identifier>, "before": <identifier>, "reason": ...}`, or with
  `"to": "first"` or `"to": "last"` in place of `before`: put a sub-ticket at another place among
  its siblings. A place that would put it above a sub-ticket it waits on is refused.
- `{"op": "depend", "ticket": <identifier>, "after": [<identifiers>], "reason": ...}`: what a
  sub-ticket waits on among its siblings, the complete list (`[]` for none): the ones it lacks are
  added, the ones left out are removed. One that would make it wait on itself is refused.
Only sub-tickets that have not ended (not Done, not Canceled) change; an operation on one that
ended, or on a ticket that is not a sub-ticket of this one, is not carried out, and you are told.
Most turns change nothing: then leave `tree` empty.

`plan`: null, or this ticket's whole plan written again (`reason`, `shape`, `layers`, `summary`,
`text`, `checks`, `size`, as a plan is written), recorded as its next version. It never lists the
sub-tickets: Symphony keeps that list, and only `tree` changes it. Keep the `id` of every check
that still stands, give a new check no `id`, and do not rewrite an outcome the asks do not change.
{{plan_rule}}
If you do list `sub_tickets` in it, Symphony reads them as the same changes: an entry with an
`identifier` keeps that sub-ticket (with a new `ask` when you give one, and the `after` you give),
one with no `identifier` is a new sub-ticket and needs a `title` and an `ask`, and the order of the
entries is the order you want.

`earlier_tries` in the facts lists what Symphony refused, or did not carry out, from earlier turns
on this ticket, with the exact reason: never give the same answer again. The limits of how many
sub-tickets a ticket may get, and how deep, are in `limits`.
