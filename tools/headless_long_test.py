#!/usr/bin/env python3
"""Long-pattern test using PyBoy (pip install pyboy pillow). Run `make` first.

A pattern is up to 8 bars = 2 segments of 4 bars (192 ticks each); a position is (segment, tick).
Covers: the cursor crossing the segment edge, editing in segment 2, the page / ruler of segment 2,
the loop length up to 8 bars, playback across the edge, the page following the playhead,
and a note that sounds across the segment edge being drawn in segment 2.
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


def boot(rom):
    pb = PyBoy(str(rom), window="null", sound_emulated=False)
    for _ in range(2000):
        pb.tick(1)
        if pb.register_file.PC >= 0x100:
            break
    pb.tick(60)
    return pb


def combo(pb, held, btn, settle=6):
    pb.button_press(held)
    pb.tick(3)
    pb.button_press(btn)
    pb.tick(3)
    pb.button_release(btn)
    pb.tick(2)
    pb.button_release(held)
    pb.tick(settle)


def tap(pb, btn, settle=4):
    pb.button_press(btn)
    pb.tick(3)
    pb.button_release(btn)
    pb.tick(settle)


PAT = 0xD000
CH_STRIDE = 512


def cell(mem, ch, seg, tick, bank=1):
    return mem[bank, PAT + ch * CH_STRIDE + seg * 256 + tick]


def setcell(mem, ch, seg, tick, value, bank=1):
    mem[bank, PAT + ch * CH_STRIDE + seg * 256 + tick] = value


with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    tiles = lambda s_: bytes(ord(c) - 32 for c in s_)

    check("the demo is in pattern 1, segment 1", cell(mem, 0, 0, 0) == 60 and cell(mem, 0, 1, 0) == 0)
    combo(pb, "start", "right")
    combo(pb, "start", "right")
    pb.tick(30)
    check("on the piano roll", v("wScreen") == 2, v("wScreen"))

    # --- the cursor crosses the segment edge (1/16: 64 cells of 3 ticks per segment)
    mem[sym["wRollCell"]] = 63
    mem[sym["wRollTick"]] = 189
    mem[sym["wRollSeg"]] = 0
    tap(pb, "right")
    check("RIGHT at the last cell: segment 2, cell 0", (v("wRollSeg"), v("wRollCell"), v("wRollTick")) == (1, 0, 0),
          (v("wRollSeg"), v("wRollCell"), v("wRollTick")))
    pb.tick(10)
    check("the page shows segment 2", v("wPageSeg") == 1 and v("wRollPage") == 0, (v("wPageSeg"), v("wRollPage")))
    mem[sym["wSeqBars"]] = 8            # (the ruler shows no bar numbers after the loop end)
    mem[sym["wRollSeg"]] = 1
    mem[sym["wRollCell"]] = 0
    mem[sym["wRollTick"]] = 0
    tap(pb, "left")                      # out of segment 2 ...
    tap(pb, "right")                     # ... and back in: the ruler is rebuilt
    pb.tick(30)
    ruler = bytes(mem[(0x9C00 if mem[0xFF40] & 8 else 0x9800) + i] for i in range(20))
    check("the ruler tab says the edited pattern: P1", ruler[18] == ord("P") - 32 + 0x80 and ruler[19] == ord("1") - 32 + 0x80, ruler)
    check("the ruler numbers the bars on: bar 5 over the first column", ruler[2] == ord("5") - 32, ruler[:6])
    tap(pb, "left")
    check("LEFT at cell 0 of segment 2: back to the last cell of segment 1", (v("wRollSeg"), v("wRollCell"), v("wRollTick")) == (0, 63, 189),
          (v("wRollSeg"), v("wRollCell"), v("wRollTick")))
    tap(pb, "right")
    mem[sym["wRollCell"]] = 63
    mem[sym["wRollTick"]] = 189
    tap(pb, "right")
    check("RIGHT at the very last cell stays", (v("wRollSeg"), v("wRollCell")) == (1, 63), (v("wRollSeg"), v("wRollCell")))

    # --- B + RIGHT moves 4 cells and crosses too
    mem[sym["wRollSeg"]] = 0
    mem[sym["wRollCell"]] = 62
    mem[sym["wRollTick"]] = 186
    combo(pb, "b", "right")
    check("B+RIGHT over the edge: 4 cells on, segment 2 cell 2", (v("wRollSeg"), v("wRollCell"), v("wRollTick")) == (1, 2, 6),
          (v("wRollSeg"), v("wRollCell"), v("wRollTick")))

    # --- edit in segment 2: A places a note there
    mem[sym["wRollSeg"]] = 1
    mem[sym["wRollCell"]] = 4
    mem[sym["wRollTick"]] = 12
    mem[sym["wRollNote"]] = 67
    tap(pb, "a")
    pb.tick(5)
    check("A in segment 2 writes into its page", cell(mem, 0, 1, 12) == 67 and cell(mem, 0, 1, 15) == 0xFF,
          (cell(mem, 0, 1, 12), cell(mem, 0, 1, 15)))
    check("... and segment 1 is untouched", cell(mem, 0, 0, 12) == 64 or cell(mem, 0, 0, 12) != 67, cell(mem, 0, 0, 12))
    mem[sym["wRollSeg"]] = 1
    pb.tick(2)
    tap(pb, "b")
    pb.tick(5)
    check("B deletes it again", cell(mem, 0, 1, 12) == 0 and cell(mem, 0, 1, 15) == 0, (cell(mem, 0, 1, 12), cell(mem, 0, 1, 15)))

    # --- a note that sounds across the edge is drawn on in segment 2
    setcell(mem, 0, 0, 150, 70)        # no OFF before the end of segment 1
    mem[sym["wRollSeg"]] = 1
    mem[sym["wRollCell"]] = 0
    mem[sym["wRollTick"]] = 0
    mem[sym["wRollNote"]] = 72
    tap(pb, "left")                      # back over the edge ...
    tap(pb, "right")                     # ... and forward again: the page of segment 2 is rebuilt
    pb.tick(10)
    check("the column summary of segment 2 starts with the note from segment 1", mem[sym["wColPitch"]] == 70, mem[sym["wColPitch"]])
    setcell(mem, 0, 0, 150, 0)

    # --- loop length up to 8 bars
    for _ in range(8):
        combo(pb, "select", "right")
    check("SELECT+RIGHT: the loop length stops at 8 bars", v("wSeqBars") == 8, v("wSeqBars"))
    for _ in range(9):
        combo(pb, "select", "left")
    check("SELECT+LEFT: and at 1 bar", v("wSeqBars") == 1, v("wSeqBars"))
    pb.stop(save=False)


# --- a full redraw is built in the hidden map and swapped in: no frame shows half old, half new rows
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    combo(pb, "start", "right")
    combo(pb, "start", "right")
    pb.tick(40)

    def picture():
        base = 0x9C00 if mem[0xFF40] & 8 else 0x9800
        return bytes(mem[base + r * 32 + c] for r in range(18) for c in range(20))

    old = picture()
    mem[sym["wRollNote"]] = mem[sym["wRollTop"]]      # the cursor on the top row: B+UP scrolls the pitch window
    pb.button_press("b")
    pb.button_press("up")
    seen = []
    for _ in range(20):
        pb.tick(1)
        seen.append(picture())
    pb.button_release("up")
    pb.button_release("b")
    pb.tick(20)
    new = picture()
    pb.tick(40)                                        # the hidden map catches up in the background
    check("the pitch scroll changed the picture", old != new)
    check("on the way, every frame shows the old picture or the new one (no tearing)", all(f == old or f == new for f in seen),
          sum(1 for f in seen if f != old and f != new))
    check("both maps hold the new picture afterwards (the old one is brought up to date)",
          bytes(mem[0x9800 + r * 32 + c] for r in range(18) for c in range(20)) ==
          bytes(mem[0x9C00 + r * 32 + c] for r in range(18) for c in range(20)))
    pb.stop(save=False)

# --- the status line shows the loop length; a note placed after the loop end lengthens the loop
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    combo(pb, "start", "right")
    combo(pb, "start", "right")
    pb.tick(40)

    def shown_row(r):
        base = 0x9C00 if mem[0xFF40] & 8 else 0x9800
        return bytes(mem[base + r * 32 + c] for c in range(20))

    st = shown_row(17)
    check("the status line ends with the loop length: L2", st[18] == ord("L") - 32 and st[19] == ord("2") - 32, st)
    check("the ruler ends with the pattern: P1", shown_row(0)[18:20] == bytes([ord("P") - 32 + 0x80, ord("1") - 32 + 0x80]), shown_row(0))
    mem[sym["wRollSeg"]] = 0
    mem[sym["wRollCell"]] = 32                 # bar 3 at 1/16 (16 cells a bar)... cell 32 = tick 96 = bar 3
    mem[sym["wRollTick"]] = 96
    mem[sym["wRollNote"]] = 64
    tap(pb, "a")
    pb.tick(30)
    check("a note in bar 3 makes the loop 3 bars", v("wSeqBars") == 3, v("wSeqBars"))
    st = shown_row(17)
    check("... and the status line says L3", st[19] == ord("3") - 32, st)
    mem[sym["wRollSeg"]] = 1
    mem[sym["wRollCell"]] = 20                 # segment 2, tick 60 = bar 6 of the pattern
    mem[sym["wRollTick"]] = 60
    tap(pb, "a")
    pb.tick(20)
    check("a note in bar 6 makes it 6 bars", v("wSeqBars") == 6, v("wSeqBars"))
    mem[sym["wRollSeg"]] = 0
    mem[sym["wRollCell"]] = 0
    mem[sym["wRollTick"]] = 6
    tap(pb, "a")
    pb.tick(10)
    check("a note inside the loop leaves the length alone", v("wSeqBars") == 6, v("wSeqBars"))
    # lengthening a note (A held + RIGHT) over the loop end lengthens the loop too
    mem[sym["wSeqBars"]] = 1
    mem[sym["wRollSeg"]] = 0
    mem[sym["wRollCell"]] = 15                # the last cell of bar 1 (tick 45)
    mem[sym["wRollTick"]] = 45
    mem[sym["wRollNote"]] = 67
    pb.button_press("a")
    pb.tick(4)
    check("the note was placed in bar 1 (the loop is still 1 bar)", v("wSeqBars") == 1, v("wSeqBars"))
    pb.button_press("right")
    pb.tick(3)
    pb.button_release("right")
    pb.tick(3)
    pb.button_release("a")
    pb.tick(10)
    check("A held + RIGHT: the note grows into bar 2 and the loop with it", v("wSeqBars") == 2, v("wSeqBars"))
    pb.stop(save=False)

# --- playback across the segment edge
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    for ch in range(4):
        for seg in range(2):
            for t in range(192):
                setcell(mem, ch, seg, t, 0)
    setcell(mem, 0, 0, 0, 60)          # bar 1: C4
    setcell(mem, 0, 1, 0, 64)          # bar 5: E4
    setcell(mem, 0, 1, 48, 67)         # bar 6: G4 (after the 5-bar loop's end)
    mem[sym["wBpm"]] = 240             # a bar = 60 frames
    mem[sym["wSeqBars"]] = 8
    combo(pb, "start", "right")
    combo(pb, "start", "right")
    combo(pb, "select", "start")
    seen = []
    notes = []
    for _ in range(220):
        pb.tick(4)
        seen.append((v("wSeqCurSeg"), v("wSeqTick") // 48))
        notes.append(mem[sym["wCurNote"]])
    check("the playhead goes from segment 1 to segment 2 and back", (0, 0) in seen and (1, 0) in seen and seen.index((1, 0)) > seen.index((0, 3)), seen[:3])
    runs = [notes[0]]
    for n in notes[1:]:
        if n != runs[-1]:
            runs.append(n)
    check("8-bar loop: C4, E4 (bar 5), G4 (bar 6), then round again", runs[:5] in ([60, 64, 67, 60, 64], [0, 60, 64, 67, 60]), runs[:6])
    cycle = None
    first = next((i for i, n in enumerate(notes) if n == 60), None)
    g = next((i for i, n in enumerate(notes) if n == 67), None)
    second = next((i for i, n in enumerate(notes) if n == 60 and g is not None and i > g), None)
    if first is not None and second is not None:
        cycle = (second - first) * 4
    check("an 8-bar loop takes about 480 frames", cycle is not None and 440 <= cycle <= 520, cycle)
    combo(pb, "select", "start")

    # a 5-bar loop: segment 2 is played for one bar only
    mem[sym["wSeqBars"]] = 5
    for _ in range(3):
        pb.tick(1)
    combo(pb, "select", "start")
    notes = []
    for _ in range(140):
        pb.tick(4)
        notes.append(mem[sym["wCurNote"]])
    runs = [notes[0]]
    for n in notes[1:]:
        if n != runs[-1]:
            runs.append(n)
    check("5-bar loop: the G4 of bar 6 never sounds", 67 not in runs, runs[:8])
    check("... but the E4 of bar 5 does", 64 in runs, runs[:8])
    combo(pb, "select", "start")

    # the page follows the playhead into segment 2
    mem[sym["wSeqBars"]] = 8
    pb.tick(5)
    mem[sym["wPageSeg"]] = 0
    combo(pb, "select", "start")
    pb.tick(200)                       # bar 4 -> the playhead is in segment 1 still at 200 frames
    pb.tick(150)                       # ... and well inside segment 2
    check("the page follows the playhead into segment 2", v("wSeqCurSeg") == 1 and v("wPageSeg") == 1, (v("wSeqCurSeg"), v("wPageSeg")))
    combo(pb, "select", "start")
    pb.stop(save=False)

print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
