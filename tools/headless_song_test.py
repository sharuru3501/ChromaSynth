#!/usr/bin/env python3
"""Song test using PyBoy (pip install pyboy pillow). Run `make` first.

Covers: the song screen (START+UP / START+DOWN, cursor, A/B steps, edit pattern, mode),
the pattern pages, chain playback (which pattern plays when), and saving / loading a whole song.
"""
import pathlib
import re
import shutil
import sys
import tempfile

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
    pb.tick(60)           # the boot (4 slot scans + a load) takes a few frames
    return pb


def combo(pb, held, btn, settle=6, hold=3):
    pb.button_press(held)
    pb.tick(3)
    pb.button_press(btn)
    pb.tick(hold)       # (a chain step change costs the main loop a few frames: hold longer when the sequencer is running)
    pb.button_release(btn)
    pb.tick(2)
    pb.button_release(held)
    pb.tick(settle)


def tap(pb, btn, settle=6):
    pb.button_press(btn)
    pb.tick(3)
    pb.button_release(btn)
    pb.tick(settle)


CHAIN = sym["wChain"]
CHAIN_LEN = 32


def set_chain(mem, *rows):
    """The chain: rows = lists of pattern numbers per channel (one list: all four alike); every other step is the end."""
    if len(rows) == 1:
        rows = rows * 4
    for c, steps in enumerate(rows):
        mem[CHAIN + c * CHAIN_LEN:CHAIN + (c + 1) * CHAIN_LEN] = bytes(list(steps) + [0xFF] * (CHAIN_LEN - len(steps)))
HI = 1                          # the pattern numbers of wEditBank / wPlayBank are 1-based

