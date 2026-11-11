#!/usr/bin/env python3
"""Time-signature test using PyBoy (pip install pyboy pillow). Run `make` first.

The time signature is two bytes of the MIDI block of the patches (BEAT = numerator, UNIT = denominator
index 0/1/2 = /4 /8 /16), so it is saved with the song. It sets the ticks of a beat (12/6/3), of a bar,
the ruler's bar lines and numbers, the longest loop (384 ticks of whole bars) and the loop end.
"""
import pathlib
import re
import shutil
import sys
import tempfile

from pyboy import PyBoy
from pool_util import Pool, to_v9

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


def screen_row(mem, r):
    base = 0x9C00 if mem[0xFF40] & 8 else 0x9800
    row = ((mem[0xFF42] // 8) + r) & 31
    return bytes(mem[base + row * 32 + c] for c in range(20))


MIDI = sym["wPatch"] + 4 * 32          # the MIDI block of the patches
TSN, TSD = MIDI + 10, MIDI + 11
TICK = 75                               # T_TICK: the ruler's mark on a beat line


def digit(n):
    return ord("0") - 32 + n if n < 10 else ord("A") - 32 + n - 10


with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]

    check("4/4 is the default", (mem[TSN], mem[TSD]) == (4, 0) and (v("wBeatTicks"), v("wBarTicks"), v("wMaxBars")) == (12, 48, 8),
          (mem[TSN], mem[TSD], v("wBeatTicks"), v("wBarTicks"), v("wMaxBars")))

    # --- the numbers for the usual signatures (set in memory, then the roll is redrawn: BuildCols recomputes them)
    combo(pb, "start", "right")
    combo(pb, "start", "right")
    pb.tick(40)
    table = [  # (numerator, denominator index, beat ticks, bar ticks, longest loop in bars)
        (4, 0, 12, 48, 8), (3, 0, 12, 36, 8), (2, 0, 12, 24, 8), (5, 0, 12, 60, 6), (6, 1, 6, 36, 8),
        (3, 1, 6, 18, 8), (7, 1, 6, 42, 8), (5, 2, 3, 15, 8), (4, 0, 12, 48, 8),
    ]
    for n, d, beat, bar, maxbars in table:
        mem[TSN] = n
        mem[TSD] = d
        combo(pb, "select", "right")
        combo(pb, "select", "left")
        got = (v("wBeatTicks"), v("wBarTicks"), v("wMaxBars"))
        check(f"{n}/{[4, 8, 16][d]}: beat {beat} ticks, bar {bar} ticks, loops up to {maxbars} bars", got == (beat, bar, maxbars), got)
    mem[TSN] = 0
    mem[TSD] = 0
    combo(pb, "select", "right")
    combo(pb, "select", "left")
    check("a song saved before the time signature existed (0 / 0) is 4/4", (v("wBarTicks"), v("wBeatTicks")) == (48, 12), (v("wBarTicks"), v("wBeatTicks")))
    mem[TSN] = 99
    mem[TSD] = 9
    combo(pb, "select", "right")
    combo(pb, "select", "left")
    check("nonsense values are clamped (16 / 4)", (v("wBarTicks"), v("wBeatTicks")) == (192, 12), (v("wBarTicks"), v("wBeatTicks")))
    pb.stop(save=False)

# --- the ruler: bar lines and numbers at the signature's bar length (3/4: 36 ticks, 1/16 grid: 3 ticks a column)
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    mem[TSN] = 3
    mem[TSD] = 0
    mem[sym["wSeqBars"]] = 4             # (beat marks are drawn inside the loop only)
    combo(pb, "start", "right")
    combo(pb, "start", "right")
    pb.tick(40)
    ruler = screen_row(mem, 0)
    check("3/4, page 1 = bar 1: bar number at column 0, beat marks at ticks 12 and 24 (columns 4, 8), nothing after the bar",
          ruler[2] == digit(1) and ruler[2 + 4] == TICK and ruler[2 + 8] == TICK and all(ruler[2 + c] == 0 for c in range(9, 16)), list(ruler))
    mem[sym["wRollSeg"]] = 0
    mem[sym["wRollCell"]] = 15
    mem[sym["wRollTick"]] = 45
    tap(pb, "right")                     # the cursor crosses into bar 2 (ticks 36..71)
    pb.tick(20)
    ruler = screen_row(mem, 0)
    # page 2 starts at tick 48 = 12 ticks into bar 2: beat at 60 (column 4), bar 3 at tick 72 (column 8), beat at 84 (column 12)
    check("3/4, page 2 = bar 2: bar number 2 at column 0, beat marks at ticks 48 and 60 (columns 4, 8)",
          ruler[2] == digit(2) and ruler[2 + 4] == TICK and ruler[2 + 8] == TICK and all(ruler[2 + c] == 0 for c in range(9, 16)), list(ruler))
    pb.stop(save=False)

# --- 6/8: the beat unit is an eighth (6 ticks): beat marks every 2 columns at 1/16
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    mem[TSN] = 6
    mem[TSD] = 1
    combo(pb, "start", "right")
    combo(pb, "start", "right")
    pb.tick(40)
    ruler = screen_row(mem, 0)
    check("6/8: bar 1 at column 0, beat marks every 2 columns (6 ticks); the page is the bar (12 columns)",
          ruler[2] == digit(1) and ruler[2 + 2] == TICK and ruler[2 + 4] == TICK and ruler[2 + 10] == TICK and ruler[2 + 12] == 0,
          list(ruler))
    pb.stop(save=False)

# --- playback loops at the signature's loop length; a note after the end lengthens the loop; the longest loop
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    mem[TSN] = 3
    mem[TSD] = 0
    combo(pb, "start", "right")
    combo(pb, "start", "right")
    pb.tick(40)
    mem[sym["wSeqBars"]] = 2             # 2 bars of 3/4 = 72 ticks
    mem[sym["wBpm"]] = 240
    combo(pb, "select", "start")
    ticks = set()
    for _ in range(400):
        pb.tick(1)
        ticks.add((v("wSeqSeg"), v("wSeqTick")))
    combo(pb, "select", "start")
    check("3/4, 2 bars: the playhead runs 0..71 and wraps", max(t for s, t in ticks) == 71 and all(s == 0 for s, t in ticks),
          (max(t for s, t in ticks), sorted(set(s for s, t in ticks))))
    # a note in bar 3 (ticks 72..107) lengthens the loop to 3 bars
    mem[sym["wRollSeg"]] = 0
    mem[sym["wRollCell"]] = 24           # tick 72 at 1/16
    mem[sym["wRollTick"]] = 72
    mem[sym["wRollNote"]] = 65
    tap(pb, "a")
    pb.tick(20)
    check("3/4: a note in bar 3 (tick 72) makes the loop 3 bars", v("wSeqBars") == 3, v("wSeqBars"))
    for _ in range(14):
        combo(pb, "select", "right")
    check("3/4: the longest loop is 8 bars (the pattern limit; 384 / 36 would be 10)", v("wSeqBars") == 8, v("wSeqBars"))
    check("... which ends in segment 2 after 96 ticks (288 - 192)", (v("wEdLoopSeg"), v("wEdLoopTail")) == (1, 96), (v("wEdLoopSeg"), v("wEdLoopTail")))
    for _ in range(14):
        combo(pb, "select", "left")
    check("... and the shortest is 1 bar", v("wSeqBars") == 1, v("wSeqBars"))
    pb.stop(save=False)

# --- 5/4: a loop of 4 bars = 240 ticks crosses the segment edge; playback wraps at 240
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    mem[TSN] = 5
    mem[TSD] = 0
    combo(pb, "start", "right")
    combo(pb, "start", "right")
    pb.tick(40)
    mem[sym["wSeqBars"]] = 4
    mem[sym["wBpm"]] = 240
    combo(pb, "select", "start")
    seen = set()
    for _ in range(900):                 # 240 ticks at 240 BPM = 300 frames: three rounds
        pb.tick(1)
        seen.add((v("wSeqSeg"), v("wSeqTick")))
    combo(pb, "select", "start")
    check("5/4, 4 bars = 240 ticks: segment 2 plays 0..47 and then the loop wraps",
          max(t for s, t in seen if s == 1) == 47 and (0, 0) in seen and max(t for s, t in seen if s == 0) == 191,
          (max(t for s, t in seen if s == 1), max(t for s, t in seen if s == 0)))
    pb.stop(save=False)

# --- a pattern chosen while playing takes over at the next bar line of the time signature (3/4: every 36 ticks)
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    mem[TSN] = 3
    mem[TSD] = 0
    combo(pb, "start", "right")
    combo(pb, "start", "right")
    pb.tick(40)
    mem[sym["wSeqBars"]] = 4             # 144 ticks
    for i in range(4):                   # every pattern is 3/4, 4 bars (the other patterns' own values)
        mem[sym["wPatTsn"] + i] = 3
        mem[sym["wPatTsd"] + i] = 0
        mem[sym["wPatBars"] + i] = 4
    mem[sym["wBpm"]] = 100
    combo(pb, "start", "left")
    combo(pb, "start", "left")
    combo(pb, "start", "up")             # the song screen
    combo(pb, "select", "start")
    pb.tick(20)
    for want in (2, 3, 4, 2):
        mem[sym["wRollTick"]] = 0
        combo(pb, "select", "right" if want > v("wPlayBank") else "left")
        queued = v("wQueuedBank")
        at = None
        for _ in range(400):
            pb.tick(1)
            if v("wPlayBank") != 0 and v("wPlayBank") == queued:
                at = v("wSeqCur")
                break
        # wSeqCur is the tick of the bar line (a multiple of 36) or the one before it, depending on the frame
        check(f"3/4: pattern {queued} takes over on a bar line", at is not None and at % 36 in (0, 35), at)
    combo(pb, "select", "start")
    pb.stop(save=False)

# --- the edit page sets it (BEAT, UNIT on the MIDI page) and a save keeps it
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    combo(pb, "start", "right")          # the edit screen
    for _ in range(4):
        tap(pb, "select")                # CH1 .. CH4, then the MIDI page
    check("on the MIDI page", v("wSelCh") == 4, v("wSelCh"))
    tap(pb, "up")                        # row 0 -> the last row (UNIT, row 11)
    check("the last row is UNIT (row 11)", v("wEditRow") == 11, v("wEditRow"))
    tap(pb, "right")                     # /4 -> /8
    check("UNIT right: /8 (index 1)", mem[TSD] == 1, mem[TSD])
    tap(pb, "up")                        # row 10: BEAT
    tap(pb, "left")
    tap(pb, "left")                      # 4 -> 2
    check("BEAT left twice: 2 (2/8: bar 12 ticks, beat 6)", mem[TSN] == 2 and (v("wBarTicks"), v("wBeatTicks")) == (12, 6),
          (mem[TSN], v("wBarTicks"), v("wBeatTicks")))
    for _ in range(4):
        tap(pb, "right")                 # 2 -> 6
    check("BEAT right x4: 6/8 -> bar 36 ticks, beat 6", mem[TSN] == 6 and (v("wBarTicks"), v("wBeatTicks")) == (36, 6),
          (mem[TSN], v("wBarTicks"), v("wBeatTicks")))
    pb.tick(30)
    # page 2 of the MIDI page: patch rows 8-15 are list rows 0-7 at screen rows 2-9: UNIT (row 11) is list row 3
    unit_row = bytes(mem[0x9800 + (2 + 3) * 32 + c] for c in range(12))
    check("the UNIT row shows 8 (the denominator), not its index", unit_row[10] == digit(8), list(unit_row))
    # save, change, load
    combo(pb, "select", "b", 40)
    check("SELECT+B saves", v("wMsg") == 1, v("wMsg"))
    mem[TSN] = 3
    mem[TSD] = 0
    combo(pb, "select", "a", 40)
    check("SELECT+A loads the song with its time signature", (mem[TSN], mem[TSD]) == (6, 1), (mem[TSN], mem[TSD]))
    check("... and the bar length follows (36 ticks, beat 6)", (v("wBarTicks"), v("wBeatTicks")) == (36, 6), (v("wBarTicks"), v("wBeatTicks")))
    pb.stop(save=True)
    ram = pathlib.Path(str(rom) + ".ram")
    pb = boot(rom)
    mem = pb.memory
    check("after a reboot the song is loaded from slot 1 with its 6/8", (mem[TSN], mem[TSD]) == (6, 1) and (mem[sym["wBarTicks"]], mem[sym["wBeatTicks"]]) == (36, 6),
          (mem[TSN], mem[TSD]))
    pb.stop(save=False)

# --- every pattern has its own time signature and loop length
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    PATN, PATD, PATB = sym["wPatTsn"], sym["wPatTsd"], sym["wPatBars"]
    pool = Pool(mem, sym)
    for p in range(16):
        pool.clear_pattern(p)
    pool.put(0, 0, 0, 0, 60)             # pattern 1: C4
    pool.put(1, 0, 0, 0, 64)             # pattern 2: E4
    combo(pb, "start", "up")             # the song screen
    pb.tick(20)
    check("every pattern starts as 4/4, 2 bars", [mem[PATN + i] for i in range(4)] == [4] * 4 and [mem[PATB + i] for i in range(4)] == [2] * 4,
          ([mem[PATN + i] for i in range(4)], [mem[PATB + i] for i in range(4)]))
    # pattern 2: 3/4, 3 bars (set through the live values of the edited pattern: the MIDI block and wSeqBars)
    combo(pb, "select", "right")
    check("editing pattern 2 loads its values (4/4, 2 bars)", (mem[TSN], mem[TSD], v("wSeqBars"), v("wBarTicks")) == (4, 0, 2, 48),
          (mem[TSN], mem[TSD], v("wSeqBars"), v("wBarTicks")))
    mem[TSN] = 3
    mem[sym["wSeqBars"]] = 3
    mem[sym["wBpm"]] = 240
    combo(pb, "select", "left")          # back to pattern 1: pattern 2's values are stored
    check("pattern 2's 3/4, 3 bars are stored when another pattern is edited", (mem[PATN + 1], mem[PATB + 1]) == (3, 3), (mem[PATN + 1], mem[PATB + 1]))
    check("pattern 1 is 4/4 again (bar 48 ticks, loop 2 bars)", (mem[TSN], v("wSeqBars"), v("wBarTicks")) == (4, 2, 48), (mem[TSN], v("wSeqBars"), v("wBarTicks")))
    # the chain 1, 2: pattern 1 plays 96 ticks, pattern 2 plays 108 ticks (3 bars of 36)
    for c_ in range(4):                 # (the chain has a row per channel: all four alike)
        mem[sym["wChain"] + c_ * 32:sym["wChain"] + c_ * 32 + 3] = bytes([0, 1, 0xFF])
    combo(pb, "select", "up")            # song mode
    combo(pb, "select", "start")
    longest = {}
    for _ in range(700):
        pb.tick(1)
        key = v("wPlayBank")
        longest[key] = max(longest.get(key, 0), v("wSeqTick") + 0)
    combo(pb, "select", "start")
    check("song mode: pattern 1 loops 96 ticks, pattern 2 loops 108 ticks (its own time signature and length)",
          longest.get(1) in (94, 95) and longest.get(2) in (106, 107), longest)   # (sampled once a frame: the last tick can fall between samples)
    combo(pb, "select", "up")            # loop mode again
    pb.stop(save=False)

# --- a queued pattern takes over at the bar line of the pattern that plays; its own bar length goes on from there
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    PATN, PATD, PATB = sym["wPatTsn"], sym["wPatTsd"], sym["wPatBars"]
    mem[PATN] = 4                        # pattern 1: 4/4 (bar 48), pattern 2: 3/4 (bar 36), 4 bars each
    mem[PATN + 1] = 3
    for i in range(4):
        mem[PATB + i] = 4
    mem[sym["wSeqBars"]] = 4
    mem[sym["wBpm"]] = 100
    combo(pb, "start", "up")
    combo(pb, "select", "start")
    pb.tick(30)
    changes = []
    last = v("wPlayBank")
    combo(pb, "select", "right")         # queue pattern 2
    for _ in range(500):
        pb.tick(1)
        if v("wPlayBank") != last:
            changes.append((last, v("wPlayBank"), v("wSeqTick")))   # (the next tick to play: the new position + 1 or 2)
            last = v("wPlayBank")
            break
    # the switch is on pattern 1's bar line; pattern 2 goes on at the same bar NUMBER, at its own bar length: a multiple of 36
    check("1 -> 2: pattern 2 starts on one of its own bar lines (a multiple of 36), at the bar number that was playing",
          len(changes) == 1 and (changes[0][2] - 1) % 36 in (0, 1, 2) and changes[0][2] > 36, changes)
    combo(pb, "select", "left")          # queue pattern 1 while pattern 2 (3/4) plays
    for _ in range(500):
        pb.tick(1)
        if v("wPlayBank") != last:
            pb.tick(2)                   # (SeqStep may straddle the frame: let it finish before reading the position)
            changes.append((last, v("wPlayBank"), v("wSeqTick")))   # (the next tick to play: the new position + 1..2)
            break
    check("2 -> 1: pattern 1 starts on one of its own bar lines (a multiple of 48)", len(changes) == 2 and (changes[1][2] - 1) % 48 in (0, 1, 2), changes)
    combo(pb, "select", "start")
    pb.stop(save=False)

# --- the per-pattern values are saved; a song saved without them gets the song's time signature everywhere
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    PATN, PATD, PATB = sym["wPatTsn"], sym["wPatTsd"], sym["wPatBars"]
    combo(pb, "start", "up")
    combo(pb, "select", "right")         # edit pattern 2: 6/8, 5 bars
    mem[TSN] = 6
    mem[TSD] = 1
    mem[sym["wSeqBars"]] = 5
    combo(pb, "select", "right")         # pattern 3: 7/8, 3 bars
    mem[TSN] = 7
    mem[TSD] = 1
    mem[sym["wSeqBars"]] = 3
    combo(pb, "select", "left")
    combo(pb, "select", "left")          # pattern 1: 3/4, 2 bars
    mem[TSN] = 3
    mem[TSD] = 0
    combo(pb, "select", "b", 60)
    check("saved", v("wMsg") == 1, v("wMsg"))
    pb.stop(save=True)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    got = ([mem[PATN + i] for i in range(3)], [mem[PATD + i] for i in range(3)], [mem[PATB + i] for i in range(3)])
    check("after a reboot every pattern keeps its time signature and length", got == ([3, 6, 7], [0, 1, 1], [2, 5, 3]), got)
    check("... pattern 1 is the edited one: 3/4, bar 36, 2 bars", (mem[TSN], v("wBarTicks"), v("wSeqBars")) == (3, 36, 2), (mem[TSN], v("wBarTicks"), v("wSeqBars")))
    pb.stop(save=False)
    # a song saved before the per-pattern values existed: their bytes in the slot are $00
    BASE = (12 if rom_src.read_bytes()[0x149] == 4 else 0) * 8192   # slot 1: bank 0 (public build) or 12 (EMS-card build)
    data = bytearray(ram.read_bytes())
    data[BASE:BASE + 8192] = to_v9(bytes(data[BASE:BASE + 8192]), zero_ts=True)   # version 9, the per-pattern bytes $00
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    got = ([mem[PATN + i] for i in range(4)], [mem[PATD + i] for i in range(4)])
    check("an older song: every pattern takes the song's time signature (the MIDI block's 3/4)", got == ([3] * 4, [0] * 4), got)
    check("... and the song's loop length", [mem[PATB + i] for i in range(4)] == [2] * 4, [mem[PATB + i] for i in range(4)])
    pb.stop(save=False)

print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
