// The link task: turns notes and MIDI messages into virtual-button symbols for the ROM's keyboard
// screen. DANGER: the ROM reads these presses as data only on its keyboard screen; on any other
// screen they are real input (START changes the screen, A edits notes). So nothing is sent until
// the user has put the ROM on its keyboard screen and typed `link on`.
//
// Console:
//   link on | off         start (sync + HELLO + keep-alive) / stop sending
//   link hold <ms>        how long each symbol is held (default 50 ms, i.e. 3 frames)
//   link hello            send HELLO again (the ROM unlinks after ~4 s without a packet)
//   link sync             re-align the symbol phase with the ROM (a stray symbol, then a pause)
//   link stat             state + the ROM's uplink slot as read with gpd
//   note on <n> [vel] | note off <n> | note <n> [ms [vel]]    play a note (the last form: on, wait, off)
//   midi <b0> <b1> [b2]   a MIDI message in hex, e.g. midi 90 3c 64
#include "chlink_link.h"

#include "chlink.h"
#include "chlink_proto.h"
#include "esp_console.h"
#include "fpga_tx.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KEEPALIVE_MS 2000   // the ROM unlinks after 250 frames (~4.2 s) without a valid packet
#define SYNC_PAUSE_MS 700   // the ROM drops a half packet after 30 frames (0.5 s)
#define GAP_MS 20           // released between packets

typedef enum { CMD_PLAY, CMD_MIDI, CMD_HELLO, CMD_SYNC } CmdKind;
typedef struct
{
    CmdKind kind;
    uint8_t a, b, c;
} Cmd;

static QueueHandle_t s_q;
static volatile bool s_on = false;
static volatile uint16_t s_hold_ms = 50;
static int s_phase = 0;            // phase of the next symbol; kept equal to the ROM's (link sync)
static volatile uint32_t s_sent = 0;

static void delay_ms(uint32_t ms)
{
    vTaskDelay((pdMS_TO_TICKS(ms) > 0) ? pdMS_TO_TICKS(ms) : 1);
}

static void send_symbols(const uint8_t *syms, int n)
{
    for (int i = 0; i < n; i++)
    {
        FPGA_Tx_RawPoke(chl_buttons(s_phase, syms[i]));
        delay_ms(s_hold_ms);
        s_phase ^= 1;
    }
    FPGA_Tx_RawPoke(0);
    delay_ms(GAP_MS);
    s_sent++;
}

static void do_play(bool on, uint8_t note, uint8_t vel)
{
    uint8_t s[CHL_PLAY_SYMBOLS];
    chl_encode_play(on, note, vel, s);
    send_symbols(s, CHL_PLAY_SYMBOLS);
}

static void do_midi(uint8_t b0, uint8_t b1, uint8_t b2)
{
    uint8_t s[CHL_GENERAL_SYMBOLS];
    chl_encode_general(b0, b1, b2, s);
    send_symbols(s, CHL_GENERAL_SYMBOLS);
}

static void do_hello(void)
{
    do_midi(0xFE, 0x43, 0x53);
}

// A stray one-symbol "packet": if the ROM expects this phase it accepts it (and drops the half packet
// later), otherwise it ignores it as a held symbol. Either way both sides expect the other phase next.
static void do_sync(void)
{
    const uint8_t zero = 0;
    send_symbols(&zero, 1);
    delay_ms(SYNC_PAUSE_MS);
}

static void link_task(void *arg)
{
    (void)arg;
    Cmd c;
    TickType_t last_tx = xTaskGetTickCount();
    for (;;)
    {
        if (xQueueReceive(s_q, &c, pdMS_TO_TICKS(250)) == pdTRUE)
        {
            if (!s_on)
            {
                continue;   // `link off`: drop whatever was queued
            }
            switch (c.kind)
            {
            case CMD_PLAY: do_play(c.a != 0, c.b, c.c); break;
            case CMD_MIDI: do_midi(c.a, c.b, c.c); break;
            case CMD_HELLO: do_hello(); break;
            case CMD_SYNC: do_sync(); break;
            }
            last_tx = xTaskGetTickCount();
        }
        else if (s_on && (xTaskGetTickCount() - last_tx) >= pdMS_TO_TICKS(KEEPALIVE_MS))
        {
            do_play(false, 0, 0);   // note 0 off: does nothing in a linked ROM, but counts as a packet
            last_tx = xTaskGetTickCount();
        }
    }
}

static bool queue_cmd(CmdKind kind, uint8_t a, uint8_t b, uint8_t c)
{
    if (s_q == NULL || !s_on)
    {
        return false;
    }
    const Cmd cmd = {kind, a, b, c};
    return xQueueSend(s_q, &cmd, 0) == pdTRUE;
}

bool ChLinkLink_Note(bool on, uint8_t note, uint8_t vel127)
{
    return queue_cmd(CMD_PLAY, on, note, vel127);
}

bool ChLinkLink_Midi(uint8_t b0, uint8_t b1, uint8_t b2)
{
    return queue_cmd(CMD_MIDI, b0, b1, b2);
}