with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]

    # --- defaults
    check("boot: chain = pattern 1 then the end", mem[CHAIN] == 0 and all(mem[CHAIN + i] == 0xFF for i in range(1, 32)) and all(mem[CHAIN + c * CHAIN_LEN + i] == (0 if i == 0 else 0xFF) for c in range(4) for i in range(CHAIN_LEN)))
    check("boot: loop mode, pattern 1 edited and played", v("wSongMode") == 0 and v("wEditBank") == HI and v("wPlayBank") == HI)
    check("boot: patterns 2-16 hold no page, pattern 1 holds its first half", not any(Pool(mem, sym).half_lent(p_, g) for p_ in range(1, 16) for g in range(2)) and Pool(mem, sym).half_lent(0, 0) and not Pool(mem, sym).half_lent(0, 1))
    check("boot: the demo is pattern 1", Pool(mem, sym).get(0, 0, 0, 0) == 60)

    # --- the song screen
    combo(pb, "start", "up")
    check("START+UP opens the song screen", v("wScreen") == 5, v("wScreen"))
    combo(pb, "start", "right")
    combo(pb, "start", "left")
    check("START+LEFT/RIGHT do nothing there", v("wScreen") == 5)
    combo(pb, "start", "up")
    check("START+UP does nothing there either", v("wScreen") == 5)
    combo(pb, "start", "down")
    check("START+DOWN goes back to the play screen", v("wScreen") == 0, v("wScreen"))
    combo(pb, "start", "right")                      # edit screen
    combo(pb, "start", "up")
    combo(pb, "start", "down")
    check("... and back to the edit screen when it came from there", v("wScreen") == 1, v("wScreen"))
    combo(pb, "start", "left")
    combo(pb, "start", "up")
    pb.tick(30)

    def row_text(r, n=18):
        return bytes(mem[0x9800 + r * 32 + i] for i in range(n))

    tiles = lambda s: bytes(ord(c) - 32 for c in s)
    def cell(c, i):
        """(cursor mark, pattern tile) of CH(c+1) in the page's cell i."""
        r = row_text(7 + c, 20)
        return r[2 + 2 * i], r[3 + 2 * i]

    check("the CH1 row shows 'C1', the cursor on step 1 and the end mark after it", row_text(7)[:4] == tiles("C1>1") and cell(0, 1) == (0, ord("-") - 32), row_text(7))
    check("CH2 shows 'C2' and its own pattern 1 without the cursor", row_text(8)[:4] == tiles("C2 1"), row_text(8))
    check("the header numbers the steps 1-8 and shows page 1", row_text(6, 20)[2:18] == b"".join(bytes([0, ord(str(n)) - 32]) for n in range(1, 9)) and row_text(12, 20)[12:20] == tiles("PAGE 1/4"), row_text(12, 20))
    check("the mode row shows LOOP, the edit row P1", row_text(2)[6:10] == tiles("LOOP") and row_text(3)[6:8] == tiles("P1"), (row_text(2), row_text(3)))

    # --- steps: A / B edit the cell of the cursor's channel only
    check("the cursor starts on step 1, channel 1", v("wSongCur") == 0 and v("wSongCh") == 0)
    tap(pb, "b")
    check("B on CH1 step 1: the end (another channel still has a pattern on that step)", mem[CHAIN] == 0xFF, mem[CHAIN])
    check("... and the other channels did not change", all(mem[CHAIN + c * CHAIN_LEN] == 0 for c in range(1, 4)), [mem[CHAIN + c * CHAIN_LEN] for c in range(4)])
    tap(pb, "a")
    check("A on the last pattern of step 1: back to pattern 1", mem[CHAIN] == 0, mem[CHAIN])
    tap(pb, "right")
    check("RIGHT moves the cursor", v("wSongCur") == 1)
    tap(pb, "a")
    check("A on the end: pattern 1 (CH1 only)", mem[CHAIN + 1] == 0 and all(mem[CHAIN + c * CHAIN_LEN + 1] == 0xFF for c in range(1, 4)), [mem[CHAIN + c * CHAIN_LEN + 1] for c in range(4)])
    for want in list(range(1, 16)) + [0xFF, 0]:
        tap(pb, "a")
        check(f"A steps the pattern to {want}", mem[CHAIN + 1] == want, mem[CHAIN + 1])
    mem[CHAIN + 1] = 0
    tap(pb, "b")
    check("B on pattern 1 (step 2) gives the end", mem[CHAIN + 1] == 0xFF, mem[CHAIN + 1])
    tap(pb, "b")
    check("B on the end gives the last pattern", mem[CHAIN + 1] == 15, mem[CHAIN + 1])
    pb.tick(20)
    check("the CH1 row shows step 2 as pattern 16, written G", cell(0, 1)[1] == ord("G") - 32, row_text(7, 20))
    tap(pb, "left")
    pb.tick(20)
    check("the cursor mark moved back to step 1", cell(0, 0) == (ord(">") - 32, ord("1") - 32) and cell(0, 1) == (0, ord("G") - 32), row_text(7, 20))

    # --- the other channels: DOWN / UP, and they may be the end (silence) on any step, even step 1
    tap(pb, "down")
    check("DOWN moves to CH2", v("wSongCh") == 1 and v("wSongCur") == 0, (v("wSongCh"), v("wSongCur")))
    pb.tick(20)
    check("the cursor mark is on the CH2 row now and left the CH1 row", cell(1, 0)[0] == ord(">") - 32 and cell(0, 0)[0] == 0, (row_text(7, 20), row_text(8, 20)))
    tap(pb, "b")
    check("B on CH2 step 1 gives the end (only CH1 needs a step 1)", mem[CHAIN + CHAIN_LEN] == 0xFF, mem[CHAIN + CHAIN_LEN])
    tap(pb, "b")
    check("B on the end gives the last pattern", mem[CHAIN + CHAIN_LEN] == 15, mem[CHAIN + CHAIN_LEN])
    tap(pb, "a")
    tap(pb, "a")
    check("A wraps the last pattern -> end -> pattern 1 (CH2 may be the end on step 1)", mem[CHAIN + CHAIN_LEN] == 0, mem[CHAIN + CHAIN_LEN])
    check("... CH1 step 1 is untouched", mem[CHAIN] == 0)
    for _ in range(5):
        tap(pb, "down")
    check("DOWN stops at CH4", v("wSongCh") == 3, v("wSongCh"))
    for _ in range(5):
        tap(pb, "up")
    check("UP stops at CH1", v("wSongCh") == 0, v("wSongCh"))
    for _ in range(7):
        tap(pb, "right")
    check("the cursor reaches step 8 (the end of page 1)", v("wSongCur") == 7, v("wSongCur"))
    pb.tick(20)
    check("... still page 1", row_text(12, 20)[12:20] == tiles("PAGE 1/4"), row_text(12, 20))
    tap(pb, "right")
    pb.tick(30)
    hdr = row_text(6, 20)
    check("RIGHT onto step 9: page 2, the header starts over at 1 and shows page 2", v("wSongCur") == 8 and row_text(12, 20)[12:20] == tiles("PAGE 2/4") and bytes(hdr[3 + 2 * i] for i in range(8)) == tiles("12345678"), hdr)
    check("... and the cursor shows in the first cell of the CH1 row", cell(0, 0)[0] == ord(">") - 32, row_text(7, 20))
    for _ in range(40):
        tap(pb, "right")
    check("RIGHT stops at step 32 (page 4)", v("wSongCur") == 31 and row_text(12, 20)[12:20] == tiles("PAGE 4/4"), (v("wSongCur"), row_text(12, 20)))
    for _ in range(40):
        tap(pb, "left", 3)
    check("LEFT stops at step 1 (page 1)", v("wSongCur") == 0 and row_text(12, 20)[12:20] == tiles("PAGE 1/4"), (v("wSongCur"), row_text(12, 20)))
    mem[CHAIN + CHAIN_LEN] = 0
    tap(pb, "right")
    mem[CHAIN + 1] = 0xFF

    # --- a held A / B repeats (the d-pad does already); with SELECT held it does not
    tap(pb, "left")
    check("the cursor is on CH1 step 1, pattern 1", v("wSongCur") == 0 and v("wSongCh") == 0 and mem[CHAIN] == 0)
    pb.button_press("a")
    pb.tick(40)
    held = mem[CHAIN]
    check("holding A steps the pattern on (more than the one press)", 4 <= held <= 9, held)
    pb.tick(30)
    check("... and goes on while it stays held", mem[CHAIN] != held, (held, mem[CHAIN]))
    pb.button_release("a")
    pb.tick(10)
    stopped = mem[CHAIN]
    pb.tick(30)
    check("... and stops when A is released", mem[CHAIN] == stopped, (stopped, mem[CHAIN]))
    mem[CHAIN] = 0
    pb.button_press("select")
    pb.tick(3)
    pb.button_press("b")
    pb.tick(40)
    pb.button_release("b")
    pb.tick(2)
    pb.button_release("select")
    pb.tick(6)
    check("SELECT+B held on the song screen does not change the pattern (and the save runs once, not repeatedly)", mem[CHAIN] == 0, mem[CHAIN])

    # --- the edited pattern is the one in the cell under the cursor (CH1, step 1 here), and mode
    tap(pb, "a")
    check("A on the cell: pattern 2 is edited (the cell and the edit follow each other)", mem[CHAIN] == 1 and v("wEditPat") == 1 and v("wEditBank") == 2, (mem[CHAIN], v("wEditPat"), v("wEditBank")))
    check("... and in loop mode that is the pattern that plays", v("wPlayBank") == 2, v("wPlayBank"))
    check("... without changing channel", v("wSelCh") == 0)
    for _ in range(14):
        tap(pb, "a")
    check("A on to pattern 16", v("wEditPat") == 15 and v("wEditBank") == 16, (v("wEditPat"), v("wEditBank")))
    for _ in range(15):
        tap(pb, "b")
    check("... and B back to pattern 1", v("wEditPat") == 0 and v("wEditBank") == HI and mem[CHAIN] == 0, (v("wEditPat"), mem[CHAIN]))
    combo(pb, "select", "up")
    check("SELECT+UP: song mode", v("wSongMode") == 1, v("wSongMode"))
    tap(pb, "a")
    check("in song mode editing another pattern does not change what plays", v("wEditPat") == 1 and v("wPlayBank") == HI, (v("wEditPat"), v("wPlayBank")))
    pb.tick(20)
    check("the mode row shows SONG, the edit row P2", row_text(2)[6:10] == tiles("SONG") and row_text(3)[6:8] == tiles("P2"), (row_text(2), row_text(3)))
    tap(pb, "b")
    combo(pb, "select", "down")
    check("SELECT+DOWN: back to loop mode", v("wSongMode") == 0)
    # SELECT+LEFT / RIGHT do not edit a pattern any more
    combo(pb, "select", "right")
    check("SELECT+RIGHT does nothing on the song screen now", v("wEditPat") == 0 and mem[CHAIN] == 0, (v("wEditPat"), mem[CHAIN]))

    # --- the cursor decides the edited pattern: another channel / step has another pattern
    mem[CHAIN + CHAIN_LEN] = 3                         # CH2, step 1: pattern 4
    mem[CHAIN + 1] = 5                                 # CH1, step 2: pattern 6
    tap(pb, "down")
    check("DOWN to CH2: pattern 4 is edited, and CH2 is the selected channel", v("wEditPat") == 3 and v("wSelCh") == 1, (v("wEditPat"), v("wSelCh")))
    tap(pb, "up")
    tap(pb, "right")
    check("RIGHT to step 2 on CH1: pattern 6 is edited", v("wEditPat") == 5 and v("wSelCh") == 0, (v("wEditPat"), v("wSelCh")))
    tap(pb, "left")
    check("LEFT back: pattern 1", v("wEditPat") == 0, v("wEditPat"))
    # an empty cell: a pattern nobody uses is the candidate; it goes in the chain with its first note only
    tap(pb, "down")
    tap(pb, "down")
    tap(pb, "down")                                    # CH4, step 1
    mem[CHAIN + 3 * CHAIN_LEN] = 0xFF
    tap(pb, "up")
    tap(pb, "down")                                    # (the cell is empty now: look at it again)
    check("an empty cell: the edited pattern is one that no chain cell uses (not 1, 4, 6)", v("wEditPat") not in (0, 3, 5), v("wEditPat"))
    cand = v("wEditPat")
    check("... and it is not in the chain yet", mem[CHAIN + 3 * CHAIN_LEN] == 0xFF, mem[CHAIN + 3 * CHAIN_LEN])
    tap(pb, "up")
    tap(pb, "down")
    check("looking at an empty cell again leaves the chain as it was", mem[CHAIN + 3 * CHAIN_LEN] == 0xFF, mem[CHAIN + 3 * CHAIN_LEN])
    tap(pb, "b")                                       # the empty cell: B gives the last pattern, that is no way to keep it empty: go on
    mem[CHAIN + 3 * CHAIN_LEN] = 0xFF
    for _ in range(3):
        tap(pb, "up")
    tap(pb, "right")
    tap(pb, "left")                                    # back on CH1, step 1
    check("back on CH1 step 1: pattern 1", v("wEditPat") == 0, v("wEditPat"))

    # --- patterns are separate: the roll writes into the edited pattern
    tap(pb, "a")                                       # the cell holds pattern 2: it is edited
    combo(pb, "start", "down")
    combo(pb, "start", "right")
    combo(pb, "start", "right")                        # the piano roll
    pb.tick(30)
    check("on the piano roll", v("wScreen") == 2, v("wScreen"))
    mem[sym["wRollNote"]] = 70
    mem[sym["wRollTick"]] = 0
    mem[sym["wRollCell"]] = 0
    tap(pb, "a")
    pb.button_release("a")
    pb.tick(10)
    check("A on the roll placed the note in pattern 2, channel 1", Pool(mem, sym).get(1, 0, 0, 0) == 70, Pool(mem, sym).get(1, 0, 0, 0))
    check("... and pattern 1 is untouched", Pool(mem, sym).get(0, 0, 0, 0) == 60, Pool(mem, sym).get(0, 0, 0, 0))
    pb.stop(save=False)

