"""Reference model of the MCU side of the cable-less Chromatic link (docs/CHROMATIC_LINK.md).

Pure functions, standard library only. The ESP32 code must do the same arithmetic.

  down:  encode_play / encode_general -> list of (phase, data5) symbols
         buttons(symbol)              -> the virtual buttons to hold for one symbol
  up:    decode_slot(4 bytes)         -> Slot(len, seq, ack, nack, bytes)
"""
from collections import namedtuple

HELLO = (0xFE, 0x43, 0x53)
PAD = 0xFE  # pads MIDI messages shorter than 3 bytes (Active Sensing: ignored by the ROM's parser)


def _check(nibbles):
    """Sum mod 15 (not & 15): each single changed bit (1, 2, 4, 8) must change it."""
    return sum(nibbles) % 15


def encode_play(on, note, vel127):
    """Mono keyboard note on the ROM's selected channel: 4 symbols of 4 bits (phase added later).
    s0 = type 0 | on | note 6..5, s1 = note 4..1, s2 = note 0 | vel(3), s3 = check."""
    vel = max(0, min(7, vel127 >> 4))
    s0 = (1 if on else 0) << 2 | (note >> 5) & 3
    s1 = (note >> 1) & 15
    s2 = (note & 1) << 3 | vel
    return [s0, s1, s2, _check([s0, s1, s2])]


def encode_release(ping=False):
    """2 symbols, type %10: (8 | x, 7 xor x). x = 0 releases the note of the last note-on, x = 1 only pings (keeps the link
    up). The pair is its own check: any single changed bit gives an invalid pair. Neither can start a note."""
    x = 1 if ping else 0
    return [8 | x, 7 ^ x]


def verify_ack(slot, last_phase):
    """After a packet (read once the ROM has had 2+ frames): did the ROM accept the last symbol (its ack = the phase of the last
    accepted symbol) and is nothing wrong (nack = the last packet failed its check, or a half packet is pending)?"""
    return slot.nack == 0 and slot.ack == last_phase


def encode_general(b0, b1, b2):
    """3 MIDI bytes: 8 symbols. s0 = type 1 | b0 7..5; the 24 bits run through s0..s6, s6's low 3 bits are 0,
    s7 = check."""
    s0 = 8 | b0 >> 5
    s1 = (b0 >> 1) & 15
    s2 = (b0 & 1) << 3 | b1 >> 5
    s3 = (b1 >> 1) & 15
    s4 = (b1 & 1) << 3 | b2 >> 5
    s5 = (b2 >> 1) & 15
    s6 = (b2 & 1) << 3
    body = [s0 & 7, s1, s2, s3, s4, s5, s6]
    return [s0, s1, s2, s3, s4, s5, s6, _check(body)]


def with_phases(symbols, first_phase):
    """[(phase, data4)]: phases alternate A(0)/B(1) across ALL symbols, starting at first_phase."""
    return [((first_phase + i) & 1, s) for i, s in enumerate(symbols)]


def buttons(phase, data):
    """Virtual buttons for one symbol (the ROM must be on its keyboard screen).
    Phase A = UP held, phase B = DOWN held. The FPGA cancels UP+DOWN and LEFT+RIGHT, so a symbol never
    has an opposite pair. data bits: 0 A, 1 B, 2 START, 3 LEFT. SELECT and RIGHT are never pressed:
    SELECT belongs to the person (channel select; SELECT+START = sequencer play/stop). A frame without UP/DOWN is
    the person's: START+LEFT there leaves the screen (the ESP32 never presses LEFT without UP/DOWN)."""
    held = {"up" if phase == 0 else "down"}
    for bit, name in ((0, "a"), (1, "b"), (2, "start"), (3, "left")):
        if data & (1 << bit):
            held.add(name)
    return held


FPGA_BITS = {"start": 1, "select": 2, "b": 4, "a": 8, "up": 16, "right": 32, "left": 64, "down": 128}


def mask(phase, data):
    """The value the MCU writes to the FPGA's MCU_buttons register for one symbol."""
    m = 0
    for name in buttons(phase, data):
        m |= FPGA_BITS[name]
    return m


BEACON_KBD = 0xF4   # ROM on the keyboard screen, not linked: the slot is {B0 = $F4, len 3}
BEACON_LEFT = 0xF5  # ROM left the keyboard screen (written once)


def classify(slot):
    """'kbd' / 'left' / 'other' for a decoded slot (what the MCU may do: send only on 'kbd' or a linked slot)."""
    if slot.length == 3 and slot.data[0] == BEACON_KBD:
        return "kbd"
    if slot.length == 3 and slot.data[0] == BEACON_LEFT:
        return "left"
    return "other"


def ble_packet(messages, ts=0x1234, running=False, sysex_between=False):
    """A BLE MIDI packet: header (bit 7 set, timestamp bits 12..7), then [timestamp low][message]...
    messages = [(status, d1, d2 or None)]. running=True drops the status byte of a message that repeats the
    previous status (the timestamp byte stays). Returns (bytes, expected_messages)."""
    out = [0x80 | ((ts >> 7) & 0x3F)]
    last = None
    for i, (st, d1, d2) in enumerate(messages):
        out.append(0x80 | ((ts + i) & 0x7F))
        if not (running and st == last and st < 0xF0):
            out.append(st)
        out.append(d1)
        if d2 is not None:
            out.append(d2)
        last = st
        if sysex_between and i == 0:
            out += [0x80 | 5, 0xF0, 0x7E, 0x00, 0x80 | 6, 0xF7]
    exp = [(st, d1, d2 or 0) for st, d1, d2 in messages]
    return bytes(out), exp


Slot = namedtuple("Slot", "length seq ack nack data")


def decode_slot(b0, b1, b2, b3):
    return Slot(length=(b3 >> 5) & 3, seq=(b3 >> 2) & 7, ack=(b3 >> 1) & 1, nack=b3 & 1, data=(b0, b1, b2))


class SlotReader:
    """What the ESP32 does with the 8 bytes it gets back from each 0xD request."""

    def __init__(self):
        self.seq = None
        self.lost = 0
        self.messages = []

    def feed(self, b0, b1, b2, b3):
        s = decode_slot(b0, b1, b2, b3)
        if self.seq is None:
            self.seq = s.seq
            return s
        step = (s.seq - self.seq) & 7
        if step:
            if step > 1:
                self.lost += step - 1
            if s.length:
                self.messages.append(bytes(s.data[: s.length]))
            self.seq = s.seq
        return s
