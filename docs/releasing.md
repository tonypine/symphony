# Releasing

Symphony ships as `Symphony.app`, the macOS menu bar app with the self-contained
[Burrito](https://github.com/burrito-elixir/burrito) `symphony` binary inside at
`Contents/Resources/symphony`. The [`release` workflow](../.github/workflows/release.yml)
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

Burrito unpacks the binary into
`~/Library/Application Support/.burrito/symphony_erts-<erts>_<release version>/`
and reuses that directory when it exists, so each build needs its own Elixir
release version. `make package` appends `SYMPHONY_BUILD_NUMBER` to the `mix.exs`
version as a semver pre-release; without it the release version is the plain
`mix.exs` version. Burrito deletes the directories of lower versions when a
newer build first runs. A pre-release sorts below the plain version, so the
directory of an unsuffixed build (`symphony_erts-<erts>_0.0.1`, including any
unpacked before build numbers were added) is never deleted; remove it by hand.

## Release assets

| Asset | What it is |
| --- | --- |
| `Symphony-<version>.zip` | `Symphony.app`, zipped with `ditto -c -k --keepParent` |
| `Symphony-<version>.zip.sha256` | its SHA-256, checked with `shasum -a 256 -c` |
| `Symphony-<version>.zip.minisig` | its minisign signature, only when the minisign key is configured |
| `version.json` | `version`, `build`, `sha256`, `commit`, `published_at`, `signed`, `zip`, `minisig` (asset name or `null`), `changes` |

The release notes list the commit subjects since the previous `v*` tag, headed
"N changes since v…". Releases are not marked prerelease, so
`releases/latest` returns the newest one. The assets are made by
[`scripts/release/package.sh`](../scripts/release/package.sh), which you can run
locally on a built app.

## Signing

The workflow signs the embedded binary first, then the app bundle, without
`--deep` and without the hardened runtime. Two sets of repository secrets are
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
codesign --verify --strict Symphony.app/Contents/Resources/symphony
codesign -dvv Symphony.app    # Authority=… once the certificate is configured
./Symphony.app/Contents/Resources/symphony check
```

## Build the app locally

```bash
BURRITO_TARGET=macos_arm64 SYMPHONY_BUILD_NUMBER=1 make package   # writes burrito_out/symphony-macos-arm64
cd macos
make bundle SYMPHONY_BIN=../burrito_out/symphony-macos-arm64 SHORT_VERSION=0.0.1.1 BUILD_NUMBER=1
```

`make bundle` signs ad hoc unless you pass `SIGNING_IDENTITY`, and embeds the update key
when you pass `MINISIGN_PUBLIC_KEY`.

The release workflow smoke-tests the binary before and after signing; run the
same check locally (cwd is `macos/`, after the commands above):

```bash
../scripts/release/smoke_test.sh build/Symphony.app/Contents/Resources/symphony "$PWD/../symphony.yml"
```

The release workflow runs only on pushes to `main`, so pull request CI (`make-all`'s `build`
job) runs the same script on the escript, without the service step only the Burrito binary
needs. Locally, `make smoke` does the same. A pull request that changes how the release is
built or started (`rel/`, `mix.exs`, `mix.lock`, `mise.toml`, the `Makefile`, `config/`'s
`config.exs` and `runtime.exs`, `ReleaseNode` and `ReleaseCookie`, `scripts/release/`, the Zig
SDK shim, the sample `symphony.yml`, or the `release` and `release-smoke` workflows) also runs
the [`release-smoke` workflow](../.github/workflows/release-smoke.yml): it builds the Burrito
binary on `macos-15` as `release` does and runs the whole script on it, service step included.

The script gives each run a fresh `HOME` and creates an empty git repo there at every
`repo: ~/...` path the config names, since `symphony check` rejects a `strategy: worktree`
repo that doesn't exist.
