#!/bin/sh
# Installs Ubuntu packages on a CI runner, retrying the package index refresh and the install
# together, so a mirror or DNS outage of a few minutes is absorbed by the step instead of failing
# the job. Each attempt is printed; the script fails only after the last one.
#
# Usage: scripts/ci/apt-install.sh PACKAGE...
# Runs apt-get through sudo when not root. APT_INSTALL_ATTEMPTS (default 5) and
# APT_INSTALL_PAUSE (seconds between attempts, default 10) are for its test.
set -eu

if [ $# -eq 0 ]; then
  echo "usage: $0 PACKAGE..." >&2
  exit 2
fi

attempts="${APT_INSTALL_ATTEMPTS:-5}"
pause="${APT_INSTALL_PAUSE:-10}"
sudo=""
[ "$(id -u)" -eq 0 ] || sudo="sudo"

attempt=1
while :; do
  echo "apt-install: attempt $attempt of $attempts: $*"
  if $sudo apt-get update && $sudo apt-get install -y --no-install-recommends "$@"; then
    echo "apt-install: installed on attempt $attempt"
    exit 0
  fi
  if [ "$attempt" -ge "$attempts" ]; then
    echo "apt-install: gave up after $attempts attempts: $*" >&2
    exit 1
  fi
  echo "apt-install: attempt $attempt failed; retrying in ${pause}s"
  sleep "$pause"
  attempt=$((attempt + 1))
done
