#pragma once
// Cable-less link to the ROM: sends notes as virtual-button symbols. See docs/CHROMATIC_LINK.md, docs/BLE_MIDI.md.
#include <stdbool.h>
#include <stdint.h>

void ChLinkLink_Start(void);   // creates the link task and registers the console commands
// Thread-safe; they only queue work. The task drops them unless the ROM is on its keyboard screen
// (auto mode, the default) or the link was forced on (`link on`).
bool ChLinkLink_Note(bool on, uint8_t note, uint8_t vel127);
bool ChLinkLink_Release(void);   // queue a note-off for the note that sounds (used when the MIDI source goes away)
bool ChLinkLink_Midi(uint8_t b0, uint8_t b1, uint8_t b2);
// The MIDI mode turns the link on (auto: sends only while the ROM shows the keyboard screen) or off (nothing is
// sent, nothing is polled, queued notes are dropped), so that the ESP32 can light-sleep again.
void ChLinkLink_SetEnabled(bool on);
// Uplink (docs/M15_DESIGN.md): the ROM's MIDI out (SYNC = OUT: clock, start/stop, the sequencer's notes) read from the slot.
// The handler runs in the link task for every new message (1-3 bytes) with the time it was read. It is only called while the
// link is armed and the uplink is on (SetUp): BLE turns it on when the Mac subscribes to the notifications, USB with `up on`.
typedef void (*ChLinkUpHandler)(const uint8_t *msg, int len, int64_t t_us);
void ChLinkLink_SetUpHandler(ChLinkUpHandler handler);
void ChLinkLink_SetUp(bool on);
uint32_t ChLinkLink_StackFree(void);   // the least free stack the link task has ever had, in bytes
