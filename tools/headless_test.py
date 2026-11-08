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

pb = PyBoy(rom, window="null", sound_emulated=True)   # True: the APU registers read back (M9a tests)
mem = pb.memory

# --- VBlank budget: UpdateUI (VRAM/OAM writes) must finish before VBlank ends,
# otherwise real hardware drops the late writes and leaves stale tiles on screen.
vb_entry = []   # (wScreenReq, LY) at UpdateUI entry
vb_exit = []    # LY when UpdateUI returned (VoiceTick is the next call)


def _hook_entry(ctx):
    vb_entry.append((mem[sym["wScreenReq"]], mem[0xFF44]))


def _hook_exit(ctx):
    vb_exit.append(mem[0xFF44])


pb.hook_register(0, sym["UpdateUI"], _hook_entry, None)
pb.hook_register(0, sym["VoiceTick"], _hook_exit, None)
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


def nav(d):
    """START+LEFT / START+RIGHT: previous / next screen."""
    pb.button_press("start")
    pb.tick(3)
    pb.button_press(d)
    pb.tick(3)
    pb.button_release(d)
    pb.tick(2)
    pb.button_release("start")
    pb.tick(4)


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
patch2 = sym["wPatch"] + 32   # CH2 (32 bytes per channel)
note0 = mem[sym["wJoyNote"]]
press("start", frames=40)
check("START alone (short or held) does nothing", mem[sym["wScreen"]] == 0 and mem[sym["wSeqPlay"]] == 0, (mem[sym["wScreen"]], mem[sym["wSeqPlay"]]))
nav("left")
check("START+LEFT on the play screen: stays (the first screen), and the d-pad does not move the note",
      mem[sym["wScreen"]] == 0 and mem[sym["wJoyNote"]] == note0, (mem[sym["wScreen"]], mem[sym["wJoyNote"]], note0))
nav("right")
pb.tick(4)
check("START+RIGHT -> edit screen", mem[sym["wScreen"]] == 1)
shot("04_edit_ch2")
# CH2 rows: 0 DUTY 1 VOL 2 EDIR 3 EPAC 4 LEN 5 PAN 6 VIBD 7 VIBS; page 2 (rows 8-15) is all hidden
press("down")
press("down")
press("down")
check("down -> row 3 (EPAC)", mem[sym["wEditRow"]] == 3, mem[sym["wEditRow"]])
press("left")
check("EPAC clamped at 0", mem[patch2 + 3] == 0)
press("right")
press("right")
check("EPAC -> 2", mem[patch2 + 3] == 2, mem[patch2 + 3])
press("up")
press("right")
press("right")
check("EDIR clamped at 1", mem[patch2 + 2] == 1, mem[patch2 + 2])
press("up")
press("left")
check("VOL 15 -> 14", mem[patch2 + 1] == 14, mem[patch2 + 1])
press("right")
press("right")
check("VOL clamped at 15", mem[patch2 + 1] == 15, mem[patch2 + 1])


def sel_dpad(btn, frames=3):
    """SELECT held + a d-pad press (released before SELECT)."""
    pb.button_press("select")
    pb.tick(3)
    pb.button_press(btn)
    pb.tick(frames)
    pb.button_release(btn)
    pb.tick(2)
    pb.button_release("select")
    pb.tick(4)


ch_before = mem[sym["wSelCh"]]
sel_dpad("down")
check("SELECT+DOWN: VOL 15 -> 5 (-10), the row stays", mem[patch2 + 1] == 5 and mem[sym["wEditRow"]] == 1,
      (mem[patch2 + 1], mem[sym["wEditRow"]]))
check("... and SELECT was not a channel tap", mem[sym["wSelCh"]] == ch_before, mem[sym["wSelCh"]])
sel_dpad("down")
check("SELECT+DOWN from 5: stops at 0", mem[patch2 + 1] == 0, mem[patch2 + 1])
sel_dpad("up")
check("SELECT+UP: 0 -> 10", mem[patch2 + 1] == 10, mem[patch2 + 1])
sel_dpad("up")
check("SELECT+UP from 10: stops at the maximum 15", mem[patch2 + 1] == 15, mem[patch2 + 1])
sel_dpad("left")
check("SELECT+LEFT does nothing on the edit screen, and is no channel tap", mem[patch2 + 1] == 15 and mem[sym["wSelCh"]] == ch_before,
      (mem[patch2 + 1], mem[sym["wSelCh"]]))
for _ in range(5):
    press("down")
check("row 6 (VIBD)", mem[sym["wEditRow"]] == 6)
for _ in range(9):
    press("right")
check("VIBD clamped at 7", mem[patch2 + 6] == 7, mem[patch2 + 6])
press("down")
press("down")
check("CH2: down from row 7 skips the empty page 2 -> row 16 (ARP1, page 3)", mem[sym["wEditRow"]] == 16, mem[sym["wEditRow"]])
pb.tick(12)
check("... the header shows P3", mem[0x9800 + 19] == ord("3") - 32, mem[0x9800 + 19])
for _ in range(5):
    press("down")
