#!/bin/sh
# The flaky-test sweep's two halves (the "flaky sweep" workflow, started by hand).
#
#   sweep-failures.sh rows <partition> <seed> <test log>
#     One markdown table row per ExUnit failure in the log of one suite run:
#     | partition | seed | test | where | failure |
#     A run that ends without ExUnit's summary (a crash, a timeout) gets one row saying so.
#
#   sweep-failures.sh report <rows dir>
#     The rows of every run (*.md in the directory) as one table, with the count of runs, the
#     failing tests first by how many runs they failed. Exits 1 when any run failed.
set -eu

usage() {
  echo "usage: sweep-failures.sh rows <partition> <seed> <log> | report <dir>" >&2
  exit 2
}

cell() {
  # A table cell: no pipe, no newline, at most 200 characters.
  tr '|' '/' | tr -d '\n' | cut -c1-200
}

rows() {
  partition="$1" seed="$2" log="$3"

  if [ ! -f "$log" ]; then
    echo "| $partition | $seed | (no log) | | the run left no test log |"
    return
  fi

  # A failure block opens at "  N) test ...": the next line is where, the one after it what.
  sed -e 's/\x1b\[[0-9;]*m//g' "$log" | awk -v p="$partition" -v s="$seed" '
    function clean(text) { gsub(/\|/, "/", text); sub(/^ +/, "", text); return substr(text, 1, 200) }
    /^ +[0-9]+\) / { title = $0; sub(/^ +[0-9]+\) /, "", title); state = 1; where = ""; next }
    state == 1 { where = clean($0); state = 2; next }
    state == 2 && NF > 0 {
      printf "| %s | %s | %s | %s | %s |\n", p, s, clean(title), where, clean($0)
      state = 0
    }
  '

  if ! grep -q '^Finished in ' "$log"; then
    tail_line="$(sed -e 's/\x1b\[[0-9;]*m//g' "$log" | awk 'NF { last = $0 } END { print last }' | cell)"
    echo "| $partition | $seed | (suite did not finish) | | $tail_line |"
  fi
}

report() {
  dir="$1"
  runs="$(find "$dir" -name '*.md' | wc -l | tr -d ' ')"
  all="$(cat "$dir"/*.md 2>/dev/null || true)"
  echo "## Flaky sweep"
  echo
  echo "$runs suite runs."
  echo

  if [ -z "$all" ]; then
    echo "No test failed in any run."
    return 0
  fi

  echo "### Failing tests, by runs failed"
  echo
  echo "| runs | test | where |"
  echo "| --- | --- | --- |"
  echo "$all" | awk -F' [|] ' '{ key = $3 " | " $4; count[key]++ } END { for (k in count) printf "| %d | %s |\n", count[k], k }' | sort -t'|' -k2,2nr
  echo
  echo "### Every failure"
  echo
  echo "| partition | seed | test | where | failure |"
  echo "| --- | --- | --- | --- | --- |"
  echo "$all"
  return 1
}

[ $# -ge 1 ] || usage
command="$1"
shift

case "$command" in
  rows) [ $# -eq 3 ] || usage; rows "$@" ;;
  report) [ $# -eq 1 ] || usage; report "$@" ;;
  *) usage ;;
esac
