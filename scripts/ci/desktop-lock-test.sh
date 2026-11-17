#!/bin/bash
# Tests scripts/ci/desktop-lock.sh with a lock folder of its own and fake processes in a temp folder
# (DESKTOP_LOCK_CLEANUP_ROOT), so it never waits for the real desktop and never stops a real app.
# Needs cc (Xcode's command line tools) for the fake apps.
#   bash scripts/ci/desktop-lock-test.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
lock="$here/desktop-lock.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/desktop-lock-test.XXXXXX")
tmp=$(cd "$tmp" && pwd -P)
root="$tmp/root"
started=()
finish() {
  for pid in "${started[@]}"; do kill -9 "$pid" 2>/dev/null; done
  pkill -9 -f "^$tmp/" 2>/dev/null
  rm -rf "$tmp"
}
trap finish EXIT
failures=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok [$1]"; else echo "FAIL [$1]: wanted '$2', got '$3'"; failures=$((failures + 1)); fi
}
contains() { # name needle haystack
  case "$3" in *"$2"*) echo "ok [$1]";; *) echo "FAIL [$1]: no '$2' in: $3"; failures=$((failures + 1));; esac
}
now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
seconds_since() { perl -e 'printf "%.1f\n", $ARGV[1] - $ARGV[0]' "$1" "$(now)"; }
within() { perl -e 'exit !($ARGV[0] <= $ARGV[1])' "$1" "$2" && echo yes || echo "no ($1 s)"; }
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo gone; }
held() { # waits until a holder has written its process group into the lock file
  for _ in $(seq 1 100); do grep -q '^pgid=' "$DESKTOP_LOCK_DIR/desktop.lock" 2>/dev/null && return 0; sleep 0.05; done
  echo "FAIL: no holder took the lock"; failures=$((failures + 1))
}
holder_group() { sed -n 's/^pgid=//p' "$DESKTOP_LOCK_DIR/desktop.lock"; }
gone_within() { # pid seconds
  for _ in $(seq 1 $(($2 * 10))); do kill -0 "$1" 2>/dev/null || { echo gone; return; }; sleep 0.1; done
  echo alive
}

export DESKTOP_LOCK_DIR="$tmp/locks" DESKTOP_LOCK_CLEANUP_ROOT="$root" DESKTOP_LOCK_NOTICE_SECONDS=1
export RUNNER_NAME=test-runner GITHUB_WORKFLOW=mac-checks GITHUB_JOB=mac GITHUB_REF=refs/pull/42/merge
export GITHUB_SERVER_URL=https://github.example GITHUB_REPOSITORY=owner/repo GITHUB_RUN_ID=7

# Fake apps: one sleeper, copied under the names the cleanup must and must not stop.
mkdir -p "$root/bin" "$root/runner/_temp/symphony-e2e/run/bin" "$tmp/outside"
printf '#include <stdlib.h>\n#include <unistd.h>\nint main(int c, char **v) { sleep(c > 1 ? atoi(v[1]) : 60); return 0; }\n' > "$tmp/sleeper.c"
cc -o "$root/bin/sleeper" "$tmp/sleeper.c" || { echo "FAIL: cc could not build the fake app"; exit 1; }
for name in SymphonyBar SymphonyBarPackageTests swift-build; do cp "$root/bin/sleeper" "$root/bin/$name"; done
cp "$root/bin/sleeper" "$root/runner/_temp/symphony-e2e/run/bin/beam.smp"
printf 'sleep 60\n' > "$root/runner/_temp/symphony-e2e/run/bin/stub-agent"
cp "$root/bin/sleeper" "$tmp/outside/SymphonyBar"
sleeper="$root/bin/sleeper"

# 1. Alone, it takes the lock at once and passes the command's status on.
t=$(now); bash "$lock" -- true; status=$?
check "alone: exits with the command's status" 0 "$status"
check "alone: takes the lock at once" yes "$(within "$(seconds_since "$t")" 1.5)"
bash "$lock" -- sh -c 'exit 3'
check "a failing command's status is passed on" 3 "$?"
check "the holder's record is cleared on exit" "" "$(cat "$DESKTOP_LOCK_DIR/desktop.lock")"
bash "$lock" -- sh -c 'lsof -p $$ 2>/dev/null' > "$tmp/fds"
check "the command does not get the lock's descriptor" 0 "$(grep -cF "$DESKTOP_LOCK_DIR/desktop.lock" "$tmp/fds")"

# 2. A second holder waits for the first, says who holds it, and runs when the first exits.
bash "$lock" -- sleep 2 & first=$!; started+=("$first"); held
check "the holder itself has the lock's descriptor (so lsof sees it)" 1 "$(lsof -p "$first" 2>/dev/null | grep -cF "$DESKTOP_LOCK_DIR/desktop.lock")"
t=$(now); out=$(bash "$lock" -- true 2>&1); status=$?
check "the second runs once the first is done" 0 "$status"
check "after waiting for it" yes "$(within 1.2 "$(seconds_since "$t")")"
contains "the waiter names the holder" "Waiting for the desktop: held by test-runner (mac-checks, mac, PR #42) running sleep 2 since " "$out"
contains "and its run" "https://github.example/owner/repo/actions/runs/7" "$out"
wait "$first"
printf '  sleep 2\necho done\n' > "$tmp/step.sh"
bash "$lock" -- bash -e "$tmp/step.sh" > /dev/null & first=$!; started+=("$first"); held
contains "a step's script is named by its first line" "running sleep 2 ... since " "$(bash "$lock" -- true 2>&1)"
wait "$first"

