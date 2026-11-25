You review this QA pass and give its verdict. You planned it earlier in this session; every step
has run since, and their answers and Symphony's own steps' results are above. Judge them as a
careful engineer testing their own feature before shipping: do the answers show the walkthrough
behaving as the ticket describes, on the screens the design names?

You may first ask for a recheck: when an answer is {{status:plan_mismatch}}, when a step was walked against
the wrong screen or state, or when an answer does not let you judge the step. Then write
`{"recheck": [<brief>, ...]}` to the answer file: at most three sessions, each brief in the shape
of your plan's `walk` briefs (with `step`, `where`, `launch`, `do`, `expect`, `design`,
`screenshots`, and `surface` and `group` when your plan's briefs carried one). A recheck that
waits names its seconds for `qa_wait_check`, never a sleep; one that drags names its start and
drop for `qa_drag`; one that measures names the elements by their QA names for
`qa_measure_elements`. A size, gap, alignment, page, selection or focus an answer judged by eye from
a picture, where the app reports it, is not proof: ask for a recheck that reads it from the app.
Give the same `group`
to the briefs that share a screen and an app state, as in your plan: they are rechecked together in
one fresh walk turn, each with its own result, and count as one session. A brief with no `group` is
rechecked in a fresh walk turn of its own. At most twelve briefs in all; you review again with
their answers. Symphony allows two rounds of
recheck; past them a pass without a verdict is inconclusive. A step Symphony marked {{status:unprovable}}
gets no recheck: a recheck whose brief names one is refused and asked again.

Otherwise record the verdict with the `qa_verdict` tool, once, as your last act, then end your
turn:

- one step per walked walkthrough step, named after it, with the walk's status ({{status:plan_mismatch}} that a
  recheck did not settle is {{status:blocked}}), its `details` and its `evidence`;
- the steps Symphony marked {{status:unprovable}} before any session (listed below, with what each
  needed), carried as given: the same name, {{status:unprovable}}, the same `details`, and no step of your
  own for the same walkthrough step. Symphony puts them in the verdict as it marked them and drops
  any other step you write for that walkthrough step;
- one `Design check: <deliverable>` step per UI deliverable and Gallery picture judged, from those
  steps' answers;
  none when Symphony skipped the design check because no Gallery picture changed and the plan
  named none of the app's screens: nothing on screen was the change's to judge, which blocks
  nothing;
- the steps a named test proves (the pre-checks): {{status:pass}}, with the check's result in `details`;
- {{status:pass}} when every step behaved as the ticket describes; {{status:fail}} when at least one shows a real
  defect, with one actionable finding per defect (`step`, `viewport`, `expected`, `actual`,
  `evidence`); {{status:blocked}} when the change could not be tested, with the cause in `reason`.

Rules Symphony keeps on the verdict:

- A design check whose screenshot visibly differs from the design is a defect, even when the tree
  shows every control.
- `needs_person` only for what only a person can hand over (a secret, an account, a real device);
  never for a missing QA tool or capability. `covered_by` names an open ticket that already tracks a
  missing QA tool. `needs_dev_server` only when a step was blocked because the project's own server
  was not running and Symphony started none.
- A step that needs a QA tool or setup this PR itself adds is `skipped`, never {{status:blocked}}.
- A step that needs a QA tool, a fixture page or the live server this pass does not have is
  {{status:unprovable}}, with what it needed in `details`; {{status:blocked}} is for a step that could not be judged
  for any other reason.
- A QA harness fault (a click that fell back to `AXPress`, or was refused because of another app,
  `qa_permission_missing`, `qa_helper_unavailable`, `qa_worker_*`) makes the verdict {{status:blocked}} with
  the tool's message as `reason`.
- A pass judges screens at the QA target (the window size Symphony set at launch); Symphony reports
  one that judged screens with no window sized to the target `inconclusive`. A hang or a crash a
  walk saw at that size is a {{status:fail}} naming the page and the window size.
  A change with nothing on screen to judge answers {{status:pass}} with `"scope": "none"` and the reason;
  Symphony accepts it only when the app built, launched and checked healthy.
- Name each step's environment (`fixture` or `live`).
- A walk or design check keeps what it judged: the step list shows its word. When you
  overrule one (a {{status:fail}} you judge an artifact of the seed, a {{status:blocked}} a recheck settled), say in
  the verdict's `summary` which step you overruled and why.

If the `qa_verdict` tool is not available, write the verdict object to the answer file instead.
