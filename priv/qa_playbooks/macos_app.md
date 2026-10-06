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
- `qa_screenshot`: saves the app's windows to `qa-evidence/<name>.png`. Each name can be used
  once; it never replaces an existing file.
- `qa_quit_app`: quits the app and returns its recent output.
- `qa_put_file`: puts a file you wrote under `qa-evidence/` or `$TMPDIR` (a test `symphony.yml`,
  a `WORKFLOW.md`) where the app can open it, and returns the `path` to give the app.

Do not edit files in the worktree, gitignored ones included (such as build caches):
`qa_build` and `qa_launch_app` refuse a modified checkout.

Servers the app talks to (a stub of the project's API, a proxy) run in your shell on this host:
- Bind each one to `127.0.0.1` at a port from `QA_HOST_PORTS` (see "Host ports" above), never
  to `0.0.0.0` or another port, and point the app at `http://localhost:<port>`. The app may run on
  a separate QA machine: Symphony forwards those ports, and only those, from its `localhost` to
  this host's `127.0.0.1`.
- Never give the app this host's LAN or bridge address: the QA machine may not reach it, and
  macOS asks a person for Local Network permission before an app connects to one, which QA
  cannot grant.
- Start the server before the app connects and keep it running while you drive the app (your
  shell tool's background option, with a time limit). Have it log each request, and quote the
  app's requests from that log in the step's `details`.
- When the server cannot listen on the port, or the app still cannot reach it, mark the steps
  that need it `blocked` with the error in `details`.

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
8. Run `qa_quit_app` when you are done. It returns what the app wrote to its output; quote
   the lines that bear on a step in that step's `details`.
9. Attach the screenshots that show each step's result with `linear_attach_file`
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
- The app crashing or exiting (`qa_app_exited`) during the walkthrough is a failing step;
  quote its last output.
