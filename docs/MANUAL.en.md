# ChromaSynth manual

Buttons: D-pad (Up/Down/Left/Right), A, B, START, SELECT. Japanese version: [MANUAL.md](MANUAL.md). Setup: [GETTING_STARTED.md](GETTING_STARTED.md).

## Your first five minutes
1. **Play screen**: press **A** to hear the selected channel. D-pad Left/Right = semitone, Up/Down = octave. **SELECT** (tap) = next channel (CH1 pulse, CH2 pulse, CH3 wave, CH4 noise).
2. **START+Right** goes to the **PATCH screen** (sound design). Up/Down picks a parameter, Left/Right changes the value, **A** auditions it. Try DUTY on CH1.
3. **START+Right** again: the **Sequencer** (piano roll). Move the cursor with the D-pad, **A** places a note, **B** deletes it. **SELECT+START** plays / stops, **SELECT+Up/Down** changes the BPM. A demo pattern is there at the start.
4. Save: go back to the Play screen (START+Left) and press **SELECT+B**. A song is saved to the current slot. **SELECT+A** loads it.

## Screens and moving between them
The screens are in a line: **Play <-> PATCH <-> Sequencer <-> Keyboard**. START+Right / START+Left moves along it (keep START held and press Left/Right again to go further). START alone does nothing. Two more screens open from the first three: **START+Down = Slot list**, **START+Up = Song screen**; START+Up / START+Down comes back.

| keys | action (everywhere unless noted) |
|---|---|
| START+Right / START+Left | next / previous screen |
| SELECT (tap) | next channel (on PATCH: after CH4 comes the MIDI page) |
| SELECT+START | play / stop the sequencer |
| START+Down | Slot list (from Play, PATCH, Sequencer) |
| START+Up | Song screen (from Play, PATCH, Sequencer) |
| SELECT+Left/Right (Play) | choose save slot 1-4 |
| SELECT+B | save to the current slot |
| SELECT+A | load the current slot |

## Saving
A **song** = the sound settings, 4 patterns, the order of patterns, BPM, loop length, 4 custom waves, per-pattern time signatures. It is saved to the cartridge's SRAM: **4 slots** (32 KB build) or **1 slot** (8 KB build); one song is 8 KB.
- The Play screen's `SLOT n` row shows the current slot and `USED` / `FREE`.
- **Slot list** (START+Down): Up/Down chooses a slot, **A loads, B saves**. Under the list is the song's **name** (8 characters: space, A-Z, 0-9, `-`): Left/Right moves the cursor, **SELECT+Up/Down** changes the letter. The name is saved with the song (press B).
- Saving over a used slot shows `AGAIN:OVERWRITE`: repeat the same key within about 1.5 seconds to confirm.
- A slot that holds data that is not ChromaSynth's (for example another game's save) is never written: `SLOT IN USE`.
- The last line shows `SAVED n` / `LOADED n` / `NO SAVE DATA n` / `SAVE FAILED n`. At start-up slot 1 is loaded if it has a song. **There is no autosave.** Saving freezes screen and sound for about 0.3 s.

## Play screen
**A** plays the selected channel (release to stop). Left/Right = semitone, Up/Down = octave. The screen shows what each channel is playing and the MIDI bytes received.

