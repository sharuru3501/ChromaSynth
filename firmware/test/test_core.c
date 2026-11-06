/*
 * Host tests for firmware/core/bridge_core.c.
 *   1. Replays the golden traces (vectors.txt) recorded from tools/bridge_ref.py and checks that
 *      the C core produces exactly the same output for every step.
 *   2. C-specific checks that the Python model cannot express: fixed-size queues, wrap-around of
 *      the 32-bit microsecond counter, chunking independence.
 *
 *   usage: test_core [vectors.txt]
 */
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bridge_core.h"

static int g_failures;

#define CHECK(cond, ...)                                            \
    do {                                                            \
        if (!(cond)) {                                              \
            g_failures++;                                           \
            printf("FAIL %s:%d: ", __FILE__, __LINE__);            \
            printf(__VA_ARGS__);                                    \
            printf("\n");                                           \
        }                                                           \
    } while (0)

/* ------------------------------------------------------------------ golden traces */

#define MAXB 1024

static int parse_hex_list(char *s, uint8_t *out)
{
    int n = 0;
    for (char *tok = strtok(s, " \t\r\n"); tok; tok = strtok(NULL, " \t\r\n")) {
        out[n++] = (uint8_t)strtoul(tok, NULL, 16);
    }
    return n;
}

static void fmt(char *dst, size_t cap, const uint8_t *b, int n)
{
    dst[0] = 0;
    for (int i = 0; i < n && strlen(dst) + 4 < cap; i++) {
        char t[8];
        snprintf(t, sizeof t, "%02X ", b[i]);
        strcat(dst, t);
    }
}

static int replay(const char *path)
{
    FILE *f = fopen(path, "r");
    if (!f) {
        printf("cannot open %s (run `make vectors`)\n", path);
        return 0;
    }
    bridge_t b;
    bridge_init(&b);
    char line[8192], scenario[128] = "";
    int lineno = 0, steps = 0, bad = 0;
    while (fgets(line, sizeof line, f)) {
        lineno++;
        if (line[0] == '#' || line[0] == '\n') {
            continue;
        }
        steps++;
        char *arrow = strstr(line, "=>");
        char head[8192];
        uint8_t exp[MAXB], got[MAXB], in[MAXB];
        int nexp = 0, ngot = 0, nin = 0;
        if (arrow) {
            *arrow = 0;
            char tail[8192];
            strcpy(tail, arrow + 2);
            strcpy(head, line);
            if (line[0] != 'N') {
                nexp = parse_hex_list(tail, exp);
            }
        } else {
            strcpy(head, line);
        }
        char kind = head[0];
        char *rest = head + 1;
        if (kind == 'S') {
            snprintf(scenario, sizeof scenario, "%s", rest);
            bridge_init(&b);
        } else if (kind == 'H' || kind == 'Q') {
            nin = parse_hex_list(rest, in);
            bridge_host_in(&b, in, (size_t)nin);
            if (kind == 'H') {
                uint8_t x;
                while (bridge_to_gb_pop(&b, &x)) {
                    got[ngot++] = x;
                }
            }
        } else if (kind == 'G' || kind == 'R') {
            unsigned byte;
            unsigned long t;
            sscanf(rest, "%x %lu", &byte, &t);
            if (kind == 'G') {
                bridge_gb_in(&b, (uint8_t)byte, (uint32_t)t);
            } else {
                bridge_link_rx(&b, (uint8_t)byte, (uint32_t)t);
            }
        } else if (kind == 'D') {
            unsigned long t = strtoul(rest, NULL, 10);
            uint8_t x;
            while (bridge_host_out_pop_due(&b, (uint32_t)t, &x)) {
                got[ngot++] = x;
            }
        } else if (kind == 'N') {
            char tail[256];
            strcpy(tail, arrow + 2);
            unsigned tx, data;
            unsigned long wait;
            sscanf(tail, "%x %lu %u", &tx, &wait, &data);
            br_link_step_t s = bridge_link_next(&b);
            if (s.tx != tx || s.wait_us != wait || (unsigned)s.data != data) {
                bad++;
                printf("FAIL line %d [%s]: link_next gave %02X %u %d, expected %02X %lu %u\n", lineno, scenario, s.tx,
                       (unsigned)s.wait_us, s.data, tx, wait, data);
            }
            continue;
        } else {
            printf("bad trace line %d: %s", lineno, line);
            bad++;
            continue;
        }
        if ((kind == 'H' || kind == 'D') && (ngot != nexp || memcmp(got, exp, (size_t)ngot) != 0)) {
            char a[2048], e[2048];
            fmt(a, sizeof a, got, ngot);
            fmt(e, sizeof e, exp, nexp);
            bad++;
            printf("FAIL line %d [%s]: got  %s\n                    want %s\n", lineno, scenario, a, e);
        }
        if (bad > 5) {
            break;
        }
    }
    fclose(f);
    CHECK(bad == 0, "%d mismatching steps", bad);
    printf("golden traces: %d steps, %s\n", steps, bad ? "MISMATCH" : "all identical to the Python model");
    return steps;
}

/* ------------------------------------------------------------------ C-specific tests */

static void test_queue_full_drops_whole_messages(void)
{
    bridge_t b;
    bridge_init(&b);
    const uint8_t note[3] = {0x90, 60, 100};
    for (int i = 0; i < 400; i++) {
        bridge_host_in(&b, note, 3);
    }
    size_t n = bridge_to_gb_count(&b);
    CHECK(n <= BR_TO_GB_CAP - 1, "queue overflowed: %zu", n);
    CHECK(n % 3 == 0, "a partial message was queued (%zu bytes)", n);
    CHECK(b.gb_dropped > 0, "nothing was dropped");
    uint8_t x, expect[3] = {0x90, 60, 100};
    int i = 0;
    while (bridge_to_gb_pop(&b, &x)) {
        CHECK(x == expect[i % 3], "queue content corrupted at %d", i);
        i++;
    }
}

