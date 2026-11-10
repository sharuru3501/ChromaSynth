#!/bin/bash
# Builds build/ChromaSynthLink.app (needs the Xcode command line tools: swiftc). The app has no Dock icon (menu bar only).
set -euo pipefail
cd "$(dirname "$0")/../.."
APP=build/ChromaSynthLink.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
SRC="tools/mac/chromasynth-link/Core.swift tools/mac/chromasynth-link/Latency.swift tools/mac/chromasynth-link/main.swift"
if [ "${UNIVERSAL:-0}" = 1 ]; then
  # for a release: one app for Intel and Apple silicon Macs (macOS 13 or later)
  swiftc -O -target x86_64-apple-macos13.0 $SRC -o build/ChromaSynthLink.x86_64
  swiftc -O -target arm64-apple-macos13.0 $SRC -o build/ChromaSynthLink.arm64
  lipo -create build/ChromaSynthLink.x86_64 build/ChromaSynthLink.arm64 -output "$APP/Contents/MacOS/ChromaSynthLink"
  rm -f build/ChromaSynthLink.x86_64 build/ChromaSynthLink.arm64
else
  swiftc -O $SRC -o "$APP/Contents/MacOS/ChromaSynthLink"
fi
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
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>ChromaSynth Link --latency listens to the Chromatic's headphone output (plugged into the audio input) to measure the delay.</string>
  <key>NSBluetoothAlwaysUsageDescription</key><string>ChromaSynth Link connects to the Chromatic over Bluetooth MIDI to play it from your DAW.</string>
</dict></plist>
P
codesign --force --sign - "$APP" 2>/dev/null || true
echo "built $APP  (open it, or: open $APP)"
