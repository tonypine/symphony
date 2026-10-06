### Playbook: macos_app

Use the macOS app the way a user would and judge what is on screen, not what the code says.
Do not run the project's test suite, `make all`, coverage or static analysis: CI already ran them.
Your sandbox cannot build Swift, launch apps or read the screen, so Symphony runs these tools
for you on the host. They only act on this worktree's configured app and on apps you launched:

- `qa_build`: runs the configured build command. Call it once, before anything else.
- `qa_launch_app`: launches the bundle `qa_build` produced, in QA mode (private settings and
  secrets, never the real ones), and returns its `pid`.
- `qa_ax_tree`: the app's accessibility tree with each element's role, title, value and
  `frame` (`x`, `y`, `w`, `h` in points). Pass `role` or `text` to list only matching elements.
- `qa_ax_press` (`action` defaults to `AXPress`; `AXRaise` focuses a window) and
  `qa_ax_set_value`: act on an element by the `path` `qa_ax_tree` gave it. `qa_ax_set_value`
  types into a text field the way a person does and presses Tab to commit it, so the app
  saves what it shows; it fails with `text_not_entered` or `not_focused` when the text did not
  land.
- `qa_resize_window`: moves the app's main window (or the `AXWindow` at `path`) to the top left
  of the screen and resizes it to `width`×`height` points, 1400×900 by default, or the screen's
  usable area when that is smaller. It returns the window's new `frame`, the `screen` size, its
  `visible` (usable) area, and `limited: true` when that area is under 1400×900 pt.
- `qa_check_app`: says whether the app is still `running`, `responding` (it answered an
  accessibility request within 10 seconds; a hung app does not) and has written no new crash
  report since launch (`crash_reports`, from `~/Library/Logs/DiagnosticReports` on the machine
  the app runs on). Pass the `page` on screen: each entry of `problems` names it and the window
  size `qa_resize_window` set. `healthy` is true when there are no problems. It works after the
  app has exited.
- `qa_screenshot`: saves the app's windows to `qa-evidence/<name>.png`. Each name can be used
  once; it never replaces an existing file.
- `qa_quit_app`: quits the app and returns its recent output.
- `qa_put_file`: puts a file you wrote under `qa-evidence/` or `$TMPDIR` (a test `symphony.yml`,
  a `WORKFLOW.md`) where the app can open it, and returns the `path` to give the app.

Do not edit files in the worktree, gitignored ones included (such as build caches):
`qa_build` and `qa_launch_app` refuse a modified checkout.

1. Run `qa_build`. A non-zero `exit_status` from a change that should build is a failing
   step; quote the end of the output.
2. Run `qa_launch_app`. In QA mode the app starts with empty settings.
3. Open each window the ticket's walkthrough and acceptance criteria touch (menu items,
   buttons, Settings), using `qa_ax_tree` to find elements and `qa_ax_press` to act.
4. Let every window settle before you judge it. A window can open at the right size and
   collapse seconds later, so a check right after opening proves nothing:
   - wait about 10 seconds after the window opens (`sleep 10` in your shell);
   - change focus once: `qa_ax_press` with `action: "AXRaise"` on another window of the app,
     or press a different control, then raise the window under test again;
   - wait a few more seconds, then read `qa_ax_tree` for that window.
5. Judge the settled window from the tree, not from the window frame alone:
   - the controls the ticket describes are present (text fields, labels, buttons), with
     sensible titles and values;
   - content areas (`AXScrollArea`, `AXGroup`, `AXSplitGroup`) have a real size. A window
     whose content or scroll area is a few points tall, or whose tree has no controls under
     the window, is empty even when the window frame looks normal.
6. Take a `qa_screenshot` of every step you judge, named after the step (for example
   `settings-open`), and after every action that changes the UI.
