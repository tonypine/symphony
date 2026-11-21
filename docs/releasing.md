# Releasing

Symphony ships as `Symphony.app`, the macOS menu bar app with the self-contained
Symphony release (`mix release`, Erlang runtime included) inside at
`Contents/Resources/symphony-release` and its launcher at `Contents/Resources/symphony`. The [`release` workflow](../.github/workflows/release.yml)
builds and publishes it as a GitHub Release on every push to `main`, on every
pushed `v*` tag, and when run by hand (**Actions → release → Run workflow**).
Only macOS arm64 is built.

## Versioning

Every release has a monotonic, machine-comparable version:

| Field | Value | Example |
| --- | --- | --- |
| `CFBundleVersion`, `version.json` `build` | the workflow run number | `42` |
| `CFBundleShortVersionString`, `version.json` `version` | `<mix.exs version>.<run number>` | `0.0.1.42` |
| Release tag | `v<short version>` | `v0.0.1.42` |
| Elixir release version (`SYMPHONY_BUILD_NUMBER`) | `<mix.exs version>-<run number>` | `0.0.1-42` |

The binary also records the commit and repository it is built from
(`SYMPHONY_BUILD_SHA`, `SYMPHONY_BUILD_REPO`); `/api/v1/state` reports them as
`build: {version, sha}`. A ticket blocked by a fix merged in that repository stays
held until the running app includes the fix's merge commit, and the menu bar
shows "Update to unblock N tickets" while any are held. A build without them, such
as one from a checkout, holds nothing.

A pushed `v*` tag is released under its own name with the same versions.
Compare `build` to tell which release is newer. Bump `@version` in `mix.exs`
for a new major, minor or patch version.

The app carries the release in `Contents/Resources/symphony-release` and runs it
in place, so nothing is unpacked outside the signed bundle. `make release`
appends `SYMPHONY_BUILD_NUMBER` to the `mix.exs` version (`0.0.1-42`); without
it the release version is the plain `mix.exs` version.

## Release assets

| Asset | What it is |
| --- | --- |
| `Symphony-<version>.zip` | `Symphony.app`, zipped with `ditto -c -k --keepParent` |
| `Symphony-<version>.zip.sha256` | its SHA-256, checked with `shasum -a 256 -c` |
| `Symphony-<version>.zip.minisig` | its minisign signature, only when the minisign key is configured |
| `version.json` | `version`, `build`, `sha256`, `commit`, `published_at`, `signed`, `zip`, `minisig` (asset name or `null`), `changes`, `settings_migrations` (the settings keys this build rewrites by itself, from `symphony config migrations`) |

The release notes list the commit subjects since the previous `v*` tag, headed
"N changes since v…". Releases are not marked prerelease, so
`releases/latest` returns the newest one. The assets are made by
[`scripts/release/package.sh`](../scripts/release/package.sh), which you can run
locally on a built app.

## Signing

The workflow signs every Mach-O in the embedded release first (ERTS's executables,
NIFs and port programs), then the app bundle, without the hardened runtime, and
checks the app with `codesign --verify --strict --deep`. Two sets of repository secrets are
optional; without them the release still publishes:

- `MACOS_SIGNING_P12_BASE64`, `MACOS_SIGNING_P12_PASSWORD`, `MACOS_SIGNING_IDENTITY`:
  the code-signing certificate. The workflow imports it into a temporary
  keychain, signs with `MACOS_SIGNING_IDENTITY`, and deletes the keychain at the
  end of the job. Without them the app is signed ad hoc, and `version.json` has
  `"signed": false`.
- `MINISIGN_SECRET_KEY`, `MINISIGN_PASSWORD`: the minisign key for the `.minisig`
  asset. Without them there is no `.minisig`, and `version.json` has
  `"minisig": null`.

One repository variable (**Settings → Secrets and variables → Actions → Variables**)
is optional too:

- `MINISIGN_PUBLIC_KEY`: the key line of the matching `minisign.pub` (the line
  after `untrusted comment:`). `make bundle` writes it into the app's
  `Info.plist` as `SymphonyUpdatePublicKey`, and the menu bar app verifies
  updates against it. Without it the app's **Update to vX** item is off. The app
  also refuses releases without a `.minisig`, and, while the app is signed ad
  hoc, every update. The release notes quote it in their `minisign` command.

