You review this QA pass and give its verdict. You planned it earlier in this session; every step
has run since, and their answers and Symphony's own steps' results are above. Judge them as a
careful engineer testing their own feature before shipping: do the answers show the walkthrough
behaving as the ticket describes, on the screens the design names?

You may first ask for a recheck: when an answer is `plan_mismatch`, when a step was walked against
the wrong screen or state, or when an answer does not let you judge the step. Then write
`{"recheck": [<brief>, ...]}` to the answer file: at most three briefs, each in the shape of your
plan's `walk` briefs (with `step`, `where`, `launch`, `do`, `expect`, `design`, `screenshots`, and
`surface` when your plan's briefs carried one). Each
runs as a fresh walk turn, and you review again with its answer. Symphony allows two rounds of
recheck; past them a pass without a verdict is inconclusive.

Otherwise record the verdict with the `qa_verdict` tool, once, as your last act, then end your
turn:

- one step per walkthrough step, named after it, with the walk's status (`plan_mismatch` that a
  recheck did not settle is `blocked`), its `details` and its `evidence`;
- one `Design check: <deliverable>` step per UI deliverable and gallery entry judged, and one
  `Wide pass` step, from those steps' answers;
- the steps a named test proves (the pre-checks): `pass`, with the check's result in `details`;
- `pass` when every step behaved as the ticket describes; `fail` when at least one shows a real
  defect, with one actionable finding per defect (`step`, `viewport`, `expected`, `actual`,
  `evidence`); `blocked` when the change could not be tested, with the cause in `reason`.

Rules Symphony keeps on the verdict:

- A design check whose screenshot visibly differs from the design is a defect, even when the tree
  shows every control.
- `needs_person` only for what only a person can hand over (a secret, an account, a real device);
  never for a missing QA tool or capability. `covered_by` names an open ticket that already tracks a
  missing QA tool. `needs_dev_server` only when a step was blocked because the project's own server
  was not running and Symphony started none.
- A step that needs a QA tool or setup this PR itself adds is `skipped`, never `blocked`.
- A QA harness fault (a click that fell back to `AXPress`, or was refused because of another app,
  `qa_permission_missing`, `qa_helper_unavailable`, `qa_worker_*`) makes the verdict `blocked` with
  the tool's message as `reason`.
- A pass that judged any screen owes the wide pass; Symphony reports one without it `inconclusive`.
  A change with nothing on screen to judge answers `pass` with `"scope": "none"` and the reason;
  Symphony accepts it only when the app built, launched and checked healthy.
- Name each step's environment (`fixture` or `live`).

If the `qa_verdict` tool is not available, write the verdict object to the answer file instead.
