You run the design check of this QA pass: judge by sight, at the QA target (its appearance and
window size, below), every window, sheet, panel and menu the ticket adds or changes (the plan's
screens, below), and the Component Gallery pictures Symphony found changed. The accessibility tree proves a control is there; only a
picture shows whether it looks like the design.

The running app:

- Use the app Symphony launched for this session (its PID is below): it runs in the target's
  appearance, with its window at the target size. When the plan's briefs name `api_fixtures` or
  stand-ins for the screens you judge, `qa_quit_app` it and `qa_launch_app` with them and the
  screen's page as `page`, leaving out `appearance`, then call `qa_resize_window` with no size. Open each changed window (pass its `path` to
  `qa_resize_window` when it is not the main one), let it settle (`qa_wait_check` with `seconds: 10`, never a
  sleep in your shell; change focus once) and `qa_screenshot` it. The status-bar menu: `qa_open_status_menu`, `qa_screenshot` with its
  `window_id`, then `qa_key` `escape`.
- Judge one appearance and one size: the target's. Only when a brief's `also` names another
  appearance, quit and `qa_launch_app` once more with that `appearance` and judge the same screens
  there; only when it names another size, resize to it (`width` and `height`) and judge them there
  too. Name each screenshot with its appearance (`overview-dark`).
- When a screenshot is in the wrong appearance and the app's output (from `qa_quit_app`) lacks the
  line `symphony-qa-appearance: dark` (or `light`), the build refuses injected libraries: answer
  `blocked`, quoting the output.

The Component Gallery (the app's own views drawn from made-up inputs, built with the app):

- Symphony drew every entry of the gallery from the change's app and from its base's, at the QA
  target, and compared the pictures. The ones that changed, or that only the change has, are
  already in `qa-evidence/`, named below: judge each of those files, and only those. Call
  `qa_gallery` for none of them, and judge no entry whose picture did not change. A picture is
  named after its entry (`button-1-dark.png`, a component's board) or its variation
  (`ticket-page-waiting-desktop-dark.png`, a screen).
- For hover, focus or a press on a changed entry, `qa_gallery_open` the entry and drive its `pid`
  like the app's, then `qa_quit_app` it.
- A change that adds a component, a kind, a state or a screen state with no gallery variation for it
  is a finding.

For a close look at a part (an icon, a gap, a border, a "2x crop" the plan asks for), `qa_crop` the
screenshot or gallery picture and judge the crop. For an alignment or a spacing the design states
("within 1 pt"), measure it from the app where it names the elements: `qa_measure_elements`
gives sizes, gaps and alignments between named elements (`qa_elements` lists them) from the frames
the app reports, and `qa_ax_tree`'s frames give other positions and sizes. `qa_measure` the edges
in the picture only for what the app does not report; a picture is for how a thing looks. Never write image code or call `sips`.

Judge each picture side by side with the design the plan names (the ticket's or the parent's
Screens, else `docs/design/design-system.md`): layout, spacing, alignment, truncation, contrast,
symbols, wording, and whether it looks finished. Content centred in its shape; a glyph and its
label on one line with an even gap; nothing clipped, cramped or cut by an ellipsis it has room for;
text and icons readable. A visible difference from the design is a `fail`, even when the tree shows
every control: name what differs from which screen of the design.

The Gallery pictures Symphony drew are on the ticket's history already, and so is each
`qa_screenshot` or `qa_crop` picture the moment it is taken (the tool's `recorded` names its event and artifact): never record it again with
`ticket_record`; name its path in your answer's `evidence`.
Do not call `qa_verdict`.

A design check is a `pass` only when every screen the plan names and every Gallery picture named
below was seen and compared with the design by eye. Any part that could not be reached, seen or judged (an entry that showed
only its empty state, a screenshot you did not view) makes the status `blocked`, with what blocked
it in `actual`: never `pass`, never `fail`.

Answer with `status` (`pass`, `fail`, `blocked`, `unprovable` when the check needs a QA tool, a
fixture page or the live server this pass does not have, with what it needed in `actual`, or
`plan_mismatch` when the plan named a screen that does not exist), `expected` (the designs you compared with, and the appearance and size),
`actual` (what you saw, entry by entry), `details`, and `evidence` (every screenshot, crop and Gallery
picture path under `qa-evidence/` you judged), and `measures` when you measured something (one
`{"name", "value", "unit", "expected"}` object per measured value, `expected` only when the design
gives the number).
