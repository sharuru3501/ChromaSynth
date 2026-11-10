#pragma once
// Cable-less link protocol, MCU side. Pure C (no ESP-IDF), so the host can test it against
// tools/chromatic_link_ref.py. The arithmetic must stay identical to that file and to
// src/clink.asm / src/joy.asm in the ROM. See docs/CHROMATIC_LINK.md.
#include <stdint.h>

#define CHL_PLAY_SYMBOLS 4
#define CHL_GENERAL_SYMBOLS 8
#define CHL_RELEASE_SYMBOLS 2
#define CHL_PAD 0xFE   // pads MIDI messages shorter than 3 bytes

// Phase of a symbol: 0 = A (UP held), 1 = B (DOWN held). Data bits: 0 A, 1 B, 2 START, 3 LEFT.
// Returns the value for the FPGA's MCU_buttons register (bit 0 START, 1 SELECT, 2 B, 3 A, 4 UP,
// 5 RIGHT, 6 LEFT, 7 DOWN). SELECT and RIGHT are never pressed.
uint16_t chl_buttons(int phase, uint8_t data);

// Mono keyboard note on the ROM's selected channel: 4 symbols. vel127 is MIDI 0..127.
void chl_encode_play(int on, int note, int vel127, uint8_t out[CHL_PLAY_SYMBOLS]);
// Release (ping = 0: stop the note of the last note-on) or ping (ping = 1: only keeps the link up): 2 symbols, the pair is
// its own check, and neither can start a note.
void chl_encode_release(int ping, uint8_t out[CHL_RELEASE_SYMBOLS]);
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
// After a packet: 1 if the ROM accepted the last symbol sent (slot ack == its phase) and did not nack, else 0.
int chl_verify_ack(const chl_slot_t *slot, int last_phase);

// ---------------------------------------------------------------- ROM beacons (docs/BLE_MIDI.md section 3)
// While the ROM is on its KEYBOARD screen and not linked it writes the slot {B0 = $F4, len = 3}; when it
// leaves that screen it writes {B0 = $F5, len = 3} once. Nothing else ever puts these statuses in the slot.
// The MCU only sends symbols while it sees the first, or a linked slot.
typedef enum
{
    CHL_ROM_OTHER = 0,    // a normal slot (linked) or anything the ROM did not write as a beacon
    CHL_ROM_KBD = 1,      // keyboard screen, not linked yet: send sync + HELLO
    CHL_ROM_LEFT = 2      // the ROM left the keyboard screen: stop sending
} chl_rom_state_t;

chl_rom_state_t chl_classify(const chl_slot_t *slot);

// ---------------------------------------------------------------- uplink: the ROM's MIDI out (docs/M15_DESIGN.md)
// When the ROM is linked and its SYNC is OUT it puts one MIDI message (1-3 bytes: clock, start/stop, notes) into the slot per
// frame and advances `seq` (0..7). Returns the length of a NEW message (copied to out) or 0: nothing new, a beacon, an empty
// slot. *last_seq = 0xFF before the first call: the first slot seen is only remembered (it may be old). A seq jump of more than
// one means messages were lost between two reads; the newest one is the one that is returned.
int chl_up_decode(const chl_slot_t *slot, uint8_t *last_seq, uint8_t out[3]);
// Before a keep-alive: 1 if the slot is still that of the ROM the MCU linked with (no beacon, the ack of the MCU's last
// symbol, no nack). Anything else (another or a reset ROM, a stray symbol): stop instead of pressing buttons in a game.
int chl_link_alive(const chl_slot_t *slot, int last_phase);

// ---------------------------------------------------------------- BLE MIDI packets (docs/BLE_MIDI.md section 2)
typedef void (*chl_midi_cb_t)(void *ctx, uint8_t status, uint8_t d1, uint8_t d2);
// Parses one BLE MIDI packet (header, timestamps, messages, running status inside the packet,
// SysEx skipped) and calls cb for every complete channel/system message. Timestamps are ignored.
// Returns the number of messages. Garbage never crashes; it is skipped.
int chl_blemidi_parse(const uint8_t *pkt, unsigned len, chl_midi_cb_t cb, void *ctx);

typedef enum
{
    CHL_ACT_IGNORE = 0,
    CHL_ACT_NOTE_ON = 1,
    CHL_ACT_NOTE_OFF = 2,
    CHL_ACT_ALL_OFF = 3,
    CHL_ACT_FORWARD = 4   // sent on as a general packet: MIDI start/continue/stop, program change, CC 10 / 14 / 15 / 20 / 21 (docs/M15_DESIGN.md)
} chl_action_t;

// MIDI message -> what the keyboard link does with it. The MIDI channel is ignored (omni).
chl_action_t chl_midi_action(uint8_t status, uint8_t d1, uint8_t d2, uint8_t *note, uint8_t *vel);

// ---------------------------------------------------------------- queue coalescing
typedef struct
{
    uint8_t kind;   // CHL_CMD_*
    uint8_t a, b, c;
    uint32_t t_us;  // when it was queued (the MCU's microsecond clock; only for latency statistics)
} chl_cmd_t;

enum { CHL_CMD_PLAY = 0, CHL_CMD_MIDI = 1, CHL_CMD_HELLO = 2, CHL_CMD_SYNC = 3, CHL_CMD_RELEASE = 4 };

// The ROM is mono: a note-off is ignored when a newer note has replaced the note it names, and a later
// note-on makes an earlier note-off pointless. Drops every PLAY note-off (a == 0) that has a later PLAY
// note-on in the list, keeping the order of the rest. Returns the new length.
int chl_coalesce(chl_cmd_t *cmds, int n);

// A message to forward as a general packet: the bytes it lacks are $FE (what the ROM's parser ignores): one byte for the realtime messages,
// two for the program change / channel pressure.
void chl_forward_bytes(uint8_t status, uint8_t d1, uint8_t d2, uint8_t out[3]);
