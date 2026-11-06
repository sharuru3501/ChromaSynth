"""Reference model of the MCU side of the cable-less Chromatic link (docs/CHROMATIC_LINK.md).

Pure functions, standard library only. The ESP32 code must do the same arithmetic.

  down:  encode_play / encode_general -> list of (phase, data5) symbols
         buttons(symbol)              -> the virtual buttons to hold for one symbol
  up:    decode_slot(4 bytes)         -> Slot(len, seq, ack, nack, bytes)
"""
from collections import namedtuple

HELLO = (0xFE, 0x43, 0x53)
PAD = 0xFE  # pads MIDI messages shorter than 3 bytes (Active Sensing: ignored by the ROM's parser)


def _check_play(s0, s1, vel_lo):
    return (s0 + s1 + vel_lo) & 7


def encode_play(on, note, vel127):
    """Mono keyboard note on the ROM's selected channel: 3 symbols (data bits only, phase added later)."""
    vel = max(0, min(7, vel127 >> 4))
    s0 = (1 if on else 0) << 3 | (note >> 4) & 7  # bit 4 (type) = 0
    s1 = (note & 15) << 1 | (vel >> 2) & 1
    s2 = (vel & 3) << 3 | _check_play(s0, s1, vel & 3)
    return [s0, s1, s2]


def encode_general(b0, b1, b2):
    """3 MIDI bytes: 6 symbols. Bit 4 of the first symbol marks a general packet."""
    s0 = 0x10 | (b0 >> 4)
    s1 = (b0 & 15) << 1 | (b1 >> 7)
    s2 = (b1 >> 2) & 31
    s3 = (b1 & 3) << 3 | (b2 >> 5)
    s4 = b2 & 31
    s5 = ((s0 & 15) + s1 + s2 + s3 + s4) & 31
    return [s0, s1, s2, s3, s4, s5]


def with_phases(symbols, first_phase):
    """[(phase, data5)]: phases alternate A(0)/B(1) across ALL symbols, starting at first_phase."""
    return [((first_phase + i) & 1, s) for i, s in enumerate(symbols)]


def buttons(phase, data):
    """Virtual buttons for one symbol. data bits: 4 = LEFT (phase A) / UP (phase B), 3..0 = START SELECT B A."""
    held = set()
    if phase == 0:
        held |= {"up", "down"}
        held.add("left" if data & 16 else "right")
    else:
        held |= {"left", "right"}
        held.add("up" if data & 16 else "down")
    for bit, name in ((0, "a"), (1, "b"), (2, "select"), (3, "start")):
        if data & (1 << bit):
            held.add(name)
    return held


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
