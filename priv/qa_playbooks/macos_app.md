### Playbook: macos_app

Use the macOS app the way a user would and judge what is on screen, not what the code says.
Do not run the project's test suite, `make all`, coverage or static analysis: CI already ran them.
Your sandbox cannot build Swift, launch apps or read the screen, so Symphony runs these tools
for you on the host. They only act on this worktree's configured app and on apps you launched:

- `qa_build`: runs the configured build command. Call it once, before anything else.
- `qa_launch_app`: launches the bundle `qa_build` produced, in QA mode (private settings and
  secrets, never the real ones), and returns its `pid`. Pass `api_fixtures`, a directory relative
  to the checkout (for example `macos/Tests/Fixtures/director-app/running`), and Symphony copies
  it to the machine the app runs on and launches the app with `SYMPHONY_BAR_QA_API_FIXTURES`
  pointing at the copy (returned as `api_fixtures`). The directory may hold only regular files,
  at most 5 MB, inside the checkout. Optional stand-ins, see "Stand-ins for GitHub, Linear, updates
  and the folder picker" below: `gh_stub_port`, `linear_stub_port`, `open_panel_dir`,
  `update_feed_port`, `update_check_interval_seconds`. Pass `appearance` (`light` or `dark`) to
  draw the app in that appearance whatever the host's; without it the app follows the host. See
  "Light and dark, and the status-bar menu" below.
- `qa_ax_tree`: the app's accessibility tree with each element's role, title, value and
  `frame` (`x`, `y`, `w`, `h` in points). Pass `role` or `text` to list only matching elements.
- `qa_ax_press` (`action` defaults to `AXPress`; `AXRaise` focuses a window) and
  `qa_ax_set_value`: act on an element by the `path` `qa_ax_tree` gave it. `qa_ax_set_value`
  types into a text field the way a person does and presses Tab to commit it, so the app
  saves what it shows; it fails with `text_not_entered` or `not_focused` when the text did not
  land.
- `qa_ax_select`: selects a table or outline row (an `AXRow`, or a cell inside it) by its
  `path`. Rows answer no `AXPress`, so use this to select one; the app comes to the front and the
  table takes keyboard focus. `qa_ax_tree` marks the selected row `selected: true`.
- `qa_key`: presses a `key` (`return`, `escape`, `tab`, `space`, `delete`, arrows such as `down`,
  or one character such as `[`) with optional `modifiers` (`command`, `shift`, `option`,
  `control`) in the app's focused window. A shortcut such as ⌘[ is `key: "["`,
  `modifiers: ["command"]`. It returns the `window` and `focused` element the key went to.
- `qa_click`: clicks the centre of an element's frame (`clicks: 2` double-clicks), for a control
  no accessibility action reaches. It fails with `covered` or `not_on_screen` when another app's
  window is in front or the element is scrolled away.
- `qa_resize_window`: moves the app's main window (or the `AXWindow` at `path`) to the top left
  of the screen and resizes it to `width`×`height` points, 1400×900 by default, or the screen's
  usable area when that is smaller. It returns the window's new frame in `window` (`x`, `y`, `w`,
  `h`), the `screen` size, its `visible` (usable) area, and `limited: true` when that area is
  under 1400×900 pt.
- `qa_check_app`: says whether the app is still `running`, `responding` (it answered an
  accessibility request within 10 seconds; a hung app does not) and has written no new crash
  report since launch (`crash_reports`, from `~/Library/Logs/DiagnosticReports` on the machine
  the app runs on). Pass the `page` on screen: each entry of `problems` names it and the window
  size `qa_resize_window` set. `healthy` is true when there are no problems. It works after the
  app has exited.
- `qa_screenshot`: saves the app's windows to `qa-evidence/<name>.png`. Each name can be used
  once; it never replaces an existing file. Pass `window_id` to save one window, such as the menu
  `qa_open_status_menu` opened.
- `qa_open_status_menu`: opens the app's status-bar menu (its menu bar item) on screen, as a
  click on the item would, and returns the menu's `window_id` and `frame` once it shows. Close it
  with `qa_key` and `key: "escape"`. Never press the status item with `qa_ax_press` or
  `qa_click`: the press blocks until the menu closes (AXError -25204) and the click is refused as
  covered.
