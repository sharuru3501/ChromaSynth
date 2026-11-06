#pragma once
// The MIDI mode of the Chromatic: OFF (nothing runs, the ESP32 light-sleeps as stock), BLE (Bluetooth MIDI), USB (notes
// from a Mac helper over the USB-C serial port). Chosen from the console (`mode`) or from the OSD menu (System > MIDI MODE).
// It always starts as OFF. See docs/BLE_MIDI.md.
#include <stdbool.h>
#include <stdint.h>

typedef enum { CHM_OFF = 0, CHM_BLE = 1, CHM_USB = 2, CHM_COUNT } ChMidiMode;

void ChMode_Init(void);                    // creates the mode task and registers `mode` and `m`
void ChMode_Request(ChMidiMode mode);      // thread-safe; applied by the mode task (starting BLE needs a big stack)
ChMidiMode ChMode_Get(void);               // the mode last requested (what the menu shows)
const char *ChMode_Name(ChMidiMode mode);
