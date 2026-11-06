/* Bridge core: see bridge_core.h. A port of tools/bridge_ref.py -- keep the two in step. */
#include "bridge_core.h"

#include <string.h>

#define GB_MASK (BR_TO_GB_CAP - 1u)

void bridge_init(bridge_t *b)
{
    memset(b, 0, sizeof(*b));
}

/* ------------------------------------------------------------------ to the GB */

static uint16_t gb_used(const bridge_t *b)
{
    return (uint16_t)((b->gb_head - b->gb_tail) & GB_MASK);
}

size_t bridge_to_gb_count(const bridge_t *b)
{
    return gb_used(b);
}

/* Queue a whole message or nothing: a half message would confuse the ROM's parser. */
static void push_msg(bridge_t *b, const uint8_t *msg, uint8_t n)
{
    if (BR_TO_GB_CAP - 1u - gb_used(b) < n) {
        b->gb_dropped++;
        return;
    }
    for (uint8_t i = 0; i < n; i++) {
        b->gb_q[b->gb_head] = msg[i];
        b->gb_head = (uint16_t)((b->gb_head + 1u) & GB_MASK);
    }
}

bool bridge_to_gb_pop(bridge_t *b, uint8_t *out)
{
    if (b->gb_head == b->gb_tail) {
        return false;
    }
    *out = b->gb_q[b->gb_tail];
    b->gb_tail = (uint16_t)((b->gb_tail + 1u) & GB_MASK);
    return true;
}

static void to_gb_clear(bridge_t *b)
{
    b->gb_tail = b->gb_head;
}

static uint8_t data_bytes(uint8_t status)
{
    return (status == 0xC0 || status == 0xD0) ? 1 : 2;
}

static void host_message(bridge_t *b)
{
    uint8_t msg[3];
    msg[0] = (uint8_t)(b->status | b->channel);
    msg[1] = b->data[0];
    msg[2] = b->data[1];
    uint8_t n = (uint8_t)(1 + b->ndata);
    switch (b->status) {
    case 0x80: /* note off */
    case 0x90: /* note on */
    case 0xE0: /* pitch bend */
        push_msg(b, msg, n);
        break;
    case 0xB0: /* control change: only CC1 (mod wheel), CC120/CC123 (all sound/notes off) */
        if (b->data[0] == 1 || b->data[0] == 120 || b->data[0] == 123) {
            push_msg(b, msg, n);
        }
        break;
    default: /* aftertouch, program change, channel pressure: not understood by the ROM */
        break;
    }
}

static void host_realtime(bridge_t *b, uint8_t x)
{
    switch (x) {
    case BR_CLOCK: /* 24 -> 12 per beat */
        if (b->clock_phase == 0) {
            push_msg(b, &x, 1);
        }
        b->clock_phase ^= 1u;
        break;
    case BR_START:
        b->clock_phase = 0; /* the first clock after start is tick 0 */
        push_msg(b, &x, 1);
        break;
    case BR_CONTINUE:
    case BR_STOP:
        push_msg(b, &x, 1);
        break;
    default: /* active sensing, system reset, undefined: dropped */
        break;
    }
}

static void host_byte(bridge_t *b, uint8_t x)
{
    if (x >= 0xF8) { /* realtime: allowed anywhere, never disturbs a message in progress */
        host_realtime(b, x);
        return;
    }
    if (x >= 0x80) { /* a status byte */
        if (x == 0xF0) {
            b->in_sysex = true;
            b->status = 0;
        } else if (x == 0xF7) {
            b->in_sysex = false;
            b->status = 0;
        } else if (x >= 0xF0) { /* other system common: not forwarded, cancels running status */
            b->status = 0;
        } else {
            b->in_sysex = false;
            b->status = (uint8_t)(x & 0xF0);
            b->channel = (uint8_t)(x & 0x0F);
        }
        b->ndata = 0;
        return;
    }
    if (b->in_sysex || b->status == 0) {
        return;
    }
    b->data[b->ndata++] = x;
    if (b->ndata == data_bytes(b->status)) {
        host_message(b);
        b->ndata = 0; /* running status: keep b->status */
    }
}