static int cmd_link(int argc, char **argv)
{
    if (argc >= 2 && !strcmp(argv[1], "on"))
    {
        if (!s_on)
        {
            xQueueReset(s_q);
            s_on = true;
            queue_cmd(CMD_SYNC, 0, 0, 0);
            queue_cmd(CMD_HELLO, 0, 0, 0);
        }
        printf("link on (the ROM must be on its KEYBOARD screen). sync + HELLO queued\n");
    }
    else if (argc >= 2 && !strcmp(argv[1], "off"))
    {
        s_on = false;
        xQueueReset(s_q);
        FPGA_Tx_RawPoke(0);
        printf("link off\n");
    }
    else if (argc >= 3 && !strcmp(argv[1], "hold"))
    {
        const int ms = atoi(argv[2]);
        if (ms < 10 || ms > 500)
        {
            printf("hold must be 10..500 ms\n");
            return -1;
        }
        s_hold_ms = (uint16_t)ms;
        printf("hold %d ms\n", ms);
    }
    else if (argc >= 2 && !strcmp(argv[1], "hello"))
    {
        printf(queue_cmd(CMD_HELLO, 0, 0, 0) ? "HELLO queued\n" : "link is off\n");
    }
    else if (argc >= 2 && !strcmp(argv[1], "sync"))
    {
        printf(queue_cmd(CMD_SYNC, 0, 0, 0) ? "sync queued\n" : "link is off\n");
    }
    else if (argc >= 2 && !strcmp(argv[1], "stat"))
    {
        printf("link %s, hold %u ms, next phase %c, %u packets sent, %u queued\n", s_on ? "ON" : "off", (unsigned)s_hold_ms,
               s_phase ? 'B' : 'A', (unsigned)s_sent, (unsigned)uxQueueMessagesWaiting(s_q));
        uint8_t g[8];
        if (ChLink_ReadGpd(g))
        {
            chl_slot_t s;
            chl_slot_from_gpd(g, &s);
            printf("gpd %02X %02X %02X %02X %02X %02X %02X %02X -> slot len %u seq %u ack %c nack %u data %02X %02X %02X\n",
                   g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7], s.len, s.seq, s.ack ? 'B' : 'A', s.nack, s.data[0],
                   s.data[1], s.data[2]);
        }
        else
        {
            printf("gpd timeout\n");
        }
    }
    else
    {
        printf("usage: link on|off|hello|sync|stat | link hold <ms>\n");
        return -1;
    }
    return 0;
}

static int cmd_note(int argc, char **argv)
{
    if (argc >= 3 && (!strcmp(argv[1], "on") || !strcmp(argv[1], "off")))
    {
        const bool on = !strcmp(argv[1], "on");
        const int note = atoi(argv[2]);
        const int vel = (argc >= 4) ? atoi(argv[3]) : 100;
        if (note < 0 || note > 127 || vel < 0 || vel > 127)
        {
            printf("note 0..127, velocity 0..127\n");
            return -1;
        }
        printf(ChLinkLink_Note(on, (uint8_t)note, (uint8_t)vel) ? "queued\n" : "link is off (or the queue is full)\n");
        return 0;
    }
    if (argc >= 2)
    {
        const int note = atoi(argv[1]);
        const int ms = (argc >= 3) ? atoi(argv[2]) : 500;
        const int vel = (argc >= 4) ? atoi(argv[3]) : 100;
        if (note < 0 || note > 127 || ms < 0 || ms > 10000 || vel < 0 || vel > 127)
        {
            printf("note 0..127, ms 0..10000, velocity 0..127\n");
            return -1;
        }
        if (!ChLinkLink_Note(true, (uint8_t)note, (uint8_t)vel))
        {
            printf("link is off (or the queue is full)\n");
            return -1;
        }
        delay_ms((uint32_t)ms);
        (void)ChLinkLink_Note(false, (uint8_t)note, 0);
        printf("note %d, %d ms\n", note, ms);
        return 0;
    }
    printf("usage: note on <n> [vel] | note off <n> | note <n> [ms [vel]]\n");
    return -1;
}

static int cmd_midi(int argc, char **argv)
{
    if (argc < 3 || argc > 4)
    {
        printf("usage: midi <b0> <b1> [b2]  (hex)\n");
        return -1;
    }
    const long b0 = strtol(argv[1], NULL, 16);
    const long b1 = strtol(argv[2], NULL, 16);
    const long b2 = (argc == 4) ? strtol(argv[3], NULL, 16) : CHL_PAD;
    if (b0 < 0x80 || b0 > 0xFF || b1 < 0 || b1 > 0xFF || b2 < 0 || b2 > 0xFF)
    {
        printf("bytes must be hex, the first a status byte\n");
        return -1;
    }
    printf(ChLinkLink_Midi((uint8_t)b0, (uint8_t)b1, (uint8_t)b2) ? "queued\n" : "link is off (or the queue is full)\n");
    return 0;
}

void ChLinkLink_Start(void)
{
    s_q = xQueueCreate(32, sizeof(Cmd));
    const esp_console_cmd_t cmds[] = {
        {.command = "link", .help = "ROM link: on|off|hello|sync|stat, hold <ms>", .func = &cmd_link},
        {.command = "note", .help = "play a note over the link: note on <n> [vel] | off <n> | <n> [ms [vel]]", .func = &cmd_note},
        {.command = "midi", .help = "send a MIDI message over the link (hex): midi 90 3c 64", .func = &cmd_midi},
    };
    for (size_t i = 0; i < sizeof(cmds) / sizeof(cmds[0]); i++)
    {
        (void)esp_console_cmd_register(&cmds[i]);
    }
    (void)xTaskCreate(link_task, "chlink_link", 4096, NULL, 17, NULL);
}
