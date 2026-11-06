// Host test: the C core against the Python reference vectors (test/vectors.txt).
#include "../src/chlink_proto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    FILE *f = fopen(argc > 1 ? argv[1] : "vectors.txt", "r");
    if (!f) { perror("vectors"); return 2; }
    char line[256];
    int n = 0, bad = 0;
    while (fgets(line, sizeof line, f))
    {
        n++;
        char kind[8];
        int a[16];
        int k = sscanf(line, "%7s %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d", kind, a, a + 1, a + 2, a + 3, a + 4,
                       a + 5, a + 6, a + 7, a + 8, a + 9, a + 10, a + 11, a + 12, a + 13, a + 14) - 1;
        if (!strcmp(kind, "play") && k == 7)
        {
            uint8_t s[4];
            chl_encode_play(a[0], a[1], a[2], s);
            if (s[0] != a[3] || s[1] != a[4] || s[2] != a[5] || s[3] != a[6]) { bad++; printf("BAD %s", line); }
        }
        else if (!strcmp(kind, "gen") && k == 11)
        {
            uint8_t s[8];
            chl_encode_general((uint8_t)a[0], (uint8_t)a[1], (uint8_t)a[2], s);
            for (int i = 0; i < 8; i++)
                if (s[i] != a[3 + i]) { bad++; printf("BAD %s", line); break; }
        }
        else if (!strcmp(kind, "mask") && k == 3)
        {
            if (chl_buttons(a[0], (uint8_t)a[1]) != a[2]) { bad++; printf("BAD %s", line); }
        }
        else if (!strcmp(kind, "slot") && k == 15)
        {
            uint8_t g[8];
            for (int i = 0; i < 8; i++) g[i] = (uint8_t)a[i];
            chl_slot_t s;
            chl_slot_from_gpd(g, &s);
            if (s.len != a[8] || s.seq != a[9] || s.ack != a[10] || s.nack != a[11] || s.data[0] != a[12] ||
                s.data[1] != a[13] || s.data[2] != a[14])
            { bad++; printf("BAD %s", line); }
        }
        else { bad++; printf("UNPARSED (%d fields) %s", k, line); }
    }
    fclose(f);
    printf("%d vectors, %d bad\n", n, bad);
    return bad ? 1 : 0;
}