- `qa_quit_app`: quits the app and returns its recent output.
- `qa_put_file`: puts a file you wrote under `qa-evidence/` or `$TMPDIR` (a test `symphony.yml`,
  a `WORKFLOW.md`) where the app can open it, and returns the `path` to give the app.
- `qa_put_checkout`: puts a git checkout where the app can open it. Make the repo under
  `$TMPDIR` (`git init -b main`, add the files, commit), then `git bundle create <file> --all`,
  and pass the bundle as `local_path` with the GitHub `remote_url` its `origin` should name (such
  as `https://github.com/acme/widgets`) and an optional `remote_name` for the folder. Returns the
  checkout's `path`. Nothing is fetched from or pushed to GitHub.
- `qa_api_requests`: returns the `requests` an app launched with `api_fixtures` sent since the
  last call, oldest first: each POST it logged to `api-requests.jsonl` in its QA root, with its
  `method`, `path` and `body`. The log lives where you cannot read it, so use this instead.

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

Stand-ins for GitHub, Linear, updates and the folder picker (the Add Repo sheet, update checks
and anything else that runs `gh`, asks Linear or picks a folder). Never let the app reach real
GitHub or Linear in QA:

- **gh:** serve a gh stub on a `QA_HOST_PORTS` port and pass it as `qa_launch_app`'s
  `gh_stub_port`. The app then runs Symphony's fake `gh` (through `SYMPHONY_BAR_GH`), which POSTs
  each call to `http://localhost:<port>` as a form body: `argc`, then one `arg` field per
  argument, in order (`urllib.parse.parse_qsl` keeps the order). Answer 200 with what `gh` would
  print on stdout (exit status 0), or any other status with an error message (stderr, exit status
  1). For example `api repos/acme/widgets --jq .default_branch` → `main`; `api
  repos/acme/widgets/contents?ref=main --jq .[].name` → one file name per line. Log every call,
  and quote the calls that bear on a step.
- **Linear:** serve a GraphQL stub on another port and pass it as `linear_stub_port`; the app
  POSTs `{"query", "variables"}` JSON to `http://localhost:<port>/graphql`. Answer by the query's
  operation name: `SymphonyBarProjects` →
  `{"data":{"projects":{"nodes":[{"id":"p1","name":"QA Project"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}`,
  `SymphonyBarProjectTeams` → `{"data":{"project":{"teams":{"nodes":[{"id":"t1"}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}`,
  `SymphonyBarLabels` → `{"data":{"issueLabels":{"nodes":[{"id":"l1","name":"macos","isGroup":false}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}`.
  Any made-up Linear key in Settings works with it.
- **Update feed:** run Symphony's shared feed server, never one you write. Start it on another
  `QA_HOST_PORTS` port with your shell tool's background option:
  `python3 -B test/support/stubs/update_feed.py --fake-release 9.9.9 9999 --port <port> --log "$TMPDIR/update-feed.log"`.
  Once it prints `update feed on http://127.0.0.1:<port>/releases/latest …`, pass the port as
  `update_feed_port`; the app's update checks then GET `http://localhost:<port>/releases/latest`
  (through `SYMPHONY_BAR_UPDATE_URL`) instead of GitHub's. `-B` keeps Python from writing `__pycache__/`
  into the checkout, and the log stays under `$TMPDIR`: `qa_build` and `qa_launch_app` refuse a
  checkout with either.
  - `--fake-release VERSION BUILD` offers a made-up release with no build: the app shows it
    (a `BUILD` above the app's own is a newer release), but its download is a 404, so it never
    installs. When a QA tool gives you a release pair's `feed/` folder, pass `--dir <folder>`
    instead.
  - Switch what `releases/latest` answers while it runs:
    `curl -X POST --data <mode> http://127.0.0.1:<port>/_feed/mode`. `publish` (the default)
    offers the release; `forbidden` answers 403, which the app reads as GitHub's rate limit, to
    make a check fail; `none` offers nothing newer, so a check finds the app up to date, and needs
    `--current VERSION BUILD` at start with a build at or below the app's own (such as
    `--current 0.0.1.0 0`).
  - The log has one JSON line per request (`method`, `path`, `status`, `time`). Quote the app's
    requests from it in the step's `details`. `test/support/README.md` lists every option.
