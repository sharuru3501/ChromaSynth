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
