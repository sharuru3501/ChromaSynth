#!/usr/bin/env python3
"""SRAM save/load test using PyBoy (pip install pyboy pillow). Run `make` first.

Uses a temp copy of the ROM so the emulator's .ram file never touches build/.
Covers: save, reboot restore, SELECT+A load, no-save case, corrupted checksum,
the 8 slots (SELECT+LEFT/RIGHT on the play screen), overwrite confirmation, foreign data in a slot.
Slots live in the last 8 KB bank of the 128 KB SRAM (bank 15, 1 KB each); nothing else may be written.
"""
import os
import pathlib
import re
import shutil
import sys
import tempfile

from pyboy import PyBoy
from pool_util import Pool, parse_save

root = pathlib.Path(__file__).resolve().parent.parent
rom_src = pathlib.Path(os.environ.get("ROM", root / "build/chromasynth.gb"))   # ROM=build-card/chromasynth.gb tests the EMS-card build

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
    pb.tick(25)
    return pb


def combo(pb, held, btn):
    pb.button_press(held)
    pb.tick(3)
    pb.button_press(btn)
    pb.tick(3)
    pb.button_release(btn)
    pb.tick(2)
    pb.button_release(held)
    pb.tick(20)       # a save or load of a 4 KB slot takes several frames


# the first slot: bank 0 in the public build (32 KB SRAM), bank 12 in the EMS-card build (128 KB SRAM; header RAM code 4)
BANK0 = (12 if rom_src.read_bytes()[0x149] == 4 else 0) * 8192
BANK12 = BANK0
SLOT = 8192
NAMEOFF = 24                       # the name inside a slot (v11)


def slot_off(n):
    return BANK12 + n * SLOT


patch = sym["wPatch"]

