#!/bin/sh
# Smoke-tests a Burrito-built `symphony` binary. Prints each command's full
# output and exit code, so a failing release run shows what the binary did.
#
#   1. `symphony --help` prints its usage and exits 1.
#   2. `symphony check --config CONFIG` prints "Config OK" and exits 0.
#   3. With a second instance of the binary running as the service, holding the
#      node name symphony@127.0.0.1, `check` still prints "Config OK" and exits 0,
#      and still exits 1 for broken YAML, an unknown key and a missing file.
#
# Each run gets a fresh HOME, so Burrito unpacks this binary's own payload
# instead of reusing an install dir left by an earlier binary of the same version.
# The run uses its own epmd port, so a Symphony already running on this machine
# neither blocks the service instance nor stands in for it.
#
# Usage:
#   scripts/release/smoke_test.sh BINARY CONFIG
set -eu

if [ $# -ne 2 ]; then
  echo "usage: $0 BINARY CONFIG" >&2
  exit 2
fi

binary="$1"
config="$2"
failed=0
work="$(mktemp -d "${TMPDIR:-/tmp}/symphony-smoke.XXXXXX")"
service_pid=""
epmd=""
ERL_EPMD_PORT="$((20000 + $$ % 20000))"
export ERL_EPMD_PORT

cleanup() {
  if [ -n "$service_pid" ]; then
    kill "$service_pid" 2>/dev/null || true
    wait "$service_pid" 2>/dev/null || true
  fi
  if [ -n "$epmd" ]; then
    "$epmd" -kill >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT

# run EXPECTED_EXIT EXPECTED_TEXT ARGS...
run() {
  expected_exit="$1"
  expected_text="$2"
  shift 2
  home="$(mktemp -d "$work/home.XXXXXX")"
  echo "::group::$binary $*"
  set +e
  output="$(HOME="$home" "$binary" "$@" 2>&1)"
  code=$?
  set -e
  printf '%s\n' "$output"
  echo "exit code: $code"
  echo "::endgroup::"
  rm -rf "$home"

  if [ "$code" -ne "$expected_exit" ]; then
    echo "::error::symphony $* exited $code, expected $expected_exit."
    failed=1
  fi
  if ! printf '%s\n' "$output" | grep -qF "$expected_text"; then
    echo "::error::symphony $* did not print '$expected_text'."
    failed=1
  fi
}

# Starts the binary as the service in the background and waits until it has
# registered symphony@127.0.0.1 with epmd.
start_service() {
  service_home="$work/service-home"
  service_log="$work/service.log"
  mkdir -p "$service_home"
  echo "::group::$binary --config $config --port 0 (background service)"
  HOME="$service_home" "$binary" --config "$config" --port 0 >"$service_log" 2>&1 &
  service_pid=$!

  attempt=0
  while [ "$attempt" -lt 120 ]; do
    if [ -z "$epmd" ]; then
      epmd="$(find "$service_home" -path '*/erts-*/bin/epmd' -type f 2>/dev/null | head -n 1)"
    fi
    if [ -n "$epmd" ] && "$epmd" -names 2>/dev/null | grep -q '^name symphony '; then
      "$epmd" -names
      echo "::endgroup::"
      return 0
    fi
    if ! kill -0 "$service_pid" 2>/dev/null; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 1
  done

  cat "$service_log"
  echo "::endgroup::"
  echo "::error::The symphony service did not register symphony@127.0.0.1 with epmd."
  return 1
}

run 1 "Usage: symphony" --help
run 0 "Config OK" check --config "$config"

if start_service; then
  printf 'issues: [\n' >"$work/broken.yml"
  sed 's/^issues:/issuez:/' "$config" >"$work/unknown-key.yml"

  run 0 "Config OK" check --config "$config"
  run 1 "Failed to parse symphony.yml" check --config "$work/broken.yml"
  run 1 "unknown symphony.yml key" check --config "$work/unknown-key.yml"
  run 1 "Symphony config file not found" check --config "$work/missing.yml"
else
  failed=1
fi

exit "$failed"
