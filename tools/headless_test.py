#!/usr/bin/env python3
"""Headless ROM smoke test using PyBoy (pip install pyboy pillow).

Drives the joypad, injects MIDI bytes straight into the serial RX ring
(the emulator has no link input) and checks RAM state + saves screenshots.

usage: headless_test.py [rom] [screenshot_dir]
"""
import pathlib
import re
import sys

from pyboy import PyBoy

root = pathlib.Path(__file__).resolve().parent.parent
rom = sys.argv[1] if len(sys.argv) > 1 else str(root / "build/chromasynth.gb")
shots = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else None
if shots:
    shots.mkdir(parents=True, exist_ok=True)

# symbol table from rgblink -n
sym = {}
for line in (root / "build/chromasynth.sym").read_text().splitlines():
    m = re.match(r"([0-9A-Fa-f]{2}):([0-9A-Fa-f]{4}) (\S+)", line)
    if m:
        sym[m.group(3)] = int(m.group(2), 16)

pb = PyBoy(rom, window="null", sound_emulated=False)
mem = pb.memory

# --- VBlank budget: UpdateUI (VRAM/OAM writes) must finish before VBlank ends,
# otherwise real hardware drops the late writes and leaves stale tiles on screen.
vb_entry = []   # (wScreenReq, LY) at UpdateUI entry
vb_exit = []    # LY when UpdateUI returned (VoiceTick is the next call)


def _hook_entry(ctx):
    vb_entry.append((mem[sym["wScreenReq"]], mem[0xFF44]))


def _hook_exit(ctx):
    vb_exit.append(mem[0xFF44])


pb.hook_register(0, sym["UpdateUI"], _hook_entry, None)
pb.hook_register(0, sym["VoiceTick"], _hook_exit, None)
fails = 0


def check(name, cond, detail=""):
    global fails
    print(("PASS " if cond else "FAIL ") + name + (f"  [{detail}]" if detail != "" else ""))
    fails += not cond


def cur(ch):
    return mem[sym["wCurNote"] + ch]


def shot(name):
    if shots:
        pb.screen.image.resize((480, 432)).save(shots / f"{name}.png")


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


# PyBoy runs the real boot ROM first; wait until it hands over to the cartridge
for _ in range(2000):
    pb.tick(1)
    if pb.register_file.PC >= 0x100:
        break
for _ in range(30):  # init takes a few frames; wait for the beep to start
    pb.tick(1)
    if cur(0) == 72:
        break
check("boot beep on CH1", cur(0) == 72, cur(0))
pb.tick(60)
check("boot beep released", cur(0) == 0, cur(0))
shot("01_boot")

# --- joypad
pb.button_press("a")
pb.tick(4)
check("A plays pad note on CH1", cur(0) == 60, cur(0))
shot("02_pad_a")
pb.button_release("a")
pb.tick(4)
check("A release stops CH1", cur(0) == 0)
press("up")
press("right")
check("pad note = 73", mem[sym["wJoyNote"]] == 73, mem[sym["wJoyNote"]])
press("down")
press("left")
check("pad note back to 60", mem[sym["wJoyNote"]] == 60)
press("select")
check("SELECT -> CH2", mem[sym["wSelCh"]] == 1)
pb.button_press("a")
pb.tick(4)
check("A plays on CH2", cur(1) == 60 and cur(0) == 0, (cur(0), cur(1)))
pb.button_release("a")
pb.tick(4)

# --- edit screen (CH2 rows: 0 DUTY 1 VOL 2 ENV, 3-5 hidden, 6 VIBD, 7 VIBS)
patch2 = sym["wPatch"] + 8
press("start")
pb.tick(4)
check("START -> edit screen", mem[sym["wScreen"]] == 1)
shot("04_edit_ch2")
press("down")
press("down")
press("down")
check("down skips hidden rows -> 6", mem[sym["wEditRow"]] == 6, mem[sym["wEditRow"]])
press("up")
check("up skips hidden rows -> 2", mem[sym["wEditRow"]] == 2, mem[sym["wEditRow"]])
press("left")
check("ENV clamped at 0", mem[patch2 + 2] == 0)
press("right")
press("right")
check("ENV -> 2", mem[patch2 + 2] == 2, mem[patch2 + 2])
press("up")
press("left")
check("VOL 15 -> 14", mem[patch2 + 1] == 14, mem[patch2 + 1])
press("right")
press("right")
check("VOL clamped at 15", mem[patch2 + 1] == 15, mem[patch2 + 1])
press("down")
press("down")
check("row 6 (VIBD)", mem[sym["wEditRow"]] == 6)
for _ in range(9):
    press("right")