with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")

    # --- fresh cart: nothing saved
    pb = boot(rom)
    mem = pb.memory
    check("fresh: defaults loaded (pattern C4 / BPM 120)", Pool(mem, sym).get(0, 0, 0, 0) == 60 and mem[sym["wBpm"]] == 120)
    combo(pb, "select", "a")
    check("fresh: SELECT+A -> NO SAVE DATA", mem[sym["wMsg"]] == 3, mem[sym["wMsg"]])
    check("fresh: state untouched by failed load", Pool(mem, sym).get(0, 0, 0, 0) == 60)

    # --- edit and save
    Pool(mem, sym).put(0, 1, 0, 1, 77)
    mem[patch + 1] = 9
    mem[sym["wBpm"]] = 133
    mem[sym["wSeqBars"]] = 6
    combo(pb, "select", "b")
    check("SELECT+B -> SAVED", mem[sym["wMsg"]] == 1, mem[sym["wMsg"]])
    pb.tick(100)
    check("message expires", mem[sym["wMsg"]] == 0 and mem[sym["wMsgTimer"]] == 0)
    check("SELECT combo did not change channel/screen", mem[sym["wSelCh"]] == 0 and mem[sym["wScreen"]] == 0)
    pb.stop(save=True)
    check("emulator wrote a .ram file", ram.exists() and ram.stat().st_size >= 8192, ram.stat().st_size if ram.exists() else 0)
    raw = ram.read_bytes()
    check("slot 1 has magic CSYN v12", raw[slot_off(0):slot_off(0) + 5] == b"CSYN\x0c", raw[slot_off(0):slot_off(0) + 5])
    check("nothing outside the four slots was written", BANK12 == 0 or (set(raw[:BANK12]) <= {0, 0xFF} and len(set(raw[:BANK12])) == 1), set(raw[:BANK12]))
    check("slots 2-4 are untouched", len(set(raw[slot_off(1):])) == 1, set(raw[slot_off(1):]))

    # --- reboot: restored automatically
    pb = boot(rom)
    mem = pb.memory
    check("reboot: pattern restored", Pool(mem, sym).get(0, 1, 0, 1) == 77, Pool(mem, sym).get(0, 1, 0, 1))
    check("reboot: patch restored", mem[patch + 1] == 9, mem[patch + 1])
    check("reboot: BPM restored", mem[sym["wBpm"]] == 133, mem[sym["wBpm"]])
    check("reboot: loop length restored", mem[sym["wSeqBars"]] == 6, mem[sym["wSeqBars"]])
    check("reboot: untouched cells keep defaults", Pool(mem, sym).get(0, 0, 0, 0) == 60 and Pool(mem, sym).get(0, 2, 0, 0) == 48)

    # --- SELECT+A reloads the saved copy over unsaved edits
    Pool(mem, sym).put(0, 1, 0, 1, 5)
    mem[sym["wBpm"]] = 90
    combo(pb, "select", "a")
    check("SELECT+A -> LOADED", mem[sym["wMsg"]] == 2, mem[sym["wMsg"]])
    check("SELECT+A restored the saved state", Pool(mem, sym).get(0, 1, 0, 1) == 77 and mem[sym["wBpm"]] == 133)
    pb.stop(save=False)

    # --- corrupted data: checksum must reject it
    data = bytearray(raw)
    data[slot_off(0) + 40] ^= 0xFF
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    mem = pb.memory
    check("corrupt save ignored at boot (defaults kept)", Pool(mem, sym).get(0, 1, 0, 1) == 0 and mem[sym["wBpm"]] == 120,
          (Pool(mem, sym).get(0, 1, 0, 1), mem[sym["wBpm"]]))
    combo(pb, "select", "a")
    check("corrupt save: SELECT+A -> NO SAVE DATA", mem[sym["wMsg"]] == 3)
    pb.stop(save=False)

    # --- wrong version must be ignored too
    data = bytearray(raw)
    data[slot_off(0) + 4] = 0x7F
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    check("other save version ignored", Pool(pb.memory, sym).get(0, 1, 0, 1) == 0)
    pb.stop(save=False)

    # --- slots: SELECT+LEFT/RIGHT on the play screen
    ram.write_bytes(raw)
    pb = boot(rom)
    mem = pb.memory
    check("boot: slot 1 selected, used bitmap = slot 1", mem[sym["wSlot"]] == 0 and mem[sym["wSlotUsed"]] == 1,
          (mem[sym["wSlot"]], mem[sym["wSlotUsed"]]))
    note0 = mem[sym["wJoyNote"]]
    combo(pb, "select", "right")
    check("SELECT+RIGHT -> slot 2", mem[sym["wSlot"]] == 1, mem[sym["wSlot"]])
    check("... without moving the audition note or changing channel", mem[sym["wJoyNote"]] == note0 and mem[sym["wSelCh"]] == 0)
    combo(pb, "select", "left")
    combo(pb, "select", "left")
    check("SELECT+LEFT stops at slot 1", mem[sym["wSlot"]] == 0)
    for _ in range(9):
        combo(pb, "select", "right")
    check("SELECT+RIGHT stops at slot 4", mem[sym["wSlot"]] == 3, mem[sym["wSlot"]])
    for _ in range(7):
        combo(pb, "select", "left")
    combo(pb, "select", "right")             # slot 2 (empty)
    combo(pb, "select", "a")
    check("empty slot: SELECT+A -> NO SAVE DATA", mem[sym["wMsg"]] == 3 and Pool(mem, sym).get(0, 1, 0, 1) == 77, mem[sym["wMsg"]])
    Pool(mem, sym).put(0, 1, 0, 1, 11)
    mem[sym["wBpm"]] = 100
    combo(pb, "select", "b")
    check("empty slot: SELECT+B saves at once", mem[sym["wMsg"]] == 1, mem[sym["wMsg"]])
    check("used bitmap = slots 1 and 2", mem[sym["wSlotUsed"]] == 3, mem[sym["wSlotUsed"]])
    pb.tick(100)
    # a used slot asks first
    Pool(mem, sym).put(0, 1, 0, 1, 12)
    combo(pb, "select", "b")
    check("used slot: first SELECT+B only asks", mem[sym["wMsg"]] == 6 and mem[sym["wConfirm"]] == 2, (mem[sym["wMsg"]], mem[sym["wConfirm"]]))
    pb.stop(save=True)
    r2 = ram.read_bytes()
    check("... and nothing was overwritten yet", parse_save(r2[slot_off(1):slot_off(1) + 8192])["pages"][(0, 1, 0)][1] == 11, None)
    pb = boot(rom)
    mem = pb.memory
    combo(pb, "select", "right")
    combo(pb, "select", "a")
    check("slot 2 restored after reboot", mem[sym["wMsg"]] == 2 and Pool(mem, sym).get(0, 1, 0, 1) == 11 and mem[sym["wBpm"]] == 100,
          (mem[sym["wMsg"]], Pool(mem, sym).get(0, 1, 0, 1), mem[sym["wBpm"]]))
    Pool(mem, sym).put(0, 1, 0, 1, 12)
    combo(pb, "select", "b")
    pb.tick(100)                              # the question expires
    check("the question expires", mem[sym["wConfirm"]] == 0)
    combo(pb, "select", "b")
    combo(pb, "select", "b")
    check("used slot: second SELECT+B overwrites", mem[sym["wMsg"]] == 1, mem[sym["wMsg"]])
    Pool(mem, sym).put(0, 1, 0, 1, 0)
    combo(pb, "select", "a")
    check("slot 2 holds the new data", Pool(mem, sym).get(0, 1, 0, 1) == 12, Pool(mem, sym).get(0, 1, 0, 1))
    combo(pb, "select", "left")
    combo(pb, "select", "a")
    check("slot 1 still holds the first save", Pool(mem, sym).get(0, 1, 0, 1) == 77 and mem[sym["wBpm"]] == 133, (Pool(mem, sym).get(0, 1, 0, 1), mem[sym["wBpm"]]))
    pb.stop(save=True)

    # --- foreign data (LSDj) in a slot is never overwritten
    data = bytearray(ram.read_bytes())
    foreign = bytes((i * 7 + 3) & 0xFF for i in range(SLOT))
    data[slot_off(2):slot_off(2) + SLOT] = foreign
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    mem = pb.memory
    check("foreign slot is not counted as a save", mem[sym["wSlotUsed"]] == 3, mem[sym["wSlotUsed"]])
    combo(pb, "select", "right")
    combo(pb, "select", "right")
    combo(pb, "select", "b")
    check("foreign slot: SELECT+B -> SLOT IN USE", mem[sym["wMsg"]] == 5, mem[sym["wMsg"]])
    pb.stop(save=True)
    check("foreign slot: the bytes are unchanged", ram.read_bytes()[slot_off(2):slot_off(2) + SLOT] == foreign)
    # one differing byte at the very end of an otherwise empty slot is foreign too
    data = bytearray(ram.read_bytes())
    data[slot_off(3):slot_off(3) + SLOT] = b"\x00" * SLOT
    data[slot_off(3) + SLOT - 1] = 0x42
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    mem = pb.memory
    for _ in range(3):
        combo(pb, "select", "right")
    combo(pb, "select", "b")
    check("almost-empty slot: SELECT+B -> SLOT IN USE", mem[sym["wMsg"]] == 5, mem[sym["wMsg"]])
    pb.stop(save=False)


