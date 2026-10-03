# End-to-end test: Update, Restart and rollback

`update_restart_e2e.py` runs the real app bundles, built from the current checkout, in an isolated instance
and checks what TP-272 used to leave to a person on the live app:

1. **Update** from release N to N+1 while an agent run is active. The old Symphony waits for the run, then
   stops; the new app starts its Symphony on its own and dispatch resumes. Afterwards only N+1's unpacked
   release is left, no BEAM from N runs, and the app folder holds N+1 as `Symphony.app` and N as
   `Symphony (previous).app`. If N's unpacked release disappears while N's Symphony still runs (the
   [TP-339](https://linear.app/tonypine/issue/TP-339) failure: the new binary ran before the old Symphony
   stopped), the test fails.
2. **Restart** while a run is active: it waits for the run, restarts, and dispatch resumes.
3. **Restart with a broken `symphony.yml`**: refused with "Symphony wasn't restarted" and the config error,
   and the running Symphony keeps its pid and keeps dispatching.
4. **Rollback**: Quit, swap `Symphony (previous).app` back in as in [Rollback](../../README.md#rollback), open
   it and Start: it runs, and the agent runs it starts get the secret stored in Settings.

For each scenario the test checks the menu lines, the Symphony pid, the stub agent's log (a run that is
stopped instead of finishing fails the drain checks) and a `before_run` hook's log, which records the binary
and unpacked release each run came from and the stored secret Symphony was given.

## Run it

From `macos/`, on an Apple silicon Mac with Xcode or the Command Line Tools, the repository's `mise`
toolchain and `minisign` (`brew install minisign`):

```bash
make e2e
```

It takes a while: it builds two Burrito binaries (`make package` with build numbers 90001 and 90002), the app,
and both bundles. It prints each step, then `all 4 scenarios passed`, and exits 1 on the first failure with
the app's status, the update helper's, app's and stub agent's logs, and the processes still running. The
work folder is removed on success and kept on failure (or with `--keep`).

Both bundles must be signed with the same certificate, as real updates are. Without one given, the test makes
a throwaway self-signed code-signing identity in a temporary keychain. `codesign --verify` and the app accept
it only once it is trusted for code signing, so set one of:

| Variable | Effect |
| --- | --- |
| `SYMPHONY_E2E_SIGNING_IDENTITY` | sign with this identity instead, for example the Symphony release certificate in your login keychain |
| `SYMPHONY_E2E_KEYCHAIN` | the keychain that holds that identity, when it isn't in the search list |
| `SYMPHONY_E2E_TRUST_CERT=1` | trust the throwaway certificate for code signing until the test ends (`sudo security add-trusted-cert`; CI sets this) |

Other options:

| Variable | Effect |
| --- | --- |
| `SYMPHONY_E2E_SYMPHONY_BIN_N`, `SYMPHONY_E2E_SYMPHONY_BIN_N1` | use these Burrito binaries instead of building them (they must be built with the matching `SYMPHONY_BUILD_NUMBER`) |
| `SYMPHONY_E2E_APP_EXECUTABLE` | use this `SymphonyBar` executable instead of `swift build -c release` |
| `SYMPHONY_E2E_BUILD_N` | build number of release N (default 90001); N+1 is the next number |
| `SYMPHONY_E2E_STUB_SECONDS` | how long each stub agent run takes (default 15) |
| `SYMPHONY_E2E_WORK_ROOT` | where the work folder is made (default the temporary folder) |

## What it never touches

The test can run while the installed app runs Symphony. The instance gets its own:

- app folder (`<work>/Applications`), not `~/Applications/Symphony.app`;
- [QA mode](../../README.md#qa-mode) root for settings, secrets, logs, update downloads, Symphony's state, its
  logs and its unpacked release (`SYMPHONY_INSTALL_DIR`), and a fresh `HOME`;
- scripted QA mode, so it presses menu items by title through files instead of Accessibility access;
- `ERL_EPMD_PORT`, since a Symphony release always takes the node name `symphony@127.0.0.1`;
- dashboard port (`dashboard.port: 0`), and a local update feed (`SYMPHONY_BAR_UPDATE_URL`) serving N+1;
- fake Linear: the memory tracker reading one issue from a file (`issues.memory.issues_file`), and a stub
  `claude` that answers each turn after `SYMPHONY_E2E_STUB_SECONDS`, so runs cost nothing.

Before and after, it records the installed app's processes, the Symphony BEAMs running from
`~/Library/Application Support/.burrito`, what listens on port 4000, the metadata of the live state files
(`control_url`, `control_token`, `erlang_cookie`, `secrets.json`, never their contents) and the live unpacked
releases. Any difference fails the test.

## CI

The `macos-e2e` workflow runs it nightly, on demand, and on pull requests that change the app, the release
packaging or this test. On failure it uploads the work folder's logs.
