#!/bin/bash
# Basic hygiene for a Mac VM that agents and CI jobs look at and drive (the QA VM, the CI runner's VM): nothing on
# its screen but what a test put there. Run it inside the VM, as its logged-in user; it is safe to run again.
#
#   - no notifications: a banner or a system dialog over a window hides what a screenshot should show and takes the
#     click meant for the app (TP-1474);
#   - no desktop widgets or icons, and a plain grey desktop;
#   - no Dock in the way: it hides, and comes back only after a very long hover;
#   - apps and windows are not reopened at login, so a restart starts from an empty screen;
#   - a screen large enough for the app (1920x1200, or VM_SCREEN);
#   - the screen never sleeps or locks.
# The menu bar stays: the app under test lives in it.
set -u
uid=$(id -u)

echo "== notifications off"
for label in com.apple.notificationcenterui com.apple.notificationcenterui.agent com.apple.usernoted; do
  launchctl disable "gui/$uid/$label"
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
done
killall NotificationCenter usernoted 2>/dev/null || true

echo "== a plain desktop"
defaults write com.apple.WindowManager StandardHideWidgets -int 1
defaults write com.apple.WindowManager StageManagerHideWidgets -int 1
defaults write com.apple.WindowManager StandardHideDesktopIcons -int 1
defaults write com.apple.finder CreateDesktop -bool false
grey="/System/Library/Desktop Pictures/Solid Colors/Stone.png"
[ -f "$grey" ] || grey=$(ls "/System/Library/Desktop Pictures/Solid Colors/"*.png 2>/dev/null | grep -i -m1 "gr[ae]y\|stone\|silver" || true)
if [ -n "$grey" ]; then osascript -e "tell application \"System Events\" to tell every desktop to set picture to \"$grey\"" >/dev/null 2>&1 || true; fi

echo "== the Dock out of the way"
defaults write com.apple.dock autohide -bool true
defaults write com.apple.dock autohide-delay -float 1000
defaults write com.apple.dock show-recents -bool false
defaults write com.apple.dock launchanim -bool false

echo "== nothing reopened at login"
defaults write com.apple.loginwindow TALLogoutSavesState -bool false
defaults write com.apple.loginwindow LoginwindowLaunchesRelaunchApps -bool false
defaults write -g NSQuitAlwaysKeepsWindows -bool false
rm -rf "$HOME/Library/Saved Application State/"*.savedState 2>/dev/null || true
pkill -x Terminal 2>/dev/null || true

echo "== a screen of ${VM_SCREEN:=1920x1200}"
# The VM tool sizes the display it offers (`tart set <vm> --display`), but the guest keeps the mode it last used, and a
# fresh image starts at 1024x768: smaller than the app's laptop size. The mode is chosen here, at two pixels a
# point as a Mac's own display has: at one, text and hairlines are soft, and a fault of half a point cannot be seen.
export PATH="/opt/homebrew/bin:$PATH"
command -v displayplacer >/dev/null || brew install -q displayplacer >/dev/null 2>&1 || true
if command -v displayplacer >/dev/null; then
  screen=$(displayplacer list | awk '/Persistent screen id/{print $4; exit}')
  displayplacer "id:$screen res:$VM_SCREEN hz:60 color_depth:7 scaling:on" >/dev/null 2>&1 \
    || echo "!! the display offers no $VM_SCREEN mode: set it on the host (tart set <vm> --display $VM_SCREEN) and restart the VM"
else
  echo "!! displayplacer is not installed; the screen keeps its size"
fi

echo "== the screen stays on"
defaults -currentHost write com.apple.screensaver idleTime -int 0
sudo -n pmset -a displaysleep 0 sleep 0 2>/dev/null || true
defaults write com.apple.screensaver askForPassword -int 0

killall WindowManager Dock Finder 2>/dev/null || true
sleep 2
pgrep -x NotificationCenter >/dev/null && echo "!! NotificationCenter is still running" || echo "hygiene: done"
