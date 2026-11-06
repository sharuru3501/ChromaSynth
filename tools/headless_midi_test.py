#!/usr/bin/env python3
"""MIDI input test using PyBoy (pip install pyboy pillow). Run `make` first.

The emulator has no link-port input, so MIDI bytes are pushed straight into the
serial RX ring buffer (what the serial ISR would have done). Covers: routing by
MIDI channel assignment, polyphony by assigning several GB channels to one MIDI
channel, velocity, mod wheel (CC1), all-notes-off (CC123/CC120) and the settings
page of the edit screen.
"""
import pathlib
import re
import shutil
import sys
import tempfile

from pyboy import PyBoy

root = pathlib.Path(__file__).resolve().parent.parent
rom_src = root / "build/chromasynth.gb"

sym = {}
for line in (root / "build/chromasynth.sym").read_text().splitlines():
    m = re.match(r"([0-9A-Fa-f]{2}):([0-9A-Fa-f]{4}) (\S+)", line)
    if m:
        sym[m.group(3)] = int(m.group(2), 16)

fails = 0


def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail != "" else ""))
    fails += not cond


tmp = tempfile.mkdtemp()
rom = pathlib.Path(tmp) / "t.gb"
shutil.copy(rom_src, rom)
pb = PyBoy(str(rom), window="null", sound_emulated=False)
mem = pb.memory
for _ in range(2000):
    pb.tick(1)
    if pb.register_file.PC >= 0x100:
        break
pb.tick(100)  # boot beep over


def v(name):
    return mem[sym[name]]


def cur(ch):
    return mem[sym["wCurNote"] + ch]


def vol(ch):
    return mem[sym["wVoiceVol"] + ch]


def midi(*bytes_):
    for b in bytes_:
        head = mem[sym["wRingHead"]]
        mem[sym["wRing"] + head] = b
        mem[sym["wRingHead"]] = (head + 1) & 0xFF
    pb.tick(3)


def press(btn, frames=4):
    pb.button_press(btn)
    pb.tick(frames)
    pb.button_release(btn)
    pb.tick(3)


MB = sym["wPatch"] + 32  # MIDI settings block: 4 listen channels, bend, velocity, mod wheel


def reset_midi_block(vals=(1, 2, 3, 4, 2, 1, 1, 0)):
    for i, x in enumerate(vals):
        mem[MB + i] = x
    for c in range(4):
        mem[sym["wMod"] + c] = 0
        if cur(c):
            midi(0xB0 | c, 123, 0)
    pb.tick(3)


check("defaults: CH1-4 listen to MIDI 1-4, velocity on, mod wheel on",
      [mem[MB + i] for i in range(7)] == [1, 2, 3, 4, 2, 1, 1], [mem[MB + i] for i in range(7)])

# ---- the settings page on the edit screen (UI)
press("start")                      # play -> edit
for _ in range(4):
    press("select")                 # CH1 -> ... -> CH4 -> MIDI page
check("edit screen: 5th page is the MIDI settings", (v("wScreen"), v("wSelCh")) == (1, 4), (v("wScreen"), v("wSelCh")))
press("down")
press("down")
check("row 2 (CH3) selected, row 4 hidden is skipped", v("wEditRow") == 2)
press("up")
press("left")
check("CH2 now listens to MIDI 1 (edited with LEFT)", mem[MB + 1] == 1, mem[MB + 1])
press("up")
for _ in range(20):
    press("right", frames=2)
check("MIDI channel value is clamped at 16", mem[MB] == 16, mem[MB])
for _ in range(20):
    press("left", frames=2)
check("...and at 0 (off)", mem[MB] == 0, mem[MB])
press("right")
check("back to MIDI 1", mem[MB] == 1)
press("down")
press("down")
press("down")
press("down")
check("rows 4 (hidden) skipped on the way down: VELO then MODW", v("wEditRow") in (5, 6), v("wEditRow"))

# ---- polyphony: CH1 and CH2 both listen to MIDI channel 1
check("CH1 and CH2 both on MIDI 1", mem[MB] == 1 and mem[MB + 1] == 1)
midi(0x90, 60, 100)
check("note 1 -> CH1 (first idle channel)", (cur(0), cur(1)) == (60, 0), (cur(0), cur(1)))
midi(0x90, 64, 100)
check("note 2 -> CH2 (the other idle channel): a two-note chord", (cur(0), cur(1)) == (60, 64), (cur(0), cur(1)))
midi(0x90, 67, 100)
check("note 3: no idle channel -> steals CH2 (round robin starts after CH1)", (cur(0), cur(1)) == (60, 67), (cur(0), cur(1)))
midi(0x90, 69, 100)
check("note 4: steals CH1 next", (cur(0), cur(1)) == (69, 67), (cur(0), cur(1)))
midi(0x90, 67, 100)
check("re-striking a sounding note reuses its channel (no steal)", (cur(0), cur(1)) == (69, 67))
midi(0x80, 60, 0)
check("note off for a note nobody plays is ignored", (cur(0), cur(1)) == (69, 67))
midi(0x80, 69, 0)
check("note off releases only the channel that plays it", (cur(0), cur(1)) == (0, 67), (cur(0), cur(1)))
midi(0x90, 67, 0)
check("note on with velocity 0 releases the other voice", (cur(0), cur(1)) == (0, 0), (cur(0), cur(1)))

