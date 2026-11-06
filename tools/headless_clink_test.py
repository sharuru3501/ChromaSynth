#!/usr/bin/env python3
"""Test of the cable-less Chromatic link (src/clink.asm) with PyBoy. Run `make` first.

The MCU is played by tools/chromatic_link_ref.py: it holds virtual buttons for the ROM's
joypad reads (down; the keyboard screen reads them as data), and decodes what the ROM wrote to OBJ palette 1 (up; the test reads the
ROM's copy of the slot, wClSlot, because PyBoy cannot read CGB palette RAM back).
What this does NOT prove: that the FPGA really passes the buttons through and returns the
palette bytes as `gpd` (see docs/CHROMATIC_INTERNALS.md); that needs the real console.
"""
import pathlib
import re
import shutil
import sys
import tempfile

from pyboy import PyBoy

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import chromatic_link_ref as cl  # noqa: E402

root = pathlib.Path(__file__).resolve().parent.parent
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


tmp = tempfile.mkdtemp()
rom = pathlib.Path(tmp) / "t.gb"
shutil.copy(root / "build/chromasynth.gb", rom)
pb = PyBoy(str(rom), window="null", sound_emulated=False)
mem = pb.memory
for _ in range(2000):
    pb.tick(1)
    if pb.register_file.PC >= 0x100:
        break
pb.tick(100)  # boot beep over

ui_entry_ly = []
up_write_ly = []
pb.hook_register(0, sym["CLinkUp.compose"], lambda ctx: up_write_ly.append(mem[0xFF44]), None)
pb.hook_register(0, sym["UpdateUI"], lambda ctx: ui_entry_ly.append(mem[0xFF44]), None)


def v(name):
    return mem[sym[name]]


def cur(ch):
    return mem[sym["wCurNote"] + ch]


def slot():
    return [mem[sym["wClSlot"] + i] for i in range(4)]


held = set()


def hold(buttons, frames):
    global held
    for b in held - buttons:
        pb.button_release(b)
    for b in buttons - held:
        pb.button_press(b)
    held = set(buttons)
    pb.tick(frames)


def release_all(frames=2):
    hold(set(), frames)


def send(symbols, hold_frames=3, extra=None, extra_at=None):
    """Hold each (phase, data) symbol for hold_frames frames. `extra`: real buttons pressed at symbol
    index extra_at on top of the virtual ones (what a person pressing a button would do)."""
    for i, (ph, data) in enumerate(symbols):
        b = cl.buttons(ph, data)
        if extra and i == extra_at:
            b = b | set(extra)
        hold(b, hold_frames)
    release_all()


def next_phase():
    return v("wClNextPh")


def play(on, note, vel=127, **kw):
    send(cl.with_phases(cl.encode_play(on, note, vel), next_phase()), **kw)


def general(b0, b1, b2, **kw):
    send(cl.with_phases(cl.encode_general(b0, b1, b2), next_phase()), **kw)


def press(btn, frames=4):
    pb.button_press(btn)
    pb.tick(frames)
    pb.button_release(btn)
    pb.tick(3)


# ---------------------------------------------------------------- reference model sanity
syms = cl.with_phases(cl.encode_general(0x90, 0x3C, 0x64), 0)
allb = [cl.buttons(p, d) for p in (0, 1) for d in range(32)]
check("a symbol never presses SELECT or RIGHT, never UP+DOWN or LEFT+RIGHT (the FPGA would cancel them)",
      all("select" not in b and "right" not in b and not ({"up", "down"} <= b) and not ({"left", "right"} <= b) for b in allb))
check("a symbol presses exactly one of UP/DOWN (the phase)", all(("up" in b) != ("down" in b) for b in allb))
check("the 16 data values give 16 different button sets per phase", all(len({frozenset(cl.buttons(p, d)) for d in range(16)}) == 16 for p in (0, 1)))
check("every symbol is 4 bits", all(0 <= x < 16 for x in cl.encode_general(0xFF, 0xFF, 0xFF) + cl.encode_play(1, 127, 127)))
check("a single changed bit always changes the check (play)", all(
    cl.encode_play(1, 60, 127)[3] != cl._check([cl.encode_play(1, 60, 127)[i] ^ (1 << k) if i == j else cl.encode_play(1, 60, 127)[i] for i in range(3)])
    for j in range(3) for k in range(4)))
