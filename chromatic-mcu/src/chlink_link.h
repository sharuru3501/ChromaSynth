#pragma once
// Cable-less link to the ROM: sends notes as virtual-button symbols. See docs/CHROMATIC_LINK.md.
#include <stdbool.h>
#include <stdint.h>

void ChLinkLink_Start(void);   // creates the link task and registers the console commands
// Thread-safe; they only queue work. Nothing is sent while the link is off (`link on`).
bool ChLinkLink_Note(bool on, uint8_t note, uint8_t vel127);
bool ChLinkLink_Midi(uint8_t b0, uint8_t b1, uint8_t b2);