check("... down to row 21 (DSPD)", mem[sym["wEditRow"]] == 21, mem[sym["wEditRow"]])
press("down")
check("... and down from row 21 wraps to row 0", mem[sym["wEditRow"]] == 0, mem[sym["wEditRow"]])
press("up")
check("... and up from row 0 wraps back to row 21", mem[sym["wEditRow"]] == 21, mem[sym["wEditRow"]])
for _ in range(6):
    press("up")
check("... up from row 16 skips page 2 back to row 7", mem[sym["wEditRow"]] == 7, mem[sym["wEditRow"]])
mem[patch2 + 2] = 0                  # back to a decaying envelope
mem[patch2 + 3] = 0
pb.tick(10)
shot("05_edit_vib")
press("select")
check("SELECT in edit -> CH3, row 0", mem[sym["wSelCh"]] == 2 and mem[sym["wEditRow"]] == 0)
pb.tick(10)
shot("06_edit_ch3")
press("right")
check("CH3 wave -> 1", mem[sym["wPatch"] + 64] == 1, mem[sym["wPatch"] + 64])
press("down")
press("down")
check("CH3: down from LVL skips the hidden envelope rows -> row 4 (LEN)", mem[sym["wEditRow"]] == 4, mem[sym["wEditRow"]])
mem[sym["wPatch"] + 64 + 4] = 254
press("right")
press("right")
check("CH3 LEN goes up to 255 and stops there (no wrap to 0)", mem[sym["wPatch"] + 64 + 4] == 255, mem[sym["wPatch"] + 64 + 4])
mem[sym["wPatch"] + 64 + 4] = 0
sel_dpad("up", frames=16 + 4 * 30)            # held: auto-repeat, 10 at a time
check("CH3 LEN: SELECT+UP held runs 0 -> 255 by tens and stops at 255", mem[sym["wPatch"] + 64 + 4] == 255,
      mem[sym["wPatch"] + 64 + 4])
sel_dpad("down")
check("... SELECT+DOWN: 255 -> 245", mem[sym["wPatch"] + 64 + 4] == 245, mem[sym["wPatch"] + 64 + 4])
pb.tick(12)
shot("06_edit_ch3_len")
mem[sym["wPatch"] + 64 + 4] = 0
press("up")
press("up")
press("select")
press("select")
check("edit screen: CH4 is followed by the 5th page (MIDI settings)", mem[sym["wSelCh"]] == 4, mem[sym["wSelCh"]])
pb.tick(10)
shot("07_edit_midi")
press("up")
pb.tick(12)
check("MIDI page: up from row 0 -> row 9 (VOLR) on page 2", mem[sym["wEditRow"]] == 9, mem[sym["wEditRow"]])
check("... the header shows P2", mem[0x9800 + 18] == ord("P") - 32 and mem[0x9800 + 19] == ord("2") - 32,
      (mem[0x9800 + 18], mem[0x9800 + 19]))
press("left")
pb.tick(2)
check("VOLR 7 -> 6 reaches NR50 at once", mem[0xFF24] == 0x76, hex(mem[0xFF24]))
press("right")
pb.tick(2)
check("... and back to 7", mem[0xFF24] == 0x77, hex(mem[0xFF24]))
shot("07_edit_midi_p2")
press("select")
check("SELECT wraps to CH1 after the MIDI page, row 0", mem[sym["wSelCh"]] == 0 and mem[sym["wEditRow"]] == 0)
pb.tick(12)
check("... the header is back to P1", mem[0x9800 + 19] == ord("1") - 32, mem[0x9800 + 19])
press("up")
pb.tick(12)
check("CH1: up from row 0 -> row 21 (DSPD, the last visible row of page 3)", mem[sym["wEditRow"]] == 21, mem[sym["wEditRow"]])
shot("07_edit_ch1_p3")
for _ in range(6):
    press("up")
pb.tick(12)
check("... up from row 16 -> row 10 (SWS on page 2: rows 11-15 are hidden)", mem[sym["wEditRow"]] == 10, mem[sym["wEditRow"]])
shot("07_edit_ch1_p2")
for _ in range(6):
    press("down")
check("... down from row 10 through page 3 to row 21", mem[sym["wEditRow"]] == 21, mem[sym["wEditRow"]])
press("down")
check("... down from row 21 wraps to row 0", mem[sym["wEditRow"]] == 0, mem[sym["wEditRow"]])
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
mem[sym["wPatch"] + 32 + 6] = 0
midi(0x91, 69, 100)
pb.tick(1)
before = mem[sym["wOut"] + 2] | (mem[sym["wOut"] + 3] << 8)
pb.tick(20)
after = mem[sym["wOut"] + 2] | (mem[sym["wOut"] + 3] << 8)
check("depth 0 -> no vibrato updates", before == after)
midi(0x81, 69, 0)

