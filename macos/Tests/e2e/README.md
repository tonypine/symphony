# End-to-end test: Update, Restart and rollback

`update_restart_e2e.py` runs the real app bundles, built from the current checkout, in an isolated instance,
and checks the three things only a real install can prove:

1. **Update** from release N to N+1 while an agent run is active. The stub run is held until the test has seen
   the update wait for it ("Waiting for …" in the menu, the run still going under N's Symphony), then released.
   The old Symphony stops only after the run ended; N+1 is downloaded, verified, swapped in and relaunched from
   its own bundle, starts its Symphony on its own and dispatch resumes. Afterwards every Symphony `beam.smp` runs
   N+1's release from inside the running app's bundle, no BEAM from N runs, N+1's run gets the secret stored in
   Settings, the app folder holds N+1 as `Symphony.app` and N as `Symphony (previous).app`, N+1 has migrated a
   renamed `symphony.yml` key with a backup, and the new app's menu shows "Updated to vN+1".
2. **Automatic rollback** ([TP-541](https://linear.app/tonypine/issue/TP-541)'s walkthrough, step 4): N is put back
   and, in **Automatically when idle**, installs N+1 by itself. N+1's check before the install passes, the test
   then removes `symphony.yml`'s `workspaces.repo`, N+1's check after the relaunch fails, and the helper puts N
   back as `Symphony.app` and N+1 aside as `Symphony (rolled back).app`. N notifies "Symphony rolled back to
   vN", naming vN+1 and the failed check; its menu line "vN+1 was rolled back: symphony check failed: …"
   opens N+1's notes with the rollback steps; and its next check shows N+1 rolled back with Retry vN+1,
   without installing it again.
3. **An update that can't start** ([TP-1324](https://linear.app/tonypine/issue/TP-1324)): Retry vN+1 from N, with a
   relaunch that makes N+1's binary not executable before it runs it. N+1 never writes that it launched, so once
   the update helper's start window has passed it puts N back as `Symphony.app`, N+1 aside as
   `Symphony (rolled back).app`, and opens N. N runs again, notifies "Symphony rolled back to vN", shows
   "vN+1 was rolled back: the app didn't start within 5 seconds of the update; see …/update.log" and Update
   rolled back: vN+1 with Retry vN+1, and the update log has a timestamped line for each step, the launch that
   failed included. The window is 30 seconds in the product (`UpdateLaunch.timeout`); the test shortens it to 5
   through the helper's `SYMPHONY_UPDATE_LAUNCH_SECONDS`, which QA mode passes on to the helper.

For each scenario the test checks the menu lines, the Symphony pid, the stub agent's log (a run that is
stopped instead of finishing fails the drain check) and a `before_run` hook's log, which records the release
root and version each run came from and the stored secret Symphony was given. Scripted QA mode records the
notifications and the release notes window in `status.json` with the alerts, so the test reads them there.

The stub agent's runs end when the test says so, never after a fixed time: while `<work>/config/hold-runs` exists
each run waits (at most 5 minutes, so a stuck test can't hang CI), and without it a run ends at once. The stub
ticket is dispatched again and again without a state move, so the test's `symphony.yml` sets the dispatch-loop
guard's `watchdog.dispatch_loop_*` limits to 50 runs within one second, out of reach of one test run; the
defaults would hold it after 4 runs in 10 minutes. When no new run starts in time, the failure says whether
Symphony skips the ticket and why, such as a `Blocked` hold.

### What the unit tests cover instead

The rest of Update, Restart and rollback is decided in `SymphonyBarCore` and covered by its unit tests
(`Tests/SymphonyBarCoreTests/`), so this test no longer walks it:

| Behaviour | Unit tests |
| --- | --- |
| Restart while a run is active drains, restarts and resumes; a pause resumed behind the app's back is made again ([TP-435](https://linear.app/tonypine/issue/TP-435)) | `RestartMachineTests`: `testRestartPausesWaitsForRunsStopsStartsAndResumes`, `testAPauseResumedBeforeTheFirstPollIsMadeAgainAndResumedAfterwards`, `testAPauseResumedWhileTheRestartWaitsIsMadeAgain` |
| Restart with a broken `symphony.yml` is refused and Symphony keeps running | `RestartMachineTests`: `testConfigErrorAbortsWithSymphonyUntouched` |
| An app runs Symphony from its own bundle, with the stored secrets in its environment (as after a rollback by hand) | `ChildLaunchTests`: `testEmbeddedSymphonyLivesInTheBundleResources`, `testEmbeddedModeKeepsSecretsInTheEnvironmentOnly`; scenario 1 here, for the real bundle |
| **Automatically when released** installs with no press, pausing with "updating to vX" while runs go on, and notifies the start with Cancel Update ([TP-970](https://linear.app/tonypine/issue/TP-970)) | `AutoUpdateTests`: `testOnReleaseInstallsOnTheCheckThatFindsARelease`; `RestartMachineTests`: `testAnUpdatesPauseNamesTheVersionItInstalls`, `testUpdateDrainsThenStopsWithoutStarting`; `UpdateKindTests`: `testStartNotificationWording`, `testStartNotificationIsDueOnceWhenTheDrainKnowsItsRuns` |
| A pause made by hand stays after an update | `RestartMachineTests`: `testUpdateKeepsAPauseTheUserMade`; `UpdateHandoffTests`: `testKeepsAPauseTheUserMade` |
| Cancel Update resumes dispatch, withdraws the start notification and holds the release until a newer one or Update to vX | `RestartMachineTests`: `testOnReleaseUpdateCancelResumesTheDispatchItPaused`; `UpdateKindTests`: `testStartNotificationIsWithdrawnWhenTheUpdateEnds`, `testCancelUpdateOnAnOnReleaseUpdateHoldsItsRelease`; `AutoUpdateTests`: `testCancelUpdateHoldsTheReleaseUntilANewerOneComesOut`, `testInstallingOrSkippingTheHeldReleaseClearsTheHold` |
| **Automatically when idle** installs only when no run is active, and the updated app notifies and shows "Updated to vX (K changes)", which opens the notes ([TP-541](https://linear.app/tonypine/issue/TP-541)) | `AutoUpdateTests`: `testIdleModeInstallsOnACheckWhenIdle`, `testIdleModeWaitsForRunsAndInstallsAtTheFirstIdlePoll`; `UpdateOutcomeTests`: `testUpdatedNotificationNamesTheNewVersionAndItsChanges`, `testUpdatedLineNamesTheVersionAndTheChangeCountWhenKnown`, `testTheUpdatedLineOpensTheInstalledReleasesNotes` |
| Retry vX with a `symphony.yml` the new build can't read is refused before anything is installed | `UpdateInstallerTests`: `testAFileTheNewBuildCantReadIsRefusedBeforeAnythingIsInstalled`; `SkippedReleasesTests`: `testARefusedReleaseNamesTheLinesAndOffersRetry` |

## Run it

From `macos/`, on an Apple silicon Mac with Xcode or the Command Line Tools, the repository's `mise`
toolchain and `minisign` (`brew install minisign`):

```bash
make e2e
```

It takes a while: it builds the release pair, two Symphony releases (`make release` with build numbers 90001 and
90002), the app and both bundles, with the shared helpers in [`test/support/`](../../../test/support/README.md)
(`release_pair.py`, as `make release-pair` does, into `<work>/release-pair`), and serves N+1 with their update
feed stand-in (`test/support/stubs/update_feed.py`, its requests logged to `<work>/logs/feed.log`). It prints each step, then `all 3 scenarios passed`, and exits 1 on the first failure with
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
| `SYMPHONY_E2E_WORK_ROOT` | where the work folder is made (default the temporary folder) |

## What it never touches

The test can run while the installed app runs Symphony. The instance gets its own:

- app folder (`<work>/Applications`), not `~/Applications/Symphony.app`;
- [QA mode](../../README.md#qa-mode) root for settings, secrets, logs, update downloads, Symphony's state and
  its logs, and a fresh `HOME`;
- scripted QA mode, so it presses menu items by title through files instead of Accessibility access;
- `ERL_EPMD_PORT`, since a Symphony release always takes the node name `symphony@127.0.0.1`;
- dashboard port (`dashboard.port: 0`), and a local update feed (`SYMPHONY_BAR_UPDATE_URL`) serving N+1;
- fake Linear: the memory tracker reading one issue from a file (`issues.memory.issues_file`), and a stub
  `claude` that answers each turn when the test releases it, so runs cost nothing.

Before and after, it records the installed app's processes, the Symphony BEAMs running from its bundle, what listens
on port 4000 and the metadata of the live state files (`control_url`, `control_token`, `erlang_cookie`,
`secrets.json`, never their contents). Any difference fails the test.

## CI

The Mac checks (`.github/workflows/mac-checks.yml`, on the self-hosted runner) run it on pull requests that change
the update's paths (`scripts/ci/mac-check-groups.sh`, the `update` group) and on every merge to `main`, in the release
gate, before anything is published. On failure they upload the work folder's
logs and the release pair's `manifest.json`, without the apps, the feed or the keys.
