#!/bin/bash
# Builds build/ChromaSynthLink.app (needs the Xcode command line tools: swiftc). The app has no Dock icon (menu bar only).
set -euo pipefail
cd "$(dirname "$0")/../.."
APP=build/ChromaSynthLink.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O tools/mac/chromasynth-link/Core.swift tools/mac/chromasynth-link/main.swift -o "$APP/Contents/MacOS/ChromaSynthLink"
cat > "$APP/Contents/Info.plist" <<'P'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>ChromaSynth Link</string>
  <key>CFBundleIdentifier</key><string>io.github.sharuru3501.chromasynth-link</string>
  <key>CFBundleExecutable</key><string>ChromaSynthLink</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>ChromaSynth Link connects to the Chromatic over Bluetooth MIDI to play it from your DAW.</string>
</dict></plist>
P
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $APP  (open it, or: open $APP)"
