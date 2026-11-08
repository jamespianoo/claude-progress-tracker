#!/bin/bash
# Builds build/ClaudeSessionTracker.app (menu-bar only, no Dock icon). A bundle is needed for notifications.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP=build/ClaudeSessionTracker.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp .build/release/ClaudeSessionTracker "$APP/Contents/MacOS/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.jamesbeckwith.claude-session-tracker</string>
<key>CFBundleName</key><string>Claude Session Tracker</string>
<key>CFBundleExecutable</key><string>ClaudeSessionTracker</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP  (open it with: open $APP)"
