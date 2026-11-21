#!/bin/bash
# Tests scripts/ci/build-store.sh and scripts/ci/mac-check-groups.sh on made-up inputs: no build.
#   bash scripts/ci/build-store-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/build-store-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
failures=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok [$1]"; return; fi
  echo "FAIL [$1]: wanted '$2', got '$3'"; failures=$((failures + 1))
  # An annotation, so the failing check is read from the run's summary, not from its whole log.
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::error::build store test: $1: wanted '$2', got '$3'"; fi
}
# Gives <path> the time of <seconds> ago. The prune checks set every time they compare: their
# order never rests on the clock moving on between two steps (a sleep, a touch a moment later),
# which a busy or resynced VM clock does not promise.
age() { touch -t "$(date -r $(( $(date +%s) - $2 )) +%Y%m%d%H%M.%S)" "$1"; }

# A made-up repository with the script in it, so keys read its HEAD.
repo="$tmp/repo"
mkdir -p "$repo/scripts/ci" "$repo/macos/Sources/App" "$repo/macos/Tests" "$repo/lib" "$repo/docs"
cp "$here/build-store.sh" "$repo/scripts/ci/"
echo "let a = 1" > "$repo/macos/Sources/App/a.swift"; echo "// test" > "$repo/macos/Tests/t.swift"
echo "26.6" > "$repo/.xcode-version"; echo "defmodule A do end" > "$repo/lib/a.ex"; echo "doc" > "$repo/docs/x.md"
git -C "$repo" init -q; git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m one
store="bash $repo/scripts/ci/build-store.sh"
commit() { git -C "$repo" add -A; git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m "$1"; }

export SYMPHONY_CI_CACHE="$tmp/cache"
# The runner sets its own work area (SYMPHONY_CI_WORK); the test makes its own.
unset RUNNER_NAME SYMPHONY_CI_WORK SYMPHONY_CI_IN_USE_MINUTES
app1=$($store key app); server1=$($store key server 7)
echo "more" >> "$repo/docs/x.md"; echo "// more" >> "$repo/macos/Tests/t.swift"; commit docs
check "a change outside a piece's inputs keeps its key" "$app1 $server1" "$($store key app) $($store key server 7)"
echo "let b = 2" >> "$repo/macos/Sources/App/a.swift"; commit app
app2=$($store key app)
check "a change to the app's sources changes the app's key" changed "$([ "$app1" != "$app2" ] && echo changed || echo same)"
check "and leaves the release's key" "$server1" "$($store key server 7)"
check "another build number is another release" changed "$([ "$server1" != "$($store key server 8)" ] && echo changed || echo same)"
echo "x" >> "$repo/lib/a.ex"
check "uncommitted changes to an input give no key" refused "$($store key server 7 2>/dev/null || echo refused)"
check "but leave the other piece's key" "$app2" "$($store key app)"
git -C "$repo" checkout -q -- lib

# The store: a miss, a hit, clean against incremental.
echo one > "$tmp/piece"
check "an empty store misses" miss "$($store get app k1 "$tmp/out" 2>/dev/null && echo hit || echo miss)"
$store put app k1 "$tmp/piece" incremental 2>/dev/null
check "a filed piece is found" one "$($store get app k1 "$tmp/out" 2>/dev/null && cat "$tmp/out")"
check "an incremental piece is not a clean one" miss "$($store get app k1 "$tmp/out" --clean 2>/dev/null && echo hit || echo miss)"
echo two > "$tmp/piece"; $store put app k1 "$tmp/piece" clean 2>/dev/null
check "a clean build replaces it" two "$($store get app k1 "$tmp/out" --clean 2>/dev/null && cat "$tmp/out")"
echo three > "$tmp/piece"; $store put app k1 "$tmp/piece" incremental 2>/dev/null
check "and an incremental one never replaces a clean one" two "$($store get app k1 "$tmp/out" 2>/dev/null && cat "$tmp/out")"
mkdir "$tmp/dir"; echo in > "$tmp/dir/f"; $store put server k2 "$tmp/dir" incremental 2>/dev/null
check "a folder is a piece too" in "$($store get server k2 "$tmp/outdir" 2>/dev/null && cat "$tmp/outdir/f")"

