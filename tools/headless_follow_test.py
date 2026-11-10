#!/usr/bin/env python3
"""SYNC = 3 (FOLLOW) test using PyBoy. Run `make` first.

The DAW follows over the slow cable-less link: start / stop ($FA / $FB / $FC), the tempo (CC14 = BPM - 60 mod 128, CC15 = (BPM - 60) / 128),
program change = the pattern, timbre CCs (CC20 main / CC21 volume / CC10 pan, scaled to each GB channel's range).
"""
import pathlib, re, shutil, tempfile
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


with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = PyBoy(str(rom), window="null", sound_emulated=False)
    for _ in range(2000):
        pb.tick(1)
        if pb.register_file.PC >= 0x100:
            break
    pb.tick(100)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    PATCH = sym["wPatch"]
    MB = PATCH + 4 * 32          # the MIDI block
    SYNC = MB + 7

    def midi(*b):
        for x in b:
            head = mem[sym["wRingHead"]]
            mem[sym["wRing"] + head] = x
            mem[sym["wRingHead"]] = (head + 1) & 0xFF
        pb.tick(4)

    # --- not in FOLLOW mode nothing of this does anything
    mem[SYNC] = 0
    midi(0xFA)
    check("SYNC 0: MIDI start does nothing", v("wSeqPlay") == 0)
    midi(0xC0, 1)
    check("SYNC 0: program change does nothing", v("wEditPat") == 0)
    bpm0 = v("wBpm")
    midi(0xB0, 14, 10, 0xB0, 15, 0)
    check("SYNC 0: the tempo CCs do nothing", v("wBpm") == bpm0, v("wBpm"))

    # --- FOLLOW
    mem[SYNC] = 3
    midi(0xFA)
    check("FOLLOW: MIDI start starts the sequencer", v("wSeqPlay") == 1, v("wSeqPlay"))
    pb.tick(60)
    midi(0xFA)
    check("FOLLOW: a second start while it runs starts from the top (still running)", v("wSeqPlay") == 1 and v("wSeqSeg") == 0 and v("wSeqTick") < 20, (v("wSeqPlay"), v("wSeqSeg"), v("wSeqTick")))
    midi(0xFC)
    check("FOLLOW: MIDI stop stops it", v("wSeqPlay") == 0, v("wSeqPlay"))
    midi(0xFC)
    check("FOLLOW: a second stop does nothing", v("wSeqPlay") == 0)
    midi(0xFB)
    check("FOLLOW: continue starts it when stopped", v("wSeqPlay") == 1)
    midi(0xFC)

    for bpm in (60, 100, 120, 187, 188, 200, 240):
        v_ = bpm - 60
        midi(0xB0, 14, v_ % 128, 0xB0, 15, v_ // 128)
        check(f"FOLLOW: CC14 / CC15 set the tempo to {bpm}", v("wBpm") == bpm, v("wBpm"))
    midi(0xB0, 14, 127, 0xB0, 15, 1)
    check("FOLLOW: the tempo is clamped to 240", v("wBpm") == 240, v("wBpm"))

    midi(0xC0, 2)
    check("FOLLOW: program change 2 edits pattern 3", v("wEditPat") == 2, v("wEditPat"))
    midi(0xC0, 9)
    check("FOLLOW: an unknown program is ignored", v("wEditPat") == 2, v("wEditPat"))
    midi(0xC0, 0)
    check("FOLLOW: program change 0 edits pattern 1", v("wEditPat") == 0, v("wEditPat"))

    # timbre CCs: MIDI channels 1-4 are CH1-CH4 (default)
    P = lambda ch, i: mem[PATCH + ch * 32 + i]
    midi(0xB0, 20, 96)                       # CH1: duty = 96 / 32 = 3
    midi(0xB1, 20, 33)                       # CH2: 1
    midi(0xB2, 20, 127)                      # CH3: wave = 127 / 16 = 7
    midi(0xB3, 20, 80)                       # CH4: width = 80 / 64 = 1
    check("CC20: duty / wave / width, scaled to each channel", (P(0, 0), P(1, 0), P(2, 0), P(3, 0)) == (3, 1, 7, 1), (P(0, 0), P(1, 0), P(2, 0), P(3, 0)))
    midi(0xB0, 20, 0, 0xB2, 20, 15, 0xB3, 20, 10)
    check("CC20: low values", (P(0, 0), P(2, 0), P(3, 0)) == (0, 0, 0), (P(0, 0), P(2, 0), P(3, 0)))
    midi(0xB0, 21, 127, 0xB1, 21, 64, 0xB3, 21, 40)
    check("CC21: volume 0-15 (value / 8)", (P(0, 1), P(1, 1), P(3, 1)) == (15, 8, 5), (P(0, 1), P(1, 1), P(3, 1)))
    midi(0xB2, 21, 0)
    a = P(2, 1)
    midi(0xB2, 21, 60)
    b_ = P(2, 1)
    midi(0xB2, 21, 127)
    c_ = P(2, 1)
    check("CC21 on CH3: output level 0 / 1 / 2", (a, b_, c_) == (0, 1, 2), (a, b_, c_))
    midi(0xB0, 10, 0, 0xB1, 10, 64, 0xB2, 10, 127)
    check("CC10: pan left (1) / both (0) / right (2)", (P(0, 5), P(1, 5), P(2, 5)) == (1, 0, 2), (P(0, 5), P(1, 5), P(2, 5)))
    other = P(1, 0)
    midi(0xB5, 20, 100)                      # MIDI channel 6: nobody listens
    check("a CC on a MIDI channel nobody listens to changes nothing", P(1, 0) == other and P(0, 0) == 0)
    pb.stop(save=False)

print("\n%d FAILED" % fails if fails else "\nALL PASSED")
raise SystemExit(1 if fails else 0)
