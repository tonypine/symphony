#!/bin/sh
# Tests scripts/ci/xcode-developer-dir.sh against a fake /Applications holding
# Xcode_26.6.app with a stub xcodebuild. Run: sh scripts/ci/xcode-developer-dir-test.sh
set -eu

script="$(cd "$(dirname "$0")" && pwd)/xcode-developer-dir.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/xcode-developer-dir.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

bin="$tmp/Xcode_26.6.app/Contents/Developer/usr/bin"
mkdir -p "$bin" "$tmp/bin"
printf '#!/bin/sh\nprintf "Xcode 26.6\\nBuild version 17F113\\n"\n' > "$tmp/bin/xcodebuild"
chmod +x "$tmp/bin/xcodebuild"
export PATH="$tmp/bin:$PATH" XCODE_APPLICATIONS_DIR="$tmp" XCODE_VERSION_FILE="$tmp/.xcode-version"
failed=0

echo 26.6 > "$tmp/.xcode-version"
out="$(sh "$script")"
if [ "$out" != "$tmp/Xcode_26.6.app/Contents/Developer" ]; then
    echo "FAIL installed version: got '$out'"; failed=1
fi

echo 99.1 > "$tmp/.xcode-version"
if err="$(sh "$script" 2>&1)"; then
    echo "FAIL missing version exited 0"; failed=1
fi
case "$err" in
    *"Xcode 99.1"*"Xcode_26.6.app"*) ;;
    *) echo "FAIL missing version message: $err"; failed=1 ;;
esac

mkdir -p "$tmp/Xcode_26.5.app/Contents/Developer"
echo 26.5 > "$tmp/.xcode-version"
if err="$(sh "$script" 2>&1)"; then
    echo "FAIL mismatched xcodebuild -version exited 0"; failed=1
fi
case "$err" in
    *"reports Xcode 26.6, not 26.5"*) ;;
    *) echo "FAIL mismatch message: $err"; failed=1 ;;
esac

[ "$failed" -eq 0 ] && echo "ok"
exit "$failed"
