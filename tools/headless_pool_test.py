#!/usr/bin/env python3
"""Page pool test using PyBoy (pip install pyboy pillow). Run `make` first. See docs/M19_PATTERN_POOL.md and M20_PER_CHANNEL_CHAINS.md.

Covers: the coded size the ROM counts (against the coder in pool_util), lending a page when a note is placed, giving it back when the
last note is deleted, MEM FULL (the edit is refused and nothing changes), the zero page staying zero, playing a pattern whose two halves
are in different WRAM banks, saving (the coded bytes against the Python coder), loading, and reading a version 9 save.
"""
import pathlib
import random
import re
import shutil
import sys
import tempfile

from pyboy import PyBoy
from pool_util import Pool, SAVE_HEADER, encode_channel, parse_save, to_v9, to_v11, chain_of

root = pathlib.Path(__file__).resolve().parent.parent
rom_src = root / "build/chromasynth.gb"

sym = {}
for line in (root / "build/chromasynth.sym").read_text().splitlines():
    m = re.match(r"([0-9A-Fa-f]{2}):([0-9A-Fa-f]{4}) (\S+)", line)
    if m:
        sym[m.group(3)] = int(m.group(2), 16)

fails = 0
POOL_BYTES = 7680
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


def page_cells(pool, p, ch, g):
    return [pool.get(p, ch, g, t) for t in range(192)]


def total(pool):
    """The coded size of every page that is lent, from the cells (the Python coder)."""
    return sum(len(encode_channel(page_cells(pool, p, ch, g))) for p in range(16) for ch in range(4) for g in range(2) if pool.page(p, ch, g) != 255)


def rom_total(mem):
    return mem[sym["wPoolBytes"]] | mem[sym["wPoolBytes"] + 1] << 8


