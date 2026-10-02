#!/bin/sh
# Packages a built Symphony.app into the release assets in OUT_DIR:
#
#   Symphony-<version>.zip          the app, made with `ditto -c -k --keepParent`
#   Symphony-<version>.zip.sha256   `shasum -a 256 -c` checks it from OUT_DIR
#   Symphony-<version>.zip.minisig  only when MINISIGN_SECRET_KEY is set
#   version.json                    what the menu bar app reads to find updates
#   release_notes.md                commit subjects since the previous release
#
# Usage:
#   scripts/release/package.sh --app build/Symphony.app --version 0.0.1.42 \
#     --build 42 --commit <sha> --tag v0.0.1.42 --signed false --out dist
#
# Optional environment:
#   MINISIGN_SECRET_KEY   minisign secret key file contents; never printed
#   MINISIGN_PASSWORD     its password, when the key has one
#   MINISIGN_PUBLIC_KEY   the matching public key, quoted in the release notes
set -eu

usage() {
  echo "usage: $0 --app PATH --version VERSION --build N --commit SHA --tag TAG --signed true|false --out DIR" >&2
  exit 2
}

app="" version="" build="" commit="" tag="" signed="" out=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --app) app="$2" ;;
    --version) version="$2" ;;
    --build) build="$2" ;;
    --commit) commit="$2" ;;
    --tag) tag="$2" ;;
    --signed) signed="$2" ;;
    --out) out="$2" ;;
    *) usage ;;
  esac
  shift 2
done

[ -n "$app" ] && [ -n "$version" ] && [ -n "$build" ] && [ -n "$commit" ] && [ -n "$tag" ] && [ -n "$out" ] || usage
case "$signed" in true | false) ;; *) usage ;; esac
case "$build" in *[!0-9]*) echo "--build must be a number, got $build" >&2; exit 2 ;; esac
[ -d "$app" ] || { echo "app $app does not exist" >&2; exit 1; }
[ -x "$app/Contents/Resources/symphony" ] || { echo "$app has no executable Contents/Resources/symphony" >&2; exit 1; }

mkdir -p "$out"
zip_name="Symphony-$version.zip"
zip="$out/$zip_name"
rm -f "$zip" "$zip.sha256" "$zip.minisig" "$out/version.json" "$out/release_notes.md"

ditto -c -k --keepParent "$app" "$zip"
(cd "$out" && shasum -a 256 "$zip_name" > "$zip_name.sha256")
sha256="$(cut -d ' ' -f 1 < "$zip.sha256")"

minisig_name=""
if [ -n "${MINISIGN_SECRET_KEY:-}" ]; then
  key_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/minisign.XXXXXX")"
  trap 'rm -rf "$key_dir"' EXIT
  (umask 077 && printf '%s\n' "$MINISIGN_SECRET_KEY" > "$key_dir/minisign.key")
  printf '%s\n' "${MINISIGN_PASSWORD:-}" |
    minisign -S -s "$key_dir/minisign.key" -m "$zip" -x "$zip.minisig" \
      -t "Symphony $version build $build commit $commit" > /dev/null
  rm -rf "$key_dir"
  minisig_name="$zip_name.minisig"
fi

# The previous release is the nearest earlier v* tag. The current tag is
# excluded in case it already exists (a pushed v* tag).
previous="$(git describe --tags --abbrev=0 --match 'v*' --exclude "$tag" "$commit" 2> /dev/null || true)"
if [ -n "$previous" ]; then
  range="$previous..$commit"
  since=" since $previous"
else
  range="$commit"
  since=""
fi
changes="$(git rev-list --count --no-merges "$range")"
shown=200

{
  if [ "$changes" -eq 1 ]; then
    echo "1 change$since:"
  else
    echo "$changes changes$since:"
  fi
  echo
  git log --no-merges --format='- %s (%h)' -n "$shown" "$range"
  if [ "$changes" -gt "$shown" ]; then
    echo "- …and $((changes - shown)) more"
  fi
  echo
  echo "## Install"
  echo
  echo "Symphony.app runs on Apple silicon Macs with macOS 13 or later. Install or reinstall it with:"
  echo
  echo '```bash'
  echo "curl -fsSL https://raw.githubusercontent.com/tonypine/symphony/main/scripts/install-macos.sh | bash"
  echo '```'
  echo
  echo "The script downloads the latest release, verifies it, installs Symphony.app to \`~/Applications\` and opens it."
  echo "If Symphony.app is already installed, choose **Update to v$version** from its menu instead."
  echo
  echo "To install by hand, download $zip_name and $zip_name.sha256, verify them as below, then:"
  echo
  echo '```bash'
  echo "mkdir -p ~/Applications"
  echo "ditto -x -k $zip_name ~/Applications"
  echo "xattr -dr com.apple.quarantine ~/Applications/Symphony.app"
  echo "open ~/Applications/Symphony.app"
  echo '```'
  echo
  echo "Symphony.app is not notarized by Apple. If macOS still says it can't be opened, click Open Anyway in"
  echo "System Settings → Privacy & Security."
  echo
  echo "## Verifying"
  echo
  if [ "$signed" = true ]; then
    echo "Symphony.app and its embedded \`symphony\` binary are signed with the Symphony code-signing certificate."
  else
    echo "Symphony.app and its embedded \`symphony\` binary are signed ad hoc: no code-signing certificate is configured yet."
  fi
  echo
  echo '```bash'
  echo "shasum -a 256 -c $zip_name.sha256"
  if [ -n "$minisig_name" ]; then
    echo "minisign -Vm $zip_name -P ${MINISIGN_PUBLIC_KEY:-<Symphony minisign public key>}"
  fi
  echo '```'
  if [ -z "$minisig_name" ]; then
    echo
    echo "No minisign signature: no minisign key is configured yet."
  fi
} > "$out/release_notes.md"

jq -n \
  --arg version "$version" \
  --argjson build "$build" \
  --arg sha256 "$sha256" \
  --arg commit "$commit" \
  --arg published_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --argjson signed "$signed" \
  --arg zip "$zip_name" \
  --arg minisig "$minisig_name" \
  --argjson changes "$changes" \
  '{
    version: $version,
    build: $build,
    sha256: $sha256,
    commit: $commit,
    published_at: $published_at,
    signed: $signed,
    zip: $zip,
    minisig: (if $minisig == "" then null else $minisig end),
    changes: $changes
  }' > "$out/version.json"

echo "Packaged $zip_name ($changes changes$since, signed=$signed, minisig=${minisig_name:-none})"