# --- playback of a chain
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    for p_ in range(16):
        Pool(mem, sym).clear_pattern(p_)
    Pool(mem, sym).put(0, 0, 0, 0, 60)  # pattern 1: C4 on channel 1 at tick 0
    Pool(mem, sym).put(1, 0, 0, 0, 64)  # pattern 2: E4
    Pool(mem, sym).put(2, 0, 0, 0, 67)  # pattern 3: G4
    mem[sym["wSeqBars"]] = 1            # one bar per pattern
    mem[sym["wBpm"]] = 240             # a bar = 60 frames
    set_chain(mem, [0, 1, 0, 2])
    combo(pb, "start", "up")
    combo(pb, "select", "up")
    check("song mode is on", v("wSongMode") == 1)
    combo(pb, "start", "down")
    combo(pb, "select", "start")
    check("the sequencer runs", v("wSeqPlay") == 1)
    check("it starts on the first chain step", v("wChainPos") == 0 and v("wPlayBank") == HI)
    seen = []
    notes = []
    for _ in range(60):
        pb.tick(8)
        seen.append(v("wChainPos"))
        notes.append(mem[sym["wCurNote"]])
    # collapse runs
    runs = [seen[0]]
    for s_ in seen[1:]:
        if s_ != runs[-1]:
            runs.append(s_)
    check("the chain steps go 0,1,2,3 and round again", runs[:6] == [0, 1, 2, 3, 0, 1], runs)
    nruns = [notes[0]]
    for n in notes[1:]:
        if n != nruns[-1]:
            nruns.append(n)
    check("the notes follow the chain: C4, E4, C4, G4, C4", nruns[:6] in ([60, 64, 60, 67, 60, 64], [0, 60, 64, 60, 67, 60]) or nruns[:5] == [60, 64, 60, 67, 60], nruns[:8])
    # stop and loop mode plays the edited pattern
    combo(pb, "select", "start", hold=8)
    check("SELECT+START stops", v("wSeqPlay") == 0)
    combo(pb, "start", "up")
    combo(pb, "select", "down")
    combo(pb, "start", "down")
    combo(pb, "select", "start")
    pb.tick(150)
    check("loop mode: the edited pattern plays over and over", v("wPlayBank") == HI and v("wChainPos") == 0, (v("wPlayBank"), v("wChainPos")))
    pb.stop(save=False)


