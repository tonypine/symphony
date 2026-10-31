#!/bin/sh
# Tests Resources/update-helper.sh with fake app bundles in a temp folder: the
# swap, the wait for the quitting app, putting the old app back on failure, and
# the reversed swap a rollback runs.
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

# Rollback after a failed health check: the same swap with the previous app as
# the new one. The failed build moves to "Symphony (rolled back).app", replacing
# an older copy there, and the previous app is back in place and relaunched.
setup rollback-swap
rolled_back="$dir/Applications/Symphony (rolled back).app"
make_app "$current" 2
make_app "$previous" 1
make_app "$rolled_back" 0
SYMPHONY_UPDATE_OPEN="$dir/open" SYMPHONY_UPDATE_WAIT_SECONDS=10 \
  sh "$helper" "$pid" "$current" "$previous" "$rolled_back" > "$dir/log" 2>&1
status=$?
expect_status 0
expect "$current" 1
expect "$rolled_back" 2
[ ! -e "$previous" ] || fail "the failed build was left in the previous app's place"
[ -z "$(ls "$dir/Applications" | grep replaced)" ] || fail "the older rolled-back copy was left behind"
expect_opened "$current"

# A rollback without a previous app changes nothing and relaunches the app,
# which then says it couldn't roll back.
setup rollback-without-previous
rolled_back="$dir/Applications/Symphony (rolled back).app"
make_app "$current" 2
SYMPHONY_UPDATE_OPEN="$dir/open" SYMPHONY_UPDATE_WAIT_SECONDS=10 \
  sh "$helper" "$pid" "$current" "$previous" "$rolled_back" > "$dir/log" 2>&1
status=$?
expect_status 1
expect "$current" 2
[ ! -e "$rolled_back" ] || fail "the rolled-back app was created"
expect_opened "$current"

# A rollback whose previous app can't move into place (its folder is
# read-only here) puts the failed build back and relaunches it.
setup rollback-swap-fails
rolled_back="$dir/Applications/Symphony (rolled back).app"
mkdir -p "$dir/kept"
previous="$dir/kept/Symphony (previous).app"
make_app "$current" 2
make_app "$previous" 1
chmod a-w "$dir/kept"
SYMPHONY_UPDATE_OPEN="$dir/open" SYMPHONY_UPDATE_WAIT_SECONDS=10 \
  sh "$helper" "$pid" "$current" "$previous" "$rolled_back" > "$dir/log" 2>&1
status=$?
chmod u+w "$dir/kept"
expect_status 1
expect "$current" 2
expect "$previous" 1
[ ! -e "$rolled_back" ] || fail "the failed build was left at $rolled_back"
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

# QA mode with a relaunch command, as the QA driver sets for a release pair: the
# helper runs that command, whose path may hold spaces, instead of the app.
setup qa-mode-relaunch-command
make_app "$current" 1
make_app "$new" 2
mkdir -p "$dir/QA driver/bin"
printf '#!/bin/sh\necho "$SYMPHONY_BAR_QA_ROOT $1" >> "%s"\n' "$opened" > "$dir/QA driver/bin/relaunch"
chmod +x "$dir/QA driver/bin/relaunch"
SYMPHONY_BAR_QA_ROOT="$dir/qa" SYMPHONY_UPDATE_OPEN="$dir/QA driver/bin/relaunch" SYMPHONY_UPDATE_WAIT_SECONDS=10 \
  sh "$helper" "$pid" "$current" "$new" "$previous" > "$dir/log" 2>&1
status=$?
expect_status 0
expect "$current" 2
expect_opened "$dir/qa $current"

# An update whose new app starts: it writes STATE_DIR/launched, as every launch
# of the app does, and the helper leaves it in place.
setup launch-watched
make_app "$current" 1
make_app "$new" 2
make_app "$previous" 0
state="$dir/cache"
rolled_back="$dir/Applications/Symphony (rolled back).app"
touch "$state/launched" "$state/launch-failed"
printf '#!/bin/sh\necho "$1" >> "%s"\ntouch "%s/launched"\n' "$opened" "$state" > "$dir/open"
SYMPHONY_UPDATE_OPEN="$dir/open" SYMPHONY_UPDATE_WAIT_SECONDS=10 SYMPHONY_UPDATE_LAUNCH_SECONDS=5 \
  sh "$helper" "$pid" "$current" "$new" "$previous" "$state" "$rolled_back" > "$dir/log" 2>&1
status=$?
expect_status 0
expect "$current" 2
expect "$previous" 1
[ ! -e "$rolled_back" ] || fail "a new app that started was rolled back"
[ ! -e "$state/launch-failed" ] || fail "an earlier launch-failed was left for the app"
expect_opened "$current"
grep -q '\[helper\] .*started after' "$dir/log" || fail "the log doesn't say the new app started: $(cat "$dir/log")"