The app is not notarized by Apple, so Gatekeeper warns on first launch of a
downloaded copy. The release notes point users at
[`scripts/install-macos.sh`](../scripts/install-macos.sh), which verifies the
zip and clears the quarantine flag, and show the manual steps
(`xattr -dr com.apple.quarantine`, or Open Anyway in System Settings → Privacy &
Security). The install script carries the public key too, as its default
`SYMPHONY_MINISIGN_PUBLIC_KEY`, so update it there if you rotate the key. See
[Install](../macos/README.md#install).

## Verify a release

```bash
shasum -a 256 -c Symphony-<version>.zip.sha256
minisign -Vm Symphony-<version>.zip -P RWThT600NSBP4TROh1cvUt5N37/c3BctbnE3Qe+VO0A81t6IikB2BPMp
ditto -x -k Symphony-<version>.zip .
codesign --verify --strict Symphony.app    # CSSMERR_TP_NOT_TRUSTED where the Symphony certificate isn't trusted
codesign --verify --strict --deep Symphony.app
codesign -dvv Symphony.app    # Authority=… once the certificate is configured
./Symphony.app/Contents/Resources/symphony check
```

## Build the app locally

```bash
SYMPHONY_BUILD_NUMBER=1 make release   # writes _build/prod/rel/symphony
cd macos
make bundle SYMPHONY_RELEASE=../_build/prod/rel/symphony SHORT_VERSION=0.0.1.1 BUILD_NUMBER=1
```

`make bundle` copies the release to `Contents/Resources/symphony-release`, installs its
launcher (`bin/symphony-app`) as `Contents/Resources/symphony`, signs every Mach-O in the
release and then the app, and checks the app with `codesign --verify --strict --deep`. It
signs ad hoc unless you pass `SIGNING_IDENTITY`, and embeds the update key when you pass
`MINISIGN_PUBLIC_KEY`.

The release workflow smoke-tests the app's Symphony after signing; run the
same check locally (cwd is `macos/`, after the commands above):

```bash
../scripts/release/smoke_test.sh build/Symphony.app/Contents/Resources/symphony "$PWD/../symphony.yml"
```

The release workflow runs only on pushes to `main`, so pull request CI (`make-all`'s `build`
job) runs the same script on the escript, without the service step only the release
needs. Locally, `make smoke` does the same. A pull request that changes how the release is
built or started (`rel/`, `mix.exs`, `mix.lock`, `mise.toml`, the `Makefile`, `config/`'s
`config.exs` and `runtime.exs`, `ReleaseNode`, `ReleaseCookie`, the `CLI` entry point and
`Paths`, `scripts/release/`, the pinned Xcode, the sample `symphony.yml`, or the `release`
workflow) also runs the Mac checks' `smoke` group (`scripts/ci/mac-check-groups.sh`,
[`mac-checks.yml`](../.github/workflows/mac-checks.yml)): on the self-hosted runner it builds the
release and the app as `release` does and runs the whole script on the app's launcher, service
step included. Every merge to `main` runs it again in the release gate.

The script gives each run a fresh `HOME` and creates an empty git repo there at every
`repo: ~/...` path the config names, since `symphony check` rejects a `strategy: worktree`
repo that doesn't exist.

## The release run

A merge to `main` starts one `release` run. Its gate is the Mac checks with every group on, from a
clean build, in three jobs that start together (TP-1591):

- `release gate / mac checks (app)`, on one self-hosted runner: the script tests that need a Mac,
  the app's clean release build, the release smoke test, the update test and the install script.
  The smoke test builds the Symphony release for this run's build number from nothing and files it
  in the build store; the update test's two releases compile on top of it in the same job.
- `release gate / mac checks (tests)`, on the other runner: the Swift tests from a clean debug
  build, the gallery on that build, the agent-sandbox build and the QA driver's tests.
- `release gate / mac checks (scripts)`, on Linux: the Xcode selection script and the shared test
  helpers.

The `release` job needs all three, so a red gate publishes nothing. It takes the app's executable
and the smoke-tested release from the build store (building either from nothing when the store has
none), signs, smoke-tests the signed app, packages and publishes.

## When the release gate fails

A merge to `main` whose release gate fails publishes nothing. Symphony files one Urgent fix ticket
in Todo with the failure (a later failure is added to it while it is open), and moves it back to
Todo itself if it ever sits in Backlog. While the gate is red:

- the fix ticket is the only ticket of the repository Symphony dispatches; every other one reads
  "Holding while the release gate on main is red: TP-… is fixing it";
- no app-update hold waits on the fix ticket, since the build it would wait for publishes only once
  its fix lands;
- a ticket held for a build whose gate failed waits for the later build that carries its commit,
  and its line names that build, never the failed one.

The hold follows the gate, not the fix ticket. It lifts as soon as a `release` run on `main` passes
the gate: a later build, or a rerun of the run that failed on the same commit. Symphony then starts
a dispatch pass at once, so held tickets do not wait for the next poll, and every poll compares the
gate with the builds it keeps in case GitHub's delivery was missed. It also lifts when the fix
ticket is closed. While the gate is red, `/api/v1/state` lists it under `red_bases` with the tickets
it holds.

A build that passes with the fix ticket still open (the check passed with no fix merged) adds a
comment to the ticket: a check that fails at random is a defect in the check, and the ticket still
asks for it. The fix ticket is not closed or moved; it runs on as an ordinary ticket.