static void test_host_out_full_drops_quietly(void)
{
    bridge_t b;
    bridge_init(&b);
    for (int i = 0; i < 200; i++) {
        bridge_gb_in(&b, 0x90, 1000);
    }
    CHECK(b.out_n == BR_OUT_CAP, "out_n %u", b.out_n);
    CHECK(b.out_dropped == 200 - BR_OUT_CAP, "dropped %" PRIu32, b.out_dropped);
    uint8_t x;
    int n = 0;
    while (bridge_host_out_pop_due(&b, 1000, &x)) {
        n++;
    }
    CHECK(n == (int)BR_OUT_CAP, "popped %d", n);
}

static void test_microsecond_counter_wraps(void)
{
    bridge_t b;
    bridge_init(&b);
    uint32_t t0 = 0xFFFFFFFFu - 20000u; /* the counter wraps 20 ms into the test */
    bridge_gb_in(&b, BR_CLOCK, t0);
    bridge_gb_in(&b, BR_CLOCK, t0 + 40000u); /* wraps to 19999 */
    uint8_t x;
    CHECK(bridge_host_out_pop_due(&b, t0, &x) && x == BR_CLOCK, "first tick due at its time");
    CHECK(!bridge_host_out_pop_due(&b, t0, &x), "nothing else is due yet");
    CHECK(bridge_host_out_next_in_us(&b, t0) == 40000u, "next tick in %" PRIu32, bridge_host_out_next_in_us(&b, t0));
    CHECK(bridge_host_out_pop_due(&b, t0 + 40000u, &x), "tick after the wrap is due");
    CHECK(bridge_host_out_next_in_us(&b, t0 + 40000u) == 20000u, "interpolated clock half an interval later");
    CHECK(!bridge_host_out_pop_due(&b, t0 + 59999u, &x), "interpolated clock is not early");
    CHECK(bridge_host_out_pop_due(&b, t0 + 60000u, &x), "interpolated clock is due across the wrap");
    CHECK(bridge_host_out_next_in_us(&b, t0 + 60000u) == UINT32_MAX, "queue empty");
}

static void test_chunking_does_not_matter(void)
{
    const uint8_t stream[] = {0x93, 60, 100, 62, 100, 0xF8, 0xE1, 0, 64, 0xB2, 1, 90, 0xF0, 1, 2, 0xF7,
                              0xD0, 5,  0xFA, 0xF8, 0xF8, 0xF8, 0x80, 60, 0, 0xFC};
    bridge_t whole, bytewise;
    bridge_init(&whole);
    bridge_init(&bytewise);
    bridge_host_in(&whole, stream, sizeof stream);
    for (size_t i = 0; i < sizeof stream; i++) {
        bridge_host_in(&bytewise, &stream[i], 1);
    }
    CHECK(bridge_to_gb_count(&whole) == bridge_to_gb_count(&bytewise), "different amounts of output");
    uint8_t a, c;
    size_t n = 0;
    while (bridge_to_gb_pop(&whole, &a)) {
        CHECK(bridge_to_gb_pop(&bytewise, &c) && a == c, "output differs at %zu", n);
        n++;
    }
    CHECK(n > 10, "suspiciously little output (%zu)", n);
}

static void test_link_flow(void)
{
    bridge_t b;
    bridge_init(&b);
    br_link_step_t s = bridge_link_next(&b);
    CHECK(s.tx == BR_IDLE && s.wait_us == BR_LINK_DOWN_POLL_US && !s.data, "link starts down and polls slowly");
    bridge_link_rx(&b, BR_NOT_READY, 0);
    CHECK(!b.link_up && b.link_down_events == 0, "still down, not counted as a loss");
    bridge_link_rx(&b, BR_IDLE, 1000);
    CHECK(b.link_up, "link up on the first reply that is not $FF");
    const uint8_t note[3] = {0x90, 60, 100};
    bridge_host_in(&b, note, 3);
    for (int i = 0; i < 3; i++) {
        s = bridge_link_next(&b);
        CHECK(s.tx == note[i] && s.wait_us == BR_GAP_US && s.data, "byte %d of the note", i);
    }
    s = bridge_link_next(&b);
    CHECK(s.tx == BR_IDLE && s.wait_us == BR_IDLE_POLL_US - BR_BYTE_US && !s.data, "idle poll");
    bridge_link_rx(&b, BR_NOT_READY, 5000);
    CHECK(!b.link_up && b.link_down_events == 1, "link lost is counted once");
    bridge_host_in(&b, note, 3);
    s = bridge_link_next(&b);
    CHECK(s.tx == BR_IDLE && bridge_to_gb_count(&b) == 0, "queued input is dropped while the GB is away");
}

static void test_timing_constants(void)
{
    CHECK(BR_BYTE_US == 8u * 1000000u / BR_BIT_CLOCK_HZ, "byte time matches the bit clock");
    CHECK(BR_GAP_US >= 200u, "the gap must cover the ROM's serial ISR (~100 us) with margin");
    CHECK(1000000u / (BR_BYTE_US + BR_GAP_US) >= 1500u, "link throughput");
}

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "vectors.txt";
    int steps = replay(path);
    CHECK(steps > 5000, "too few golden steps (%d)", steps);
    test_queue_full_drops_whole_messages();
    test_host_out_full_drops_quietly();
    test_microsecond_counter_wraps();
    test_chunking_does_not_matter();
    test_link_flow();
    test_timing_constants();
    printf(g_failures ? "\n%d FAILED\n" : "\nALL PASSED\n", g_failures);
    return g_failures ? 1 : 0;
}
