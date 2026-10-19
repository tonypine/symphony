# Symphony menu bar app

Symphony for macOS is a menu bar app, `Symphony.app`. Its menu shows Symphony's status, and has Open
Symphony, Start Symphony, Stop Symphony, Restart Symphony, Pause Dispatch, Resume Dispatch, Force a Ticket…,
Check for Updates…, Repos…, Settings…, a Developer submenu (Open Dashboard in Terminal, Open Logs) and Quit.
Open Symphony opens the [Symphony window](#the-symphony-window).

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
- [The Symphony window](#the-symphony-window)
- [Development mode](#development-mode)
- [QA mode](#qa-mode)
- [Troubleshooting](#troubleshooting)

## Install

Symphony.app needs a Mac with Apple silicon and macOS 26 or later. Install it with the install script or by
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
   `music.note.list` once it answers. Choose **Open Symphony** to see it in the Symphony window.

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
- **Pause Dispatch…** opens the Symphony window's Pause Dispatch sheet, with an optional reason. A pause holds
  new dispatch: Symphony picks up no new issues, but agent runs already under way continue. The pause is kept
  across restarts.
- **Resume Dispatch** lets Symphony pick up new issues again.
- **Force a Ticket…** opens the Symphony window's Force a Ticket sheet (also ⇧⌘F in the window), which finds
  the ticket as you type its identifier and shows its title and state, and forces that ticket past the dispatch limits, like
  `symphony force`. The forced tickets are listed above it, each with **Stop forcing**. See
  [Forced tickets](#forced-tickets).
- **Open Symphony** (⌘O) opens the [Symphony window](#the-symphony-window), or brings it to the front.
- **Developer** holds the items for looking under the hood: **Open Logs** opens Symphony's output log, and
  **Open Dashboard in Terminal**
  opens a Terminal window running `symphony dashboard`: the live terminal
  dashboard (running agents, retry queue, recent events) of the Symphony the app watches. It runs the same
  binary as Start (`bin/symphony` from the checkout in Development mode). Press `q` or Ctrl-C, or close the
  window, to quit; Symphony keeps running.
- **Check for Updates…** looks for a newer Symphony release. When there is one, the menu shows
  **Update available: vX (N changes)**, **Update to vX**, **Skip This Version** and **Release Notes…**.
- **Skip This Version** stops offering that release as available: the menu shows **Update skipped: vX**
  instead, and Update to vX still installs it. See [Skip a release](#skip-a-release).
- **Update to vX** downloads and verifies the release, waits for agent runs like Restart, then swaps the app
  and relaunches it. See [Install an update](#install-an-update).
- **Repos…** opens the Repos window: a sidebar of the connected repos and the detail of the selected one
  (its health, source, GitHub remote, Linear routing, `WORKFLOW.md` status, last fetch, running agents and
  manual review, with a **Needs attention** box listing each problem and its fix), **Add Repo…** to connect another, and per repo an **Edit…** on its Source, Linear routing and Review,
  **Disconnect…** and, for a managed clone, **Remove Clone…**. See [Repos](#repos).
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
  before it also offers Restart Now Anyway, and how long Automatically at a set time waits for them before it
  tries again the next day.
- **Update mode** (in **Updates**) is how the app installs a newer release:
  - **Manual**: the menu shows the release and you install it with Update to vX. See [Update](#update).
  - **Automatically when idle** installs a new release by itself as soon as no agent runs are active.
  - **Automatically at a set time** installs a new release by itself each day at the **Time** shown under
    it (03:00 by default, in the Mac's time zone), waiting for agent runs like Update to vX. The time shows
    only for this mode, and is kept when you choose another.
  - **Automatically when released** (the default for every install that never saved an update mode)
    installs a new release by itself as soon as a check finds it, waiting for agent runs like Update to vX.
    Under it, **Check for releases every N minutes** (1–60, 5 by default) sets how often the app checks, and
    a line says what the last check found, with **Check Now**. Both show only for this mode. See
    [How often the app checks](#how-often-the-app-checks).

  In an automatic mode, when this copy can't install updates (a development build, Development mode, no
  update signing key, or an app folder you can't write to), a line under the picker says "▲ This copy can't
  update itself:" and why. The picker stays editable. See [Automatic updates](#automatic-updates).
- `symphony.yml` path, Development mode, checkout folder, command prefix (`mise exec --` until you change
  it), stop timeout, restart timeout, "Start Symphony when the app opens", update mode (`updateMode`),
  update time (`updateTime`, minutes after midnight) and release check interval (`releaseCheckMinutes`) are
  stored in UserDefaults
  (`defaults read com.tonypine.symphony.bar`).
- Max concurrent agents (1–10) is `agent.concurrency.max_total` in the `symphony.yml` itself. The window
  reads it from the file each time it opens (10, Symphony's default, when the key is missing). Save changes
  only that line and keeps comments and indentation, adding the key when it is missing. Symphony
  reloads `symphony.yml` while it runs, so the new limit applies within a minute without a restart. More
  agents use the Linear and GitHub API budgets faster; 2–3 is a safe range on a personal Linear key.
  Each epic under way keeps one agent for its sub-tickets and the tickets blocking them
  (`agent.concurrency.epic_lanes`, default every slot), so 3 agents can mean 3 epics at once, or 2 epics plus 1 for other work. Merge (landing) runs and
  QA passes don't use these agents; up to `agent.concurrency.finishing_max` (default 2) of them
  run on top.
- **Limit tokens per day** and **Limit tokens per ticket** are `agent.limits.tokens_per_day` and
  `agent.limits.tokens_per_issue`, also in the `symphony.yml` itself. A switch turned off writes `null`, which
  turns that cap off; turned on, it shows the number of tokens, with a hint such as `1,000,000,000 = 1B`. A
  missing key shows Symphony's default (5,000,000 a day, 500,000 a ticket). While a changed value is entered,
  the window runs `symphony check` on a copy of the file with it, shows the error inline when the check rejects
  it (for example a negative number) and keeps Save off until it passes. Save writes only the changed lines and
  keeps comments. Below them, today's usage comes from `/api/v1/state`'s `budget`: tokens used and left, when
  the count resets (UTC midnight, shown in local time), and a line while the daily cap has paused new runs.
- **Dispatch loops** holds a ticket Symphony keeps dispatching without progress. **Hold a ticket after** is
  `watchdog.dispatch_loop_runs` in `watchdog.dispatch_loop_window_ms` (4 runs in 10 minutes by default) and **Or
  after** is `watchdog.dispatch_loop_long_runs` in `watchdog.dispatch_loop_long_window_ms` (8 runs in 60
  minutes), each a stepper for the runs and one for the minutes. Once a ticket got that many runs of one kind
  with no state change, new PR head or decision, Symphony starts no more and puts it on a Blocked hold whose
  reason says why; the Inbox lists it with **Unblock…**, and **Restart…** under ⋯. Save runs `symphony check`
  first and writes only the changed lines.
- **Models** sets the provider, model and effort for each kind of run, also in the `symphony.yml` itself.
  The **Scope** picker chooses which `agent` block the rows edit: **All repositories** is the top-level
  `agent` section, and each `repositories[]` key edits that repository's `repositories[<key>].agent`
  overrides. The Default row is `agent.provider` / `agent.model` / `agent.effort`, and each run kind row
  (breakdown, close-out, implementation, rework, CI fix, review feedback, landing,
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
  save sets the Default row or the pre-push review row, `pre_push_review.model` / `pre_push_review.effort`, or
  else `--model` / `--effort` in `pre_push_review.command`, move into the pre-push review row
  (`agent.run_profiles.pre_push_review`), and once it sets the Default row or the QA row, those of
  `auto_review` move into the QA row. Those section keys outrank the rows and name no provider, so left in
  place they would hide the row's choice, and an OpenRouter Default row would make Symphony look their Claude
  model up on OpenRouter. A moved model keeps the provider it ran on, and a value you change in that row in
  the same save wins over the moved one. A provider alone moves nothing. Higher effort and bigger models use the shared
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
| `pause.circle` | paused, for example from the dashboard, or holding runs for a provider usage limit |
| `exclamationmark.triangle` | error: Symphony exited unexpectedly, stopped answering, or answered with an error |

While Symphony answers, the menu shows `N running · M retrying`, and while dispatch is paused, the pause
reason and since when. If a Symphony the app didn't start (for example one started from the CLI) answers,
the app attaches to it as "running (external)": Start, Stop and Restart stay disabled, so the app neither
starts a second Symphony nor stops one it doesn't own. Open Logs opens `menubar-child.log`.

While something waits on you (`waiting_on_you` in `/api/v1/state`, the Inbox's list: plans in
`Plan Review`, open decisions, tickets the quality gate
holds or skipped, and tickets an access hold pauses in place), the icon shows an orange dot and the menu lists them under **Waiting on you**, oldest first,
each with its kind's symbol, for example `TP-123 · Plan · Split the importer into four sub-tickets · 2h`: the
ticket, what it waits for, its one-line ask (its title when it has none) and how long it has waited. Choosing a
row opens the Symphony window on it in the Inbox. The menu lists five; **N more…** opens the Inbox for the rest.

Each poll waits up to 5 seconds for an answer. After one missed poll the menu keeps the last status, with
"Symphony is slow to answer" under it. Only after two missed polls in a row does it show "Symphony isn't
answering" (error) for a Symphony the app started, or stopped for an external one. That grace counts for an
external Symphony too, so Start isn't offered while a busy one still holds the control URL; the cost is that
after an external Symphony exits, Start is offered 5 to 10 seconds later. A Symphony the app started that
exits unexpectedly shows the error at once.

## Usage-limit pause

When Symphony holds runs for a provider usage limit (for example Claude's 5-hour window), it lists the hold
under `usage_limits` in `/api/v1/state`, and the menu adds a line for each hold, in local time with the date
when it isn't today:

- `Paused: Claude limit, resumes ~14:05` while new runs wait for the reset.
- `Resuming: checking Claude limit…` while one canary run checks the limit after the reset.
- `Holding new runs: Claude at 91%, resets ~14:05` while Symphony leaves headroom before the limit runs out.

Symphony holds runs the same way when the model API can't be reached at all (a network or DNS outage), and
the menu reads it as an outage, not a limit:

- `Paused: Claude API unreachable (ENOTFOUND), retries ~14:05` while new runs wait for the next check.
- `Resuming: checking Claude API…` while one canary run checks the API is back.

The icon shows `pause.circle` and the title reads "paused" while any hold is in place. When you have also
paused dispatch, your pause is listed first. Pause Dispatch and Resume Dispatch only control your pause:
Symphony lifts a usage-limit hold on its own.

The app posts a notification when a hold starts, for example "Symphony paused: Claude 5-hour limit, resumes
~14:05" or "Symphony paused: Claude API unreachable", and when a provider's last hold clears, "Symphony
resumed: Claude limit reset" or, after an outage, "Symphony resumed: Claude API reachable again". It posts each once,
not on every poll. A headroom hold or a canary posts nothing, and nothing is posted for a hold already in
place when the app opens or when Symphony starts answering again. While your pause is on, the resume
notification is skipped, since dispatch stays paused.

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
- Otherwise `~/Library/Application Support/symphony` or, for the release Symphony.app runs, its `release/`
  subdirectory. The app can't tell which build runs, so it uses the one whose `control_url` was written
  last, then the one holding a `control_token`.

## Forced tickets

Force a Ticket… opens a sheet that asks for a Linear identifier, for example `TP-123`, and calls `POST /api/v1/control/force`
with `{"identifier":"TP-123"}`, like `symphony force TP-123`. Symphony adds its force label
(`agent.concurrency.force_label`, `expedite` by default) to the ticket, which then skips the slot limits but
still waits for its blockers, a pause, usage limits and its reviews. It is offered while Symphony answers,
including while dispatch is paused. If Symphony refuses (the ticket isn't in Linear or is already done, the
label doesn't exist in Linear, the control token is wrong), an alert says why.

While any ticket is forced, a **Forced** heading lists them under Pause and Resume, in queue order, as
`/api/v1/state` reports them under `forced`:

- `⚡ TP-123 · implementation · running · forced 5m`: the identifier, what the ticket does and waits on,
  as the dashboards word it, and how long it has been forced.
- `⚡ TP-100 → TP-101 · waiting for a human · forced 3d 2h · stale`: a forced parent with the sub-ticket it
  is on, forced for longer than `agent.concurrency.forced_stale_after_hours`.

Each row's submenu has **Stop forcing TP-123**, which removes the force label (`symphony force --clear`).
The menu follows within one poll. A Symphony too old to report forced tickets shows no Forced heading.

## Repos

Repos… opens the Repos window, titled **Repos**: a sidebar of the repos on the left and the detail of the
selected one on the right. It opens at 880×600 the first time and at least 720×460, so it fits a 1024×768
screen; after that it reopens at the size and position it was left at, on the repo selected last.

The toolbar says Symphony's state once, in a chip: **Symphony running**, **Symphony paused**, **Symphony
is starting…**, **Symphony stopped** or **Symphony isn't answering**. Its **+** is **Add Repo…**.

The sidebar lists one row per entry of `repositories:`, in config order: a status glyph, the key, the
`owner/repo` (or the folder name of a local folder whose remote isn't known yet), a **Default** capsule on
the repo that takes the issues no other repo's route matches, and the number of agents running on it. The
glyph differs in shape as well as colour: a green circle for healthy, an orange triangle for needs
attention, a red diamond for not working, and a hollow grey circle for not checked (Symphony isn't
answering with the repos). VoiceOver reads a row as, for example, "symphony, needs attention, default, 2
agents running". A row's context menu has **Edit Linear Routing…**, **Edit
Source…**, **Edit Review…**, **Reveal in Finder**, **Open on GitHub** and **Disconnect…**; **+** and **−** under the list add and disconnect.

While Symphony answers, the detail shows each repo as Symphony's `GET /api/v1/repos` reports it:

- The key, its `owner/repo` as a link to GitHub and the **Default** capsule, then a health line:
  **Healthy**, **1 problem**, **2 problems**, or **Not checked: Symphony is stopped**.
- **Needs attention**, above the sections while the repo has a problem, red when one is an error and orange
  otherwise, one line per problem with its fixes:
  - `WORKFLOW.md` invalid (error): Symphony's error and **Open WORKFLOW.md** (the file in a local folder,
    the file on GitHub at the base branch for a managed clone).
  - `WORKFLOW.md` missing (warning): **Set Up WORKFLOW.md…** opens the Add Repo sheet's WORKFLOW.md page on
    its own (see [Setting up a WORKFLOW.md for a connected repo](#setting-up-a-workflowmd-for-a-connected-repo)).
  - `WORKFLOW.md` pending (warning), for a file the app added that Symphony can't read yet: **View Pull
    Request**, or the file's path and **Reveal in Finder**.
  - The last fetch failed (error): git's error, selectable, **Copy Error** and **Open on GitHub**. Symphony
    tries again before the next dispatch.
  - An agent run with no activity for 10 minutes or more (warning): Symphony's stall timeout should have
    restarted it, so it looks stuck. **Stop Run…** asks first, then asks Symphony's control API to stop it,
    and shows why under the line when it couldn't; **Open in Linear** and **Reveal Worktree**.
  - Under the problems, as information only: Symphony couldn't list the running agents, and a managed
    clone not made yet.

  A problem goes away on the next poll once it clears.
- **Source**: **Local folder** with the checkout agent worktrees are made from, or **Managed clone** for a
  `workspace.source` repo with Symphony's clone or `Not cloned yet: Symphony clones it on the next
  dispatch`; the base branch (origin's default branch when `symphony.yml` names none). A path truncates in the middle,
  shows in full on hover, can be selected, and has **Reveal in Finder**. A managed repo has **Remove
  Clone…** here.
- **Linear routing**: a sentence such as "Issues in billing with label backend go to api.", then the
  project, labels, team and assignee that are set, and for the default repo "It also takes the issues no
  other repo's route matches."
- **WORKFLOW.md**: **Valid**, **Invalid** or **Missing**, in red when it doesn't load, with Symphony's
  error under it. Symphony keeps using the last good workflow until the file is fixed. With the default
  `workflow_source: ref`, this is the file committed on the base branch, so a broken `WORKFLOW.md` pushed
  there shows as invalid even though the last good one still runs. For a repo whose `WORKFLOW.md` Add Repo
  or **Set Up WORKFLOW.md…** added, it shows **Pending: pull request open** with the pull request's URL, or **Pending: written, not
  pushed** with the file's path, until Symphony reports the file valid.
- **Activity**: how long ago Symphony last ran `git fetch origin` before a dispatch, or **Failed** (in
  red, with git's error), or **None yet**; then one line per running agent with its issue, the SSH worker
  it runs on, how long it has run and its last activity, and **Reveal Worktree** for a worktree on this
  Mac. **No agents running** otherwise.
- **Review**: the repo's manual review, **On** or **Off** with what it does (**Off**, the default, when
  `symphony.yml` sets none).
- **Source**, **Linear routing** and **Review** each have an **Edit…** in their header, which opens that
  section's sheet (see [Edit, disconnect or remove a clone](#edit-disconnect-or-remove-a-clone)).
- **Disconnect…** at the foot, in red.

While the window is open it refreshes with each status poll, so an agent run that starts shows up within a
few seconds. ↑ and ↓ move through the sidebar, ⌘N adds a repo, Delete opens the same Disconnect sheet as
**Disconnect…** and **−**, and ⌘W closes the window.

When Symphony is stopped, starting, or not answering, the window lists the repos in the `symphony.yml`
set in Settings instead. Their source, Linear routing and manual review come from the file, and
**WORKFLOW.md** and **Activity** fold into one line: "Live status shows while Symphony runs." with **Start
Symphony** (or that Symphony is starting, or isn't answering). A Symphony too old to serve
`GET /api/v1/repos` shows the same repos with "Update Symphony to see live status."

In place of the repos, the detail shows:

- **No repos connected**, with **Add Repo…**, when `repositories:` is empty (nothing under it, or `[]`) or missing;
- **Symphony doesn't know where its config is.**, with **Open Settings…**, when no `symphony.yml` is set;
- the error, with **Reveal in Finder** and **Try Again**, when the `symphony.yml` can't be read.

### Add a repo

**Add Repo…** (the toolbar's **+**, the **+** under the sidebar, ⌘N, or the button of an empty window) opens
a sheet that adds an entry to `repositories:` in the `symphony.yml` set in Settings. The sheet asks one thing
per page: **Source**, **Linear**, **WORKFLOW.md** (only for a repo that has none) and **Review**. A step
indicator at the top names the pages, and a fixed footer holds **Cancel**, **Back** and **Continue**
(**Connect** on Review). The sheet is 520×520pt, so its footer stays on a 1024×768 screen on every page.
Continue stays off until the page checks out, and its help says why.

**Source.** Pick where the code comes from:

- **GitHub URL:** paste `https://github.com/owner/repo` (a browser URL with more path after it works
  too), `git@github.com:owner/repo.git` or `owner/repo`. The entry gets `workspace.source: owner/repo`:
  Symphony keeps its own clone under `workspaces.clones_root` (`~/.local/share/symphony/repos` by
  default), made when Symphony starts, and never touches a checkout of yours. Its `WORKFLOW.md` comes
  from the repo.
- **Local folder:** **Choose…** a folder in a git checkout. The checkout must have a GitHub `origin` remote.
  The entry gets `workspace.strategy: worktree`, `workspace.repo` and `workflow` set to the checkout's
  top folder and its `WORKFLOW.md`, and agents work in worktrees of it.

Once typing pauses, or a folder is chosen, a line under the source shows what the sheet found: the folder,
`owner/repo`, the default branch, and **has WORKFLOW.md** or **No WORKFLOW.md on main: you can set one up
in a later step**. A folder that isn't a git checkout, or has no GitHub origin, shows the reason in red
instead, and Continue stays off.

**Linear.** The **Project** pop-up lists the projects of the Linear workspace of the `LINEAR_API_KEY` in
Settings; while they load it says so inside the pop-up. **Labels** is a token field that completes from the
labels an issue in the picked project can carry (the workspace's and those of the project's teams), and
takes only those; an issue must carry all of them. A sentence previews the route as it changes: "Issues in
Billing with label backend go to billing-api." A project and labels another repo already takes show that
repo under the labels, and Continue stays off. A failed request (a rejected key, no projects, the network,
a query Linear finds too complex) shows in a warning box under the pickers, which keep their place, with
**Retry** and **Open Settings…**. Each request reads one list in pages of 50, so it stays well under
Linear's query complexity limit.

**Review** sums up the source, the route and what happens to `WORKFLOW.md`, and holds:

- **Repo key**, filled in from the repo name (in lower case, with `-2`, `-3`… when taken) until you
  type one. It holds letters, digits, `.`, `_` and `-`, and must differ from every other key; a key that is
  empty, malformed or taken says so under the field and turns Connect off.
- **Base branch**, the repo's default branch (GitHub's, or the checkout's `origin/HEAD`), else `main`,
  until you change it. For a GitHub URL, a changed branch is checked again for a `WORKFLOW.md`.
- When the file has a single repo with no route, the line that it becomes the default repo.
- What happens next: Symphony restarts now, after the active agent runs, when it starts, or by hand.

#### WORKFLOW.md

Symphony runs no agent on a repo without a `WORKFLOW.md`, so the sheet checks for one: a local folder at
the checkout's top, a GitHub URL on the base branch through the GitHub CLI (`gh`, logged in with
`gh auth login`). A repo that has one skips the step. For a repo that has none, the **WORKFLOW.md** page
says so and offers a draft in the shape
Symphony's own repos use: the setup hook, QA playbooks and `playbook` settings in the front matter, then
the repo's commands and steps above the `{% render "playbook" %}` line, which expands to Symphony's
standard playbook ([playbook partials](../docs/playbook.md)). The draft is filled in from the files at the
repo's top:

| Files | Stack | Setup hook | Tests |
| --- | --- | --- | --- |
| `mix.exs` | Elixir, Mix | `mix deps.get` (through `mise` with a `mise.toml` or `.tool-versions`) | `mix test` |
| `build.gradle(.kts)` or `settings.gradle(.kts)` | Kotlin or Java, Gradle | none | `./gradlew test`; an Android app (`com.android.application` in `app/build.gradle(.kts)`) gets `testDebugUnitTest` and the `android_app` QA playbook with its `applicationId` |
| `package.json` | TypeScript or JavaScript; npm, pnpm, yarn or bun from the lock file | the manager's install | the `test` script; `lint` and `typecheck` scripts as pre-push checks, and a commented `verification` block for a `dev` script |
| `Cargo.toml`, `go.mod`, `Package.swift` | Rust, Go, Swift | `cargo fetch`, `go mod download`, `swift package resolve` | `cargo test`, `go test ./...`, `swift test` |

A `test:` target in the `Makefile` makes the tests `make test`. The line **Found** sums up what was found.
Edit the draft in the sheet, then pick how it lands under **Add it by**:

- **Open a pull request** (the default): Connect makes a `symphony/add-workflow` branch (`-2`, `-3`… when
  taken) from the base branch through GitHub's API, commits the file there and opens a pull request
  against the base branch with `gh pr create`, so the file goes through review like any change. No
  checkout of yours is touched. Agents start on the repo once it merges. When the commit or the pull
  request fails, Connect deletes the branch again, so trying again doesn't leave branches behind.
- **Write it into the checkout** (local folder only): Connect writes `WORKFLOW.md` at the checkout's top and
  leaves it uncommitted. Commit and push it: Symphony reads the file from the base branch.
- **Don't create one now**: Connect adds the repo as before.

Connect adds the file first, then writes `symphony.yml`, and the banner on the new repo names the pull
request or the file. When `gh` is missing or can't read the repo, the Source page says why and the sheet
connects the repo without the step. Symphony never writes `WORKFLOW.md` without this pick, and
agents still can't change the file afterwards: it stays a write-protected path in their workspaces.
`SYMPHONY_BAR_GH` names the `gh` to run instead of the one on `PATH` or in the Homebrew folders, as QA
passes do with a fake.

A write that fails stays on the Review page in a warning box, and a `WORKFLOW.md` already added isn't added
again when Connect is pressed once more. Connect changes only `repositories:`: comments and the other entries
stay as they are. When the file has a single repo with no route, Connect also marks it `default: true`, so it
keeps the issues no route matches (Symphony refuses a second repo next to a repo with no route that isn't the
default).

#### Setting up a WORKFLOW.md for a connected repo

A repo connected without a `WORKFLOW.md` (Add Repo's **Don't create one now**, or a file deleted since) shows
`WORKFLOW.md is missing` in **Needs attention** once Symphony reports it, with **Set Up WORKFLOW.md…**. It
opens a sheet, **Set Up WORKFLOW.md for billing-api**, with the same WORKFLOW.md page as Add Repo's step:
what was found and the editable draft, read from the checkout's working tree for a local folder, or from the
base branch on GitHub through `gh` for a managed clone, then **Add it by**: **Open a pull request** (the
default) or, for a local folder, **Write it into the checkout**. Not creating one is **Cancel**.

**Create** adds the file as Add Repo's Connect does: the same `symphony/add-workflow` branch and pull request,
deleted again when the pull request fails, or the file uncommitted at the checkout's top. The sheet then
closes, a banner names the pull request or the file, and the repo shows **Pending: pull request open** or
**Pending: written, not pushed** until Symphony reports the file valid. `symphony.yml` isn't written, so
nothing restarts. A failure (no `gh`, a repo `gh` can't read, a pull request that couldn't be opened, a
`WORKFLOW.md` already in the checkout) stays in the sheet in a warning box, and **Create** tries again.
The button needs the repo's `owner/repo`, so a local folder without a GitHub `origin` has none.

Symphony reads a new route from `symphony.yml` while it runs, but sets up a repo's workflow and its own
clone only when it starts. So after Connect:

- a Symphony the app started restarts as with **Restart Symphony** when no agent runs; while agents
  run, the app asks first, and **Restart When Runs Finish** pauses dispatch and waits for them;
- a stopped Symphony picks the repo up when it starts;
- a Symphony the app didn't start needs a restart from where it was started.

The new repo is selected, and a banner at the top of its detail says which applies; Edit, Disconnect
(on the repo selected next) and Remove Clone show theirs the same way, and so does a write that failed.
A banner stays until you close it or make the next change. While a restart waits for agent runs, the
toolbar chip reads **Restart pending: waiting on N runs**; click it for the runs, **Cancel Restart**,
and **Restart Now** once the runs outlast the restart timeout. A running Symphony lists the new repo at the
next poll, as it reads the route right away; a GitHub URL repo shows `not cloned yet` and its
`WORKFLOW.md` as `missing` until the restart clones it. With Symphony stopped, the sidebar shows the repo
from `symphony.yml`.

### Edit, disconnect or remove a clone

Each of the detail's Source, Linear routing and Review sections has its own **Edit…**, also in the sidebar
row's context menu (**Edit Source…**, **Edit Linear Routing…**, **Edit Review…**); Disconnect… sits at the
detail's foot and in the context menu. They are disabled, with the reason on hover (and next to Disconnect…),
while `symphony.yml` can't be read or no longer has the repo.

Each Edit… opens a small sheet titled for its section and the repo, such as "Review of billing-api"; the key
can't change. Every sheet is at most 520pt tall with **Cancel** and **Save** in a fixed footer, so they stay
on a 1024×768 screen. Save rewrites only that repo's entry (and, for Make Default, the old default's
`default` line): comments, the other entries, the route's team and assignee, and `fetch_before_dispatch`
stay. A new route, default or review setting applies without a restart; a new source, workflow or base branch
restarts Symphony as Add Repo does, asking first while agents run. The banner at the top of the detail says
which.

- **Source** (480×380): **GitHub URL** or **Local folder**, in either direction, with the same check as Add
  Repo's Source step once you pick another repo or folder, and the base branch (empty uses `origin`'s default
  branch). A caption says what switching does on disk: Symphony makes its own clone on the next start and
  your folder stays as it is, or agents work in worktrees of the new folder and Symphony's old clone stays on
  disk until you remove it. A local repo keeps its folder until you choose another. Switching to a GitHub URL
  drops `repo`, `strategy` and `workflow` (Symphony reads `WORKFLOW.md` from its clone); switching to a folder
  sets them as Add Repo does, and refuses a checkout without a `WORKFLOW.md` at its top (only Add Repo drafts
  one).
- **Linear routing** (480×420): the project, the labels (the token field of Add Repo, completing from the
  project's labels), the route preview, and **Default repo** ("Take the issues no other repo's route
  matches."). A project or label Linear doesn't list stays selectable; **No project** is allowed while
  labels, a team or an assignee still route issues, or for the default repo. A route another repo already has
  shows under the labels and keeps Save off. Turning **Default repo** on names the current default that loses
  it, and Save moves `default: true` from that repo to this one in the same write. On the default repo the
  checkbox stays on (turn it on in another repo to move it). While the current default has no route of its
  own the checkbox stays off and says so: Symphony refuses a repo with no route that isn't the default.
- **Review** (440×360): **Ask me before merging (a merge-confirmation hold after QA)**, the repo's
  `manual_review`, with what it does under it, and the repo's **Built-in ticket patterns** (Same as Settings,
  On, Off). Save runs `symphony check` on the result first, with a spinner in the footer; when it rejects the
  change, the reason shows in the sheet and nothing is written. **Change Review…** in the Symphony window's
  Quality view opens this sheet.
- **Disconnect…** (the detail's foot, the sidebar **−**, the context menu or Delete) opens a sheet,
  "Disconnect <key>?", saying what happens and what stays on disk, with **Cancel** and **Disconnect**.
  Disconnect removes the entry from `repositories:` together with the comment lines right above it
  (with no blank line between), and leaves one blank line between its neighbours. It never deletes a
  local folder: a local checkout and its branches stay as they are. It is disabled for the only repo,
  with "Symphony needs at least one repo." on hover and next to it, and the sheet doesn't open. For
  the `default: true` repo, the sheet's **New default** pop-up picks the repo that becomes the default.
  For a managed repo whose clone exists, **Also delete Symphony's clone (<path>)** deletes the clone
  in the same step. It can be checked only when Remove Clone… could run (below), and otherwise shows
  why under it, following each poll. After removing the entry the app checks again as Remove Clone
  does, so a clone that became busy is kept and the banner says why. Symphony then restarts as after
  Add Repo.
- **Remove Clone…** (managed repos only), for a repo that stays connected, deletes Symphony's clone under `workspaces.clones_root`
  after you confirm; the repo stays connected and Symphony clones it again when it starts or on its
  next dispatch. It is disabled, with the reason next to it, while an agent runs in a worktree of
  the clone (any repo with the same source), and while Symphony is starting or doesn't list its running
  agents. Before the first clone the detail says "Not cloned yet" and shows no Remove Clone…. The app asks Symphony again after you confirm, and deletes the
  folder only when, with symlinks resolved, it is inside the clones folder: `clones_root` with `~`
  expanded and a relative path taken from the folder of `symphony.yml`, or
  `~/.local/share/symphony/repos`.

## Restart

Restart Symphony restarts a Symphony the app started without ending agent runs. It is disabled for a
Symphony the app didn't start ("running (external)"), and Start, Stop, Pause and Resume are disabled while it
runs. The line under the status shows each step:

1. **Check symphony.yml:** runs `symphony check --config <symphony.yml>` with the same binary and
   environment Start uses (in Development mode, through the same login shell and command prefix). If the
   check fails, an alert and a menu line show its error, and Symphony keeps running untouched.
2. **Pause dispatch,** unless it is already paused. The restart remembers whether it paused it.
3. **Wait for agent runs:** the menu shows "Waiting for N agent runs…" until a poll shows dispatch paused and
   `0 running`. If a poll shows dispatch running again (it was resumed just before the restart, or while it
   waits, from the dashboard for example), the restart pauses it again and then resumes it afterwards.
   After the restart timeout (Settings, 30 minutes by default) **Restart Now Anyway** also shows;
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
with Symphony running again. The steps are under [Install an update](#install-an-update). The relaunched
app then [checks that Symphony is healthy](#health-check-and-automatic-rollback) on the new version and puts
the previous version back by itself when it isn't. The app can also
[install updates by itself](#automatic-updates) when idle or at a set time. You can also
update by running the [install script](#with-the-install-script) again after quitting the app.

The app checks the latest release at
`https://api.github.com/repos/tonypine/symphony/releases/latest` at launch, in the background (see
[How often the app checks](#how-often-the-app-checks)), and when you choose Check for Updates. The request
carries no token. It sends the last response's `ETag` in `If-None-Match`, so an unchanged release answers 304
Not Modified without the release body. Every request still counts against GitHub's rate limit of 60
unauthenticated requests an hour from the Mac's address, a 304 included, and every other tool on the Mac that
calls GitHub's API without a token shares that limit.

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

### How often the app checks

- **Automatically when released** checks every **Check for releases every N minutes** in Settings: 5 by
  default, 2 to 60. Every 2 minutes is 30 checks an hour, half of GitHub's limit, which leaves the rest to Check
  Now and other tools. A stored value outside that range is moved into it when the app loads it, and a typed one
  when the field commits, with the note "Between 2 and 60 minutes. 1 was changed to 2." in place of the
  last-check line, once. The other modes check every 6 hours.
- Saving Settings takes effect without a relaunch. Switching to Automatically when released, or changing its
  minutes, checks straight away and then on the new interval; switching to another mode goes back to every
  6 hours. Choosing Automatically when released in the picker also checks straight away, before Save, so the
  line shows what it finds.
- Symphony tells the app when a release is out: `/api/v1/state` reports the newest release under
  `app_update.latest_release`, which Symphony learns from GitHub's `release` delivery or its own authenticated
  poll. When a status poll reports one newer than the running build and than the release the last check found, the
  app checks at once, in every mode, and the mode then installs as usual: Automatically when released installs it
  right away. Each reported release starts one check at most, none while a check runs or GitHub's rate limit holds,
  so the timer above is only the safety net for when Symphony doesn't report.
- A failed check shows no alert. After a check that hit GitHub's rate limit (HTTP 403 or 429), the next one waits
  until GitHub lifts the limit: `Retry-After` seconds, or else the `X-RateLimit-Reset` time, at most an hour, and
  never sooner than the usual interval. Any other failure, such as a check that couldn't reach GitHub, retries at
  the usual interval. Check Now and Check for Updates count too.
- In Automatically when released, Settings shows the last check under the interval, with **Check Now**,
  which runs the same check as Check for Updates…: "● Checked 2 min ago: v0.0.1.42 is the newest release.",
  "Checking for a new release…" with a spinner while it checks, "▲ Couldn't check at 14:05: <reason>. Next
  check at 14:47." after a failure, and "Not checked yet." before the first check. After a check that found
  nothing new, the menu says "Up to date: v0.0.1.42, checked 2 min ago" under Check for Updates….
- In [QA mode](#qa-mode), `SYMPHONY_BAR_UPDATE_CHECK_INTERVAL` sets the seconds between checks in every mode
  instead.

### Skip a release

To stay on your version, choose **Skip This Version** while the menu offers a release. The app records that
release's build as skipped in UserDefaults (`skippedReleases`), so it stays skipped across relaunches:

- The menu no longer shows it as available: the line reads **Update skipped: vX (N changes)**, and Skip This
  Version hides. **Update to vX** and **Release Notes…** stay, so you can still install it by hand.
- Installing it by hand with Update to vX clears the skip.
- A skip covers that one build. A newer release is offered as usual, with its own Skip This Version.

A release an update [rolled back](#health-check-and-automatic-rollback) is recorded the same way, with the
reason "rolled back": the line reads **Update rolled back: vX**, and **Retry vX** replaces Update to vX.

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
   version's Symphony yet. The pause's reason is `updating to vX`, not the menu's, in every update mode, so
   the Symphony window tells it from a pause you made: the toolbar's dispatch control reads "Paused ·
   Updating to vX", and its popover says how many agent runs the update waits for and offers **Cancel
   Update** in place of Resume Dispatch, with **Update Now Anyway** after the restart timeout (both do what
   the menu's items do). While the release downloads or Symphony stops, it says "Updating to vX" with
   nothing to press. The Overview says "Dispatch is paused since HH:MM: updating to vX." and that Symphony
   updates and resumes dispatch when the runs end.
5. **Swap and relaunch:** the app starts a small helper (`Contents/Resources/update-helper.sh`, run from a
   copy in the cache folder) and quits. Once the app has exited, the helper moves it to
   `Symphony (previous).app` next to it (replacing an older one), moves the new app into place, and opens
   it. If a move fails, it puts the old app back and opens that instead. Its log is
   `~/Library/Caches/com.tonypine.symphony.bar/update-helper.log`.
6. **Bring Symphony back:** the relaunched app runs the [health check](#health-check-and-automatic-rollback):
   it checks `symphony.yml` with its new embedded binary, starts Symphony from it, and, once it answers, resumes dispatch if the update paused it. A pause you
   made before the update stays. If the helper had to put the old app back, an alert says so.

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

### Health check and automatic rollback

After every update, by hand or automatic, the relaunched app checks that Symphony works on the new version.
The line under the update items shows "Checking vX: …" while it does:

1. **Config check:** `symphony check --config <symphony.yml>` with the new embedded binary must pass, so a
   config error such as `workspaces.repo does not exist` is caught. Symphony starts only once it passes.
2. **Answer:** when the app starts Symphony after the update (it ran before the update, or "Start Symphony
   when the app opens" is on), Symphony must answer on its control URL within 2 minutes of starting. If it
   doesn't, the app stops it and starts it once more, and a second miss fails the check. A Symphony that
   still answers when the app goes to start it is the one the update stopped, still on its way out: the app
   waits up to a minute for it to exit before it starts the new one. When it doesn't start Symphony, only
   the config check runs. Each exit of Symphony is noted at the end of `menubar-child.log`, with its status,
   so a crash before Symphony's own logger starts is on record.
3. **No crash loop:** for 10 minutes after the update, an unexpected exit of Symphony starts it again (each
   start must answer within 2 minutes), and the third unexpected exit in those 10 minutes fails the check.
   A Stop you choose doesn't count. Outside those 10 minutes the app doesn't start Symphony again after an
   unexpected exit, as before.

If any of these fails, the app rolls back by itself:

1. It **pins** the new version: the build is recorded in the [skip list](#skip-a-release) as rolled back,
   before anything moves.
2. It stops Symphony if it runs, starts the update helper in reverse and quits. The helper moves the new
   version aside as `Symphony (rolled back).app`, out of the previous version's place, moves
   `Symphony (previous).app` back to `Symphony.app`, and opens it. Its log is
   `~/Library/Caches/com.tonypine.symphony.bar/rollback-helper.log`.
3. The restored app starts Symphony if it ran before the update and resumes dispatch if the update paused
   it. A notification says "Symphony rolled back to vY", naming the version that failed and the check it
   failed. The line under the update items says the same, for example "v0.0.1.43 was rolled back: symphony
   check failed: …", naming Symphony's log when Symphony didn't answer or kept exiting. Choosing the line
   opens the failed version's release notes, with **Open Rollback Steps**, which opens [Rollback](#rollback).
   The restored app doesn't check itself, so a rollback can't loop.

The pinned version shows as **Update rolled back: vX** and is never installed by itself; a newer release
is, as usual. **Retry vX** takes the place of Update to vX: after the same confirmation it clears the pin
and installs vX again, health check included. Installing it by hand any other way clears the pin too.

When there is no `Symphony (previous).app`, or the helper can't start or can't swap the apps, the app
doesn't roll back. A notification and the line under the update items say so, with how to do it by hand (see
[Rollback](#rollback)), and leaves Symphony as it is. A failed swap relaunches the new version, which says
so and doesn't start Symphony unless "Start Symphony when the app opens" is on. The version stays pinned.

Automatic rollback only fully protects an update from a version that already has it: the version put back
must read the pin and what the failed version recorded. A version from before it is still put back, but it
doesn't say why, doesn't bring Symphony and dispatch back as they were, and may offer the rolled-back release
as a normal update again. The next update still checks itself, to the rolled-back release or any other: the
record the failed version left is dropped once an update is pending or a newer version runs. Installing the
failed version again by hand drops it too, since the helper only renames apps and a reinstall puts a new one in
place: the app then opens as usual instead of saying the rollback failed.

`Symphony (previous).app` is never deleted by an update or a health check, whether it passes or not.

### What changed

Once an update passes the blocking part of its [health check](#health-check-and-automatic-rollback) (the config
check, and Symphony answering when the app starts it), the menu shows **Updated to vX (N changes)** above
Check for Updates…, with N from the release notes when known, whether you installed it or the app did.
Choosing it opens that release's notes, in the same window as Release Notes…, with **Open Release Page**.
The app keeps the release's version, notes and page in UserDefaults (`lastUpdate`) across the relaunch, as
the new version is now the latest and no check offers it. The line stays until the next update (or a
rollback) or for 7 days.

After an automatic update the app also posts a notification, "Symphony updated to vX", with the number of
changes when known. An update you just confirmed with Update to vX gets none. A rollback always gets one, see
[Health check and automatic rollback](#health-check-and-automatic-rollback). Notifications need Symphony to be
allowed in System Settings > Notifications; when they aren't, the app shows an alert instead.

### Automatic updates

**Update mode** in Settings chooses how a newer release is installed:

- **Manual**: the menu shows the release and you install it with Update to vX. Nothing installs by itself.
- **Automatically when idle**, **Automatically at a set time** and **Automatically when released**, below.

**Automatically when released** is the default for every install that has no update mode stored: a new one,
and one that ran before but never saved Settings. Saving Settings stores the mode, and a stored mode,
Manual included, is never changed.

With one of the automatic modes, the app installs a newer release by itself through the same steps as
[Install an update](#install-an-update), without the confirmation:

- **Automatically when idle**: when a check finds a release, the app installs it as soon as Symphony has
  no active agent runs. Idle means `0 running` in Symphony's state, whether dispatch is paused or not, so
  paused dispatch with runs still active is not idle; with Symphony stopped the app counts as idle. The app
  never pauses dispatch to get there: while runs are active the menu shows the release as available, and
  the app looks again on each status poll (every 5 seconds) and installs at the first idle moment. If a run
  starts just as the update pauses dispatch, the update gives up, resumes dispatch, and waits for the next
  idle moment.
- **Automatically at a set time**: each day at the set time the app checks for a release. If there is one,
  it pauses dispatch, waits for the active agent runs to finish without interrupting them (there is no
  Update Now Anyway), installs, and the relaunched app resumes dispatch. If the runs are still active after
  the **Restart timeout** (30 minutes by default), it resumes dispatch, installs nothing, and the menu says
  "Update postponed"; the next attempt is the next day's time. A time missed while the Mac slept or the app
  was closed (more than 10 minutes late) waits for the next day's time too, so dispatch isn't paused in the
  middle of the day. A release found by another check waits for the set time.
- **Automatically when released**: as soon as a check finds a release (at launch, every 5 minutes by default,
  or Check for Updates…), or a status poll sees one already found, the app installs it, whatever agent runs
  are active. It downloads and verifies it ("Updating: downloading and verifying vX…"), pauses dispatch, waits
  for the active runs to finish ("Updating to vX: waiting for N agent runs…") and installs, as Update to vX
  does but without asking. It never gives up on the runs: after the **Restart timeout** the line adds how long
  it has waited ("(35 min)") and **Update Now Anyway** stops Symphony without waiting more. Release Notes…
  shows the release under way.
  - Once it has paused dispatch, it posts a notification, "Updating Symphony to vX", saying how many agent
    runs it waits for, with **Cancel Update**. It makes no sound, and nothing shows in its place when
    notifications aren't allowed. Clicking it opens the Symphony window. It is removed once the update
    ends, fails or is cancelled, and the other modes post none.
  - **Cancel Update**, in the menu while the release downloads or the update waits for runs, or on the
    notification, stops the update and resumes the dispatch it paused. It holds that release: no check
    installs it again, and the menu shows it as available with "You cancelled this update. It waits for
    you; a newer release installs by itself.", **Update to vX** and **Skip This Version**. Installing it by
    hand, skipping it or a newer release ends the hold; the app forgets it when it relaunches. Once
    Symphony is stopping for the swap, Cancel Update does nothing.
  - A failure before the swap, such as a failed download or verification, shows "Symphony wasn't updated:
    <reason>. Trying again at the next check." under the update items, with no alert; the next check tries
    again, not every status poll.

In all automatic modes:

- A release you [skip](#skip-a-release), or one an update [rolled back](#health-check-and-automatic-rollback),
  is never installed by itself. A newer release is.
- Nothing installs while Update is disabled (a development build, Development mode, no update signing key,
  or an app folder you can't write to).
- A pause you made before the update stays after it, as with Update to vX. Cancel Update stops waiting.
- A failure shows on the line under the update items, with no alert: a failed download or verification,
  for example. When idle or when released, the app tries again after the next check (every 6 hours when
  idle, every N minutes when released, or Check for Updates); at a set time, the next day.
- The relaunched app runs the [health check](#health-check-and-automatic-rollback), as after Update to vX:
  `symphony check` must pass, Symphony must answer within 120 seconds of starting, and it must not exit
  unexpectedly 3 times within 10 minutes of the update. If any of these fails, the app rolls back to
  `Symphony (previous).app` by itself and pins the failed version, so no automatic mode installs it again; a
  notification and the menu say which version was rolled back and why. **Retry vX** installs the pinned
  version again by hand, health check included. A newer release is installed as usual.
- Once the update is healthy, a notification says "Symphony updated to vX" and the menu shows
  [Updated to vX](#what-changed).

## Rollback

Each update, and each install over an older version, keeps the version it replaced next to the app as
`Symphony (previous).app`, for example `~/Applications/Symphony (previous).app`. Only one previous version is
kept. When an update fails its [health check](#health-check-and-automatic-rollback) the app goes back to it by
itself, moving the failed version aside as `Symphony (rolled back).app`. To go back to it by hand:

1. **With an [automatic update mode](#automatic-updates) on, set Update mode to Manual in Settings… first.**
   Otherwise the version you go back to finds the newer release with its check at launch and, when idle or
   when released, installs it again right away. The running version can't skip itself: its menu offers no
   release. The mode is kept in UserDefaults, so the version you go back to reads it.
2. Choose **Quit** from the menu (this stops Symphony).
3. Swap the two apps, in Finder or a terminal:

   ```bash
   cd ~/Applications
   mv Symphony.app "Symphony (rolled back).app"
   mv "Symphony (previous).app" Symphony.app
   ```

4. Open `Symphony.app` and start Symphony. Your settings and stored variables carry over. A version from
   before the secrets file reads the variables from the login Keychain instead, as they were when they were
   copied into the file, so a variable changed in Settings since then has its old value there. Delete
   `Symphony (rolled back).app` once you no longer need it.
5. The menu offers the release you left as **Update available: vX**. Choose **Skip This Version** (see
   [Skip a release](#skip-a-release)): a skipped release is never installed by itself, so you can set Update
   mode back to an automatic mode. A newer release is installed as usual. Or stay on Manual.

After an automatic rollback the failed version is already pinned, with **Retry vX** to install it again, so
there is nothing to skip. To install an older release than the previous
one, quit the app and run the install script with `SYMPHONY_RELEASE_TAG` set to that release's tag (see
[With the install script](#with-the-install-script)).

## The Symphony window

**Open Symphony** (⌘O) opens one window, **Symphony**, next to the menu bar item. It has a sidebar of views
and, in the toolbar, **Back** and **Forward** (⌘[ and ⌘], between the views and the ticket pages shown), the
view's title, Symphony's connection state (quiet while Symphony answers; the time of the last update is in its
help), the scope pop-up and **Refresh** (⌘R). The sidebar lists the views this
version has, in the order they will keep as more arrive, on ⌘1 to ⌘8: **Inbox**, **Overview**, **Initiatives**, then under
**Factory**, **Repos** (which opens the Repos window), **Setup** and **Diagnostics**. Its foot shows Symphony's version and
state. The window opens on the Inbox the first time.

- **Inbox** lists everything that waits on you (`/api/v1/inbox`), grouped as Plans, Pull requests, Final
  verifications, Actions, Clarify and Blocked, oldest first in each group, each row with its ticket, title, one-line ask
  and age; its sidebar item counts them in orange, in every repo. ↑ and ↓ move through the list and Return
  takes the review's first action. Beside the list, the review of the selected item: a plan's **What to
  review** with its links, **Decisions needed** with the recommended option picked, and its sub-tickets in
  landing order; a PR's checks (CI, and QA with its report), with **Open PR**; an action's why and numbered steps, with **Copy Steps**; what the quality gate found in a ticket it holds, its
  score and round, with **Edit in Linear**; and a blocked ticket's reason for the hold and what clears it. Last,
  **Where this ticket sits**: its parent with a strip of its sub-tickets and how many are done, its pull request's
  checks and how often Code Review sent it back, the tickets connected to it with their stage, what your answer
  unblocks and the decisions already made on it; each row only when known, and no card without one. No review shows
  a time estimate. A review brief Symphony can't read into its parts shows as text. **Open in Linear** opens
  the ticket in Linear: in the Linear desktop app when it is installed (its `linear://` link, without starting the
  browser), else in the browser. Every Linear link in the app opens the same way. The review's title, or a double-click on a row, opens its ticket page. With nothing left it says "Nothing waits on you." with **Open Overview**, and a scope that hides
  items says how many ("2 more in other repos").

  You answer from the review's actions, the default one prominent: a plan has **Approve Plan…**, **Send
  Decisions** (on once a pick differs from the recommended option) and, under ⋯, **Send to Rework…**; a PR
  waiting on its merge confirmation **Approve and Merge…** and **Send to Rework…** (with a red check, **Open PR** is the
  default), which answer that request like **Send Decision…**: Approve and Merge picks the option that moves the ticket
  to `Merging`, and a PR with no request to answer offers only its links; an action asking a decision **Send Decision…** (its options are the picks) and,
  under ⋯, **Send to Rework…** as the redirect; a blocked ticket **Unblock…**, which clears the access or
  dispatch-loop hold and lets it continue in place, and **Restart…** under ⋯. Each opens a sheet first: the question, what happens in Linear ("Moves SHOP-330 to
  Waiting on sub-tickets and promotes its 7 sub-tickets to Todo; SHOP-331 starts first."), what stays the same,
  the picks it posts or the reason Send to Rework needs (its button stays off without one), and **Cancel** and the
  verb. Nothing changes in Linear until you press it; a spinner shows while Symphony makes the move
  (`POST /api/v1/control/approve_plan`, `rework`, `decisions`, `decide`, `unblock`), and what went wrong
  shows in the sheet. After a move the selection moves to the next item (the moved one leaves the list once
  Symphony's next poll sees the move), and a banner at the foot says "Moved to Merging" with **Undo** for 10
  seconds, which moves the ticket back (`POST /api/v1/control/undo`). The banner and the selection follow
  Symphony's answer (`moved`, `to_state`). Send Decisions posts its comment in place and leaves the plan in
  `Plan Review`, so its banner just says "Sent your decisions" with no Undo. Unblock moves no ticket, so its banner
  just says "Hold cleared" with no Undo.

- **Initiatives** follows each plan you approved to done (`/api/v1/initiatives`), in three columns like the
  Inbox. The list groups the plan tickets as Active, In review and Done recently (a week after they are done),
  each with "4 of 8 done" and a bar of its sub-tickets by stage (Done, Working, Waiting on you, Queued,
  Blocked) with a legend that gives each stage's symbol, count and word; VoiceOver reads the counts too. The
  detail opens with a sentence ("4 of 8 done. BIL-206 waits on you, and 2 tickets wait on it."), the bar and its
  legend, the initiative's lane ("Holds a lane, running BIL-205"), and the sub-tickets in landing order, each
  with what it waits on (you, a blocker, CI, a slot) and links to the tickets it is blocked by. **Review** on a
  sub-ticket that waits on you opens its Inbox item; any other row opens its ticket page. The final
  verification comes last and reads "Waits on 3 tickets" until the others are done, then its result. The
  Overview's side column shows the active initiatives in an **Initiatives** card; a click opens one here. The
  scope pop-up applies.

- **Overview** answers "is the factory moving, is anything stuck" at a glance. One sentence says how things
  are: "The factory is flowing.", "2 things need attention.", "Dispatch is paused since 14:03: Deploy
  freeze." with **Resume Dispatch**, or "The factory is idle.", with a line of context under it. The flow
  strip counts the tickets at each stage: Queued, Working, Code Review & QA, Waiting on you (the Inbox; the tile
  opens it), Merging
  and Shipped today (the tickets Symphony saw reach Done today, UTC); a stage at 0 stays in place in grey.
  **Needs attention** shows only when something does, most severe and oldest first, one row per ticket or
  hold: a run with no agent activity for 10 minutes, 3 failed attempts or more, a ticket routed to more than
  one repo (**Open in Linear**), a usage-limit hold with the time runs resume, a forced ticket gone stale
  (**Stop Forcing**) and stray processes (**Open Diagnostics**); **Open** opens the ticket page, and a stuck or
  failing row also has **Stop Run…**. The sidebar's Overview item counts these rows. **Now working** lists the agent runs, QA passes and landings
  with their phase, turn, last activity, running time and tokens, and **Next up** the tickets waiting for a
  slot or a retry. On the side, **Today** has the day's tokens against the daily budget and each provider
  limit Symphony reports, accent below 75%, orange from 75% and red from 95%, and **Repos** says in one line
  whether each repo is healthy. Return or a double-click on a ticket row opens its ticket page.
- A **ticket page** tells one ticket's story: its badges, repo and initiative, what it is doing ("Waiting on a
  retry at 14:32", "In review · QA pass running"), **Now** (the run and its model and effort, running time,
  turn, last activity, the tool call it waits on, its workspace with **Reveal**, and its tokens against the
  per-ticket cap), the **Timeline** of every run with its result, duration and tokens, and
  your moves ("Stopped by you, moved to Backlog", from the audit records), and the ticket's facts (state,
  type, initiative, pull request, forced, and for a done ticket when it merged) and the agent's
  last message. It reads `/api/v1/:issue_identifier`, `/api/v1/runs` and `/api/v1/audit` besides the state;
  a done ticket, which Symphony no longer tracks, shows what the state and the run records still say. Its
  actions: **View Transcript**, **Open in Linear**, **Stop Run…**, and under ⋯ **Copy API URL**, **Show Audit
  Records** (Audit, filtered to the ticket) and **Reveal Worktree**.
- **View Transcript** opens the run's transcript in its own window (⌘-click opens another): the agent's
  messages, each tool call with its result and duration, and errors, grouped by turn, with **All**,
  **Messages**, **Tools** and **Errors**, a search field (⌘F) and **Copy Session ID**. The selected event shows
  in full below, monospaced and selectable, and a call that hasn't returned says how long it has been silent.
- **Stop Run…** opens a sheet first. It says what a stop does: it ends the agent and removes its workspace,
  with any work not pushed, and the ticket keeps its Linear state, so Symphony starts it again on its next
  poll. **Also move to Backlog** (on from Needs attention, off from the ticket page) then moves the ticket to
  Backlog with your note as a comment (`POST /api/v1/control/stop`, then `backlog`). A failing ticket between
  attempts has no run to stop, so only the Backlog move is left.
- The **scope** pop-up shows all repos or one of the repos Symphony has tickets in. It filters every count
  and row of the Overview (the sidebar badge still counts every repo), and the app remembers it across
  relaunches.

- **Audit** (⌘8, under Records) lists the local audit records newest first (`/api/v1/audit`, the newest 1,000
  under the filters): time, kind, ticket, repo, who acted (you, the agent or Symphony) and what happened. Your
  moves from the app (approve, merge, rework, decisions, Backlog, Stop Run) are recorded like any
  other; older records may still show a sign-off, a move retired with `Final verification:` tickets.
  The kind and date pop-ups (the last 7 days, or one of them), the search (⌘F) and the scope pop-up filter
  it; a ticket page's **Show Audit Records** filters it to that ticket. Above the table each shown day says
  whether its hash chain verified (`/api/v1/audit/verify`): "Chain verified" with a seal, or the line and record
  that broke it with a crossed seal, which is also marked in its row. The inspector (⌥⌘I, Space) shows the
  selected record in full. **Export…** saves every record under the filters and the search as NDJSON, one per
  line as Symphony wrote it, from the API's export. With nothing to show it says "No audit records match." with
  **Clear Filters**.
- **Setup** lists what is wrong with Symphony's setup, from `/api/v1/state`'s `setup`: a sentence ("Setup has 1
  error and 1 warning.", or "Symphony is set up right." with what was checked and when), then an Errors and a
  Warnings card, rows grouped by category (routing, teams, labels, statuses, keys, secrets, runtime). Each row says
  what breaks, the repos and tickets it touches (a ticket opens its page), **Details**, and its fix: **Remove…**,
  **Change…** or **Add…** for an edit of `symphony.yml`, **Create Label…** (or **Create Status…**) and **Re-sync…**
  for a Linear change, or the place to fix it by hand (**Open Settings…**, **Open symphony.yml**, **Open in
  Linear**, **Open Drain Report**, **Open Repos**). Nothing is fixed without its sheet: an edit shows the exact
  lines it removes and adds, copies `symphony.yml` to `symphony.yml.<yyyyMMdd-HHmmss>.bak` next to it (the last 10
  are kept), saves through the same writer as Settings once `symphony check` passes, and offers **Undo** for 10
  seconds; a Linear change names what it creates, in which team, and how to undo it by hand. A fix that fails keeps
  its sheet open with the reason, **Try Again** and **Close**. **Check Again** (⌘R) runs the checks now. Checks
  that couldn't run (no Linear API key) show under **Not checked**; when Linear can't be reached, a banner says
  when the Linear results are from. A warning also shows when Symphony runs another build than the app, with
  **Check for Updates…**. Its sidebar item counts the errors in red, or the warnings in orange when there are no
  errors; Overview's Needs attention has one row for the errors, with **Open Setup**; and the menu bar has a
  "Setup: 1 error, 1 warning" row and a red dot on its icon while there are errors. A Symphony older than Setup
  shows **Check for Updates…** and no badge.
- **Diagnostics** shows Symphony's own health in plain words: the connection (version, API URL, uptime, last
  update), capacity (agent slots, landing slots, forced allowance, initiative slots), Linear requests by
  caller over the last hour, the CI and review pollers and GitHub webhooks, and stray processes. **Copy State
  JSON** copies `/api/v1/state` as Symphony served it, and **Open Logs** does what
  the menu item does.
- While Symphony doesn't answer, every view shows one placeholder instead: **Start Symphony** while it is
  stopped, a spinner while it starts, **Open Logs** and **Restart Symphony** when it stopped answering, and
  **Open Settings…** while no `symphony.yml` is set. A view whose endpoint an older Symphony doesn't serve
  says "Update Symphony to see this view."

**Notifications.** The app notifies each new Inbox item ("BIL-206 waits on you") and each new Needs attention
problem once, with **Open**, which opens the window on it; a PR whose checks are green also has **Approve and
Merge…**, which opens the window on its sheet and approves nothing by itself; never twice for the same one, even after a relaunch,
and nothing for routine progress or what was already there the first time the app ran. They make no sound. The
app asks for permission the first time one is due, and Settings has a switch per kind under **Notifications**.

While the window is open the app is a regular app, with a Dock icon, a ⌘-Tab entry and its main menu; the Dock
icon shows how many things wait on you. ⌘W
closes the window and the app goes back to the menu bar only; Symphony keeps running. The window opens at
1200 × 760 (it can't shrink below 960 × 600) and comes back at the size, position and view it was left at,
also after a relaunch. It reads Symphony's local API every 2 seconds while it is on screen and every 30
seconds otherwise.

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
make snapshots  # renders the views in Tests/Snapshots offscreen (no window) and rewrites their PNGs
make clean    # removes build/ and .build/
make bundle SYMPHONY_RELEASE=../_build/prod/rel/symphony   # embeds the Symphony release (make release), as releases do
```

`make` and `make bundle` sign ad hoc. Pass `SIGNING_IDENTITY="<certificate name>"` to sign with a
certificate, `SHORT_VERSION=` / `BUILD_NUMBER=` to set the versions in `Info.plist`, and
`MINISIGN_PUBLIC_KEY=` to embed the update key. `make install` replaces `~/Applications/Symphony.app`, so it
replaces an installed release too; reinstall the release with the install script afterwards.

Every build also carries `Contents/Helpers/SymphonyQADriver.app`, the helper that takes screenshots and reads
the accessibility tree for the QA state's `macos_app` playbook. Grant Screen Recording and Accessibility to that helper,
never to Symphony.app: macOS passes Symphony.app's grants to the agents it starts (see
[One-time macOS permissions](../docs/configuration.md#one-time-macos-permissions)).

A plain `make` build has no embedded Symphony, so it runs only in Development mode, and it can't update
itself. `make qa-app` builds this checkout's Symphony (an escript, so it needs the checkout's Erlang and
Elixir) and embeds it as `make bundle` does, for the QA state's `macos_app` playbook (see
[macOS app QA](../docs/configuration.md#macos-app-qa)). It sets no update key, so it can't update itself either.

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
directory and leaves your real settings, secrets and Symphony alone. The QA state's `macos_app` playbook
always launches the app this way (see [macOS app QA](../docs/configuration.md#macos-app-qa)). Turn it on by starting the app's binary
with `SYMPHONY_BAR_QA_ROOT` set to a directory. A launch from Finder or `open` doesn't pass the variable on, so
run the binary directly:

```bash
SYMPHONY_BAR_QA_ROOT="$(mktemp -d)" ./build/Symphony.app/Contents/MacOS/SymphonyBar
```

In QA mode, under that directory:

| Path | Holds | Instead of |
| --- | --- | --- |
| `settings.plist` | the Settings values, Launch at Login, the pending update across a relaunch, and the Symphony and Repos windows' frames and selections | UserDefaults; Launch at Login registers nothing with macOS |
| `secrets.json` | `LINEAR_API_KEY` and the other variables, readable only by you | `~/Library/Application Support/symphony/release/secrets.json` |
| `logs/` | Symphony's output log | `~/Library/Logs/symphony` |
| `updates/` | update downloads and the update helper's log | `~/Library/Caches/<bundle id>` |
| `state/` | Symphony's state: control URL and token (`SYMPHONY_STATE_ROOT`) | `~/Library/Application Support/symphony` |
| `symphony-logs/` | Symphony's own logs (`SYMPHONY_LOGS_ROOT`) | `~/Library/Logs/symphony/release` |

The app starts with empty settings, so Settings opens. It doesn't see a Symphony already running outside QA
mode, so Stop, Restart, Pause and Resume can't reach it, unless `SYMPHONY_STATE_ROOT` is set too, which wins
over `state/`. Until its own Symphony has written a control URL, the app doesn't look for one on the default
port 4000 either, where the Symphony a normal launch runs answers. `SYMPHONY_LOGS_ROOT` set in
the environment wins over `symphony-logs/` the same way. Saving
Settings leaves `~/Library/Application Support/symphony/release/secrets.json` and the login Keychain as they
were.

Start runs a checkout in Development mode, or the embedded Symphony with Development mode off. The embedded
Symphony runs from the app's bundle and takes the Erlang node name
`symphony@127.0.0.1`, so while another Symphony release runs, start the app with its own `ERL_EPMD_PORT`, for
example `ERL_EPMD_PORT=24369`, and use a `symphony.yml` whose `dashboard.port` is free (`0` picks one).

Each `symphony check` the app runs (on Save in Settings, and before Restart) goes to the app's stderr in QA
mode: its exit status and output, which start with the build that checked, `Symphony <version> (<commit>)`.

Eight more variables, read only in QA mode:

- `SYMPHONY_BAR_UPDATE_URL` replaces GitHub's `releases/latest` URL for update checks, for a local update feed
  that answers in the same format. An update in QA mode relaunches the app with its environment, so the new
  version is in QA mode too, with the same folders.
- `SYMPHONY_BAR_UPDATE_CHECK_INTERVAL=<seconds>` (a positive whole number) sets how often the app checks for
  a release in the background, in every update mode, in place of the mode's interval and **Check for releases
  every N minutes**, so a test or the e2e harness sees a release within seconds. A check that hit the rate limit
  still waits until the limit lifts, an hour when the 403 or 429 names no reset.
- `SYMPHONY_QA_OPENROUTER_URL` points Settings' OpenRouter section (Test connection, the Models list) at a stub
  OpenRouter instead of `https://openrouter.ai`, so QA never needs a real key: the API base `symphony
  openrouter-stub` prints, such as `http://127.0.0.1:4100/api`. Only an `http` or `https` URL on a loopback host
  counts. The Symphony the app runs gets it too and, also only in QA mode, checks and runs OpenRouter models
  against the stub. Outside QA mode the app always talks to `https://openrouter.ai`, whatever the environment
  says. See [OpenRouter in QA](../docs/configuration.md#qa-passes).
- `SYMPHONY_BAR_QA_API_FIXTURES=<dir>` makes the app read Symphony's local API from files instead of
  Symphony, so QA walks every view with fixed data and no Linear or model calls: each GET reads
  `<dir>/<path>.json` (for example `<dir>/api/v1/state.json` for `/api/v1/state`) and answers 404 when the
  file is missing, and each control POST (Pause, Resume, Force, Stop Run, and the Inbox's moves and Undo) is
  appended as one JSON line to `api-requests.jsonl` under the QA root and answered 200, with
  `<dir>/<path>.json` as the body when there is one (the `inbox` fixtures answer each move from
  `api/v1/control/`). The menu, the Repos window and the Symphony window
  all read through it, so the app shows Symphony as running (external). The fixtures of a running Symphony
  are in [`Tests/Fixtures/director-app/running`](Tests/Fixtures/director-app/running), and those of the
  Overview's four states next to it: `flowing`, `attention` (a stuck forced ticket and a Codex usage-limit
  hold; the stuck ticket, SHOP-305, has a failed run 1, its own endpoint and its transcript, SHOP-288 is a done
  ticket, the Inbox holds two pull requests, and Stop Run's requests are answered from `api/v1/control/`),
  `paused` (paused for "Deploy freeze") and `idle`, of the Inbox: `inbox` (one item of each kind, plus the Initiatives: two active, BIL-200 with BIL-206 waiting on you, one in review and one done),
  `inbox-empty` and `inbox-decision` (TP-892's decision, with three options, with every ticket and pull request it mentions resolved
  and where TP-892 sits: 4 of its parent's 7 sub-tickets done, its pull request, two connected tickets and one
  earlier decision; TP-891's endpoint, watched in Code Review with its parent, a blocker, TP-892, and a ticket it
  blocks; the plan TP-923, whose brief mentions TP-947; TP-895's pull request, TP-896's clarify and TP-897's
  block, whose texts mention tickets and pull requests for their chips), of the pull request page: `pull-request`
  (`inbox-decision`'s content plus PR #448's page: two Code Review verdicts, four areas and TP-891's PR #446
  overlapping it), of Tickets: `tickets` (tickets in every stage, a forced ticket, SHOP-325, a blocked one, a
  conflict, and API-140, which a `tickets.priorities` filter passes over), of the dispatch control's limit hold: `holding` (a Claude 5-hour limit), and of Shipped: `shipped` (14 days of
  merges in `web-shop` and `api` across the Gift cards and Rate limits initiatives, 14 of them in the last 7 days and 3
  shipped today, and learnings in both repos with tags), and of Audit: `audit` (two days of records of several kinds, your
  moves among them; Oct 7's chain verifies and Oct 6's breaks at its line 5, SHOP-298's PR opened, and SHOP-305's
  ticket page has a stop and a Backlog move), and of an update's pause: `update-paused` (dispatch paused "updating to
  v9.9.9" with two runs finishing) and `update-paused-idle` (the same pause with nothing running), which QA runs with
  the shared update feed's `--fake-release 9.9.9 9999` ([`test/support/README.md`](../test/support/README.md#the-update-feed)).
  `APIFixturesTests` decodes every fixture's state and repos, so one that drifts from the API fails CI. Ages in them
  count from the payload's `generated_at`, so they read the same on any day; clock times show in the Mac's time zone:

  ```bash
  SYMPHONY_BAR_QA_ROOT="$(mktemp -d)" SYMPHONY_BAR_QA_API_FIXTURES="$PWD/Tests/Fixtures/director-app/running" \
    ./build/Symphony.app/Contents/MacOS/SymphonyBar
  ```
- `SYMPHONY_QA_LINEAR_URL` points the Add Repo sheet's Linear queries (projects and labels) at a stub GraphQL
  endpoint instead of `https://api.linear.app/graphql`, such as `http://localhost:4101/graphql`. Only an `http`
  or `https` URL on a loopback host counts, since the sheet sends `LINEAR_API_KEY` with each query.
- `SYMPHONY_BAR_QA_OPEN_PANEL_DIR` makes the Add Repo sheet's folder picker open in that absolute folder, so a
  QA pass, which can't type a path into the panel, picks a prepared checkout with the panel's Choose button.
- `SYMPHONY_BAR_QA_APPEARANCE=light` or `dark` makes the app draw in that appearance (`NSApp.appearance`
  set to Aqua or Dark Aqua at launch) whatever the Mac's own setting, so QA judges both on one Mac without
  switching the Mac's appearance. Any other value, or none, follows the Mac.
- `SYMPHONY_BAR_QA_SCRIPTED=1` lets a script drive the app without Accessibility access. The app presses the
  menu item whose title the first line of a file in `commands/` holds (files are taken in name order and
  deleted; a name starting with `.` is skipped, so write one and rename it). As a click would, it presses
  only a visible, enabled item; an item in a visible item's submenu, such as Stop forcing TP-123, counts.
  It keeps `status.json` current: its pid, version, build and bundle path, the pid of the Symphony it runs,
  every visible menu item (submenu items right after the item they open from) with whether it is enabled,
  the presses it handled (`pressed`, `disabled` or `missing`) and the alerts it would have shown. It shows
  no alerts: it records them there, and answers confirmations (Update, Quit) yes. Notifications and the
  release notes window are recorded the same way, the window as its heading ("Symphony 0.0.1.43") and the
  text above the notes, then the notes. A recorded notification the app withdraws, such as "Updating Symphony
  to vX" once its update ends or is cancelled, is listed by its title under `withdrawn`. A prompt is answered
  with the rest of the command file and cancelled when there is none. Pause Dispatch… and Force a Ticket…,
  which open the Symphony window's sheets otherwise, are answered the same way: `Force a Ticket…` on the
  first line and `TP-123` on the second forces TP-123; `Pause Dispatch…` with a second line pauses with that
  reason, and without one pauses with the menu's.

In QA mode the app also opens its status-bar menu on screen when asked, so QA can screenshot it: an empty
file `status-menu/open-<pid>` under the QA root, named after the app's own process ID, makes the app delete it
and open the menu as a click on the menu bar item would (`qa_open_status_menu` writes it). Pressing the item
through Accessibility can't do this, because the menu holds the press until it closes. A request that comes
while the menu is open is dropped. Outside QA mode the app watches for no such file.

The [end-to-end test](Tests/e2e/README.md) uses all of this to test Update, Restart and rollback without
touching the installed app.

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

`SymphonyBarCore` holds pure logic that is unit tested without AppKit; `SymphonyBarUI` holds the AppKit views the
app wraps for SwiftUI (the chip text view), unit tested without a window; `SymphonyBar` is the AppKit app.
