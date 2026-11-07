#!/usr/bin/env python3
"""MIDI input test using PyBoy (pip install pyboy pillow). Run `make` first.

The emulator has no link-port input, so MIDI bytes are pushed straight into the
serial RX ring buffer (what the serial ISR would have done). Covers: routing by
MIDI channel assignment, polyphony by assigning several GB channels to one MIDI
channel, velocity, mod wheel (CC1), all-notes-off (CC123/CC120) and the settings
page of the edit screen.
"""
import pathlib
import re
import shutil
import sys
import tempfile

from pyboy import PyBoy

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import bridge_c  # noqa: E402  (the same logic in C, as it runs on the ESP32)
import bridge_ref as br  # noqa: E402  (the bridge firmware's reference model)

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


tmp = tempfile.mkdtemp()
rom = pathlib.Path(tmp) / "t.gb"
shutil.copy(rom_src, rom)
pb = PyBoy(str(rom), window="null", sound_emulated=False)
mem = pb.memory
for _ in range(2000):
    pb.tick(1)
    if pb.register_file.PC >= 0x100:
        break
pb.tick(100)  # boot beep over


def v(name):
    return mem[sym[name]]


def cur(ch):
    return mem[sym["wCurNote"] + ch]


def vol(ch):
    return mem[sym["wVoiceVol"] + ch]


def midi(*bytes_):
    for b in bytes_:
        head = mem[sym["wRingHead"]]
        mem[sym["wRing"] + head] = b
        mem[sym["wRingHead"]] = (head + 1) & 0xFF
    pb.tick(3)


def press(btn, frames=4):
    pb.button_press(btn)
    pb.tick(frames)
    pb.button_release(btn)
    pb.tick(3)


def nav(d):
    """START+LEFT / START+RIGHT: previous / next screen."""
    pb.button_press("start")
    pb.tick(3)
    pb.button_press(d)
    pb.tick(3)
    pb.button_release(d)
    pb.tick(2)
    pb.button_release("start")
    pb.tick(4)


MB = sym["wPatch"] + 32  # MIDI settings block: 4 listen channels, bend, velocity, mod wheel


def reset_midi_block(vals=(1, 2, 3, 4, 2, 1, 1, 0)):
    for i, x in enumerate(vals):
        mem[MB + i] = x
    for c in range(4):
        mem[sym["wMod"] + c] = 0
        if cur(c):
            midi(0xB0 | c, 123, 0)
    pb.tick(3)


check("defaults: CH1-4 listen to MIDI 1-4, velocity on, mod wheel on",
      [mem[MB + i] for i in range(7)] == [1, 2, 3, 4, 2, 1, 1], [mem[MB + i] for i in range(7)])

# ---- the settings page on the edit screen (UI)
nav("right")                        # play -> edit
for _ in range(4):
    press("select")                 # CH1 -> ... -> CH4 -> MIDI page
check("edit screen: 5th page is the MIDI settings", (v("wScreen"), v("wSelCh")) == (1, 4), (v("wScreen"), v("wSelCh")))
press("down")
press("down")
check("row 2 (CH3) selected, row 4 hidden is skipped", v("wEditRow") == 2)
press("up")
press("left")
check("CH2 now listens to MIDI 1 (edited with LEFT)", mem[MB + 1] == 1, mem[MB + 1])
press("up")
for _ in range(20):
    press("right", frames=2)
check("MIDI channel value is clamped at 16", mem[MB] == 16, mem[MB])
for _ in range(20):
    press("left", frames=2)
check("...and at 0 (off)", mem[MB] == 0, mem[MB])
press("right")
check("back to MIDI 1", mem[MB] == 1)
press("down")
press("down")
press("down")
press("down")
check("row 4 is BEND (visible), then VELO and MODW", v("wEditRow") == 4, v("wEditRow"))
for _ in range(20):
    press("right", frames=2)
check("BEND range is clamped at 12 semitones", mem[MB + 4] == 12, mem[MB + 4])
for _ in range(20):
    press("left", frames=2)
