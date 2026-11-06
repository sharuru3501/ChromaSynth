#!/bin/bash
# End-to-end test of the wired-MIDI Mac helper without any hardware: a virtual MIDI keyboard (CoreMIDI) plays notes, the
# helper (--dry-run) must print the matching console lines. Needs swiftc and a Mac. Run: make check-usb-bridge
set -u
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O tools/chromasynth_usb_bridge.swift -o build/chromasynth_usb_bridge || exit 1
swiftc -O tools/test_virtual_midi_keyboard.swift -o build/test_virtual_midi_keyboard || exit 1
build/chromasynth_usb_bridge --selftest | grep -c PASS | sed 's/^/self test: PASS x/'
build/chromasynth_usb_bridge --selftest > /dev/null || { echo "FAIL: self test"; exit 1; }
OUT=build/usb_bridge_e2e.out
rm -f "$OUT"
build/chromasynth_usb_bridge --dry-run --input TestKbd > "$OUT" 2>&1 &
PID=$!
sleep 1
build/test_virtual_midi_keyboard > /dev/null
sleep 1
kill $PID 2>/dev/null
wait $PID 2>/dev/null
WANT="mode usb
m 90 3c 64
m 80 3c 00
m 90 40 5a
m b0 7b 00
m 90 43 50
m 80 43 00"
GOT=$(grep -E "^(mode|m ) ?" "$OUT" | grep -v "^mode off")
if [ "$GOT" = "$WANT" ] && grep -q "listening to: TestKbd" "$OUT"; then
    echo "PASS end to end: a keyboard that appeared later, and notes sent to the MIDI output ChromaSynth USB that the helper creates (what Live does), became the right console lines"
else
    echo "FAIL end to end"; echo "--- wanted"; echo "$WANT"; echo "--- got"; cat "$OUT"; exit 1
fi
