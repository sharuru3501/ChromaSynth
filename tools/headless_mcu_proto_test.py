#!/usr/bin/env python3
"""End to end: the MCU's C encoder (chromatic-mcu/src/chlink_proto.c, via test/chl_cli) drives the ROM in PyBoy.

The masks the MCU would write to the FPGA's button register are turned into joypad buttons, held for 3
frames each, exactly as the MCU's link task does. Run `make` first. (Needs `cc`; builds the CLI itself.)
"""
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

from pyboy import PyBoy

root = pathlib.Path(__file__).resolve().parent.parent
subprocess.run(["make", "-s", "-C", str(root / "chromatic-mcu/test"), "chl_cli"], check=True)
CLI = str(root / "chromatic-mcu/test/chl_cli")
sym = {}
for line in (root / "build/chromasynth.sym").read_text().splitlines():
    m = re.match(r"([0-9A-Fa-f]{2}):([0-9A-Fa-f]{4}) (\S+)", line)
    if m:
        sym[m.group(3)] = int(m.group(2), 16)
BITS = [(1, "start"), (2, "select"), (4, "b"), (8, "a"), (16, "up"), (32, "right"), (64, "left"), (128, "down")]

fails = 0


def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail != "" else ""))
    fails += not cond


tmp = tempfile.mkdtemp()
rom = pathlib.Path(tmp) / "t.gb"
shutil.copy(root / "build/chromasynth.gb", rom)
pb = PyBoy(str(rom), window="null", sound_emulated=False)
mem = pb.memory
for _ in range(2000):
    pb.tick(1)
    if pb.register_file.PC >= 0x100:
        break
pb.tick(100)
v = lambda n: mem[sym[n]]
cur = lambda ch: mem[sym["wCurNote"] + ch]
held = set()


def hold(buttons, frames):
    global held
    for b in held - buttons:
        pb.button_release(b)
    for b in buttons - held:
        pb.button_press(b)
    held = set(buttons)
    pb.tick(frames)


def cli(*args):
    return [int(x, 16) for x in subprocess.run([CLI, *map(str, args)], capture_output=True, text=True, check=True).stdout.split()]


def slot_bytes():
    return [mem[sym["wClSlot"] + i] for i in range(4)]


def mcu_view():
    """What the MCU's link task decides from the slot the ROM wrote (the C classifier in chl_cli)."""
    b = slot_bytes()
    return subprocess.run([CLI, "slot", *map(str, b)], capture_output=True, text=True, check=True).stdout.strip()


def mcu_send(masks, hold_frames=3):
    """What the MCU's link task does: hold each symbol's mask, then release."""
    for m in masks:
        hold({name for bit, name in BITS if m & bit}, hold_frames)
    hold(set(), 2)


def press(btn, frames=4):
    pb.button_press(btn)
    pb.tick(frames)
    pb.button_release(btn)
    pb.tick(3)


for _ in range(8):
    if v("wScreen") == 3:
        break
    press("start")
pb.tick(10)
check("the ROM is on the keyboard screen", v("wScreen") == 3, v("wScreen"))
phase = v("wClNextPh")   # the MCU assumes 0 at boot; the ROM starts with 0 too
check("ROM and MCU start with the same phase", phase == 0, phase)

check("the MCU's classifier sees the ROM's beacon on the keyboard screen", mcu_view() == "kbd", slot_bytes())
mem[sym["wSelCh"]] = 0
mcu_send(cli("play", 1, 60, 100, phase))
check("not linked: a play packet from the C encoder does nothing", cur(0) == 0 and v("wClLinked") == 0, cur(0))
mcu_send(cli("midi", 0xFE, 0x43, 0x53, v("wClNextPh")))
check("HELLO from the C encoder links", v("wClLinked") == 1)
pb.tick(2)
check("... and the MCU's classifier then sees an ordinary slot (armed)", mcu_view() == "other", slot_bytes())
check("... and the phase is still in step after an 8-symbol packet", v("wClNextPh") == phase, v("wClNextPh"))