mem[MB + 4] = 2
press("down")
press("down")
press("down")
check("row 7 is SYNC (the last row)", v("wEditRow") == 7, v("wEditRow"))
for _ in range(20):
    press("right", frames=2)
check("SYNC is clamped at 2 (0 = off, 1 = out, 2 = in)", mem[MB + 7] == 2, mem[MB + 7])
mem[MB + 7] = 0

# ---- polyphony: CH1 and CH2 both listen to MIDI channel 1
check("CH1 and CH2 both on MIDI 1", mem[MB] == 1 and mem[MB + 1] == 1)
midi(0x90, 60, 100)
check("note 1 -> CH1 (first idle channel)", (cur(0), cur(1)) == (60, 0), (cur(0), cur(1)))
midi(0x90, 64, 100)
check("note 2 -> CH2 (the other idle channel): a two-note chord", (cur(0), cur(1)) == (60, 64), (cur(0), cur(1)))
midi(0x90, 67, 100)
check("note 3: no idle channel -> steals CH2 (round robin starts after CH1)", (cur(0), cur(1)) == (60, 67), (cur(0), cur(1)))
midi(0x90, 69, 100)
check("note 4: steals CH1 next", (cur(0), cur(1)) == (69, 67), (cur(0), cur(1)))
midi(0x90, 67, 100)
check("re-striking a sounding note reuses its channel (no steal)", (cur(0), cur(1)) == (69, 67))
midi(0x80, 60, 0)
check("note off for a note nobody plays is ignored", (cur(0), cur(1)) == (69, 67))
midi(0x80, 69, 0)
check("note off releases only the channel that plays it", (cur(0), cur(1)) == (0, 67), (cur(0), cur(1)))
midi(0x90, 67, 0)
check("note on with velocity 0 releases the other voice", (cur(0), cur(1)) == (0, 0), (cur(0), cur(1)))

# ---- channels that are not listening / listening to something else
reset_midi_block()
midi(0x99, 60, 100)
check("MIDI channel 10 (nobody listens): ignored", [cur(c) for c in range(4)] == [0, 0, 0, 0])
mem[MB] = 0
midi(0x90, 60, 100)
check("a GB channel set to 0 (off) does not play", cur(0) == 0, cur(0))
mem[MB] = 5
midi(0x94, 60, 100)
check("a GB channel can listen to any MIDI channel (5)", cur(0) == 60, cur(0))
midi(0x80 | 4, 60, 0)
reset_midi_block()

# ---- velocity
midi(0x90, 60, 127)
check("velocity 127: full volume (15)", vol(0) == 15, vol(0))
midi(0x90, 60, 64)
check("velocity 64: about half (8)", vol(0) == 8, vol(0))
midi(0x90, 60, 1)
check("velocity 1: quiet but never silent (1)", vol(0) == 1, vol(0))
midi(0x93, 70, 64)
check("velocity also scales the noise channel (8)", vol(3) == 8, vol(3))
midi(0x92, 48, 127)
check("wave channel, loud: patch level kept (0)", vol(2) == 0, vol(2))
midi(0x92, 48, 70)
check("wave channel, medium velocity: one level quieter (1)", vol(2) == 1, vol(2))
midi(0x92, 48, 20)
check("wave channel, soft: two levels quieter (2)", vol(2) == 2, vol(2))
mem[MB + 5] = 0                     # velocity sensitivity off
midi(0x90, 60, 1)
check("velocity off: velocity is ignored (15)", vol(0) == 15, vol(0))
mem[MB + 5] = 1
reset_midi_block()
check("after a MIDI note the next pad/sequencer note is full velocity again", v("wNoteVel") == 127, v("wNoteVel"))