def tap(pb, btn, settle=25):
    pb.button_press(btn)
    pb.tick(3)
    pb.button_release(btn)
    pb.tick(settle)


def menu(pb, item):
    """On the slot screen's list: A opens the menu, DOWN to the item, A runs it."""
    tap(pb, "a")
    for _ in range(item):
        tap(pb, "down", 8)
    tap(pb, "a")


LOAD, SAVE, NEW, COPY, RENAME, DELETE = range(6)

# --- the slot screen (START+DOWN / START+UP, UP/DOWN pick the slot, A opens the menu: LOAD, SAVE, ...)
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")
    pb = boot(rom)
    mem = pb.memory
    combo(pb, "start", "down")
    check("START+DOWN opens the slot list", mem[sym["wScreen"]] == 4 and mem[sym["wScreenBack"]] == 0, (mem[sym["wScreen"]], mem[sym["wScreenBack"]]))
    combo(pb, "start", "right")
    combo(pb, "start", "left")
    check("START+LEFT/RIGHT do nothing on the slot list", mem[sym["wScreen"]] == 4)
    combo(pb, "start", "up")
    check("START+UP goes back to the play screen", mem[sym["wScreen"]] == 0, mem[sym["wScreen"]])
    combo(pb, "start", "right")                       # edit screen
    combo(pb, "start", "down")
    combo(pb, "start", "up")
    check("... and back to the edit screen when it came from there", mem[sym["wScreen"]] == 1, mem[sym["wScreen"]])
    combo(pb, "start", "left")
    combo(pb, "start", "down")
    pb.tick(20)
    Pool(mem, sym).put(0, 1, 0, 1, 33)
    mem[sym["wBpm"]] = 111
    tap(pb, "down")
    tap(pb, "down")
    check("DOWN picks slot 3", mem[sym["wSlot"]] == 2, mem[sym["wSlot"]])
    menu(pb, SAVE)
    check("the menu's SAVE saves into slot 3", mem[sym["wMsg"]] == 1 and mem[sym["wSlotUsed"]] == 4, (mem[sym["wMsg"]], mem[sym["wSlotUsed"]]))
    pb.tick(20)
    tap(pb, "b")                                      # back to the list
    check("B leaves the menu for the list", mem[sym["wSlotMode"]] == 0, mem[sym["wSlotMode"]])
    pb.tick(20)
    # every row must have been drawn (marker on row of slot 3, USED on it, FREE on slot 1)
    def row(n):
        return bytes(mem[0x9800 + (2 + n) * 32 + i] for i in range(18))
    check("slot 3's row: marker and USED", row(2)[0] == ord(">") - 32 and row(2)[14:18] == bytes(ord(c) - 32 for c in "USED"), row(2))
    check("slot 1's row: no marker, FREE", row(0)[0] == 0 and row(0)[14:18] == bytes(ord(c) - 32 for c in "FREE"), row(0))
    tap(pb, "up", 20)
    check("the marker moved to slot 2's row", row(1)[0] == ord(">") - 32 and row(2)[0] == 0, (row(1), row(2)))
    menu(pb, LOAD)
    check("LOAD on an empty slot -> NO SAVE DATA", mem[sym["wMsg"]] == 3, mem[sym["wMsg"]])
    tap(pb, "b")
    tap(pb, "down")
    Pool(mem, sym).put(0, 1, 0, 1, 0)
    menu(pb, LOAD)
    check("LOAD loads slot 3", mem[sym["wMsg"]] == 2 and Pool(mem, sym).get(0, 1, 0, 1) == 33 and mem[sym["wBpm"]] == 111, (mem[sym["wMsg"]], Pool(mem, sym).get(0, 1, 0, 1)))
    pb.tick(100)
    tap(pb, "down", 8)
    tap(pb, "a")                                      # the menu is open on LOAD; DOWN to SAVE
    check("SAVE on a used slot asks first", mem[sym["wMsg"]] == 6, mem[sym["wMsg"]])
    tap(pb, "a")
    check("... the second A overwrites", mem[sym["wMsg"]] == 1, mem[sym["wMsg"]])
    pb.stop(save=False)