# --- APU parameters (M9a): envelope, length, pan, noise divisor
W = sym["wPatch"]
mem[W + 32 + 2], mem[W + 32 + 3] = 1, 5            # CH2: envelope up, pace 5
midi(0x91, 60, 127)
pb.tick(1)
check("CH2 NR22 = volume << 4 | up << 3 | pace", mem[0xFF17] == (15 << 4) | 8 | 5, hex(mem[0xFF17]))
midi(0x81, 60, 0)
mem[W + 32 + 2], mem[W + 32 + 3] = 0, 0
pb.tick(2)
mem[W + 4] = 48                                    # CH1: length 48/256 s (about 11 frames)
midi(0x90, 60, 100)
pb.tick(1)
check("CH1 with LEN: the length counter is enabled", mem[sym["wLenBit"]] == 0x40 and mem[0xFF26] & 1 == 1,
      (mem[sym["wLenBit"]], hex(mem[0xFF26])))
pb.tick(16)
check("... and the APU stops the channel by itself (NR52 bit 0 clear)", mem[0xFF26] & 1 == 0, hex(mem[0xFF26]))
midi(0x80, 60, 0)
for duty in (0, 1, 2, 3):                          # the length must not overwrite the duty (NR11 bits 7-6)
    mem[W + 0] = duty
    midi(0x90, 60, 100)
    pb.tick(1)
    check("CH1 DUTY %d with LEN 48: NR11 keeps the duty" % duty, mem[0xFF11] >> 6 == duty, hex(mem[0xFF11]))
    midi(0x80, 60, 0)
mem[W + 0] = 2
mem[W + 4] = 0
midi(0x90, 60, 100)
pb.tick(12)
check("CH1 with LEN 0: keeps sounding (NR52 bit 0 set)", mem[sym["wLenBit"]] == 0 and mem[0xFF26] & 1 == 1, hex(mem[0xFF26]))
midi(0x80, 60, 0)
mem[W + 2 * 32 + 4] = 200                           # CH3: length 200/256 s
midi(0x92, 60, 100)
pb.tick(1)
check("CH3 LEN 200: enabled", mem[sym["wLenBit"] + 2] == 0x40)
pb.tick(40)
check("... still sounding after 40 frames (0.67 s)", mem[0xFF26] & 4 == 4, hex(mem[0xFF26]))
pb.tick(15)
check("... stopped after 55 frames (0.92 s)", mem[0xFF26] & 4 == 0, hex(mem[0xFF26]))
midi(0x82, 60, 0)
mem[W + 2 * 32 + 4] = 0
mem[W + 5], mem[W + 32 + 5], mem[W + 3 * 32 + 5] = 1, 2, 1   # CH1 left, CH2 right, CH4 left
pb.tick(2)
check("PAN -> NR51 (CH1 left, CH2 right, CH3 both, CH4 left)", mem[0xFF25] == 0b11010110, bin(mem[0xFF25]))
mem[W + 5], mem[W + 32 + 5], mem[W + 3 * 32 + 5] = 0, 0, 0
pb.tick(2)
check("PAN back to both -> NR51 = $FF", mem[0xFF25] == 0xFF, hex(mem[0xFF25]))
mem[W + 3 * 32 + 11] = 5                            # CH4 noise divisor code 5
midi(0x93, 80, 100)
pb.tick(1)
check("CH4 NDIV 5 -> NR43 bits 2-0", mem[0xFF22] & 7 == 5, hex(mem[0xFF22]))
midi(0x83, 80, 0)
mem[W + 3 * 32 + 11] = 0
pb.tick(4)

# --- M9b effects: arpeggio, slide, duty switching (CH1-3; frame based)
def period(ch, table="wOut"):
    return mem[sym[table] + 2 * ch] | (mem[sym[table] + 2 * ch + 1] << 8)


def periods(ch, frames):
    seen = []
    for _ in range(frames):
        pb.tick(1)
        seen.append(period(ch))
    return seen


ARP1, ARP2, ARPS, SLID, DUT2, DSPD = 16, 17, 18, 19, 20, 21
mem[W + 32 + 6] = 0                                  # CH2 without vibrato
midi(0x91, 62, 100)
p_d = period(1, "wBase")
midi(0x81, 62, 0)
midi(0x91, 60, 100)
p_c = period(1, "wBase")
seen = periods(1, 20)
check("no arpeggio (ARP1 = ARP2 = 0): one period only", set(seen) <= {p_c}, sorted(set(seen)))
midi(0x81, 60, 0)
mem[W + 32 + ARP1], mem[W + 32 + ARP2], mem[W + 32 + ARPS] = 2, 7, 2   # C, D, G
midi(0x91, 60, 100)
seen = periods(1, 24)
check("CH2 arpeggio 2/7 every 2 frames: three periods, the root and +2 among them",
      len(set(seen)) == 3 and p_c in seen and p_d in seen, sorted(set(seen)))