with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")

    # ---- boot: the demo holds pages; the ROM counted their coded size like the Python coder
    pb = boot(rom)
    mem = pb.memory
    pool = Pool(mem, sym)
    v = lambda n: mem[sym[n]]
    demo_pages = pool.lent()
    check("boot: only pattern 1's first half is lent, and only the channels that hold notes (%d pages)" % len(demo_pages),
          len(demo_pages) == 3 and all(pool.page(0, ch, 0) != 255 for ch in (0, 2, 3)) and pool.page(0, 1, 0) == 255 and not pool.half_lent(0, 1), demo_pages)
    check("boot: the ROM's coded size is the Python coder's (%d)" % total(pool), rom_total(mem) == total(pool), (rom_total(mem), total(pool)))
    check("boot: the zero page is zero", pool.zero_segment_is_zero())
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

    # ---- placing a note lends a page (the selected channel's half), deleting it gives it back
    combo(pb, "start", "right")
    combo(pb, "start", "right")
    check("the sequencer screen", v("wScreen") == 2, v("wScreen"))
    combo(pb, "start", "a")              # edit pattern 2
    check("pattern 2 is edited and holds nothing", v("wEditPat") == 1 and not pool.half_lent(1, 0) and not pool.half_lent(1, 1), (v("wEditPat"), pool.lent()))
    mem[sym["wRollNote"]] = 70
    mem[sym["wRollCell"]] = 0
    mem[sym["wRollTick"]] = 0
    mem[sym["wRollSeg"]] = 0
    tap(pb, "a")
    check("A lends exactly one page: channel 1, first half, of pattern 2", pool.page(1, 0, 0) != 255 and sum(1 for ch in range(4) for g in range(2) if pool.page(1, ch, g) != 255) == 1, (pool.lent()))
    check("... and the note is in it (tick 0 = 70, tick 3 = the OFF)", pool.get(1, 0, 0, 0) == 70 and pool.get(1, 0, 0, 3) == 0xFF, (pool.get(1, 0, 0, 0), pool.get(1, 0, 0, 3)))
    check("... and the ROM counted the new size (%d)" % total(pool), rom_total(mem) == total(pool), (rom_total(mem), total(pool)))
    check("the other pattern is untouched", pool.get(0, 0, 0, 0) == 60)
    tap(pb, "b")
    check("B deletes the note and the page goes back to the pool", pool.page(1, 0, 0) == 255 and sorted(pool.lent()) == sorted(demo_pages), (pool.lent(), demo_pages))
    check("... the size is back to the demo's", rom_total(mem) == demo_total, (rom_total(mem), demo_total))
    check("... the zero page is still zero", pool.zero_segment_is_zero())
    # channel 3 (select twice): a note there lends only channel 3's page (pattern 2 is the edited one on CH3 too: its cell says so)
    mem[sym["wChain"] + 2 * 32] = 1
    tap(pb, "select")
    tap(pb, "select")
    check("channel 3 is selected", v("wSelCh") == 2, v("wSelCh"))
    mem[sym["wRollNote"]] = 50
    mem[sym["wRollCell"]] = 0
    mem[sym["wRollTick"]] = 0
    mem[sym["wRollSeg"]] = 0
    tap(pb, "a")
    check("a note on channel 3 lends channel 3's page only", pool.page(1, 2, 0) != 255 and pool.page(1, 0, 0) == 255 and len(pool.lent()) == len(demo_pages) + 1, pool.lent())
    tap(pb, "b")
    tap(pb, "select")
    tap(pb, "select")                    # (the channel goes round to 1 again)
    check("channel 1 is selected again", v("wSelCh") == 0, v("wSelCh"))

    # ---- a note in the second half lends the second half's page
    mem[sym["wRollSeg"]] = 1
    mem[sym["wRollTick"]] = 0
    mem[sym["wRollCell"]] = 0
    tap(pb, "a")
    check("a note in the second half lends only that half", pool.page(1, 0, 0) == 255 and pool.page(1, 0, 1) != 255, (pool.page(1, 0, 0), pool.page(1, 0, 1)))
    check("... and the loop grew to cover it", v("wSeqBars") >= 5, v("wSeqBars"))
    tap(pb, "b")
    check("... deleting it gives the page back", pool.page(1, 0, 1) == 255, pool.page(1, 0, 1))

    # ---- MEM FULL: the memory is full by bytes
    mem[sym["wRollSeg"]] = 0
    mem[sym["wRollTick"]] = 0
    mem[sym["wRollCell"]] = 0
    mem[sym["wPoolBytes"]] = (POOL_BYTES - 40) & 0xFF
    mem[sym["wPoolBytes"] + 1] = (POOL_BYTES - 40) >> 8
    tap(pb, "a")
    check("by bytes: A is refused with MEM FULL and nothing is lent", v("wMsg") == 7 and sorted(pool.lent()) == sorted(demo_pages) and pool.get(1, 0, 0, 0) == 0, (v("wMsg"), pool.lent()))
    mem[sym["wPoolBytes"]] = demo_total & 0xFF
    mem[sym["wPoolBytes"] + 1] = demo_total >> 8
    # ---- MEM FULL: (nearly) all pages are lent
    n = 0
    for p in range(2, 16):
        for ch in range(4):
            for g in range(2):
                if len(pool.lent()) < 110:
                    pool.lend(p, ch, g)
    check("110 pages are lent", len(pool.lent()) == 110, len(pool.lent()))
    mem[sym["wMsg"]] = 0
    tap(pb, "a")
    check("by pages: with 110 lent (less than 2 free) A is refused with MEM FULL", v("wMsg") == 7 and pool.get(1, 0, 0, 0) == 0, (v("wMsg"), pool.get(1, 0, 0, 0)))
    pool.release(2, 3, 1)
    pool.release(2, 3, 0)                # two pages go back
    mem[sym["wRollNote"]] = 70
    tap(pb, "a")
    check("with room again the note is placed", pool.get(1, 0, 0, 0) == 70, pool.get(1, 0, 0, 0))
    check("the zero page is still zero", pool.zero_segment_is_zero())
    for p in range(16):
        pool.clear_pattern(p)
    pb.stop(save=False)

    # ---- a pattern whose halves are in different WRAM banks plays on
    pb = boot(rom)
    mem = pb.memory
    pool = Pool(mem, sym)
    v = lambda n: mem[sym[n]]
    pool.clear_pattern(0)
    for (ch, g, pid) in ((0, 0, 2), (0, 1, 40), (1, 1, 100)):          # pages 2, 40, 100: banks 1, 3, 7
        mem[sym["wPatPage"] + ch * 2 + g] = pid
        pool._setmap(pid, True)
        for t in range(256):
            bank, a = pool._addr(pid, t)
            mem[bank, a] = 0
    pool.put(0, 0, 0, 0, 60)
    pool.put(0, 0, 1, 0, 64)
    pool.put(0, 1, 1, 5, 67)
    check("the pages are in banks 1, 3 and 7", (pool.page(0, 0, 0) // 16 + 1, pool.page(0, 0, 1) // 16 + 1, pool.page(0, 1, 1) // 16 + 1) == (1, 3, 7))
    mem[sym["wSeqBars"]] = 8
    mem[sym["wBpm"]] = 240
    combo(pb, "select", "start")         # play
    seen = {}
    for _ in range(3000):
        pb.tick(1)
        t = v("wSeqCur") + (192 if v("wSeqCurSeg") else 0)
        for ch, nt in ((0, mem[sym["wCurNote"]]), (1, mem[sym["wCurNote"] + 1])):
            if nt:
                seen.setdefault((ch, nt), t)
        if (1, 67) in seen:
            break
    check("the first half's note plays at tick 0 and the second half's after the edge", seen.get((0, 60), 999) < 10 and 190 <= seen.get((0, 64), 0) <= 197, seen)
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
    density = [0.02, 0.1, 0.3, 0.5, 0.9, 1.0]     # of the cells of a page: a few ... all of them
    pages = sorted(rng.sample([(p, ch, g) for p in range(16) for ch in range(4) for g in range(2)], 38))
    for (p, ch, g) in pages:
        d = rng.choice(density)
        pool.lend(p, ch, g)
        for t in range(192):
            if rng.random() < d:
                pool.put(p, ch, g, t, rng.randrange(1, 256))
    expect = bytearray()
    for (p, ch, g) in pages:
        expect += encode_channel(page_cells(pool, p, ch, g))
    mem[sym["wPoolBytes"]] = len(expect) & 0xFF
    mem[sym["wPoolBytes"] + 1] = len(expect) >> 8
    before = {(p, ch, g): page_cells(pool, p, ch, g) for (p, ch, g) in pages}
    check("%d pages are lent, the coded size is %d bytes (budget %d)" % (len(pages), len(expect), POOL_BYTES), len(expect) <= POOL_BYTES, len(expect))
    combo(pb, "select", "b", 30)
    check("SELECT+B saves it", v("wMsg") == 1, v("wMsg"))
    pb.stop(save=True)
    raw = ram.read_bytes()
    slot = raw[BASE:BASE + 8192]
    got = parse_save(slot)
    check("the slot is a version 12 save with a good checksum", got is not None)
    check("the coded region is exactly what the Python coder makes", slot[SAVE_HEADER:SAVE_HEADER + len(expect)] == bytes(expect) and got["length"] == len(expect),
          (got and got["length"], len(expect)))
    check("the Python decoder reads every cell back", got is not None and got["pages"] == before)
    check("nothing was written behind the slot's data", len(set(raw[BASE + SAVE_HEADER + len(expect):BASE + 8192])) <= 1)
    pb = boot(rom)
    mem = pb.memory
    pool = Pool(mem, sym)
    after = {(p, ch, g): page_cells(pool, p, ch, g) for p in range(16) for ch in range(4) for g in range(2) if pool.page(p, ch, g) != 255}
    nonempty = {k: c for k, c in before.items() if any(c)}
    check("reboot: the ROM's decoder brings every cell back (pages that came in empty are given back)", after == nonempty, (len(after), len(nonempty)))
    check("reboot: the ROM counted the size again", rom_total(mem) == total(pool), (rom_total(mem), total(pool)))
    check("reboot: the zero page is zero", pool.zero_segment_is_zero())
    # ---- a version 9 save: the same song as 4 raw patterns (what v11 holds for patterns 1-4)
    v9 = to_v9(slot)
    pb.stop(save=False)
    data = bytearray(raw)
    data[BASE:BASE + 8192] = v9
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    mem = pb.memory
    pool = Pool(mem, sym)
    want = {k: c for k, c in nonempty.items() if k[0] < 4}
    after = {(p, ch, g): page_cells(pool, p, ch, g) for p in range(16) for ch in range(4) for g in range(2) if pool.page(p, ch, g) != 255}
    check("version 9: patterns 1-4 are read, only the channel halves that hold something are lent (%d)" % len(want), after == want, (len(after), len(want)))
    row9 = list(v9[165:181])
    chain9 = [list(mem[sym["wChain"] + c * 32:sym["wChain"] + (c + 1) * 32]) for c in range(4)]
    check("version 9: the chain (16 steps, all four channels alike, the rest the end) and bpm came along", chain9 == [row9 + [255] * 16] * 4 and mem[sym["wBpm"]] == v9[181], chain9)
    combo(pb, "select", "b", 20)         # a used slot asks first ...
    combo(pb, "select", "b", 30)         # ... and the second press overwrites
    pb.stop(save=True)
    slot2 = ram.read_bytes()[BASE:BASE + 8192]
    check("a version 9 song is saved as version 12 again", slot2[:5] == b"CSYN\x0c" and parse_save(slot2) is not None)
    check("... with the chain on all four channels", chain_of(slot2) == [row9 + [255] * 16] * 4, chain_of(slot2))

    # ---- a version 11 save (a 16 step chain, the header 112 bytes shorter): the pages and the chain are read, the next save is version 12
    v11 = to_v11(slot)
    data = bytearray(raw)
    data[BASE:BASE + 8192] = v11
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    mem = pb.memory
    pool = Pool(mem, sym)
    after = {(p, ch, g): page_cells(pool, p, ch, g) for p in range(16) for ch in range(4) for g in range(2) if pool.page(p, ch, g) != 255}
    check("version 11: every page is read back", after == nonempty, (len(after), len(nonempty)))
    row11 = chain_of(slot)[0][:16]
    chain11 = [list(mem[sym["wChain"] + c * 32:sym["wChain"] + (c + 1) * 32]) for c in range(4)]
    check("version 11: the chain is on all four channels", chain11 == [row11 + [255] * 16] * 4, chain11)
    combo(pb, "select", "b", 20)
    combo(pb, "select", "b", 30)
    pb.stop(save=True)
    slot3 = ram.read_bytes()[BASE:BASE + 8192]
    got3 = parse_save(slot3)
    check("a version 11 song is saved as version 12 again, the same pages", got3 is not None and got3["pages"] == before, got3 is None)
    check("... and the chain is the same on all four channels", chain_of(slot3) == [row11 + [255] * 16] * 4, chain_of(slot3))

print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
