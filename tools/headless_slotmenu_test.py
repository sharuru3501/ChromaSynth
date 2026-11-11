#!/usr/bin/env python3
"""Slot menu test using PyBoy (pip install pyboy pillow). Run `make` first. See docs/M24_SLOT_MENU.md.

Covers: NEW (an empty slot becomes a song; a used slot asks, then is emptied, name too), COPY TO (pick the target from the list, same slot,
a used target asks, bytes identical, one-slot cartridge), DELETE (asks, empties 8 KB, an empty slot), RENAME on an empty slot, and that data
that is not ours (LSDj) is never touched by NEW / COPY / DELETE.
"""
import pathlib
import re
import shutil
import sys
import tempfile

from pyboy import PyBoy
from pool_util import Pool, parse_save

root = pathlib.Path(__file__).resolve().parent.parent
rom_src = root / "build/chromasynth.gb"

sym = {}
for line in (root / "build/chromasynth.sym").read_text().splitlines():
    m = re.match(r"([0-9A-Fa-f]{2}):([0-9A-Fa-f]{4}) (\S+)", line)
    if m:
        sym[m.group(3)] = int(m.group(2), 16)

fails = 0
BANK0 = (12 if rom_src.read_bytes()[0x149] == 4 else 0) * 8192
SLOT = 8192


def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail != "" else ""))
    fails += not cond


def slot_off(n):
    return BANK0 + n * SLOT


def boot(rom):
    pb = PyBoy(str(rom), window="null", sound_emulated=False)
    for _ in range(2000):
        pb.tick(1)
        if pb.register_file.PC >= 0x100:
            break
    pb.tick(60)
    return pb


def combo(pb, held, btn):
    pb.button_press(held)
    pb.tick(3)
    pb.button_press(btn)
    pb.tick(3)
    pb.button_release(btn)
    pb.tick(2)
    pb.button_release(held)
    pb.tick(20)


def tap(pb, btn, settle=25):
    pb.button_press(btn)
    pb.tick(3)
    pb.button_release(btn)
    pb.tick(settle)


LOAD, SAVE, NEW, COPY, RENAME, DELETE = range(6)


MEM = []


def item(pb, n):
    """The slot screen: A opens the menu (when the list is shown), UP / DOWN to the item, A runs it."""
    mem = MEM[0]
    if mem[sym["wSlotMode"]] == 0:
        tap(pb, "a")
    while mem[sym["wMenuIdx"]] < n:
        tap(pb, "down", 8)
    while mem[sym["wMenuIdx"]] > n:
        tap(pb, "up", 8)
    tap(pb, "a")


def to_slot(pb, mem, n):
    """On the list: the cursor on slot n."""
    while mem[sym["wSlot"]] < n:
        tap(pb, "down", 12)
    while mem[sym["wSlot"]] > n:
        tap(pb, "up", 12)


def used(mem):
    return mem[sym["wSlotUsed"]]


