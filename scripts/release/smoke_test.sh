#!/bin/sh
# Smoke-tests a Burrito-built `symphony` binary. Prints each command's full
# output and exit code, so a failing release run shows what the binary did.
#
#   1. `symphony --help` prints its usage and exits 1.
#   2. `symphony check --config CONFIG` prints "Config OK" and exits 0.
#
# Each run gets a fresh HOME, so Burrito unpacks this binary's own payload
# instead of reusing an install dir left by an earlier binary of the same version.
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

# run EXPECTED_EXIT EXPECTED_TEXT ARGS...
run() {
  expected_exit="$1"
  expected_text="$2"
  shift 2
  home="$(mktemp -d "${TMPDIR:-/tmp}/symphony-smoke.XXXXXX")"
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

run 1 "Usage: symphony" --help
run 0 "Config OK" check --config "$config"

exit "$failed"
