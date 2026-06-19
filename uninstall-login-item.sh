#!/bin/zsh
# Remove the FanControl login item (LaunchAgent). Does not delete the app.
set -euo pipefail
LABEL="local.fancontrol"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_=$(id -u)

launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
launchctl unload -w "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "Removed login item ($LABEL). FanControl will no longer launch at login."
echo "(The app itself is untouched at /Applications/FanControl.app.)"
