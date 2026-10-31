#!/bin/sh
# Swaps Symphony.app for a verified update once the app has quit, then relaunches it.
#
# Usage: update-helper.sh PID CURRENT_APP NEW_APP PREVIOUS_APP [STATE_DIR ROLLED_BACK_APP]
#
#   PID              the app that is quitting; nothing moves until it has exited
#   CURRENT_APP      the installed app, kept as PREVIOUS_APP for a manual rollback
#   NEW_APP          the downloaded and verified app, moved to CURRENT_APP
#   PREVIOUS_APP     replaced; an older copy there is restored if the swap fails
#   STATE_DIR        where the relaunched app writes `launched` once it runs
#   ROLLED_BACK_APP  where the new app goes when it doesn't start
#
# If a move fails, the old app is put back. Either way the app at CURRENT_APP
# is relaunched. The app copies this script out of its bundle and runs it
# detached, so moving the bundle doesn't pull it from under itself.
#
# With STATE_DIR and ROLLED_BACK_APP, as an update passes them, the helper
# watches the relaunch: the new app must write STATE_DIR/launched within
# SYMPHONY_UPDATE_LAUNCH_SECONDS. When it doesn't, whatever runs from the new
# app is killed, the new app moves to ROLLED_BACK_APP, PREVIOUS_APP is put back,
# STATE_DIR/launch-failed tells the restored app why, and the restored app is
# relaunched. So an update never leaves nothing running.
#
# A rollback, after an update fails its health check, runs the same swap with
# the previous app as NEW_APP and "Symphony (rolled back).app" as PREVIOUS_APP:
# the build that failed moves out of the way, the previous one moves back into
# place and is relaunched, and the previous slot is left empty.
#
# In QA mode (SYMPHONY_BAR_QA_ROOT set, see macos/README.md) the app passes its
# environment on, and the helper runs the app's binary directly instead of
# `open`, which would start it without that environment, outside QA mode.
#
# Optional environment, for tests:
#   SYMPHONY_UPDATE_OPEN          relaunch command, one executable (default /usr/bin/open)
#   SYMPHONY_UPDATE_WAIT_SECONDS  how long to wait for PID (default 120)
#   SYMPHONY_UPDATE_LAUNCH_SECONDS  how long the relaunched app has to start (default 30)
set -u

if [ $# -ne 4 ] && [ $# -ne 6 ]; then
  echo "usage: $0 PID CURRENT_APP NEW_APP PREVIOUS_APP [STATE_DIR ROLLED_BACK_APP]" >&2
  exit 2
fi

pid="$1"
current="$2"
new="$3"
previous="$4"
state="${5:-}"
rolled_back="${6:-}"
open_command="${SYMPHONY_UPDATE_OPEN:-/usr/bin/open}"
wait_seconds="${SYMPHONY_UPDATE_WAIT_SECONDS:-120}"
launch_seconds="${SYMPHONY_UPDATE_LAUNCH_SECONDS:-30}"

# The same format as the app's lines in the update log, which this output is appended to.
log() {
  echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) [helper] $*"
}

relaunch() {
  log "relaunching $current"
  if [ -n "${SYMPHONY_BAR_QA_ROOT:-}" ] && [ -z "${SYMPHONY_UPDATE_OPEN:-}" ]; then
    executable="$(plutil -extract CFBundleExecutable raw -o - "$current/Contents/Info.plist" 2> /dev/null)" ||
      executable=SymphonyBar
    nohup "$current/Contents/MacOS/$executable" > /dev/null 2>&1 &
    log "started $current/Contents/MacOS/$executable in QA mode as pid $!"
    return
  fi
  "$open_command" "$current" || log "couldn't relaunch $current: $open_command exited with $?"
}

# Waits up to launch_seconds for the relaunched app to write STATE_DIR/launched.
wait_for_launch() {
  waited=0
  while [ ! -e "$state/launched" ]; do
    if [ "$waited" -ge "$launch_seconds" ]; then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "$current started after ${waited}s"
}

# Kills every process running an executable from inside the app at $1, such as a launch that hung.
kill_app() {
  ps -axo pid=,command= | while read -r app_pid command; do
    case "$command" in
      "$1/Contents/MacOS/"*)
        log "stopping pid $app_pid, which runs from $1"
        kill -9 "$app_pid" 2> /dev/null
        ;;
    esac
  done
}

# Relaunches the app at CURRENT_APP and, for an update, puts the previous app back when the new one doesn't start.
relaunch_watched() {
  if [ -z "$state" ]; then
    relaunch
    return 0
  fi
  rm -f "$state/launched" "$state/launch-failed"
  relaunch
  wait_for_launch && return 0

  log "$current didn't start within ${launch_seconds}s; putting $previous back"
  kill_app "$current"
  if [ ! -d "$previous" ]; then
    log "there is no $previous to put back; relaunching $current again"
    relaunch
    return 1
  fi
  if [ -e "$rolled_back" ] && ! rm -rf "$rolled_back"; then
    log "couldn't remove the older $rolled_back"
  fi
  if ! mv "$current" "$rolled_back"; then
    log "couldn't move $current to $rolled_back; relaunching it again"
    relaunch
    return 1
  fi
  if ! mv "$previous" "$current"; then
    log "couldn't move $previous to $current; putting the new app back and relaunching it"
    mv "$rolled_back" "$current" || log "couldn't put the new app back; it is at $rolled_back"
    relaunch
    return 1
  fi
  echo "$launch_seconds" > "$state/launch-failed" || log "couldn't write $state/launch-failed"
  log "rolled back: the new app is at $rolled_back"
  relaunch
  wait_for_launch || log "the restored $current didn't start within ${launch_seconds}s either"
  return 1
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
relaunch_watched
