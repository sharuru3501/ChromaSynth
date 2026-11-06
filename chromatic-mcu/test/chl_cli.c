// Prints the FPGA button masks (hex, one per symbol) the MCU would write for a packet.
//   chl_cli play <on> <note> <vel127> <first phase>
//   chl_cli midi <b0> <b1> <b2> <first phase>      (decimal)
//   chl_cli sync <phase>                            (one stray symbol, data 0)
// Used by tools/headless_mcu_proto_test.py, which feeds them to the ROM running in PyBoy.
#include "../src/chlink_proto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
    uint8_t s[CHL_GENERAL_SYMBOLS];
    int n = 0, phase = 0;
    if (argc == 6 && !strcmp(argv[1], "play"))
    {
        chl_encode_play(atoi(argv[2]), atoi(argv[3]), atoi(argv[4]), s);
        n = CHL_PLAY_SYMBOLS;
        phase = atoi(argv[5]);
    }
    else if (argc == 6 && !strcmp(argv[1], "midi"))
    {
        chl_encode_general((uint8_t)atoi(argv[2]), (uint8_t)atoi(argv[3]), (uint8_t)atoi(argv[4]), s);
        n = CHL_GENERAL_SYMBOLS;
        phase = atoi(argv[5]);
    }
    else if (argc == 3 && !strcmp(argv[1], "sync"))
    {
        s[0] = 0;
        n = 1;
        phase = atoi(argv[2]);
    }
    else
    {
        fprintf(stderr, "usage: see the top of chl_cli.c\n");
        return 2;
    }
    for (int i = 0; i < n; i++)
    {
        printf("%s%02X", i ? " " : "", chl_buttons(phase, s[i]));
        phase ^= 1;
    }
    printf("\n");
    return 0;
}
