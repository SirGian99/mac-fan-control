#!/bin/zsh
# Install FanControl.app as a per-user login item via a LaunchAgent.
set -euo pipefail
LABEL="local.fancontrol"
APP="/Applications/FanControl.app"
EXE="$APP/Contents/MacOS/FanControl"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ ! -x "$EXE" ]]; then
  echo "FanControl not found at $APP"
  echo "Build it (./build-app.sh) and copy it to /Applications first."
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$EXE</string></array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PL

UID_=$(id -u)
# Stop any running instance and unload a previous agent, then (re)load.
pkill -f "$EXE" 2>/dev/null || true
launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "gui/$UID_" "$PLIST" 2>/dev/null; then
  launchctl load -w "$PLIST"   # fallback for older launchctl semantics
fi
launchctl enable "gui/$UID_/$LABEL" 2>/dev/null || true

echo "Installed: $PLIST"
echo "FanControl will now launch automatically at every login."
