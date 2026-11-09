#!/usr/bin/env python3
"""CH3 wave editor test using PyBoy. Run `make` first.

WAVE 0-3 are presets, 4-7 the custom waves W1-W4 (wWaves). START+A on the edit screen (CH3) opens the
editor; the pad edits samples; A plays; START+A loads the next preset; START+B goes back; the waves are
saved with the song.
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


def boot(rom):
    pb = PyBoy(str(rom), window="null", sound_emulated=False)
    for _ in range(2000):
        pb.tick(1)
        if pb.register_file.PC >= 0x100:
            break
    pb.tick(60)
    return pb


def combo(pb, held, btn, settle=6):
    pb.button_press(held); pb.tick(3); pb.button_press(btn); pb.tick(3)
    pb.button_release(btn); pb.tick(2); pb.button_release(held); pb.tick(settle)


def tap(pb, btn, settle=6):
    pb.button_press(btn); pb.tick(3); pb.button_release(btn); pb.tick(settle)


# the preset waves from src/waves.inc
waves_inc = (root / "src/waves.inc").read_text()
presets = [[int(x, 16) for x in re.findall(r"\$([0-9A-F]{2})", ln)] for ln in waves_inc.splitlines() if ln.strip().startswith("db ")]

with tempfile.TemporaryDirectory() as tmp:
    rom = pathlib.Path(tmp) / "t.gb"
    shutil.copy(rom_src, rom)
    pb = boot(rom)
    mem = pb.memory
    v = lambda n: mem[sym[n]]
    W = sym["wWaves"]
    srcs = []
    pb.hook_register(0, sym["LoadWave.l"], lambda ctx: srcs.append(pb.register_file.HL), None)   # (the source of the wave RAM copy)
    wv = lambda k: [mem[W + 16 * k + i] for i in range(16)]
    check("the custom waves start as copies of the four presets", all(wv(k) == presets[k] for k in range(4)), [wv(k)[:3] for k in range(4)])
    PATCH_CH3 = sym["wPatch"] + 2 * 32
    mem[PATCH_CH3] = 6                       # WAVE = W3
    combo(pb, "start", "right"); pb.tick(20)  # the edit screen
    tap(pb, "select"); tap(pb, "select")       # CH3
    check("on the edit screen, CH3", v("wScreen") == 1 and v("wSelCh") == 2, (v("wScreen"), v("wSelCh")))
    combo(pb, "start", "a"); pb.tick(30)
    check("START+A opens the wave editor on W3", v("wScreen") == 6 and v("wWaveSel") == 6, (v("wScreen"), v("wWaveSel")))
    before = wv(2)
    tap(pb, "up")                              # level of sample 0 +1
    lvl0 = wv(2)[0] >> 4
    check("UP raises the level of the sample under the cursor (sample 0 = high nibble of byte 0)", lvl0 == (before[0] >> 4) + 1 or (before[0] >> 4) == 15, (before[0] >> 4, lvl0))
    for _ in range(20):
        tap(pb, "down", 2)
    check("DOWN stops at 0", wv(2)[0] >> 4 == 0, wv(2)[0])
    tap(pb, "right")
    check("RIGHT moves the cursor to sample 1 (low nibble of byte 0)", v("wWaveCur") == 1, v("wWaveCur"))
    for _ in range(3):
        tap(pb, "up", 2)
    check("the level of sample 1 is the low nibble (the high one is kept)", (wv(2)[0] & 0x0F) == min(15, (before[0] & 0x0F) + 3) and wv(2)[0] >> 4 == 0, wv(2)[0])
    pb.button_press("b"); pb.tick(3); tap(pb, "up", 2); pb.button_release("b"); pb.tick(4)
    check("B+UP: +4", (wv(2)[0] & 0x0F) == min(15, (before[0] & 0x0F) + 7), wv(2)[0])
    pb.tick(10)
    # the screen: row 5 shows the hex digits (the cursor's sample inverted), rows 3-4 the bars
    def bg(row, col):
        return pb.tilemap_background[col, row]
    hexrow = [bg(5, 2 + i) for i in range(16)]
    check("the hex row shows the 16 samples; sample 1 is inverted", hexrow[1] >= 128 and all(h < 128 for i, h in enumerate(hexrow) if i != 1), hexrow)
    top = [bg(3, 2 + i) for i in range(16)]
    bot = [bg(4, 2 + i) for i in range(16)]
    check("the bars: tiles of the bar set (or blank above)", all(t == 0 or 76 <= t <= 83 for t in top + bot) and all(76 <= t <= 83 for t in bot), (top, bot))
    # A plays: wave RAM holds W3
    del srcs[:]
    pb.button_press("a"); pb.tick(20)
    pb.button_release("a"); pb.tick(10)
    check("A plays the wave: the wave RAM is loaded from W3", srcs and srcs[0] == W + 32, (srcs[:1], W + 32))
    # START+A: the next preset goes into W3
    combo(pb, "start", "a"); pb.tick(10)
    check("START+A copies the next preset into the wave (preset 1 = SAW)", wv(2) == presets[1], wv(2))
    check("the other custom waves are untouched", wv(0) == presets[0] and wv(1) == presets[1] and wv(3) == presets[3])
    # back
    combo(pb, "start", "b"); pb.tick(30)
    check("START+B goes back to the edit screen on CH3", v("wScreen") == 1 and v("wSelCh") == 2, (v("wScreen"), v("wSelCh")))
    # a preset WAVE opens the editor read-only
    mem[PATCH_CH3] = 1
    combo(pb, "start", "a"); pb.tick(30)
    check("START+A with a preset wave opens the editor on the preset (view only)", v("wScreen") == 6 and v("wWaveSel") == 1, (v("wScreen"), v("wWaveSel")))
    top = [pb.tilemap_background[2 + i, 3] for i in range(16)]
    check("the preset SAW is drawn (bar tiles)", any(76 <= t <= 83 for t in top + [pb.tilemap_background[2 + i, 4] for i in range(16)]))
    for _ in range(3):
        tap(pb, "up", 2)
    check("the preset is not changed by UP", all(mem[sym["Waves"] + 16 + i] == presets[1][i] for i in range(16)))
    check("START+A does not load a preset over a preset", (combo(pb, "start", "a") or True) and mem[sym["Waves"] + 16] == presets[1][0] and wv(2) == presets[1])
    combo(pb, "start", "b"); pb.tick(30)
    # A held, START pressed, A released while START is held: the note must stop
    mem[PATCH_CH3] = 5
    combo(pb, "start", "a"); pb.tick(30)
    pb.button_press("a"); pb.tick(10)
    pb.button_press("start"); pb.tick(4)
    pb.button_release("a"); pb.tick(10)
    check("A released while START is held still stops the note", mem[sym["wCurNote"] + 2] == 0 and mem[0xFF1A] & 0x80 == 0, (mem[sym["wCurNote"] + 2], hex(mem[0xFF1A])))
    pb.button_release("start"); pb.tick(10)
    combo(pb, "start", "b"); pb.tick(30)
    # presets still play from the presets
    mem[PATCH_CH3] = 1
    del srcs[:]
    pb.button_press("a"); pb.tick(20)
    pb.button_release("a"); pb.tick(10)
    check("WAVE 1 still plays the preset SAW (from the preset table)", srcs and srcs[0] == sym["Waves"] + 16, (srcs[:1], sym["Waves"] + 16))
    # save and load: the custom waves come back
    mem[PATCH_CH3] = 4
    mem[W] = 0x12
    combo(pb, "select", "b", 40)
    check("saved", v("wMsg") == 1, v("wMsg"))
    mem[W] = 0x99
    combo(pb, "select", "a", 40)
    check("SELECT+A loads the song with its custom waves", v("wMsg") == 2 and mem[W] == 0x12, (v("wMsg"), mem[W]))
    pb.stop(save=False)

print("\n%d FAILED" % fails if fails else "\nALL PASSED")
raise SystemExit(1 if fails else 0)
