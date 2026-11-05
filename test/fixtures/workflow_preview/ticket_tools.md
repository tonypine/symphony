## implementation

- `ticket_events` reads this ticket's history (Symphony's ledger) and `ticket_record` adds an event to it. Symphony fills the run, phase and head; verdicts, moves, pauses and questions are Symphony's, and `ticket_record` refuses them.
- This implementation run records `step.completed` for each delegated step as it ends it, `evidence` for every screenshot or output it attaches (the files as `artifacts`), and each walkthrough step's proof as `evidence` with `proof` (the step and the test), which `linear_record_walkthrough_proofs` records; a `note` keeps a choice worth knowing later.
- This run follows a step list: Symphony runs its build, checks and tests itself between turns and brings a failure back to the step it names, with the output. Run none of them yourself: write the code, record what you changed, and end the turn; the handoff step pushes.

## breakdown

- `ticket_events` reads this ticket's history (Symphony's ledger) and `ticket_record` adds an event to it. Symphony fills the run, phase and head; verdicts, moves, pauses and questions are Symphony's, and `ticket_record` refuses them.
- This plan run records a `note` for each choice the plan makes and why; the sub-tickets, documents and requests are the rest of its record.

## rework

- `ticket_events` reads this ticket's history (Symphony's ledger) and `ticket_record` adds an event to it. Symphony fills the run, phase and head; verdicts, moves, pauses and questions are Symphony's, and `ticket_record` refuses them.
- This rework run reads `ticket_events` with `open_findings: true` before it plans, records `finding.resolved` for each finding it fixes (Symphony fills the head that fixes it), `evidence` for every screenshot or output it attaches (the files as `artifacts`), `step.completed` for each delegated step and a walkthrough proof again as `evidence` with `proof` when it changes the test.

## landing

- `ticket_events` reads this ticket's history (Symphony's ledger) and `ticket_record` adds an event to it. Symphony fills the run, phase and head; verdicts, moves, pauses and questions are Symphony's, and `ticket_record` refuses them.
- This landing run records a `note` for what held the merge and how it landed, and `evidence` for every screenshot or output it attaches (the files as `artifacts`).

## code_review

- `ticket_events` reads this ticket's history (Symphony's ledger) and `ticket_record` adds an event to it. Symphony fills the run, phase and head; verdicts, moves, pauses and questions are Symphony's, and `ticket_record` refuses them.
- This code review run records `evidence` for every screenshot or output it attaches (the files as `artifacts`) and a `note` for each risk it weighed; its verdict is the verdict tool's.

## epic_review

- `ticket_events` reads this ticket's history (Symphony's ledger) and `ticket_record` adds an event to it. Symphony fills the run, phase and head; verdicts, moves, pauses and questions are Symphony's, and `ticket_record` refuses them.
- This epic review run records `evidence` for each requirement and walkthrough step it checked against what shipped; its outcome is Symphony's.

## ci_fix

- `ticket_events` reads this ticket's history (Symphony's ledger) and `ticket_record` adds an event to it. Symphony fills the run, phase and head; verdicts, moves, pauses and questions are Symphony's, and `ticket_record` refuses them.
- This CI-fix run records a `note` naming the red check's cause, `evidence` for every screenshot or output it attaches (the files as `artifacts`), and `finding.resolved` for an open finding the repair fixes.

## review_feedback

- `ticket_events` reads this ticket's history (Symphony's ledger) and `ticket_record` adds an event to it. Symphony fills the run, phase and head; verdicts, moves, pauses and questions are Symphony's, and `ticket_record` refuses them.
- This review-feedback run reads `ticket_events` with `open_findings: true` before it plans, records `finding.resolved` for each finding it fixes (Symphony fills the head that fixes it), `evidence` for every screenshot or output it attaches (the files as `artifacts`), `step.completed` for each delegated step and a walkthrough proof again as `evidence` with `proof` when it changes the test.

## qa

- `ticket_events` reads this ticket's history (Symphony's ledger) and `ticket_record` adds an event to it. Symphony fills the run, phase and head; verdicts, moves, pauses and questions are Symphony's, and `ticket_record` refuses them.
- This QA run records `evidence` for each walkthrough step it proves, with the environment it proved it in, and `finding.recorded` for each defect, before its verdict; the verdict is the verdict tool's.