for note in (36, 37, 60, 61, 72, 96, 107):   # the ROM's range is 36..107 (inc/synth.inc)
    mcu_send(cli("play", 1, note, 100, v("wClNextPh")))
    on = cur(0)
    mcu_send(cli("play", 0, note, 0, v("wClNextPh")))
    check("note %d: on then off through the C encoder" % note, on == note and cur(0) == 0, (on, cur(0)))

for vel in (0, 16, 127):
    mcu_send(cli("play", 1, 64, vel, v("wClNextPh")))
    vol = mem[sym["wVoiceVol"]]
    mcu_send(cli("play", 0, 64, 0, v("wClNextPh")))
    if vel == 0:
        soft = vol
    if vel == 127:
        check("velocity: 127 is louder than 0", vol > soft, (soft, vol))

mem[sym["wSelCh"]] = 2
mcu_send(cli("play", 1, 70, 100, v("wClNextPh")))
check("a note goes to the channel selected on the ROM (CH3)", cur(2) == 70 and cur(0) == 0, (cur(2), cur(0)))
mcu_send(cli("play", 0, 70, 0, v("wClNextPh")))
mem[sym["wSelCh"]] = 0

mcu_send(cli("midi", 0x90, 62, 100, v("wClNextPh")))
check("a general MIDI packet from the C encoder: note-on", cur(0) == 62, cur(0))
mcu_send(cli("midi", 0x80, 62, 0, v("wClNextPh")))
check("... and note-off", cur(0) == 0, cur(0))
mcu_send(cli("midi", 0xC0, 3, 0xFE, v("wClNextPh")))
check("a padded 2-byte MIDI message is accepted (no nack)", v("wClNack") == 0, v("wClNack"))

# the keep-alive: a note-0 off packet every 2 s keeps the link up for much longer than the 4 s timeout
for _ in range(5):
    pb.tick(120)
    mcu_send(cli("play", 0, 0, 0, v("wClNextPh")))
check("keep-alive packets (note 0 off every 2 s) hold the link for 10 s", v("wClLinked") == 1)
pb.tick(260)
check("without them the link drops after about 4 s", v("wClLinked") == 0)

# phase sync (`link sync`): the ROM and the MCU disagree; one stray symbol aligns them in both cases
mcu_send(cli("midi", 0xFE, 0x43, 0x53, v("wClNextPh")))
check("relinked", v("wClLinked") == 1)
for rom_ahead in (False, True):
    if rom_ahead:
        mcu_send(cli("sync", v("wClNextPh")))   # the ROM accepts a stray symbol: it now expects the other phase
        pb.tick(40)                              # (it drops the half packet by itself)
    rom_phase = v("wClNextPh")
    mcu_phase = rom_phase ^ 1                    # the MCU believes the opposite
    mcu_send(cli("sync", mcu_phase))             # link sync: send one symbol with the MCU's phase, then the MCU flips
    pb.tick(45)
    mcu_phase ^= 1
    check("after link sync the MCU's phase equals the ROM's (ROM was %s)" % ("ahead" if rom_ahead else "behind"),
          mcu_phase == v("wClNextPh"), (mcu_phase, v("wClNextPh")))
    mcu_send(cli("play", 1, 60, 100, mcu_phase))
    check("... and the next packet works", cur(0) == 60, cur(0))
    mcu_send(cli("play", 0, 60, 0, v("wClNextPh")))

# leaving the keyboard screen: the MCU must see the end beacon and stop
pb.button_press("select")
pb.button_press("start")
pb.tick(70)
pb.button_release("select")
pb.button_release("start")
pb.tick(4)
check("the ROM left the keyboard screen and unlinked", v("wScreen") == 0 and v("wClLinked") == 0, (v("wScreen"), v("wClLinked")))
check("the MCU's classifier sees the end beacon (stop sending)", mcu_view() == "left", slot_bytes())
pb.tick(30)
check("... and it stays that way while the ROM is elsewhere", mcu_view() == "left", slot_bytes())

print()
print("ALL PASSED" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