check("VIBD clamped at 7", mem[patch2 + 6] == 7, mem[patch2 + 6])
pb.tick(10)
shot("05_edit_vib")
press("select")
check("SELECT in edit -> CH3, row 0", mem[sym["wSelCh"]] == 2 and mem[sym["wEditRow"]] == 0)
pb.tick(10)
shot("06_edit_ch3")
press("right")
check("CH3 wave -> 1", mem[sym["wPatch"] + 16] == 1, mem[sym["wPatch"] + 16])
press("select")
press("select")
check("SELECT wraps to CH1", mem[sym["wSelCh"]] == 0)
pb.tick(10)
shot("07_edit_ch1")

# --- MIDI
midi(0x90, 64, 100)
check("MIDI ch1 note on", cur(0) == 64, cur(0))
midi(0x92, 48, 100)
check("MIDI ch3 (wave) note on", cur(2) == 48, cur(2))
midi(0x93, 80, 1)
check("MIDI ch4 (noise) note on", cur(3) == 80, cur(3))
midi(0x80, 64, 0)
check("MIDI note off", cur(0) == 0)
midi(0x90, 60, 100, 62, 100)  # running status: second note replaces first (mono)
check("running status", cur(0) == 62, cur(0))
midi(0x90, 62, 0)
check("note on vel 0 == off", cur(0) == 0)
midi(0x94, 60, 100)
check("MIDI ch5 ignored", cur(0) == 0 and cur(1) == 0 and cur(2) == 48)
midi(0x90, 10, 100)
check("out-of-range note ignored", cur(0) == 0, cur(0))
midi(0xF8, 0xF8)
check("realtime bytes ignored", cur(0) == 0)
pb.tick(30)
shot("08_midi")

# --- vibrato: CH2 depth 7 at A4 (period 1750): output must oscillate around the base
midi(0x91, 69, 100)
base = mem[sym["wBase"] + 2] | (mem[sym["wBase"] + 3] << 8)
seen = []
for _ in range(60):
    pb.tick(1)
    seen.append(mem[sym["wOut"] + 2] | (mem[sym["wOut"] + 3] << 8))
check("vibrato base period = 1750", base == 1750, base)
check("vibrato oscillates both sides", min(seen) < base < max(seen), (min(seen), max(seen)))
check("vibrato depth bounded", max(seen) - base <= 10 and base - min(seen) <= 10, (min(seen), max(seen)))
midi(0x81, 69, 0)
mem[sym["wPatch"] + 8 + 6] = 0
midi(0x91, 69, 100)
pb.tick(1)
before = mem[sym["wOut"] + 2] | (mem[sym["wOut"] + 3] << 8)
pb.tick(20)
after = mem[sym["wOut"] + 2] | (mem[sym["wOut"] + 3] << 8)
check("depth 0 -> no vibrato updates", before == after)
midi(0x81, 69, 0)

# --- piano roll
def hold(*btns, frames=3):
    for b in btns:
        pb.button_press(b)
    pb.tick(frames)


def release(*btns, frames=2):
    for b in btns:
        pb.button_release(b)
    pb.tick(frames)


def tap_while(held, btn):
    """Press btn while `held` is down (a combo)."""
    pb.button_press(held)
    pb.tick(3)
    pb.button_press(btn)
    pb.tick(3)
    pb.button_release(btn)
    pb.tick(2)
    pb.button_release(held)
    pb.tick(3)


P = sym["wPattern"]
G = sym["wGrid"]
T_EMP_W, T_NOTE_HEAD, T_NOTE_BODY, T_CUR_EMP, T_CUR_NOTE = 64, 68, 69, 70, 71


def cell(ch, step):
    return mem[P + ch * 64 + step]


def grid(row, col):
    """Tile in the shadow map: grid row 0..15, step column 0..15."""
    return mem[G + row * 20 + 2 + col]


def v(name):
    return mem[sym[name]]