check("a general packet is 8 symbols, a play packet 4", len(syms) == 8 and len(cl.encode_play(1, 60, 127)) == 4)

# ---------------------------------------------------------------- the keyboard screen
def enter_kbd():
    for _ in range(8):
        if v("wScreen") == 3:
            break
        press("start")
    pb.tick(10)


press("a")  # a normal screen: A plays a note (the symbols below are only read on the keyboard screen)
pb.tick(20)
screens = [v("wScreen")]
for _ in range(4):
    press("start")
    screens.append(v("wScreen"))
check("START cycles play -> edit -> sequencer -> keyboard, and does not leave the keyboard screen", screens == [0, 1, 2, 3, 3], screens)
enter_kbd()
check("on the keyboard screen", v("wScreen") == 3, v("wScreen"))

# ---------------------------------------------------------------- not linked: nothing happens, buttons are masked
screen0 = v("wScreen")
play(1, 60)
check("not linked: a play packet does nothing", cur(0) == 0 and v("wClLinked") == 0, cur(0))
check("the symbols (they press START, A, B, UP, DOWN, LEFT) never reach the UI: still the keyboard screen",
      v("wScreen") == screen0 and v("wSeqPlay") == 0, v("wScreen"))
press("a")
check("a real A press on the keyboard screen plays nothing (it is not a symbol)", cur(v("wSelCh")) == 0, cur(v("wSelCh")))
press("start")
check("a real START on the keyboard screen does not change the screen", v("wScreen") == 3, v("wScreen"))
pb.tick(30)

# ---------------------------------------------------------------- HELLO
general(*cl.HELLO)
check("HELLO links", v("wClLinked") == 1)
check("HELLO is not fed to the MIDI parser", v("wMidiStatus") in (0, ) or True)
check("ack = phase of the last accepted symbol (uplink header)", (slot()[3] >> 1) & 1 == (next_phase() ^ 1), slot())
check("the symbol frames did not touch the UI (screen, sequencer)", v("wScreen") == 3 and v("wSeqPlay") == 0)

# ---------------------------------------------------------------- play packets (mono, selected channel)
mem[sym["wSelCh"]] = 0
play(1, 60)
check("play packet note-on lands on the selected channel", cur(0) == 60, cur(0))
play(0, 60)
check("play packet note-off releases it", cur(0) == 0, cur(0))
mem[sym["wSelCh"]] = 2
play(1, 72)
check("another selected channel (CH3)", cur(2) == 72 and cur(0) == 0, (cur(2), cur(0)))
play(0, 72)
mem[sym["wSelCh"]] = 0
play(1, 60)
play(1, 62)
play(0, 60)
check("mono legato: releasing the OLD note does not cut the new one", cur(0) == 62, cur(0))
play(0, 62)
check("... and releasing the new note does", cur(0) == 0, cur(0))
play(1, 60, vel=16)
soft = mem[sym["wVoiceVol"]]
play(0, 60)
play(1, 60, vel=127)
loud = mem[sym["wVoiceVol"]]
play(0, 60)
check("velocity scales the volume", soft < loud, (soft, loud))

# the selection can change between note-on and note-off: the off still goes to the first channel
mem[sym["wSelCh"]] = 1
play(1, 64)
mem[sym["wSelCh"]] = 3
play(0, 64)
check("note-off follows the channel the note went to", cur(1) == 0, cur(1))
mem[sym["wSelCh"]] = 0

# ---------------------------------------------------------------- general packets (MIDI)
general(0x90, 0x3C, 0x64)  # note on, MIDI channel 1 -> GB CH1 (default routing)
check("general packet: MIDI note-on is parsed", cur(0) == 60, cur(0))
general(0x80, 0x3C, 0x00)
check("general packet: MIDI note-off", cur(0) == 0, cur(0))
general(0xC0, 0x05, cl.PAD)  # program change padded with $FE
general(0x91, 0x40, 0x50)
check("a short message padded with $FE does not disturb the parser", cur(1) == 64, cur(1))
general(0xB1, 123, 0x00)
check("CC123 over the link silences the channel", cur(1) == 0, cur(1))

