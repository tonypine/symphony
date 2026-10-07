#!/bin/sh
# Prints the Developer directory of an Xcode 26 or later in /Applications, the
# newest name first. The Mac app targets macOS 26 (decision DD3 in
# docs/design/director-app-screens.md), so it builds only with the macOS 26 SDK,
# while the Burrito build stays on the macOS 15 SDK where a runner defaults to it.
# Use it as DEVELOPER_DIR for the Swift build only.
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