void bridge_host_in(bridge_t *b, const uint8_t *data, size_t len)
{
    for (size_t i = 0; i < len; i++) {
        host_byte(b, data[i]);
    }
}

/* ------------------------------------------------------------------ to the host */

/* Wrap-safe "a is later than b". */
static bool later(uint32_t a, uint32_t b)
{
    return (int32_t)(a - b) > 0;
}

static void schedule(bridge_t *b, uint32_t t, uint8_t byte)
{
    if (b->out_n >= BR_OUT_CAP) {
        b->out_dropped++;
        return;
    }
    uint8_t i = b->out_n;
    while (i > 0 && later(b->out[i - 1].t_us, t)) { /* stable: after entries with an equal time */
        b->out[i] = b->out[i - 1];
        i--;
    }
    b->out[i].t_us = t;
    b->out[i].byte = byte;
    b->out_n++;
}

void bridge_gb_in(bridge_t *b, uint8_t byte, uint32_t now_us)
{
    switch (byte) {
    case BR_IDLE:
        return;
    case BR_CLOCK: /* 12 -> 24 per beat: this tick, and one half an interval later */
        schedule(b, now_us, BR_CLOCK);
        if (b->have_last_tick) {
            uint32_t half = (now_us - b->last_tick_us) / 2u;
            if (half > 0 && half < BR_MAX_HALF_US) {
                schedule(b, now_us + half, BR_CLOCK);
            }
        }
        b->last_tick_us = now_us;
        b->have_last_tick = true;
        return;
    case BR_START:
    case BR_STOP:
    case BR_CONTINUE:
        if (byte != BR_CONTINUE) {
            b->have_last_tick = false; /* no tempo reference across a start/stop */
        }
        schedule(b, now_us, byte);
        return;
    default: /* channel messages arrive complete from the GB */
        schedule(b, now_us, byte);
        return;
    }
}

bool bridge_host_out_pop_due(bridge_t *b, uint32_t now_us, uint8_t *out)
{
    if (b->out_n == 0 || later(b->out[0].t_us, now_us)) {
        return false;
    }
    *out = b->out[0].byte;
    b->out_n--;
    memmove(&b->out[0], &b->out[1], (size_t)b->out_n * sizeof(b->out[0]));
    return true;
}

uint32_t bridge_host_out_next_in_us(const bridge_t *b, uint32_t now_us)
{
    if (b->out_n == 0) {
        return UINT32_MAX;
    }
    if (!later(b->out[0].t_us, now_us)) {
        return 0;
    }
    return b->out[0].t_us - now_us;
}

/* ------------------------------------------------------------------ the link */

br_link_step_t bridge_link_next(bridge_t *b)
{
    br_link_step_t s;
    if (!b->link_up) {
        to_gb_clear(b); /* do not hoard input for a GB that is not there */
        s.tx = BR_IDLE;
        s.wait_us = BR_LINK_DOWN_POLL_US;
        s.data = false;
        return s;
    }
    uint8_t x;
    if (bridge_to_gb_pop(b, &x)) {
        s.tx = x;
        s.wait_us = BR_GAP_US;
        s.data = true;
        return s;
    }
    s.tx = BR_IDLE;
    s.wait_us = BR_IDLE_POLL_US - BR_BYTE_US;
    s.data = false;
    return s;
}

void bridge_link_rx(bridge_t *b, uint8_t reply, uint32_t now_us)
{
    if (reply == BR_NOT_READY) {
        if (b->link_up) {
            b->link_down_events++;
        }
        b->link_up = false;
        return;
    }
    if (!b->link_up) {
        b->link_up = true;
        to_gb_clear(b); /* whatever piled up while it was away is stale */
    }
    bridge_gb_in(b, reply, now_us);
}
