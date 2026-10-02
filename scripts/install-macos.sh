#!/usr/bin/env bash
# Installs the latest Symphony.app release from GitHub:
#
#   curl -fsSL https://raw.githubusercontent.com/tonypine/symphony/main/scripts/install-macos.sh | bash
#
# It downloads the release zip, verifies its SHA-256 and, when `minisign` is
# installed, its minisign signature, unzips it, checks the app's code signature,
# moves it to INSTALL_DIR, clears the quarantine flag and opens it. An installed older version is kept as `Symphony (previous).app`.
# Running it again when the release is already installed changes nothing.
#
# Optional environment:
#   INSTALL_DIR                   where Symphony.app goes (default ~/Applications)
#   SYMPHONY_RELEASE_TAG          release to install, e.g. v0.0.1.81 (default the latest)
#   SYMPHONY_MINISIGN_PUBLIC_KEY  minisign public key to verify with (default the
#                                 Symphony release key below)
#   SYMPHONY_NO_OPEN=1            don't open the app at the end
set -euo pipefail

repo="tonypine/symphony"
# The Symphony release key: the repository's MINISIGN_PUBLIC_KEY variable, which
# release builds also embed in the app to verify updates.
release_public_key="RWThT600NSBP4TROh1cvUt5N37/c3BctbnE3Qe+VO0A81t6IikB2BPMp"
install_dir="${INSTALL_DIR:-$HOME/Applications}"
app="$install_dir/Symphony.app"
previous="$install_dir/Symphony (previous).app"

step() {
  printf '==> %s\n' "$*"
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

[ "$(uname -s)" = Darwin ] || fail "Symphony.app runs on macOS only."
[ "$(uname -m)" = arm64 ] || fail "Symphony.app is built for Apple silicon (arm64) only."

work="$(mktemp -d "${TMPDIR:-/tmp}/symphony-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT

tag="${SYMPHONY_RELEASE_TAG:-}"
if [ -z "$tag" ]; then
  step "Finding the latest release"
  latest_url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")"
  tag="${latest_url##*/tag/}"
  if [ -z "$tag" ] || [ "$tag" = "$latest_url" ]; then
    fail "couldn't find the latest release at $latest_url"
  fi
fi
base="https://github.com/$repo/releases/download/$tag"

step "Downloading version.json for $tag"
curl -fsSL -o "$work/version.json" "$base/version.json"
zip_name="$(plutil -extract zip raw -o - "$work/version.json")"
build="$(plutil -extract build raw -o - "$work/version.json")"
version="$(plutil -extract version raw -o - "$work/version.json")"
minisig_name="$(plutil -extract minisig raw -o - "$work/version.json" 2> /dev/null || true)"

if [ -d "$app" ]; then
  installed_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist" 2> /dev/null || true)"
  if [ "$installed_build" = "$build" ]; then
    step "Symphony $version (build $build) is already installed at $app"
    if [ "${SYMPHONY_NO_OPEN:-}" != 1 ]; then
      step "Opening $app"
      open "$app"
    fi
    exit 0
  fi
  if pgrep -f "$app/Contents/MacOS/" > /dev/null 2>&1; then
    fail "Symphony is running from $app. Choose Quit from its menu, then run this again."
  fi
fi

step "Downloading $zip_name"
curl -fSL --progress-bar -o "$work/$zip_name" "$base/$zip_name"
curl -fsSL -o "$work/$zip_name.sha256" "$base/$zip_name.sha256"

step "Verifying the SHA-256 checksum"
(cd "$work" && shasum -a 256 -c "$zip_name.sha256") || fail "$zip_name doesn't match its published SHA-256; nothing was installed."

public_key="${SYMPHONY_MINISIGN_PUBLIC_KEY:-$release_public_key}"
if [ -z "$minisig_name" ] || [ "$minisig_name" = null ]; then
  step "Skipping the minisign signature: release $tag doesn't publish one. Verified by SHA-256 only."
elif ! command -v minisign > /dev/null; then
  step "Skipping the minisign signature: minisign isn't installed (brew install minisign). Verified by SHA-256 only."
else
  step "Verifying the minisign signature"
  curl -fsSL -o "$work/$minisig_name" "$base/$minisig_name"
  minisign -Vm "$work/$zip_name" -x "$work/$minisig_name" -P "$public_key" ||
    fail "$zip_name doesn't match its minisign signature; nothing was installed."
fi

step "Unzipping Symphony.app"
mkdir "$work/unzipped"
ditto -x -k "$work/$zip_name" "$work/unzipped"
[ -d "$work/unzipped/Symphony.app" ] || fail "$zip_name has no Symphony.app."

step "Checking the app's code signature"
# A release signed with the Symphony certificate fails with CSSMERR_TP_NOT_TRUSTED
# on a Mac that doesn't trust that certificate. codesign stops at the trust check,
# so the SHA-256 (and minisign) checks above are what vouch for the download then.
if ! codesign_output="$(codesign --verify --strict "$work/unzipped/Symphony.app" 2>&1)"; then
  case "$codesign_output" in
    *CSSMERR_TP_NOT_TRUSTED*)
      step "The app is signed with the Symphony certificate, which this Mac doesn't trust; relying on the checks above."
      ;;
    *)
      printf '%s\n' "$codesign_output" >&2
      fail "Symphony.app's code signature is invalid; nothing was installed."
      ;;
  esac
fi
case "$(codesign -dv "$work/unzipped/Symphony.app" 2>&1)" in
  *"Identifier=com.tonypine.symphony.bar"*) ;;
  *) fail "the downloaded app isn't Symphony (com.tonypine.symphony.bar); nothing was installed." ;;
esac

step "Installing to $app"
mkdir -p "$install_dir"
if [ -d "$app" ]; then
  rm -rf "$previous"
  mv "$app" "$previous"
  step "Kept the version you had as $previous"
fi
mv "$work/unzipped/Symphony.app" "$app"

step "Clearing the quarantine flag"
xattr -dr com.apple.quarantine "$app"

if [ "${SYMPHONY_NO_OPEN:-}" = 1 ]; then
  step "Installed Symphony $version (build $build). Open it with: open \"$app\""
else
  step "Opening $app"
  open "$app"
  step "Installed Symphony $version (build $build). Look for its icon in the menu bar."
fi