7. Exercise the change: fill fields with `qa_ax_set_value`, press the buttons the
   walkthrough names, and read the tree again to check the result. Use made-up values, never
   real credentials, and never write what you typed into a secure field (an API key) in the
   report, a comment or a file name.
   For every file the app must open (a config path in Settings, a `WORKFLOW.md`), write the fixture under `qa-evidence/` or `$TMPDIR`, call `qa_put_file`,
   and give the app the `path` it returns, never your own path: the app may run on a
   separate QA machine that cannot see your files. Type that path into the field rather
   than browsing for it in a file picker.
   OpenRouter steps (Test connection, the Models list, the Effort note) run against a stub
   OpenRouter Symphony starts for this pass: `qa_launch_app` points the app at it, and the
   Symphony the app runs (`symphony check` on Save) checks models against it too. The app never
   reaches openrouter.ai in QA, so never ask for a real key and never mark an OpenRouter step
   `blocked` for want of one. The stub knows:
   - one valid key, `sk-or-v1-symphony-qa-stub`: Test connection answers "Connected as Symphony
     QA stub: $1.25 used of a $10.00 limit, $8.75 left". Any other key is rejected ("OpenRouter
     rejected the key…"). The stub key is made up and public, so you may quote it;
   - three models: `symphony-qa/reasoning-tools` (tools and reasoning),
     `symphony-qa/tools-only` (tools, no reasoning, so Effort gets its note) and
     `symphony-qa/no-tools` (no tools, so the Models picker leaves it out).
   Judge the walkthrough's OpenRouter steps with these, `pass` or `fail`. Checks with a real key
   are manual and not part of QA.
8. **Wide pass.** Layout bugs that only show in wide windows (a layout loop, a constraint
   crash) never appear at the default size, so after the walkthrough run the app wide:
   - call `qa_resize_window` for the app's main window. When the main window is not the one the
     PR changes (a Settings window, a panel), pass that window's `path`. Use the default
     1400×900 unless the ticket names a larger size;
   - with the window at that size, open each page or view the PR changes (the main page when it
     changes none), and on each one the inspector or side panel where the page has one;
   - on each of them, wait 30 seconds with the app running (`sleep 30` in your shell), then call
     `qa_check_app` with `page` set to the page's name (for example `Decide` or
     `Decide + inspector`), and take a `qa_screenshot`.
   Report one step named `Wide pass` with: the window size `qa_resize_window` reached, the
   screen size it reports, and every page and panel you opened with its `qa_check_app` result.
   The step fails when `qa_check_app` is not `healthy` on any of them (the app exited, it hung,
   or it wrote a new crash report): quote its `problems`, which name the page and the window
   size, and list each one in `findings`. When the app exits, wait 10 seconds and call
   `qa_check_app` once more, because macOS writes the crash report a few seconds after the
   crash. When `qa_resize_window` returns `limited: true`, the QA screen is too small for the
   wide pass: still run it at the size you got, say in the step that the wide pass was limited
   with the screen size, and mark the step `blocked`. Symphony reports a pass whose wide pass
   was limited as `blocked` either way, so a person enlarges the QA screen.
9. Run `qa_quit_app` when you are done. It returns what the app wrote to its output; quote
   the lines that bear on a step in that step's `details`.
10. Attach the screenshots that show each step's result with `linear_attach_file`
   (`make_public: false`) and list the returned URLs in that step's `evidence`.

Verdicts for this playbook:

- An empty or collapsed window, a missing control, or a control that does nothing is a
  failing step. In `details` quote the relevant part of the settled AX tree (the window and
  its direct children, with frames) and attach the screenshot of that window.
- When a tool returns `qa_permission_missing`, stop this playbook: mark each app step you
  could not check `blocked` with the tool's message in `details`. Then continue with the
  steps of the other playbooks offered to you (such as `cli` or `web`) and report each of
  them as `pass` or `fail`. Answer `blocked` with the tool's message as `reason`. Do the same
  for `qa_helper_unavailable`.
- The app crashing or exiting (`qa_app_exited`) during the walkthrough or the wide pass is a
  failing step; quote its last output and the `qa_check_app` problems.