def settle():
    pb.tick(10)  # rendering and copying are spread over a few frames


press("start")
pb.tick(4)
check("START -> piano roll", v("wScreen") == 2, v("wScreen"))
settle()
shot("09_roll")
check("demo pattern: CH1 C4 / OFF, CH1 page 2 starts with A3, CH3 bass",
      cell(0, 0) == 60 and cell(0, 2) == 0xFF and cell(0, 16) == 57 and cell(2, 0) == 48)
check("defaults: loop 32, cursor C4 step 0, window top C5",
      (v("wSeqLen"), v("wRollNote"), v("wRollStep"), v("wRollTop")) == (32, 60, 0, 72),
      (v("wSeqLen"), v("wRollNote"), v("wRollStep"), v("wRollTop")))
# top = 72 -> grid row r shows pitch 72 - r: C4 (60) is row 12, E4 (64) row 8, G4 (67) row 5
check("grid: cursor on the C4 note head", grid(12, 0) == T_CUR_NOTE, grid(12, 0))
check("grid: note body follows the head", grid(12, 1) == T_NOTE_BODY, grid(12, 1))
check("grid: E4 head at step 4", grid(8, 4) == T_NOTE_HEAD, grid(8, 4))
check("grid: empty white-key cell", grid(12, 2) == T_EMP_W, grid(12, 2))
check("grid: black-key row is shaded (+1)", grid(11, 2) == T_EMP_W + 1, grid(11, 2))
check("grid: beat column marked (+2)", grid(10, 4) == T_EMP_W + 2, grid(10, 4))

press("right")
check("RIGHT: cursor step 1", v("wRollStep") == 1)
settle()
check("cursor moved onto the note body", grid(12, 1) == T_CUR_NOTE and grid(12, 0) == T_NOTE_HEAD,
      (grid(12, 0), grid(12, 1)))
press("up")
check("UP: cursor pitch 61", v("wRollNote") == 61)
settle()
check("cursor on an empty cell", grid(11, 1) == T_CUR_EMP, grid(11, 1))
press("down")
press("left")
check("back at C4 step 0", (v("wRollNote"), v("wRollStep")) == (60, 0))

# --- d-pad auto-repeat: holding RIGHT keeps moving the cursor after an initial delay
hold("right", frames=0)
pb.tick(10)
check("auto-repeat: only the first move before the initial delay", v("wRollStep") == 1, v("wRollStep"))
pb.tick(30)
check("auto-repeat: a held direction keeps moving the cursor", v("wRollStep") >= 6, v("wRollStep"))
release("right")
stop_at = v("wRollStep")
pb.tick(20)
check("auto-repeat stops on release", v("wRollStep") == stop_at)
hold("left", frames=0)
pb.tick(120)
release("left")
check("auto-repeat to the left stops at step 0", v("wRollStep") == 0, v("wRollStep"))
pb.tick(10)

# B + d-pad jumps and must not delete anything
hold("b")
press("right")
press("right")
release("b", frames=4)
check("B+RIGHT jumps 4 steps", v("wRollStep") == 8, v("wRollStep"))
check("B+d-pad did not delete the note", cell(0, 0) == 60 and cell(0, 4) == 64)
hold("b")
press("right")
press("right")
release("b", frames=4)
check("page scroll: step 16 -> page 2", (v("wRollStep"), v("wRollPage")) == (16, 1), (v("wRollStep"), v("wRollPage")))
settle()
check("page 2: A3 head at column 0 (row 15), cursor empty at C4",
      grid(15, 0) == T_NOTE_HEAD and grid(12, 0) == T_CUR_EMP, (grid(15, 0), grid(12, 0)))
hold("b")
press("left")
press("left")
release("b", frames=4)
check("page scroll back", (v("wRollStep"), v("wRollPage")) == (8, 0))
press("left")
for _ in range(7):
    press("left")
check("cursor at step 0", v("wRollStep") == 0)
hold("b")
press("up")
release("b", frames=4)
check("B+UP: octave up, still in the window", (v("wRollNote"), v("wRollTop")) == (72, 72), (v("wRollNote"), v("wRollTop")))
hold("b")
press("up")
release("b", frames=4)
check("pitch scroll up: window follows", (v("wRollNote"), v("wRollTop")) == (84, 84), (v("wRollNote"), v("wRollTop")))
hold("b")
press("down")
press("down")
release("b", frames=4)
check("pitch scroll down: window follows", (v("wRollNote"), v("wRollTop")) == (60, 75), (v("wRollNote"), v("wRollTop")))
settle()

