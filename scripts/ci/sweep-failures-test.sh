#!/bin/sh
# Tests scripts/ci/sweep-failures.sh on made-up ExUnit logs. Run: sh scripts/ci/sweep-failures-test.sh
set -eu

script="$(cd "$(dirname "$0")" && pwd)/sweep-failures.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/sweep-failures.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
failed=0

fail() {
  echo "FAIL $1"
  failed=1
}

# A log with two failures, ANSI colours and the summary.
esc="$(printf '\033')"
cat > "$tmp/red.log" <<LOG
Running ExUnit with seed: 42, max_cases: 4
..

  1) test dispatch starts each run (SymphonyElixir.RunProfileDispatchTest)
     test/symphony_elixir/run_profile_dispatch_test.exs:195
     ${esc}[31mexpected 2 Claude invocation(s), got ["a | b"]${esc}[0m
     code: assert [_first, second | _rest] = wait_for_argv_lines(ctx.argv_trace, 2)

  2) test config defaults (SymphonyElixir.CoreTest)
     test/symphony_elixir/core_test.exs:67
     Assertion with == failed
     code:  assert 1 == 2

Finished in 3.2 seconds (1.0s async, 2.2s sync)
10 tests, 2 failures
LOG

rows="$(sh "$script" rows 3 42 "$tmp/red.log")"
[ "$(echo "$rows" | wc -l | tr -d ' ')" = 2 ] || fail "two failures give two rows: $rows"
case "$rows" in
  *'| 3 | 42 | test dispatch starts each run (SymphonyElixir.RunProfileDispatchTest) | test/symphony_elixir/run_profile_dispatch_test.exs:195 | expected 2 Claude invocation(s), got ["a / b"] |'*) ;;
  *) fail "first row: $rows" ;;
esac
case "$rows" in
  *'| 3 | 42 | test config defaults (SymphonyElixir.CoreTest) | test/symphony_elixir/core_test.exs:67 | Assertion with == failed |'*) ;;
  *) fail "second row: $rows" ;;
esac

# A green log gives no row; a log cut off before the summary gives one.
printf 'Running ExUnit with seed: 7\n...\nFinished in 1.0 seconds\n3 tests, 0 failures\n' > "$tmp/green.log"
[ -z "$(sh "$script" rows 1 7 "$tmp/green.log")" ] || fail "a green log gives no row"
printf 'Running ExUnit with seed: 8\n...\n** (EXIT) killed\n' > "$tmp/cut.log"
case "$(sh "$script" rows 2 8 "$tmp/cut.log")" in
  '| 2 | 8 | (suite did not finish) | | ** (EXIT) killed |') ;;
  *) fail "a cut-off log: $(sh "$script" rows 2 8 "$tmp/cut.log")" ;;
esac
case "$(sh "$script" rows 4 9 "$tmp/missing.log")" in
  '| 4 | 9 | (no log) | | the run left no test log |') ;;
  *) fail "a missing log" ;;
esac

# The report: green runs only pass; any failure fails it and counts the test across runs.
mkdir -p "$tmp/green" "$tmp/red"
: > "$tmp/green/1-7.md"
: > "$tmp/green/2-7.md"
out="$(sh "$script" report "$tmp/green")" || fail "an all-green report exits 0"
case "$out" in
  *"2 suite runs."*"No test failed in any run."*) ;;
  *) fail "green report: $out" ;;
esac

sh "$script" rows 3 42 "$tmp/red.log" > "$tmp/red/3-42.md"
sh "$script" rows 3 43 "$tmp/red.log" | head -1 > "$tmp/red/3-43.md"
: > "$tmp/red/1-42.md"
if out="$(sh "$script" report "$tmp/red")"; then fail "a report with failures exits 1"; fi
case "$out" in
  *"3 suite runs."*"| 2 | test dispatch starts each run (SymphonyElixir.RunProfileDispatchTest) | test/symphony_elixir/run_profile_dispatch_test.exs:195 |"*"| 1 | test config defaults"*"### Every failure"*"| 3 | 43 |"*) ;;
  *) fail "red report: $out" ;;
esac

if sh "$script" bogus > /dev/null 2>&1; then fail "an unknown command exits non-zero"; fi

[ "$failed" = 0 ] && echo "sweep-failures: all tests passed"
exit "$failed"