- **Update fixtures:** for an update's state in the Symphony window, pass a committed fixture as
  `api_fixtures`, never one you build under `qa-evidence/`.
  `macos/Tests/Fixtures/director-app/update-paused` has dispatch paused for an update to v9.9.9
  with two agent runs finishing, and `macos/Tests/Fixtures/director-app/update-paused-idle` has
  the same pause with nothing running. Run the feed with `--fake-release 9.9.9 9999`, so the
  release it offers is the one the pause names. When a step needs an update state no fixture
  has, say so in `findings`, so one is committed for the next pass.
- **Update-check interval:** pass `update_check_interval_seconds` (a positive integer, such as
  `30`) and the app checks for a release that often in the background, in every update mode,
  through `SYMPHONY_BAR_UPDATE_CHECK_INTERVAL`. A failed check still backs off to 6 hours, so use
  Check Now to check again after one.
- **Folder picker:** the picker is a system panel with no path field. Put the checkout with
  `qa_put_checkout`, pass its `path` as `open_panel_dir`, and the panel opens inside it: press
  its Choose button without selecting anything to choose that folder. Use one launch per
  checkout you need to pick.

Light and dark, and the status-bar menu. A UI deliverable is judged by sight in both
appearances. The host's appearance is never switched; launch the app once per appearance instead:

- **Dark:** `qa_launch_app` with `appearance: "dark"` (plus the walkthrough's `api_fixtures` and
  stand-ins). Open the windows the ticket changes, let them settle (step 4 below) and
  `qa_screenshot` each, named with the appearance (for example `overview-dark`).
- **Status-bar menu:** when the ticket changes the status-bar menu, or a step reads it:
  `qa_open_status_menu`, then `qa_screenshot` with the `window_id` it returned (for example `status-menu-dark`), then
  `qa_key` with `key: "escape"` to close it. Read the menu's items from `qa_ax_tree` as before
  when a step needs their titles; the screenshot is for judging how it looks.
- **Light:** `qa_quit_app`, then do the same with `appearance: "light"` (`overview-light`,
  `status-menu-light`). At most three launched apps run at once, so quit each before the next.
- **Judge** each pair side by side: text and icons stay readable, nothing keeps a light-only or
  dark-only colour, and the two match the design. When `qa_open_status_menu` fails with
  `qa_status_menu_not_opened`, call `qa_check_app`; a menu that never opens on a healthy app is a
  failing step, quoted with the tool's message.

1. Run `qa_build`. A non-zero `exit_status` from a change that should build is a failing
   step; quote the end of the output.
2. Run `qa_launch_app`. In QA mode the app starts with empty settings. When the walkthrough
   runs the app with `SYMPHONY_BAR_QA_API_FIXTURES` set to a fixtures directory, pass that
   directory as `api_fixtures`, never by setting the variable yourself: the app reads Symphony's
   API from those files instead of a running Symphony. When the walkthrough checks what the app
   sent (`api-requests.jsonl`), call `qa_api_requests` after the action and judge its `requests`.
3. Open each window the ticket's walkthrough and acceptance criteria touch (menu items,
   buttons, Settings), using `qa_ax_tree` to find elements and `qa_ax_press` to act. When an
   element answers `qa_ax_press` with `unsupported`:
   - a table or list row (`AXOutline` or `AXTable` > `AXRow`): select it with `qa_ax_select`, then
     read `qa_ax_tree` again to check what the selection shows (an inspector, a detail pane);
   - a step that names a key or shortcut (Return opens the selected item, ⌘[ goes back, Escape
     closes): press it with `qa_key` after selecting what it acts on;
   - any other control: `qa_click` it.
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
   was limited as `blocked` either way, so a person enlarges the QA screen, and reports a pass
   with no `qa_resize_window` call as `blocked` too, because its wide pass did not run. In an epic
   review that launches no app, because the epic changed none, there is no wide pass to run.
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
