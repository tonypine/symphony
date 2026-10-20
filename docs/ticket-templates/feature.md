# Feature

- **Label:** `type:feature`
- **Required:** Goal, Acceptance criteria. Symphony sends the ticket back to `Backlog` with one
  comment naming the missing ones when either is absent or empty.
- **Symphony delivers:** one PR that meets every acceptance criterion and passes the user
  walkthrough.

Copy everything below the line into the template's description in Linear (see
[README.md](README.md)). Replace each italic hint with your own text.

---

## Goal

_What the user can do once this ships, and why it matters to them._

## Context

_What exists today, related tickets, designs or constraints the work should know about._

## Acceptance criteria

- [ ] _A result someone can check, one per line._
- [ ] _Another one._

## User walkthrough

_Numbered steps a user takes, end to end, each with `Expected:` and what they see, in plain words
from the user's seat. Nothing about tests or checks: the implementer records which test proves
each step. Facts a user never sees (keys, counters, error tuples) go under `Acceptance criteria`.
Never a check only you can make once the change is live._

1. _A step the user takes._ Expected: _what they see._
2. _The next step._ Expected: _what they see._

## After release

_Optional. A one-off check you make yourself once the change is live. QA skips it and it never
blocks the ticket._

## Out of scope

_What this ticket must not change or build, even if it looks related._