# --- switching the pattern while it plays must not leave a note hanging; the playing step is marked
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    tiles = lambda s_: bytes(ord(c) - 32 for c in s_)
    for p_ in range(16):
        Pool(mem, sym).clear_pattern(p_)
    Pool(mem, sym).put(0, 0, 0, 0, 60)  # pattern 1: a note at tick 0 that nothing ends
    mem[sym["wSeqBars"]] = 1
    combo(pb, "start", "up")
    combo(pb, "select", "start")
    pb.tick(60)
    check("pattern 1 plays and its note sounds", v("wSeqPlay") == 1 and mem[sym["wCurNote"]] == 60, (v("wSeqPlay"), mem[sym["wCurNote"]]))
    mem[sym["wBpm"]] = 90              # a bar (48 ticks) = 2 s at 90 BPM, so a switch has time to wait
    tap(pb, "a")                       # edit pattern 2 while pattern 1 plays (loop mode)
    check("the edited pattern is queued: it takes over at the next bar line, not now", v("wPlayBank") == 1 and v("wQueuedBank") == 2,
          (v("wPlayBank"), v("wQueuedBank")))
    check("... the old note keeps sounding until then", mem[sym["wCurNote"]] == 60, mem[sym["wCurNote"]])
    pb.tick(20)
    row = bytes(mem[0x9800 + 4 * 32 + i] for i in range(20))
    check("the song screen says PLAY P1 / NEXT P2", row[:4] == bytes(ord(c) - 32 for c in "PLAY") and row[6] == ord("P") - 32 and row[7] == ord("1") - 32
          and row[9:13] == bytes(ord(c) - 32 for c in "NEXT") and row[14] == ord("P") - 32 and row[15] == ord("2") - 32, list(row))
    at = None
    for _ in range(200):
        pb.tick(1)
        if v("wPlayBank") == 2:
            at = v("wSeqCur")
            break
    check("the switch happens on a bar line (tick 0 of the bar)", at is not None and at % 48 in (0, 1, 47), at)
    pb.tick(4)
    check("... the old pattern's note was released (no hanging note)", all(mem[sym["wCurNote"] + c] == 0 for c in range(4)),
          [mem[sym["wCurNote"] + c] for c in range(4)])
    check("... and nothing waits any more", v("wQueuedBank") == 0, v("wQueuedBank"))
    # choosing a pattern and then going back to the playing one before the bar line cancels the switch
    tap(pb, "b")                       # pattern 1 is queued (pattern 2 plays)
    check("pattern 1 queued while 2 plays", v("wQueuedBank") == 1 and v("wPlayBank") == 2, (v("wQueuedBank"), v("wPlayBank")))
    tap(pb, "a")                       # back to 2, the playing one: nothing waits
    check("going back to the playing pattern cancels the queue", v("wQueuedBank") == 0 and v("wPlayBank") == 2, (v("wQueuedBank"), v("wPlayBank")))
    tap(pb, "b")
    tap(pb, "a")
    tap(pb, "b")                       # the last choice wins
    for _ in range(200):
        pb.tick(1)
        if v("wPlayBank") == 1:
            break
    check("the last choice before the bar line wins (pattern 1 plays again)", v("wPlayBank") == 1, v("wPlayBank"))
    pb.tick(60)
    check("back on pattern 1 its note sounds again", mem[sym["wCurNote"]] == 60, mem[sym["wCurNote"]])
    # stopped: the edited pattern is the played one at once
    combo(pb, "select", "start")
    check("stopped", v("wSeqPlay") == 0)
    tap(pb, "a")
    check("stopped: the edited pattern plays at once, nothing is queued", v("wPlayBank") == 2 and v("wQueuedBank") == 0, (v("wPlayBank"), v("wQueuedBank")))
    tap(pb, "b")
    combo(pb, "select", "start")       # play again from pattern 1
    pb.tick(10)
    # song mode: the playing step is shown as [n]
    set_chain(mem, [0, 1])
    combo(pb, "select", "up")          # song mode (restarts the song, silences)
    check("switching to song mode silences the old note and restarts", v("wSongMode") == 1 and v("wChainPos") == 0 and v("wPlayBank") == HI, (v("wChainPos"), v("wPlayBank")))
    pb.tick(10)
    mark = lambda: bytes(mem[0x9800 + 11 * 32 + i] for i in range(20))
    for ch in "^>":
        tile = [mem[0x8000 + (ord(ch) - 32) * 16 + i] for i in range(16)]
        check(f"the font has a glyph for '{ch}' (the marks must be visible, not just in the map)", any(tile), tile)
    caret = ord("^") - 32
    check("step 1 is marked under the grid: '^' under its pattern", mark()[3] == caret and mark()[5] == 0, mark())
    pb.tick(80)                        # the second pattern now (a bar is 120 frames at 120 BPM: wait for it)
    for _ in range(60):
        pb.tick(4)
        if v("wChainPos") == 1:
            break
    pb.tick(15)
    check("step 2 is marked and step 1 lost its mark", mark()[3] == 0 and mark()[5] == caret, mark())
    play = lambda: bytes(mem[0x9800 + 4 * 32 + i] for i in range(20))
    check("the PLAY row names the playing step: PAGE1 STEP2", play()[9:20] == tiles("PAGE1 STEP2"), play())
    tap(pb, "up")  # (nothing: the cursor is on CH1)
    for _ in range(8):
        tap(pb, "right")
    pb.tick(20)
    check("the cursor on page 2 while step 2 plays: no '^' (it is on page 1), the PLAY row still says step 2", caret not in mark()[2:18] and play()[9:20] == tiles("PAGE1 STEP2"), (mark(), play()))
    for _ in range(8):
        tap(pb, "left")
    pb.tick(20)
    check("back on page 1: the '^' is back", mark()[5] == caret, mark())
    saved = (mem[sym["wChainPos"]], mem[sym["wDirtySong"]])
    mem[sym["wChainPos"]] = 11         # (the redraw reads the chain position: step 12 = page 2, place 4)
    mem[sym["wDirtySong"]] |= 1
    pb.tick(3)
    check("the PLAY row says PAGE2 STEP4 for chain step 12", play()[9:20] == tiles("PAGE2 STEP4"), play())
    mem[sym["wChainPos"]] = saved[0]
    mem[sym["wDirtySong"]] |= 1
    pb.tick(3)
    combo(pb, "select", "start")
    pb.tick(15)
    check("stopped: the mark and the STEP text are gone", caret not in mark() and play()[9:13] != tiles("PAGE"), (mark(), play()))
    pb.stop(save=False)