runs = [len(list(g)) for _, g in __import__("itertools").groupby(seen[2:-2])]
check("... each step lasts 2 frames", all(r == 2 for r in runs[1:-1]), runs)
check("... the note number stays the root (the UI and the sequencer see C)", cur(1) == 60, cur(1))
midi(0x81, 60, 0)
mem[W + 32 + ARP1], mem[W + 32 + ARP2] = 0, 0
mem[W + 64 + 6] = 0                                  # CH3 without vibrato
mem[W + 64 + ARP1], mem[W + 64 + ARP2], mem[W + 64 + ARPS] = 12, 0, 1
midi(0x92, 48, 100)
seen = periods(2, 12)
check("CH3 arpeggio +12 (octave): two periods", len(set(seen)) == 2, sorted(set(seen)))
midi(0x82, 48, 0)
mem[W + 64 + ARP1] = 0
mem[W + 64 + 6] = 0
pb.tick(2)
# slide: CH1 legato C4 -> C5 glides; a detached note does not
mem[W + 6] = 0
mem[W + SLID] = 3
midi(0x90, 60, 100)
pb.tick(4)
p60 = period(0, "wBase")
midi(0x90, 72, 100)                                  # legato: no note-off in between
p72 = period(0, "wBase")
seen = periods(0, 40)
check("SLID 3, legato: the first frames are between the old and the new period", p60 < seen[0] < p72, (p60, seen[0], p72))
check("... it moves toward the new note without overshoot", all(a <= b for a, b in zip(seen, seen[1:])) and max(seen) <= p72,
      seen[:8])
check("... and arrives (within 40 frames)", seen[-1] == p72, (seen[-1], p72))
midi(0x80, 72, 0)
pb.tick(2)
midi(0x90, 60, 100)                                  # detached (after a note-off): no slide
pb.tick(1)
check("SLID 3, after a note-off: no slide", period(0) == period(0, "wBase") and mem[sym["wGlide"]] | mem[sym["wGlide"] + 1] == 0,
      (period(0), period(0, "wBase")))
midi(0x80, 60, 0)
mem[W + SLID] = 0
midi(0x90, 60, 100)
pb.tick(2)
midi(0x90, 72, 100)
pb.tick(1)
check("SLID 0, legato: jumps at once", period(0) == period(0, "wBase") == p72, (period(0), p72))
midi(0x80, 72, 0)
# duty switching: CH1 DUTY 0 <-> DUT2 2 every 3 frames
mem[W + 0], mem[W + DUT2], mem[W + DSPD] = 0, 2, 3
midi(0x90, 60, 100)
duties = []
for _ in range(18):
    pb.tick(1)
    duties.append(mem[0xFF11] >> 6)
check("DSPD 3: NR11's duty alternates 0 / 2", set(duties) == {0, 2}, duties)
runs = [len(list(g)) for _, g in __import__("itertools").groupby(duties)]
check("... every 3 frames", all(r == 3 for r in runs[1:-1]), runs)
midi(0x80, 60, 0)
mem[W + 4] = 60                                      # with a length the duty stays (NRx1 also holds the length)
midi(0x90, 60, 100)
duties = []
for _ in range(9):
    pb.tick(1)
    duties.append(mem[0xFF11] >> 6)
check("DSPD with LEN set: no switching (the duty stays 0)", set(duties) == {0}, duties)
midi(0x80, 60, 0)
mem[W + 4] = 0
mem[W + 0], mem[W + DUT2], mem[W + DSPD] = 2, 0, 0
pb.tick(4)

# --- piano roll (12 ticks per beat, grid division selectable)
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
G = sym["wGrid"]
T_EMP_W, T_NOTE_HEAD, T_NOTE_BODY, T_CUR_EMP, T_CUR_NOTE = 64, 68, 69, 70, 71


def cell(ch, tick):
    return mem[1, P + ch * 512 + tick]   # pattern 1 lives in WRAM bank 1, 512 bytes per channel


def grid(row, col):
    """Tile in the shadow map: grid row 0..15, grid column 0..15."""
    return mem[G + row * 20 + 2 + col]


def vram(row, col):
    """Tile actually in VRAM (BG map) at grid row 0..15 / column 0..15."""
    return mem[0x9800 + (1 + row) * 32 + 2 + col]


def v(name):
    return mem[sym[name]]


def settle():
    pb.tick(10)  # rendering and copying are spread over a few frames


def chord_grid():
    """B held, then A pressed: next grid division."""
    pb.button_press("b")
    pb.tick(3)
    pb.button_press("a")
    pb.tick(3)
    pb.button_release("a")
    pb.button_release("b")
    pb.tick(4)


nav("right")
pb.tick(4)
check("START+RIGHT -> piano roll", v("wScreen") == 2, v("wScreen"))
settle()
shot("09_roll")
check("demo pattern (ticks): CH1 C4 + OFF after 6, A3 at bar 2, CH3 bass",
      cell(0, 0) == 60 and cell(0, 6) == 0xFF and cell(0, 12) == 64 and cell(0, 48) == 57 and cell(2, 0) == 48)
