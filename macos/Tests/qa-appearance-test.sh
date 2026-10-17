#!/bin/sh
# Tests the QA appearance library (priv/qa_driver/symphony-qa-appearance.m) the
# way `qa_launch_app` uses it: built with priv/qa_driver/build-appearance.sh and
# injected with DYLD_INSERT_LIBRARIES into an ordinary AppKit program that knows
# nothing of Symphony. The program finishes launching and prints its effective
# appearance and whether DYLD_INSERT_LIBRARIES is still in its environment.
#
# It starts an NSApplication, so it runs in CI only, never in an agent's sandbox.
#
# Usage (from macos/): sh Tests/qa-appearance-test.sh
set -u

priv="$(cd "$(dirname "$0")/../../priv/qa_driver" && pwd)"
root="$(mktemp -d "${TMPDIR:-/tmp}/qa-appearance-test.XXXXXX")"
trap 'rm -rf "$root"' EXIT
failures=0

fail() {
  echo "FAIL [$name]: $*"
  failures=$((failures + 1))
}

sh "$priv/build-appearance.sh" "$priv/symphony-qa-appearance.m" "$root/symphony-qa-appearance.dylib" || exit 1

cat > "$root/probe.swift" << 'EOF'
import AppKit

let app = NSApplication.shared
app.finishLaunching()
print("appearance=\(app.effectiveAppearance.name.rawValue)")
print("inserted=\(getenv("DYLD_INSERT_LIBRARIES").map { String(cString: $0) } ?? "unset")")
EOF
swiftc -module-cache-path "$root/module-cache" -o "$root/probe" "$root/probe.swift" || exit 1

# Runs the probe with the library and SYMPHONY_BAR_QA_APPEARANCE=$1.
probe() {
  env DYLD_INSERT_LIBRARIES="$root/symphony-qa-appearance.dylib" SYMPHONY_BAR_QA_APPEARANCE="$1" "$root/probe" 2>&1
}

expect() {
  case "$output" in
    *"$1"*) ;;
    *) fail "expected '$1' in: $output" ;;
  esac
}

name="dark"
output=$(probe dark)
expect "appearance=NSAppearanceNameDarkAqua"
expect "symphony-qa-appearance: dark"
expect "inserted=unset"

name="light"
output=$(probe light)
expect "appearance=NSAppearanceNameAqua"
expect "symphony-qa-appearance: light"
expect "inserted=unset"

name="no appearance"
output=$(probe "")
expect "inserted=unset"
case "$output" in
  *symphony-qa-appearance:*) fail "set an appearance without one asked for: $output" ;;
esac

if [ "$failures" -gt 0 ]; then
  echo "$failures failure(s)"
  exit 1
fi
echo "qa appearance: all cases passed"