# --- step length = the longest pattern in the step (a shorter one repeats), and the song ends where no channel has a pattern
CELL_OFF = 0xFF


def note_at(pool, p, ch, tick, note):
    pool.put_abs(p, ch, tick, note)
    pool.put_abs(p, ch, tick + 12, CELL_OFF)


def start_song(rom_src, setup):
    tmp = tempfile.TemporaryDirectory()
    rom = pathlib.Path(tmp.name) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    pool = Pool(mem, sym)
    for p_ in range(16):
        pool.clear_pattern(p_)
    mem[sym["wSeqBars"]] = 1                         # the edited pattern (1) has one bar ...
    mem[sym["wPatBars"]] = 1
    mem[sym["wPatBars"] + 1] = 2                     # ... pattern 2 has two
    mem[sym["wBpm"]] = 240                           # a bar = 60 frames
    setup(mem, pool)
    mem[sym["wSongMode"]] = 1
    combo(pb, "select", "start")
    return tmp, pb, mem


def sample(pb, mem, frames):
    out = []
    for _ in range(frames):
        pb.tick(1)
        out.append((mem[sym["wChainPos"]], mem[sym["wCurNote"]], mem[sym["wCurNote"] + 1]))
    return out


def edges(vals):
    n, prev = 0, 0
    for x in vals:
        if x != 0 and prev == 0:
            n += 1
        prev = x
    return n


