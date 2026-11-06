#pragma once
// Cable-less link protocol, MCU side. Pure C (no ESP-IDF), so the host can test it against
// tools/chromatic_link_ref.py. The arithmetic must stay identical to that file and to
// src/clink.asm / src/joy.asm in the ROM. See docs/CHROMATIC_LINK.md.
#include <stdint.h>

#define CHL_PLAY_SYMBOLS 4
#define CHL_GENERAL_SYMBOLS 8
#define CHL_PAD 0xFE   // pads MIDI messages shorter than 3 bytes

// Phase of a symbol: 0 = A (UP held), 1 = B (DOWN held). Data bits: 0 A, 1 B, 2 START, 3 LEFT.
// Returns the value for the FPGA's MCU_buttons register (bit 0 START, 1 SELECT, 2 B, 3 A, 4 UP,
// 5 RIGHT, 6 LEFT, 7 DOWN). SELECT and RIGHT are never pressed.
uint16_t chl_buttons(int phase, uint8_t data);

// Mono keyboard note on the ROM's selected channel: 4 symbols. vel127 is MIDI 0..127.
void chl_encode_play(int on, int note, int vel127, uint8_t out[CHL_PLAY_SYMBOLS]);
// Three MIDI bytes: 8 symbols (use CHL_PAD for the missing bytes of short messages).
void chl_encode_general(uint8_t b0, uint8_t b1, uint8_t b2, uint8_t out[CHL_GENERAL_SYMBOLS]);

// What the ROM writes to OBJ palette 1 colours 1-2, as the 8 bytes of the FPGA's reply (gpd):
// bytes [0..3] = obpd[13], [12], [11], [10] = header, B2, B1, B0.
typedef struct
{
    uint8_t len;   // length of the message in the slot (0..3)
    uint8_t seq;   // 0..7, advances when the ROM puts a new message in the slot
    uint8_t ack;   // phase of the last symbol the ROM accepted
    uint8_t nack;  // the last packet failed its check
    uint8_t data[3];
} chl_slot_t;

void chl_slot_from_gpd(const uint8_t gpd[8], chl_slot_t *out);