## Keyboard screen
For notes from a DAW (through the Chromatic's ESP32). Buttons are ignored here so you cannot play by accident: **START+Left** leaves, **SELECT** = next channel, **SELECT+START** = play/stop. A `BPM nnn   SYNC n` row shows the tempo and the SYNC mode. Setup: [GETTING_STARTED.md](GETTING_STARTED.md).

## PATCH screen (sound design)
Changes take effect at the **next note** (PAN, VIBD/VIBS and the master volume VOLL/VOLR are immediate).

| keys | action |
|---|---|
| Up / Down | choose a parameter row (pages of 8 rows, `P1`/`P2`/`P3` at the top right) |
| Left / Right | value -1 / +1 |
| SELECT+Up / SELECT+Down | value +10 / -10 |
| A | audition |
| B held + D-pad | change the audition pitch |
| SELECT (tap) | next channel |

**Common parameters** (range in brackets; 0 = off where noted)

| name | meaning | channels |
|---|---|---|
| DUTY | pulse width: 0 = 12.5 %, 1 = 25 %, 2 = 50 %, 3 = 75 % (0-3) | CH1 CH2 |
| WAVE | CH3 waveform: 0 square, 1 saw, 2 triangle, 3 sine, **4-7 = your own waves W1-W4** (0-7) | CH3 |
| LVL | CH3 volume: 0 = 100 %, 1 = 50 %, 2 = 25 % (0-2) | CH3 |
| WDTH | noise width: 0 = 15-bit (rough noise), 1 = 7-bit (metallic, pitched) | CH4 |
| VOL | start volume (0-15) | CH1 CH2 CH4 |
| EDIR | envelope direction: 0 = fade out, 1 = fade in | CH1 CH2 CH4 |
| EPAC | envelope speed: 1 fast ... 7 slow, **0 = no change** (0-7) | CH1 CH2 CH4 |
| LEN | note length: **0 = until the key is released**, otherwise the chip stops it (CH1/2/4: 1-64, CH3: 1-255) | all |
| PAN | 0 = both sides, 1 = left, 2 = right | all |
| VIBD / VIBS | vibrato depth (**0 = off**) / speed (0-7); the MIDI mod wheel (CC1) also raises the depth | CH1-3 |

**Page 2, CH1 sweep** (the chip's automatic pitch slide): SWT = interval (**0 = no sweep**), SWD = direction (0 down, 1 up), SWS = amount per step (bigger = smaller change).
**CH4**: NDIV = noise divider (small = high noise like a hi-hat, large = low like a bass drum).
**Page 3 (CH1-3)**, units are frames (about 1/60 s): ARP1, ARP2 = **arpeggio** (root, root+ARP1, root+ARP2 semitones; both 0 = off; a major chord is 4 and 7, minor 3 and 7), ARPS = frames per step; SLID = **slide/portamento** between notes (0 off, 1 fast ... 7 slow); DUT2 + DSPD = alternate DUTY and DUT2 every DSPD frames (CH1/CH2 only, 0 = off; does not work while LEN is used).

**MIDI page** (after CH4 with SELECT)

| name | meaning |
|---|---|
| CH1-CH4 | the MIDI channel each Game Boy channel listens to (0 = off, 1-16; default 1, 2, 3, 4; the same number on two channels makes chords) |
| BEND | pitch-bend range in semitones (default 2) |
| VELO | 1 = velocity changes the volume |
| MODW | 1 = mod wheel changes vibrato depth |
| SYNC | **0 = off, 1 = OUT** (the Chromatic is the master: sends notes, clock, start/stop to the DAW), **2 = IN** (a cable clock drives the sequencer), **3 = FOLLOW** (the DAW starts/stops it and sets the tempo; program change picks the pattern) |
| BEAT / UNIT | time signature of the edited pattern: numerator 1-16, denominator 4 / 8 / 16 |
| VOLL / VOLR | master volume left / right (0-7) |

**Wave editor** (CH3, WAVE 4-7): select WAVE and press **START+A**; **START+B** returns. W1-W4 (WAVE 4-7) are editable, the presets (WAVE 0-3) are view-only. A waveform is 32 samples of 4 bits (0-15). Left/Right chooses a sample, Up/Down changes it by 1 (B held: 4), **A** plays it, **START+A** copies the next preset (square, saw, triangle, sine) into the wave being edited. Waves are saved with the song; they are written at the next note.

## Sequencer screen (piano roll)
1 beat = 12 ticks. The top-left tab is the channel (`1P` ...), the top-right tab `P1`-`P4` is the pattern being edited, `L2` at the right of the status line is the loop length in bars.

| keys | action |
|---|---|
| D-pad | move the cursor one cell / one semitone (repeats when held) |
| B held + D-pad | move 4 cells / one octave |
| A | place a note of one cell at the cursor (and audition it) |
| A held + Left/Right | make the note shorter / longer (the cursor follows its end; the page turns when you go past the edge) |
| A held + Up/Down | transpose the note |
| B (tap) | delete the note under the cursor |
| B+A | change the grid division (1/4, 1/4T, 1/8, 1/8T, 1/16, 1/16T, 1/48 ...; T = triplet) |
| SELECT held + Up/Down | BPM +1 / -1 |
| SELECT held + Left/Right | loop length -1 / +1 bar |
| START held + A / B | edit the next / previous pattern (P1-P4; while playing it switches at the start of the next bar) |
| SELECT (tap) | next channel |
| SELECT+START | play / stop |

A page holds a whole number of bars. A note placed after the end of the loop extends the loop (up to 8 bars). Notes may cross the 4-bar boundary when played. You can edit sounds on the other screens while it plays. Triplets: B+A until 1/8T, then A, Right, Right, A, Right, Right, A.

## Song screen (patterns in a chain)
- **Patterns P1-P4** are boxes of notes (4 channels, up to 8 bars). The Sequencer edits **the pattern chosen as `EDIT`** here.
- The **chain** (`ORDER STEP:PATTERN`, 16 steps) is the order in which patterns play. Each cell plays one pattern once; `-` ends the chain, which then repeats. `1 1 2 1 -` plays P1, P1, P2, P1. During SONG playback the playing step is shown as `[1]`.

| keys | action |
|---|---|
| D-pad | move in the chain (Left/Right one step, Up/Down one row of 6) |
| A / B | pattern of this step +1 / -1 (1, 2, 3, 4, `-`) |
| SELECT+Left/Right | choose the pattern to edit (P1-P4) |
| SELECT+Up/Down | MODE: LOOP (repeat the edited pattern) / SONG (play the chain) |
| START+Up / START+Down | open / return |

While playing in LOOP mode, choosing another `EDIT` pattern switches to it at the start of the next bar (`PLAY P1` / `NEXT P2` shows it), like launching clips.

## Time signatures
Each pattern has its own time signature and number of bars (PATCH > MIDI page: BEAT/UNIT; loop length with SELECT+Left/Right). Notes are stored by tick, so changing the signature later never moves or breaks notes; only bar lines and the loop end move. BPM always counts quarter notes. Not supported: a change inside one pattern, denominators 2 and 32+, numerators above 16.
