# ChromaSynth

A **synthesizer + piano-roll sequencer** ROM for the **ModRetro Chromatic** (Game Boy / Game Boy Color compatible handheld). Make a sound, program a pattern, play it on the Chromatic. With the Chromatic's built-in ESP32 it can also be **played from a DAW such as Ableton Live over Bluetooth MIDI or USB-C**, and the sequencer can be **recorded into the DAW**.

> Status: a personal project in progress. What has been checked on real hardware (Chromatic + EMS 64M smart card) is listed in the status column of [docs/ROADMAP.md](docs/ROADMAP.md) (in Japanese). Unverified behaviour is never marked as verified. The project's own documents are mostly in Japanese; this page is the English entry point.
> **Cartridges**: built for ordinary **Game Boy Color cartridges** (MBC5 recommended, see [docs/CARTRIDGES.md](docs/CARTRIDGES.md)): the normal build needs 32 KB of SRAM (4 saved songs, `make`), the reduced build 8 KB (1 saved song, `make small`). The author uses an EMS smart card (`make card`); the ROM does not depend on it.
> **License**: MIT for the ROM, tools and Mac app; `chromatic-mcu/` (patches on ModRetro's MCU firmware) is GPL-3.0. See [docs/LICENSES.md](docs/LICENSES.md).

## What it does
- **ROM** (`src/`, RGBDS assembly): 4 channels (2 pulse, wave, noise), piano roll, patterns/songs saved to SRAM, 8-bar patterns with per-pattern time signature, custom waveforms.
- **Cable-less link** ([docs/CHROMATIC_LINK.md](docs/CHROMATIC_LINK.md)): the Chromatic's ESP32 sends notes to the ROM as virtual button presses; the ROM sends its notes, clock and tempo back through palette RAM.
- **Bluetooth MIDI / USB-C**: the menu-bar app **ChromaSynth Link** (`tools/mac/`, [docs/MAC_APP.md](docs/MAC_APP.md)) connects to the Chromatic and shows up in the DAW as the MIDI port `ChromaSynth`.
- **DAW follow** (`SYNC 3`): Start/Stop, tempo, program change (pattern) and CC from the DAW.
- **Recording**: the sequencer's four channels go to the DAW as MIDI channels 1-4 (`SYNC 1`), with the clock.

## Known problems
- Over BLE, part of the sequencer's clock and notes arrive late or never arrive, so the recorded rhythm can be uneven. The plan to fix it is in [docs/M15_DESIGN.md](docs/M15_DESIGN.md) section 10. Recording the audio over USB (the Chromatic shows up as a USB audio input) is not affected.

## Build and test
Needs RGBDS v1.0.x (ROM), Python 3 + PyBoy (headless tests), `swiftc` (Mac app), ESP-IDF v5.3 (MCU firmware, only if you change it).

```bash
make                  # ROM: build/chromasynth.gb (no warnings, header checked; 32 KB SRAM build)
make small            # 8 KB SRAM cartridges: build-8k/chromasynth.gb
make card             # the author's EMS card build (not for ordinary cartridges)
make gen              # regenerate the generated tables
python3 tools/headless_test.py     # ROM tests in PyBoy (pip install pyboy pillow)
make check-mcu        # the MCU's protocol core (C) against the Python reference
tools/mac/test.sh     # Mac app self test
```

## Hardware notes
- The MCU firmware lives in `chromatic-mcu/`. **Flashing the Chromatic's ESP32 or an EMS card is done at your own risk**: read [docs/MCU_FLASH_SAFETY.md](docs/MCU_FLASH_SAFETY.md) first and keep a backup.
- Never send SELECT+A / SELECT+B from the MCU on a shared-SRAM smart card (it overwrites the other game's save data).