# ---- mod wheel (CC1) raises the vibrato depth of the channels on that MIDI channel
base_depth = mem[sym["wPatch"] + 6]
check("patch vibrato depth starts at 0", base_depth == 0, base_depth)
midi(0x90, 69, 100)                 # A4, period 1750
base = mem[sym["wBase"]] | (mem[sym["wBase"] + 1] << 8)
midi(0xB0, 1, 127)
check("CC1 127 -> vibrato depth 7 on CH1", mem[sym["wMod"]] == 7, mem[sym["wMod"]])
check("...and not on CH2 (other MIDI channel)", mem[sym["wMod"] + 1] == 0)
seen = []
for _ in range(60):
    pb.tick(1)
    seen.append(mem[sym["wOut"]] | (mem[sym["wOut"] + 1] << 8))
check("the mod wheel makes the pitch oscillate around the note", min(seen) < base < max(seen), (base, min(seen), max(seen)))
midi(0xB0, 1, 0)
check("CC1 0 -> depth back to 0", mem[sym["wMod"]] == 0)
before = mem[sym["wOut"]] | (mem[sym["wOut"] + 1] << 8)
pb.tick(30)
after = mem[sym["wOut"]] | (mem[sym["wOut"] + 1] << 8)
check("vibrato stops updating at depth 0", before == after)
mem[MB + 6] = 0                     # mod wheel disabled
midi(0xB0, 1, 127)
check("mod wheel disabled in the settings: CC1 ignored", mem[sym["wMod"]] == 0, mem[sym["wMod"]])
mem[MB + 6] = 1
midi(0x80, 69, 0)

# ---- pitch bend (MSB only; range = BEND semitones)
def out(ch=0):
    return mem[sym["wOut"] + 2 * ch] | (mem[sym["wOut"] + 2 * ch + 1] << 8)


def tick_ms(n=6):
    pb.tick(n)


reset_midi_block()
midi(0x90, 69, 100)                 # A4: period 1750
base = mem[sym["wBase"]] | (mem[sym["wBase"] + 1] << 8)
check("A4 base period", base == 1750, base)
check("bend wheel starts in the middle", mem[sym["wBend"]] == 64)
midi(0xE0, 0, 127)                  # full up, +-2 semitones: +2 semitones = period ~1783
tick_ms()
check("bend up by 2 semitones: period +33 (exact value 32.6)", 1780 <= out() <= 1786, out())
midi(0xE0, 0, 0)                    # full down
tick_ms()
check("bend down by 2 semitones: period -36 (exact value -36.4)", 1710 <= out() <= 1717, out())
midi(0xE0, 0, 96)                   # half way up: +1 semitone
tick_ms()
check("half way up: +1 semitone (exact +16.7)", 1764 <= out() <= 1769, out())
midi(0xE0, 0, 64)                   # back to centre
tick_ms()
check("wheel back in the middle: the plain period is restored", out() == base, out())
frozen = out()
tick_ms(30)
check("...and nothing keeps rewriting it", out() == frozen)
midi(0xE1, 0, 127)                  # other MIDI channel
tick_ms()
check("bend on another MIDI channel does not touch CH1", out() == base and mem[sym["wBend"]] == 64)
mem[MB + 4] = 0                     # range 0: bend disabled
midi(0xE0, 0, 127)
tick_ms()
check("range 0 disables the bend", out() == base, out())
mem[MB + 4] = 12                    # +-12 semitones: clamped inside the register range
tick_ms()
check("range 12, full up: exactly an octave (A4 -> A5, period +149)", 1895 <= out() <= 1903, out())
midi(0xE0, 0, 0)
tick_ms()
check("range 12, full down: exactly an octave (A4 -> A3, period -298)", 1448 <= out() <= 1458, out())
mem[MB + 4] = 2
midi(0xE0, 0, 127)                  # hold the bend up, then play a new note
midi(0x80, 69, 0)
midi(0x90, 60, 100)                 # C4
tick_ms()
base_c4 = mem[sym["wBase"]] | (mem[sym["wBase"] + 1] << 8)
bent = out()
check("a new note starts already bent (about +2 semitones)", base_c4 + 20 < bent < base_c4 + 60, (base_c4, bent))
# bend and vibrato together: the pitch oscillates around the bent centre
midi(0xB0, 1, 127)
seen = []
for _ in range(60):
    pb.tick(1)
    seen.append(out())
