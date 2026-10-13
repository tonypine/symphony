#!/usr/bin/env bash
# Boots a real `mix release` through bin/symphony-app, so a launcher
# that can't start the VM fails here: `--help` must print usage and `check` must
# get a config path with spaces in it unchanged.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd -P)"
cd "$repo"
work="$(mktemp -d "${TMPDIR:-/tmp}/symphony-launcher-boot.XXXXXX")"
trap 'rm -rf "$work"' EXIT
failures=0

MIX_ENV=prod mix release --overwrite >/dev/null
launcher="$repo/_build/prod/rel/symphony/bin/symphony-app"

export SYMPHONY_STATE_ROOT="$work/state"
export RELEASE_TMP="$work/tmp"

# Runs the launcher with <args...> and checks its output contains $2.
expect_output() {
  local name="$1" needle="$2"
  shift 2
  local output
  output="$("$launcher" "$@" 2>&1 || true)"
  if [[ "$output" == *"$needle"* ]]; then
    echo "ok - $name"
  else
    echo "not ok - $name"
    printf '%s\n' "$output" | head -20
    failures=$((failures + 1))
  fi
}

mkdir -p "$work/my settings"
printf 'not_a_key: 1\n' > "$work/my settings/symphony.yml"

expect_output "--help prints usage" "Usage: symphony" --help
expect_output "check gets a config path with spaces" "$work/my settings/symphony.yml" \
  check --config "$work/my settings/symphony.yml"

[ "$failures" -eq 0 ]
