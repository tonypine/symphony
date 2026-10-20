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
  draw the app in that appearance whatever the host's, for any AppKit app (Symphony injects a
  library that sets the app's appearance); without it the app follows the host. See
  "Light and dark, and the status-bar menu" below.
- `qa_ax_tree`: the app's accessibility tree with each element's role, title, value, `help`
  and `frame` (`x`, `y`, `w`, `h` in points). Pass `role` or `text` to list only matching elements.
  `help` is the text of the element's tooltip: a step that hovers to read a tooltip reads it
  there (`text` matches it too), with no hover.
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
  no accessibility action reaches. The pointer moves there first, as a person's mouse would, and
  the result names the element under it (`under_pointer`) and whether the tree or the windows
  `changed`. When a single click changed nothing and the element answers `AXPress`, it is
  pressed that way instead and `fallback` is `AXPress`: say so in the step's `details`. It fails
  with `not_on_screen` when the element is scrolled out of the app's window, and with `covered`
  when another app would take the click at that point; the message names that app, so quote it
  in the step's `details`.
- `qa_hover`: moves the pointer over an element's centre (`path`) or a point on screen (`x`,
  `y`, in the points of `qa_ax_tree`'s frames) and waits for the app to settle (`settled`). The
  pointer stays there, so a hover state (a button that only shows on hover, a highlight) is in
  the next `qa_ax_tree` and `qa_screenshot`. A `qa_click` on what the hover showed moves the
  pointer onto it, as a person's would. It fails like `qa_click`.
- `qa_context_menu`: right-clicks an element's centre or a point and returns the `menu` that
  opened, with each item's `path`, `title`, `enabled` and `shortcut`, and its `window_id` for
  `qa_screenshot`. Press an item with `qa_ax_press` on its `path`; close the menu with `qa_key`
  and `key: "escape"`. Use it for a row or control whose `AXShowMenu` is `unsupported`. It fails
  with `no_menu` when no menu opened.
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
- `qa_build_release_pair`, `qa_relaunched_app` and `qa_update_feed`, with `qa_launch_app`'s
  `release_pair: true`: build release N and its update N+1 signed, launch N, and drive the app
  after it installed N+1. See "After an update: the signed release pair" below.

Do not edit files in the worktree, gitignored ones included (such as build caches):
`qa_build` and `qa_launch_app` refuse a modified checkout.

Servers the app talks to (a stand-in for an outside service, a proxy to the dev server Symphony
started) run in your shell on this host; never a stub you write of the project's own server or
API, which is the system under test. For each one:
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

