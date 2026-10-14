#!/usr/bin/env bash
# Publishes each ExUnit failure block in a test log as a GitHub error annotation.
# Job logs need admin rights to download; check-run annotations are readable by
# anyone with read access, so agents can name a failing test without the log.
#
# Usage: annotate-test-failures.sh <test log>
set -euo pipefail

log="${1:?usage: annotate-test-failures.sh <test log>}"
[ -f "$log" ] || exit 0

# A failure block starts at "  N) test ..." and runs to the next block or the
# "Finished in" summary. Strip ANSI colours and encode newlines for the command.
sed -e 's/\x1b\[[0-9;]*m//g' "$log" | awk '
  function flush() {
    if (block != "") {
      gsub(/%/, "%25", block); gsub(/\r/, "%0D", block); gsub(/\n/, "%0A", block)
      printf "::error title=%s::%s\n", title, block
    }
    block = ""
  }
  /^ +[0-9]+\) / { flush(); title = $0; sub(/^ +/, "", title); gsub(/[:,]/, " ", title); block = $0; next }
  /^Finished in / { flush(); summary = 1 }
  block != "" { block = block "\n" $0 }
  summary && /[0-9]+ failures?/ { print "::error title=ExUnit summary::" $0; summary = 0 }
  END { flush() }
'
