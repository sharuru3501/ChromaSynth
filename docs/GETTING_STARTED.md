# Getting started with ChromaSynth

ChromaSynth is a ROM: you put it on a Game Boy Color cartridge and play it on a Chromatic (or any Game Boy Color compatible machine). Everything in **Part A** needs nothing but the cartridge. **Part B** (playing it from a DAW, recording its sequencer into a DAW) is optional, needs a Mac, and needs a patched firmware in the Chromatic's built-in ESP32, which you flash **at your own risk**.

Japanese version: [GETTING_STARTED.ja.md](GETTING_STARTED.ja.md). How to use the synthesizer itself: [MANUAL.en.md](MANUAL.en.md).

## Part A. Use it on a cartridge

### What you need
- A machine that runs Game Boy Color software (the Chromatic does). An original Game Boy (DMG) does **not** work.
- A writable cartridge or flash cart. **MBC5 + RAM + battery** is recommended ([CARTRIDGES.md](CARTRIDGES.md), in Japanese, explains the mappers).
- Pick the ROM that fits the cartridge's SRAM (battery-backed save memory):

| ROM (from the [Releases](https://github.com/sharuru3501/ChromaSynth/releases) page) | cartridge SRAM | saved songs |
|---|---|---|
| `chromasynth-v0.1.0-sram32k.gb` | 32 KB or more | 4 |
| `chromasynth-v0.1.0-sram8k.gb` | 8 KB | 1 |

Playing, programming and sound design are the same in both; only the number of saved songs differs. Do not put the 32 KB ROM on an 8 KB cartridge (saves in slots 2-4 would overwrite slot 1).

### Steps
1. Download the ROM. Check it against `SHA256SUMS.txt` (`shasum -a 256 <file>`).
2. Write it to your cartridge with the tool for your cartridge or flash cart (this project does not provide one). **Saving writes to the cartridge's SRAM. Do not use a cartridge whose save data you want to keep** (a game's save would be overwritten; ChromaSynth refuses to write over data that is not its own and shows `SLOT IN USE`).
3. Power on. You see the **Play screen**. Press **A**: a note sounds.
4. Continue with the first five minutes in [MANUAL.en.md](MANUAL.en.md).

## Part B. Play and record with a DAW (Mac, optional)

What this gives you: the Chromatic shows up in your DAW as a MIDI port named `ChromaSynth`. You can play the Chromatic's synthesizer from the DAW's keyboard or clips, record the Chromatic's sequencer into the DAW as four MIDI tracks, and let the DAW start/stop and set the tempo of the sequencer. It works over Bluetooth (no cable) or USB-C.

```
DAW <-> ChromaSynth Link (Mac app) <-> Bluetooth or USB-C <-> ESP32 in the Chromatic <-> ChromaSynth ROM
```

**Known problem**: over Bluetooth, part of the sequencer's clock and notes arrive late or get lost, so a recording can sound uneven. Playing the Chromatic from the DAW is much less affected. To record the *sound*, use the Chromatic's USB audio instead. See `docs/M15_DESIGN.md`, section 10.

### B1. The Chromatic's ESP32 firmware (once)
The stock firmware cannot talk to the ROM. This project patches ModRetro's open firmware ([oss-chromatic-console-mcu](https://github.com/ModRetro/oss-chromatic-console-mcu), v4.6, GPL-3.0); the patches are in `chromatic-mcu/`.
- **If a flash goes wrong, the Chromatic may need its stock firmware restored. You do it at your own risk.** Read [MCU_FLASH_SAFETY.md](MCU_FLASH_SAFETY.md) (Japanese) first, back up the stock firmware, and rehearse the restore before you flash.
- Build: `chromatic-mcu/build.sh` (needs ESP-IDF v5.3). Flash: `chromatic-mcu/flash.sh <image> <first 16 hex digits of its sha256>` (writes only the application slot, checks before and after).
- The author has tested the patched firmware on one Chromatic only.

### B2. The Mac app (ChromaSynth Link)
A small menu-bar app that connects to the Chromatic (Bluetooth or USB, automatically) and gives the DAW the MIDI ports. No ready-made app is distributed yet; you build it:
```bash
xcode-select --install          # once: gives you swiftc
git clone https://github.com/sharuru3501/ChromaSynth.git
cd ChromaSynth
tools/mac/build_app.sh
open build/ChromaSynthLink.app
```
- The app is not signed. If macOS refuses to open it, right-click it and choose Open.
- Allow Bluetooth when asked. Use the menu-bar item (`♪●` connected, `♪○` not connected) to see the state, and "Open at login" if you want it always running.
- Do **not** also pair the Chromatic in "Audio MIDI Setup": every note would sound twice.
- More about the app: [MAC_APP.md](MAC_APP.md) (Japanese).

### B3. Chromatic side
1. Open the Chromatic's menu: **System > MIDI MODE**, choose **BLE** or **USB**. The choice is remembered. (OFF lets the ESP32 sleep to save battery.)
2. In ChromaSynth, go to the **Keyboard screen** (START+→ from the Sequencer). Notes from the DAW only arrive while this screen is shown.
3. For USB: connect the USB-C cable to the Mac; the app switches to USB by itself.

### B4. Play it from a DAW (example: Ableton Live)
1. Live > Settings > Tempo & MIDI: in the **Output** list, `ChromaSynth` appears. Turn its **Track** on.
2. Make a MIDI track, set its **MIDI To** to `ChromaSynth`, and play or arm it. The notes sound on the Chromatic.
3. Which MIDI channel plays which Game Boy channel is set on the PATCH screen's MIDI page (default: MIDI channels 1-4 play CH1-CH4).

### B5. Record the Chromatic's sequencer into the DAW
1. ChromaSynth, PATCH screen, MIDI page: set **SYNC = 1** (OUT), press **SELECT+B** to save it.
2. Live > Settings > Tempo & MIDI: in the **Input** list, turn on **Track** *and* **Sync** for `ChromaSynth`.
3. Make four MIDI tracks: **MIDI From = `ChromaSynth`**, channel **Ch. 1 / 2 / 3 / 4**, **MIDI To = No Output**, **Monitor = In**. Arm all four (Cmd-click the arm buttons). Turn **EXT** on (top left).
4. On the Chromatic, show the Keyboard screen and press **SELECT+START** to play. Live starts recording; stopping the Chromatic stops Live. The takes land in the Arrangement view.

### B6. Let the DAW drive the sequencer
SYNC = **3** (FOLLOW). Live > Settings > Tempo & MIDI > **Output** list: turn **Sync** on for `ChromaSynth`. Live's play/stop starts/stops the sequencer, Live's tempo sets the BPM, program change 0-3 selects pattern 1-4, CC20 / CC21 / CC10 move duty-or-wave / volume / pan. (Program change and CC are not yet tested on hardware.)

### When something does not work
| symptom | try |
|---|---|
| The DAW has no `ChromaSynth` port | the app must be running; quit and reopen the DAW after starting the app |
| Notes arrive (the Chromatic's screen shows them) but the DAW's instrument is silent | track **Monitor = In**; a track that is playing a clip does not pass live input when Monitor is Auto; in Preferences > Tempo & MIDI no control-surface slot should use the `ChromaSynth` port |
| Everything seems right but nothing reaches the DAW | restart the Mac (once, a stuck CoreMIDI state was the cause), then start the app first and the DAW second |
| Notes sound twice | `ChromaSynth` is also paired in Audio MIDI Setup, or the DAW plays the keyboard and the app plays it directly ("Play MIDI keyboards directly" in the app menu) |
| Nothing sounds on the Chromatic | ROM must be on the Keyboard screen; MIDI MODE must not be OFF |
