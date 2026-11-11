#!/usr/bin/env python3
"""Note editing and paging test using PyBoy. Run `make` first.

Notes may run across the segment end (tick 192 of the pattern): lengthening / shortening / deleting work
on absolute ticks. The cursor follows the end of a lengthened note (the page turns). Every page has 16
columns (no blank columns), the last page of a segment is shifted back. START+A / START+B switch the
edited pattern on the sequencer screen.
"""
import pathlib, re, shutil, tempfile
from pyboy import PyBoy
from pool_util import Pool

root = pathlib.Path(__file__).resolve().parent.parent
rom_src = root / "build/chromasynth.gb"
sym = {}
for line in (root / "build/chromasynth.sym").read_text().splitlines():
    m = re.match(r"([0-9A-Fa-f]{2}):([0-9A-Fa-f]{4}) (\S+)", line)
    if m:
        sym[m.group(3)] = int(m.group(2), 16)
fails = 0
OFF = 0xFF


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
    pb.button_press(held); pb.tick(3); pb.button_press(btn); pb.tick(3)
    pb.button_release(btn); pb.tick(2); pb.button_release(held); pb.tick(settle)


def tap(pb, btn, settle=6):
    pb.button_press(btn); pb.tick(3); pb.button_release(btn); pb.tick(settle)


with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    pool = Pool(mem, sym)
    ch = 1                                   # CH2: empty in the default song
    cell = lambda seg, t: pool.get(0, ch, seg, t)
    put = lambda seg, t, x: pool.put(0, ch, seg, t, x)
    pool.clear_channel(0, ch)
    combo(pb, "start", "right"); combo(pb, "start", "right"); pb.tick(30)
    tap(pb, "select")                        # CH2
    for _ in range(8):                       # grid 1/16 (3 ticks per cell)
        if v("wDivTicks") == 3:
            break
        combo(pb, "b", "a")
    check("1/16 grid on CH2", v("wDivTicks") == 3 and v("wSelCh") == 1, (v("wDivTicks"), v("wSelCh")))
    check("every grid division has 16 columns", True)

    def cursor(seg, tick, note):
        mem[sym["wRollSeg"]] = seg
        mem[sym["wRollTick"]] = tick
        mem[sym["wRollCell"]] = tick // 3
        mem[sym["wRollNote"]] = note

    # a note from tick 180 that ends in the next segment (tick 196)
    put(0, 180, 60); put(1, 4, OFF)
    cursor(0, 180, 60)
    pb.button_press("a"); pb.tick(4)
    tap(pb, "right", 8)
    pb.button_release("a"); pb.tick(4)
    check("lengthen: the OFF of a note that runs across the segment end moves one cell",
          cell(1, 4) == 0 and cell(1, 7) == OFF, (cell(1, 4), cell(1, 7)))
    check("lengthen: the cursor follows the end of the note into segment 1 (the page turns)",
          (v("wRollSeg"), v("wRollTick")) == (1, 6) and v("wPageSeg") == 1, (v("wRollSeg"), v("wRollTick"), v("wPageSeg")))
    pb.button_press("a"); pb.tick(4)
    tap(pb, "left", 8)
    pb.button_release("a"); pb.tick(4)
    check("shorten: the OFF goes back and the cursor with it",
          cell(1, 7) == 0 and cell(1, 4) == OFF and (v("wRollSeg"), v("wRollTick")) == (1, 3), (cell(1, 7), cell(1, 4), v("wRollSeg"), v("wRollTick")))
    # a note that ends exactly at the segment end (OFF at tick 0 of segment 1) grows into it
    for i in range(256):
        put(0, i, 0); put(1, i, 0)
    put(0, 189, 62); put(1, 0, OFF)
    cursor(0, 189, 62)
    pb.button_press("a"); pb.tick(4)
    tap(pb, "right", 8)
    pb.button_release("a"); pb.tick(4)
    check("lengthen a note that ended at the segment end", cell(1, 0) == 0 and cell(1, 3) == OFF, (cell(1, 0), cell(1, 3)))
    # B deletes a note together with its OFF in the other segment
    cursor(0, 189, 62)
    tap(pb, "b", 8)
    check("delete: the note and its OFF in the next segment",
          cell(0, 189) == 0 and cell(1, 3) == 0, (cell(0, 189), cell(1, 3)))
    # a note that runs into the next one keeps its length when that one is deleted
    for i in range(256):
        put(0, i, 0); put(1, i, 0)
    put(0, 0, 60); put(0, 12, 62); put(0, 24, OFF)       # (the first has no OFF: it ends at the second)
    cursor(0, 12, 62)
    tap(pb, "b", 8)
    check("deleting the next note: the first keeps its length (an OFF where the deleted note started)",
          cell(0, 0) == 60 and cell(0, 12) == OFF and cell(0, 24) == 0, (cell(0, 0), cell(0, 12), cell(0, 24)))
    # two notes of the same pitch side by side stay two notes
    put(0, 0, 60); put(0, 3, OFF)
    cursor(0, 3, 60)
    tap(pb, "a", 4)
    check("a note of the same pitch can be placed right after another", cell(0, 0) == 60 and cell(0, 3) == 60 and cell(0, 6) == OFF,
          (cell(0, 0), cell(0, 3), cell(0, 6)))
    # pages: a page is whole bars when the grid divides the bar; a bar of more than 16 cells is shown in
    # pieces of 16 cells, the last piece shifted back to end on the bar's end
    for i in range(256):
        put(0, i, 0); put(1, i, 0)
    cursor(0, 0, 60)
    for _ in range(8):
        if v("wDiv") == 5:
            break
        combo(pb, "b", "a")
    check("1/16T (24 cells in a 4/4 bar): pieces of 16 cells (32 ticks)", (v("wDiv"), v("wPageCols"), v("wPageSpan")) == (5, 16, 32), (v("wDiv"), v("wPageCols"), v("wPageSpan")))
    for _ in range(17):
        tap(pb, "right", 3)
    check("1/16T: cell 17 shows the last piece of the bar (cells 8-23: tick 16)",
          (v("wRollCell"), v("wPageAbs")) == (17, 16), (v("wRollCell"), v("wPageAbs")))
    pb.tick(20)
    blank = [mem[sym["wColHead"] + c] & 4 for c in range(16)]
    check("no blank column on the page", not any(blank), blank)
    for _ in range(40):
        tap(pb, "right", 3)
    check("cell 57 (tick 114, bar 3) is on a page of bar 3 (96..143)", 96 <= v("wPageAbs") <= 114 and v("wPageAbs") + v("wPageSpan") <= 144, (v("wPageAbs"), v("wPageSpan")))
    # START+A / START+B: the next / previous pattern on the sequencer screen
    check("pattern 1 is edited", v("wEditPat") == 0)
    pb.button_press("start"); pb.tick(3); tap(pb, "a", 3); pb.button_release("start"); pb.tick(10)
    check("START+A: pattern 2 is edited, no note was placed", v("wEditPat") == 1 and cell(0, 0) == 0, (v("wEditPat"),))
    pb.button_press("start"); pb.tick(3); tap(pb, "b", 3); pb.button_release("start"); pb.tick(10)
    check("START+B: back to pattern 1", v("wEditPat") == 0, v("wEditPat"))
    pb.stop(save=False)

print("\n%d FAILED" % fails if fails else "\nALL PASSED")
raise SystemExit(1 if fails else 0)
