#!/bin/bash
# Tests scripts/ci/build-store.sh and scripts/ci/mac-check-groups.sh on made-up inputs: no build.
#   bash scripts/ci/build-store-test.sh
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/build-store-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
failures=0
check() { # name expected actual
  if [ "$2" = "$3" ]; then echo "ok [$1]"; else echo "FAIL [$1]: wanted '$2', got '$3'"; failures=$((failures + 1)); fi
}

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
$store save pr-a release 2>/dev/null
check "a save for another branch than the active one saves nothing" a-state "$(cat "$($store work pr-a release 2>/dev/null)/state")"

# Content-made times: the same content has the same time after git rewrote the file.
$store stamp; before=$(stat -f %m "$repo/macos/Sources/App/a.swift")
cp "$repo/macos/Sources/App/a.swift" "$tmp/copy"; rm "$repo/macos/Sources/App/a.swift"; sleep 1; cp "$tmp/copy" "$repo/macos/Sources/App/a.swift"
$store stamp
check "a rewritten file with the same content keeps its time" "$before" "$(stat -f %m "$repo/macos/Sources/App/a.swift")"
echo "let c = 3" >> "$repo/macos/Sources/App/a.swift"; commit c; $store stamp
check "new content has a new time" changed "$([ "$before" != "$(stat -f %m "$repo/macos/Sources/App/a.swift")" ] && echo changed || echo same)"

# Pruning keeps the newest.
for n in 1 2 3 4; do echo "$n" > "$tmp/piece"; $store put app "old$n" "$tmp/piece" incremental 2>/dev/null; sleep 1; done
SYMPHONY_CI_KEEP_PIECES=2 $store prune 2>/dev/null
check "prune keeps the newest pieces" "old3 old4" "$(ls "$SYMPHONY_CI_CACHE/store/app" | tr '\n' ' ' | sed 's/ $//')"
SYMPHONY_CI_KEEP_REFS=1 $store prune 2>/dev/null
check "and the newest branches, and main" "main pr-a" "$(ls "$SYMPHONY_CI_CACHE"/work/*/refs | tr '\n' ' ' | sed 's/ $//')"

# With no cache (GitHub's own runners) nothing is kept and nothing fails.
unset SYMPHONY_CI_CACHE
check "no cache: no working folder" "" "$($store work main release)"
check "no cache: get misses" miss "$($store get app k1 "$tmp/out" 2>/dev/null && echo hit || echo miss)"
check "no cache: put, save, stamp and prune do nothing" ok "$($store put app k9 "$tmp/piece" clean && $store save main release && $store stamp && $store prune && echo ok)"
check "an unknown command is refused" 2 "$($store nonsense >/dev/null 2>&1; echo $?)"

# The groups of checks a pull request needs.
groups() { gate=$1; shift; printf '%s\n' "$@" | sh "$here/mac-check-groups.sh" "$gate" | grep '=true' | cut -d= -f1 | tr '\n' ' ' | sed 's/ $//'; }
check "a UI source file" "any build unit speed sheet" "$(groups success macos/Sources/SymphonyBarUI/Row.swift)"
check "a Core source file" "any build unit speed" "$(groups success macos/Sources/SymphonyBarCore/Model.swift)"
check "a Swift test only" "any unit" "$(groups success macos/Tests/SymphonyBarUITests/RowTests.swift)"
check "server code only" "" "$(groups success lib/symphony_elixir/orchestrator.ex test/symphony_elixir/x_test.exs README.md)"
check "the QA driver" "any build driver speed" "$(groups success priv/qa_driver/symphony-qa-driver.swift)"
check "the updater's sources" "any build unit speed update" "$(groups success macos/Sources/SymphonyBarCore/AutoUpdate.swift)"
check "the release's packaging" "any update smoke" "$(groups success mix.lock)"
check "the design files" "any sheet" "$(groups success docs/design/catalog/stories.js)"
check "the install script" "any installer" "$(groups success scripts/install-macos.sh)"
check "a red gate on main turns every group on" "any build unit sandbox helpers driver speed sheet update smoke installer" "$(groups failure README.md)"
check "so does a change to the checks themselves" "any build unit sandbox helpers driver speed sheet update smoke installer" "$(groups success .github/workflows/mac-checks.yml)"

if [ "$failures" -gt 0 ]; then echo "$failures failure(s)"; exit 1; fi
echo "build-store-test: all passed"