check("vibrato and bend add up: oscillation around the bent pitch", min(seen) < bent < max(seen) and min(seen) > base_c4, (base_c4, bent, min(seen), max(seen)))
midi(0xB0, 1, 0)
midi(0xE0, 0, 64)
midi(0x80, 60, 0)
reset_midi_block()

# ---- all notes off
mem[MB + 1] = 1
midi(0x90, 60, 100)
midi(0x90, 64, 100)
midi(0x92, 48, 100)                 # CH3 on MIDI channel 3
check("two voices on MIDI 1 and one on MIDI 3", (cur(0), cur(1), cur(2)) == (60, 64, 48), (cur(0), cur(1), cur(2)))
midi(0xB0, 123, 0)
check("CC123 on MIDI 1: releases CH1 and CH2 only", (cur(0), cur(1), cur(2)) == (0, 0, 48), (cur(0), cur(1), cur(2)))
midi(0xB2, 120, 0)
check("CC120 on MIDI 3: releases CH3", cur(2) == 0)
midi(0x90, 60, 100)
midi(0xB4, 123, 0)
check("all-notes-off on another MIDI channel does nothing", cur(0) == 60 or cur(1) == 60, (cur(0), cur(1)))
midi(0xB0, 123, 0)

# ---- other messages must not disturb the parser
midi(0xB0, 7, 100)                  # CC7: ignored
midi(0xE0, 0, 64)                   # pitch bend (not handled yet): ignored cleanly
midi(0xC0, 5)                       # program change: one data byte
midi(0x90, 62, 100)
check("unhandled messages are skipped without upsetting running status", cur(0) == 62 or cur(1) == 62, (cur(0), cur(1)))

# =====================================================================
# Link protocol and DAW sync (docs/BRIDGE.md)
# =====================================================================
TX = sym["wTx"]
SYNC = MB + 7
IDLE = 0xFD


isr_reply = []
isr_input = [None]
# PyBoy cannot feed the serial unit (SB always reads back as $FF), so both sides of the ISR are
# handled with hooks:
#  - right after the ISR's "ldh a, [rSB]" (SerialISR + 5: push af/bc/hl are 3 bytes, ldh is 2)
#    register A is overwritten with the byte the bridge "clocked in";
#  - at ".send" register B holds the byte the ISR is about to load into SB: that is the reply.


def _inject(ctx):
    if isr_input[0] is not None:
        pb.register_file.A = isr_input[0]


pb.hook_register(0, sym["SerialISR"] + 5, _inject, None)
pb.hook_register(0, sym["SerialISR.send"], lambda ctx: isr_reply.append(pb.register_file.B), None)


def serial_byte(b, frames=2):
    """What the hardware does when the bridge clocks one byte through the GB: SB holds the
    byte, the serial interrupt fires, the ISR loads the reply for the next transfer.
    Returns that reply."""
    isr_reply.clear()
    isr_input[0] = b
    mem[0xFF0F] = mem[0xFF0F] | 0x08
    pb.tick(frames)
    isr_input[0] = None
    assert len(isr_reply) == 1, f"serial ISR ran {len(isr_reply)} times"
    return isr_reply[0]


def tx_bytes():
    return [mem[TX + i] for i in range(mem[sym["wTxHead"]])]


def reset_tx():
    mem[sym["wTxHead"]] = 0
    mem[sym["wTxTail"]] = 0


reset_midi_block()
reset_tx()

# ---- the serial ISR: idle filler in, queue out
head = v("wRingHead")
last_rx = v("wLastRx")
check("ISR: an idle byte is answered with idle", serial_byte(IDLE) == IDLE)
check("...and is not stored (ring and RX display untouched)", v("wRingHead") == head and v("wLastRx") == last_rx)
mem[TX + 0], mem[TX + 1], mem[TX + 2] = 0x90, 60, 100
mem[sym["wTxHead"]] = 3
check("ISR: with bytes queued the reply is the next byte, in order",
      [serial_byte(IDLE), serial_byte(IDLE), serial_byte(IDLE), serial_byte(IDLE)] == [0x90, 60, 100, IDLE])