# 3. A holder killed with SIGKILL frees the lock at once, and the next holder stops what it left.
bash "$lock" -- "$sleeper" 60 & first=$!; started+=("$first"); disown "$first"; held
orphan=$(holder_group)
out="$tmp/second.out"; (t=$(now); bash "$lock" -- true > "$out" 2>&1; echo "status=$? after=$(seconds_since "$t")" >> "$out") & second=$!
sleep 1; t=$(now); kill -9 "$first"; wait "$second"
check "a waiter runs after the holder is killed" status=0 "$(grep -o 'status=[0-9]*' "$out")"
check "within 2 s of the kill" yes "$(within "$(seconds_since "$t")" 2)"
check "and stops the killed holder's command" gone "$(gone_within "$orphan" 3)"

# 4. The command does not hold the lock: a process it leaves running in a group of its own (as
# `open` does) has no descriptor of it, and the next holder gets the lock at once.
bash "$lock" -- perl -e 'if (!fork) { setpgrp(0, 0); exec @ARGV } ' "$sleeper" 30
stray=$(pgrep -f "^$sleeper 30$" | head -1); started+=("$stray")
check "the stray outlives its step" alive "$(alive "$stray")"
check "without the lock's descriptor" 0 "$(lsof -p "$stray" 2>/dev/null | grep -cF "$DESKTOP_LOCK_DIR/desktop.lock")"
t=$(now); bash "$lock" --wait 0.02 -- true
check "the lock is free while the stray lives" 0 "$?"
check "at once" yes "$(within "$(seconds_since "$t")" 1.5)"
kill "$stray"

# 5. The run limit stops the command's whole group, fails and frees the lock.
t=$(now); out=$(bash "$lock" --limit 0.03 -- sh -c "\"$sleeper\" 61 & sleep 60" 2>&1); status=$?
check "a command past its limit fails" 124 "$status"
check "at the limit" yes "$(within "$(seconds_since "$t")" 8)"
contains "saying so" "ran past its 0.03 min limit" "$out"
check "its background child is stopped too" "" "$(pgrep -f "^$sleeper 61$")"
bash "$lock" --wait 0.02 -- true
check "the lock is free after the limit" 0 "$?"

# 6. The wait limit fails, naming the holder.
bash "$lock" -- sleep 6 & first=$!; started+=("$first"); held
t=$(now); out=$(bash "$lock" --wait 0.03 -- true 2>&1); status=$?
check "a waiter past its wait limit fails" 75 "$status"
check "at the wait limit" yes "$(within "$(seconds_since "$t")" 4)"
contains "naming the holder" "Desktop busy for 0.03 min, held by test-runner (mac-checks, mac, PR #42) running sleep 6" "$out"
kill "$first"; wait "$first" 2>/dev/null

# 7. TERM stops the command and frees the lock.
bash "$lock" -- "$sleeper" 62 & first=$!; started+=("$first"); held
kill -TERM "$first"; wait "$first"
check "TERM exits 143" 143 "$?"
check "and stops the command" "" "$(pgrep -f "^$sleeper 62$")"
bash "$lock" --wait 0.02 -- true
check "the lock is free after TERM" 0 "$?"

# 8. Cleanup on taking the lock: the app and the update test's processes, nothing else.
start() { "$@" > /dev/null 2>&1 & started+=("$!"); echo "$!"; }
app=$(start "$root/bin/SymphonyBar" 60)
beam=$(start "$root/runner/_temp/symphony-e2e/run/bin/beam.smp" 60)
stub=$(start /bin/sh "$root/runner/_temp/symphony-e2e/run/bin/stub-agent")
tests=$(start "$root/bin/SymphonyBarPackageTests" 60)
build=$(start "$root/bin/swift-build" 60)
other=$(start "$root/bin/sleeper" 60)
outside=$(start "$tmp/outside/SymphonyBar" 60)
sleep 0.3
out=$(bash "$lock" -- true 2>&1)
check "cleanup stops a stray SymphonyBar" gone "$(gone_within "$app" 3)"
check "and the update test's beam.smp" gone "$(gone_within "$beam" 3)"
check "and its stub agent script" gone "$(gone_within "$stub" 3)"
check "but not a test bundle named SymphonyBarPackageTests" alive "$(alive "$tests")"
check "nor swift-build" alive "$(alive "$build")"
check "nor any other process" alive "$(alive "$other")"
check "nor anything outside the test's root" alive "$(alive "$outside")"
contains "it says what it stopped" "stopping the desktop apps left running" "$out"

# ...and on exit: an app the command started with `open`-like detachment is stopped with it.
bash "$lock" -- perl -e 'if (!fork) { setpgrp(0, 0); exec @ARGV } sleep 0.3' "$root/bin/SymphonyBar" 63
check "an app the command left running is stopped on exit" "" "$(pgrep -f "^$root/bin/SymphonyBar 63$")"

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "desktop-lock-test: all passed"
