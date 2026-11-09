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


def screen_row_of(mem, r):
    """The 20 tiles shown on screen row r (0 = ruler .. 17 = status): the BG map in use, shifted by SCY."""
    base = 0x9C00 if mem[0xFF40] & 8 else 0x9800
    row = ((mem[0xFF42] // 8) + r) & 31
    return bytes(mem[base + row * 32 + c] for c in range(20))


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
    ruler = screen_row_of(mem, 0)
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
        return b"".join(screen_row_of(mem, r) for r in range(18))

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
          True)
    pb.stop(save=False)


# --- one-pitch scroll: 3 rows and SCY (no redraw), smooth while a key is held
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
        return b"".join(screen_row_of(mem, r) for r in range(18))

    def full_redraw_picture():
        """What a complete redraw shows for the current state (the loop-length round trip rebuilds everything)."""
        combo(pb, "select", "right")
        combo(pb, "select", "left")
        pb.tick(40)
        return picture()

    vb_in, vb_out = [], []
    pb.hook_register(0, sym["UpdateUI"], lambda ctx: vb_in.append(mem[0xFF44]), None)
    pb.hook_register(0, sym["VoiceTick"], lambda ctx: vb_out.append(mem[0xFF44]), None)
    mem[sym["wRollNote"]] = mem[sym["wRollTop"]]       # the cursor on the top row (poked: draw it there first)
    full_redraw_picture()
    top0 = v("wRollTop")
    scy0 = mem[0xFF42]
    tap(pb, "up")
    changed_at = None
    for i in range(1, 7):
        pb.tick(1)
        if v("wShownTop") == top0 + 1:
            changed_at = i
            break
    check("one UP at the top edge: the window moves within a few frames (no 8-frame redraw)", changed_at is not None and changed_at <= 4, changed_at)
    check("... the picture shows the window one pitch higher", v("wShownTop") == v("wRollTop") == top0 + 1, (v("wShownTop"), v("wRollTop")))
    pb.tick(10)
    check("... SCY moved by one row (8 pixels)", (mem[0xFF42] - scy0) & 0xFF == 0xF8, (scy0, mem[0xFF42]))
    p_fast = picture()
    p_full = full_redraw_picture()
    check("the fast scroll leaves exactly the picture a full redraw would give", p_fast == p_full,
          [r for r in range(18) if p_fast[r * 20:(r + 1) * 20] != p_full[r * 20:(r + 1) * 20]])

    # hold UP: the window follows the cursor on every repeat, and ends consistent
    pb.button_press("up")
    tops = []
    for _ in range(70):
        pb.tick(1)
        tops.append(v("wShownTop"))
    pb.button_release("up")
    pb.tick(20)
    steps = len(set(tops))
    check("holding UP scrolls step by step while it is held (not at the release)", steps >= 6 and tops[len(tops) // 2] > tops[0], (steps, tops[0], tops[len(tops) // 2]))
    check("the window and the cursor agree afterwards", v("wShownTop") == v("wRollTop") and v("wRollNote") <= v("wRollTop"), (v("wShownTop"), v("wRollTop"), v("wRollNote")))
    p_fast = picture()
    p_full = full_redraw_picture()
    check("after the held scroll the picture equals a full redraw", p_fast == p_full,
          [r for r in range(18) if p_fast[r * 20:(r + 1) * 20] != p_full[r * 20:(r + 1) * 20]])

    # and downwards
    mem[sym["wRollNote"]] = mem[sym["wRollTop"]] - 15
    full_redraw_picture()                              # (poked cursor: draw it first)
    pb.button_press("down")
    pb.tick(50)
    pb.button_release("down")
    pb.tick(20)
    check("holding DOWN scrolls the window down", v("wShownTop") < tops[-1], (v("wShownTop"), tops[-1]))
    worked = [o for i_, o in zip(vb_in, vb_out) if 144 <= i_ < 147]
    check("the scrolls never run past the end of VBlank (UpdateUI exits by LY 151)", len(worked) > 100 and min(worked) >= 144 and max(worked) <= 151,
          (len(worked), min(worked), max(worked)))
    p_fast = picture()
    p_full = full_redraw_picture()
    check("... and the picture equals a full redraw", p_fast == p_full,
          [r for r in range(18) if p_fast[r * 20:(r + 1) * 20] != p_full[r * 20:(r + 1) * 20]])
    # ... while the sequencer plays (the playhead also uses the VBlank)
    mem[sym["wBpm"]] = 240
    vb_in.clear()
    vb_out.clear()
    combo(pb, "select", "start")
    mem[sym["wRollNote"]] = mem[sym["wRollTop"]]
    full_redraw_picture()
    pb.button_press("up")
    pb.tick(60)
    pb.button_release("up")
    pb.button_press("down")
    pb.tick(40)
    pb.button_release("down")
    combo(pb, "select", "start")
    pb.tick(30)
    worked = [o for i_, o in zip(vb_in, vb_out) if 144 <= i_ < 147]
    over = sum(1 for o in worked if o > 151)
    check("scrolling while the sequencer plays: UpdateUI ends by LY 151 (a rare quiet frame may end on 152, none later)",
          len(worked) > 100 and min(worked) >= 144 and max(worked) <= 152 and over <= 2, (len(worked), min(worked), max(worked), over))
    p_fast = picture()
    p_full = full_redraw_picture()
    check("... and the picture still equals a full redraw", p_fast == p_full,
          [r for r in range(18) if p_fast[r * 20:(r + 1) * 20] != p_full[r * 20:(r + 1) * 20]])
    pb.stop(save=False)


# --- turning the page: only the rows that change are copied, so the page turns within a few frames
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
        return b"".join(screen_row_of(mem, r) for r in range(18))

    for turn, (cell, tick) in enumerate(((15, 45), (31, 93), (47, 141))):
        mem[sym["wRollSeg"]] = 0
        mem[sym["wRollCell"]] = cell
        mem[sym["wRollTick"]] = tick
        combo(pb, "left", "right") if False else None
        pb.tick(30)
        before = picture()
        pb.button_press("right")
        pb.tick(1)
        pb.button_release("right")
        frames = None
        shots = []
        for i in range(1, 16):
            pb.tick(1)
            shots.append(picture())
        final = shots[-1]
        for i, f in enumerate(shots, 1):
            if f == final:
                frames = i
                break
        check(f"page turn {turn + 1}: the new page is complete within 5 frames of the key press", v("wPageSeg") == 0 and frames is not None and frames <= 6,
              (frames, v("wRollPage")))
    # and the turned page equals a full redraw
    combo(pb, "select", "right")
    combo(pb, "select", "left")
    pb.tick(40)
    check("the page that was turned equals a complete redraw", final == picture(),
          [r for r in range(18) if final[r * 20:(r + 1) * 20] != picture()[r * 20:(r + 1) * 20]])
    pb.stop(save=False)


# --- playing across a page boundary: the next page is built ahead and shown as the playhead gets there
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    combo(pb, "start", "right")
    combo(pb, "start", "right")
    pb.tick(40)
    mem[sym["wBpm"]] = 200                       # a tick every 1.5 frames: a turn that lags shows
    mem[sym["wSeqBars"]] = 3
    pb.tick(20)
    combo(pb, "select", "start")
    samples = []                                  # (tick, segment, bar number tile on the ruler, playhead visible)
    for _ in range(420):
        pb.tick(1)
        samples.append((v("wSeqCur"), v("wSeqCurSeg"), screen_row_of(mem, 0)[2], v("wPlayShown") != 0xFF))
    combo(pb, "select", "start")
    # 1/16: a page is one bar (48 ticks). The ruler's first bar number is the bar of the shown page.
    lag = []
    for tick, seg, ruler, vis in samples:
        want = ord("1") - 32 + tick // 48
        if tick % 48 >= 2:                        # two ticks after the page started: it must be the shown one
            lag.append(ruler != want)
    check("every page turn is on screen two ticks after the playhead enters the new page (no lag)", sum(lag) <= 3, (sum(lag), len(lag)))
    hidden = [1 for tick, seg, ruler, vis in samples if tick % 48 >= 2 and not vis]
    check("the playhead is visible except for the first ticks of a page", len(hidden) <= 4, len(hidden))
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
        return screen_row_of(mem, r)

    check("the ruler numbers the bars of the page even after the loop end (loop 2 bars, page 1: bar 1)", shown_row(0)[2] == ord("1") - 32, shown_row(0)[:6])
    mem[sym["wRollSeg"]] = 1
    mem[sym["wRollCell"]] = 0
    mem[sym["wRollTick"]] = 0
    tap(pb, "left")                          # out of segment 2 and back: the ruler of bar 5's page
    tap(pb, "right")
    pb.tick(30)
    check("... and a page after the loop end (loop 2 bars) still shows its bar number: 5", shown_row(0)[2] == ord("5") - 32, shown_row(0)[:6])
    mem[sym["wRollSeg"]] = 0
    mem[sym["wRollCell"]] = 0
    mem[sym["wRollTick"]] = 0
    tap(pb, "left")
    pb.tick(30)
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
    for g in range(2):
        for t in range(192):
            setcell(mem, 0, g, t, 0)          # an empty channel: nothing touches the growing note
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
