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

A pushed `v*` tag is released under its own name with the same versions.
Compare `build` to tell which release is newer. Bump `version:` in `mix.exs`
for a new major, minor or patch version.

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

The app is not notarized by Apple, so Gatekeeper warns on first launch of a
downloaded copy. The release notes tell users to clear the quarantine flag with
`xattr -dr com.apple.quarantine Symphony.app`.

## Verify a release

```bash
shasum -a 256 -c Symphony-<version>.zip.sha256
minisign -Vm Symphony-<version>.zip -P <Symphony minisign public key>   # when published
ditto -x -k Symphony-<version>.zip .
codesign --verify --strict Symphony.app
codesign --verify --strict Symphony.app/Contents/Resources/symphony
codesign -dvv Symphony.app    # Authority=… once the certificate is configured
./Symphony.app/Contents/Resources/symphony check
```

## Build the app locally

```bash
BURRITO_TARGET=macos_arm64 make package     # writes burrito_out/symphony-macos-arm64
cd macos
make bundle SYMPHONY_BIN=../burrito_out/symphony-macos-arm64 SHORT_VERSION=0.0.1.0 BUILD_NUMBER=0
```

`make bundle` signs ad hoc unless you pass `SIGNING_IDENTITY`.