# ---- channels that are not listening / listening to something else
reset_midi_block()
midi(0x99, 60, 100)
check("MIDI channel 10 (nobody listens): ignored", [cur(c) for c in range(4)] == [0, 0, 0, 0])
mem[MB] = 0
midi(0x90, 60, 100)
check("a GB channel set to 0 (off) does not play", cur(0) == 0, cur(0))
mem[MB] = 5
midi(0x94, 60, 100)
check("a GB channel can listen to any MIDI channel (5)", cur(0) == 60, cur(0))
midi(0x80 | 4, 60, 0)
reset_midi_block()

# ---- velocity
midi(0x90, 60, 127)
check("velocity 127: full volume (15)", vol(0) == 15, vol(0))
midi(0x90, 60, 64)
check("velocity 64: about half (8)", vol(0) == 8, vol(0))
midi(0x90, 60, 1)
check("velocity 1: quiet but never silent (1)", vol(0) == 1, vol(0))
midi(0x93, 70, 64)
check("velocity also scales the noise channel (8)", vol(3) == 8, vol(3))
midi(0x92, 48, 127)
check("wave channel, loud: patch level kept (0)", vol(2) == 0, vol(2))
midi(0x92, 48, 70)
check("wave channel, medium velocity: one level quieter (1)", vol(2) == 1, vol(2))
midi(0x92, 48, 20)
check("wave channel, soft: two levels quieter (2)", vol(2) == 2, vol(2))
mem[MB + 5] = 0                     # velocity sensitivity off
midi(0x90, 60, 1)
check("velocity off: velocity is ignored (15)", vol(0) == 15, vol(0))
mem[MB + 5] = 1
reset_midi_block()
check("after a MIDI note the next pad/sequencer note is full velocity again", v("wNoteVel") == 127, v("wNoteVel"))

# ---- mod wheel (CC1) raises the vibrato depth of the channels on that MIDI channel
base_depth = mem[sym["wPatch"] + 6]
check("patch vibrato depth starts at 0", base_depth == 0, base_depth)
midi(0x90, 69, 100)                 # A4, period 1750
base = mem[sym["wBase"]] | (mem[sym["wBase"] + 1] << 8)
midi(0xB0, 1, 127)
check("CC1 127 -> vibrato depth 7 on CH1", mem[sym["wMod"]] == 7, mem[sym["wMod"]])
check("...and not on CH2 (other MIDI channel)", mem[sym["wMod"] + 1] == 0)
seen = []
for _ in range(60):
    pb.tick(1)
    seen.append(mem[sym["wOut"]] | (mem[sym["wOut"] + 1] << 8))
check("the mod wheel makes the pitch oscillate around the note", min(seen) < base < max(seen), (base, min(seen), max(seen)))
midi(0xB0, 1, 0)
check("CC1 0 -> depth back to 0", mem[sym["wMod"]] == 0)
before = mem[sym["wOut"]] | (mem[sym["wOut"] + 1] << 8)
pb.tick(30)
after = mem[sym["wOut"]] | (mem[sym["wOut"] + 1] << 8)
check("vibrato stops updating at depth 0", before == after)
mem[MB + 6] = 0                     # mod wheel disabled
midi(0xB0, 1, 127)
check("mod wheel disabled in the settings: CC1 ignored", mem[sym["wMod"]] == 0, mem[sym["wMod"]])
mem[MB + 6] = 1
midi(0x80, 69, 0)

# ---- all notes off
mem[MB + 1] = 1
midi(0x90, 60, 100)
midi(0x90, 64, 100)
midi(0x92, 48, 100)                 # CH3 on MIDI channel 3
check("two voices on MIDI 1 and one on MIDI 3", (cur(0), cur(1), cur(2)) == (60, 64, 48), (cur(0), cur(1), cur(2)))
midi(0xB0, 123, 0)
check("CC123 on MIDI 1: releases CH1 and CH2 only", (cur(0), cur(1), cur(2)) == (0, 0, 48), (cur(0), cur(1), cur(2)))
midi(0xB2, 120, 0)
check("CC120 on MIDI 3: releases CH3", cur(2) == 0)
midi(0x90, 60, 100)
midi(0xB4, 123, 0)
check("all-notes-off on another MIDI channel does nothing", cur(0) == 60 or cur(1) == 60, (cur(0), cur(1)))
midi(0xB0, 123, 0)

# ---- other messages must not disturb the parser
midi(0xB0, 7, 100)                  # CC7: ignored
midi(0xE0, 0, 64)                   # pitch bend (not handled yet): ignored cleanly
midi(0xC0, 5)                       # program change: one data byte
midi(0x90, 62, 100)
check("unhandled messages are skipped without upsetting running status", cur(0) == 62 or cur(1) == 62, (cur(0), cur(1)))

pb.stop(save=False)
print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
