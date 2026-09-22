#!/bin/bash
# Builds AgentIsland.app: a menu-bar-only app bundle with the hook forwarder inside.
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIGURATION="${1:-release}"
APP="build/AgentIsland.app"

echo "Building ($CONFIGURATION)..."
swift build -c "$CONFIGURATION" --product AgentIsland
swift build -c "$CONFIGURATION" --product agent-island-hook
BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/AgentIsland" "$APP/Contents/MacOS/AgentIsland"
cp "$BIN_DIR/agent-island-hook" "$APP/Contents/MacOS/agent-island-hook"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Agent Island</string>
    <key>CFBundleDisplayName</key>
    <string>Agent Island</string>
    <key>CFBundleIdentifier</key>
    <string>com.agentisland.app</string>
    <key>CFBundleExecutable</key>
    <string>AgentIsland</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>26.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/agent-island-hook"
codesign --force --sign - --timestamp=none "$APP"

echo "Built $APP"
echo "Run it with:  open $APP"
echo "Demo mode:    open $APP --args --demo"
