#!/bin/sh
# Prints the Developer directory of the newest Xcode 26 or later in /Applications.
# Used only by release.yml and release-smoke.yml, which still run on macos-15, an
# image without the Xcode pinned in .xcode-version; TP-870 moves them to macos-26
# and onto scripts/ci/xcode-developer-dir.sh, then deletes this script.
set -eu

for app in $(ls -d /Applications/Xcode_*.app /Applications/Xcode-*.app /Applications/Xcode.app 2> /dev/null | sort -r); do
    dir="$app/Contents/Developer"
    major="$(DEVELOPER_DIR="$dir" xcodebuild -version 2> /dev/null | sed -n 's/^Xcode \([0-9][0-9]*\).*/\1/p')"
    if [ -n "$major" ] && [ "$major" -ge 26 ]; then
        echo "$dir"
        exit 0
    fi
done

echo "No Xcode 26 or later in /Applications" >&2
exit 1
