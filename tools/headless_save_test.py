#!/usr/bin/env python3
"""SRAM save/load test using PyBoy (pip install pyboy pillow). Run `make` first.

Uses a temp copy of the ROM so the emulator's .ram file never touches build/.
Covers: save, reboot restore, SELECT+B load, no-save case, corrupted checksum,
the 8 slots (SELECT+LEFT/RIGHT on the play screen), overwrite confirmation, foreign data in a slot.
Slots live in the last 8 KB bank of the 128 KB SRAM (bank 15, 1 KB each); nothing else may be written.
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


BANK12 = 12 * 8192
SLOT = 8192
PAT0 = 5 + 160 + 16 + 2          # the first pattern inside a slot (v9)
NAMEOFF = 5 + 6322 + 1             # the name inside a slot


def slot_off(n):
    return BANK12 + n * SLOT


P = sym["wPattern"]
patch = sym["wPatch"]

with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")

    # --- fresh cart: nothing saved
    pb = boot(rom)
    mem = pb.memory
    check("fresh: defaults loaded (pattern C4 / BPM 120)", mem[1, P] == 60 and mem[sym["wBpm"]] == 120)
    combo(pb, "select", "b")
    check("fresh: SELECT+B -> NO SAVE DATA", mem[sym["wMsg"]] == 3, mem[sym["wMsg"]])
    check("fresh: state untouched by failed load", mem[1, P] == 60)

    # --- edit and save
    mem[1, P + 513] = 77
    mem[patch + 1] = 9
    mem[sym["wBpm"]] = 133
    mem[sym["wSeqBars"]] = 6
    combo(pb, "select", "a")
    check("SELECT+A -> SAVED", mem[sym["wMsg"]] == 1, mem[sym["wMsg"]])
    pb.tick(100)
    check("message expires", mem[sym["wMsg"]] == 0 and mem[sym["wMsgTimer"]] == 0)
    check("SELECT combo did not change channel/screen", mem[sym["wSelCh"]] == 0 and mem[sym["wScreen"]] == 0)
    pb.stop(save=True)
    check("emulator wrote a .ram file", ram.exists() and ram.stat().st_size >= 8192, ram.stat().st_size if ram.exists() else 0)
    raw = ram.read_bytes()
    check("slot 1 has magic CSYN v9", raw[slot_off(0):slot_off(0) + 5] == b"CSYN\x09", raw[slot_off(0):slot_off(0) + 5])
    check("nothing outside banks 12-15 was written", set(raw[:BANK12]) <= {0, 0xFF} and len(set(raw[:BANK12])) == 1, set(raw[:BANK12]))
    check("slots 2-4 are untouched", len(set(raw[slot_off(1):])) == 1, set(raw[slot_off(1):]))

    # --- reboot: restored automatically
    pb = boot(rom)
    mem = pb.memory
    check("reboot: pattern restored", mem[1, P + 513] == 77, mem[1, P + 513])
    check("reboot: patch restored", mem[patch + 1] == 9, mem[patch + 1])
    check("reboot: BPM restored", mem[sym["wBpm"]] == 133, mem[sym["wBpm"]])
    check("reboot: loop length restored", mem[sym["wSeqBars"]] == 6, mem[sym["wSeqBars"]])
    check("reboot: untouched cells keep defaults", mem[1, P] == 60 and mem[1, P + 1024] == 48)

    # --- SELECT+B reloads the saved copy over unsaved edits
    mem[1, P + 513] = 5
    mem[sym["wBpm"]] = 90
    combo(pb, "select", "b")
    check("SELECT+B -> LOADED", mem[sym["wMsg"]] == 2, mem[sym["wMsg"]])
    check("SELECT+B restored the saved state", mem[1, P + 513] == 77 and mem[sym["wBpm"]] == 133)
    pb.stop(save=False)

    # --- corrupted data: checksum must reject it
    data = bytearray(raw)
    data[slot_off(0) + 40] ^= 0xFF
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    mem = pb.memory
    check("corrupt save ignored at boot (defaults kept)", mem[1, P + 513] == 0 and mem[sym["wBpm"]] == 120,
          (mem[1, P + 513], mem[sym["wBpm"]]))
    combo(pb, "select", "b")
    check("corrupt save: SELECT+B -> NO SAVE DATA", mem[sym["wMsg"]] == 3)
    pb.stop(save=False)

    # --- wrong version must be ignored too
    data = bytearray(raw)
    data[slot_off(0) + 4] = 0x7F
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    check("other save version ignored", pb.memory[P + 257] == 0)
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
    combo(pb, "select", "b")
    check("empty slot: SELECT+B -> NO SAVE DATA", mem[sym["wMsg"]] == 3 and mem[1, P + 513] == 77, mem[sym["wMsg"]])
    mem[1, P + 513] = 11
    mem[sym["wBpm"]] = 100
    combo(pb, "select", "a")
    check("empty slot: SELECT+A saves at once", mem[sym["wMsg"]] == 1, mem[sym["wMsg"]])
    check("used bitmap = slots 1 and 2", mem[sym["wSlotUsed"]] == 3, mem[sym["wSlotUsed"]])
    pb.tick(100)
    # a used slot asks first
    mem[1, P + 513] = 12
    combo(pb, "select", "a")
    check("used slot: first SELECT+A only asks", mem[sym["wMsg"]] == 6 and mem[sym["wConfirm"]] == 2, (mem[sym["wMsg"]], mem[sym["wConfirm"]]))
    pb.stop(save=True)
    r2 = ram.read_bytes()
    check("... and nothing was overwritten yet", r2[slot_off(1) + PAT0 + 2 * 192 + 1] == 11, r2[slot_off(1) + PAT0 + 2 * 192 + 1])
    pb = boot(rom)
    mem = pb.memory
    combo(pb, "select", "right")
    combo(pb, "select", "b")
    check("slot 2 restored after reboot", mem[sym["wMsg"]] == 2 and mem[1, P + 513] == 11 and mem[sym["wBpm"]] == 100,
          (mem[sym["wMsg"]], mem[1, P + 513], mem[sym["wBpm"]]))
    mem[1, P + 513] = 12
    combo(pb, "select", "a")
    pb.tick(100)                              # the question expires
    check("the question expires", mem[sym["wConfirm"]] == 0)
    combo(pb, "select", "a")
    combo(pb, "select", "a")
    check("used slot: second SELECT+A overwrites", mem[sym["wMsg"]] == 1, mem[sym["wMsg"]])
    mem[1, P + 513] = 0
    combo(pb, "select", "b")
    check("slot 2 holds the new data", mem[1, P + 513] == 12, mem[1, P + 513])
    combo(pb, "select", "left")
    combo(pb, "select", "b")
    check("slot 1 still holds the first save", mem[1, P + 513] == 77 and mem[sym["wBpm"]] == 133, (mem[1, P + 513], mem[sym["wBpm"]]))
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
    combo(pb, "select", "a")
    check("foreign slot: SELECT+A -> SLOT IN USE", mem[sym["wMsg"]] == 5, mem[sym["wMsg"]])
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
    combo(pb, "select", "a")
    check("almost-empty slot: SELECT+A -> SLOT IN USE", mem[sym["wMsg"]] == 5, mem[sym["wMsg"]])
    pb.stop(save=False)


# --- the slot list screen (START+DOWN / START+UP, UP/DOWN pick, A load, B save)
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
    mem[1, P + 513] = 33
    mem[sym["wBpm"]] = 111
    pb.button_press("down"); pb.tick(3); pb.button_release("down"); pb.tick(25)
    pb.button_press("down"); pb.tick(3); pb.button_release("down"); pb.tick(25)
    check("DOWN picks slot 3", mem[sym["wSlot"]] == 2, mem[sym["wSlot"]])
    pb.button_press("b"); pb.tick(3); pb.button_release("b"); pb.tick(25)
    check("B saves into slot 3", mem[sym["wMsg"]] == 1 and mem[sym["wSlotUsed"]] == 4, (mem[sym["wMsg"]], mem[sym["wSlotUsed"]]))
    pb.tick(20)
    # every row must have been drawn (marker on row of slot 3, USED on it, FREE on slot 1)
    def row(n):
        return bytes(mem[0x9800 + (2 + n) * 32 + i] for i in range(18))
    check("slot 3's row: marker and USED", row(2)[0] == ord(">") - 32 and row(2)[14:18] == bytes(ord(c) - 32 for c in "USED"), row(2))
    check("slot 1's row: no marker, FREE", row(0)[0] == 0 and row(0)[14:18] == bytes(ord(c) - 32 for c in "FREE"), row(0))
    pb.button_press("up"); pb.tick(3); pb.button_release("up"); pb.tick(20)
    check("the marker moved to slot 2's row", row(1)[0] == ord(">") - 32 and row(2)[0] == 0, (row(1), row(2)))
    pb.button_press("a"); pb.tick(3); pb.button_release("a"); pb.tick(25)
    check("A on an empty slot -> NO SAVE DATA", mem[sym["wMsg"]] == 3, mem[sym["wMsg"]])
    pb.button_press("down"); pb.tick(3); pb.button_release("down"); pb.tick(25)
    mem[1, P + 513] = 0
    pb.button_press("a"); pb.tick(3); pb.button_release("a"); pb.tick(25)
    check("A loads slot 3", mem[sym["wMsg"]] == 2 and mem[1, P + 513] == 33 and mem[sym["wBpm"]] == 111, (mem[sym["wMsg"]], mem[1, P + 513]))
    pb.tick(100)
    pb.button_press("b"); pb.tick(3); pb.button_release("b"); pb.tick(25)
    check("B on a used slot asks first", mem[sym["wMsg"]] == 6, mem[sym["wMsg"]])
    pb.button_press("b"); pb.tick(3); pb.button_release("b"); pb.tick(25)
    check("... the second B overwrites", mem[sym["wMsg"]] == 1, mem[sym["wMsg"]])
    pb.stop(save=False)


# --- song names: SELECT+UP/DOWN edits the character, LEFT/RIGHT moves the cursor; saved with the slot
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")
    NAME = sym["wName"]
    CACHE = sym["wSlotNames"]
    pb = boot(rom)
    mem = pb.memory
    combo(pb, "start", "down")
    pb.tick(20)
    check("a new song has a blank name", bytes(mem[NAME:NAME + 8]) == bytes(8))
    combo(pb, "select", "up")                          # ' ' -> 'A'
    combo(pb, "select", "up")                          # -> 'B'
    check("SELECT+UP steps the first character", mem[NAME] == 2, mem[NAME])
    check("... without moving the slot or changing channel", mem[sym["wSlot"]] == 0 and mem[sym["wSelCh"]] == 0)
    pb.button_press("right"); pb.tick(3); pb.button_release("right"); pb.tick(5)
    check("RIGHT moves the cursor", mem[sym["wNameCur"]] == 1, mem[sym["wNameCur"]])
    combo(pb, "select", "down")                        # ' ' -> '-' (wraps below the first)
    check("SELECT+DOWN wraps below the first character", mem[NAME + 1] == 37, mem[NAME + 1])
    for _ in range(12):
        pb.button_press("right"); pb.tick(3); pb.button_release("right"); pb.tick(3)
    check("the cursor stops at the last character", mem[sym["wNameCur"]] == 7, mem[sym["wNameCur"]])
    pb.tick(25)
    name_row = bytes(mem[0x9800 + 11 * 32 + 5 + i] for i in range(8))
    check("the name row shows 'B-'", name_row[:2] == bytes([ord("B") - 32, ord("-") - 32]), name_row)
    cur_row = bytes(mem[0x9800 + 12 * 32 + 5 + i] for i in range(8))
    check("the cursor mark is under the 8th character", cur_row == bytes(7) + bytes([ord("+") - 32]), cur_row)
    pb.button_press("b"); pb.tick(3); pb.button_release("b"); pb.tick(30)
    check("B saves the song with its name", mem[sym["wMsg"]] == 1 and mem[CACHE] == 2 and mem[CACHE + 1] == 37, (mem[sym["wMsg"]], mem[CACHE]))
    row0 = bytes(mem[0x9800 + 2 * 32 + 5 + i] for i in range(2))
    check("the slot row shows the name", row0 == bytes([ord("B") - 32, ord("-") - 32]), row0)
    pb.stop(save=True)
    raw = ram.read_bytes()
    check("the name is stored after the checksum", raw[slot_off(0) + NAMEOFF:slot_off(0) + NAMEOFF + 2] == bytes([2, 37]), raw[slot_off(0) + NAMEOFF:slot_off(0) + NAMEOFF + 4])
    pb = boot(rom)
    mem = pb.memory
    check("boot: the slot list cache has the name", mem[CACHE] == 2 and mem[CACHE + 1] == 37, (mem[CACHE], mem[CACHE + 1]))
    check("boot: slot 1 loaded with its name", mem[NAME] == 2 and mem[NAME + 1] == 37, (mem[NAME], mem[NAME + 1]))
    pb.stop(save=False)
    # an out-of-range name byte (corrupt / foreign) becomes blank, not garbage
    data = bytearray(raw)
    data[slot_off(0) + NAMEOFF] = 200
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    mem = pb.memory
    check("an out-of-range name byte is blanked", mem[NAME] == 0 and mem[CACHE] == 0, (mem[NAME], mem[CACHE]))
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
    combo(pb, "select", "a")
    check("no-SRAM cart: SELECT+A -> SAVE FAILED", pb.memory[sym["wMsg"]] == 4, pb.memory[sym["wMsg"]])
    pb.tick(20)
    pb.stop(save=False)

print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
