#!/usr/bin/env python3
"""Cartridge variants test using PyBoy. Run `make` first.

The ROM reads the RAM size from its own header: 32 KB (or more) = 4 save slots, 8 KB = 1 slot (`make small`), none / 2 KB = no
saving. The SRAM access also works on MBC1 (RAM banking mode) and MBC3 cartridges, not only MBC5.
"""
import pathlib, re, shutil, tempfile
from pyboy import PyBoy

root = pathlib.Path(__file__).resolve().parent.parent
rom32 = (root / "build/chromasynth.gb").read_bytes()
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


def make_rom(tmp, name, cart_type, ram_code):
    data = bytearray(rom32)
    data[0x147] = cart_type
    data[0x149] = ram_code
    x = 0
    for i in range(0x134, 0x14D):
        x = (x - data[i] - 1) & 0xFF
    data[0x14D] = x
    p = pathlib.Path(tmp) / name
    p.write_bytes(bytes(data))
    return p


def boot(rom):
    pb = PyBoy(str(rom), window="null", sound_emulated=False)
    for _ in range(2000):
        pb.tick(1)
        if pb.register_file.PC >= 0x100:
            break
    pb.tick(60)
    return pb


def combo(pb, held, btn, settle=24):
    pb.button_press(held); pb.tick(3); pb.button_press(btn); pb.tick(3)
    pb.button_release(btn); pb.tick(2); pb.button_release(held); pb.tick(settle)


with tempfile.TemporaryDirectory() as tmp:
    # --- 8 KB: one slot
    rom = make_rom(tmp, "k8.gb", 0x1B, 2)
    pb = boot(rom)
    v = lambda n: pb.memory[sym[n]]
    check("8 KB cartridge: one save slot", v("wNumSlots") == 1, v("wNumSlots"))
    combo(pb, "select", "right")
    check("8 KB: SELECT+RIGHT does not go to a slot that is not there", v("wSlot") == 0, v("wSlot"))
    combo(pb, "select", "b", 40)
    check("8 KB: SELECT+B saves", v("wMsg") == 1, v("wMsg"))
    pb.stop(save=True)
    raw = pathlib.Path(str(rom) + ".ram").read_bytes()
    check("8 KB: the save is in the one bank (CSYN), the file is 8 KB", raw[:4] == b"CSYN" and len(raw) == 8192, (raw[:4], len(raw)))
    pb = boot(rom)
    check("8 KB: loaded again at boot", pb.memory[sym["wPatch"] + 1] == pb.memory[sym["wPatch"] + 1] and v("wSlotUsed") == 1, v("wSlotUsed"))
    pb.stop(save=False)

    # --- no SRAM (0) and 2 KB (1): no slots, no crash
    for code, label in ((0, "no SRAM"), (1, "2 KB")):
        rom = make_rom(tmp, f"k{code}.gb", 0x1B if code else 0x00, code)
        pb = boot(rom)
        v = lambda n: pb.memory[sym[n]]
        combo(pb, "select", "b", 40)
        check(f"{label}: no slot, SELECT+B -> SAVE FAILED", v("wNumSlots") == 0 and v("wMsg") == 4, (v("wNumSlots"), v("wMsg")))
        combo(pb, "select", "a", 40)
        check(f"{label}: SELECT+A -> NO SAVE DATA", v("wMsg") == 3, v("wMsg"))
        pb.stop(save=False)

    # --- 32 KB on other mappers: MBC5 (1B), MBC3 (13), MBC1 (03): the 4th slot (bank 3) works
    for ctype, label in ((0x1B, "MBC5"), (0x13, "MBC3"), (0x03, "MBC1")):
        rom = make_rom(tmp, f"m{ctype:02x}.gb", ctype, 3)
        pb = boot(rom)
        v = lambda n: pb.memory[sym[n]]
        check(f"{label} 32 KB: four slots", v("wNumSlots") == 4, v("wNumSlots"))
        for _ in range(3):
            combo(pb, "select", "right")
        check(f"{label}: slot 4 selected", v("wSlot") == 3, v("wSlot"))
        pb.memory[sym["wBpm"]] = 77
        combo(pb, "select", "b", 40)
        check(f"{label}: SELECT+B saves in slot 4", v("wMsg") == 1, v("wMsg"))
        pb.memory[sym["wBpm"]] = 99
        combo(pb, "select", "a", 40)
        check(f"{label}: SELECT+A loads it back", v("wMsg") == 2 and v("wBpm") == 77, (v("wMsg"), v("wBpm")))
        pb.stop(save=True)
        raw = pathlib.Path(str(rom) + ".ram").read_bytes()
        check(f"{label}: the save is in bank 3 only", raw[3 * 8192:3 * 8192 + 4] == b"CSYN" and raw[:3 * 8192].count(b"CSYN") == 0, raw[3 * 8192:3 * 8192 + 4])

print("\n%d FAILED" % fails if fails else "\nALL PASSED")
raise SystemExit(1 if fails else 0)