# An update whose new app doesn't start (its binary isn't executable, so the
# launch fails, and a launched file from the old app's own launch is no
# proof): the helper puts the previous app back, says why in launch-failed,
# and relaunches the previous app, which starts.
setup launch-fails
make_app "$current" 1
make_app "$new" 2
make_app "$previous" 0
state="$dir/cache"
rolled_back="$dir/Applications/Symphony (rolled back).app"
make_app "$rolled_back" -1
touch "$state/launched"
printf '#!/bin/sh\necho "$1" >> "%s"\n[ "$(cat "$1/Contents/version")" = 1 ] && touch "%s/launched"\nexit 0\n' \
  "$opened" "$state" > "$dir/open"
started=$(date +%s)
SYMPHONY_UPDATE_OPEN="$dir/open" SYMPHONY_UPDATE_WAIT_SECONDS=10 SYMPHONY_UPDATE_LAUNCH_SECONDS=2 \
  sh "$helper" "$pid" "$current" "$new" "$previous" "$state" "$rolled_back" > "$dir/log" 2>&1
status=$?
expect_status 1
expect "$current" 1
expect "$rolled_back" 2
[ ! -e "$previous" ] || fail "the previous slot isn't empty after the rollback"
[ "$(cat "$state/launch-failed" 2> /dev/null)" = 2 ] || fail "launch-failed doesn't name the bound: $(cat "$dir/log")"
[ "$(cat "$opened")" = "$current
$current" ] || fail "expected the new app, then the restored one, to be opened: $(cat "$opened")"
[ $(($(date +%s) - started)) -lt 10 ] || fail "the rollback took longer than the bound allows"
grep -q "didn't start within 2s; putting" "$dir/log" || fail "the log doesn't name the launch that failed: $(cat "$dir/log")"
grep -q "started after" "$dir/log" || fail "the log doesn't say the restored app started: $(cat "$dir/log")"

# A new app that hangs on launch is stopped before it is moved aside.
setup launch-hangs
make_app "$current" 1
make_app "$new" 2
make_app "$previous" 0
mkdir -p "$new/Contents/MacOS"
printf '#!/bin/sh\nsleep 60\n' > "$new/Contents/MacOS/SymphonyBar"
chmod +x "$new/Contents/MacOS/SymphonyBar"
state="$dir/cache"
rolled_back="$dir/Applications/Symphony (rolled back).app"
printf '#!/bin/sh\n"$1/Contents/MacOS/SymphonyBar" > /dev/null 2>&1 &\necho $! > "%s"\n' "$dir/hung" > "$dir/open"
SYMPHONY_UPDATE_OPEN="$dir/open" SYMPHONY_UPDATE_WAIT_SECONDS=10 SYMPHONY_UPDATE_LAUNCH_SECONDS=1 \
  sh "$helper" "$pid" "$current" "$new" "$previous" "$state" "$rolled_back" > "$dir/log" 2>&1
status=$?
expect_status 1
expect "$current" 1
expect "$rolled_back" 2
hung="$(head -1 "$dir/hung")"
kill -0 "$hung" 2> /dev/null && { fail "the hung new app (pid $hung) is still running"; kill -9 "$hung"; }
grep -q "the restored .* didn't start within 1s either" "$dir/log" || fail "the log doesn't say the restored app didn't start: $(cat "$dir/log")"

# A new app that doesn't start, with nothing to put back, is relaunched again.
setup launch-fails-without-previous
make_app "$current" 1
make_app "$new" 2
state="$dir/cache"
rolled_back="$dir/Applications/Symphony (rolled back).app"
SYMPHONY_UPDATE_OPEN="$dir/open" SYMPHONY_UPDATE_WAIT_SECONDS=10 SYMPHONY_UPDATE_LAUNCH_SECONDS=1 \
  sh "$helper" "$pid" "$current" "$new" "$previous" "$state" "$rolled_back" > "$dir/log" 2>&1 &
helper_pid=$!
# Takes the previous app away while the helper waits for the new one to start.
waited=0
while [ ! -e "$opened" ] && [ "$waited" -lt 50 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
rm -rf "$previous"
wait "$helper_pid"
status=$?
expect_status 1
expect "$current" 2
[ ! -e "$rolled_back" ] || fail "the new app was moved aside with nothing to put back"
[ "$(wc -l < "$opened" | tr -d ' ')" = 2 ] || fail "expected the new app to be opened twice: $(cat "$opened")"

if [ "$failures" -gt 0 ]; then
  echo "$failures update helper check(s) failed"
  exit 1
fi
echo "update helper: all checks passed"
