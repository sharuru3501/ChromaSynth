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
print("\n".join(out))
