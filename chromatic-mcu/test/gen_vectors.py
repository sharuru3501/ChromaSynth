#!/usr/bin/env python3
"""Writes the reference vectors the C core must reproduce (from tools/chromatic_link_ref.py)."""
import pathlib, sys
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent.parent / "tools"))
import chromatic_link_ref as cl

out = []
for on in (0, 1):
    for note in range(0, 128):
        for vel in (0, 1, 15, 16, 64, 100, 127):
            s = cl.encode_play(on, note, vel)
            out.append("play %d %d %d %s" % (on, note, vel, " ".join(map(str, s))))
for b0, b1, b2 in [(0x90, 60, 100), (0x80, 60, 0), (0xB1, 123, 0), (0xC0, 5, cl.PAD), (0xF8, cl.PAD, cl.PAD), cl.HELLO,
                   (0xFF, 0xFF, 0xFF), (0, 0, 0), (0xAA, 0x55, 0xA5)]:
    s = cl.encode_general(b0, b1, b2)
    out.append("gen %d %d %d %s" % (b0, b1, b2, " ".join(map(str, s))))
for phase in (0, 1):
    for data in range(16):
        out.append("mask %d %d %d" % (phase, data, cl.mask(phase, data)))
for h in range(0, 128, 3):
    for b0, b1, b2 in [(0x90, 60, 100), (0, 0, 0), (255, 127, 255)]:
        # gpd order: [0] = header (obpd13), [1] = B2, [2] = B1, [3] = B0, then the BG bytes
        g = [h, b2, b1, b0, 0x62, 0x0C, 0x7B, 0x79]
        s = cl.decode_slot(b0, b1, b2, h)
        out.append("slot %s %d %d %d %d %d %d %d" % (" ".join(map(str, g)), s.length, s.seq, s.ack, s.nack, *s.data))

# release / ping, and the ack check
for ping in (0, 1):
    s = cl.encode_release(bool(ping))
    out.append("rel %d %d %d" % (ping, s[0], s[1]))
for nack in (0, 1):
    for ack in (0, 1):
        for last in (0, 1):
            sl = cl.Slot(length=0, seq=0, ack=ack, nack=nack, data=(0, 0, 0))
            out.append("ack %d %d %d %d" % (nack, ack, last, 1 if cl.verify_ack(sl, last) else 0))
# beacons
for ln in (0, 1, 2, 3):
    for b0 in (0x00, 0x90, 0xF4, 0xF5, 0xFE):
        h = ln << 5
        sl = cl.decode_slot(b0, 0, 0, h)
        out.append("cls %d %d %s" % (ln, b0, {"kbd": 1, "left": 2, "other": 0}[cl.classify(sl)]))
# BLE MIDI packets: "ble <n> <bytes> <m> <messages as st d1 d2>"
def ble(pkt, exp):
    out.append("ble %d %s %d %s" % (len(pkt), " ".join(map(str, pkt)), len(exp), " ".join("%d %d %d" % m for m in exp)))
cases = [
    [(0x90, 60, 100)],
    [(0x80, 60, 0)],
    [(0x90, 60, 100), (0x90, 64, 90), (0x80, 60, 0)],
    [(0xC0, 5, None)],
    [(0xB0, 123, 0), (0xE0, 0, 64)],
    [(0x90, 36, 127), (0x90, 107, 1)],
]
for msgs in cases:
    for running in (False, True):
        for ts in (0, 0x1234, 0x1FFF):
            pkt, exp = cl.ble_packet(msgs, ts=ts, running=running)
            ble(pkt, exp)
pkt, exp = cl.ble_packet([(0x90, 60, 100), (0x90, 62, 100)], sysex_between=True)
ble(pkt, exp)
# hand-written edge cases (expected lists written by hand, not by the packet builder)
ble(bytes([0x81, 0x85, 0x90, 60, 100]), [(0x90, 60, 100)])                       # single note-on
ble(bytes([0x81, 0x85, 0x90, 60, 100, 0x86, 61, 100]), [(0x90, 60, 100), (0x90, 61, 100)])   # running status after a timestamp
ble(bytes([0x81, 0x85, 0x90, 60, 100, 61, 100]), [(0x90, 60, 100), (0x90, 61, 100)])         # running status with no timestamp
ble(bytes([0x81, 0x85, 0x90, 60]), [])                                           # truncated: nothing
ble(bytes([0x81]), [])                                                           # header only
ble(bytes([0x00, 0x85, 0x90, 60, 100]), [])                                      # no header bit 7: rejected
ble(bytes([0x81, 0x85, 0xF0, 1, 2, 3, 0x86, 0xF7, 0x87, 0x90, 60, 100]), [(0x90, 60, 100)])  # SysEx skipped
ble(bytes([0x81, 0x85, 0xFE]), [(0xFE, 0, 0)])                                    # a realtime byte (active sensing)
ble(bytes([0x81, 0x85, 0xC1, 7, 0x86, 0xD0, 20]), [(0xC1, 7, 0), (0xD0, 20, 0)]) # one-data-byte messages
# actions: "act st d1 d2 action note vel" (action: 0 ignore, 1 on, 2 off, 3 all off)
for st, d1, d2, a, note, vel in [(0x90, 60, 100, 1, 60, 100), (0x93, 72, 1, 1, 72, 1), (0x90, 60, 0, 2, 60, 0), (0x80, 60, 64, 2, 60, 0),
                                (0x8F, 36, 0, 2, 36, 0), (0xB0, 123, 0, 3, 0, 0), (0xB5, 120, 0, 3, 0, 0), (0xB0, 7, 100, 0, 0, 0),
                                (0xE0, 0, 64, 0, 0, 0), (0xC0, 5, 0, 0, 0, 0), (0xF8, 0, 0, 0, 0, 0)]:
    out.append("act %d %d %d %d %d %d" % (st, d1, d2, a, note, vel))
# coalescing: "coal n k a b c ... m k a b c ..." (input then expected)
def coal(inp, exp):
    out.append("coal %d %s %d %s" % (len(inp), " ".join("%d %d %d %d" % c for c in inp), len(exp), " ".join("%d %d %d %d" % c for c in exp)))
P0, P1 = 0, 0
coal([(0, 1, 60, 100), (0, 0, 60, 0)], [(0, 1, 60, 100), (0, 0, 60, 0)])                   # on then off: keep both
coal([(0, 0, 60, 0), (0, 1, 62, 100)], [(0, 1, 62, 100)])                                  # off then on: the off is pointless
coal([(0, 1, 60, 100), (0, 0, 60, 0), (0, 1, 62, 100), (0, 0, 62, 0)], [(0, 1, 60, 100), (0, 1, 62, 100), (0, 0, 62, 0)])
coal([(2, 0, 0, 0), (0, 0, 60, 0), (0, 1, 64, 100)], [(2, 0, 0, 0), (0, 1, 64, 100)])      # other kinds untouched
coal([(1, 0xB0, 123, 0), (0, 0, 60, 0)], [(1, 0xB0, 123, 0), (0, 0, 60, 0)])               # a general packet is not a note-on
coal([], [])
print("\n".join(out))
