### Playbook: macos_app

Use the macOS app the way a user would and judge what is on screen, not what the code says.
Do not run the project's test suite, `make all`, coverage or static analysis: CI already ran them.
Your sandbox cannot build Swift, launch apps or read the screen, so Symphony runs these tools
for you on the host. They only act on this worktree's configured app and on apps you launched:

- `qa_build`: runs the configured build command. Call it once, before anything else.
- `qa_launch_app`: launches the bundle `qa_build` produced, in QA mode (private settings and
  secrets, never the real ones), and returns its `pid` and its `host_stub_url`, the address
  this app reaches the `qa_host_stub` stub at.
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
- `qa_host_stub`: serves the app canned HTTP responses from Symphony's host stub, and returns
  the requests the stub answered.

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
   When the app reads from a server of the project's (an API, a hub), serve it with
   `qa_host_stub`, never with a server you start yourself, and never give the app an address
   you picked (this host's LAN or bridge address, a port you listen on): the app may run on a
   separate QA machine, and your sandbox listens only on this host's loopback, which that
   machine cannot reach. Write the responses to a JSON file under `qa-evidence/` or `$TMPDIR`:
   `{"routes": [{"method": "GET", "path": "/api/items", "json": [...]}, {"path": "/api/items?page=2", "json": []}]}`
   (`method` defaults to `GET`, `status` to 200; `body` with `content_type` serves text; a
   `path` without a query matches any query; anything else gets a 404). Call `qa_host_stub`
   with that `local_path`, then type the `host_stub_url` that `qa_launch_app` returned into the
   app's server address field, as is or with the path prefix the app expects. Each launch
   returns its own `host_stub_url`; routes stay loaded for the whole pass and a new file
   replaces them. To serve what the project's own server would answer, run that server in your
   sandbox on `127.0.0.1`, save its responses with `curl`, and serve those.
   Call `qa_host_stub` without arguments to read the requests the stub answered, and quote the
   ones a step relies on in that step's `details`: they show the app reached the stub and what
   it asked for. A request that got a 404 means a route is missing or the app asked for
   another path: fix the routes and try again before you judge the step.
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