with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")

    # a fresh cart: slot 1 empty, the demo song is the working one; slot 4 holds data that is not ours
    pb = boot(rom)
    mem = pb.memory
    MEM[:] = [mem]
    pb.stop(save=True)
    data = bytearray(ram.read_bytes())
    foreign = bytes((i * 7 + 3) & 0xFF for i in range(SLOT))
    data[slot_off(3):slot_off(3) + SLOT] = foreign
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    mem = pb.memory
    MEM[:] = [mem]
    pool = Pool(mem, sym)
    v = lambda n: mem[sym[n]]
    check("boot: no slot holds a song (slot 4 is foreign)", used(mem) == 0, used(mem))

    # ---- NEW on an empty slot: it becomes a song
    combo(pb, "start", "down")
    pb.tick(20)
    to_slot(pb, mem, 1)
    item(pb, NEW)
    check("NEW on an empty slot: NEW SONG, no question", v("wMsg") == 8, v("wMsg"))
    check("... the slot is used now and the working song is empty and unnamed", used(mem) == 2 and not pool.lent() and bytes(mem[sym["wName"]:sym["wName"] + 8]) == bytes(8), (used(mem), pool.lent()))
    check("... it is the loaded slot", v("wLoadedSlot") == 1, v("wLoadedSlot"))
    tap(pb, "b")
    item(pb, LOAD)
    check("... and LOAD works on it (LOADED, not NO SAVE DATA)", v("wMsg") == 2, v("wMsg"))
    tap(pb, "b")
    combo(pb, "start", "up")
    pb.tick(30)
    pb.stop(save=True)
    raw = ram.read_bytes()
    got = parse_save(raw[slot_off(1):slot_off(1) + SLOT])
    check("slot 2 holds a valid, empty song", got is not None and got["pages"] == {} and got["name"] == [0] * 8, got and got["length"])
    check("slot 4 (foreign) is untouched", raw[slot_off(3):slot_off(3) + SLOT] == foreign)

    # ---- a song with notes and a name in slot 1, then NEW on it asks and empties it
    pb = boot(rom)
    mem = pb.memory
    MEM[:] = [mem]
    pool = Pool(mem, sym)
    v = lambda n: mem[sym[n]]
    pool.put(0, 0, 0, 5, 64)
    pool.put(1, 2, 0, 9, 50)
    mem[sym["wBpm"]] = 99
    combo(pb, "select", "b")
    check("slot 1 saved (SELECT+B)", v("wMsg") == 1 and used(mem) == 3, (v("wMsg"), used(mem)))
    combo(pb, "start", "down")
    pb.tick(20)
    to_slot(pb, mem, 0)
    item(pb, RENAME)
    for _ in range(2):
        tap(pb, "up", 8)
    tap(pb, "a")
    check("RENAME wrote 'B'", v("wMsg") == 12 and mem[sym["wSlotNames"]] == 2, (v("wMsg"), mem[sym["wSlotNames"]]))
    item(pb, NEW)
    check("NEW on a used slot asks first (AGAIN:ERASE)", v("wMsg") == 14 and v("wConfirm") != 0 and pool.get(0, 0, 0, 5) == 64, (v("wMsg"), v("wConfirm")))
    tap(pb, "a")
    check("... the second press empties it (NEW SONG), name too", v("wMsg") == 8 and not pool.lent() and mem[sym["wName"]] == 0 and mem[sym["wSlotNames"]] == 0, (v("wMsg"), pool.lent(), mem[sym["wSlotNames"]]))
    tap(pb, "b")

    # ---- COPY TO
    pool.put(0, 0, 0, 5, 64)
    pool.put(1, 2, 0, 9, 50)
    mem[sym["wBpm"]] = 99
    item(pb, SAVE)                                  # the menu is closed: A opens it, SAVE
    pb.tick(10)
    check("(slot 1 holds the song again)", v("wMsg") in (1, 6), v("wMsg"))
    if v("wMsg") == 6:
        tap(pb, "a")
    tap(pb, "b")
    item(pb, COPY)
    check("COPY TO opens the target list, the target starts on the next slot", v("wSlotMode") == 2 and v("wCopyTo") == 1, (v("wSlotMode"), v("wCopyTo")))
    tap(pb, "up", 12)
    check("UP picks the target (slot 1 itself)", v("wCopyTo") == 0, v("wCopyTo"))
    tap(pb, "a")
    check("the source as target: SAME SLOT", v("wMsg") == 16, v("wMsg"))
    tap(pb, "down", 12)
    tap(pb, "down", 12)
    check("DOWN picks slot 3", v("wCopyTo") == 2, v("wCopyTo"))
    tap(pb, "a")
    check("COPY into an empty slot: COPIED", v("wMsg") == 9 and used(mem) == 7, (v("wMsg"), used(mem)))
    pb.tick(20)
    tap(pb, "b")                                    # back to the menu
    tap(pb, "b")                                    # and the list
    # copy over a used slot asks
    item(pb, COPY)
    tap(pb, "up", 12)                               # target: slot 1 .. no: from slot 1 the target starts on slot 2
    check("COPY onto a used slot (slot 2)", v("wCopyTo") in (0, 1), v("wCopyTo"))
    mem[sym["wCopyTo"]] = 1
    mem[sym["wMsg"]] = 0
    tap(pb, "a")
    check("... asks first (AGAIN:OVERWRITE)", v("wMsg") == 6, v("wMsg"))
    tap(pb, "a")
    check("... the second A copies", v("wMsg") == 9, v("wMsg"))
    tap(pb, "b")
    tap(pb, "b")
    # copy onto foreign data: refused, bytes untouched
    item(pb, COPY)
    mem[sym["wCopyTo"]] = 3
    tap(pb, "a")
    check("COPY onto data that is not ours: SLOT IN USE", v("wMsg") == 5, v("wMsg"))
    tap(pb, "b")
    tap(pb, "b")
    pb.stop(save=True)
    raw = ram.read_bytes()
    check("slot 3 is a byte for byte copy of slot 1", raw[slot_off(2):slot_off(2) + SLOT] == raw[slot_off(0):slot_off(0) + SLOT])
    check("slot 2 is a copy too (the second COPY)", raw[slot_off(1):slot_off(1) + SLOT] == raw[slot_off(0):slot_off(0) + SLOT])
    check("slot 4 (foreign) is untouched", raw[slot_off(3):slot_off(3) + SLOT] == foreign)
    got = parse_save(raw[slot_off(2):slot_off(2) + SLOT])
    check("the copy has the notes", got is not None and got["pages"].get((0, 0, 0), [0] * 8)[5] == 64 and got["pages"].get((1, 2, 0), [0] * 10)[9] == 50)

    # ---- DELETE
    pb = boot(rom)
    mem = pb.memory
    MEM[:] = [mem]
    v = lambda n: mem[sym[n]]
    combo(pb, "start", "down")
    pb.tick(20)
    to_slot(pb, mem, 2)
    item(pb, DELETE)
    check("DELETE asks first (AGAIN:DELETE)", v("wMsg") == 13, v("wMsg"))
    tap(pb, "a")
    check("... the second press deletes (DELETED) and the slot is FREE", v("wMsg") == 10 and (used(mem) >> 2) & 1 == 0, (v("wMsg"), used(mem)))
    tap(pb, "a")                                    # on the menu (DELETE) again: the slot is empty now
    check("DELETE on an empty slot: SLOT EMPTY", v("wMsg") == 11, v("wMsg"))
    tap(pb, "b")
    to_slot(pb, mem, 3)
    item(pb, DELETE)
    check("DELETE on foreign data: SLOT EMPTY (it is not a song of ours; nothing is written)", v("wMsg") == 11, v("wMsg"))
    tap(pb, "b")
    item(pb, NEW)
    check("NEW on foreign data: SLOT IN USE, and the working song is still there", v("wMsg") == 5 and Pool(mem, sym).lent() != [], (v("wMsg"), Pool(mem, sym).lent()))
    tap(pb, "b")
    to_slot(pb, mem, 2)
    item(pb, RENAME)
    check("RENAME on an empty slot: SLOT EMPTY", v("wMsg") == 11, v("wMsg"))
    pb.stop(save=True)
    raw = ram.read_bytes()
    check("the deleted slot is all zeros", set(raw[slot_off(2):slot_off(2) + SLOT]) == {0})
    check("slot 4 (foreign) is still untouched", raw[slot_off(3):slot_off(3) + SLOT] == foreign)

# ---- a cartridge with one slot (8 KB of SRAM): COPY has nowhere to go
with tempfile.TemporaryDirectory() as tmp:
    data = bytearray(rom_src.read_bytes())
    data[0x149] = 2
    x = 0
    for i in range(0x134, 0x14D):
        x = (x - data[i] - 1) & 0xFF
    data[0x14D] = x                                  # the header checksum PyBoy checks
    rom = pathlib.Path(tmp) / "t.gb"
    rom.write_bytes(bytes(data))
    pb = boot(rom)
    mem = pb.memory
    MEM[:] = [mem]
    v = lambda n: mem[sym[n]]
    combo(pb, "start", "down")
    pb.tick(20)
    check("one slot: the list has one slot", v("wNumSlots") == 1, v("wNumSlots"))
    item(pb, SAVE)
    check("one slot: SAVE works", v("wMsg") == 1, v("wMsg"))
    tap(pb, "b")
    item(pb, COPY)
    check("one slot: COPY says ONLY ONE SLOT", v("wMsg") == 15, v("wMsg"))
    pb.stop(save=False)

print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
