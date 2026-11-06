#!/usr/bin/env python3
"""SRAM save/load test using PyBoy (pip install pyboy pillow). Run `make` first.

Uses a temp copy of the ROM so the emulator's .ram file never touches build/.
Covers: save, reboot restore, SELECT+B load, no-save case, corrupted checksum.
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
    pb.tick(10)
    return pb


def combo(pb, held, btn):
    pb.button_press(held)
    pb.tick(3)
    pb.button_press(btn)
    pb.tick(3)
    pb.button_release(btn)
    pb.tick(2)
    pb.button_release(held)
    pb.tick(3)


P = sym["wPattern"]
patch = sym["wPatch"]

with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")

    # --- fresh cart: nothing saved
    pb = boot(rom)
    mem = pb.memory
    check("fresh: defaults loaded (pattern C4 / BPM 120)", mem[P] == 60 and mem[sym["wBpm"]] == 120)
    combo(pb, "select", "b")
    check("fresh: SELECT+B -> NO SAVE DATA", mem[sym["wMsg"]] == 3, mem[sym["wMsg"]])
    check("fresh: state untouched by failed load", mem[P] == 60)

    # --- edit and save
    mem[P + 17] = 77
    mem[patch + 1] = 9
    mem[sym["wBpm"]] = 133
    combo(pb, "select", "a")
    check("SELECT+A -> SAVED", mem[sym["wMsg"]] == 1, mem[sym["wMsg"]])
    pb.tick(100)
    check("message expires", mem[sym["wMsg"]] == 0 and mem[sym["wMsgTimer"]] == 0)
    check("SELECT combo did not change channel/screen", mem[sym["wSelCh"]] == 0 and mem[sym["wScreen"]] == 0)
    pb.stop(save=True)
    check("emulator wrote a .ram file", ram.exists() and ram.stat().st_size >= 8192, ram.stat().st_size if ram.exists() else 0)
    raw = ram.read_bytes()
    check("slot has magic CSYN v1", raw[:5] == b"CSYN\x01", raw[:5])

    # --- reboot: restored automatically
    pb = boot(rom)
    mem = pb.memory
    check("reboot: pattern restored", mem[P + 17] == 77, mem[P + 17])
    check("reboot: patch restored", mem[patch + 1] == 9, mem[patch + 1])
    check("reboot: BPM restored", mem[sym["wBpm"]] == 133, mem[sym["wBpm"]])
    check("reboot: untouched cells keep defaults", mem[P] == 60 and mem[P + 32] == 48)

    # --- SELECT+B reloads the saved copy over unsaved edits
    mem[P + 17] = 5
    mem[sym["wBpm"]] = 90
    combo(pb, "select", "b")
    check("SELECT+B -> LOADED", mem[sym["wMsg"]] == 2, mem[sym["wMsg"]])
    check("SELECT+B restored the saved state", mem[P + 17] == 77 and mem[sym["wBpm"]] == 133)
    pb.stop(save=False)

    # --- corrupted data: checksum must reject it
    data = bytearray(raw)
    data[40] ^= 0xFF
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    mem = pb.memory
    check("corrupt save ignored at boot (defaults kept)", mem[P + 17] == 0 and mem[sym["wBpm"]] == 120,
          (mem[P + 17], mem[sym["wBpm"]]))
    combo(pb, "select", "b")
    check("corrupt save: SELECT+B -> NO SAVE DATA", mem[sym["wMsg"]] == 3)
    pb.stop(save=False)

    # --- wrong version must be ignored too
    data = bytearray(raw)
    data[4] = 0x7F
    ram.write_bytes(bytes(data))
    pb = boot(rom)
    check("other save version ignored", pb.memory[P + 17] == 0)
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
