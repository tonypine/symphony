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

_Steps a machine can reproduce: an end-to-end test in CI, or the QA agent driving the app or CLI
on its own VM. Never a check only you can make once the change is live. End each step with the one
place that proves it: `Proved by: <check> › <test>` (the GitHub check, then the suite, scenario or
test file) or `Proved by: QA`. Name the test as the code has it (its file path, or a test or
scenario name as written): Symphony looks it up in the PR before QA starts and fails the step when it
is not there. QA links a named test's result instead of walking its step, and a step without the
line is a QA step. A step that needs what QA lacks (a signed build, a device, real
credentials) names an automated harness; a judgment by sight stays with QA._

1. _A step the user takes._ Expected: _what they see._ Proved by: _`make-all` › `test/path/to/feature_test.exs`._
2. _The next step._ Expected: _what they see._ Proved by: QA

## After release

_Optional. A one-off check you make yourself once the change is live. QA skips it and it never
blocks the ticket._

## Out of scope

_What this ticket must not change or build, even if it looks related._
