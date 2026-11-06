#!/usr/bin/env python3
"""Headless ROM smoke test using PyBoy (pip install pyboy pillow).

Drives the joypad, injects MIDI bytes straight into the serial RX ring
(the emulator has no link input) and checks RAM state + saves screenshots.

usage: headless_test.py [rom] [screenshot_dir]
"""
import pathlib
import re
import sys

from pyboy import PyBoy

root = pathlib.Path(__file__).resolve().parent.parent
rom = sys.argv[1] if len(sys.argv) > 1 else str(root / "build/chromasynth.gb")
shots = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else None
if shots:
    shots.mkdir(parents=True, exist_ok=True)

# symbol table from rgblink -n
sym = {}
for line in (root / "build/chromasynth.sym").read_text().splitlines():
    m = re.match(r"([0-9A-Fa-f]{2}):([0-9A-Fa-f]{4}) (\S+)", line)
    if m:
        sym[m.group(3)] = int(m.group(2), 16)

pb = PyBoy(rom, window="null", sound_emulated=False)
mem = pb.memory
fails = 0


def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail != "" else ""))
    fails += not cond


def cur(ch):
    return mem[sym["wCurNote"] + ch]


def shot(name):
    if shots:
        pb.screen.image.resize((480, 432)).save(shots / f"{name}.png")


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


# PyBoy runs the real boot ROM first; wait until it hands over to the cartridge
for _ in range(2000):
    pb.tick(1)
    if pb.register_file.PC >= 0x100:
        break
pb.tick(3)
check("boot beep on CH1", cur(0) == 72, cur(0))
pb.tick(60)
check("boot beep released", cur(0) == 0, cur(0))
shot("01_boot")

# --- joypad
pb.button_press("a")
pb.tick(4)
check("A plays pad note on CH1", cur(0) == 60, cur(0))
shot("02_pad_a")
pb.button_release("a")
pb.tick(4)
check("A release stops CH1", cur(0) == 0)
press("up")
press("right")
check("pad note = 73", mem[sym["wJoyNote"]] == 73, mem[sym["wJoyNote"]])
press("down")
press("left")
check("pad note back to 60", mem[sym["wJoyNote"]] == 60)
press("select")
check("SELECT -> CH2", mem[sym["wSelCh"]] == 1)
pb.button_press("a")
pb.tick(4)
check("A plays on CH2", cur(1) == 60 and cur(0) == 0, (cur(0), cur(1)))
pb.button_release("a")
pb.tick(4)

# --- edit screen (CH2 rows: 0 DUTY 1 VOL 2 ENV, 3-5 hidden, 6 VIBD, 7 VIBS)
patch2 = sym["wPatch"] + 8
press("start")
pb.tick(4)
check("START -> edit screen", mem[sym["wScreen"]] == 1)
shot("04_edit_ch2")
press("down")
press("down")
press("down")
check("down skips hidden rows -> 6", mem[sym["wEditRow"]] == 6, mem[sym["wEditRow"]])
press("up")
check("up skips hidden rows -> 2", mem[sym["wEditRow"]] == 2, mem[sym["wEditRow"]])
press("left")
check("ENV clamped at 0", mem[patch2 + 2] == 0)
press("right")
press("right")
check("ENV -> 2", mem[patch2 + 2] == 2, mem[patch2 + 2])
press("up")
press("left")
check("VOL 15 -> 14", mem[patch2 + 1] == 14, mem[patch2 + 1])
press("right")
press("right")
check("VOL clamped at 15", mem[patch2 + 1] == 15, mem[patch2 + 1])
press("down")
press("down")
check("row 6 (VIBD)", mem[sym["wEditRow"]] == 6)
for _ in range(9):
    press("right")
check("VIBD clamped at 7", mem[patch2 + 6] == 7, mem[patch2 + 6])
pb.tick(10)
shot("05_edit_vib")
press("select")
check("SELECT in edit -> CH3, row 0", mem[sym["wSelCh"]] == 2 and mem[sym["wEditRow"]] == 0)
pb.tick(10)
shot("06_edit_ch3")
press("right")
check("CH3 wave -> 1", mem[sym["wPatch"] + 16] == 1, mem[sym["wPatch"] + 16])
press("select")
press("select")
check("SELECT wraps to CH1", mem[sym["wSelCh"]] == 0)
pb.tick(10)
shot("07_edit_ch1")

# --- MIDI
midi(0x90, 64, 100)
check("MIDI ch1 note on", cur(0) == 64, cur(0))
midi(0x92, 48, 100)
check("MIDI ch3 (wave) note on", cur(2) == 48, cur(2))
midi(0x93, 80, 1)
check("MIDI ch4 (noise) note on", cur(3) == 80, cur(3))
midi(0x80, 64, 0)
check("MIDI note off", cur(0) == 0)
midi(0x90, 60, 100, 62, 100)  # running status: second note replaces first (mono)
check("running status", cur(0) == 62, cur(0))
midi(0x90, 62, 0)
check("note on vel 0 == off", cur(0) == 0)
midi(0x94, 60, 100)
check("MIDI ch5 ignored", cur(0) == 0 and cur(1) == 0 and cur(2) == 48)
midi(0x90, 10, 100)
check("out-of-range note ignored", cur(0) == 0, cur(0))
midi(0xF8, 0xF8)
check("realtime bytes ignored", cur(0) == 0)
pb.tick(30)
shot("08_midi")

# --- vibrato: CH2 depth 7 at A4 (period 1750): output must oscillate around the base
midi(0x91, 69, 100)
base = mem[sym["wBase"] + 2] | (mem[sym["wBase"] + 3] << 8)
seen = []
for _ in range(60):
    pb.tick(1)
    seen.append(mem[sym["wOut"] + 2] | (mem[sym["wOut"] + 3] << 8))
check("vibrato base period = 1750", base == 1750, base)
check("vibrato oscillates both sides", min(seen) < base < max(seen), (min(seen), max(seen)))
check("vibrato depth bounded", max(seen) - base <= 10 and base - min(seen) <= 10, (min(seen), max(seen)))
midi(0x81, 69, 0)
mem[sym["wPatch"] + 8 + 6] = 0
midi(0x91, 69, 100)
pb.tick(1)
before = mem[sym["wOut"] + 2] | (mem[sym["wOut"] + 3] << 8)
pb.tick(20)
after = mem[sym["wOut"] + 2] | (mem[sym["wOut"] + 3] << 8)
check("depth 0 -> no vibrato updates", before == after)
midi(0x81, 69, 0)

press("start")
pb.tick(4)
check("START -> back to play screen", mem[sym["wScreen"]] == 0)
pb.tick(20)
shot("09_play_again")

pb.stop(save=False)
print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
