#!/bin/sh
# The `gh` scripts/qa-server-start.sh puts first on the QA server's PATH: it answers for the seed's
# own pull requests (https://github.com/symphony-qa/seed/pull/<n>, priv/qa_seed/symphony/) as an
# open PR with no comments that closes when asked, so a Director move that reads or closes a
# ticket's PR (Restart) runs to its end, and refuses every other call. The QA server reaches no
# GitHub.
case "$*" in
  *github.com/symphony-qa/seed/pull/* | *repos/symphony-qa/seed/pulls/*) ;;
  *)
    echo "gh: the QA server reaches no GitHub" >&2
    exit 1
    ;;
esac

if [ "${1:-} ${2:-}" = "pr view" ]; then
  url=$3 number=${3##*/}
  printf '{"id":"PR_qa_seed_%s","number":%s,"state":"OPEN","url":"%s","title":"QA seed pull request %s","body":"","author":{"login":"symphony-qa"},"headRefName":"qa-seed","baseRefName":"main","comments":[],"reviews":[]}\n' \
    "$number" "$number" "$url" "$number"
  exit 0
fi

case "$*" in
  */comments*) echo '[]' ;;
  *) echo '{}' ;;
esac
