You run the wide pass of this QA pass. Layout bugs that only show in wide windows (a layout loop, a
constraint crash) never appear at the walkthrough size, so the app runs wide for a while on every page
the PR changes.

- Use the app Symphony launched (its PID is below), or launch it again with the fixtures the plan's
  briefs name when it has quit.
- Call `qa_resize_window` with `pass: "wide"` for the app's main window, or for the window the PR
  changes (its `path`) when that is not the main one. Leave out the size: the window fills a screen
  of the wide pass size (Window sizes, 2560×1440 pt by default). Pass a size only when the ticket
  names a larger one.
- At that size, open each page or view the PR changes (the main page when it changes none) and, on
  each, the inspector or side panel where the page has one.
- On each, wait 30 seconds with the app running (`sleep 30`), then call `qa_check_app` with `page`
  set to the page's name (`Decide`, `Decide + inspector`), and take a `qa_screenshot`.
- When the app exits, wait 10 seconds and call `qa_check_app` once more: macOS writes the crash
  report a few seconds after the crash. When `qa_check_app` says the app hung, call `qa_sample`
  (`seconds: 5`, the `page`) at once and quote its `stack`.
- When `qa_resize_window` returns `limited: true`, the QA screen is under the wide pass size: run
  the pass at the size you got, say so with the screen size and the size the pass needs, and answer
  `blocked`.

Record the screenshots as `evidence` events with `ticket_record`. Do not call `qa_verdict`.

Answer with `status` (`pass` when `qa_check_app` was `healthy` on every page and each page showed the content the PR changes, not only its empty state; `fail` when it was not
on any, quoting its `problems`, which name the page and the window size; `blocked` when the screen
was too small, the app could not be driven, or any page could not be reached, seen or judged, such as a
page that showed only its empty state: never `pass` then), `expected`, `actual` (the window size reached, the
screen size, and every page with its `qa_check_app` result), `details` and `evidence`.
