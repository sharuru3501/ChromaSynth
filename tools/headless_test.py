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
for _ in range(30):  # init takes a few frames; wait for the beep to start
    pb.tick(1)
    if cur(0) == 72:
        break
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

# --- sequencer screen
def hold(*btns, frames=3):
    for b in btns:
        pb.button_press(b)
    pb.tick(frames)


def release(*btns, frames=2):
    for b in btns:
        pb.button_release(b)
    pb.tick(frames)


def tap_while(held, btn):
    """Press btn while `held` is down (a combo)."""
    pb.button_press(held)
    pb.tick(3)
    pb.button_press(btn)
    pb.tick(3)
    pb.button_release(btn)
    pb.tick(2)
    pb.button_release(held)
    pb.tick(3)


P = sym["wPattern"]
press("start")
pb.tick(4)
check("START -> sequencer screen", mem[sym["wScreen"]] == 2, mem[sym["wScreen"]])
shot("09_seq")
check("default pattern: CH1 step0 = C4, CH3 step0 = C3",
      mem[P] == 60 and mem[P + 32] == 48 and mem[P + 2] == 0xFF)
press("down")
check("DOWN moves cursor row", mem[sym["wSeqRow"]] == 1)
press("right")
check("RIGHT moves cursor channel", mem[sym["wSeqCh"]] == 1)
cell = P + 16 * 1 + 1
press("b")
check("B: empty -> OFF", mem[cell] == 0xFF, mem[cell])
press("b")
check("B: OFF -> empty", mem[cell] == 0, mem[cell])
hold("a", frames=4)
check("A inserts the current note", mem[cell] == 60, mem[cell])
check("A auditions on the cursor channel", cur(1) == 60, cur(1))
hold("up")
release("up")
check("A+UP: +1 semitone", mem[cell] == 61 and mem[sym["wSeqNote"]] == 61, mem[cell])
hold("left")
release("left")
check("A+LEFT: -1 octave", mem[cell] == 49, mem[cell])
release("a", frames=4)
check("A release stops the audition", cur(1) == 0, cur(1))
pb.tick(2)
shot("10_seq_edit")
press("b")
check("B on a note clears it", mem[cell] == 0, mem[cell])

tap_while("select", "up")
check("SELECT+UP: BPM 121", mem[sym["wBpm"]] == 121, mem[sym["wBpm"]])
tap_while("select", "left")
check("SELECT+LEFT: BPM 111", mem[sym["wBpm"]] == 111, mem[sym["wBpm"]])
check("SELECT combo did not change screen/channel", mem[sym["wScreen"]] == 2 and mem[sym["wSelCh"]] == 0)
mem[sym["wBpm"]] = 120

# playback: SELECT held, tap START
tap_while("select", "start")
check("SELECT+START starts playback", mem[sym["wSeqPlay"]] == 1)
check("still on the sequencer screen", mem[sym["wScreen"]] == 2)
steps = 0
last = mem[sym["wSeqStep"]]
bass = set()
for i in range(120):
    pb.tick(1)
    s_ = mem[sym["wSeqStep"]]
    if s_ != last:
        steps += 1
        last = s_
    bass.add(cur(2))
    if i == 30:
        shot("11_seq_playing")
check("tempo: 16 steps in 2 s at 120 BPM", 15 <= steps <= 17, steps)
check("bass notes triggered by the pattern", {48, 43} <= bass, sorted(bass))
check("hi-hat (CH4) triggered", cur(3) in (90, 100), cur(3))
tap_while("select", "start")
check("SELECT+START stops playback", mem[sym["wSeqPlay"]] == 0)
check("stop silences all channels", [cur(c) for c in range(4)] == [0, 0, 0, 0], [cur(c) for c in range(4)])

# tempo scales: 240 BPM -> twice as many steps
mem[sym["wBpm"]] = 240
tap_while("select", "start")
steps = 0
last = mem[sym["wSeqStep"]]
for _ in range(60):
    pb.tick(1)
    s_ = mem[sym["wSeqStep"]]
    if s_ != last:
        steps += 1
        last = s_
check("tempo: 16 steps in 1 s at 240 BPM", 15 <= steps <= 17, steps)
tap_while("select", "start")

press("start")
pb.tick(4)
check("START -> back to play screen", mem[sym["wScreen"]] == 0, mem[sym["wScreen"]])
pb.tick(20)
shot("12_play_again")

pb.stop(save=False)
print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
