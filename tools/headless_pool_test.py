#!/usr/bin/env python3
"""Segment pool test using PyBoy (pip install pyboy pillow). Run `make` first. See docs/M19_PATTERN_POOL.md.

Covers: the coded size the ROM counts (against the coder in pool_util), lending a segment when a note is placed, giving it back when the
last note is deleted, MEM FULL (the edit is refused and nothing changes), the zero segment staying zero, playing a pattern whose two halves
are in different WRAM banks, saving (the coded bytes against the Python coder), loading, and reading a version 9 save.
"""
import pathlib
import random
import re
import shutil
import sys
import tempfile

from pyboy import PyBoy
from pool_util import Pool, SAVE_HEADER, encode_channel, parse_v10, to_v9

root = pathlib.Path(__file__).resolve().parent.parent
rom_src = root / "build/chromasynth.gb"

sym = {}
for line in (root / "build/chromasynth.sym").read_text().splitlines():
    m = re.match(r"([0-9A-Fa-f]{2}):([0-9A-Fa-f]{4}) (\S+)", line)
    if m:
        sym[m.group(3)] = int(m.group(2), 16)

fails = 0
POOL_BYTES = 7800
BASE = (12 if rom_src.read_bytes()[0x149] == 4 else 0) * 8192     # slot 1


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


def tap(pb, btn, settle=8):
    pb.button_press(btn)
    pb.tick(3)
    pb.button_release(btn)
    pb.tick(settle)


def seg_size(pool, p, g):
    """The coded size of a half, from the cells (the Python coder)."""
    return sum(len(encode_channel([pool.get(p, c, g, t) for t in range(192)])) for c in range(4))


def total(pool):
    return sum(seg_size(pool, p, g) for p in range(16) for g in range(2) if pool.seg(p, g) != 255)


def rom_total(mem):
    return mem[sym["wPoolBytes"]] | mem[sym["wPoolBytes"] + 1] << 8


