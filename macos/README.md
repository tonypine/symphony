# Symphony menu bar app

A macOS menu bar app for Symphony. Its menu has Start Symphony, Stop Symphony, Settings… and Quit.

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

`SymphonyBarCore` holds pure logic that is unit tested without AppKit; `SymphonyBar` is the AppKit app.
