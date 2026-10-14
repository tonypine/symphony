# The supervisor-check inventory

`docs/design/state-machine.md` §"The review skill, diluted" gives every duty the old review skill
performed exactly one home, and settles the checks an implementation run cannot run — host, device,
DB-backed — as **CI** (write the test), **QA** (its VM, emulator and host driver), or consciously
left out. This is that settlement at capability level: every check an agent used to hand a person as
a `## Supervisor check` block, and where it lives now.

The escape hatches (`priv/playbook/escape_hatches.liquid`) no longer hand a check to a person: a
check is CI's or QA's, and a block that stops work is an environment block the self-heal lane
handles. Supervisor checks are retired: no repo's instructions hand a check to the supervisor, and
no code reads a `## Supervisor check` block.

| Old capability, handed to the supervisor | Home now | Where |
|---|---|---|
| Launch the macOS app and judge what is on screen | QA playbook | `priv/qa_playbooks/macos_app.md` — `qa_build`, then `qa_launch_app` in QA mode; read the app with `qa_ax_tree` and `qa_screenshot` |
| Host crash check: the app is still up, still responding, and wrote no new crash report | QA playbook | `macos_app.md` — `qa_check_app` reports `running`, `responding` and `crash_reports` (from the machine the app runs on) |
| Check a web app in a real browser | QA playbook | `priv/qa_playbooks/web.md` — the `browser` MCP server against the dev server QA started, with a screenshot and a console dump per step |
| Check a CLI's real behavior | QA playbook | `priv/qa_playbooks/cli.md` — build the entry point, then exercise it in throwaway `$TMPDIR` state, never a real config or key |
| Check on a device (Android emulator) | QA playbook | `priv/qa_playbooks/android_app.md` — `qa_android_install`/`launch`/`ui_tree`/`tap`/`type`, plus rotate, dark mode and font scale |
| Check on an iOS device or simulator | Consciously left out | No `ios_app` playbook kind or host driver exists (the built-ins are `cli`, `macos_app`, `web`, `android_app`); adding one is its own ticket. Until then an iOS check that blocks work is an environment block, so the self-heal lane files a fix ticket for it |
| A check that is really a test: logic, an endpoint, a migration, a rendering | CI | Write the test — CI runs the suite (`mix test`); QA judges user journeys, not script execution |
| A check that needs a live database or another service | CI when it can be a test, else QA | A DB-backed assertion is a test CI runs; what a user sees of it QA reaches through the app's own dev server |
| A check that needs hardware, an account or a license nobody can hand the machine | Consciously left out — Needs Decision | `docs/design/state-machine.md` §Guards: a fix that itself needs a person surfaces through the fix ticket's own flow, and a block only a person can clear keeps its access hold |

Every row above is a home, not a hand-off: none of them moves a ticket to a review state for a
check. A capability that turns out to belong in none of these rows is a coverage gap to close in CI
or a QA playbook — never a task queued for a person.