check("ISR: the queue is empty again (tail caught up with head)", v("wTxHead") == v("wTxTail"))
for b in (0x90, 62, 100):           # a note-on arriving byte by byte through the ISR
    serial_byte(b)
pb.tick(3)
check("a MIDI message clocked in through the serial ISR plays", cur(0) == 62, cur(0))
check("...and the ring holds exactly what arrived", v("wRingHead") == (head + 3) & 0xFF, v("wRingHead"))
midi(0xB0, 123, 0)

# ---- SYNC_IN: the DAW's clock drives the sequencer (one $F8 per tick, 12 per beat)
mem[SYNC] = 2
midi(0xFA)
check("SYNC_IN: MIDI start begins playback from tick 0", (v("wSeqPlay"), v("wSeqTick")) == (1, 0), (v("wSeqPlay"), v("wSeqTick")))
pb.tick(30)
check("no clock, no progress: the sequencer waits for the DAW", v("wSeqTick") == 0 and cur(0) == 0, (v("wSeqTick"), cur(0)))
midi(0xF8)
pb.tick(2)
check("first clock plays tick 0 (demo: CH1 C4, CH3 C3)", (v("wSeqCur"), cur(0), cur(2)) == (0, 60, 48), (v("wSeqCur"), cur(0), cur(2)))
for _ in range(12):
    midi(0xF8)
    pb.tick(1)
check("12 clocks = one beat = 12 ticks", v("wSeqCur") == 12, v("wSeqCur"))
check("tick 12 is where the demo plays E4 on CH1", cur(0) == 64, cur(0))
for _ in range(12):
    midi(0xF8)
    pb.tick(1)
check("tick 24 plays the bass G2 (43)", (v("wSeqCur"), cur(2)) == (24, 43), (v("wSeqCur"), cur(2)))
midi(0xF8, 0xF8, 0xF8, 0xF8)
pb.tick(2)
check("a burst of 4 clocks is played within one frame", v("wSeqCur") == 28, v("wSeqCur"))
midi(0xF8, 0xF8, 0xF8, 0xF8, 0xF8, 0xF8, 0xF8, 0xF8)
pb.tick(3)
check("a burst larger than 4 is limited (the rest is dropped, nothing hangs)", 31 <= v("wSeqCur") <= 32, v("wSeqCur"))
before = v("wSeqCur")
midi(0x90, 62, 100, 0xF8, 100)      # a clock byte in the middle of a message
pb.tick(2)
check("a realtime byte inside a message does not break it (note-on still plays)", 62 in (cur(0), cur(1)), (cur(0), cur(1)))
check("...and the clock inside it was counted", v("wSeqCur") == before + 1, (before, v("wSeqCur")))
midi(0xFC)
check("MIDI stop: playback stops and every channel is silent", v("wSeqPlay") == 0 and [cur(c) for c in range(4)] == [0, 0, 0, 0],
      (v("wSeqPlay"), [cur(c) for c in range(4)]))
stopped_at = v("wSeqTick")
midi(0xF8, 0xF8)
pb.tick(3)
check("clocks while stopped are ignored", v("wSeqTick") == stopped_at and v("wSeqCur") == before + 1)
midi(0xFB)
check("MIDI continue resumes from where it stopped", (v("wSeqPlay"), v("wSeqTick")) == (1, stopped_at), (v("wSeqPlay"), v("wSeqTick")))
midi(0xFA)
check("MIDI start rewinds to tick 0", v("wSeqTick") == 0)
midi(0xFC)
# local start/stop is ignored while following the DAW
pb.button_press("select")
pb.tick(3)
pb.button_press("start")
pb.tick(3)
pb.button_release("start")
pb.button_release("select")
pb.tick(4)
check("SYNC_IN: SELECT+START on the unit does nothing (the DAW is the master)", v("wSeqPlay") == 0, v("wSeqPlay"))
mem[SYNC] = 0
midi(0xFA)
check("SYNC off: realtime messages are ignored", v("wSeqPlay") == 0)
mem[SYNC] = 1
midi(0xFA)
check("SYNC out: incoming start is ignored too", v("wSeqPlay") == 0)