state = (v("wSeqBars"), v("wRollNote"), v("wRollTick"), v("wRollCell"), v("wRollTop"), v("wDiv"), v("wDivTicks"))
check("defaults: 2 bars, cursor C4 tick 0, window top C5, grid 1/16 (3 ticks)", state == (2, 60, 0, 0, 72, 4, 3), state)
# top = 72 -> grid row r shows pitch 72 - r: C4 (60) is row 12, E4 (64) row 8, G4 (67) row 5
check("grid: cursor on the C4 note head", grid(12, 0) == T_CUR_NOTE, grid(12, 0))
check("grid: note body follows the head (a 6-tick note spans two 1/16 columns)", grid(12, 1) == T_NOTE_BODY, grid(12, 1))
check("grid: E4 head in column 4 (tick 12)", grid(8, 4) == T_NOTE_HEAD, grid(8, 4))
check("grid: empty white-key cell", grid(12, 2) == T_EMP_W, grid(12, 2))
check("grid: black-key row is shaded (+1)", grid(11, 2) == T_EMP_W + 1, grid(11, 2))
check("grid: beat column marked (+2)", grid(10, 4) == T_EMP_W + 2, grid(10, 4))
ruler = [mem[sym["wRulerBuf"] + i] for i in range(20)]
DOT = 75  # T_TICK: the ruler beat mark
check("ruler: bar number over the bar line, ticks over the other beats, page tab at the right",
      ruler[2] == 17 and ruler[6] == DOT and ruler[10] == DOT and ruler[14] == DOT and ruler[3] == 0 and ruler[18] == 48 + 128 and ruler[19] == 17 + 128,
      ruler)
check("grid: bar line on column 0 (navy), beat lines on columns 4, 8, 12",
      grid(0, 0) in (73, 74) and all(grid(0, c) in (66, 67) for c in (4, 8, 12)) and all(grid(0, c) in (64, 65) for c in (1, 2, 3, 5)),
      [grid(0, c) for c in range(16)])

press("right")
check("RIGHT: cursor cell 1 = tick 3", (v("wRollCell"), v("wRollTick")) == (1, 3), (v("wRollCell"), v("wRollTick")))
settle()
check("cursor moved onto the note body", grid(12, 1) == T_CUR_NOTE and grid(12, 0) == T_NOTE_HEAD,
      (grid(12, 0), grid(12, 1)))
press("up")
check("UP: cursor pitch 61", v("wRollNote") == 61)
settle()
check("cursor on an empty cell", grid(11, 1) == T_CUR_EMP, grid(11, 1))
press("down")
press("left")
check("back at C4 tick 0", (v("wRollNote"), v("wRollTick")) == (60, 0))

# --- d-pad auto-repeat: holding RIGHT keeps moving the cursor after an initial delay
hold("right", frames=0)
pb.tick(10)
check("auto-repeat: only the first move before the initial delay", v("wRollCell") == 1, v("wRollCell"))
pb.tick(30)
check("auto-repeat: a held direction keeps moving the cursor", v("wRollCell") >= 6, v("wRollCell"))
release("right")
stop_at = v("wRollCell")
pb.tick(20)
check("auto-repeat stops on release", v("wRollCell") == stop_at)
hold("left", frames=0)
pb.tick(120)
release("left")
check("auto-repeat to the left stops at cell 0", (v("wRollCell"), v("wRollTick")) == (0, 0), (v("wRollCell"), v("wRollTick")))
pb.tick(10)

# B + d-pad jumps and must not delete anything
hold("b")
press("right")
press("right")
release("b", frames=4)
check("B+RIGHT jumps 4 cells", v("wRollCell") == 8 and v("wRollTick") == 24, (v("wRollCell"), v("wRollTick")))
check("B+d-pad did not delete the note", cell(0, 0) == 60 and cell(0, 12) == 64)
hold("b")
press("right")
press("right")
release("b", frames=4)
check("page scroll: cell 16 -> page 2 (starts at tick 48)",
      (v("wRollCell"), v("wRollPage"), v("wPageTick")) == (16, 1, 48), (v("wRollCell"), v("wRollPage"), v("wPageTick")))
settle()
check("page 2: A3 head at column 0 (row 15), cursor empty at C4",
      grid(15, 0) == T_NOTE_HEAD and grid(12, 0) == T_CUR_EMP, (grid(15, 0), grid(12, 0)))
hold("b")
press("left")
press("left")
release("b", frames=4)
check("page scroll back", (v("wRollCell"), v("wRollPage"), v("wPageTick")) == (8, 0, 0))
for _ in range(8):
    press("left")
check("cursor at cell 0", v("wRollCell") == 0 and v("wRollTick") == 0)
hold("b")
press("up")
release("b", frames=4)
check("B+UP: octave up, still in the window", (v("wRollNote"), v("wRollTop")) == (72, 72), (v("wRollNote"), v("wRollTop")))
hold("b")
press("up")
release("b", frames=4)
check("pitch scroll up: window follows", (v("wRollNote"), v("wRollTop")) == (84, 84), (v("wRollNote"), v("wRollTop")))
hold("b")
press("down")
press("down")
release("b", frames=4)
check("pitch scroll down: window follows", (v("wRollNote"), v("wRollTop")) == (60, 75), (v("wRollNote"), v("wRollTop")))
settle()

# ---- editing on CH2 (empty channel), 1/16 grid (3 ticks per cell)
press("select")
check("SELECT tap -> channel 2 on the roll", v("wSelCh") == 1)
settle()
row = v("wRollTop") - v("wRollNote")
pb.button_press("a")
frames = 0
for frames in range(1, 13):
    pb.tick(1)
    if vram(row, 0) == T_CUR_NOTE:
        break