# ---- editing on CH2 (empty channel)
press("select")
check("SELECT tap -> channel 2 on the roll", v("wSelCh") == 1)
settle()
def vram(row, col):
    """Tile actually in VRAM (BG map) at grid row 0..15 / step column 0..15."""
    return mem[0x9800 + (1 + row) * 32 + 2 + col]


row = v("wRollTop") - v("wRollNote")
pb.button_press("a")
frames = 0
for frames in range(1, 13):
    pb.tick(1)
    if vram(row, 0) == T_CUR_NOTE:
        break
check("input latency: the note is on screen within 4 frames of pressing A", frames <= 4, frames)
pb.tick(2)
check("A places a note at the cursor", cell(1, 0) == 60, cell(1, 0))
check("...with a one-step length (OFF after it)", cell(1, 1) == 0xFF, cell(1, 1))
check("A auditions on CH2", cur(1) == 60, cur(1))
press("right")  # ignored while A is held? no: right while A held lengthens
check("A held + RIGHT lengthens: OFF moved to step 2", cell(1, 1) == 0 and cell(1, 2) == 0xFF, (cell(1, 1), cell(1, 2)))
press("left")
check("A held + LEFT shortens: OFF back at step 1", cell(1, 2) == 0 and cell(1, 1) == 0xFF, (cell(1, 1), cell(1, 2)))
release("a", frames=4)
check("A release stops the audition", cur(1) == 0)
hold("a", frames=4)
press("up")
check("A held + UP transposes the note and the cursor", cell(1, 0) == 61 and v("wRollNote") == 61, (cell(1, 0), v("wRollNote")))
press("down")
check("A held + DOWN transposes back", cell(1, 0) == 60 and v("wRollNote") == 60)
release("a", frames=4)
settle()
check("grid: the new note is drawn (cursor on its head)", grid(15, 0) == T_CUR_NOTE, grid(15, 0))
press("b")
check("B tap deletes the note and its OFF", cell(1, 0) == 0 and cell(1, 1) == 0, (cell(1, 0), cell(1, 1)))

# collision: a note that grows until it touches the next one
hold("a", frames=4)
release("a", frames=4)
press("right")
press("right")
hold("a", frames=4)
release("a", frames=4)
check("two notes on CH2 (steps 0 and 2)", cell(1, 0) == 60 and cell(1, 2) == 60 and cell(1, 1) == 0xFF)
press("left")
press("left")
hold("a", frames=4)
press("right")
check("growing into the next note removes the OFF (they touch)", cell(1, 1) == 0 and cell(1, 2) == 60, (cell(1, 1), cell(1, 2)))
press("right")
check("cannot grow past the next note", cell(1, 2) == 60 and cell(1, 3) == 0xFF, (cell(1, 2), cell(1, 3)))
release("a", frames=4)
press("b")
check("deleting the first note keeps the neighbour", cell(1, 0) == 0 and cell(1, 2) == 60)
for i in range(64):
    mem[P + 64 + i] = 0     # clean up CH2
press("select")             # CH3 (bass): the cursor jumps to its first note
check("channel switch: cursor on the first bass note", (v("wRollNote"), v("wRollStep"), v("wRollTop")) == (48, 0, 56),
      (v("wRollNote"), v("wRollStep"), v("wRollTop")))
settle()
check("channel switch: bass note drawn in the window", grid(8, 0) == T_CUR_NOTE, grid(8, 0))
press("select")             # CH4, then back to CH1
press("select")
check("SELECT cycles channels back to CH1", v("wSelCh") == 0)
settle()

# ---- BPM / loop length
tap_while("select", "up")
check("SELECT+UP: BPM 121", v("wBpm") == 121, v("wBpm"))
tap_while("select", "down")
check("SELECT+DOWN: BPM 120", v("wBpm") == 120, v("wBpm"))
tap_while("select", "left")
check("SELECT+LEFT: loop length 16", v("wSeqLen") == 16, v("wSeqLen"))
tap_while("select", "left")
check("loop length clamps at 16", v("wSeqLen") == 16)
tap_while("select", "right")
tap_while("select", "right")
check("SELECT+RIGHT x2: loop length 48", v("wSeqLen") == 48, v("wSeqLen"))
tap_while("select", "left")
check("loop length 32 again", v("wSeqLen") == 32)
check("combos did not change screen/channel", v("wScreen") == 2 and v("wSelCh") == 0)

