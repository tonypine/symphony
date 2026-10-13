#!/bin/sh
# Prints the Developer directory of the Xcode pinned in .xcode-version at the repo
# root, /Applications/Xcode_<version>.app/Contents/Developer, after checking that
# its `xcodebuild -version` reports that version. Every macOS workflow on macos-26
# uses it as DEVELOPER_DIR, so PR CI and the release build with the same Swift.
# Exits non-zero, naming the wanted version and the Xcodes found, when the runner
# lacks it: there is no fallback to another version.
#
# XCODE_VERSION_FILE and XCODE_APPLICATIONS_DIR override the version file and the
# folder searched, for scripts/ci/xcode-developer-dir-test.sh.
set -eu

root="$(cd "$(dirname "$0")/../.." && pwd)"
version_file="${XCODE_VERSION_FILE:-$root/.xcode-version}"
apps="${XCODE_APPLICATIONS_DIR:-/Applications}"

if [ ! -f "$version_file" ]; then
    echo "No Xcode version file at $version_file" >&2
    exit 1
fi
version="$(tr -d '[:space:]' < "$version_file")"
if [ -z "$version" ]; then
    echo "$version_file names no Xcode version" >&2
    exit 1
fi

found="$(ls -d "$apps"/Xcode*.app 2> /dev/null | sed 's|.*/||' | tr '\n' ' ' | sed 's/ $//' || true)"
dir="$apps/Xcode_$version.app/Contents/Developer"
if [ ! -d "$dir" ]; then
    echo "Xcode $version (from $version_file) is not installed: no $apps/Xcode_$version.app. Xcodes found: ${found:-none}" >&2
    exit 1
fi

reported="$(DEVELOPER_DIR="$dir" xcodebuild -version 2> /dev/null | sed -n 's/^Xcode \(.*\)$/\1/p' | head -n 1)"
if [ "$reported" != "$version" ]; then
    echo "$apps/Xcode_$version.app reports Xcode ${reported:-no version}, not $version (from $version_file). Xcodes found: ${found:-none}" >&2
    exit 1
fi

echo "$dir"