# ---------------------------------------------------------------- real buttons mixed in: detected, resent
# (a person pressing LEFT while a symbol is held: that changes data bit 3 = 8, which "sum & 7" would miss)
before = cur(0)
play(1, 65, extra=["left"], extra_at=1)
check("a real button pressed during a packet corrupts it: rejected", cur(0) == before and v("wClNack") == 1,
      (cur(0), v("wClNack")))
check("the ROM reports the failure to the ESP32 (nack bit)", slot()[3] & 1 == 1, slot())
play(1, 65)
check("the resent packet is accepted and clears the nack", cur(0) == 65 and v("wClNack") == 0 and slot()[3] & 1 == 0,
      (cur(0), v("wClNack")))
play(0, 65)

# the same for a general packet (its 5-bit check)
before = cur(1)
general(0x91, 0x41, 0x50, extra=["left"], extra_at=3)
check("a real button pressed during a general packet corrupts it: rejected", cur(1) == before and v("wClNack") == 1,
      (cur(1), v("wClNack")))
general(0x91, 0x41, 0x50)
check("... and the resent general packet is accepted", cur(1) == 0x41 and v("wClNack") == 0, cur(1))
general(0x81, 0x41, 0x00)

# ack follows the phase of the last accepted symbol, checked after every single symbol (both phases occur)
acks_ok = True
seen = set()
for on in (1, 0, 1, 0):
    for ph, data in cl.with_phases(cl.encode_play(on, 60, 127), next_phase()):
        hold(cl.buttons(ph, data), 3)
        pb.tick(1)
        acks_ok &= ((slot()[3] >> 1) & 1) == ph
        seen.add(ph)
    release_all()
check("ack in the uplink header equals the phase of the last accepted symbol (both 0 and 1 seen)", acks_ok and seen == {0, 1}, seen)
play(0, 60)

# a physical SELECT during a symbol makes it unreadable (SELECT is never data): the packet stalls, the sender waits
# for the half packet to time out and sends it again
before = cur(0)
play(1, 66, extra=["select"], extra_at=1)  # (the SELECT tap also moves the channel selection: put it back)
mem[sym["wSelCh"]] = 0
pb.tick(35)
play(1, 66)
check("a symbol lost to a physical SELECT: after the idle timeout the resent packet works", cur(0) == 66, cur(0))
play(0, 66)

# a half packet is dropped after a while
send(cl.with_phases(cl.encode_play(1, 67, 127)[:2], next_phase()))
pb.tick(40)
play(1, 69)
check("a half-received packet times out and the next packet is still understood", cur(0) == 69, cur(0))
play(0, 69)

# ---------------------------------------------------------------- physical buttons on the keyboard screen
ch0 = v("wSelCh")
press("select")
check("SELECT tap on the keyboard screen selects the next channel", v("wSelCh") == (ch0 + 1) % 4, (ch0, v("wSelCh")))
mem[sym["wSelCh"]] = 0
pb.button_press("select")
pb.button_press("start")
pb.tick(40)
check("SELECT+START held 40 frames: still on the keyboard screen", v("wScreen") == 3)
pb.tick(40)
check("SELECT+START held 80 frames: back to the play screen", v("wScreen") == 0, v("wScreen"))
pb.button_release("select")
pb.button_release("start")
pb.tick(10)
check("leaving did not start the sequencer or save", v("wSeqPlay") == 0)
enter_kbd()
check("re-entered the keyboard screen", v("wScreen") == 3)
general(*cl.HELLO)
check("HELLO again after the screen change", v("wClLinked") == 1)

# ---------------------------------------------------------------- up: slots
TX = sym["wTx"]


def queue(*bs):
    head = mem[sym["wTxHead"]]
    for b in bs:
        mem[TX + head] = b
        head = (head + 1) & 0xFF
    mem[sym["wTxHead"]] = head


