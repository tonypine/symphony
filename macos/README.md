# Symphony menu bar app

Symphony for macOS is a menu bar app, `Symphony.app`. Its menu shows Symphony's status, and has Start
Symphony, Stop Symphony, Restart Symphony, Pause Dispatch, Resume Dispatch, Open Dashboard, Open Dashboard in
Terminal, Open Logs, Check for Updates…, Settings… and Quit.

The app runs Symphony with your `symphony.yml`, the same as running it from a terminal. A release carries a
self-contained Symphony binary at `Contents/Resources/symphony` (see [Releasing](../docs/releasing.md)), so
you need no checkout, `mise` or Elixir: download the app, choose a `symphony.yml`, paste a Linear API key,
and start it. To work on Symphony itself, build the app from source and run a checkout instead; see
[Development mode](#development-mode).

- [Install](#install)
- [First run](#first-run)
- [Restart](#restart)
- [Update](#update)
- [Rollback](#rollback)
- [Development mode](#development-mode)
- [QA mode](#qa-mode)
- [Troubleshooting](#troubleshooting)

## Install

Symphony.app needs a Mac with Apple silicon and macOS 13 or later. Install it with the install script or by
hand. Both put it at `~/Applications/Symphony.app`, which is where the app updates itself and where Launch
at Login expects it.

### With the install script

```bash
curl -fsSL https://raw.githubusercontent.com/tonypine/symphony/main/scripts/install-macos.sh | bash
```

[`scripts/install-macos.sh`](../scripts/install-macos.sh) prints each step as it:

1. finds the latest release and downloads its zip;
2. checks the zip's SHA-256 against the published `.sha256`;
3. checks its minisign signature against the Symphony release key, when `minisign` is installed
   (`brew install minisign`). Without `minisign` it says so and relies on the SHA-256 only;
4. unzips it and checks the app's code signature;
5. moves it to `~/Applications/Symphony.app`, keeping an older installed version as
   `Symphony (previous).app` (see [Rollback](#rollback));
6. clears the quarantine flag (`xattr -dr com.apple.quarantine`) so Gatekeeper doesn't block it, and opens
   it.

Running it again when the latest release is already installed changes nothing and just opens the app. It
refuses to replace an app that is running: choose Quit from the menu first. If any check fails, nothing is
installed. Optional environment variables:

| Variable | Effect |
| --- | --- |
| `INSTALL_DIR` | install somewhere other than `~/Applications` |
| `SYMPHONY_RELEASE_TAG` | install that release instead of the latest, for example `v0.0.1.81` |
| `SYMPHONY_MINISIGN_PUBLIC_KEY` | verify with this minisign public key instead of the Symphony release key |
| `SYMPHONY_NO_OPEN=1` | don't open the app at the end |

For example, to pin a version:

```bash
curl -fsSL https://raw.githubusercontent.com/tonypine/symphony/main/scripts/install-macos.sh | SYMPHONY_RELEASE_TAG=v0.0.1.81 bash
```

### By hand

1. Download `Symphony-<version>.zip` and `Symphony-<version>.zip.sha256` from the
   [latest release](https://github.com/tonypine/symphony/releases/latest).
2. Verify the download, in the folder that holds both files:

   ```bash
   shasum -a 256 -c Symphony-<version>.zip.sha256
   ```

   To also check the minisign signature, download the `.zip.minisig` too and run the `minisign` command from
   the release notes.
3. Unzip it into `~/Applications` and open it:

   ```bash
   mkdir -p ~/Applications
   ditto -x -k Symphony-<version>.zip ~/Applications
   open ~/Applications/Symphony.app
   ```

4. The app is not notarized by Apple, so macOS blocks a downloaded copy the first time: it says the app
   can't be opened or can't be checked for malicious software. Click Done, open System Settings → Privacy &
   Security, scroll to Security, click **Open Anyway** next to "Symphony.app was blocked", and confirm with
   your password. macOS remembers the choice for this copy. To skip the prompt, clear the quarantine flag
   before opening it instead:

   ```bash
   xattr -dr com.apple.quarantine ~/Applications/Symphony.app
   ```

The app has no Dock icon or window of its own; look for its icon in the menu bar.

## First run

A release app needs only two things: a `symphony.yml` and a Linear personal API key. You don't need to
export `LINEAR_API_KEY`; the app keeps it in a file only you can read.

1. Open the app. The Settings window opens because no `symphony.yml` is set yet.
2. **symphony.yml:** choose the operator config to run with. To make one, see the
   [Quickstart](../README.md#quickstart); `~/Applications/Symphony.app/Contents/Resources/symphony init` writes a starter
   `symphony.yml` in the current folder.
3. **LINEAR_API_KEY:** paste your Linear API key (Linear → Settings → Security & access → Personal API keys).
   Add any other variables your `symphony.yml` or agents need (for example a GitHub token) with Add
   Variable.
4. Leave **Development mode** off, so the app runs the Symphony embedded in it.
5. Click **Save**. The app checks that `symphony.yml` exists, that the app has an embedded Symphony and that
   the key is set, then stores the key in the secrets file (see [Settings](#settings)).
6. Choose **Start Symphony** from the menu. The icon shows `hourglass` while Symphony starts, then
   `music.note.list` once it answers. Choose **Open Dashboard** to see it at `http://127.0.0.1:4000`.

If the icon turns to a warning triangle instead, choose **Open Logs** and see [Troubleshooting](#troubleshooting).
To have Symphony running after login with no clicks, turn on Launch at Login and "Start Symphony when the
app opens" in Settings (see [Launch at Login](#launch-at-login)).

## Menu commands

- The line under the status names the Symphony that Start runs: `Symphony v1.2.3 (embedded)`, or
  `Development: ~/path/to/checkout` in Development mode.
- **Start Symphony** starts Symphony as a child of the app.
- **Stop Symphony** stops it and the agent runs it started. To let runs finish first, use Restart Symphony,
  or pause dispatch and wait until the menu shows `0 running`.
- **Restart Symphony** checks `symphony.yml`, waits for agent runs to finish, then stops and starts Symphony
  and resumes dispatch. See [Restart](#restart). While it waits, **Restart Now Anyway** (after the restart
  timeout) and **Cancel Restart** also show.
- **Pause Dispatch** holds new dispatch: Symphony picks up no new issues, but agent runs already under way
  continue. The pause is kept across restarts.
- **Resume Dispatch** lets Symphony pick up new issues again.
- **Open Dashboard** opens the dashboard in the browser, and **Open Logs** opens Symphony's output log.
- **Open Dashboard in Terminal** opens a Terminal window running `symphony dashboard`: the live terminal
  dashboard (running agents, retry queue, recent events) of the Symphony the app watches. It runs the same
  binary as Start (`bin/symphony` from the checkout in Development mode). Press `q` or Ctrl-C, or close the
  window, to quit; Symphony keeps running.
- **Check for Updates…** looks for a newer Symphony release. When there is one, the menu shows
  **Update available: vX (N changes)**, **Update to vX** and **Release Notes…**.
- **Update to vX** downloads and verifies the release, waits for agent runs like Restart, then swaps the app
  and relaunches it. See [Install an update](#install-an-update).
- **Quit** stops Symphony first and asks before stopping active agent runs.

The sections below describe each in detail.

## Settings

Settings… (⌘,) opens the Settings window. It also opens on first launch, while no `symphony.yml` is
set (or, in Development mode, no checkout folder).

- **Development mode** (off by default) runs the checkout's `bin/symphony` instead of the embedded
  Symphony. The checkout folder and command prefix show only while it is on. With it off, Save needs only
  `symphony.yml` and `LINEAR_API_KEY`, and reports "This build has no embedded Symphony; turn on Development
  mode in Settings." for a local `make` build. The first time this version opens, Development mode is turned
  on if a checkout folder is already set and the app has no embedded Symphony, so existing setups keep
  running their checkout.
- **Restart timeout** (1–1440 minutes, 30 by default) is how long Restart Symphony waits for agent runs
  before it also offers Restart Now Anyway.
- `symphony.yml` path, Development mode, checkout folder, command prefix (`mise exec --` until you change
  it), stop timeout, restart timeout and "Start Symphony when the app opens" are stored in UserDefaults (`defaults read com.tonypine.symphony.bar`).
- Max concurrent agents (1–10) is `agent.concurrency.max_total` in the `symphony.yml` itself. The window
  reads it from the file each time it opens (10, Symphony's default, when the key is missing). Save changes
  only that line and keeps comments and indentation, adding the key when it is missing. Symphony
  reloads `symphony.yml` while it runs, so the new limit applies within a minute without a restart. More
  agents use the Linear and GitHub API budgets faster; 2–3 is a safe range on a personal Linear key.
  Each epic under way keeps one agent for its sub-tickets and the tickets blocking them
  (`agent.concurrency.epic_lanes`, default every slot), so 3 agents can mean 3 epics at once, or 2 epics plus 1 for other work. Merge (landing) runs and
  Auto Review QA passes don't use these agents; up to `agent.concurrency.finishing_max` (default 2) of them
  run on top.
- **Models** sets the provider, model and effort for each kind of run, also in the `symphony.yml` itself.
  The **Scope** picker chooses which `agent` block the rows edit: **All repositories** is the top-level
  `agent` section, and each `repositories[]` key edits that repository's `repositories[<key>].agent`
  overrides. The Default row is `agent.provider` / `agent.model` / `agent.effort`, and each run kind row
  (breakdown, close-out, final verification, implementation, rework, CI fix, review feedback, landing,
  pre-push review, QA) is `agent.run_profiles.<kind>.provider` / `.model` / `.effort` (the same keys under
  the repository's `agent` for a repository scope). A field left unset shows, greyed out, the value it
  inherits, resolved the way Symphony does: the repository's kind, the repository's Default row, the
  All repositories kind, the All repositories Default row, then `agent.command` and the `anthropic` provider.
  In a repository scope each row has **Reset to inherited**, which removes the row's keys on save, then a
  kind, `run_profiles:` or repository `agent:` left empty.
  - **Provider** is Anthropic (the default) or OpenRouter. Changing it clears the row's own model.
  - **Model**: for Anthropic, Opus 5.5 (`claude-opus-5-5`), Sonnet 5.5 (`claude-sonnet-5-5`) and Haiku 4.5
    (`claude-haiku-4-5-20251001`), plus any other value already in the file. For OpenRouter, a searchable
    list of the OpenRouter models that support tools (loaded from `GET /api/v1/models` once an OpenRouter
    key is entered); with no key the field points to the OpenRouter section instead.
  - **Effort**: low, medium, high, xhigh and max. It is off, with a tooltip saying why, for an OpenRouter
    model that doesn't list `reasoning`.

  Save writes only the fields you changed: it rewrites that one value (keeping a trailing comment), or
  inserts the key, the kind (as `breakdown: { effort: high }`, or as an indented block when the other kinds
  are written that way, and always as a block in a repository) and `run_profiles:` / `agent:` when they are
  missing. Choosing "default" removes the key, then a kind or `run_profiles:` left empty. Comments and other
  keys stay as they are, in block or `{ ... }` style, and a file you didn't change is never rewritten. Before
  writing, Save runs `symphony check` on a copy of the changed file next to it, with the form's settings and
  keys; when the check fails (for example an OpenRouter model without tools), its message shows in the Models
  section and nothing is saved. A layout the editor can't change, such as `agent: { ... }` on one line, turns
  the pickers off with an error naming the line. Symphony rejects `--model` or `--effort` in `agent.command`
  once any model, effort or kind is set (top-level or in a repository), so when `agent.command` passes them
  the Default row shows their values (for example "Opus 5.5, from command"), and the first save that sets a
  model or effort moves them out of the command (keeping the rest of the line and its comment) into
  `agent.model` / `agent.effort`, unless you set the Default row in the same save. In the same way, once a
  save sets the Default row or the pre-push review row, `--model` / `--effort` in `pre_push_review.command`
  move into `pre_push_review.model` / `pre_push_review.effort` (a key already there wins), and once it sets the
  Default row or the QA row, those in `auto_review.command` move into `auto_review.model` /
  `auto_review.effort`. A provider alone moves nothing. Higher effort and bigger models use the shared
  5-hour usage limit faster. The next run picks the change up without a restart. The Codex runtime ignores
  these keys (see [Run profiles](../docs/configuration.md)).
- `LINEAR_API_KEY` and any extra environment variables are stored only in
  `~/Library/Application Support/symphony/release/secrets.json`, next to Symphony's `control_token`, as a
  JSON object of variable name to value. The file is readable only by you (`0600`), and agents' sandboxes
  can't read `~/Library/Application Support`. Unlike the Keychain, the file also goes into file backups such
  as Time Machine.
- **OpenRouter** holds the optional `OPENROUTER_API_KEY`, which run profiles with `provider: openrouter`
  need. It is stored in the secrets file like `LINEAR_API_KEY` and passed to Symphony only when set; it is
  never written to `symphony.yml` or UserDefaults. **Test connection** checks the key with OpenRouter
  (`GET /api/v1/key`) and shows its label and credit, or why it was rejected, and the **Models** line counts
  the models OpenRouter offers and how many of them support tools.
- When Save changes `LINEAR_API_KEY`, `OPENROUTER_API_KEY` or an extra variable while Symphony runs, the app
  restarts Symphony the way Restart Symphony does, so it picks up the new environment.

Earlier versions kept these in the login Keychain, which asked for the password again after every update.
The first time a version with the secrets file reads them, it copies each `symphony` Keychain item into the
file and leaves the item in place; after that it never reads the Keychain. That one read may still ask for Keychain
access; choose Allow. Start, Restart, Update and Settings… read the secrets without blocking the menu: while
macOS waits for the password, the menu and the Settings window show "Waiting for Keychain access…", and Save
stays off until the secrets have been read.

## Running Symphony

Start Symphony sets the stored variables only in Symphony's environment (never on its command line).
With Development mode off it runs the embedded binary directly, without a shell, in the folder that holds
`symphony.yml`:

```bash
~/Applications/Symphony.app/Contents/Resources/symphony --config /path/to/symphony.yml
```

In Development mode it runs this in the checkout folder:

```bash
/bin/zsh -lc 'exec mise exec -- ./bin/symphony --config /path/to/symphony.yml'
```

The login shell loads your zsh profile, so a Finder-launched app still finds `mise`. In both modes the app
appends to PATH, after your own PATH: mise's shims folder (`$MISE_DATA_DIR/shims`, else
`~/.local/share/mise/shims`) when it exists, then `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`.
Build `bin/symphony` first with `mise exec -- mix build`. An empty `LINEAR_API_KEY` counts as not set, and
Start asks you to add one.

The embedded Symphony doesn't load your shell profile or activate mise, so agents find tools only through
mise's shims or the Homebrew folders above. A shim picks the tool version each repo asks for (its
`mise.toml` or `.tool-versions`). If an agent reports `command not found` for a tool you installed with mise,
run `mise reshim` so the shim exists, then restart Symphony.

- Output goes to `~/Library/Logs/symphony/menubar-child.log`. Each start moves the previous log to
  `menubar-child.log.1`. The log holds log lines only: Symphony doesn't draw its terminal dashboard into a
  file.
- Symphony runs in its own process group. Stop sends SIGTERM to the group and SIGKILL after the stop
  timeout. Agent CLIs run in their own sessions (Erlang starts port programs that way), so the app also
  tracks Symphony's process tree and kills anything still left once Symphony exits.
- Quit stops Symphony first. If agent runs are active (per `/api/v1/state`), or that can't be checked,
  it asks before quitting.
- A SIGTERM, SIGINT or SIGHUP to the app (a `kill`, or the terminal that started it closing) stops
  Symphony the same way, without asking, before the app exits.
- If Symphony exits without being asked to, the app posts a notification (or shows an alert when
  notifications are off).
- "Start Symphony when the app opens" starts it at launch.

## Launch at Login

The Launch at Login toggle in Settings registers the app with macOS as a login item
(`SMAppService.mainApp`), so it is listed in System Settings → General → Login Items. The toggle shows
what macOS reports, so turning the app off in System Settings turns the toggle off too. If macOS asks you
to allow it, Save opens Login Items, and Settings shows a note until you do. With "Start Symphony when the
app opens" also on, Symphony is running after login with no clicks.

macOS opens the copy that was registered, so [install](#install) the app to `~/Applications` first and turn
the toggle on from that copy. Updates keep the same path, so the login item keeps working after an update.

## Status

The app polls `GET /api/v1/state` on the URL in `<state root>/control_url` (`http://127.0.0.1:4000` when that
file is missing) every 5 seconds, and every second while Symphony starts.
It keeps App Nap off so the poll keeps that pace in the background.

| Icon | Status |
| --- | --- |
| `stop.circle` | stopped: nothing answers |
| `hourglass` | starting: the app started Symphony and it hasn't answered yet |
| `music.note.list` | running |
| `pause.circle` | paused, for example from the dashboard |
| `exclamationmark.triangle` | error: Symphony exited unexpectedly, stopped answering, or answered with an error |

While Symphony answers, the menu shows `N running · M retrying`, and while dispatch is paused, the pause
reason and since when. If a Symphony the app didn't start (for example one started from the CLI) answers,
the app attaches to it as "running (external)": Start, Stop and Restart stay disabled, so the app neither
starts a second Symphony nor stops one it doesn't own. Open Dashboard opens the control URL in the browser; Open Logs
opens `menubar-child.log`.

## Pause and Resume

Pause Dispatch holds new dispatch; agent runs already under way continue. It calls
`POST /api/v1/control/pause` with `{"reason":"paused from menu bar"}`, and Resume Dispatch calls
`POST /api/v1/control/resume`, both with the bearer token in `<state root>/control_token`. Pause is offered
while Symphony is running and Resume while it's paused, including for a Symphony the app didn't start.
Symphony keeps the pause across restarts, so a restarted Symphony stays paused until you resume it. If the
request fails (no token file, HTTP 401 for a wrong token, nothing answering), the menu shows why under the
status until the next Pause or Resume.

The state root is found as Symphony finds it:

- `SYMPHONY_STATE_ROOT`, from the app's environment or from the variables Start Symphony last used.
- Otherwise `~/Library/Application Support/symphony` or, for the Burrito release build, its `release/`
  subdirectory. The app can't tell which build runs, so it uses the one whose `control_url` was written
  last, then the one holding a `control_token`.

## Restart

Restart Symphony restarts a Symphony the app started without ending agent runs. It is disabled for a
Symphony the app didn't start ("running (external)"), and Start, Stop, Pause and Resume are disabled while it
runs. The line under the status shows each step:

1. **Check symphony.yml:** runs `symphony check --config <symphony.yml>` with the same binary and
   environment Start uses (in Development mode, through the same login shell and command prefix). If the
   check fails, an alert and a menu line show its error, and Symphony keeps running untouched.
2. **Pause dispatch,** unless it is already paused. The restart remembers whether it paused it.
3. **Wait for agent runs:** the menu shows "Waiting for N agent runs…" until a poll shows dispatch paused and
   `0 running`. After the restart timeout (Settings, 30 minutes by default) **Restart Now Anyway** also shows;
   it stops Symphony and the runs still active. **Cancel Restart** stops waiting and resumes dispatch if the
   restart paused it.
4. **Stop, then Start** with the configured `symphony.yml`.
5. **Wait until Symphony answers** on its control URL, then **resume dispatch**, only if the restart paused it.
   A pause you made before the restart stays, because Symphony keeps pauses across restarts.

If Symphony doesn't come back (Start fails, it exits, or it doesn't answer within 2 minutes) an alert and the
menu say why and name the log. A pause the restart made is then kept; choose Resume Dispatch once Symphony
runs.

## Update

When a newer release is out, the menu shows **Update available: vX (N changes)**. Choose **Update to vX**:
the app downloads and verifies it, lets agent runs finish, swaps itself for the new version and relaunches,
with Symphony running again. The steps are under [Install an update](#install-an-update). You can also
update by running the [install script](#with-the-install-script) again after quitting the app.

The app checks the latest release at
`https://api.github.com/repos/tonypine/symphony/releases/latest` at launch, every 6 hours, and when you
choose Check for Updates. The request carries no token. It sends the last response's `ETag` in
`If-None-Match`, so an unchanged release answers 304 Not Modified, which doesn't count against GitHub's
rate limit of 60 unauthenticated requests an hour.

A release counts only when it has `version.json` and the zip and `.sha256` that `version.json` names (see
[docs/releasing.md](../docs/releasing.md)). The app compares `version.json` `build` with its own
`CFBundleVersion`. When the release is newer, the menu shows **Update available: vX (N changes)**, taking
N from the first line of the release notes ("12 changes since v…") or else from `version.json` `changes`.
Choosing it, or **Release Notes…**, shows the notes in a scrollable window with **Open Release Page**.

A development build (one without Symphony embedded at `Contents/Resources/symphony`, such as a plain
`make`) still shows the indicator, labelled `· development build`. A local build keeps the `CFBundleVersion`
of `Info.plist`, so it usually sees every release as newer.

Background checks fail silently. When you choose Check for Updates, the result shows under it: "Symphony
is up to date (vX)" or why the check failed, for example GitHub's rate limit.

### Install an update

**Update to vX** shows under Update available. After you confirm, the line under it shows each step:

1. **Download** the release zip, its `.sha256` and its `.minisig` into
   `~/Library/Caches/com.tonypine.symphony.bar/updates/`.
2. **Verify** the zip's SHA-256 against the `.sha256`, then its minisign signature against the public key
   built into the app (checked with CryptoKit; the `minisign` tool isn't needed). The update is refused,
   with an alert that says why, on any mismatch.
3. **Unzip** it with `ditto` and check the new app: `codesign --verify --strict` passes, it is Symphony
   (same bundle identifier), its build is newer, and it is signed with the same certificate as the running
   app.
4. **Drain Symphony** like [Restart](#restart), checking `symphony.yml` with the running Symphony: pause
   dispatch, wait for `0 running` (**Update Now Anyway** shows after the restart timeout, **Cancel Update**
   stops waiting), then stop Symphony. A Symphony the app didn't start is left alone. Nothing runs the new
   version's Symphony yet: running it removes older versions' unpacked releases from
   `~/Library/Application Support/.burrito/`, including the one the running Symphony loads its code from.
5. **Swap and relaunch:** the app starts a small helper (`Contents/Resources/update-helper.sh`, run from a
   copy in the cache folder) and quits. Once the app has exited, the helper moves it to
   `Symphony (previous).app` next to it (replacing an older one), moves the new app into place, and opens
   it. If a move fails, it puts the old app back and opens that instead. Its log is
   `~/Library/Caches/com.tonypine.symphony.bar/update-helper.log`.
6. **Bring Symphony back:** the relaunched app starts Symphony from its new embedded binary, which removes
   the old version's unpacked release, and, once it answers, resumes dispatch if the update paused it. A
   pause you made before the update stays. If the helper had to put the old app back, an alert says so.

Update is disabled, with the reason under it, when:

- the app is a development build (no embedded Symphony), or Development mode is on;
- the app was built without an update signing key (`MINISIGN_PUBLIC_KEY`, see
  [docs/releasing.md](../docs/releasing.md));
- the app's folder isn't writable, for example when macOS runs a downloaded app from a read-only
  translocated copy. Move `Symphony.app` to `~/Applications` and open it from there.

An app signed ad hoc refuses updates: there is no certificate to compare the new app's with. Install the
release with the [install script](#with-the-install-script) instead; it keeps the old app as
`Symphony (previous).app` too.

To undo an update, see [Rollback](#rollback).

## Rollback

Each update, and each install over an older version, keeps the version it replaced next to the app as
`Symphony (previous).app`, for example `~/Applications/Symphony (previous).app`. Only one previous version is
kept. To go back to it:

1. Choose **Quit** from the menu (this stops Symphony).
2. Swap the two apps, in Finder or a terminal:

   ```bash
   cd ~/Applications
   mv Symphony.app "Symphony (rolled back).app"
   mv "Symphony (previous).app" Symphony.app
   ```

3. Open `Symphony.app` and start Symphony. Your settings and stored variables carry over. A version from
   before the secrets file reads the variables from the login Keychain instead, as they were when they were
   copied into the file, so a variable changed in Settings since then has its old value there. Delete
   `Symphony (rolled back).app` once you no longer need it.

The app then offers the newer release again as an update. To install an older release than the previous
one, quit the app and run the install script with `SYMPHONY_RELEASE_TAG` set to that release's tag (see
[With the install script](#with-the-install-script)).

## Development mode

Development mode is for working on Symphony itself: the app runs `bin/symphony` from a checkout, through
`mise`, instead of its embedded Symphony.

### Prerequisites

- Xcode, or the Command Line Tools (`xcode-select --install`). `swift --version` should work.
- A Symphony checkout with `bin/symphony` built, as in the [Quickstart](../README.md#quickstart):

  ```bash
  mise trust && mise install
  mise exec -- mix setup
  mise exec -- mix build              # writes bin/symphony
  mise exec -- ./bin/symphony init    # writes symphony.yml in the current folder
  ```

### Build the app from source

From the checkout:

```bash
cd macos
make          # builds an ad-hoc-signed build/Symphony.app
make install  # builds it and copies it to ~/Applications (set INSTALL_DIR to change)
make run      # builds and opens build/Symphony.app
make test     # runs swift test
make clean    # removes build/ and .build/
make bundle SYMPHONY_BIN=../burrito_out/symphony-macos-arm64   # embeds a Symphony binary, as releases do
```

`make` and `make bundle` sign ad hoc. Pass `SIGNING_IDENTITY="<certificate name>"` to sign with a
certificate, `SHORT_VERSION=` / `BUILD_NUMBER=` to set the versions in `Info.plist`, and
`MINISIGN_PUBLIC_KEY=` to embed the update key. `make install` replaces `~/Applications/Symphony.app`, so it
replaces an installed release too; reinstall the release with the install script afterwards.

A plain `make` build has no embedded Symphony, so it runs only in Development mode, and it can't update
itself.

### Run a checkout

1. Open Settings… and turn on **Development mode**. The first time a version opens, it turns this on itself
   if a checkout folder is already set and the app has no embedded Symphony.
2. **Checkout folder:** the Symphony checkout, the folder that contains `bin/symphony`.
3. **Command prefix:** leave `mise exec --` so Symphony runs with the checkout's `mise` toolchain. Clear it
   if `bin/symphony` runs without `mise`.
4. Click **Save**, then **Restart Symphony** (or Start). The line under the status shows
   `Development: ~/path/to/checkout`.

After changing Symphony, run `mise exec -- mix build` in the checkout and choose Restart Symphony. Turn
Development mode off to go back to the embedded Symphony. You can also run a checkout from a terminal
instead of the app; see [Running](../README.md#running).

## QA mode

QA mode is for test launches, by hand or by a QA agent: the app keeps everything it would store under one
directory and leaves your real settings, secrets and Symphony alone. Auto Review's `macos_app` playbook
always launches the app this way (see [macOS app QA](../docs/configuration.md#macos-app-qa)). Turn it on by starting the app's binary
with `SYMPHONY_BAR_QA_ROOT` set to a directory. A launch from Finder or `open` doesn't pass the variable on, so
run the binary directly:

```bash
SYMPHONY_BAR_QA_ROOT="$(mktemp -d)" ./build/Symphony.app/Contents/MacOS/SymphonyBar
```

In QA mode, under that directory:

| Path | Holds | Instead of |
| --- | --- | --- |
| `settings.plist` | the Settings values, Launch at Login, and the pending update across a relaunch | UserDefaults; Launch at Login registers nothing with macOS |
| `secrets.json` | `LINEAR_API_KEY` and the other variables, readable only by you | `~/Library/Application Support/symphony/release/secrets.json` |
| `logs/` | Symphony's output log | `~/Library/Logs/symphony` |
| `updates/` | update downloads and the update helper's log | `~/Library/Caches/<bundle id>` |
| `state/` | Symphony's state: control URL and token | `~/Library/Application Support/symphony` |

The app starts with empty settings, so Settings opens. It doesn't see a Symphony already running outside QA
mode, so Stop, Restart, Pause and Resume can't reach it, unless `SYMPHONY_STATE_ROOT` is set too, which wins
over `state/`. Start runs only a checkout: with Development mode off it reports "QA mode runs only a
checkout's Symphony; turn on Development mode in Settings." Saving Settings leaves
`~/Library/Application Support/symphony/release/secrets.json` and the login Keychain as they were.

## Troubleshooting

- **The install script says the SHA-256 or minisign signature doesn't match.** The download isn't what was
  published (a broken download, a proxy, or a release still being uploaded), and nothing was installed. Run
  the script again in a few minutes. If it keeps failing, don't install that file; open an issue. A minisign
  key mismatch ("the key id in the public key is …") means `SYMPHONY_MINISIGN_PUBLIC_KEY` isn't the Symphony
  release key: unset it.
- **The install script says Symphony is running.** It doesn't replace an app that is running. Choose Quit
  from the menu, then run it again.
- **The install script says the app's code signature is invalid.** The unzipped app fails
  `codesign --verify --strict` for a reason other than an untrusted certificate, and nothing was installed.
  "signed with the Symphony certificate, which this Mac doesn't trust" is not an error: the release is
  signed with Symphony's own certificate rather than an Apple Developer ID, so the SHA-256 and minisign
  checks vouch for it.
- **macOS says the app can't be opened or is from an unidentified developer.** The app is not notarized by
  Apple, so macOS blocks a downloaded copy that still has the quarantine flag. Open System Settings →
  Privacy & Security and click Open Anyway, or clear the flag with
  `xattr -dr com.apple.quarantine ~/Applications/Symphony.app`. The install script clears it for you.
- **macOS asks for Keychain access.** It asks once, when the first version with the secrets file copies the
  variables an earlier version kept in the login Keychain into
  `~/Library/Application Support/symphony/release/secrets.json`: enter your login password and choose Allow.
  It doesn't ask again, after updates or rebuilds. While the prompt waits, the menu shows "Waiting for
  Keychain access…" and Start stays off; if you can't see the prompt, look behind other windows. If you deny
  it, nothing is copied and the next Start asks again.
- **Start Symphony shows a message instead of starting.** The app checks the settings before it starts
  Symphony. "Linear API key not set" and the path messages are fixed in Settings. "This build has no
  embedded Symphony" means a local `make` build: turn on Development mode and set the checkout folder.
  "`…/bin/symphony` was not found" means the checkout isn't built yet: run `mise exec -- mix build` in it.
- **The icon shows a warning triangle right after Start.** Symphony exited. Choose Open Logs, or read
  `~/Library/Logs/symphony/menubar-child.log` (the run before is in `menubar-child.log.1`). Common causes:
  - `mise: command not found`: install `mise`, or clear the command prefix if you don't use it.
  - Symphony rejected `symphony.yml`: run the same command from a terminal to see the error, for example
    `~/Applications/Symphony.app/Contents/Resources/symphony --config <symphony.yml>`, or in Development mode
    `cd <checkout> && mise exec -- ./bin/symphony --config <symphony.yml>`.
- **The menu shows "running (external)" and Start is disabled.** A Symphony started elsewhere (for example
  from a terminal) is answering on the control URL. Stop that one first, then Start from the menu.
- **Update says "Symphony wasn't updated".** Nothing was replaced. A checksum or signature mismatch means
  the download doesn't match what was published: check again later, or download the release by hand and
  verify it as in [docs/releasing.md](../docs/releasing.md). "the update's signer can't be checked" or "isn't
  signed with the same certificate" means this copy and the release are signed differently: install the
  release with the [install script](#with-the-install-script). A `symphony.yml` error comes from the
  running version's check; Symphony keeps running. A setting only the new version rejects shows up after the
  relaunch, when the new Symphony fails to start: choose Open Logs.
- **Restart Symphony says "Symphony wasn't restarted".** The `symphony.yml` check (or the pause) failed, and
  the old Symphony is still running. Fix what the message names, then check it from a terminal with
  `~/Applications/Symphony.app/Contents/Resources/symphony check --config <symphony.yml>`, or in Development mode
  `cd <checkout> && mise exec -- ./bin/symphony check --config <symphony.yml>`, and restart again.
- **Restart Symphony stays on "Waiting for N agent runs…".** Agent runs are still active. Wait, choose Restart
  Now Anyway once the restart timeout has passed (lower it in Settings), or Cancel Restart.
- **Restart Symphony says "Symphony didn't come back".** Choose Open Logs to see why it didn't start or
  answer. If dispatch stays paused afterwards, choose Resume Dispatch.
- **Pause or Resume shows an error under the status.** The app could not reach Symphony's control API or
  its token was rejected; the message says which. See [Pause and Resume](#pause-and-resume).

`SymphonyBarCore` holds pure logic that is unit tested without AppKit; `SymphonyBar` is the AppKit app.
