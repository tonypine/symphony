# Symphony menu bar app

A macOS menu bar app for Symphony. Its menu shows Symphony's status, and has Start Symphony, Stop Symphony,
Pause Dispatch, Resume Dispatch, Open Dashboard, Open Logs, Settings… and Quit.

The app runs Symphony with your `symphony.yml`, the same as running it from a terminal. Release builds
carry a self-contained Symphony binary at `Contents/Resources/symphony` (see [Releasing](../docs/releasing.md))
and run it by default, so they need no checkout, `mise` or Elixir. Turn on **Development mode** in Settings
to run the `bin/symphony` in a checkout instead, for working on Symphony itself.

## Prerequisites

- macOS 13 or later.
- Xcode, or the Command Line Tools (`xcode-select --install`). `swift --version` should work.
- A `symphony.yml`. A release build needs nothing else; a local `make` build has no embedded Symphony, so
  it also needs Development mode and a Symphony checkout with `bin/symphony` built, as in the
  [Quickstart](../README.md#quickstart) steps 2–4:

  ```bash
  mise trust && mise install
  mise exec -- mix setup
  mise exec -- mix build              # writes bin/symphony
  mise exec -- ./bin/symphony init    # writes symphony.yml in the current folder
  ```

- A Linear personal API key. You enter it in the app, so you don't need to export `LINEAR_API_KEY`.

## Build and install

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
certificate, and `SHORT_VERSION=` / `BUILD_NUMBER=` to set the versions in `Info.plist`.

Use `make install` and open the installed copy if you want Launch at Login:

```bash
open ~/Applications/Symphony.app
```

The app has no Dock icon or window of its own; look for its icon in the menu bar.

## First run

1. Open the app. The Settings window opens because no `symphony.yml` is set yet.
2. **symphony.yml:** choose the operator config to run with.
3. **Development mode:** leave it off to run the Symphony embedded in the app. Turn it on for a local `make`
   build, or to run a checkout, then set:
   - **Checkout folder:** the Symphony checkout, the folder that contains `bin/symphony`.
   - **Command prefix:** leave `mise exec --` so Symphony runs with the checkout's `mise` toolchain. Clear
     it if `bin/symphony` runs without `mise`.
4. **LINEAR_API_KEY:** paste your Linear API key. Add any other variables your `symphony.yml` or agents
   need (for example a GitHub token) with Add Variable.
5. Click **Save**. The app checks that the paths exist (and, with Development mode off, that the app has an
   embedded Symphony) and that the key is set, then stores the key in the
   login Keychain. macOS may ask to allow Keychain access; choose Always Allow.
6. Choose **Start Symphony** from the menu. The icon shows `hourglass` while Symphony starts, then
   `music.note.list` once it answers. Choose **Open Dashboard** to see it at `http://127.0.0.1:4000`.

If the icon turns to a warning triangle instead, choose **Open Logs** and see [Troubleshooting](#troubleshooting).

## Menu commands

- The line under the status names the Symphony that Start runs: `Symphony v1.2.3 (embedded)`, or
  `Development: ~/path/to/checkout` in Development mode.
- **Start Symphony** starts Symphony as a child of the app.
- **Stop Symphony** stops it and the agent runs it started. To let runs finish first, pause dispatch and
  wait until the menu shows `0 running`.
- **Pause Dispatch** holds new dispatch: Symphony picks up no new issues, but agent runs already under way
  continue. The pause is kept across restarts.
- **Resume Dispatch** lets Symphony pick up new issues again.
- **Open Dashboard** opens the dashboard in the browser, and **Open Logs** opens Symphony's output log.
- **Check for Updates…** looks for a newer Symphony release. When there is one, the menu shows
  **Update available: vX (N changes)** and **Release Notes…**.
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
- `symphony.yml` path, Development mode, checkout folder, command prefix (`mise exec --` until you change
  it), stop timeout and "Start Symphony when the app opens" are stored in UserDefaults (`defaults read com.tonypine.symphony.bar`).
- Max concurrent agents (1–10) is `agent.concurrency.max_total` in the `symphony.yml` itself. The window
  reads it from the file each time it opens (10, Symphony's default, when the key is missing). Save changes
  only that line and keeps comments and indentation, adding the key when it is missing. Symphony
  reloads `symphony.yml` while it runs, so the new limit applies within a minute without a restart. More
  agents use the Linear and GitHub API budgets faster; 2–3 is a safe range on a personal Linear key.
- `LINEAR_API_KEY` and any extra environment variables are stored only in the login Keychain, as generic
  passwords under service `symphony` with the variable name as the account:

  ```bash
  security find-generic-password -s symphony -a LINEAR_API_KEY
  ```

Because the app is ad-hoc signed, its signature changes on every rebuild, so macOS may ask again for
Keychain access after a rebuild. Choose Always Allow to stop the prompt for that build.

## Running Symphony

Start Symphony sets the Keychain variables only in Symphony's environment (never on its command line).
With Development mode off it runs the embedded binary directly, without a shell, in the folder that holds
`symphony.yml`:

```bash
/Applications/Symphony.app/Contents/Resources/symphony --config /path/to/symphony.yml
```

In Development mode it runs this in the checkout folder:

```bash
/bin/zsh -lc 'exec mise exec -- ./bin/symphony --config /path/to/symphony.yml'
```

The login shell loads your zsh profile, so a Finder-launched app still finds `mise`; `/opt/homebrew/bin`,
`/usr/local/bin` and `~/.local/bin` are also appended to PATH. Build `bin/symphony` first with
`mise exec -- mix build`. An empty `LINEAR_API_KEY` counts as not set, and Start asks you to add one.

- Output goes to `~/Library/Logs/symphony/menubar-child.log`. Each start moves the previous log to
  `menubar-child.log.1`.
- Symphony runs in its own process group. Stop sends SIGTERM to the group and SIGKILL after the stop
  timeout. Agent CLIs run in their own sessions (Erlang starts port programs that way), so the app also
  tracks Symphony's process tree and kills anything still left once Symphony exits.
- Quit stops Symphony first. If agent runs are active (per `/api/v1/state`), or that can't be checked,
  it asks before quitting.
- If Symphony exits without being asked to, the app posts a notification (or shows an alert when
  notifications are off).
- "Start Symphony when the app opens" starts it at launch.

## Launch at Login

The Launch at Login toggle in Settings registers the app with macOS as a login item
(`SMAppService.mainApp`), so it is listed in System Settings → General → Login Items. The toggle shows
what macOS reports, so turning the app off in System Settings turns the toggle off too. If macOS asks you
to allow it, Save opens Login Items, and Settings shows a note until you do. With "Start Symphony when the
app opens" also on, Symphony is running after login with no clicks.

macOS opens the copy that was registered, so install the app first and turn the toggle on from that copy:

```bash
make install
open ~/Applications/Symphony.app
```

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
the app attaches to it as "running (external)": Start and Stop stay disabled, so the app neither starts a
second Symphony nor stops one it doesn't own. Open Dashboard opens the control URL in the browser; Open Logs
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

## Updates

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

## Troubleshooting

- **macOS says the app can't be opened or is from an unidentified developer.** The app is ad-hoc signed,
  not notarized. A copy built on this Mac normally opens directly; a copy that was downloaded or copied
  from elsewhere may be blocked. Right-click the app and choose Open, or on macOS 15 and later open System
  Settings → Privacy & Security and click Open Anyway.
- **macOS asks for Keychain access again after a rebuild.** Each build has a new ad-hoc signature, so the
  Keychain treats it as a new app. Enter your login password and choose Always Allow; the prompt stops
  until the next rebuild.
- **Start Symphony shows a message instead of starting.** The app checks the settings before it starts
  Symphony. "Linear API key not set" and the path messages are fixed in Settings. "This build has no
  embedded Symphony" means a local `make` build: turn on Development mode and set the checkout folder.
  "`…/bin/symphony` was not found" means the checkout isn't built yet: run `mise exec -- mix build` in it.
- **The icon shows a warning triangle right after Start.** Symphony exited. Choose Open Logs, or read
  `~/Library/Logs/symphony/menubar-child.log` (the run before is in `menubar-child.log.1`). Common causes:
  - `mise: command not found`: install `mise`, or clear the command prefix if you don't use it.
  - Symphony rejected `symphony.yml`: run the same command from a terminal to see the error, for example
    `Symphony.app/Contents/Resources/symphony --config <symphony.yml>`, or in Development mode
    `cd <checkout> && mise exec -- ./bin/symphony --config <symphony.yml>`.
- **The menu shows "running (external)" and Start is disabled.** A Symphony started elsewhere (for example
  from a terminal) is answering on the control URL. Stop that one first, then Start from the menu.
- **Pause or Resume shows an error under the status.** The app could not reach Symphony's control API or
  its token was rejected; the message says which. See [Pause and Resume](#pause-and-resume).

`SymphonyBarCore` holds pure logic that is unit tested without AppKit; `SymphonyBar` is the AppKit app.