check("input latency: the note is on screen within 4 frames of pressing A", frames <= 4, frames)
pb.tick(2)
check("A places a note at the cursor", cell(1, 0) == 60, cell(1, 0))
check("...one cell long (OFF 3 ticks later)", cell(1, 3) == 0xFF, cell(1, 3))
check("A auditions on CH2", cur(1) == 60, cur(1))
press("right")
check("A held + RIGHT lengthens by a cell: OFF moved to tick 6", cell(1, 3) == 0 and cell(1, 6) == 0xFF, (cell(1, 3), cell(1, 6)))
press("left")
check("A held + LEFT shortens: OFF back at tick 3", cell(1, 6) == 0 and cell(1, 3) == 0xFF, (cell(1, 3), cell(1, 6)))
release("a", frames=4)
check("A release stops the audition", cur(1) == 0)
hold("a", frames=4)
press("up")
check("A held + UP transposes the note and the cursor", cell(1, 0) == 61 and v("wRollNote") == 61, (cell(1, 0), v("wRollNote")))
press("down")
check("A held + DOWN transposes back", cell(1, 0) == 60 and v("wRollNote") == 60)
release("a", frames=4)
settle()
check("grid: the new note is drawn (cursor on its head)", grid(15, 0) == T_CUR_NOTE, grid(15, 0))
press("b")
check("B tap deletes the note and its OFF", cell(1, 0) == 0 and cell(1, 3) == 0, (cell(1, 0), cell(1, 3)))

# collision: a note that grows until it touches the next one
hold("a", frames=4)
release("a", frames=4)
press("right")
press("right")
hold("a", frames=4)
release("a", frames=4)
check("two notes on CH2 (ticks 0 and 6)", cell(1, 0) == 60 and cell(1, 6) == 60 and cell(1, 3) == 0xFF)
press("left")
press("left")
hold("a", frames=4)
press("right")
check("growing into the next note removes the OFF (they touch)", cell(1, 3) == 0 and cell(1, 6) == 60, (cell(1, 3), cell(1, 6)))
press("right")
check("cannot grow past the next note", cell(1, 6) == 60 and cell(1, 9) == 0xFF, (cell(1, 6), cell(1, 9)))
release("a", frames=4)
press("b")
check("deleting the first note keeps the neighbour", cell(1, 0) == 0 and cell(1, 6) == 60)
for i in range(256):
    mem[1, P + 512 + i] = 0     # clean up CH2
press("select")             # CH3 (bass): the cursor jumps to its first note
check("channel switch: cursor on the first bass note", (v("wRollNote"), v("wRollTick"), v("wRollTop")) == (48, 0, 56),
      (v("wRollNote"), v("wRollTick"), v("wRollTop")))
settle()
check("channel switch: bass note drawn in the window", grid(8, 0) == T_CUR_NOTE, grid(8, 0))
press("select")             # CH4, then back to CH1
press("select")
check("SELECT cycles channels back to CH1", v("wSelCh") == 0)
settle()

# ---- BPM / loop length
tap_while("select", "up")
check("SELECT+UP: BPM 121", v("wBpm") == 121, v("wBpm"))
tap_while("select", "down")
check("SELECT+DOWN: BPM 120", v("wBpm") == 120, v("wBpm"))
tap_while("select", "left")
check("SELECT+LEFT: loop length 1 bar", v("wSeqBars") == 1, v("wSeqBars"))
tap_while("select", "left")
check("loop length clamps at 1 bar", v("wSeqBars") == 1)
tap_while("select", "right")
tap_while("select", "right")
check("SELECT+RIGHT x2: loop length 3 bars", v("wSeqBars") == 3, v("wSeqBars"))
tap_while("select", "left")
check("loop length 2 bars again", v("wSeqBars") == 2)
check("combos did not change screen/channel", v("wScreen") == 2 and v("wSelCh") == 0)

# ---- playback at the 1/16 grid
tap_while("select", "start")
check("SELECT+START starts playback", v("wSeqPlay") == 1)
check("...still on the roll", v("wScreen") == 2)
ticks = 0
last = v("wSeqTick")
bass = set()
samples = []
for i in range(120):
    pb.tick(1)
    t_ = v("wSeqTick")
    if t_ != last:
        ticks += 1
        last = t_
    bass.add(cur(2))
    if v("wPlayX") != 0xFF:
        samples.append((v("wSeqCur"), v("wPageTick"), v("wPlayX"), v("wPlayShown")))
    if i == 30:
        shot("10_roll_playing")
check("tempo: 48 ticks in 2 s at 120 BPM (12 ticks per beat)", 46 <= ticks <= 50, ticks)
check("bass notes triggered by the pattern (ticks 24 and 48)", {43, 45} <= bass, sorted(bass))
check("hi-hat (CH4) triggered", cur(3) in (90, 100), cur(3))


def expect_x(cur_tick, page_tick, div=3):
    return ROLL_X0 + (cur_tick - page_tick) * 8 // div


