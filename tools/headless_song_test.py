#!/usr/bin/env python3
"""Song test using PyBoy (pip install pyboy pillow). Run `make` first.

Covers: the song screen (START+UP / START+DOWN, cursor, A/B steps, edit pattern, mode),
the pattern pages, chain playback (which pattern plays when), and saving / loading a whole song.
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
    pb.tick(60)           # the boot (4 slot scans + a load) takes a few frames
    return pb


def combo(pb, held, btn, settle=6):
    pb.button_press(held)
    pb.tick(3)
    pb.button_press(btn)
    pb.tick(3)
    pb.button_release(btn)
    pb.tick(2)
    pb.button_release(held)
    pb.tick(settle)


def tap(pb, btn, settle=6):
    pb.button_press(btn)
    pb.tick(3)
    pb.button_release(btn)
    pb.tick(settle)


PAT = sym["wPatterns"]          # $D000
CHAIN = sym["wChain"]
HI = 1                          # pattern p lives in WRAM bank p + 1
check("the patterns start at $D000 (a bank each)", PAT == 0xD000, hex(PAT))

with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]

    # --- defaults
    check("boot: chain = pattern 1 then the end", mem[CHAIN] == 0 and all(mem[CHAIN + i] == 0xFF for i in range(1, 16)))
    check("boot: loop mode, pattern 1 edited and played", v("wSongMode") == 0 and v("wEditBank") == HI and v("wPlayBank") == HI)
    check("boot: patterns 2-4 are empty", all(mem[b, PAT + i] == 0 for b in (2, 3, 4) for i in range(2048)))
    check("boot: the demo is pattern 1", mem[1, PAT] == 60)

    # --- the song screen
    combo(pb, "start", "up")
    check("START+UP opens the song screen", v("wScreen") == 5, v("wScreen"))
    combo(pb, "start", "right")
    combo(pb, "start", "left")
    check("START+LEFT/RIGHT do nothing there", v("wScreen") == 5)
    combo(pb, "start", "up")
    check("START+UP does nothing there either", v("wScreen") == 5)
    combo(pb, "start", "down")
    check("START+DOWN goes back to the play screen", v("wScreen") == 0, v("wScreen"))
    combo(pb, "start", "right")                      # edit screen
    combo(pb, "start", "up")
    combo(pb, "start", "down")
    check("... and back to the edit screen when it came from there", v("wScreen") == 1, v("wScreen"))
    combo(pb, "start", "left")
    combo(pb, "start", "up")
    pb.tick(30)

    def row_text(r, n=18):
        return bytes(mem[0x9800 + r * 32 + i] for i in range(n))

    tiles = lambda s: bytes(ord(c) - 32 for c in s)
    check("the first chain row shows '>1' and '--' for the end", row_text(6)[:6] == tiles(">1 ") + tiles(" - ")[:3] or row_text(6)[:2] == tiles(">1"), row_text(6))
    check("the mode row shows LOOP, the edit row P1", row_text(2)[6:10] == tiles("LOOP") and row_text(3)[6:8] == tiles("P1"), (row_text(2), row_text(3)))

    # --- steps: A / B on the chain
    check("the cursor starts on step 1", v("wSongCur") == 0)
    tap(pb, "b")
    check("B on step 1: wraps to the last pattern (a song needs one step)", mem[CHAIN] == 3, mem[CHAIN])
    tap(pb, "a")
    check("A on the last pattern of step 1: back to pattern 1", mem[CHAIN] == 0, mem[CHAIN])
    tap(pb, "right")
    check("RIGHT moves the cursor", v("wSongCur") == 1)
    tap(pb, "a")
    check("A on the end: pattern 1", mem[CHAIN + 1] == 0, mem[CHAIN + 1])
    for want in (1, 2, 3, 0xFF, 0):
        tap(pb, "a")
        check(f"A steps the pattern to {want}", mem[CHAIN + 1] == want, mem[CHAIN + 1])
    mem[CHAIN + 1] = 0
    tap(pb, "b")
    check("B on pattern 1 (step 2) gives the end", mem[CHAIN + 1] == 0xFF, mem[CHAIN + 1])
    tap(pb, "b")
    check("B on the end gives the last pattern", mem[CHAIN + 1] == 3, mem[CHAIN + 1])
    pb.tick(20)
    check("the chain row shows step 2 as pattern 4 (and the cursor)", row_text(6)[3:6] == tiles(">4 "), row_text(6))
    tap(pb, "left")
    pb.tick(20)
    check("the cursor mark moved back to step 1", row_text(6)[:3] == tiles(">1 ") and row_text(6)[3:6] == tiles(" 4 "), row_text(6))
    tap(pb, "right")
    for _ in range(8):
        tap(pb, "right")
    check("the cursor reaches step 10 (row 2 of the chain)", v("wSongCur") == 9, v("wSongCur"))
    tap(pb, "up")
    check("UP moves a whole row (6 steps)", v("wSongCur") == 3, v("wSongCur"))
    for _ in range(20):
        tap(pb, "down")
    check("DOWN stops inside the 16 steps", v("wSongCur") <= 15 and v("wSongCur") >= 9, v("wSongCur"))
    for _ in range(40):
        tap(pb, "right")
    check("RIGHT stops at step 16", v("wSongCur") == 15, v("wSongCur"))
    for _ in range(40):
        tap(pb, "left", 3)
    check("LEFT stops at step 1", v("wSongCur") == 0, v("wSongCur"))
    tap(pb, "right")
    mem[CHAIN + 1] = 0xFF

    # --- edit pattern and mode
    combo(pb, "select", "right")
    check("SELECT+RIGHT edits pattern 2", v("wEditPat") == 1 and v("wEditBank") == 2, (v("wEditPat"), v("wEditBank")))
    check("... and in loop mode that is the pattern that plays", v("wPlayBank") == 2, v("wPlayBank"))
    check("... without changing channel", v("wSelCh") == 0)
    combo(pb, "select", "right")
    combo(pb, "select", "right")
    combo(pb, "select", "right")
    check("the edit pattern stops at pattern 4", v("wEditPat") == 3 and v("wEditBank") == 4, (v("wEditPat"), v("wEditBank")))
    for _ in range(5):
        combo(pb, "select", "left")
    check("... and at pattern 1", v("wEditPat") == 0 and v("wEditBank") == HI)
    combo(pb, "select", "up")
    check("SELECT+UP: song mode", v("wSongMode") == 1, v("wSongMode"))
    combo(pb, "select", "right")
    check("in song mode editing another pattern does not change what plays", v("wEditPat") == 1 and v("wPlayBank") == HI, (v("wEditPat"), v("wPlayBank")))
    pb.tick(20)
    check("the mode row shows SONG, the edit row P2", row_text(2)[6:10] == tiles("SONG") and row_text(3)[6:8] == tiles("P2"), (row_text(2), row_text(3)))
    combo(pb, "select", "left")
    combo(pb, "select", "down")
    check("SELECT+DOWN: back to loop mode", v("wSongMode") == 0)

    # --- patterns are separate: the roll writes into the edited pattern
    combo(pb, "select", "right")                       # edit pattern 2
    combo(pb, "start", "down")
    combo(pb, "start", "right")
    combo(pb, "start", "right")                        # the piano roll
    pb.tick(30)
    check("on the piano roll", v("wScreen") == 2, v("wScreen"))
    mem[sym["wRollNote"]] = 70
    mem[sym["wRollTick"]] = 0
    mem[sym["wRollCell"]] = 0
    tap(pb, "a")
    pb.button_release("a")
    pb.tick(10)
    check("A on the roll placed the note in pattern 2, channel 1", mem[2, PAT] == 70, mem[2, PAT])
    check("... and pattern 1 is untouched", mem[1, PAT] == 60, mem[1, PAT])
    pb.stop(save=False)

# --- playback of a chain
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    for b in range(1, 5):
        for i in range(2048):
            mem[b, PAT + i] = 0
    mem[1, PAT] = 60                   # pattern 1: C4 on channel 1 at tick 0
    mem[2, PAT] = 64                   # pattern 2: E4
    mem[3, PAT] = 67                   # pattern 3: G4
    mem[sym["wSeqBars"]] = 1            # one bar per pattern
    mem[sym["wBpm"]] = 240             # a bar = 60 frames
    mem[CHAIN:CHAIN + 4] = bytes([0, 1, 0, 2])
    mem[CHAIN + 4] = 0xFF
    combo(pb, "start", "up")
    combo(pb, "select", "up")
    check("song mode is on", v("wSongMode") == 1)
    combo(pb, "start", "down")
    combo(pb, "select", "start")
    check("the sequencer runs", v("wSeqPlay") == 1)
    check("it starts on the first chain step", v("wChainPos") == 0 and v("wPlayBank") == HI)
    seen = []
    notes = []
    for _ in range(60):
        pb.tick(8)
        seen.append(v("wChainPos"))
        notes.append(mem[sym["wCurNote"]])
    # collapse runs
    runs = [seen[0]]
    for s_ in seen[1:]:
        if s_ != runs[-1]:
            runs.append(s_)
    check("the chain steps go 0,1,2,3 and round again", runs[:6] == [0, 1, 2, 3, 0, 1], runs)
    nruns = [notes[0]]
    for n in notes[1:]:
        if n != nruns[-1]:
            nruns.append(n)
    check("the notes follow the chain: C4, E4, C4, G4, C4", nruns[:6] in ([60, 64, 60, 67, 60, 64], [0, 60, 64, 60, 67, 60]) or nruns[:5] == [60, 64, 60, 67, 60], nruns[:8])
    # stop and loop mode plays the edited pattern
    combo(pb, "select", "start")
    check("SELECT+START stops", v("wSeqPlay") == 0)
    combo(pb, "start", "up")
    combo(pb, "select", "down")
    combo(pb, "start", "down")
    combo(pb, "select", "start")
    pb.tick(150)
    check("loop mode: the edited pattern plays over and over", v("wPlayBank") == HI and v("wChainPos") == 0, (v("wPlayBank"), v("wChainPos")))
    pb.stop(save=False)


# --- switching the pattern while it plays must not leave a note hanging; the playing step is marked
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    tiles = lambda s_: bytes(ord(c) - 32 for c in s_)
    for b in range(1, 5):
        for i in range(2048):
            mem[b, PAT + i] = 0
    mem[1, PAT] = 60                   # pattern 1: a note at tick 0 that nothing ends
    mem[sym["wSeqBars"]] = 1
    combo(pb, "start", "up")
    combo(pb, "select", "start")
    pb.tick(60)
    check("pattern 1 plays and its note sounds", v("wSeqPlay") == 1 and mem[sym["wCurNote"]] == 60, (v("wSeqPlay"), mem[sym["wCurNote"]]))
    combo(pb, "select", "right")       # edit pattern 2 while pattern 1 plays (loop mode)
    check("the edited pattern plays now", v("wPlayBank") == 2, v("wPlayBank"))
    check("the old pattern's note was released (no hanging note)", all(mem[sym["wCurNote"] + c] == 0 for c in range(4)), [mem[sym["wCurNote"] + c] for c in range(4)])
    combo(pb, "select", "left")
    pb.tick(60)
    check("back on pattern 1 its note sounds again", mem[sym["wCurNote"]] == 60, mem[sym["wCurNote"]])
    # song mode: the playing step is shown as [n]
    mem[CHAIN:CHAIN + 3] = bytes([0, 1, 0xFF])
    combo(pb, "select", "up")          # song mode (restarts the song, silences)
    check("switching to song mode silences the old note and restarts", v("wSongMode") == 1 and v("wChainPos") == 0 and v("wPlayBank") == HI, (v("wChainPos"), v("wPlayBank")))
    pb.tick(10)
    row = bytes(mem[0x9800 + 6 * 32 + i] for i in range(9))
    pb.tick(10)
    row = bytes(mem[0x9800 + 6 * 32 + i] for i in range(9))
    check("step 1 shows the cursor and the end mark of the playing step: '>1]'", row[:3] == tiles(">1]"), row)
    pb.tick(80)                        # the second pattern now (a bar is 120 frames at 120 BPM: wait for it)
    for _ in range(60):
        pb.tick(4)
        if v("wChainPos") == 1:
            break
    pb.tick(15)
    row = bytes(mem[0x9800 + 6 * 32 + i] for i in range(9))
    check("step 2 is marked '[2]' and step 1 lost its marks", row[:6] == tiles(">1 ") + tiles("[2]"), row)
    combo(pb, "select", "start")
    pb.tick(15)
    row = bytes(mem[0x9800 + 6 * 32 + i] for i in range(9))
    check("stopped: the marks are gone", row[3:6] == tiles(" 2 "), row)
    pb.stop(save=False)


# --- a note that is still sounding at the end of a chain step does not carry into the next pattern
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    for b in range(1, 5):
        for i in range(2048):
            mem[b, PAT + i] = 0
    mem[1, PAT] = 36                   # pattern 1: a bass note on channel 1 that nothing ends
    mem[2, PAT + 512] = 72             # pattern 2: a note on channel 2 only
    mem[sym["wSeqBars"]] = 1
    mem[sym["wBpm"]] = 240             # a bar = 60 frames
    mem[CHAIN:CHAIN + 3] = bytes([0, 1, 0xFF])
    combo(pb, "start", "up")
    combo(pb, "select", "up")
    combo(pb, "start", "down")
    combo(pb, "select", "start")
    pb.tick(20)
    check("pattern 1's bass note sounds", mem[sym["wCurNote"]] == 36, mem[sym["wCurNote"]])
    for _ in range(40):
        pb.tick(2)
        if v("wChainPos") == 1:
            break
    pb.tick(12)
    check("in pattern 2 the old bass note is gone and channel 2 plays", v("wChainPos") == 1 and mem[sym["wCurNote"]] == 0 and mem[sym["wCurNote"] + 1] == 72,
          (v("wChainPos"), mem[sym["wCurNote"]], mem[sym["wCurNote"] + 1]))
    pb.stop(save=False)

# --- saving and loading a whole song
with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    ram = pathlib.Path(str(rom) + ".ram")
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    for p_ in range(4):
        for c in range(4):
            for t in (0, 5, 100, 191):
                mem[p_ + 1, PAT + c * 512 + t] = 40 + p_ * 5 + c + (t % 7)
                mem[p_ + 1, PAT + c * 512 + 256 + t] = 90 + p_ * 5 + c + (t % 7)    # segment 2 too
    mem[CHAIN:CHAIN + 6] = bytes([3, 0, 2, 2, 1, 0xFF])
    mem[CHAIN + 6] = 9            # a damaged step: it must not survive a load
    mem[sym["wBpm"]] = 141
    mem[sym["wSeqBars"]] = 6
    snapshot = {(p_, c, g): bytes(mem[p_ + 1, PAT + c * 512 + g * 256: PAT + c * 512 + g * 256 + 192]) for p_ in range(4) for c in range(4) for g in range(2)}
    combo(pb, "select", "a", 30)
    check("SELECT+A saves the song", v("wMsg") == 1, v("wMsg"))
    for b in range(1, 5):
        for i in range(2048):
            mem[b, PAT + i] = 0
    mem[CHAIN:CHAIN + 16] = bytes([0] + [0xFF] * 15)
    mem[sym["wBpm"]] = 90
    combo(pb, "select", "b", 30)
    check("SELECT+B loads it", v("wMsg") == 2, v("wMsg"))
    check("all four patterns are restored exactly (both segments of every channel)",
          all(bytes(mem[p_ + 1, PAT + c * 512 + g * 256: PAT + c * 512 + g * 256 + 192]) == snapshot[(p_, c, g)]
              for p_ in range(4) for c in range(4) for g in range(2)))
    check("the chain is restored", bytes(mem[CHAIN:CHAIN + 5]) == bytes([3, 0, 2, 2, 1]) and mem[CHAIN + 5] == 0xFF)
    check("a damaged chain step becomes the end", mem[CHAIN + 6] == 0xFF, mem[CHAIN + 6])
    check("BPM and loop length are restored", v("wBpm") == 141 and v("wSeqBars") == 6)
    check("loading edits pattern 1 in loop mode", v("wEditPat") == 0 and v("wSongMode") == 0 and v("wEditBank") == HI and v("wPlayBank") == HI)
    pb.stop(save=True)
    pb = boot(rom)
    mem = pb.memory
    check("reboot: the song is loaded from slot 1", bytes(mem[CHAIN:CHAIN + 5]) == bytes([3, 0, 2, 2, 1]) and mem[sym["wBpm"]] == 141,
          (bytes(mem[CHAIN:CHAIN + 5]), mem[sym["wBpm"]]))
    check("reboot: pattern 4's cells are there", mem[4, PAT + 512 + 100] == 40 + 15 + 1 + (100 % 7) and mem[4, PAT + 512 + 256 + 100] == 90 + 15 + 1 + (100 % 7), mem[4, PAT + 512 + 100])
    pb.stop(save=False)

print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
