#!/bin/bash
# The build cache of a CI runner that keeps its disk between jobs (a self-hosted Mac runner).
# Two things live under $SYMPHONY_CI_CACHE:
#
#   work/<toolchain>/refs/<ref>/<flavour>   the compiler's own folders, one set per branch, so a
#                                      push recompiles what it changed. A new branch starts from
#                                      main's set. Builds run in work/<toolchain>/active/<flavour>;
#                                      copies between the two are APFS clones (no space until changed).
#   store/<kind>/<key>/                finished pieces, filed under a key made from the content of
#                                      the paths that feed them, so a job that needs a piece some
#                                      job already built takes it instead of building it again:
#                                        app      macos' SymphonyBar executable (release)
#                                        server   the Symphony release (`make release`), per build number
#
# With SYMPHONY_CI_CACHE unset (GitHub's own runners) nothing is cached: `app` and `server` build
# in place, as the workflows did before, and `get` always misses.
#
#   build-store.sh key app                      the app executable's key at HEAD
#   build-store.sh key server <build-number>    the release's key at HEAD for that build number
#   build-store.sh work <ref> <flavour> [--fresh]   puts the branch's saved state (else main's) in the
#                                               active folder and prints it; --fresh empties it
#   build-store.sh save <ref> <flavour>         files the active folder's state under the branch
#   build-store.sh stamp                        gives the sources content-made times (after checkout)
#   build-store.sh get <kind> <key> <dest> [--clean]   copies the piece to <dest>; exit 1 on a miss.
#                                               --clean takes only a piece from a clean build
#   build-store.sh put <kind> <key> <src> <clean|incremental>
#   build-store.sh app <dest> [--clean]         the executable at <dest>: from the store, else built
#                                               (in <ref>'s working folder, $SYMPHONY_CI_REF) and filed
#   build-store.sh server <build-number> <dest> the release at <dest>: from the store, else built and filed
#   build-store.sh prune                        drops old pieces and working folders
#
# The key lists (APP_INPUTS, SERVER_INPUTS) are the whole contract: a path that feeds a piece and
# is missing from its list lets a job take a stale piece. When unsure, list it. A release never
# takes an incremental piece: main builds clean (`work main <flavour> --fresh`) and files `clean`.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
ROOT=${SYMPHONY_CI_CACHE:-}
KEEP_PIECES=${SYMPHONY_CI_KEEP_PIECES:-30}
KEEP_REFS=${SYMPHONY_CI_KEEP_REFS:-20}

# What feeds the SymphonyBar executable. Tests, snapshots, Info.plist, Resources and the QA driver
# are not in it: `make app` assembles those around it on every build.
APP_INPUTS="macos/Sources macos/Package.swift macos/Makefile .xcode-version"
# What feeds `make release`.
SERVER_INPUTS="lib config priv rel mix.exs mix.lock mise.toml Makefile"

die() { echo "build-store: $*" >&2; exit 2; }
note() { echo "build-store: $*" >&2; }
enabled() { [ -n "$ROOT" ]; }

# The key of a piece: the git object of each input at HEAD, the machine's architecture and the
# words after the inputs (the build number, the build's environment). Uncommitted changes to an
# input have no object, so they turn the cache off for that piece rather than file it under HEAD's key.
key_of() { # "<inputs>" extra...
  local inputs=$1; shift
  local path lines=""
  # shellcheck disable=SC2086
  if [ -n "$(git -C "$REPO" status --porcelain -- $inputs 2>/dev/null)" ]; then return 1; fi
  for path in $inputs; do
    lines="$lines$path $(git -C "$REPO" rev-parse --verify -q "HEAD:$path" || echo absent)
"
  done
  printf '%s%s %s\n' "$lines" "$(uname -m)" "$*" | shasum -a 256 | cut -c1-32
}

app_key() { key_of "$APP_INPUTS" release; }
server_key() { key_of "$SERVER_INPUTS" "build=$1" "sha=${SYMPHONY_BUILD_SHA:-}" "repo=${SYMPHONY_BUILD_REPO:-}"; }

toolchain() { # the Xcode a working folder belongs to: another Xcode starts clean
  xcodebuild -version 2>/dev/null | tr -s ' \n' '-' | sed 's/-$//' || echo unknown
}

safe_ref() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

copy() { # APFS clones where the disk allows, a plain copy elsewhere
  rm -rf "$2"; mkdir -p "$(dirname "$2")"
  cp -cR "$1" "$2" 2>/dev/null || cp -R "$1" "$2"
}

