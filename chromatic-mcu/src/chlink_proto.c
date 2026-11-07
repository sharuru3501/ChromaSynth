#include "chlink_proto.h"

enum
{
    BTN_START = 1 << 0,
    BTN_B = 1 << 2,
    BTN_A = 1 << 3,
    BTN_UP = 1 << 4,
    BTN_LEFT = 1 << 6,
    BTN_DOWN = 1 << 7,
};

uint16_t chl_buttons(int phase, uint8_t data)
{
    uint16_t m = (phase == 0) ? BTN_UP : BTN_DOWN;
    if (data & 1) m |= BTN_A;
    if (data & 2) m |= BTN_B;
    if (data & 4) m |= BTN_START;
    if (data & 8) m |= BTN_LEFT;
    return m;
}

// Sum mod 15 (not & 15): every single changed bit (1, 2, 4, 8) must change the check.
static uint8_t check(const uint8_t *nibbles, int n)
{
    unsigned sum = 0;
    for (int i = 0; i < n; i++) sum += nibbles[i];
    return (uint8_t)(sum % 15);
}

void chl_encode_play(int on, int note, int vel127, uint8_t out[CHL_PLAY_SYMBOLS])
{
    int vel = vel127 >> 4;
    if (vel < 0) vel = 0;
    if (vel > 7) vel = 7;
    out[0] = (uint8_t)(((on ? 1 : 0) << 2) | ((note >> 5) & 3));
    out[1] = (uint8_t)((note >> 1) & 15);
    out[2] = (uint8_t)(((note & 1) << 3) | vel);
    out[3] = check(out, 3);
}

void chl_encode_release(int ping, uint8_t out[CHL_RELEASE_SYMBOLS])
{
    const uint8_t x = ping ? 1 : 0;
    out[0] = (uint8_t)(8 | x);
    out[1] = (uint8_t)(7 ^ x);
}

int chl_verify_ack(const chl_slot_t *slot, int last_phase)
{
    return slot->nack == 0 && slot->ack == (last_phase ? 1 : 0);
}

void chl_encode_general(uint8_t b0, uint8_t b1, uint8_t b2, uint8_t out[CHL_GENERAL_SYMBOLS])
{
    out[0] = (uint8_t)(8 | (b0 >> 5));
    out[1] = (uint8_t)((b0 >> 1) & 15);
    out[2] = (uint8_t)(((b0 & 1) << 3) | (b1 >> 5));
    out[3] = (uint8_t)((b1 >> 1) & 15);
    out[4] = (uint8_t)(((b1 & 1) << 3) | (b2 >> 5));
    out[5] = (uint8_t)((b2 >> 1) & 15);
    out[6] = (uint8_t)((b2 & 1) << 3);
    uint8_t body[7];
    for (int i = 0; i < 7; i++) body[i] = out[i];
    body[0] &= 7;  // the type bit is not part of the check
    out[7] = check(body, 7);
}

void chl_slot_from_gpd(const uint8_t gpd[8], chl_slot_t *out)
{
    const uint8_t header = gpd[0];
    out->len = (header >> 5) & 3;
    out->seq = (header >> 2) & 7;
    out->ack = (header >> 1) & 1;
    out->nack = header & 1;
    out->data[0] = gpd[3];
    out->data[1] = gpd[2];
    out->data[2] = gpd[1];
}

chl_rom_state_t chl_classify(const chl_slot_t *slot)
{
    if (slot->len == 3)
    {
        if (slot->data[0] == 0xF4) return CHL_ROM_KBD;
        if (slot->data[0] == 0xF5) return CHL_ROM_LEFT;
    }
    return CHL_ROM_OTHER;
}

int chl_link_alive(const chl_slot_t *slot, int last_phase)
{
    return chl_classify(slot) == CHL_ROM_OTHER && chl_verify_ack(slot, last_phase);
}

static int data_bytes(uint8_t status)
{
    if (status >= 0xF8) return 0;
    if (status >= 0xF0) return -1;           // system common / SysEx: not handled
    const uint8_t hi = status & 0xF0;
    return (hi == 0xC0 || hi == 0xD0) ? 1 : 2;
}

int chl_blemidi_parse(const uint8_t *p, unsigned len, chl_midi_cb_t cb, void *ctx)
{
    if (len < 1 || !(p[0] & 0x80)) return 0;   // the header has bit 7 set
    int count = 0;
    int expect_ts = 1;       // a timestamp byte comes before every message
    uint8_t status = 0;      // running status (cleared by the end of the packet and by system messages)
    uint8_t data[2] = {0, 0};
    int have = 0, need = 0;  // data bytes of the message in progress
    int in_sysex = 0;
    for (unsigned i = 1; i < len; i++)
    {
        const uint8_t b = p[i];
        if (in_sysex)
        {
            if (b & 0x80)
            {
                if (b == 0xF7) { in_sysex = 0; expect_ts = 1; }
                else if (b < 0xF8) { in_sysex = 0; expect_ts = 1; i--; continue; }   // aborted by a new message
            }
            continue;
        }
        if (expect_ts)
        {
            if (b & 0x80) { expect_ts = 0; continue; }    // the timestamp
            // a data byte with no timestamp: running status
            if (!status) continue;
        }
        else if (b & 0x80)
        {
            // a status byte
            if (b == 0xF0) { in_sysex = 1; status = 0; continue; }
            const int d = data_bytes(b);
            if (d < 0) { status = 0; expect_ts = 1; continue; }
            if (d == 0)
            {
                if (cb) cb(ctx, b, 0, 0);
                count++;
                expect_ts = 1;
                continue;
            }
            status = b;
            need = d;
            have = 0;
            continue;
        }
        // a data byte for `status`
        if (!status) continue;
        if (have == 0 && need == 0) need = data_bytes(status);   // running status: a new message
        data[have++] = b;
        if (have == need)
        {
            if (cb) cb(ctx, status, data[0], need > 1 ? data[1] : 0);
            count++;
            have = 0;
            need = 0;
            expect_ts = 1;
        }
    }
    return count;
}

chl_action_t chl_midi_action(uint8_t status, uint8_t d1, uint8_t d2, uint8_t *note, uint8_t *vel)
{
    const uint8_t hi = status & 0xF0;
    if (hi == 0x90 && d2 > 0)
    {
        *note = d1;
        *vel = d2;
        return CHL_ACT_NOTE_ON;
    }
    if (hi == 0x80 || hi == 0x90)
    {
        *note = d1;
        *vel = 0;
        return CHL_ACT_NOTE_OFF;
    }
    if (hi == 0xB0 && (d1 == 123 || d1 == 120)) return CHL_ACT_ALL_OFF;
    return CHL_ACT_IGNORE;
}

int chl_coalesce(chl_cmd_t *cmds, int n)
{
    int out = 0;
    for (int i = 0; i < n; i++)
    {
        int drop = 0;
        if (cmds[i].kind == CHL_CMD_PLAY && cmds[i].a == 0)
        {
            for (int j = i + 1; j < n; j++)
                if (cmds[j].kind == CHL_CMD_PLAY && cmds[j].a != 0) { drop = 1; break; }
        }
        if (!drop) cmds[out++] = cmds[i];
    }
    return out;
}