# --- song names: RENAME edits the name of a slot's song (UP/DOWN the character, LEFT/RIGHT the cursor, A writes it into the slot)
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")
    NAME = sym["wName"]
    CACHE = sym["wSlotNames"]
    REN = sym["wRenameBuf"]
    pb = boot(rom)
    mem = pb.memory
    check("a new song has a blank name", bytes(mem[NAME:NAME + 8]) == bytes(8))
    combo(pb, "select", "b")                          # save it into slot 1 (the other screens keep SELECT+B)
    check("SELECT+B still saves on the play screen", mem[sym["wMsg"]] == 1, mem[sym["wMsg"]])
    combo(pb, "start", "down")
    pb.tick(20)
    tap(pb, "a")
    for _ in range(RENAME):
        tap(pb, "down", 8)
    tap(pb, "a")
    check("RENAME opens the name editor", mem[sym["wSlotMode"]] == 3, mem[sym["wSlotMode"]])
    tap(pb, "up", 8)                                   # ' ' -> 'A'
    tap(pb, "up", 8)                                   # -> 'B'
    check("UP steps the first character", mem[REN] == 2, mem[REN])
    check("... without moving the slot", mem[sym["wSlot"]] == 0)
    tap(pb, "right", 5)
    check("RIGHT moves the cursor", mem[sym["wNameCur"]] == 1, mem[sym["wNameCur"]])
    tap(pb, "down", 8)                                 # ' ' -> '-' (wraps below the first)
    check("DOWN wraps below the first character", mem[REN + 1] == 37, mem[REN + 1])
    for _ in range(12):
        tap(pb, "right", 3)
    check("the cursor stops at the last character", mem[sym["wNameCur"]] == 7, mem[sym["wNameCur"]])
    pb.tick(25)
    name_row = bytes(mem[0x9800 + 14 * 32 + 5 + i] for i in range(8))
    check("the name row shows 'B-' and the 8th character inverted", name_row[:2] == bytes([ord("B") - 32, ord("-") - 32]) and name_row[7] == 128, name_row)
    tap(pb, "b")                                       # cancel
    check("B cancels: the slot keeps its blank name", mem[CACHE] == 0 and mem[sym["wSlotMode"]] == 1, (mem[CACHE], mem[sym["wSlotMode"]]))
    tap(pb, "a")                                       # the menu is open on RENAME again
    tap(pb, "up", 8)
    tap(pb, "up", 8)
    tap(pb, "right", 5)
    tap(pb, "down", 8)
    tap(pb, "a")                                       # A writes it
    check("A writes the name into the slot (RENAMED)", mem[sym["wMsg"]] == 12 and mem[CACHE] == 2 and mem[CACHE + 1] == 37, (mem[sym["wMsg"]], mem[CACHE]))
    check("... and the working song (the one of this slot) has the new name too", mem[NAME] == 2 and mem[NAME + 1] == 37, (mem[NAME], mem[NAME + 1]))
    pb.tick(20)
    row0 = bytes(mem[0x9800 + 2 * 32 + 5 + i] for i in range(2))
    check("the slot row shows the name", row0 == bytes([ord("B") - 32, ord("-") - 32]), row0)
    pb.stop(save=True)
    raw = ram.read_bytes()
    check("the name is stored in the slot", raw[slot_off(0) + NAMEOFF:slot_off(0) + NAMEOFF + 2] == bytes([2, 37]), raw[slot_off(0) + NAMEOFF:slot_off(0) + NAMEOFF + 4])
    check("... and the checksum was fixed (the slot is still a valid save)", parse_save(raw[slot_off(0):slot_off(0) + SLOT]) is not None)
    pb = boot(rom)
    mem = pb.memory
    check("boot: the slot list cache has the name", mem[CACHE] == 2 and mem[CACHE + 1] == 37, (mem[CACHE], mem[CACHE + 1]))
    check("boot: slot 1 loaded with its name", mem[NAME] == 2 and mem[NAME + 1] == 37, (mem[NAME], mem[NAME + 1]))
    pb.stop(save=False)
    # an out-of-range name byte (corrupt / foreign) becomes blank, not garbage; the checksum then fails, so the slot is ignored
    data = bytearray(raw)
    data[slot_off(0) + NAMEOFF] = 200
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    mem = pb.memory
    check("a damaged slot is ignored (blank name)", mem[NAME] == 0 and mem[CACHE] == 0, (mem[NAME], mem[CACHE]))
    pb.stop(save=False)

# --- a cart without SRAM: the read-back check must report failure, not "SAVED"
with tempfile.TemporaryDirectory() as tmp:
    data = bytearray(rom_src.read_bytes())
    data[0x147] = 0x00  # ROM only
    data[0x149] = 0x00  # no RAM
    x = 0
    for i in range(0x134, 0x14D):
        x = (x - data[i] - 1) & 0xFF
    data[0x14D] = x
    rom = pathlib.Path(tmp) / "norams.gb"
    rom.write_bytes(bytes(data))
    pb = boot(rom)
    combo(pb, "select", "b")
    check("no-SRAM cart: SELECT+B -> SAVE FAILED", pb.memory[sym["wMsg"]] == 4, pb.memory[sym["wMsg"]])
    pb.tick(20)
    pb.stop(save=False)

print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