# Working folders: one active place, each branch's state beside it.
main=$($store work main release --fresh 2>/dev/null); echo main-state > "$main/state"; $store save main release 2>/dev/null
a=$($store work pr-a release 2>/dev/null)
check "every branch builds in the same folder" "$main" "$a"
check "a new branch starts from main's state" main-state "$(cat "$a/state")"
echo a-state > "$a/state"; $store save pr-a release 2>/dev/null
b=$($store work feature/b release 2>/dev/null); echo b-state > "$b/state"; $store save feature/b release 2>/dev/null
check "a branch gets its own state back" a-state "$(cat "$($store work pr-a release 2>/dev/null)/state")"
check "main's is untouched" main-state "$(cat "$($store work main release 2>/dev/null)/state")"
check "--fresh empties it" "" "$(ls "$($store work main release --fresh 2>/dev/null)")"
# A saved state's object of a source the branch deleted is dropped; one with a source stays.
orph="$($store work main release --fresh 2>/dev/null)/x/App.build"; mkdir -p "$orph"
touch "$orph/a.swift.o" "$orph/gone.swift.o" "$orph/gone.swift.d"
$store work main release >/dev/null 2>&1
check "an object whose source was deleted is dropped" "a.swift.o" "$(ls "$orph" | tr '\n' ' ' | sed 's/ $//')"
$store work main release --fresh >/dev/null 2>&1
$store save pr-a release 2>/dev/null
check "a save for another branch than the active one saves nothing" a-state "$(cat "$($store work pr-a release 2>/dev/null)/state")"
check "a save leaves no copy half-way" "" "$(find "$SYMPHONY_CI_CACHE"/work/*/refs/pr-a -mindepth 1 -maxdepth 1 ! -name release)"

# --fresh-once: from nothing once per job and commit; that job's later builds take the clean state.
once() { GITHUB_RUN_ID="$1" GITHUB_RUN_ATTEMPT=1 GITHUB_JOB="$2" $store work main mix --fresh-once 2>/dev/null; }
echo stale > "$(once 1 app)/state"
check "--fresh-once empties it the first time in a job" "" "$(ls "$(once 2 app)")"
echo built > "$(once 2 app)/state"
check "and keeps it for the same job's next build" built "$(cat "$(once 2 app)/state")"
check "another job starts from nothing" "" "$(ls "$(once 2 release)")"
echo built > "$(once 3 app)/state"
check "and so does another run" "" "$(ls "$(once 4 app)")"
echo built > "$(once 5 app)/state"; echo "x" >> "$repo/docs/x.md"; commit five
check "and the same job at another commit" "" "$(ls "$(once 5 app)")"
echo built > "$(once 6 app)/state"; $store work pr-a mix >/dev/null 2>&1; $store work main mix >/dev/null 2>&1
check "a state another branch's job put in the folder is never taken for the job's" "" "$(ls "$(once 6 app)")"
echo built > "$(GITHUB_RUN_ID="" $store work main mix --fresh-once 2>/dev/null)/state"
check "outside a GitHub job it is --fresh" "" "$(ls "$(GITHUB_RUN_ID="" $store work main mix --fresh-once 2>/dev/null)")"

