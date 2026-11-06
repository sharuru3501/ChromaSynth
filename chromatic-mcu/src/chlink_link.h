#pragma once
// Cable-less link to the ROM: sends notes as virtual-button symbols. See docs/CHROMATIC_LINK.md, docs/BLE_MIDI.md.
#include <stdbool.h>
#include <stdint.h>

void ChLinkLink_Start(void);   // creates the link task and registers the console commands
// Thread-safe; they only queue work. The task drops them unless the ROM is on its keyboard screen
// (auto mode, the default) or the link was forced on (`link on`).
bool ChLinkLink_Note(bool on, uint8_t note, uint8_t vel127);
bool ChLinkLink_Midi(uint8_t b0, uint8_t b1, uint8_t b2);