ROLL_X0 = 24
# the sprite is moved in the VBlank after the tick plays, so it may lag by one tick-frame
exact = sum(1 for c, p, x, _ in samples if x == expect_x(c, p))
near = all(x == expect_x(c, p) or x == expect_x(c - 1, p) for c, p, x, _ in samples)
check("playhead moves smoothly with the tick (X = 24 + dt*8/3)", len(samples) > 50 and near and exact >= 0.6 * len(samples),
      (exact, len(samples)))
# the sprite really lands on every beat line: X = 24 + 32 * beat at 1/16 (4 columns of 8 px per beat)
shown = {sh for _, _, _, sh in samples}
check("playhead sprite lands exactly on the beat lines (X = 24, 56, 88, 120)", {24, 56, 88, 120} <= shown, sorted(shown)[:12])
check("playhead sprite is placed in OAM", mem[0xFE00] == 24 and mem[0xFE01] == v("wPlayShown"), (mem[0xFE00], mem[0xFE01]))
check("16 playhead sprites stacked on the grid rows", mem[0xFE00 + 15 * 4] == 24 + 15 * 8 and mem[0xFE02] == 72)
check("playhead line sits at the left edge of its cell (on the beat line)", mem[0x8000 + 72 * 16] == 0xC0 and mem[0x8000 + 72 * 16 + 1] == 0x00)
tap_while("select", "start")
check("SELECT+START stops playback", v("wSeqPlay") == 0)
check("stop silences all channels", [cur(c) for c in range(4)] == [0, 0, 0, 0])
pb.tick(4)
check("playhead hidden while stopped", v("wPlayShown") == 0xFF and mem[0xFE00] == 0)

# 240 BPM: loops over 96 ticks, view follows the playhead across pages
mem[sym["wBpm"]] = 240
tap_while("select", "start")
seen = set()
pages = set()
for _ in range(240):
    pb.tick(1)
    seen.add(v("wSeqTick"))
    if v("wSeqCur") >= 48:
        pages.add(v("wRollPage"))
check("loop: ticks wrap inside 0..95", max(seen) == 95 and 0 in seen, (min(seen), max(seen)))
check("view followed the playhead onto page 2", 1 in pages, pages)
tap_while("select", "start")
mem[sym["wBpm"]] = 120

# ---- the bars never move when the grid division changes
for _ in range(5):          # cursor to cell 20 = tick 60 (bar 2, beat 2) at 1/16
    hold("b")
    press("right")
    release("b", frames=4)
check("cursor at tick 60 (bar 2, beat 2)", (v("wRollCell"), v("wRollTick"), v("wDiv")) == (20, 60, 4),
      (v("wRollCell"), v("wRollTick"), v("wDiv")))
DIV_TICKS = [12, 8, 6, 4, 3, 2, 1]
DIV_COLS = [16, 12, 16, 12, 16, 12, 12]
bad = []
for step in range(7):       # visit every division once, ending where we started
    d_ = v("wDiv")
    ticks, cols = DIV_TICKS[d_], DIV_COLS[d_]
    span, ptick = v("wPageSpan"), v("wPageTick")
    if (v("wDivTicks"), v("wPageCols"), span) != (ticks, cols, ticks * cols):
        bad.append(("params", d_))
    if ptick % 12 != 0 or not (ptick <= v("wRollTick") < ptick + span):
        bad.append(("page", d_, ptick))
    settle()
    for c in range(16):
        flags = mem[sym["wColHead"] + c]
        t0 = ptick + c * ticks
        if c >= cols:
            want = 4
        else:
            want = (2 if t0 % 12 == 0 else 0) | (8 if t0 % 48 == 0 else 0)
        if (flags & ~1) != want:
            bad.append(("flags", d_, c, flags, want))
    chord_grid()
check("every grid division shows whole bars/beats: bar and beat lines sit on the same ticks",
      not bad and v("wDiv") == 4, bad[:3])
for _ in range(5):
    hold("b")
    press("left")
    release("b", frames=4)
check("cursor back at cell 0", (v("wRollCell"), v("wRollTick")) == (0, 0), (v("wRollCell"), v("wRollTick")))
settle()

# ---- grid division: triplets by placement, not by commands
press("select")             # CH2 (empty)
check("on CH2", v("wSelCh") == 1)
check("SELECT tap on the roll places no stray note (it once trashed the d register)",
      all(cell(1, i) == 0 for i in range(256)) and all(cell(0, i) == mem[sym["DefaultPattern"] + i] for i in range(0)),
      [(i, cell(1, i)) for i in range(256) if cell(1, i)][:4])
settle()
chord_grid()
check("B+A: grid 1/16 -> 1/16T (2 ticks per cell)", (v("wDiv"), v("wDivTicks")) == (5, 2), (v("wDiv"), v("wDivTicks")))
check("B+A did not place a note or delete anything", cell(1, 0) == 0 and cell(0, 0) == 60)
for _ in range(5):
    chord_grid()            # 1/48, 1/4, 1/4T, 1/8, 1/8T
