#!/bin/zsh
# Build the CLI + menu bar app and package the latter as FanControl.app
set -euo pipefail
ROOT="${0:A:h}"
cd "$ROOT"

echo "Building (release)…"
swift build -c release

BIN="$ROOT/.build/release"
APP="$ROOT/FanControl.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# The GUI invokes the bundled `fan` helper for privileged writes, so ship both.
cp "$BIN/FanControlApp" "$APP/Contents/MacOS/FanControl"
cp "$BIN/fan"           "$APP/Contents/MacOS/fan"

# App icon (used in Finder / Applications / Login Items).
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>FanControl</string>
  <key>CFBundleDisplayName</key><string>Fan Control</string>
  <key>CFBundleIdentifier</key><string>local.fancontrol</string>
  <key>CFBundleVersion</key><string>1.0</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleExecutable</key><string>FanControl</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc sign so the local launch is clean.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built: $APP"
echo "Launch:  open \"$APP\""
echo "CLI:     $BIN/fan status"