# ---- SYNC_OUT: this unit is the master and sends clock, start/stop and the sequencer's notes
reset_tx()
mem[SYNC] = 1
mem[sym["wBpm"]] = 120
pb.button_press("select")
pb.tick(3)
pb.button_press("start")
pb.tick(3)
pb.button_release("start")
pb.button_release("select")
pb.tick(2)
check("SYNC_OUT: SELECT+START plays and queues MIDI start ($FA) first", v("wSeqPlay") == 1 and tx_bytes()[:1] == [0xFA], tx_bytes()[:4])
pb.tick(120)                        # 2 seconds at 120 BPM = 48 ticks = 4 beats
out = tx_bytes()
clocks = out.count(0xF8)
check("one $F8 per tick: about 48 clocks in 2 s at 120 BPM (12 per beat)", 45 <= clocks <= 50, clocks)
check("the first tick sends C4 on MIDI channel 1 as note-on, velocity 100", [0xF8, 0x90, 60, 100] == out[1:5], out[:8])
check("the bass (CH3 -> MIDI channel 3) goes out too: note-on 48 on $92", [0x92, 48, 100] in [out[i:i + 3] for i in range(len(out) - 2)])
check("a note that ends is sent as note-off ($80, note, 0)", [0x80, 60, 0] in [out[i:i + 3] for i in range(len(out) - 2)])
check("the queue never overflows or stalls playback", len(out) < 255 and v("wSeqPlay") == 1, len(out))
pb.tick(300)                        # nobody drains the queue: it fills up and drops bytes quietly
check("a full queue drops bytes quietly and the sequencer keeps running", v("wSeqPlay") == 1 and mem[sym["wTxHead"]] != mem[sym["wTxTail"]])
tail = v("wTxTail")
pb.button_press("select")
pb.tick(3)
pb.button_press("start")
pb.tick(3)
pb.button_release("start")
pb.button_release("select")
pb.tick(3)
check("SELECT+START again stops it", v("wSeqPlay") == 0)
reset_tx()
mem[SYNC] = 1
pb.button_press("select")
pb.tick(3)
pb.button_press("start")
pb.tick(3)
pb.button_release("start")
pb.button_release("select")
pb.tick(60)
playing = tx_bytes()
pb.button_press("select")
pb.tick(3)
pb.button_press("start")
pb.tick(3)
pb.button_release("start")
pb.button_release("select")
pb.tick(3)
out = tx_bytes()
check("stop: MIDI stop ($FC) goes out, preceded by note-offs for the notes still sounding", out[-1] == 0xFC and 0x80 in out[len(playing):], out[len(playing):])
reset_tx()
mem[SYNC] = 0
pb.button_press("select")
pb.tick(3)
pb.button_press("start")
pb.tick(3)
pb.button_release("start")
pb.button_release("select")
pb.tick(60)
check("SYNC off: nothing is queued for the bridge", tx_bytes() == [], tx_bytes()[:6])
pb.button_press("select")
pb.tick(3)
pb.button_press("start")
pb.tick(3)
pb.button_release("start")
pb.button_release("select")
pb.tick(3)

