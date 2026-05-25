#!/usr/bin/env bash
# Build SimConsole.app: a real macOS .app bundle wrapping the SwiftUI dev
# console. The .app lets users open it from Spotlight / Dock / Finder, picks
# up a normal titled-window chrome, and works for both
# attached-to-the-sim-window mode and detached USB-device mode.
#
# Output layout:
#   Tools/SimConsole.app/
#     Contents/
#       Info.plist
#       MacOS/SimConsole          ← Mach-O built from sim-console.swift
#       PkgInfo
set -euo pipefail
cd "$(dirname "$0")"

APP="SimConsole.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
EXE="$MACOS/SimConsole"

rm -rf "$APP"
mkdir -p "$MACOS"

# Compile straight into the .app's MacOS dir.
swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework Cocoa \
  -framework SwiftUI \
  -framework ApplicationServices \
  -o "$EXE" \
  sim-console.swift

# Info.plist. Bundle id is stable so the macOS Accessibility / TCC databases
# don't lose their grant whenever the binary is rebuilt.
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>SimConsole</string>
    <key>CFBundleIdentifier</key>
    <string>com.simconsole.SimConsole</string>
    <key>CFBundleName</key>
    <string>SimConsole</string>
    <key>CFBundleDisplayName</key>
    <string>SimConsole</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <!-- The app drops into the Dock and Spotlight (LSUIElement absent / false). -->
    <key>NSHumanReadableCopyright</key>
    <string>SimConsole — live structured-log overlay for iOS / Android.</string>
</dict>
</plist>
PLIST

# PkgInfo — required for older Spotlight/launchservices to recognize the bundle.
printf 'APPL????' > "$CONTENTS/PkgInfo"

# Ad-hoc signing so Gatekeeper doesn't quarantine the app on first launch.
codesign --force --sign - "$APP" 2>/dev/null || true

echo "✓ built $(pwd)/$APP"
