# 0003. Automated tests first; QA is the last-resort check and judges by sight; CI and QA share their test helpers

- **Status:** Accepted, 2026-10-15
- **Decided in:** the operator's ruling of 2026-10-15, after
  [TP-983](https://linear.app/tonypine/issue/TP-983) and
  [TP-972](https://linear.app/tonypine/issue/TP-972) looped in QA for about 12 hours on steps the
  QA build could never pass
- **Delivered by:** [TP-1033](https://linear.app/tonypine/issue/TP-1033) (plan); see
  [Implementation](#implementation)

## Context

Symphony proves a ticket in two places before it merges: the tests CI runs on the PR head, and the
QA agent's pass. The QA agent works through the ticket's `## User walkthrough` on a QA machine with
the tools Symphony gives it, and records a verdict (`pass`, `fail` or `blocked`) bound to the PR
head. QA is the expensive check: a pass runs a high-effort model on a VM for minutes, and a
`blocked` verdict leaves the ticket waiting.

Three things went wrong on 2026-10-14 and 2026-10-15:

1. **QA repeated what a test already proves.** TP-970's plan put one journey (a release installs by
   itself while a run is active) in three places: the walkthroughs of TP-983 and TP-972, and the
   end-to-end scenarios of [TP-973](https://linear.app/tonypine/issue/TP-973). The e2e harness
   ([`update_restart_e2e.py`](../../macos/Tests/e2e/update_restart_e2e.py), run in CI by
   `macos-e2e`) can install one signed build over another. The QA build can't:
   `make -C macos qa-app` embeds no update signing key, and the build is signed ad hoc, which the
   app's installer refuses. QA ran about 90 passes on TP-983 and 133 on TP-972, each blocked on
   the same steps. TP-971 had hit the same wall the day before.
2. **The test environments can't be shared.** The pieces that build that environment (a throwaway
   minisign key, a throwaway trusted certificate, releases N and N+1, a release feed) live inside
   the e2e script. QA improvises its own on every pass instead: the macOS playbook has the QA agent
   write its own feed stub, and TP-983's QA wrote the same API fixture into `qa-evidence/` on every
   pass. No two passes run against the same thing.
3. **What only QA can do is barely asked of it.** The [macOS playbook](../../priv/qa_playbooks/macos_app.md)
   judges a window from its accessibility tree, and screenshots are evidence. Nothing asks QA to
   look at the result and judge whether it meets the design and the quality bar, the one check no
   test can make.

The [plan pipeline](../../priv/playbook/plan_pipeline.liquid) asks for walkthrough steps "written
so an end-to-end test or the QA agent can reproduce it", without saying which, so QA walks every
step.

## Decision

### Automated tests are the proof

Every behaviour that code can check is checked by an automated test that CI runs on the PR head.
That already holds for acceptance criteria ([`ticket_types`](../../priv/playbook/ticket_types.liquid):
"A test for every criterion that code can check"). It now holds for walkthrough steps too,
end-to-end harnesses included.

### Each walkthrough step names the one place that proves it

A step is proved by a named automated test (a suite, scenario or test) or by QA, never both. QA
doesn't walk a step that a named test proves: it confirms that test passed on the PR head and says
so in its report. A step that needs an environment QA doesn't have goes to an automated harness,
not to QA. The plan run routes each step when it writes the sub-tickets, so one journey is never
placed both in a sub-ticket's walkthrough and in an end-to-end ticket.

### QA is the last-resort check, and it judges by sight

QA does what no test can:

- the steps no automated test can drive;
- **a judgment by sight of every UI deliverable.** QA looks at screenshots of the real app (light
  and dark, at the sizes the design names) and judges whether the result meets the ticket's design
  and the [design system](../design/design-system.md) and looks finished: layout, spacing,
  alignment, truncation, contrast, symbols and wording. A visible miss is a `fail`, with the
  screenshot and what differs, even when every structural check passes;
- the wide pass and the other checks of the running app that the playbooks already ask for.

A QA verdict never stands in for a missing test. When a step could be a test, the gap is a ticket.

### CI and QA share deterministic test helpers

The environments that tests and QA need (builds, signing identities, fake services and feeds, API
fixtures, stub agents) come from helpers in the repo, with fixed inputs and outputs. Both CI's
tests and QA's tools call them. A QA agent doesn't improvise a stub or a fixture that a helper
provides. When no helper exists, the gap is a ticket, not a workaround inside one pass. Helpers are
code: they have tests of their own, and a change to one is checked by both of its users.

The macOS app comes first: the signed release pair and the update feed that the e2e harness builds
today become helpers that QA can call too.

## Consequences

- Fewer and shorter QA passes. QA stops being blocked by environments only CI has, and stops paying
  a model to repeat what a test proved.
- QA's verdict gains weight where the operator needs it: whether the result looks and feels right.
- The harnesses become shared infrastructure. A flaky test now blocks CI and the QA verdicts that
  rely on it, so a flake is fixed as urgent, as TP-1030 was.
- Walkthroughs take longer to write, because each step names its proof. In return a reviewer sees
  at a glance what is tested and what is judged.
- QA must be able to see the design it judges against. Designs often sit on the parent ticket, so
  the QA prompt has to reach them.
- A step moved from QA to a test isn't proved until that test lands. TP-983 and TP-972 now rely on
  TP-973's scenarios for their install steps.

## Alternatives

- **QA walks every step, as before.** Turned down: it duplicates CI, it blocks on environments only
  CI has, and it is the slowest and most expensive check.
- **Drop QA and rely on tests alone.** Turned down: no test judges whether a screen meets the design
  and looks finished, and that judgment is what the operator wants from QA.
- **Give QA its own copy of the environment**, for example a signing key on the QA VM for QA's
  builds only. Turned down: it is a second implementation of what the e2e harness already does, and
  it drifts from it. One shared helper builds the environment for both.

## Implementation

| Part | Ticket |
| --- | --- |
| The routing rule in the plan pipeline, the ticket templates and the QA prompt | TP-1033 (plan) |
| QA's judgment by sight in the QA playbooks and the verdict rules | TP-1042 |
| Shared macOS helpers (signed release pair, update feed, committed fixtures), with the e2e harness on top of them | TP-1033 (plan) |
| TP-983 and TP-972: install steps moved to TP-973's scenarios, a judgment by sight added | Done by hand on 2026-10-15 (TP-1034) |
