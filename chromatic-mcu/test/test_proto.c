// Host test: the C core against the Python reference vectors (test/vectors.txt).
#include "../src/chlink_proto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAXTOK 400

typedef struct
{
    int n;
    uint8_t m[40][3];
} msgs_t;

static void collect(void *ctx, uint8_t st, uint8_t d1, uint8_t d2)
{
    msgs_t *r = ctx;
    if (r->n < 40)
    {
        r->m[r->n][0] = st;
        r->m[r->n][1] = d1;
        r->m[r->n][2] = d2;
    }
    r->n++;
}

int main(int argc, char **argv)
{
    FILE *f = fopen(argc > 1 ? argv[1] : "vectors.txt", "r");
    if (!f) { perror("vectors"); return 2; }
    char line[4096];
    int n = 0, bad = 0;
    static int kinds[11];
    while (fgets(line, sizeof line, f))
    {
        n++;
        char kind[8] = {0};
        int a[MAXTOK];
        int k = 0;
        char *save = NULL;
        char *tok = strtok_r(line, " \n", &save);
        if (tok) { strncpy(kind, tok, 7); }
        while ((tok = strtok_r(NULL, " \n", &save)) != NULL && k < MAXTOK) a[k++] = atoi(tok);
        int ok = 0;
        if (!strcmp(kind, "play") && k == 7)
        {
            uint8_t s[4];
            chl_encode_play(a[0], a[1], a[2], s);
            ok = s[0] == a[3] && s[1] == a[4] && s[2] == a[5] && s[3] == a[6];
            kinds[0]++;
        }
        else if (!strcmp(kind, "gen") && k == 11)
        {
            uint8_t s[8];
            chl_encode_general((uint8_t)a[0], (uint8_t)a[1], (uint8_t)a[2], s);
            ok = 1;
            for (int i = 0; i < 8; i++) ok &= s[i] == a[3 + i];
            kinds[1]++;
        }
        else if (!strcmp(kind, "mask") && k == 3)
        {
            ok = chl_buttons(a[0], (uint8_t)a[1]) == a[2];
            kinds[2]++;
        }
        else if (!strcmp(kind, "slot") && k == 15)
        {
            uint8_t g[8];
            for (int i = 0; i < 8; i++) g[i] = (uint8_t)a[i];
            chl_slot_t s;
            chl_slot_from_gpd(g, &s);
            ok = s.len == a[8] && s.seq == a[9] && s.ack == a[10] && s.nack == a[11] && s.data[0] == a[12] &&
                 s.data[1] == a[13] && s.data[2] == a[14];
            kinds[3]++;
        }
        else if (!strcmp(kind, "rel") && k == 3)
        {
            uint8_t s[2];
            chl_encode_release(a[0], s);
            ok = s[0] == a[1] && s[1] == a[2];
            kinds[8]++;
        }
        else if (!strcmp(kind, "ack") && k == 4)
        {
            chl_slot_t sl = {0, 0, (uint8_t)a[1], (uint8_t)a[0], {0, 0, 0}};
            ok = chl_verify_ack(&sl, a[2]) == a[3];
            kinds[9]++;
        }
        else if (!strcmp(kind, "alive") && k == 6)
        {
            chl_slot_t sl = {(uint8_t)a[0], 0, (uint8_t)a[2], (uint8_t)a[3], {(uint8_t)a[1], 0, 0}};
            ok = chl_link_alive(&sl, a[4]) == a[5];
            kinds[10]++;
        }
        else if (!strcmp(kind, "cls") && k == 3)
        {
            // gpd order: [0] = header, [3] = B0
            uint8_t g[8] = {(uint8_t)(a[0] << 5), 0, 0, (uint8_t)a[1], 0, 0, 0, 0};
            chl_slot_t s;
            chl_slot_from_gpd(g, &s);
            ok = (int)chl_classify(&s) == a[2];
            kinds[4]++;
        }
        else if (!strcmp(kind, "ble") && k >= 2)
        {
            const int len = a[0];
            uint8_t pkt[256];
            for (int i = 0; i < len; i++) pkt[i] = (uint8_t)a[1 + i];
            const int m = a[1 + len];
            msgs_t r = {0};
            const int got = chl_blemidi_parse(pkt, (unsigned)len, collect, &r);
            ok = got == m && r.n == m;
            for (int i = 0; ok && i < m; i++)
                for (int j = 0; j < 3; j++) ok &= r.m[i][j] == a[2 + len + i * 3 + j];
            kinds[5]++;
        }
        else if (!strcmp(kind, "act") && k == 6)
        {
            uint8_t note = 0xAA, vel = 0xAA;
            const chl_action_t act = chl_midi_action((uint8_t)a[0], (uint8_t)a[1], (uint8_t)a[2], &note, &vel);
            ok = (int)act == a[3] && (act == CHL_ACT_IGNORE || act == CHL_ACT_ALL_OFF || (note == a[4] && vel == a[5]));
            kinds[6]++;
        }
        else if (!strcmp(kind, "coal") && k >= 2)
        {
            const int cn = a[0];
            chl_cmd_t c[32];
            for (int i = 0; i < cn; i++)
                c[i] = (chl_cmd_t){(uint8_t)a[1 + i * 4], (uint8_t)a[2 + i * 4], (uint8_t)a[3 + i * 4], (uint8_t)a[4 + i * 4], 0};
            const int en = a[1 + cn * 4];
            const int got = chl_coalesce(c, cn);
            ok = got == en;
            for (int i = 0; ok && i < en; i++)
            {
                const int o = 2 + cn * 4 + i * 4;
                ok &= c[i].kind == a[o] && c[i].a == a[o + 1] && c[i].b == a[o + 2] && c[i].c == a[o + 3];
            }
            kinds[7]++;
        }
        if (!ok)
        {
            bad++;
            printf("BAD line %d (%s)\n", n, kind);
        }
    }
    fclose(f);
    // Random packets: the parser must never read outside the packet or crash (run under ASan/UBSan: `make asan`).
    unsigned seed = 12345;
    for (int it = 0; it < 200000; it++)
    {
        uint8_t pkt[40];
        const unsigned len = (seed = seed * 1103515245u + 12345u) % 40u;
        for (unsigned i = 0; i < len; i++) pkt[i] = (uint8_t)((seed = seed * 1103515245u + 12345u) >> 16);
        msgs_t r = {0};
        const int got = chl_blemidi_parse(pkt, len, collect, &r);
        if (got < 0 || (unsigned)got > len) { bad++; printf("BAD fuzz count %d for %u bytes\n", got, len); break; }
    }
    {   // uplink: new messages are detected by seq
        chl_slot_t sl = {.len = 3, .seq = 2, .ack = 0, .nack = 0, .data = {0x90, 60, 100}};
        uint8_t last = 0xFF, out[3] = {0};
        if (chl_up_decode(&sl, &last, out) != 0 || last != 2) { bad++; printf("BAD up: the first slot must only be remembered\n"); }
        if (chl_up_decode(&sl, &last, out) != 0) { bad++; printf("BAD up: the same seq twice\n"); }
        sl.seq = 3;
        if (chl_up_decode(&sl, &last, out) != 3 || out[0] != 0x90 || out[1] != 60 || out[2] != 100 || last != 3) { bad++; printf("BAD up: a new 3-byte message\n"); }
        sl.seq = 4; sl.len = 1; sl.data[0] = 0xF8;
        if (chl_up_decode(&sl, &last, out) != 1 || out[0] != 0xF8) { bad++; printf("BAD up: a 1-byte clock\n"); }
        sl.seq = 7;
        if (chl_up_decode(&sl, &last, out) != 1 || last != 7) { bad++; printf("BAD up: a seq jump returns the newest\n"); }
        sl.seq = 0; sl.len = 3; sl.data[0] = 0xF4; sl.data[1] = 0; sl.data[2] = 0;   // the keyboard-screen beacon
        if (chl_up_decode(&sl, &last, out) != 0 || last != 7) { bad++; printf("BAD up: a beacon is not a message\n"); }
        sl.seq = 1; sl.len = 0;
        if (chl_up_decode(&sl, &last, out) != 0) { bad++; printf("BAD up: an empty slot\n"); }
        sl.seq = 7; sl.len = 3; sl.data[0] = 0x90;       // wraps: 7 -> 0 -> ...
        last = 7;
        sl.seq = 0;
        if (chl_up_decode(&sl, &last, out) != 3 || last != 0) { bad++; printf("BAD up: seq wraps 7 -> 0\n"); }
    }
    printf("%d vectors (play %d, gen %d, mask %d, slot %d, cls %d, ble %d, act %d, coal %d, rel %d, ack %d, alive %d), %d bad\n", n,
           kinds[0], kinds[1], kinds[2], kinds[3], kinds[4], kinds[5], kinds[6], kinds[7], kinds[8], kinds[9], kinds[10], bad);
    return bad ? 1 : 0;
}