# A compiler's folder cannot be copied to another path and reused: Swift's module cache refuses
# files compiled under another path. So every build runs in one fixed place, work/<toolchain>/active/<flavour>,
# and each branch's state is kept beside it: `work` puts the branch's saved state (else main's) into
# the active place, `save` files the active state back under the branch. One runner runs one job at
# a time, so the active place has one user.
cmd_work() {
  local ref=${1:?ref} flavour=${2:?flavour} fresh=${3:-}
  enabled || { echo ""; return 0; }
  local base="$ROOT/work/$(toolchain)"
  local active="$base/active/$flavour" own="$base/refs/$(safe_ref "$ref")/$flavour" seed="$base/refs/main/$flavour"
  mkdir -p "$base/active"
  if [ "$(cat "$active.ref" 2>/dev/null)" = "$ref" ] && [ -d "$active" ] && [ "$fresh" != "--fresh" ]; then
    : # the active state is already this branch's (the last job was the same branch's)
  elif [ "$fresh" = "--fresh" ]; then
    rm -rf "$active"; mkdir -p "$active"
  elif [ -d "$own" ]; then
    copy "$own" "$active"
  elif [ -d "$seed" ]; then
    note "work: $ref/$flavour starts from main's"
    copy "$seed" "$active"
  else
    rm -rf "$active"; mkdir -p "$active"
  fi
  echo "$ref" > "$active.ref"
  # a branch in use is the last to be pruned
  if [ -d "$base/refs/$(safe_ref "$ref")" ]; then touch "$base/refs/$(safe_ref "$ref")"; fi
  echo "$active"
}

# The build tools decide what to recompile from each file's time, and git gives every file it
# writes the time of the checkout. So after one branch's job, another branch's files that differ
# all look new, and a switch between branches recompiled nearly everything (measured: 115 s against
# 7 s). `stamp` gives every tracked source file a time made from its content, so the same content
# has the same time whichever job wrote it. Run it after the checkout, before the first build.
STAMP_PATHS="macos priv/qa_driver"
cmd_stamp() {
  enabled || return 0
  local mode hash stage path
  # shellcheck disable=SC2086
  git -C "$REPO" ls-files -s -- $STAMP_PATHS | while read -r mode hash stage path; do
    [ -f "$REPO/$path" ] || continue
    touch -t "$(date -r $((1500000000 + 0x${hash:0:7})) +%Y%m%d%H%M.%S)" "$REPO/$path"
  done
}

cmd_save() {
  local ref=${1:?ref} flavour=${2:?flavour}
  enabled || return 0
  local base="$ROOT/work/$(toolchain)"
  local active="$base/active/$flavour" own="$base/refs/$(safe_ref "$ref")/$flavour"
  [ -d "$active" ] && [ "$(cat "$active.ref" 2>/dev/null)" = "$ref" ] || { note "save: the active $flavour is not $ref's; nothing saved"; return 0; }
  copy "$active" "$own"
  touch "$base/refs/$(safe_ref "$ref")"
}

cmd_get() {
  local kind=${1:?kind} key=${2:?key} dest=${3:?dest} only=${4:-}
  enabled || return 1
  local entry="$ROOT/store/$kind/$key"
  [ -e "$entry/payload" ] || return 1
  if [ "$only" = "--clean" ] && [ "$(cat "$entry/mode" 2>/dev/null)" != clean ]; then
    note "get: $kind/$key is from an incremental build; a clean one is wanted"
    return 1
  fi
  copy "$entry/payload" "$dest"
  touch "$entry"
  note "get: $kind/$key ($(cat "$entry/mode" 2>/dev/null)) -> $dest"
}

cmd_put() {
  local kind=${1:?kind} key=${2:?key} src=${3:?src} mode=${4:?clean|incremental}
  enabled || return 0
  [ -e "$src" ] || die "put: $src does not exist"
  local entry="$ROOT/store/$kind/$key" tmp
  # A clean piece is never replaced by an incremental one.
  if [ "$mode" = incremental ] && [ "$(cat "$entry/mode" 2>/dev/null)" = clean ]; then
    note "put: $kind/$key already holds a clean build; kept"; return 0
  fi
  if [ -e "$entry/payload" ] && [ -f "$src" ] && ! cmp -s "$src" "$entry/payload"; then
    note "put: $kind/$key differs from the piece already filed under that key (was $(cat "$entry/mode" 2>/dev/null), now $mode)"
  fi
  mkdir -p "$ROOT/store/$kind"
  tmp=$(mktemp -d "$ROOT/store/$kind/.put.XXXXXX")
  copy "$src" "$tmp/payload"
  echo "$mode" > "$tmp/mode"
  git -C "$REPO" rev-parse HEAD > "$tmp/commit" 2>/dev/null || true
  rm -rf "$entry"; mv "$tmp" "$entry"
  note "put: $kind/$key ($mode)"
}

mode_of() { if [ "${SYMPHONY_CI_REF:-}" = main ]; then echo clean; else echo incremental; fi; }