def setup_len(mem, pool):
    note_at(pool, 0, 0, 0, 60)                        # pattern 1, CH1: C4 at the start of its one bar
    note_at(pool, 1, 1, 0, 64)                        # pattern 2, CH2: E4 at the start of its two bars
    set_chain(mem, [0, 0], [1], [], [])               # step 1: CH1 pattern 1 + CH2 pattern 2; step 2: CH1 pattern 1 alone


tmp, pb, mem = start_song(rom_src, setup_len)
smp = sample(pb, mem, 520)
step0 = [s for s in smp[:200] if s[0] == 0]
first1 = next(i for i, s in enumerate(smp) if s[0] == 1)
dur0 = first1
dur1 = next(i for i, s in enumerate(smp[first1:]) if s[0] != 1)
check("step 1 lasts as long as its longest pattern (2 bars = about 120 frames)", 110 <= dur0 <= 130, dur0)
check("step 2 lasts one bar (about 60 frames): CH2 has no pattern there", 50 <= dur1 <= 70, dur1)
check("in step 1 the one-bar pattern of CH1 plays twice (it repeats), the two-bar one of CH2 once",
      edges([s[1] for s in smp[:first1]]) == 2 and edges([s[2] for s in smp[:first1]]) == 1,
      (edges([s[1] for s in smp[:first1]]), edges([s[2] for s in smp[:first1]])))
runs = [smp[0][0]]
for s_ in smp[1:]:
    if s_[0] != runs[-1]:
        runs.append(s_[0])
check("the song ends after step 2 (no channel has a pattern on step 3): 1, 2, 1, 2 ...", runs[:5] == [0, 1, 0, 1, 0], runs)
pb.stop(save=False)
tmp.cleanup()


def setup_end(mem, pool):
    note_at(pool, 0, 0, 0, 60)                        # pattern 1, CH1
    note_at(pool, 1, 1, 0, 64)                        # pattern 2, CH2
    set_chain(mem, [0], [0xFF, 1], [], [])            # step 1: CH1 only; step 2: CH2 only (CH1 is the end there, the song goes on)


tmp, pb, mem = start_song(rom_src, setup_end)
smp = sample(pb, mem, 400)
runs = [smp[0][0]]
for s_ in smp[1:]:
    if s_[0] != runs[-1]:
        runs.append(s_[0])
check("a step whose CH1 is the end plays on while another channel has a pattern: 1, 2, 1, 2", runs[:5] == [0, 1, 0, 1, 0], runs)
in2 = [s for s in smp[:240] if s[0] == 1]
check("... and in it CH2 sounds and CH1 is silent", any(s[2] == 64 for s in in2) and all(s[1] == 0 for s in in2[5:]), (len(in2), in2[:3]))
pb.stop(save=False)
tmp.cleanup()

# --- the end is refused where it would leave step 1 with no pattern at all
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    set_chain(mem, [0], [], [], [])
    combo(pb, "start", "up")                          # the song screen, the cursor on CH1 step 1
    tap(pb, "b")
    check("B on the only pattern of step 1: not the end (a song needs one step) but the last pattern", mem[CHAIN] == 15, mem[CHAIN])
    mem[CHAIN] = 0
    mem[CHAIN + CHAIN_LEN] = 0                       # CH2 has a pattern on step 1 too
    tap(pb, "b")
    check("... with another channel there, the end is offered", mem[CHAIN] == 0xFF, mem[CHAIN])
    pb.stop(save=False)

# --- an empty cell: the roll opens a candidate pattern; its first note puts it in the chain
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    pool = Pool(mem, sym)
    for p_ in range(16):
        pool.clear_pattern(p_)
    set_chain(mem, [0, 3], [0], [0], [0])               # CH1: patterns 1 and 4; CH2-4: pattern 1 only
    pool.put(1, 0, 0, 0, 55)                            # pattern 2 holds a note on CH1 only: that must not matter to CH2
    combo(pb, "start", "up")                            # the song screen
    tap(pb, "down")                                     # CH2, step 1 (pattern 1)
    tap(pb, "right")                                    # step 2: CH2 is empty there
    check("CH2 step 2 is empty", mem[CHAIN + CHAIN_LEN + 1] == 0xFF, mem[CHAIN + CHAIN_LEN + 1])
    cand = v("wEditPat")
    check("CH2's row has only pattern 1: the candidate is pattern 2 for CH2 (whatever CH1 uses: patterns 1 and 4; pattern 2's CH1 part holds a note: that is CH1's)", cand == 1, cand)
    check("... it is not in the chain yet", mem[CHAIN + CHAIN_LEN + 1] == 0xFF)
    combo(pb, "start", "down")                          # back to the screen the song screen was opened from
    combo(pb, "start", "right")
    combo(pb, "start", "right")                         # the piano roll
    pb.tick(30)
    check("on the roll: channel 2, the candidate pattern", v("wScreen") == 2 and v("wSelCh") == 1 and v("wEditPat") == cand, (v("wScreen"), v("wSelCh"), v("wEditPat")))
    check("... and still nothing in the chain", mem[CHAIN + CHAIN_LEN + 1] == 0xFF)
    mem[sym["wRollNote"]] = 62
    mem[sym["wRollTick"]] = 0
    mem[sym["wRollCell"]] = 0
    mem[sym["wRollSeg"]] = 0
    tap(pb, "a")
    pb.button_release("a")
    pb.tick(10)
    check("the first note went into the candidate pattern, channel 2", pool.get(cand, 1, 0, 0) == 62, pool.get(cand, 1, 0, 0))
    check("... and the candidate is in the chain now: CH2, step 2", mem[CHAIN + CHAIN_LEN + 1] == cand, mem[CHAIN + CHAIN_LEN + 1])
    check("... the other channels of that step are untouched", all(mem[CHAIN + c * CHAIN_LEN + 1] == (3 if c == 0 else 0xFF) for c in range(4) if c != 1), [mem[CHAIN + c * CHAIN_LEN + 1] for c in range(4)])
    # START+A on the roll gives that cell the next pattern (not the other channels)
    combo(pb, "start", "a")
    check("START+A: CH2 step 2 gets the next pattern; CH1 step 2 keeps pattern 4", mem[CHAIN + CHAIN_LEN + 1] == cand + 1 and mem[CHAIN + 1] == 3, (mem[CHAIN + CHAIN_LEN + 1], mem[CHAIN + 1]))
    check("... and the edited pattern is the new one", v("wEditPat") == cand + 1, v("wEditPat"))
    # back to channel 1: its cell at this step (pattern 4) is edited
    tap(pb, "select")
    tap(pb, "select")
    tap(pb, "select")
    check("three channel taps from CH2 round to CH1: its cell (pattern 4) is edited", v("wSelCh") == 0 and v("wEditPat") == 3, (v("wSelCh"), v("wEditPat")))
    # a part of this channel that already holds notes is passed over, a clean one is preferred
    pool.put(cand + 2, 1, 0, 0, 56)                     # a leftover note in CH2's part of the number after the next
    tap(pb, "select")                                   # CH2
    combo(pb, "start", "up")                            # the song screen
    tap(pb, "right")                                    # CH2 step 3 (empty): its row has 1 and cand + 1
    check("CH2 step 3: the first number that is free in CH2's row and clean in CH2's part: 0 and 2 are in the row, 1 and 3 hold notes on CH2, so pattern 5",
          v("wEditPat") == 4, (v("wEditPat"), cand))
    pb.stop(save=False)

