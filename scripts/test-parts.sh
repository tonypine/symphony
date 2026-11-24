#!/usr/bin/env bash
# Runs every Elixir test in several processes at once, and the tests that failed last time first.
#
#   scripts/test-parts.sh               all tests, in 8 parts
#   scripts/test-parts.sh -n 4          in 4 parts
#   scripts/test-parts.sh --record      also rewrites test/support/test_weights.tsv from this run
#   TEST_PARTS=6 scripts/test-parts.sh  the number of parts from the environment
#
# 1. When the last run left failures (_build/test/parts/failed.txt), those tests run first, alone.
#    If one still fails the script stops there: a fix is checked in seconds, not after a whole run.
# 2. Then the test files are spread over the parts by how long each took last time
#    (test/support/test_weights.tsv; a file it does not list counts as an average one), heaviest
#    first onto the lightest part, and each part runs as its own `mix test`. Most test files run
#    one test at a time, so one process leaves most cores idle; the parts use them.
# 3. Each part stops after 10 failures and runs 2 tests at a time. Only the failing parts' failures
#    are printed, then one summary line.
# 4. Tests that failed run once more, alone. The ones that pass then are named as unsteady and do
#    not fail the run; the exit status is 0 when nothing failed twice.
#
# Each part's whole output stays in _build/test/parts/part-<n>.log.
set -u

parts="${TEST_PARTS:-8}"
record=0
max_failures="${TEST_MAX_FAILURES:-10}"
# ExUnit runs 2 x cores of the tests that may run together, in every part. With 8 parts that is
# 16 x cores at once, and the tests that measure time fail. 2 per part keeps the cores busy.
max_cases="${TEST_MAX_CASES:-2}"

while [ $# -gt 0 ]; do
  case "$1" in
    -n) parts="$2"; shift 2 ;;
    --record) record=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "test-parts: unknown argument $1" >&2; exit 64 ;;
  esac
done

case "$parts" in ''|*[!0-9]*|0) echo "test-parts: the number of parts must be 1 or more, got '$parts'" >&2; exit 64 ;; esac

cd "$(dirname "$0")/.." || exit 70
out="_build/test/parts"
weights="test/support/test_weights.tsv"
failed="$out/failed.txt"
mkdir -p "$out"
started=$(date +%s)

# The numbered failures of a `mix test` log, as `test/file_test.exs:line`, one per failed test.
failures_of() {
  awk '
    /^ +[0-9]+\) test / { want = 1; next }
    want && /^ +test\/[^ ]+\.exs:[0-9]+/ { sub(/^ +/, ""); print; want = 0 }
  ' "$1"
}

# The failures of a log as ExUnit printed them, without the lines before the first one.
print_failures() {
  awk '/^ +[0-9]+\) test / { on = 1 } /^Finished in / { on = 0 } on && !/^[.*]+$/' "$1" | head -n 400
}

MIX_ENV=test mix compile >"$out/compile.log" 2>&1 || {
  cat "$out/compile.log"
  echo "test-parts: the test build failed"
  exit 1
}

if [ -s "$failed" ]; then
  count=$(wc -l <"$failed" | tr -d ' ')
  # A test file that is gone has no failure left to check.
  again=$(while IFS= read -r spec; do [ -f "${spec%:*}" ] && printf '%s\n' "$spec"; done <"$failed")

  if [ -n "$again" ]; then
    # shellcheck disable=SC2086
    mix test --max-failures "$max_failures" $again >"$out/failed-first.log" 2>&1
    status=$?

    if [ $status -ne 0 ]; then
      print_failures "$out/failed-first.log"
      [ -n "$(failures_of "$out/failed-first.log")" ] || tail -n 60 "$out/failed-first.log"
      failures_of "$out/failed-first.log" | sort -u >"$failed.next"
      [ -s "$failed.next" ] && mv "$failed.next" "$failed"
      rm -f "$failed.next"
      still=$(wc -l <"$failed" | tr -d ' ')
      echo "test-parts: $still of the $count tests that failed last time still fail; the rest of the suite did not run ($(( $(date +%s) - started )) s)"
      exit 1
    fi
  fi

  rm -f "$failed"
fi

rm -f "$out"/part-*.log "$out"/part-*.files "$out"/part-*.status