# The SymphonyBar executable at <dest>.
cmd_app() {
  local dest=${1:?dest} only=${2:-} key="" scratch="" bin
  if enabled; then key=$(app_key) || { note "app: uncommitted changes under the app's inputs; building without the store"; key=""; }; fi
  if [ -n "$key" ] && cmd_get app "$key" "$dest" "$only"; then return 0; fi
  if enabled; then
    if [ "$only" = "--clean" ]; then scratch=$(cmd_work "${SYMPHONY_CI_REF:-main}" release-clean --fresh)
    else scratch=$(cmd_work "${SYMPHONY_CI_REF:-main}" release-plain); fi
  fi
  note "app: building SymphonyBar (swift build -c release)"
  # shellcheck disable=SC2086
  (cd "$REPO/macos" && swift build -c release --product SymphonyBar ${scratch:+--scratch-path "$scratch"} >&2)
  # shellcheck disable=SC2086
  bin=$(cd "$REPO/macos" && swift build -c release --show-bin-path ${scratch:+--scratch-path "$scratch"})
  mkdir -p "$(dirname "$dest")"; cp "$bin/SymphonyBar" "$dest"
  if enabled; then if [ "$only" = "--clean" ]; then cmd_save "${SYMPHONY_CI_REF:-main}" release-clean; else cmd_save "${SYMPHONY_CI_REF:-main}" release-plain; fi; fi
  if [ -n "$key" ]; then
    if [ "$only" = "--clean" ]; then cmd_put app "$key" "$dest" clean; else cmd_put app "$key" "$dest" "$(mode_of)"; fi
  fi
}

# The Symphony release for <build-number> at <dest>. Mix compiles in the ref's working folder
# when there is one, so the second release of a job, and the next push, compile little.
cmd_server() {
  local build=${1:?build number} dest=${2:?dest} key="" work="" built
  if enabled; then key=$(server_key "$build") || { note "server: uncommitted changes under the release's inputs; building without the store"; key=""; }; fi
  if [ -n "$key" ] && cmd_get server "$key" "$dest"; then return 0; fi
  note "server: building the Symphony release for build $build (make release)"
  if enabled; then
    if [ "${SYMPHONY_CI_REF:-main}" = main ]; then work=$(cmd_work main mix --fresh); else work=$(cmd_work "$SYMPHONY_CI_REF" mix); fi
    export MIX_BUILD_ROOT="$work/_build" MIX_DEPS_PATH="$work/deps"
    built="$work/_build/prod/rel/symphony"
  else
    built="$REPO/_build/prod/rel/symphony"
  fi
  # Mix keeps the application file (it carries the build number) while mix.exs is unchanged, so a
  # second build would report the first one's number.
  rm -f "${MIX_BUILD_ROOT:-$REPO/_build}/prod/lib/symphony_elixir/ebin/symphony_elixir.app"
  (cd "$REPO" && env -u SYMPHONY_AGENT_RUNTIME SYMPHONY_BUILD_NUMBER="$build" make release >&2)
  [ -d "$built/releases/0.0.1-$build" ] || die "server: make release did not produce build $build in $built"
  rm -rf "$dest"; mkdir -p "$(dirname "$dest")"; ditto "$built" "$dest"
  if enabled; then cmd_save "${SYMPHONY_CI_REF:-main}" mix; fi
  if [ -n "$key" ]; then cmd_put server "$key" "$dest" "$(mode_of)"; fi
}

cmd_prune() {
  enabled || return 0
  local kind dir n
  for kind in "$ROOT"/store/*/; do
    [ -d "$kind" ] || continue
    n=0
    # newest first; `get` touches a piece, so one in use stays
    while IFS= read -r dir; do
      n=$((n + 1))
      if [ "$n" -gt "$KEEP_PIECES" ]; then note "prune: $dir"; rm -rf "$dir"; fi
    done < <(ls -1dt "$kind"*/ 2>/dev/null)
    rm -rf "$kind".put.* 2>/dev/null || true
  done
  for kind in "$ROOT"/work/*/; do
    [ -d "$kind" ] || continue
    if [ "$(basename "$kind")" != "$(toolchain)" ]; then note "prune: $kind (another Xcode)"; rm -rf "$kind"; continue; fi
    n=0
    while IFS= read -r dir; do
      [ "$(basename "$dir")" = main ] && continue
      n=$((n + 1))
      if [ "$n" -gt "$KEEP_REFS" ]; then note "prune: $dir"; rm -rf "$dir"; fi
    done < <(ls -1dt "$kind"refs/*/ 2>/dev/null)
  done
}

command=${1:-}; [ $# -gt 0 ] && shift
case "$command" in
  key)
    case "${1:-}" in
      app) app_key || die "key: uncommitted changes under: $APP_INPUTS";;
      server) server_key "${2:?build number}" || die "key: uncommitted changes under: $SERVER_INPUTS";;
      *) die "key: app | server <build-number>";;
    esac;;
  inputs) case "${1:-}" in app) echo "$APP_INPUTS";; server) echo "$SERVER_INPUTS";; *) die "inputs: app | server";; esac;;
  work) cmd_work "$@";;
  save) cmd_save "$@";;
  stamp) cmd_stamp;;
  get) cmd_get "$@";;
  put) cmd_put "$@";;
  app) cmd_app "$@";;
  server) cmd_server "$@";;
  prune) cmd_prune;;
  *) sed -n '2,34p' "$0" >&2; exit 2;;
esac