# --- a note that is still sounding at the end of a chain step does not carry into the next pattern
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    for p_ in range(16):
        Pool(mem, sym).clear_pattern(p_)
    Pool(mem, sym).put(0, 0, 0, 0, 36)  # pattern 1: a bass note on channel 1 that nothing ends
    Pool(mem, sym).put(1, 1, 0, 0, 72)  # pattern 2: a note on channel 2 only
    mem[sym["wSeqBars"]] = 1
    mem[sym["wBpm"]] = 240             # a bar = 60 frames
    set_chain(mem, [0, 1])
    combo(pb, "start", "up")
    combo(pb, "select", "up")
    combo(pb, "start", "down")
    combo(pb, "select", "start")
    pb.tick(20)
    check("pattern 1's bass note sounds", mem[sym["wCurNote"]] == 36, mem[sym["wCurNote"]])
    for _ in range(40):
        pb.tick(2)
        if v("wChainPos") == 1:
            break
    pb.tick(12)
    check("in pattern 2 the old bass note is gone and channel 2 plays", v("wChainPos") == 1 and mem[sym["wCurNote"]] == 0 and mem[sym["wCurNote"] + 1] == 72,
          (v("wChainPos"), mem[sym["wCurNote"]], mem[sym["wCurNote"] + 1]))
    pb.stop(save=False)

# --- saving and loading a whole song
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    for p_ in range(4):
        for c in range(4):
            for t in (0, 5, 100, 191):
                Pool(mem, sym).put(p_, c, 0, t, 40 + p_ * 5 + c + (t % 7))
                Pool(mem, sym).put(p_, c, 1, t, 90 + p_ * 5 + c + (t % 7))    # segment 2 too
    set_chain(mem, [3, 0, 2, 2, 1])
    mem[CHAIN + 6] = 20           # a damaged step (the patterns are 0-15): it must not survive a load
    mem[sym["wBpm"]] = 141
    mem[sym["wSeqBars"]] = 6
    snapshot = {(p_, c, g): [Pool(mem, sym).get(p_, c, g, t) for t in range(192)] for p_ in range(4) for c in range(4) for g in range(2)}
    combo(pb, "select", "b", 30)
    check("SELECT+B saves the song", v("wMsg") == 1, v("wMsg"))
    for p_ in range(16):
        Pool(mem, sym).clear_pattern(p_)
    set_chain(mem, [0])
    mem[sym["wBpm"]] = 90
    combo(pb, "select", "a", 30)
    check("SELECT+A loads it", v("wMsg") == 2, v("wMsg"))
    check("all four patterns are restored exactly (both segments of every channel)",
          all([Pool(mem, sym).get(p_, c, g, t) for t in range(192)] == snapshot[(p_, c, g)]
              for p_ in range(4) for c in range(4) for g in range(2)))
    check("the chain is restored", bytes(mem[CHAIN:CHAIN + 5]) == bytes([3, 0, 2, 2, 1]) and mem[CHAIN + 5] == 0xFF)
    check("a damaged chain step becomes the end", mem[CHAIN + 6] == 0xFF, mem[CHAIN + 6])
    check("BPM and the first pattern's loop length are restored", v("wBpm") == 141 and mem[sym["wPatBars"]] == 6, (v("wBpm"), mem[sym["wPatBars"]]))
    check("loading edits the pattern in the cursor's cell (CH1, step 1: pattern 4) in loop mode", v("wEditPat") == 3 and v("wSongMode") == 0 and v("wEditBank") == 4 and v("wPlayBank") == 4, (v("wEditPat"), v("wEditBank"), v("wPlayBank")))
    pb.stop(save=True)
    pb = boot(rom)
    mem = pb.memory
    check("reboot: the song is loaded from slot 1", bytes(mem[CHAIN:CHAIN + 5]) == bytes([3, 0, 2, 2, 1]) and mem[sym["wBpm"]] == 141,
          (bytes(mem[CHAIN:CHAIN + 5]), mem[sym["wBpm"]]))
    check("reboot: pattern 4's cells are there", Pool(mem, sym).get(3, 1, 0, 100) == 40 + 15 + 1 + (100 % 7) and Pool(mem, sym).get(3, 1, 1, 100) == 90 + 15 + 1 + (100 % 7), Pool(mem, sym).get(3, 1, 0, 100))
    pb.stop(save=False)