# Heaviest file first onto the lightest part. A file with no recorded time counts as the average.
find test -name '*_test.exs' | sort >"$out/files.txt"
awk -F '\t' -v parts="$parts" -v out="$out" '
  FNR == NR { weight[$1] = $2; total += $2; known++; next }
  { files[++n] = $0 }
  END {
    average = known ? total / known : 1
    for (i = 1; i <= n; i++) w[i] = (files[i] in weight) ? weight[files[i]] : average
    for (i = 1; i <= n; i++) order[i] = i
    for (i = 2; i <= n; i++) {
      key = order[i]
      for (j = i - 1; j >= 1 && w[order[j]] < w[key]; j--) order[j + 1] = order[j]
      order[j + 1] = key
    }
    for (k = 1; k <= n; k++) {
      lightest = 1
      for (p = 2; p <= parts; p++) if (load[p] < load[lightest]) lightest = p
      load[lightest] += w[order[k]]
      print files[order[k]] > (out "/part-" lightest ".files")
    }
  }
' "$( [ -f "$weights" ] && echo "$weights" || echo /dev/null )" "$out/files.txt"

extra=""
[ "$record" -eq 1 ] && extra="--slowest-modules 100000"

pids=""
for part in $(seq 1 "$parts"); do
  [ -s "$out/part-$part.files" ] || continue
  (
    # shellcheck disable=SC2046,SC2086
    mix test --max-failures "$max_failures" --max-cases "$max_cases" $extra $(tr '\n' ' ' <"$out/part-$part.files") >"$out/part-$part.log" 2>&1
    echo $? >"$out/part-$part.status"
  ) &
  pids="$pids $!"
done

# shellcheck disable=SC2086
wait $pids

failed_parts=0
crashed=0
tests=0
failures=0
: >"$failed.next"

for part in $(seq 1 "$parts"); do
  [ -f "$out/part-$part.status" ] || continue
  status=$(cat "$out/part-$part.status")
  counts=$(grep -E '^[0-9]+ tests?, [0-9]+ failures?' "$out/part-$part.log" | tail -n 1)
  tests=$(( tests + $(echo "$counts" | awk '{ print $1 + 0 }') ))
  failures=$(( failures + $(echo "$counts" | awk '{ print $3 + 0 }') ))

  if [ "$status" -ne 0 ]; then
    failed_parts=$(( failed_parts + 1 ))
    failures_of "$out/part-$part.log" >>"$failed.next"

    # No numbered failure: the part did not get as far as running tests (a compile error, a crash).
    if [ -z "$(failures_of "$out/part-$part.log")" ]; then
      crashed=$(( crashed + 1 ))
      echo "Part $part of $parts ended without running its tests:"
      tail -n 60 "$out/part-$part.log"
    fi
  fi
done

elapsed=$(( $(date +%s) - started ))

if [ "$record" -eq 1 ] && [ "$failed_parts" -eq 0 ]; then
  cat "$out"/part-*.log | awk '
    /^[A-Za-z0-9_.]+ \([0-9.]+ms\)$/ { ms = $2; gsub(/[()ms]/, "", ms); next }
    /^ \[test\/.*\]$/ { file = $1; gsub(/[\[\]]/, "", file); printf "%s\t%.1f\n", file, ms / 1000 }
  ' | sort >"$weights"
  echo "test-parts: recorded $(wc -l <"$weights" | tr -d ' ') file times in $weights"
fi

if [ "$failed_parts" -eq 0 ]; then
  rm -f "$failed.next"
  echo "test-parts: $tests tests passed in $parts parts, $elapsed s"
  exit 0
fi

sort -u "$failed.next" >"$failed"
rm -f "$failed.next"

# A test that measures time can fail while every core is busy. The failed tests run once more,
# alone: the ones that pass are named as unsteady and do not fail the run.
again=$(cat "$failed")
count=$(wc -l <"$failed" | tr -d ' ')

if [ "$crashed" -eq 0 ] && [ -n "$again" ] && [ "$count" -le 30 ]; then
  # shellcheck disable=SC2086
  if mix test $again >"$out/retry.log" 2>&1; then
    rm -f "$failed"
    echo "test-parts: $tests tests passed in $parts parts, $(( $(date +%s) - started )) s; $count failed beside the others and passed alone:"
    sed 's/^/  /' <<EOF
$again
EOF
    exit 0
  fi

  failures_of "$out/retry.log" | sort -u >"$failed"
  [ -s "$failed" ] || printf '%s\n' "$again" >"$failed"
  echo "Failed again, alone:"
  print_failures "$out/retry.log"
else
  for part in $(seq 1 "$parts"); do
    [ "$(cat "$out/part-$part.status" 2>/dev/null)" = "0" ] || print_failures "$out/part-$part.log"
  done
fi

echo "test-parts: $(wc -l <"$failed" | tr -d ' ') tests fail ($failures failures in $failed_parts of $parts parts, $tests tests ran, $(( $(date +%s) - started )) s); they run first next time"
exit 1