# =====================================================================
# End to end with the bridge reference model (tools/bridge_ref.py)
# host MIDI -> Bridge -> serial ISR -> ROM, and ROM TX queue -> ISR reply -> Bridge -> host MIDI
# =====================================================================
def end_to_end(label, make):
    bridge = make()
    reset_midi_block()
    reset_tx()
    mem[SYNC] = 2


    def to_rom(host_bytes):
        bridge.host_in(bytes(host_bytes))
        sent = bridge.take_to_gb()
        for b in sent:
            serial_byte(b)
        pb.tick(3)
        return sent


    sent = to_rom([br.START] + [br.CLOCK] * 24)
    check(f"[{label}] bridge: MIDI start + 24 host clocks (one beat) reach the GB as start + 12 ticks",
          sent[0] == br.START and sent.count(br.CLOCK) == 12 and len(sent) == 13, sent[:6])
    check(f"[{label}] ROM: it played 12 ticks (0..11)", (v("wSeqPlay"), v("wSeqCur")) == (1, 11), (v("wSeqPlay"), v("wSeqCur")))
    sent = to_rom([0x90, 60, 100])
    check(f"[{label}] bridge -> ROM: a note-on plays", sent == [0x90, 60, 100] and cur(0) == 60, (sent, cur(0)))
    before = [v("wSeqCur"), v("wBend"), v("wMod")]
    sent = to_rom([0xF0, 0x7E, 0x00, 0x09, 0x01, 0xF7, 0xA0, 60, 50, 0xD0, 40, 0xC0, 2, 0xB0, 7, 100, 0xFE])
    check(f"[{label}] bridge: sysex, aftertouch, program change, CC7 and active sensing never reach the GB", sent == [], sent)
    sent = to_rom([0xE0, 0, 127, 0xB0, 1, 127])
    check(f"[{label}] bridge -> ROM: pitch bend and CC1 arrive", sent == [0xE0, 0, 127, 0xB0, 1, 127] and v("wBend") == 127 and v("wMod") == 7, (sent, v("wBend"), v("wMod")))
    sent = to_rom([0xE0, 0, 64, 0xB0, 1, 0, 0xB0, 123, 0, br.STOP])
    check(f"[{label}] bridge -> ROM: stop silences and halts", v("wSeqPlay") == 0 and cur(0) == 0 and v("wBend") == 64, (v("wSeqPlay"), cur(0), v("wBend")))

    # ROM -> host: the unit is the master (SYNC_OUT); drain the TX queue the way the bridge does
    bridge = make()
    reset_midi_block()
    reset_tx()
    mem[SYNC] = 1
    mem[sym["wBpm"]] = 60               # 12 ticks per second keeps the 1 byte/frame drain of this test ahead of the production
    pb.button_press("select")
    pb.tick(3)
    pb.button_press("start")
    pb.tick(3)
    pb.button_release("start")
    pb.button_release("select")
    FPS = 59.7275
    host = []
    for i in range(240):                # the firmware drains the host-bound queue every millisecond
        reply = serial_byte(br.IDLE, frames=1)
        t_us = int(i / FPS * 1_000_000)
        bridge.gb_in(reply, t_us)
        host.extend(bridge.host_out_due(t_us))
    host.extend(bridge.host_out_due(10**9))
    check(f"[{label}] ROM -> bridge -> host: starts with MIDI start", host[:1] == [br.START], host[:4])
    ticks_played = v("wSeqCur") + 1
    clocks = host.count(br.CLOCK)
    check(f"[{label}] ROM -> host: two MIDI clocks per tick (24 per beat) after the first interval", 2 * (ticks_played - 8) <= clocks <= 2 * ticks_played + 2, (ticks_played, clocks))
    triples = [host[i:i + 3] for i in range(len(host) - 2)]
    check(f"[{label}] ROM -> host: the sequencer's notes arrive as complete messages", [0x90, 60, 100] in triples and [0x92, 48, 100] in triples)
    pb.button_press("select")
    pb.tick(3)
    pb.button_press("start")
    pb.tick(3)
    pb.button_release("start")
    pb.button_release("select")
    pb.tick(3)
    tail = []
    for i in range(40):
        tail.append(serial_byte(br.IDLE, frames=1))
    check(f"[{label}] ROM -> bridge: the stop and its note-offs are flushed after the notes", br.STOP in tail, [hex(x) for x in tail if x != br.IDLE])
    mem[SYNC] = 0


end_to_end("python model", br.Bridge)
if bridge_c.available():
    end_to_end("C core", bridge_c.CBridge)
else:
    print("SKIP C core end-to-end (run `make -C firmware/test lib` first)")

pb.stop(save=False)
print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
