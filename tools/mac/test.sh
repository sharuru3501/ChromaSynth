#!/bin/bash
# ChromaSynth Link without hardware: its self test (MIDI bytes -> console lines, the flood guard, BLE MIDI packets).
set -euo pipefail
cd "$(dirname "$0")/../.."
tools/mac/build_app.sh > /dev/null
build/ChromaSynthLink.app/Contents/MacOS/ChromaSynthLink --selftest
# end to end: a virtual MIDI keyboard plays; the app (--dry-run) must print the console lines for its notes
swiftc -O tools/test_virtual_midi_keyboard.swift -o build/test_virtual_midi_keyboard
OUT=build/link_e2e.out
rm -f "$OUT"
build/ChromaSynthLink.app/Contents/MacOS/ChromaSynthLink --dry-run > "$OUT" 2>&1 &
PID=$!
sleep 2
DEST=ChromaSynth build/test_virtual_midi_keyboard > /dev/null
sleep 1
kill $PID 2>/dev/null || true
wait $PID 2>/dev/null || true
GOT=$(grep -E "^m " "$OUT")
WANT="m 90 3c 64
m 80 3c 00
m 90 40 5a
m b0 7b 00
m 90 43 50
m 80 43 00"
if [ "$GOT" = "$WANT" ]; then echo "PASS end to end: the notes of a MIDI keyboard became the right console lines"; else echo "FAIL end to end"; echo "$GOT"; exit 1; fi