# ---- playback
tap_while("select", "start")
check("SELECT+START starts playback", v("wSeqPlay") == 1)
check("...still on the roll", v("wScreen") == 2)
steps = 0
last = v("wSeqStep")
bass = set()
heads = []
for i in range(120):
    pb.tick(1)
    s_ = v("wSeqStep")
    if s_ != last:
        steps += 1
        last = s_
    bass.add(cur(2))
    if v("wPlayCol") != 0xFF:
        heads.append((v("wSeqCur") & 15, v("wPlayCol")))
    if i == 30:
        shot("10_roll_playing")
check("tempo: 16 steps in 2 s at 120 BPM", 15 <= steps <= 17, steps)
check("bass notes triggered by the pattern (steps 8 and 16)", {43, 45} <= bass, sorted(bass))
check("hi-hat (CH4) triggered", cur(3) in (90, 100), cur(3))
# the sprite is moved in the VBlank after the step plays, so it may lag by one frame
exact = sum(1 for a, b in heads if a == b)
near = all(a == b or (a - 1) % 16 == b for a, b in heads)
check("playhead sprite follows the played step", len(heads) > 50 and near and exact >= 0.8 * len(heads),
      (exact, len(heads)))
oam_x = mem[0xFE01]
check("playhead sprite is placed in OAM", mem[0xFE00] == 24 and oam_x == 24 + 8 * v("wPlayCol"), (mem[0xFE00], oam_x))
check("playhead line sits at the left edge of its cell (on the beat line)", mem[0x8000 + 72 * 16] == 0xC0 and mem[0x8000 + 72 * 16 + 1] == 0x00)
check("16 playhead sprites stacked on the grid rows", mem[0xFE00 + 15 * 4] == 24 + 15 * 8 and mem[0xFE02] == 72)
tap_while("select", "start")
check("SELECT+START stops playback", v("wSeqPlay") == 0)
check("stop silences all channels", [cur(c) for c in range(4)] == [0, 0, 0, 0])
pb.tick(4)
check("playhead hidden while stopped", v("wPlayCol") == 0xFF and mem[0xFE00] == 0)

# 240 BPM: loops over 32 steps, view follows the playhead across pages
mem[sym["wBpm"]] = 240
mem[sym["wRollStep"]] = 0
tap_while("select", "start")
seen = set()
pages = set()
for _ in range(200):
    pb.tick(1)
    seen.add(v("wSeqStep"))
    if v("wSeqCur") >= 16:
        pages.add(v("wRollPage"))
check("loop: steps wrap inside 0..31", max(seen) == 31 and 0 in seen, (min(seen), max(seen)))
check("view followed the playhead onto page 2", 1 in pages, pages)
tap_while("select", "start")

press("start")
pb.tick(4)
check("START -> back to play screen", v("wScreen") == 0, v("wScreen"))
pb.tick(20)
shot("12_play_again")

# Frames that entered after LY 146 (or outside VBlank) are skipped by UpdateUI's own
# guard and draw nothing; screen switches turn the LCD off/on (LY restarts): ignore both.
frames = list(zip(vb_entry, vb_exit))
worked = [(ly_out) for (req, ly_in), ly_out in frames if req == 0 and 144 <= ly_in < 147]
skipped = sum(1 for (req, ly_in), _ in frames if req == 0 and not (144 <= ly_in < 147))
late = [ly for ly in worked if ly < 144]
check("UpdateUI finishes inside VBlank on every frame it draws",
      len(worked) > 500 and not late and max(worked) <= 151,
      f"{len(worked)} frames, {len(late)} late, worst exit LY {max(worked)}")
check("frames skipped for entering VBlank too late are rare", skipped <= 0.02 * len(frames),
      f"{skipped} of {len(frames)}")

pb.stop(save=False)
print("\nALL PASSED" if not fails else f"\n{fails} FAILED")
sys.exit(1 if fails else 0)
