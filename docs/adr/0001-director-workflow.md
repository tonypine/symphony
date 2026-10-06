# 0001. The Director workflow: ticket types, plan review and artifacts

- **Status:** Accepted, 2026-10-06
- **Decided in:** the plan review of [TP-553](https://linear.app/tonypine/issue/TP-553/research-issue-template)
  (comment "Proposal: the Director workflow", revised after the operator's review)
- **Delivered by:** TP-663, TP-614, TP-615, TP-616, TP-617, TP-618, TP-619, checked by TP-621

This ADR describes the target design. Until the tickets above land, what Symphony does today is
what [`WORKFLOW.md`](../../WORKFLOW.md) and the [`parent_tickets`](../playbook.md) partial say;
[Implementation](#implementation) maps each part to its ticket.

## Context

The operator works as a *director*, the way a film director does: they hold a vision, sometimes an
abstract one, they don't do the work themselves, and they judge whether the result meets their
standard. Symphony is the crew. Before this ADR the crew took direction badly in four ways:

1. **Every ticket looked the same.** A bug, a feature and a research ticket got the same prompt.
   Large tickets were marked with a `breakdown` label and split into sub-tickets, but a research
   ticket that should produce design artifacts (domain research, user journeys, screens, decision
   records) before splitting had no defined path.
2. **Good results needed steering.** On MOT-3 the operator got user journeys, a Kano-based feature
   map and screens that were pleasant to review, but only after steering the agent by hand over
   several runs. The order real product work follows (understand the domain, map the journeys,
   find the features, picture them as platform-quality UI) was not written down anywhere, and
   neither was the rule that the features every app is expected to have (edit, delete, backup and
   so on) are mandatory whatever the niche.
3. **The operator could not find what waited on them, or what to review in it.** Plans waiting in
   `In Review` did not show in SymphonyBar, which only counts `Human Review`. Inside the ticket, the
   only record was the Symphony workpad, which is the agent's working log and not written for a
   person.
4. **Artifacts lived in comments.** A plan's artifacts were posted as comments, which pile up,
   drift out of date and are hard to edit over several runs. The description, the first thing a
   person reads, never said where the ticket stood.

## Decision

### Three ticket types

Every ticket has one type, set by its label. The type picks the Linear template the operator
writes, the steps Symphony follows and what it must deliver.

| Type | Label | The operator writes | Symphony delivers | The operator reviews |
| --- | --- | --- | --- | --- |
| Bug | `type:bug` | Observed, Expected, Steps to reproduce, Where (platform, version), Evidence | A failing test that reproduces the bug, then the fix, in one PR | The PR |
| Feature | `type:feature` | Goal, Context, Acceptance criteria, User walkthrough, Out of scope | One PR | The PR |
| Plan | `plan` | Vision (can be abstract), Context (domain, users, platform), Constraints, Quality bar, Artifacts wanted (checkboxes), Done when | The artifacts checked under "Artifacts wanted", then sub-tickets of one PR each | Everything at once, then the final verification |

- **`plan` replaces `breakdown` and the proposed `discovery` type.** A plan ticket is a parent
  ticket that does plan work, produces artifacts and splits into sub-tickets for execution. It
  never opens a PR itself. A plan with no artifact checked is what a `breakdown` ticket is today, a
  plain split; a plan with every artifact checked is what MOT-3 became after steering.
- **`breakdown` stays accepted as an alias of `plan`** (TP-663), so every parent already in flight
  keeps working. The operator renames the label in Linear (Settings → Labels) and Linear relabels
  every ticket that has it. Internal names (the `breakdown` run kind, `BreakdownReview`, run profile
  keys) stay, so existing `WORKFLOW.md` configs and SymphonyBar run profiles keep working.
- **Templates are versioned in the repo** under `docs/ticket-templates/` (TP-618), with the steps
  to create each one in Linear, so the template and the prompt that reads it change together.
- **A readiness check runs on bugs and features.** When a required section is missing or empty
  (bug: Observed, Expected, Steps to reproduce; feature: Goal, Acceptance criteria), Symphony asks
  for it in one comment and moves the ticket to `Backlog` instead of guessing and spending a run.
- **A plan is never sent back for missing input.** What is unclear becomes a decision with a
  recommended default in its review, and the run goes on with the default.
- A ticket with no type label keeps today's behaviour.

### The plan, in the order real work happens

A plan run produces its stages in this order. Each builds on the one before it, and each is
produced only when the ticket checks it under "Artifacts wanted". The implementation plan is always
produced. A plan ticket with no "Artifacts wanted" section, such as every `breakdown` ticket written
before the templates, gets only the implementation plan, as today.

1. **Domain brief**: the domain, the people in it, its vocabulary, constraints and sources (for
   example, research on the menstrual cycle before designing a cycle-tracking app).
2. **User journeys**: personas and their jobs, and each journey end to end, including the routine
   ones (first launch, fixing a mistake, moving to a new phone).
3. **Kano feature map**: every feature from the journeys classed Must-be, Performance, Attractive
   or Indifferent. A **platform baseline** is always added as Must-be, whatever the niche: edit,
   delete, undo, search, backup/export/restore, settings, accessibility, offline use, notification
   control and privacy controls. A cycle app that can't edit an entry fails, however good its
   predictions are.
4. **Screens**, in the format below.
5. **Decisions**: one ADR-style section per real choice, with the options and a recommendation.
6. **Implementation plan**: the sub-tickets, each naming the feature, journey and Kano class it
   serves (feature → journey → screen → ticket) and carrying a user walkthrough; Must-be tickets
   first. A `Final verification:` sub-ticket closes the plan, as today.

Two written references replace the steering the operator did by hand on MOT-3 (TP-619):

- **House standards** (`docs/standards/house-standards.md`) hold the platform baseline and the
  design quality bar. A project overrides them with a Linear document named "House standards".
- **A rubric per stage**: before handing over, the run checks each artifact against it and fixes
  what fails. For example: the baseline is in the Kano map, every Must-be has a screen, the HTML
  file shows every screen in the document, every sub-ticket traces back to a feature.

### One review, with everything at once

A plan ticket is reviewed **once**. The run produces every stage the ticket asks for, files the
sub-tickets in `Backlog`, and hands over a single time, with every artifact, decision and sub-ticket
ready to review together. There is no gate between stages.

The review moves stay the ones the `parent_tickets` flow uses today:

- **Approve**: move the parent to `Waiting on sub-tickets`. Symphony promotes its `Backlog`
  sub-tickets to `Todo`, and blocked-by links keep their order.
- **Change**: comment on any part. A revision run edits the documents, the HTML screens and the
  `Backlog` sub-tickets in place, answers each comment, updates the review brief and hands over
  again.
- **Reject**: move the parent to `Rework`. Symphony cancels the `Backlog` sub-tickets and a
  re-plan run starts over.

Bugs and features keep today's PR review.

### Screens: a Linear document plus one HTML file, as on MOT-50

The screens stage delivers two views of the same screens, the format MOT-50 used:

- A **Screens document** in Linear lays out each journey screen by screen: what the screen shows,
  its states, and the platform conventions it follows (Material 3 on Android, the Human Interface
  Guidelines on Apple platforms), with an image per screen where one can be rendered offscreen.
- **One self-contained HTML file** holds every screen, styled for the platform, with no external
  assets. It is attached to the ticket and linked at the top of the Screens document, for viewing in
  a desktop browser.

### Where artifacts live

Each artifact has one home, chosen by who reads it and how long it lives:

| Home | What it holds | Who it is for | Written by |
| --- | --- | --- | --- |
| Linear documents | One per artifact: domain brief, journeys, Kano map, screens, decisions. Titled `<identifier> · <title>`, in the issue's project, attached to the issue, edited in place by later runs | The operator, then the agents on the sub-tickets | TP-615's document tools |
| Symphony-owned description block | At the end of the description, between `<!-- symphony:summary:start -->` and `<!-- symphony:summary:end -->`: a status line, a link to the review brief, links to the artifacts (documents, HTML screens, PR, sub-tickets) and a dated changelog, newest first and capped | Anyone opening the ticket | TP-616's tool, which can write only that block; the operator's text above it is never touched, and agents never read the block as requirements |
| Review brief | One comment per ticket headed `## Review brief`, edited in place at each handoff: what to review (with links), what changed since the last brief, decisions needed (each with options and a recommendation), and the exact move that approves, changes or rejects | The operator, and only the operator | TP-614 |
| Workpad | The `## Symphony Workpad` comment: plan, checklist, validation evidence, notes | The agents: it is the crew's log, and the operator never needs to read it | Unchanged; its template points to the review brief |

The rule against editing the issue description stays, with one exception: the summary block,
through its own tool. A `## Review brief` comment counts as Symphony's own, so it never starts a
plan revision run.

### How the operator finds what waits on them

A ticket waits on the operator when it is in `In Review` or `Human Review`, or has an open
`linear_request_human_action` request. Three surfaces list them:

- **SymphonyBar and the dashboard** show a "Waiting on you" list (TP-617). Each entry gives the
  ticket, its kind (`plan`, `pr`, `final_verification` or `action`), the headline of its review
  brief and how long it has waited, oldest first. The menu bar icon shows a badge while the list is
  not empty, and each item opens the ticket in the browser.
- **A saved Linear view, "Waiting on me"**, for use away from the Mac: in Linear, create a view
  filtered to status `In Review` or `Human Review` and assignee "me", and save it as "Waiting on
  me". On a mobile device, add it to favourites.
- **The project update** for human actions, which already lists every open request with its steps.

Opening a ticket from any of these, the operator reads the summary block, follows its link to the
review brief, and finds there everything to review and the move that answers it.

### Decisions taken in the plan review on TP-553

The proposal on TP-553 left three questions open. The operator's review answered all three:

| Question | Chosen | Why |
| --- | --- | --- |
| Is research ("discovery") a separate type from `breakdown`? | **One `plan` type** replaces both, with `breakdown` kept as an alias (TP-663). | Both follow one pattern: a parent ticket that does plan work, produces artifacts and splits into sub-tickets. The "Artifacts wanted" checkboxes cover the difference: none checked is a plain split, any checked adds those stages. |
| Does a plan stop for review after each stage, or once? | **One review at the end**, with every artifact, decision and sub-ticket at the same time. TP-620 (stage gates) was cancelled. | The operator wants to review everything at once. A comment on any part brings a revision run that edits it in place, so a later stage never has to wait on approval of an earlier one. |
| What form do screens take? | **The MOT-50 format**: screens laid out in a Linear document, plus one self-contained HTML version attached to the ticket and linked from the document. | The Linear document keeps the screens next to the ticket and open to comments; the HTML version is easier to view on the desktop. |

## Consequences

- The operator writes a ticket from its template and reviews one brief per handoff, without
  reading the workpad.
- A plan ticket's result no longer depends on steering: the stage order, the house standards and
  the rubrics are written down and checked before the handoff.
- One review means a wrong domain brief is caught only at the end, after the later stages were
  built on it. A revision run fixes every stage in place, so the cost is one more run, not a
  restart, and the operator chose this trade.
- A plan run that produces every stage is much longer and costs more tokens than today's split.
  Unchecked stages are skipped, so a ticket pays only for what it asks for.
- Symphony gains write access to two more things in Linear: documents that its runs created, and
  one delimited block of the description. Each is limited by its tool: other documents and the rest
  of the description stay out of reach, and content is scanned for secrets as comments are.
- Agents must not read Symphony's own output as requirements: the summary block is stripped from
  the description they read, and the review brief, like the workpad, never starts a plan revision.
- `breakdown` keeps working, so the migration is one label rename in Linear, done whenever the
  operator chooses.
- Templates live in the repo, so a template change is reviewed like code, but each template has to
  be created by hand in Linear once (the steps are in `docs/ticket-templates/`).

## Alternatives

- **A separate `discovery` type next to `breakdown`.** Turned down in the plan review: two labels
  for one pattern, and the operator would have to pick between them on every large ticket. The
  "Artifacts wanted" checkboxes carry the difference inside one type.
- **A review gate after each stage** (`gate:stages`, one stage per run, approve by moving the
  ticket to `Todo`). Specified as TP-620 and dropped in the plan review: it puts the operator in the
  loop once per stage, and they want to review everything at once.
- **Screens only as images in the Linear document**, or **only as an HTML prototype**. Turned down
  for the MOT-50 format: images alone are hard to take in at desktop size, and an HTML file alone
  can't be commented on next to the ticket.
- **Artifacts as comments**, as today. Turned down: comments pile up, are hard to edit over several
  runs, and bury the current version under the old ones.
- **Rewriting the whole description** with the plan and the changelog. Turned down: it would
  overwrite the operator's own text and races with their edits. A delimited block keeps the two
  apart.
- **Making the workpad readable for people** instead of adding a review brief. Turned down: the
  workpad has to hold the agent's full log and evidence, which is exactly what makes it the wrong
  thing for a person to review.

## Out of scope and parked

- **Running Symphony as a Linear OAuth app actor.** Symphony posts with the operator's own API key,
  so Linear treats its handoffs as the operator's own actions and doesn't notify them. Acting as an
  OAuth app would make the handoffs notify the operator in Linear. Parked: it needs an app
  registration and a new kind of credential to run, and the "Waiting on you" list and the saved
  view cover finding the work for now.
- **Per-stage review gates.** Dropped in the plan review (see Alternatives); TP-620 is cancelled.

## Implementation

| Part | Ticket |
| --- | --- |
| `plan` label, `breakdown` kept as an alias | TP-663 |
| Review brief at every handoff | TP-614 |
| Linear document tools | TP-615 |
| Symphony-owned description block | TP-616 |
| "Waiting on you" list in SymphonyBar and the dashboard | TP-617 |
| Ticket templates, type routing, readiness check | TP-618 |
| Plan pipeline: stages, screens, house standards, rubrics, one review | TP-619 |
| Final verification of the whole | TP-621 |