with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")

    # ---- boot: the demo holds one segment; the ROM counted its coded size like the Python coder
    pb = boot(rom)
    mem = pb.memory
    pool = Pool(mem, sym)
    v = lambda n: mem[sym[n]]
    check("boot: pattern 1 holds segment 0, nothing else is lent", pool.lent() == [0], pool.lent())
    check("boot: the ROM's coded size is the Python coder's (%d)" % total(pool), rom_total(mem) == total(pool), (rom_total(mem), total(pool)))
    check("boot: the zero segment is zero", pool.zero_segment_is_zero())
    check("boot: the memory percentage is bytes / 78", v("wPoolPct") == total(pool) // 78, v("wPoolPct"))
    demo_total = total(pool)

    # ---- the song screen shows the memory
    combo(pb, "start", "up")
    pb.tick(30)
    base = 0x9C00 if mem[0xFF40] & 8 else 0x9800
    row = ((mem[0xFF42] // 8) + 1) & 31
    text = bytes(mem[base + row * 32 + c] for c in range(4, 12))
    pct = total(pool) // 78
    want = ("MEM " + (" " if pct < 100 else str(pct // 100)) + "%02d" % (pct % 100) + "%").encode()
    check("the song screen shows MEM and the percentage", text == bytes(c - 32 for c in want), (text, want))
    combo(pb, "start", "down")
    pb.tick(20)

    # ---- placing a note lends a segment, deleting it gives it back
    combo(pb, "start", "right")
    combo(pb, "start", "right")
    check("the sequencer screen", v("wScreen") == 2, v("wScreen"))
    combo(pb, "start", "a")              # edit pattern 2
    check("pattern 2 is edited and holds nothing", v("wEditPat") == 1 and pool.seg(1, 0) == 255 and pool.seg(1, 1) == 255, (v("wEditPat"), pool.seg(1, 0)))
    mem[sym["wRollNote"]] = 70
    mem[sym["wRollCell"]] = 0
    mem[sym["wRollTick"]] = 0
    mem[sym["wRollSeg"]] = 0
    tap(pb, "a")
    check("A lends pattern 2's first half a segment", pool.seg(1, 0) == 1 and pool.seg(1, 1) == 255, (pool.seg(1, 0), pool.seg(1, 1)))
    check("... and the note is in it (tick 0 = 70, tick 3 = the OFF)", pool.get(1, 0, 0, 0) == 70 and pool.get(1, 0, 0, 3) == 0xFF, (pool.get(1, 0, 0, 0), pool.get(1, 0, 0, 3)))
    check("... and the ROM counted the new size (%d)" % total(pool), rom_total(mem) == total(pool), (rom_total(mem), total(pool)))
    check("the other pattern is untouched", pool.get(0, 0, 0, 0) == 60)
    tap(pb, "b")
    check("B deletes the note and the half goes back to the pool", pool.seg(1, 0) == 255 and pool.lent() == [0], (pool.seg(1, 0), pool.lent()))
    check("... the size is back to the demo's", rom_total(mem) == demo_total, (rom_total(mem), demo_total))
    check("... the zero segment is still zero", pool.zero_segment_is_zero())

    # ---- a note in the second half lends the second half
    mem[sym["wRollSeg"]] = 1
    mem[sym["wRollTick"]] = 0
    mem[sym["wRollCell"]] = 0
    tap(pb, "a")
    check("a note in the second half lends only that half", pool.seg(1, 0) == 255 and pool.seg(1, 1) == 1, (pool.seg(1, 0), pool.seg(1, 1)))
    check("... and the loop grew to cover it", v("wSeqBars") >= 5, v("wSeqBars"))
    tap(pb, "b")
    check("... deleting it gives the half back", pool.seg(1, 1) == 255, pool.seg(1, 1))

    # ---- MEM FULL: the memory is full by bytes
    mem[sym["wRollSeg"]] = 0
    mem[sym["wRollTick"]] = 0
    mem[sym["wRollCell"]] = 0
    mem[sym["wPoolBytes"]] = (POOL_BYTES - 100) & 0xFF
    mem[sym["wPoolBytes"] + 1] = (POOL_BYTES - 100) >> 8
    tap(pb, "a")
    check("by bytes: A is refused with MEM FULL and nothing is lent", v("wMsg") == 7 and pool.lent() == [0] and pool.get(1, 0, 0, 0) == 0, (v("wMsg"), pool.lent()))
    mem[sym["wPoolBytes"]] = demo_total & 0xFF
    mem[sym["wPoolBytes"] + 1] = demo_total >> 8
    # ---- MEM FULL: all segments are lent
    held = []
    for p in range(2, 15):
        for g in range(2):
            held.append(pool.lend(p, g))
    check("26 segments are lent", len(pool.lent()) == 27, len(pool.lent()))
    mem[sym["wPatSeg"] + 4] = 255        # (pattern 3's first half goes back so that 26 are lent)
    check("26 are lent", len(pool.lent()) == 26, len(pool.lent()))
    mem[sym["wMsg"]] = 0
    tap(pb, "a")
    check("by segments: with 26 lent (less than 2 free) A is refused with MEM FULL", v("wMsg") == 7 and pool.get(1, 0, 0, 0) == 0, (v("wMsg"), pool.get(1, 0, 0, 0)))
    mem[sym["wPatSeg"] + 5] = 255
    mem[sym["wPatSeg"] + 7] = 255        # two more halves go back (23 lent)
    tap(pb, "a")
    check("with room again the note is placed", pool.get(1, 0, 0, 0) == 70, pool.get(1, 0, 0, 0))
    check("the zero segment is still zero", pool.zero_segment_is_zero())
    for p in range(16):
        pool.clear_pattern(p)
    pb.stop(save=False)

    # ---- a pattern whose halves are in different WRAM banks plays on
    pb = boot(rom)
    mem = pb.memory
    pool = Pool(mem, sym)
    v = lambda n: mem[sym[n]]
    pool.clear_pattern(0)
    mem[sym["wPatSeg"] + 0] = 2          # segment 2: bank 1
    mem[sym["wPatSeg"] + 1] = 13         # segment 13: bank 4
    pool.put(0, 0, 0, 0, 60)
    pool.put(0, 0, 1, 0, 64)
    pool.put(0, 1, 1, 5, 67)
    check("the halves are in banks 1 and 4", (pool.seg(0, 0) // 4 + 1, pool.seg(0, 1) // 4 + 1) == (1, 4))
    mem[sym["wSeqBars"]] = 8
    mem[sym["wBpm"]] = 240
    combo(pb, "select", "start")         # play
    seen = {}
    for _ in range(3000):
        pb.tick(1)
        t = v("wSeqCur") + (192 if v("wSeqCurSeg") else 0)
        for ch, n in ((0, mem[sym["wCurNote"]]), (1, mem[sym["wCurNote"] + 1])):
            if n:
                seen.setdefault((ch, n), t)
        if (1, 67) in seen:
            break
    check("segment 1's note plays at tick 0 and segment 2's after the edge", seen.get((0, 60), 999) < 10 and 190 <= seen.get((0, 64), 0) <= 197, seen)
    check("a note of channel 2 in the second half plays too", 190 <= seen.get((1, 67), 0) <= 205, seen)
    combo(pb, "select", "start")
    pb.stop(save=False)

    # ---- saving: the coded bytes are the Python coder's; loading brings every cell back
    rng = random.Random(10)
    pb = boot(rom)
    mem = pb.memory
    pool = Pool(mem, sym)
    v = lambda n: mem[sym[n]]
    for p in range(16):
        pool.clear_pattern(p)
    halves = [(0, 0), (0, 1), (1, 0), (3, 1), (4, 0), (7, 0), (7, 1), (9, 0), (12, 1), (15, 0)]
    density = [0, 0.02, 0.1, 0.5, 0.9, 1.0]       # of the cells of a channel: empty ... all of them
    for (p, g) in halves:
        for c in range(4):
            d = rng.choice(density)
            for t in range(192):
                if rng.random() < d:
                    pool.put(p, c, g, t, rng.randrange(1, 256))
    expect = bytearray()
    for idx in range(32):
        p, g = idx // 2, idx % 2
        if pool.seg(p, g) != 255:
            for c in range(4):
                expect += encode_channel([pool.get(p, c, g, t) for t in range(192)])
    mem[sym["wPoolBytes"]] = len(expect) & 0xFF
    mem[sym["wPoolBytes"] + 1] = len(expect) >> 8
    before = {(p, g): [[pool.get(p, c, g, t) for t in range(192)] for c in range(4)] for p in range(16) for g in range(2) if pool.seg(p, g) != 255}
    check("10 halves are lent, the coded size is %d bytes (budget %d)" % (len(expect), POOL_BYTES), len(before) == 10 and len(expect) <= POOL_BYTES, (len(before), len(expect)))
    combo(pb, "select", "b", 30)
    check("SELECT+B saves it", v("wMsg") == 1, v("wMsg"))
    pb.stop(save=True)
    raw = ram.read_bytes()
    slot = raw[BASE:BASE + 8192]
    got = parse_v10(slot)
    check("the slot is a version 10 save with a good checksum", got is not None)
    check("the coded region is exactly what the Python coder makes", slot[SAVE_HEADER:SAVE_HEADER + len(expect)] == bytes(expect) and got["length"] == len(expect),
          (got and got["length"], len(expect)))
    check("the Python decoder reads every cell back", got is not None and all(got["segments"].get(k) == before[k] for k in before) and len(got["segments"]) == len(before))
    check("nothing was written behind the slot", len(raw) == len(raw) and set(raw[BASE + SAVE_HEADER + len(expect):BASE + 8192]) <= {0, 0xFF} and len(set(raw[BASE + SAVE_HEADER + len(expect):BASE + 8192])) <= 1)
    pb = boot(rom)
    mem = pb.memory
    pool = Pool(mem, sym)
    after = {(p, g): [[pool.get(p, c, g, t) for t in range(192)] for c in range(4)] for p in range(16) for g in range(2) if pool.seg(p, g) != 255}
    check("reboot: the ROM's decoder brings every cell back, and the same halves are lent", after == before, (len(after), len(before)))
    check("reboot: the ROM counted the size again", rom_total(mem) == len(expect), (rom_total(mem), len(expect)))
    check("reboot: the zero segment is zero", pool.zero_segment_is_zero())
    # ---- a version 9 save: the same song as 4 raw patterns (what v10 holds for patterns 1-4)
    v9 = to_v9(slot)
    pb.stop(save=False)
    data = bytearray(raw)
    data[BASE:BASE + 8192] = v9
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    mem = pb.memory
    pool = Pool(mem, sym)
    want = {k: before[k] for k in before if k[0] < 4}
    after = {(p, g): [[pool.get(p, c, g, t) for t in range(192)] for c in range(4)] for p in range(16) for g in range(2) if pool.seg(p, g) != 255}
    check("version 9: patterns 1-4 are read, only the halves that hold something are lent (%d)" % len(want), after == want, (sorted(after), sorted(want)))
    check("version 9: the chain and bpm came along", bytes(mem[sym["wChain"]:sym["wChain"] + 16]) == v9[165:181] and mem[sym["wBpm"]] == v9[181])
    combo(pb, "select", "b", 20)         # a used slot asks first ...
    combo(pb, "select", "b", 30)         # ... and the second press overwrites
    pb.stop(save=True)
    slot2 = ram.read_bytes()[BASE:BASE + 8192]
    check("a version 9 song is saved as version 10 again", slot2[:5] == b"CSYN\x0a" and parse_v10(slot2) is not None)

print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