# Two runners on one VM: each has a work area of its own (SYMPHONY_CI_WORK), and the default is today's.
check "the default work area is the cache's work folder" "$SYMPHONY_CI_CACHE/work" "$(dirname "$(dirname "$(dirname "$a")")")"
two=$(SYMPHONY_CI_WORK="$tmp/work-2" $store work pr-a release 2>/dev/null)
check "another runner builds in its own work area" "$tmp/work-2" "$(dirname "$(dirname "$(dirname "$two")")")"
check "from nothing: saved states hold absolute paths, so they are not shared" "" "$(ls "$two")"
echo two-state > "$two/state"; SYMPHONY_CI_WORK="$tmp/work-2" $store save pr-a release 2>/dev/null
check "its save stays in its own area" a-state "$(cat "$($store work pr-a release 2>/dev/null)/state")"
check "and is its own next time" two-state "$(cat "$(SYMPHONY_CI_WORK="$tmp/work-2" $store work pr-a release 2>/dev/null)/state")"
SYMPHONY_CI_WORK="$tmp/work-2" $store save pr-a release 2>/dev/null
check "a save puts the state it replaced aside" yes "$([ -n "$(ls -A "$tmp"/work-2/*/old)" ] && echo yes || echo no)"

# Content-made times: the same content has the same time after git rewrote the file.
$store stamp; before=$(stat -f %m "$repo/macos/Sources/App/a.swift")
cp "$repo/macos/Sources/App/a.swift" "$tmp/copy"; rm "$repo/macos/Sources/App/a.swift"; sleep 1; cp "$tmp/copy" "$repo/macos/Sources/App/a.swift"
$store stamp
check "a rewritten file with the same content keeps its time" "$before" "$(stat -f %m "$repo/macos/Sources/App/a.swift")"
echo "let c = 3" >> "$repo/macos/Sources/App/a.swift"; commit c; $store stamp
check "new content has a new time" changed "$([ "$before" != "$(stat -f %m "$repo/macos/Sources/App/a.swift")" ] && echo changed || echo same)"

# Pruning keeps the newest.
for n in 1 2 3 4; do echo "$n" > "$tmp/piece"; $store put app "old$n" "$tmp/piece" incremental 2>/dev/null; done
# k1 was used 50 minutes ago, old1 to old4 40 to 10 minutes ago: all within the last 3 hours.
age "$SYMPHONY_CI_CACHE/store/app/k1" 3000
for n in 1 2 3 4; do age "$SYMPHONY_CI_CACHE/store/app/old$n" $(( (5 - n) * 600 )); done
# pr-a was used last, then main, then feature/b.
refs=$(echo "$SYMPHONY_CI_CACHE"/work/*/refs)
age "$refs/pr-a" 600; age "$refs/main" 900; age "$refs/feature_b" 1200
SYMPHONY_CI_KEEP_PIECES=2 $store prune 2>/dev/null
check "prune keeps what was used in the last 3 hours" "k1 old1 old2 old3 old4" "$(ls "$SYMPHONY_CI_CACHE/store/app" | tr '\n' ' ' | sed 's/ $//')"
SYMPHONY_CI_KEEP_REFS=1 $store prune 2>/dev/null
check "branches too, another runner may be building one" "feature_b main pr-a" "$(ls "$SYMPHONY_CI_CACHE"/work/*/refs | tr '\n' ' ' | sed 's/ $//')"
mkdir -p "$SYMPHONY_CI_CACHE/work/Xcode-1.0-Build-old/active"
$store prune 2>/dev/null
check "and another Xcode's folders" yes "$([ -d "$SYMPHONY_CI_CACHE/work/Xcode-1.0-Build-old" ] && echo yes || echo no)"
export SYMPHONY_CI_IN_USE_MINUTES=0
SYMPHONY_CI_KEEP_PIECES=2 $store prune 2>/dev/null
check "past that, prune keeps the newest pieces" "old3 old4" "$(ls "$SYMPHONY_CI_CACHE/store/app" | tr '\n' ' ' | sed 's/ $//')"
SYMPHONY_CI_KEEP_REFS=1 $store prune 2>/dev/null
check "and the newest branches, and main" "main pr-a" "$(ls "$SYMPHONY_CI_CACHE"/work/*/refs | tr '\n' ' ' | sed 's/ $//')"
check "and drops the states saves put aside" "" "$(ls -A "$SYMPHONY_CI_CACHE"/work/*/old)"
check "and another Xcode's folders" no "$([ -d "$SYMPHONY_CI_CACHE/work/Xcode-1.0-Build-old" ] && echo yes || echo no)"
unset SYMPHONY_CI_IN_USE_MINUTES

