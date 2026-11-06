/*
 * Bridge core: the platform-independent logic of the MIDI <-> Game Boy link bridge.
 *
 * No hardware, no RTOS, no allocation: plain C11 so that it runs unchanged on the ESP32-S3 and in
 * the host tests (firmware/test). It is a line-by-line port of tools/bridge_ref.py, and
 * tools/gen_bridge_vectors.py records that model's behaviour as golden traces that the host
 * test replays against this code. Specification: docs/BRIDGE.md.
 *
 * NOT thread-safe. The firmware wraps every call in one mutex (see firmware/main/main.c).
 * All times are microseconds from any free-running 32-bit counter; comparisons are wrap-safe.
 */
#ifndef BRIDGE_CORE_H
#define BRIDGE_CORE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Link protocol bytes (docs/BRIDGE.md section 2) */
#define BR_IDLE      0xFD  /* "nothing to say", both directions */
#define BR_NOT_READY 0xFF  /* reply: the GB is not listening */
#define BR_CLOCK     0xF8
#define BR_START     0xFA
#define BR_CONTINUE  0xFB
#define BR_STOP      0xFC

/* Link timing */
#define BR_BIT_CLOCK_HZ      32000u
#define BR_BYTE_US           250u     /* 8 bits at 32 kHz */
#define BR_GAP_US            250u     /* pause after a byte: the ROM's serial ISR needs ~100 us */
#define BR_IDLE_POLL_US      2000u    /* start-to-start spacing of idle polls */
#define BR_LINK_DOWN_POLL_US 100000u
#define BR_MAX_HALF_US       250000u  /* no clock interpolation across a longer pause */

#define BR_TO_GB_CAP 512u  /* power of two; one slot stays empty */
#define BR_OUT_CAP   64u

typedef struct {
    uint32_t t_us;
    uint8_t byte;
} br_event_t;

typedef struct {
    /* host MIDI parser */
    uint8_t status;      /* status nibble << 4 of the running status, 0 = none */
    uint8_t channel;
    uint8_t data[2];
    uint8_t ndata;
    bool in_sysex;
    uint8_t clock_phase; /* host clocks since start: forward the 1st, 3rd, 5th... */

    /* bytes for the GB */
    uint8_t gb_q[BR_TO_GB_CAP];
    uint16_t gb_head, gb_tail;
    uint32_t gb_dropped; /* messages dropped because the queue was full */

    /* bytes for the host, sorted by time (interpolated clocks lie in the future) */
    bool have_last_tick;
    uint32_t last_tick_us;
    br_event_t out[BR_OUT_CAP];
    uint8_t out_n;
    uint32_t out_dropped;

    /* link state */
    bool link_up;
    uint32_t link_down_events;
} bridge_t;

typedef struct {
    uint8_t tx;       /* the byte to clock out next */
    uint32_t wait_us; /* how long to wait after it has been shifted out */
    bool data;        /* false = idle filler */
} br_link_step_t;

void bridge_init(bridge_t *b);

/* host -> GB. Feed raw MIDI bytes in any chunking; complete, supported messages are queued. */
void bridge_host_in(bridge_t *b, const uint8_t *data, size_t len);
size_t bridge_to_gb_count(const bridge_t *b);
bool bridge_to_gb_pop(bridge_t *b, uint8_t *out);

/* GB -> host. `byte` came back over the link at time now_us. */
void bridge_gb_in(bridge_t *b, uint8_t byte, uint32_t now_us);
/* Pops the next host-bound byte whose time has come (call until it returns false). */
bool bridge_host_out_pop_due(bridge_t *b, uint32_t now_us, uint8_t *out);
/* Microseconds until the next scheduled host-bound byte is due (0 if due now), or UINT32_MAX. */
uint32_t bridge_host_out_next_in_us(const bridge_t *b, uint32_t now_us);

/* The link: call link_next(), clock the byte out, give the reply to link_rx(), wait wait_us. */
br_link_step_t bridge_link_next(bridge_t *b);
void bridge_link_rx(bridge_t *b, uint8_t reply, uint32_t now_us);

#ifdef __cplusplus
}
#endif

#endif /* BRIDGE_CORE_H */