- **gh and Linear:** run Symphony's shared stubs, never ones you write. Start each on its own
  `QA_HOST_PORTS` port with your shell tool's background option:
  `python3 -B test/support/stubs/gh.py --port <port> --log "$TMPDIR/gh.log"` and
  `python3 -B test/support/stubs/linear.py --port <port> --log "$TMPDIR/linear.log"`. Once they
  print `gh stub on http://127.0.0.1:<port> …` and `Linear stub on http://127.0.0.1:<port>/graphql …`,
  pass the ports as `qa_launch_app`'s `gh_stub_port` and `linear_stub_port`.
  - The app then runs Symphony's fake `gh` (through `SYMPHONY_BAR_GH`), which sends each call
    to the gh stub and prints its answer, and POSTs its Linear queries to the Linear stub's
    `/graphql` (through `SYMPHONY_QA_LINEAR_URL`). Any made-up Linear key in Settings works.
  - The gh stub answers the Add Repo sheet's calls for the repo `acme/widgets` (default branch
    `main`, top-level files `README.md`, `mix.exs` and `mix.lock`: an Elixir project with Credo),
    and opening its `WORKFLOW.md` pull request (`https://github.com/acme/widgets/pull/1`), so
    put the checkout with `qa_put_checkout` and `remote_url` `https://github.com/acme/widgets`.
    The Linear stub answers the sheet's projects (`QA Project`), a project's teams and the
    labels (`macos`).
  - A call they have no answer for gets a clear error: the gh stub's (`gh stub: no committed
    answer for: gh …`) is what `gh` prints on stderr, so the app shows it as gh's error; the
    Linear stub's is a GraphQL error naming the operation, which the app shows as Linear's.
    When a step needs an answer they don't have, say so in `findings`, so one is committed to
    `test/support/stubs/answers/` for the next pass.
  - Each log has one JSON line per request (`method`, `path`, `status`, `time`, and the call:
    `args` for gh, `operation` and `variables` for Linear). Quote the app's calls that bear on a
    step from them in its `details`. `test/support/README.md` lists every option.
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
  through `SYMPHONY_BAR_UPDATE_CHECK_INTERVAL`. A failed check retries at that interval, except a
  403 or 429: it waits for the reset the response names in `Retry-After` or `X-RateLimit-Reset`,
  an hour when it names none, so use Check Now to check again after one.
- **Folder picker:** the picker is a system panel with no path field. Put the checkout with
  `qa_put_checkout`, pass its `path` as `open_panel_dir`, and the panel opens inside it: press
  its Choose button without selecting anything to choose that folder. Use one launch per
  checkout you need to pick.
- **PR and CI watcher:** pass `macos/Tests/Fixtures/director-app/pr-watch` as `api_fixtures`.
  Its clock is 2026-10-16 12:04 UTC. Open each ticket from Tickets (or from Overview's Code
  Review & QA and Merging tiles) and judge its **PR and CI** card, the first card on the page:
  - TP-701 (Code Review, CI running): the first line reads "Waiting for CI on 9f8e7d6", then
    "CI acts next, until the checks finish · 4 min", "Updated 4 min ago · check" and the fact
    "Fix attempts: Checks 2 of 10 · conflict 1 of 3 · last: conflict with main". Press
    **Check Now**: `qa_api_requests` lists a `POST /api/v1/issues/TP-701/watch/check`, and the
    Updated line reads "Updated 3 s ago · check".
  - Overview reads "1 thing needs attention." with the row "TP-702 in Rework: nothing is running
    and nothing says why." and its buttons **Check Now** (prominent) and **Open Ticket**; Open
    Ticket opens TP-702's page.
  - Inbox, Decisions: TP-703's review has **What the watcher found** above its options, with the
    failing check `protected paths` and the files `WORKFLOW.md` and
    `config/settings_ui_exempt.yml`; "Drop the change in Rework" is marked Recommended. Send
    Decision posts `POST /api/v1/control/decide` and the selection moves to TP-706.
  - TP-704 (Merging): "Waiting on TP-705 to land · they change the same file (SPEC.md)" with
    **Open TP-705**. TP-707: "CI keeps failing: waiting on TP-708, a fix ticket for the test
    check" with **Open TP-708**. TP-709: "PR #709 was closed without merging. Sent back to
    Rework, …" with **Open PR**. The Inbox lists none of TP-704, TP-707 and TP-709.
  - VoiceOver: the card's summary reads as one element (the status word, the line, who acts
    next, since when, Updated), each action row as one, and each button by its title.
- **Setup (TP-910):** pass `macos/Tests/Fixtures/director-app/setup` as `api_fixtures`. Its
  state has one error, `Team TP has no "Needs Decision" label` (**Create Label…**), and one
  warning, `symphony.yml sets auto_review.enabled, which is deprecated` (**Remove…**). Before
  Remove, copy the fixture's `config/symphony.yml` to `qa-evidence/`, `qa_put_file` it, and type
  the returned path into Settings' config field: Remove edits that file, and `symphony check`
  passes on it before and after.
  - Sidebar: **Setup** between Repos and Diagnostics with a red badge of 1; Overview's Needs
    attention has "Setup has 1 error." with **Open Setup**; the status-bar menu has
    "Setup: 1 error, 1 warning" (it opens the Setup page) and the icon's dot is red.
  - The fixtures answer in turn, so press each button once, in this order: **Create Label…** then
    the sheet's **Create Label** (`qa_api_requests` lists `POST /api/v1/setup/fixes` with
    `fix.action` `create_label`, `team` `TP`, `name` `Needs Decision`): the error row leaves and
    the badge turns orange with 1. **Remove…** shows the two removed lines (`auto_review:`,
    `  enabled: true`); **Remove**: the row leaves and the banner names the
    `symphony.yml.<time>.bak` copy and offers **Undo**. **Undo** within 10 s: the warning row is
    back, and **Remove…** shows the same two lines again (the key is back in the file). **Remove**
    again, then **Check Again** (⌘R): "Symphony is set up right." with "at 12:05" and "Symphony checks again every 15 minutes
    and each time symphony.yml changes.", and no badge.
    Each of these posts `POST /api/v1/setup/refresh`. That the file loses the key, the backup
    holds the old bytes and Undo restores them byte for byte is proved by
    `SetupConfigEditTests`, not by reading the file.
  - Refused: launch again with `macos/Tests/Fixtures/director-app/setup-refused`. **Create Label…**
    then **Create Label**: the sheet stays open with "Linear refused to create the label …
    (HTTP 403) …" in red, **Open Settings…**, **Close** and **Try Again**; **Open Settings…** opens the
    Settings window with the sheet still open behind it, and the row is still there.
  - Look: judge the page, its Details, both sheets and the banner in light and dark against
    `macos/Tests/Snapshots/setup-*.png`.
- **Add Repo's Check setup and the first launch (TP-911):**
  - First launch, before any other launch of the pass: every launch in a pass shares one QA root,
    and the first one that sees Symphony's setup checked records the app's first run, so only that
    launch is a first launch. Make the pass's first `qa_launch_app` the one with
    `macos/Tests/Fixtures/director-app/setup` as `api_fixtures` and `appearance: "dark"`: the
    Symphony window opens on its own on Setup with "Welcome to Symphony on this Mac…" above
    "Setup has 1 error and 1 warning." (walkthrough step 6). Judge the welcome by sight there
    against `macos/Tests/Snapshots/setup-first-launch-dark.png`. No later launch is a first
    launch, so judge the light welcome from `macos/Tests/Snapshots/setup-first-launch-light.png`
    alone until a launch can start from a fresh QA root (TP-1121). That a first launch without
    errors, or a later launch with errors, opens nothing is proved by `SetupOnStartTests`.
  - Then pass `macos/Tests/Fixtures/director-app/add-repo-setup` as `api_fixtures`, with the gh
    and Linear stubs. Copy its `config/symphony.yml` to `qa-evidence/`, `qa_put_file` it, and type
    the returned path into Settings' config field. Add `acme/widgets` (GitHub URL, key `widgets`),
    pick `QA Project`, and on WORKFLOW.md pick **Don't create one now**.
  - Review's **Route** line reads "Project ID p1 · team QA"; after **Connect**, the file's
    `widgets` entry has `route.projects: [p1]` and `route.team: QA`.
  - Check setup shows "Setup has 1 error for widgets." with `Team QA has no "Blocked" label`
    and **Create Label…** (not web-shop's `Needs Decision` error), **Done** disabled, and
    "Done is available once there are no errors." beside it. **Create Label…** then **Create
    Label** (`qa_api_requests` lists `POST /api/v1/setup/refresh` before it and
    `POST /api/v1/setup/fixes` with `create_label`, `QA`, `Blocked`): "widgets is set up right.",
    Written to symphony.yml with Project `p1` and Team `QA`, and **Done** enabled.
  - Warning only: launch again with `macos/Tests/Fixtures/director-app/add-repo-setup-warning`
    and add the repo the same way: `widgets is not cloned yet` is listed and **Done** is enabled.
  - Symphony stopped: launch without `api_fixtures` and add the repo: "Symphony isn't running, so
    it checks widgets when it starts." with **Start Symphony** and **Done** both enabled.
  - Look: judge the step in light and dark against `macos/Tests/Snapshots/add-repo-check-*.png`.

QA does three things, in this order: (a) the walkthrough steps marked `Proved by: QA` (no test
can drive them), steps 1 to 7 below; (b) the `Design check` of every UI deliverable, by sight, in
light and dark (step 8); (c) the wide pass (step 9).

Design check: light and dark, and the status-bar menu. The accessibility tree proves a control is
there; only a screenshot shows whether it looks like the design. Judge every window, sheet, panel
and menu the ticket adds or changes by sight in both appearances. The host's appearance is never
switched; launch the app once per appearance instead:

- **Dark:** `qa_launch_app` with `appearance: "dark"` (plus the walkthrough's `api_fixtures` and
  stand-ins). Open the windows the ticket changes. When the design names a size of 1400×900 pt or
  more for one, set it with `qa_resize_window` (`width`, `height`, and the window's `path` when it
  is not the main window); the tool makes no window smaller, so judge one whose design names a
  smaller size at the size it opens, and give both sizes in the step. Let each settle (step 4
  below) and `qa_screenshot` it, named with the appearance (for example `overview-dark`).
- **Status-bar menu:** when the ticket changes the status-bar menu, or a step reads it:
  `qa_open_status_menu`, then `qa_screenshot` with the `window_id` it returned (for example
  `status-menu-dark`), then `qa_key` with `key: "escape"` to close it. Judge the menu from that
  screenshot, not only from the tree: read its items from `qa_ax_tree` when a step needs their
  titles, but how it looks is in the screenshot.
- **Light:** `qa_quit_app`, then do the same with `appearance: "light"` (`overview-light`,
  `status-menu-light`). At most three launched apps run at once, so quit each before the next.
- **When the app ignores it:** the library prints `symphony-qa-appearance: dark` (or `light`) to
  the app's output once it has set the appearance, and `qa_quit_app` returns that output. When a
  screenshot is in the wrong appearance and that line is missing, the app's build refuses injected
  libraries (the hardened runtime): mark the `Design check` `blocked`, quoting the output, and say
  so in `findings`.
- **Judge** each pair side by side with the deliverable's design: the ticket's or the parent's
  Screens (named under "Design" above), then `docs/design/design-system.md`. Compare layout,
  spacing, alignment, truncation, contrast, symbols (SF Symbols, icons), wording, and whether it
  looks finished: text and icons stay readable, nothing keeps a light-only or dark-only colour,
  nothing is clipped or placeholder. When no Screens cover the deliverable, judge it against the
  design system alone. When `qa_open_status_menu` fails with `qa_status_menu_not_opened`, call
  `qa_check_app`; a menu that never opens on a healthy app is a failing step, quoted with the
  tool's message.

After an update: the signed release pair. The `qa_build` app is signed ad hoc and has no update
key, so it never installs an update. When a step judges what the app shows once an update
installed, or once a failed one was rolled back, use the signed release pair instead. Whether the
install works is proved by the `macos-e2e` check, not by you: do not report the install itself as a
step you proved, judge what the app shows.

**One-time setup on the QA host.** The QA host gets a persistent test identity, installed and
trusted once, rather than a throwaway one trusted for each pass: a pass that died would leave its
trust setting behind. On a QA VM (a `worker_host`) whose QA user has passwordless `sudo`,
`qa_build_release_pair` installs it itself the first time it finds none, or finds it untrusted,
with Symphony's own copy of the script, and builds the pair in the same call. Anywhere else (QA on
Symphony's own host, or a QA user whose `sudo` asks for a password) whoever provisions the host
runs it by hand as the QA user, from a checkout of this repository:

```sh
scripts/qa/install-test-signing-identity.sh          # asks for sudo once, to trust the certificate
scripts/qa/install-test-signing-identity.sh --check  # says whether it is installed and trusted; no sudo
```

It creates a self-signed code-signing identity named `Symphony QA Test Signing`, never Symphony's
release certificate, in a keychain of its own,
`~/Library/Keychains/symphony-qa-signing.keychain-db`, whose password it keeps beside it in
`symphony-qa-signing.password`. It puts that keychain on the user's keychain search list (codesign
only finds an identity there) and trusts the certificate for code signing only
(`sudo security add-trusted-cert -d -r trustRoot -p codeSign`). Running it again changes nothing
once the identity is installed and trusted, and finishes an install that stopped half way. The
pair's build also needs `minisign` and `jq` (`brew install minisign jq`) and the repository's
toolchain for `make release`. You never install it yourself, and the QA sandbox cannot run `sudo`
anyway: Symphony's tool does it, or it is host setup. Where it can't be installed,
`qa_build_release_pair` fails with `qa_signing_identity_missing` or
`qa_signing_identity_untrusted`, as **Build** below says.

- **Build:** `qa_build_release_pair` builds release N and its update N+1 on the machine the app
  runs on and returns their `manifest` (each one's `version` and `build`). It takes several
  minutes; call it once, after `qa_build`. A non-zero `exit_status` is a failing step; quote the
  end of the output. When its result has `signing_identity_installed: true`, Symphony installed the
  QA host's test signing identity in that call: say so in the report. When it fails with
  `qa_signing_identity_missing` or
  `qa_signing_identity_untrusted`, the QA host lacks its test signing identity: mark the steps that
  need the pair `blocked` with the tool's message, finish the other steps, and answer `blocked`
  with that message.
- **Launch N:** `qa_launch_app` with `release_pair: true` (plus the walkthrough's `appearance`,
  `api_fixtures` and `update_check_interval_seconds`; not `update_feed_port`). N starts from a fresh
  copy, and its update checks read the pair's own feed, which offers N+1. When the walkthrough has
  Symphony report N+1, so the app checks at once instead of on its timer, pass
  `macos/Tests/Fixtures/director-app/update-reported` as `api_fixtures`: its state reports N+1's tag.
- **The feed:** `qa_update_feed` returns its `mode` and the `requests` the app sent it (the
  `/releases/latest` checks, the zip's download). Pass `mode` to switch it: `none` offers nothing
  newer (the app is up to date), `forbidden` answers 403 (GitHub's rate limit), `publish` offers
  N+1 again.
- **Install:** let N install N+1 the way the walkthrough says (its menu's Update item, or an
  automatic update mode with a short `update_check_interval_seconds`). N quits to install.
- **After:** call `qa_relaunched_app`. It waits up to `wait_seconds` (60 by default) for the
  update helper to ask for the app again, starts it and returns its new `pid` with the `version`
  and `build` it runs: N+1 after an install, N after a rollback. Use that PID from then on, let the
  window settle as in step 4, and `qa_screenshot` it. When it fails with `qa_no_relaunch`, check the
  first app with `qa_check_app` and the feed with `qa_update_feed`, then call it again once.

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
   - any other control: `qa_click` it;
   - a step that hovers over something (to show a button, a highlight) or right-clicks it: use
     `qa_hover` or `qa_context_menu` on it, and screenshot the state it shows.
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
   The tree shows what is there; how it looks is judged by sight in the Design check (step 8).
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
8. **Design check.** Run the light and dark launches above for every UI deliverable and report
   one step per deliverable named `Design check: <deliverable>` (for example
   `Design check: status-bar menu`). Put both screenshots in its `evidence`, and in `details` name
   the design it compared with (the Screens document or HTML screen, and the screen in it, or
   "the design system alone: no Screens cover it") and the size it judged. `pass` when both
   screenshots match the design; `fail` when either visibly differs, naming what differs.
9. **Wide pass.** Layout bugs that only show in wide windows (a layout loop, a constraint
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
   with no `qa_resize_window` call as `inconclusive`, because its wide pass did not run, and runs
   QA again. In an epic review that launches no app, because the epic changed none, there is no
   wide pass to run. Outside an epic review, a change with nothing on screen to judge owes no wide
   pass either: build the app, launch it, call `qa_check_app`, and answer `pass` with
   `"scope": "none"` and the reason.
10. Run `qa_quit_app` when you are done. It returns what the app wrote to its output; quote
   the lines that bear on a step in that step's `details`.
11. Attach the screenshots that show each step's result with `linear_attach_file`
   (`make_public: false`) and list the returned URLs in that step's `evidence`.

Verdicts for this playbook:

- A `Design check` whose light or dark screenshot visibly differs from the design (a misaligned
  or clipped control, wrong spacing, unreadable contrast, a wrong symbol or wording, an unfinished
  look) is a failing step, even when the tree shows every control: in `details` and `findings`
  name what differs from which screen of the design, and attach the screenshot that shows it.
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
