#!/bin/sh
# Swaps Symphony.app for a verified update once the app has quit, then relaunches it.
#
# Usage: update-helper.sh PID CURRENT_APP NEW_APP PREVIOUS_APP
#
#   PID           the app that is quitting; nothing moves until it has exited
#   CURRENT_APP   the installed app, kept as PREVIOUS_APP for a manual rollback
#   NEW_APP       the downloaded and verified app, moved to CURRENT_APP
#   PREVIOUS_APP  replaced; an older copy there is restored if the swap fails
#
# If a move fails, the old app is put back. Either way the app at CURRENT_APP
# is relaunched. The app copies this script out of its bundle and runs it
# detached, so moving the bundle doesn't pull it from under itself.
#
# Optional environment, for tests:
#   SYMPHONY_UPDATE_OPEN          relaunch command (default /usr/bin/open)
#   SYMPHONY_UPDATE_WAIT_SECONDS  how long to wait for PID (default 120)
set -u

if [ $# -ne 4 ]; then
  echo "usage: $0 PID CURRENT_APP NEW_APP PREVIOUS_APP" >&2
  exit 2
fi

pid="$1"
current="$2"
new="$3"
previous="$4"
open_command="${SYMPHONY_UPDATE_OPEN:-/usr/bin/open}"
wait_seconds="${SYMPHONY_UPDATE_WAIT_SECONDS:-120}"

log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*"
}

relaunch() {
  log "relaunching $current"
  $open_command "$current" || log "couldn't relaunch $current"
}

log "updating $current from $new, waiting for pid $pid to exit"
waited=0
while kill -0 "$pid" 2> /dev/null; do
  if [ "$waited" -ge "$wait_seconds" ]; then
    log "pid $pid is still running after ${wait_seconds}s; nothing was changed"
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done

if [ ! -d "$new" ]; then
  log "$new is missing; nothing was changed"
  relaunch
  exit 1
fi

# Keep an older previous copy until the swap has worked, so a failure can restore it.
stash=""
if [ -e "$previous" ]; then
  stash="$previous.replaced.$$"
  if ! mv "$previous" "$stash"; then
    log "couldn't move the older $previous aside; nothing was changed"
    relaunch
    exit 1
  fi
fi

restore_stash() {
  if [ -n "$stash" ]; then
    mv "$stash" "$previous" || log "couldn't restore $previous from $stash"
  fi
}

if ! mv "$current" "$previous"; then
  log "couldn't move $current to $previous; nothing was changed"
  restore_stash
  relaunch
  exit 1
fi

if ! mv "$new" "$current"; then
  log "couldn't move $new to $current; putting the old app back"
  # A move across volumes copies, and may have left part of the new app behind.
  if [ -e "$current" ]; then
    rm -rf "$current"
  fi
  if ! mv "$previous" "$current"; then
    log "couldn't put the old app back; it is at $previous"
    exit 1
  fi
  restore_stash
  relaunch
  exit 1
fi

if [ -n "$stash" ]; then
  rm -rf "$stash"
fi
log "updated; the replaced app is at $previous"
relaunch