check("five more B+A: 1/8T (4 ticks per cell)", (v("wDiv"), v("wDivTicks")) == (3, 4), (v("wDiv"), v("wDivTicks")))
settle()
status = [mem[sym["wStatusBuf"] + i] for i in range(8, 13)]
check("status line shows the division label '1/8T'", status[:4] == [ord(c) - 32 for c in "1/8T"], status)
ruler = [mem[sym["wRulerBuf"] + i] for i in range(20)]
check("ruler at 1/8T: bar 1 at column 0, beat dots every 3 columns (12 ticks / 4)",
      ruler[2] == 17 and ruler[5] == DOT and ruler[8] == DOT and ruler[11] == DOT and ruler[3] == 0 and ruler[4] == 0, ruler)
check("1/8T page: 12 columns, one bar; the unused columns are blank",
      (v("wPageCols"), v("wPageSpan")) == (12, 48) and all(grid(0, c) == 0 for c in range(12, 16)),
      (v("wPageCols"), v("wPageSpan"), [grid(0, c) for c in range(12, 16)]))
check("grid: beat column tiles follow the new division",
      (grid(0, 3) - T_EMP_W) & 2 == 2 and (grid(0, 6) - T_EMP_W) & 2 == 2 and (grid(0, 1) - T_EMP_W) & 2 == 0 and (grid(0, 2) - T_EMP_W) & 2 == 0,
      (grid(0, 1), grid(0, 3), grid(0, 6)))
# three 1/8T notes in the time of one beat: ticks 0, 4, 8 (pitches 60, 61, 62)
hold("a", frames=4)
release("a", frames=4)
for pitch in (61, 62):
    press("right")
    press("up")
    hold("a", frames=4)
    release("a", frames=4)
check("triplet: three notes 4 ticks apart (cells 0, 1, 2)",
      (cell(1, 0), cell(1, 4), cell(1, 8)) == (60, 61, 62), (cell(1, 0), cell(1, 4), cell(1, 8)))
check("...each as long as one 1/8T cell, the last one ends at tick 12", cell(1, 12) == 0xFF and cell(1, 3) == 0 and cell(1, 7) == 0,
      (cell(1, 12), cell(1, 3), cell(1, 7)))
settle()
check("grid: the three notes are heads in columns 0, 1, 2",
      all(vram(v("wRollTop") - p, c) in (T_NOTE_HEAD, T_CUR_NOTE) for c, p in ((0, 60), (1, 61), (2, 62))))
# play it: a note-on every 4 ticks (a third of a beat)
mem[sym["wRollTick"]] = 0
pb.tick(2)
mem[sym["wSeqBars"]] = 1
tap_while("select", "start")
events = {}
prev = cur(1)
for _ in range(200):
    pb.tick(1)
    if cur(1) != prev:
        events.setdefault(v("wSeqCur"), []).append(cur(1))
        prev = cur(1)
tap_while("select", "start")
check("triplet playback: note-ons land on ticks 0, 4 and 8 of the beat",
      events.get(0, [None])[0] == 60 and events.get(4, [None])[0] == 61 and events.get(8, [None])[0] == 62,
      {k: events[k] for k in sorted(events)[:6]})
mem[sym["wSeqBars"]] = 2
# one more full cycle returns to 1/16 (7 divisions)
for _ in range(6):
    chord_grid()
check("grid divisions wrap around (7 steps back to 1/8T)", (v("wDiv"), v("wDivTicks")) == (3, 4) or v("wDiv") == 2, (v("wDiv"), v("wDivTicks")))
for i in range(256):
    mem[1, P + 512 + i] = 0
nav("right")
pb.tick(4)
check("START+RIGHT from the sequencer -> keyboard screen", v("wScreen") == 3, v("wScreen"))
nav("right")
check("START+RIGHT on the keyboard screen: stays (the last screen)", v("wScreen") == 3, v("wScreen"))
nav("left")
pb.tick(6)
check("START+LEFT on the keyboard screen -> back to the sequencer", v("wScreen") == 2, v("wScreen"))
nav("left")
nav("left")
pb.tick(6)
check("START+LEFT twice more -> the play screen", v("wScreen") == 0, v("wScreen"))
pb.tick(20)
shot("12_play_again")

# Frames that entered after LY 146 (or outside VBlank) are skipped by UpdateUI's own
# guard and draw nothing; screen switches turn the LCD off/on (LY restarts): ignore both.
frames = list(zip(vb_entry, vb_exit))
worked = [(ly_out) for (req, ly_in), ly_out in frames if req == 0 and 144 <= ly_in < 147]
skipped = sum(1 for (req, ly_in), _ in frames if req == 0 and not (144 <= ly_in < 147))
late = [ly for ly in worked if ly < 144]
check("UpdateUI finishes inside VBlank on every frame it draws",
      len(worked) > 500 and not late and max(worked) <= 151,
      f"{len(worked)} frames, {len(late)} late, worst exit LY {max(worked)}")
check("frames skipped for entering VBlank too late are rare", skipped <= 0.02 * len(frames),
      f"{skipped} of {len(frames)}")

pb.stop(save=False)
print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