# --- every channel follows its own row of the chain; a channel with no pattern in a step is silent; the chain is saved per channel
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    for p_ in range(16):
        Pool(mem, sym).clear_pattern(p_)
    for p_, (a, b, c, d) in enumerate([(60, 62, 64, 65), (67, 69, 71, 72)]):
        Pool(mem, sym).put(p_, 0, 0, 0, a)
        Pool(mem, sym).put(p_, 1, 0, 0, b)
        Pool(mem, sym).put(p_, 2, 0, 0, c)
        Pool(mem, sym).put(p_, 3, 0, 0, d)
    mem[sym["wSeqBars"]] = 1
    mem[sym["wBpm"]] = 240             # a bar = 60 frames
    # CH1: P1 P2   CH2: P2 P1   CH3: P1 P1   CH4: P2 none
    set_chain(mem, [0, 1], [1, 0], [0, 0], [1])
    combo(pb, "start", "up")
    combo(pb, "select", "up")
    combo(pb, "start", "down")
    combo(pb, "select", "start")
    pb.tick(20)
    notes = lambda: [mem[sym["wCurNote"] + c] for c in range(4)]
    check("step 1: every channel plays its own pattern (CH1 P1, CH2 P2, CH3 P1, CH4 P2)", v("wChainPos") == 0 and notes() == [60, 69, 64, 72], (v("wChainPos"), notes()))
    for _ in range(40):
        pb.tick(2)
        if v("wChainPos") == 1:
            break
    pb.tick(12)
    check("step 2: CH1 P2, CH2 P1, CH3 P1, and CH4 (no pattern) is silent", v("wChainPos") == 1 and notes() == [67, 62, 64, 0], (v("wChainPos"), notes()))
    pb.stop(save=False)

with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    rows = [[0, 1, 2] + [5] * 20, [3, 3], [0, 0, 0, 0, 7], [15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 0]]
    set_chain(mem, *rows)
    combo(pb, "select", "b", 30)
    check("SELECT+B saves the song", v("wMsg") == 1, v("wMsg"))
    set_chain(mem, [0])
    combo(pb, "select", "a", 30)
    check("SELECT+A loads it", v("wMsg") == 2, v("wMsg"))
    got = [list(mem[CHAIN + c * CHAIN_LEN:CHAIN + (c + 1) * CHAIN_LEN]) for c in range(4)]
    check("the four chain rows of 32 steps are restored", got == [list(r) + [0xFF] * (CHAIN_LEN - len(r)) for r in rows], got)
    pb.stop(save=True)
    pb = boot(rom)
    mem = pb.memory
    got = [list(mem[CHAIN + c * CHAIN_LEN:CHAIN + (c + 1) * CHAIN_LEN]) for c in range(4)]
    check("reboot: the chain comes from the slot", got == [list(r) + [0xFF] * (CHAIN_LEN - len(r)) for r in rows], got)
    pb.stop(save=False)

# --- the sequencer clock is steady while the play and edit screens are shown: the piano roll is not drawn for a screen that does not show it
# (a pass of the main loop that takes more than one frame makes the ticks late; the roll used to cost 2-3 frames a pass there)
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    pool = Pool(mem, sym)
    for p_ in range(16):
        pool.clear_pattern(p_)
    for t in range(0, 384, 6):
        pool.put(0, 0, t // 192, t % 192, 60 + 2 * ((t // 6) % 2))
    mem[sym["wSeqBars"]] = 8
    mem[sym["wPatBars"]] = 8
    mem[sym["wBpm"]] = 120
    frames = []
    pb.hook_register(0, sym["SeqTick"], lambda ctx: frames.append(mem[sym["wFrames"]]), None)
    for screen_name, presses in (("play", 0), ("edit", 1)):
        for _ in range(presses):
            combo(pb, "start", "right", settle=30)
        combo(pb, "select", "start", hold=8)
        check(f"{screen_name} screen: the sequencer runs", v("wSeqPlay") == 1)
        frames.clear()
        pb.tick(700)                      # about 8 bars: the playhead crosses several pages
        check(f"{screen_name} screen: every main-loop pass takes one frame while playing (%d passes)" % len(frames), len(frames) > 600 and max(frames) == 1, (len(frames), sorted(set(frames))))
        combo(pb, "select", "start", hold=8)
    pb.stop(save=False)

print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