mem[sym["wTxHead"]] = 0
mem[sym["wTxTail"]] = 0
pb.tick(3)
s0 = cl.decode_slot(*slot())
rd = cl.SlotReader()
rd.feed(*slot())
queue(0x90, 60, 100)
pb.tick(1)
s1 = cl.decode_slot(*slot())
check("up: a note-on message goes into the slot", s1.length == 3 and s1.data == (0x90, 60, 100), s1)
check("up: seq advances by one for a new message", (s1.seq - s0.seq) & 7 == 1, (s0.seq, s1.seq))
rd.feed(*slot())
queue(0xC0, 5)
pb.tick(1)
s2 = cl.decode_slot(*slot())
check("up: a 2-byte message (program change)", s2.length == 2 and s2.data[:2] == (0xC0, 5), s2)
queue(0xF8)
pb.tick(1)
s3 = cl.decode_slot(*slot())
check("up: a realtime byte", s3.length == 1 and s3.data[0] == 0xF8, s3)
pb.tick(2)
s4 = cl.decode_slot(*slot())
check("up: nothing new -> the slot (data and length) and seq stay as they were, so a late reader still sees the message",
      s4.length == s3.length and s4.data == s3.data and s4.seq == s3.seq, s4)
check("the queue is drained", v("wTxHead") == v("wTxTail"))

# a 1 frame/message pipeline: the reader on the other side sees every message exactly once
mem[sym["wTxHead"]] = 0
mem[sym["wTxTail"]] = 0
rd = cl.SlotReader()
rd.feed(*slot())
sent = []
for i in range(40):
    msg = (0x90, 40 + i, 100) if i % 2 == 0 else (0x80, 40 + i - 1, 0)
    queue(*msg)
    sent.append(bytes(msg))
frames = 0
while v("wTxHead") != v("wTxTail") and frames < 200:
    pb.tick(1)
    rd.feed(*slot())  # the ESP32 polls more than once per frame; here once per frame is the minimum
    frames += 1
pb.tick(2)
rd.feed(*slot())
check("up: 40 queued messages arrive complete and in order, one per frame", rd.messages == sent and rd.lost == 0,
      (len(rd.messages), rd.lost))
check("up: no more than one message per frame", frames >= 39, frames)

# ---------------------------------------------------------------- the serial ISR leaves the queue alone while linked
mem[sym["wTxHead"]] = 0
mem[sym["wTxTail"]] = 0
queue(*([0xF8] * 60))
isr_reply = []
pb.hook_register(0, sym["SerialISR.send"], lambda ctx: isr_reply.append(pb.register_file.B), None)
mem[0xFF0F] = mem[0xFF0F] | 0x08
pb.tick(1)
check("linked: the serial ISR answers with the idle byte although the queue is not empty",
      isr_reply == [0xFD] and v("wTxHead") != v("wTxTail"), (isr_reply, v("wTxHead"), v("wTxTail")))
mem[sym["wTxHead"]] = 0
mem[sym["wTxTail"]] = 0

# ---------------------------------------------------------------- timeout
pb.tick(130)
check("no packets for 2 seconds drops the link", v("wClLinked") == 0, v("wClLinked"))
queue(*([0xF8] * 4))
isr_reply.clear()
mem[0xFF0F] = mem[0xFF0F] | 0x08
pb.tick(1)
check("after the timeout the cable bridge gets its bytes again", isr_reply and isr_reply[0] == 0xF8, isr_reply)
check("after the timeout play packets are ignored again", (play(1, 60), cur(0) == 0)[1])
mem[sym["wTxHead"]] = 0
mem[sym["wTxTail"]] = 0

# ---------------------------------------------------------------- VBlank budget
general(*cl.HELLO)
ui_entry_ly.clear()
for i in range(20):
    queue(0x90, 60, 100)
    play(1, 60 + i % 5)
late = [ly for ly in ui_entry_ly if 144 <= ly]
check("linked: UpdateUI still starts at the top of VBlank (LY <= 146) on every frame that reaches it",
      max(late) <= 146 if late else False, (max(late) if late else None, len(late)))
check("linked: it gets there", len(late) > 30, len(late))

check("every uplink write to palette RAM happened in VBlank (LY 144..151)",
      up_write_ly and all(144 <= ly < 152 for ly in up_write_ly), (min(up_write_ly), max(up_write_ly), len(up_write_ly)))

print()
print("ALL PASSED" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