# A disk short of room: prune drops idle pieces and branch states past the count limits, oldest
# first, until the floor is met. A made-up disk: its free space is a capacity less the cache's size,
# so what prune removes frees room as it would on the runner.
export SYMPHONY_CI_CACHE="$tmp/room" SYMPHONY_CI_MIN_FREE_GB=1
mb() { head -c 1048576 /dev/zero > "$1"; }
for n in 1 2 3 4; do mb "$tmp/piece"; $store put app "p$n" "$tmp/piece" incremental 2>/dev/null; done
for ref in main pr-x pr-y; do mb "$($store work "$ref" release --fresh 2>/dev/null)/state"; $store save "$ref" release 2>/dev/null; done
rstore="$SYMPHONY_CI_CACHE/store/app"; rrefs=$(echo "$SYMPHONY_CI_CACHE"/work/*/refs)
# main is the oldest but is always kept; p4 was used 10 minutes ago, so a job may be copying it.
age "$rrefs/main" 39600; age "$rstore/p1" 36000; age "$rstore/p2" 32400; age "$rrefs/pr-x" 28800
age "$rstore/p3" 25200; age "$rrefs/pr-y" 18000; age "$rstore/p4" 600
used_kb() { du -sk "$SYMPHONY_CI_CACHE" | awk '{ print $1 }'; }
roomy() { # capacity in KB: free = capacity - the cache's size
  export SYMPHONY_CI_FREE_KB_COMMAND="echo \$(( $1 - \$(du -sk '$SYMPHONY_CI_CACHE' | awk '{ print \$1 }') ))"
}
left() { echo "$(ls "$rstore" | tr '\n' ' ')| $(ls "$rrefs" | tr '\n' ' ' | sed 's/ $//')"; }
roomy $(( 1048576 + $(used_kb) + 10240 ))
$store prune 2>/dev/null
check "with room, prune keeps what the count limits allow" "p1 p2 p3 p4 | main pr-x pr-y" "$(left)"
# Two megabytes and a half short: the three oldest idle ones go, and no more.
roomy $(( 1048576 + $(used_kb) - 2560 ))
$store prune 2>/dev/null
check "short of room, prune drops the oldest idle ones until the floor is met" "p3 p4 | main pr-y" "$(left)"
check "and the disk is back over the floor" ok "$($store room >/dev/null 2>&1 && echo ok || echo short)"
check "the report names the free space and the floor" "the floor is 1 GB" "$($store space | grep -o 'the floor is 1 GB')"
# Room that no prune can make: every idle one goes, never main's state, the active folder or a piece in use.
roomy $(( $(used_kb) + 1024 ))
check "when nothing idle is left, room fails" 1 "$($store room >/dev/null 2>&1; echo $?)"
check "having kept what is in use and main's state" "p4 | main" "$(left)"
check "and the active folder" yes "$([ -f "$(dirname "$rrefs")/active/release/state" ] && echo yes || echo no)"
check "its error names the free space and the floor" yes "$(out=$($store room 2>/dev/null || true); echo "$out" | grep -q '::error::.*GB free.*under the 1 GB' && echo yes || echo no)"
unset SYMPHONY_CI_FREE_KB_COMMAND SYMPHONY_CI_MIN_FREE_GB

# With no cache (GitHub's own runners) nothing is kept and nothing fails.
unset SYMPHONY_CI_CACHE
check "no cache: no working folder" "" "$($store work main release)"
check "no cache: get misses" miss "$($store get app k1 "$tmp/out" 2>/dev/null && echo hit || echo miss)"
check "no cache: put, save, stamp and prune do nothing" ok "$($store put app k9 "$tmp/piece" clean && $store save main release && $store stamp && $store prune && echo ok)"
check "no cache: space reports the checkout's disk" yes "$($store space | grep -q '^disk: .* GB free' && echo yes || echo no)"
check "an unknown command is refused" 2 "$($store nonsense >/dev/null 2>&1; echo $?)"

# The groups of checks a pull request needs.
groups() { gate=$1; shift; printf '%s\n' "$@" | sh "$here/mac-check-groups.sh" "$gate" | grep '=true' | cut -d= -f1 | tr '\n' ' ' | sed 's/ $//'; }
check "a UI source file" "any build unit" "$(groups success macos/Sources/SymphonyBarUI/Row.swift)"
check "a Core source file" "any build unit" "$(groups success macos/Sources/SymphonyBarCore/Model.swift)"
check "a Swift test only" "any unit" "$(groups success macos/Tests/SymphonyBarUITests/RowTests.swift)"
check "server code only" "" "$(groups success lib/symphony_elixir/orchestrator.ex test/symphony_elixir/x_test.exs README.md)"
check "the gallery's stories" "any build" "$(groups success macos/Gallery/ButtonStories.swift)"
check "the QA driver" "any build driver" "$(groups success priv/qa_driver/symphony-qa-driver.swift)"
check "the updater's sources" "any build unit update" "$(groups success macos/Sources/SymphonyBarCore/AutoUpdate.swift)"
check "the release's packaging" "any update smoke" "$(groups success mix.lock)"
check "the design notes alone need no Mac check" "" "$(groups success docs/design/director-ticket-page.md)"
check "the catalog meets the unit tests that read it" "any unit" "$(groups success docs/design/catalog/stories.js)"
check "so does its counterpart table" "any unit" "$(groups success docs/design/catalog-counterparts.md)"
check "and the gallery's list of component variations" "any build unit" "$(groups success macos/Gallery/component-variations.txt)"
check "the install script" "any installer" "$(groups success scripts/install-macos.sh)"
check "a red gate on main turns every group on" "any build unit sandbox helpers driver update smoke installer" "$(groups failure README.md)"
check "so does a change to the checks themselves" "any build unit sandbox helpers driver update smoke installer" "$(groups success .github/workflows/mac-checks.yml)"
check "and to the desktop lock" "any build unit sandbox helpers driver update smoke installer" "$(groups success scripts/ci/desktop-lock.sh)"
check "but not to its test alone" "any helpers" "$(groups success scripts/ci/desktop-lock-test.sh)"

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "build-store-test: all passed"
