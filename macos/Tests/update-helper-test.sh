#!/bin/sh
# Tests Resources/update-helper.sh with fake app bundles in a temp folder: the
# swap, the wait for the quitting app, and putting the old app back on failure.
#
# Usage (from macos/): sh Tests/update-helper-test.sh
set -u

helper="$(cd "$(dirname "$0")/.." && pwd)/Resources/update-helper.sh"
root="$(mktemp -d "${TMPDIR:-/tmp}/update-helper-test.XXXXXX")"
trap 'chmod -R u+w "$root"; rm -rf "$root"' EXIT
failures=0

fail() {
  echo "FAIL [$name]: $*"
  failures=$((failures + 1))
}

# A fake bundle: the folder with a version marker inside.
make_app() {
  mkdir -p "$1/Contents"
  echo "$2" > "$1/Contents/version"
}

version_of() {
  cat "$1/Contents/version" 2> /dev/null || echo missing
}

# Each case gets a fresh folder, a fake `open` that records what it opened,
# and a pid that has already exited.
setup() {
  name="$1"
  dir="$root/$name"
  mkdir -p "$dir/Applications" "$dir/cache"
  current="$dir/Applications/Symphony.app"
  previous="$dir/Applications/Symphony (previous).app"
  new="$dir/cache/Symphony.app"
  opened="$dir/opened"
  printf '#!/bin/sh\necho "$1" >> "%s"\n' "$opened" > "$dir/open"
  chmod +x "$dir/open"
  sh -c 'exit 0' &
  pid=$!
  wait "$pid"
}

run_helper() {
  SYMPHONY_UPDATE_OPEN="$dir/open" SYMPHONY_UPDATE_WAIT_SECONDS="${wait_seconds:-10}" \
    sh "$helper" "$pid" "$current" "$new" "$previous" > "$dir/log" 2>&1
  status=$?
}

expect() {
  [ "$(version_of "$1")" = "$2" ] || fail "expected $2 at $1, found $(version_of "$1")"
}

expect_opened() {
  [ "$(cat "$opened" 2> /dev/null)" = "$1" ] || fail "expected the helper to open '$1', it opened '$(cat "$opened" 2> /dev/null)'"
}

expect_status() {
  [ "$status" -eq "$1" ] || fail "expected exit $1, got $status: $(cat "$dir/log")"
}

# Success: the new app is installed, the old one becomes the previous one
# (replacing an older previous copy), and the new app is relaunched.
setup success
make_app "$current" 1
make_app "$new" 2
make_app "$previous" 0
run_helper
expect_status 0
expect "$current" 2
expect "$previous" 1
[ ! -e "$new" ] || fail "the new app is still in the cache"
[ -z "$(ls "$dir/Applications" | grep replaced)" ] || fail "the older previous copy was left behind"
expect_opened "$current"

# Success without an older previous copy.
setup first-update
make_app "$current" 1
make_app "$new" 2
run_helper
expect_status 0
expect "$current" 2
expect "$previous" 1
expect_opened "$current"

# Waits for the quitting app before moving anything.
setup waits-for-pid
make_app "$current" 1
make_app "$new" 2
sleep 2 &
pid=$!
run_helper
expect_status 0
kill -0 "$pid" 2> /dev/null && fail "the helper returned while pid $pid still ran"
expect "$current" 2
expect "$previous" 1

# Gives up, changing nothing, when the app doesn't quit.
setup app-keeps-running
make_app "$current" 1
make_app "$new" 2
sleep 30 &
pid=$!
wait_seconds=1 run_helper
{ kill "$pid" && wait "$pid"; } 2> /dev/null
expect_status 1
expect "$current" 1
expect "$new" 2
[ ! -e "$previous" ] || fail "the previous app was created"
[ ! -e "$opened" ] || fail "the helper relaunched an app that was still running"

# Rollback: the new app can't be moved (its folder is read-only), so the old
# app and the older previous copy are put back, and the old app is relaunched.
setup rollback
make_app "$current" 1
make_app "$new" 2
make_app "$previous" 0
chmod a-w "$dir/cache"
run_helper
chmod u+w "$dir/cache"
expect_status 1
expect "$current" 1
expect "$previous" 0
expect "$new" 2
[ -z "$(ls "$dir/Applications" | grep replaced)" ] || fail "the older previous copy wasn't restored"
expect_opened "$current"

# A missing new app changes nothing; the old app is relaunched.
setup missing-new-app
make_app "$current" 1
run_helper
expect_status 1
expect "$current" 1
[ ! -e "$previous" ] || fail "the previous app was created"
expect_opened "$current"

# QA mode: the helper runs the new app's binary itself, with the QA
# environment, instead of `open`, which would drop it.
setup qa-mode
make_app "$current" 1
make_app "$new" 2
mkdir -p "$new/Contents/MacOS"
printf '#!/bin/sh\necho "$SYMPHONY_BAR_QA_ROOT" > "%s"\n' "$dir/qa-launched" > "$new/Contents/MacOS/SymphonyBar"
chmod +x "$new/Contents/MacOS/SymphonyBar"
SYMPHONY_BAR_QA_ROOT="$dir/qa" SYMPHONY_UPDATE_WAIT_SECONDS=10 \
  sh "$helper" "$pid" "$current" "$new" "$previous" > "$dir/log" 2>&1
status=$?
expect_status 0
expect "$current" 2
waited=0
while [ ! -s "$dir/qa-launched" ] && [ "$waited" -lt 50 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
[ "$(cat "$dir/qa-launched" 2> /dev/null)" = "$dir/qa" ] || fail "the new app wasn't started with the QA root: $(cat "$dir/log")"
[ ! -e "$opened" ] || fail "the helper used open in QA mode"

if [ "$failures" -gt 0 ]; then
  echo "$failures update helper check(s) failed"
  exit 1
fi
echo "update helper: all checks passed"
