#!/bin/bash
# Starts the wired-MIDI helper (builds it first if needed). Leave it running while you play; Ctrl-C stops it and puts the
# Chromatic's ESP32 back to OFF (so it can light-sleep again). Arguments are passed on: --verbose, --input <name>, --list ...
# In Ableton Live: a track's MIDI To = "ChromaSynth USB", MIDI From = All Ins. The ChromaSynth ROM must be on its KEYBOARD screen.
cd "$(dirname "$0")/.." || exit 1
mkdir -p build
if [ ! -x build/chromasynth_usb_bridge ] || [ tools/chromasynth_usb_bridge.swift -nt build/chromasynth_usb_bridge ]; then
    echo "building the helper (needs the Xcode command line tools: swiftc)..."
    swiftc -O tools/chromasynth_usb_bridge.swift -o build/chromasynth_usb_bridge || exit 1
fi
exec build/chromasynth_usb_bridge "$@"
