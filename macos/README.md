# Symphony menu bar app

A macOS menu bar app for Symphony. Its menu shows Symphony's status, and has Start Symphony, Stop Symphony,
Open Dashboard, Open Logs, Settings… and Quit.

Requires macOS 13+ and Xcode or the Command Line Tools.

```bash
cd macos
make        # builds an ad-hoc-signed build/Symphony.app
make run    # builds and opens it
make test   # runs swift test
make clean  # removes build/ and .build/
```

The app is ad-hoc signed, so on first open Gatekeeper may ask you to confirm it
(right-click the app and choose Open).

## Settings

Settings… (⌘,) opens the Settings window. It also opens on first launch, while no checkout folder is set.

- Checkout folder, `symphony.yml` path, command prefix (`mise exec --` until you change it), stop timeout
  and "Start Symphony when the app opens" are stored in UserDefaults (`defaults read com.tonypine.symphony.bar`).
- `LINEAR_API_KEY` and any extra environment variables are stored only in the login Keychain, as generic
  passwords under service `symphony` with the variable name as the account:

  ```bash
  security find-generic-password -s symphony -a LINEAR_API_KEY
  ```

Because the app is ad-hoc signed, its signature changes on every rebuild, so macOS may ask again for
Keychain access after a rebuild. Choose Always Allow to stop the prompt for that build.

## Running Symphony

Start Symphony runs this in the checkout folder, with the Keychain variables set only in that process's
environment (never on its command line):

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

## Status

The app polls `GET /api/v1/state` on the URL in `~/Library/Application Support/symphony/control_url`
(`http://127.0.0.1:4000` when that file is missing) every 5 seconds, and every second while Symphony starts.
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

`SymphonyBarCore` holds pure logic that is unit tested without AppKit; `SymphonyBar` is the AppKit app.
