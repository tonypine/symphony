# End-to-end test: Update, Restart and rollback

`update_restart_e2e.py` runs the real app bundles, built from the current checkout, in an isolated instance
and checks what TP-272 used to leave to a person on the live app:

1. **Update** from release N to N+1 while an agent run is active. The old Symphony waits for the run, then
   stops; the new app starts its Symphony on its own and dispatch resumes. Afterwards every Symphony
   `beam.smp` runs N+1's release from inside the running app's bundle, no BEAM from N runs, the app folder holds N+1 as
   `Symphony.app` and N as `Symphony (previous).app`, and the new app's menu shows "Updated to vN+1", the
   release carried across the relaunch.
2. **Restart** while a run is active: it waits for the run, restarts, and dispatch resumes. The test pauses
   dispatch from the menu, resumes it through the control API and presses Restart before the app polls again, so
   the app still thinks dispatch is paused: the restart must pause it itself (Symphony's log shows its
   `POST /api/v1/control/pause`) instead of waiting forever for a pause
   ([TP-435](https://linear.app/tonypine/issue/TP-435)).
3. **Restart with a broken `symphony.yml`**: refused with "Symphony wasn't restarted" and the config error,
   and the running Symphony keeps its pid and keeps dispatching.
4. **Rollback**: Quit, swap `Symphony (previous).app` back in as in [Rollback](../../README.md#rollback), open
   it and Start: it runs N's BEAM from its own bundle, and the agent runs it starts get the secret stored in
   Settings.
5. **`update_on_release`** ([TP-970](https://linear.app/tonypine/issue/TP-970)'s journey J3,
   [TP-973](https://linear.app/tonypine/issue/TP-973)): build N runs in **Automatically when released**, checking
   every 2 seconds (`SYMPHONY_BAR_UPDATE_CHECK_INTERVAL`), with the feed serving N only and an agent run active.
   The feed then publishes N+1 and, with no menu press, the app pauses dispatch with the reason `updating to vN+1`
   while the run goes on, records the start notification "Updating Symphony to vN+1" with its Cancel Update action,
   waits for the run, relaunches on N+1 and resumes dispatch. No BEAM from N is left, and N+1 notifies "Symphony
   updated to vN+1". It fails in Manual mode (nothing installs) and when no start notification is recorded.
6. **`update_on_release_hand_pause`**: N is put back and dispatch paused by hand, with a reason, before N+1 is
   published. N+1 installs by itself, and the relaunched Symphony is still paused with that reason.
7. **`update_on_release_cancel`** (journey J4): the same start, then Cancel Update once the app paused for N+1 and
   recorded the start notification. Dispatch resumes, the run goes on, the start notification is withdrawn, and
   over the next three checks (counted at the feed) no update to N+1 starts and no second start notification is
   recorded. The menu shows N+1 held: "You cancelled this update. It waits for you; a newer release installs by
   itself.", **Update to vN+1** and **Skip This Version**. Update to vN+1, confirmed, waits for the run under way
   and relaunches on N+1 with dispatch resumed.
8. **Automatic update** ([TP-541](https://linear.app/tonypine/issue/TP-541)'s walkthrough, steps 1 to 3):
   with **Automatically when idle** chosen and Symphony running with no agent runs, N installs N+1 with no
   press. N+1 passes its health check, starts Symphony and resumes dispatch, and notifies "Symphony updated
   to vN+1" with the change count. Its menu shows "Updated to vN+1 (K changes)", and choosing it opens N+1's
   release notes.
9. **Automatic rollback** (TP-541's walkthrough, step 4): N is put back with a `symphony.yml` whose
   `workspaces.repo` doesn't exist. N installs N+1 by itself, N+1's config check fails, and the helper puts N
   back as `Symphony.app` and N+1 aside as `Symphony (rolled back).app`. N notifies "Symphony rolled back to
   vN", naming vN+1 and the failed check; its menu line "vN+1 was rolled back: symphony check failed: …"
   opens N+1's notes with the rollback steps; and its next check shows N+1 rolled back with Retry vN+1,
   without installing it again.
10. **An update that can't start** (TP-1324): Retry vN+1 from N, with a relaunch that makes N+1's binary not
   executable before it runs it. N+1 never writes that it launched, so after 30 seconds the update helper
   puts N back as `Symphony.app`, N+1 aside as `Symphony (rolled back).app`, and opens N. N runs again within
   60 seconds of the hand-over, notifies "Symphony rolled back to vN", shows "vN+1 was rolled back: the app
   didn't start within 30 seconds of the update; see …/update.log" and Update rolled back: vN+1 with Retry
   vN+1, and the update log has a timestamped line for each step, the launch that failed included.

For each scenario the test checks the menu lines, the Symphony pid, the stub agent's log (a run that is
stopped instead of finishing fails the drain checks) and a `before_run` hook's log, which records the release
root and version each run came from and the stored secret Symphony was given. Scripted QA mode records the
notifications and the release notes window in `status.json` with the alerts, and the notifications the app withdraws
under `withdrawn`, so the test reads them there. Scripted QA presses the menu's Cancel Update, which does what the
notification's Cancel Update does.

The stub ticket is dispatched again and again without a state move, so the test's `symphony.yml` sets the
dispatch-loop guard's `watchdog.dispatch_loop_*` limits to 50 runs within one second, out of reach of one test
run; the defaults would hold it after 4 runs in 10 minutes. When no new run starts in time, the failure says
whether Symphony skips the ticket and why, such as a `Blocked` hold.

## Run it

From `macos/`, on an Apple silicon Mac with Xcode or the Command Line Tools, the repository's `mise`
toolchain and `minisign` (`brew install minisign`):

```bash
make e2e
```

It takes a while: it builds the release pair, two Symphony releases (`make release` with build numbers 90001 and
90002), the app and both bundles, with the shared helpers in [`test/support/`](../../../test/support/README.md)
(`release_pair.py`, as `make release-pair` does, into `<work>/release-pair`), and serves N+1 with their update
feed stand-in (`test/support/stubs/update_feed.py`, its requests logged to `<work>/logs/feed.log`). It prints each step, then `all 9 scenarios passed`, and exits 1 on the first failure with
the app's status, the update helper's, app's and stub agent's logs, and the processes still running. The
work folder is removed on success and kept on failure (or with `--keep`).

Both bundles must be signed with the same certificate, as real updates are. Without one given, the test makes
a throwaway self-signed code-signing identity in a temporary keychain, on your keychain search list until the
test ends. `codesign --verify` and the app accept it only once it is trusted for code signing, so set one of
(see the [helpers' README](../../../test/support/README.md#signing-identity)):

| Variable | Effect |
| --- | --- |
| `SYMPHONY_E2E_SIGNING_IDENTITY` | sign with this test identity instead, trusted for code signing (never Symphony's release certificate) |
| `SYMPHONY_E2E_KEYCHAIN` | the keychain that holds that identity, when it isn't in the search list |
| `SYMPHONY_E2E_TRUST_CERT=1` | trust the throwaway certificate for code signing until the test ends (`sudo security add-trusted-cert`; CI sets this) |

Other options:

| Variable | Effect |
| --- | --- |
| `SYMPHONY_E2E_SYMPHONY_RELEASE_N`, `SYMPHONY_E2E_SYMPHONY_RELEASE_N1` | use these release directories (`_build/prod/rel/symphony`) instead of building them (they must be built with the matching `SYMPHONY_BUILD_NUMBER`) |
| `SYMPHONY_E2E_APP_EXECUTABLE` | use this `SymphonyBar` executable instead of `swift build -c release` |
| `SYMPHONY_E2E_BUILD_N` | build number of release N (default 90001); N+1 is the next number |
| `SYMPHONY_E2E_STUB_SECONDS` | how long each stub agent run takes (default 15; 45 in scenarios 5 to 7, so the run active when N+1 is published outlasts its download) |
| `SYMPHONY_E2E_WORK_ROOT` | where the work folder is made (default the temporary folder) |

## What it never touches

The test can run while the installed app runs Symphony. The instance gets its own:

- app folder (`<work>/Applications`), not `~/Applications/Symphony.app`;
- [QA mode](../../README.md#qa-mode) root for settings, secrets, logs, update downloads, Symphony's state and
  its logs, and a fresh `HOME`;
- scripted QA mode, so it presses menu items by title through files instead of Accessibility access;
- `ERL_EPMD_PORT`, since a Symphony release always takes the node name `symphony@127.0.0.1`;
- dashboard port (`dashboard.port: 0`), and a local update feed (`SYMPHONY_BAR_UPDATE_URL`) serving N+1 (its
  `publish` mode), or N only (`none`) until scenarios 5 to 7 publish N+1;
- fake Linear: the memory tracker reading one issue from a file (`issues.memory.issues_file`), and a stub
  `claude` that answers each turn after `SYMPHONY_E2E_STUB_SECONDS`, so runs cost nothing.

Before and after, it records the installed app's processes, the Symphony BEAMs running from its bundle, what listens
on port 4000 and the metadata of the live state files (`control_url`, `control_token`, `erlang_cookie`,
`secrets.json`, never their contents). Any difference fails the test.

## CI

The `macos-e2e` workflow runs it nightly, on demand, and on pull requests that change the app, the release
packaging, the shared release-pair and update feed helpers or this test. On failure it uploads the work folder's
logs and the release pair's `manifest.json`, without the apps, the feed or the keys.
