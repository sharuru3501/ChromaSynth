// The link task: turns notes and MIDI messages into virtual-button symbols for the ROM's keyboard
// screen.
//
// DANGER: the ROM reads these presses as data only on its keyboard screen; on any other screen they are
// real input (START changes the screen, A edits notes). So in the default AUTO mode nothing is sent unless
// the ROM says, through the palette slot (gpd), that it is on the keyboard screen: it writes the beacon
// {$F4} while waiting for HELLO and {$F5} once when it leaves the screen. The state is read again before
// EVERY symbol. `link on` forces sending without any check (debugging only).
//
// Console:
//   link auto            (default) send only while the ROM shows it is on the keyboard screen
//   link on              FORCE: send without checking the ROM (the ROM must be on its KEYBOARD screen!)
//   link off             send nothing
//   link hold <ms>       how long each symbol is held (default 30 ms, about 2 ROM frames; 20 ms loses symbols)
//   link hello|sync      queue a HELLO / a phase sync
//   link stat            mode, armed, what the ROM shows (gpd), counters
//   link lat             latency statistics measured inside the MCU (queue wait, packet time, gpd check time)
//   note on <n> [vel] | note off <n> | note <n> [ms [vel]]    play a note (the last form: on, wait, off)
//   midi <b0> <b1> [b2]  a MIDI message in hex, e.g. midi 90 3c 64
#include "chlink_link.h"

#include "chlink.h"
#include "chlink_proto.h"
#include "esp_console.h"
#include "esp_rom_sys.h"
#include "esp_timer.h"
#include "fpga_tx.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KEEPALIVE_MS 2000   // the ROM unlinks after 250 frames (~4.2 s) without a valid packet
#define SYNC_PAUSE_MS 700   // the ROM drops a half packet after 30 frames (0.5 s)
#define GAP_MS 15           // released between packets
#define POLL_MS 100         // how often the ROM's state is read while idle
#define GPD_TIMEOUT_MS 30   // one request/reply takes about 2 ms

typedef enum { MODE_OFF, MODE_AUTO, MODE_FORCE } Mode;
typedef enum { RS_UNKNOWN, RS_KBD, RS_LEFT, RS_OTHER } RomState;

static QueueHandle_t s_q;
static volatile Mode s_mode = MODE_AUTO;
static volatile uint16_t s_hold_ms = 30;   // measured on the console: 30 ms works, 20 ms loses symbols
static int s_phase = 0;                 // phase of the next symbol; kept equal to the ROM's (sync)
static bool s_armed = false;            // HELLO sent and the ROM is on the keyboard screen
static volatile uint32_t s_sent = 0, s_aborted = 0, s_dropped = 0, s_handshakes = 0;
static volatile RomState s_last_state = RS_UNKNOWN;

// Latency statistics (microseconds): queue wait = from "queued" (a BLE write arrived) to the first symbol being
// pressed; packet = first symbol pressed to the last one released; check = one gpd request/reply.
typedef struct { uint32_t n, last, sum, max; } Stat;
static Stat s_wait, s_packet, s_check;
static void stat_add(Stat *s, uint32_t us)
{
    s->n++;
    s->last = us;
    s->sum += us;
    if (us > s->max) s->max = us;
}
static void stat_print(const char *name, const Stat *s)
{
    printf("  %-22s n %u, last %u us, avg %u us, max %u us\n", name, (unsigned)s->n, (unsigned)s->last,
           (unsigned)(s->n ? s->sum / s->n : 0), (unsigned)s->max);
}

static void delay_ms(uint32_t ms)
{
    vTaskDelay((pdMS_TO_TICKS(ms) > 0) ? pdMS_TO_TICKS(ms) : 1);
}

static RomState rom_state(void)
{
    uint8_t g[8];
    const int64_t t0 = esp_timer_get_time();
    const bool got = ChLink_ReadGpdTimeout(g, GPD_TIMEOUT_MS);
    stat_add(&s_check, (uint32_t)(esp_timer_get_time() - t0));
    if (!got)
    {
        return s_last_state = RS_UNKNOWN;
    }
    chl_slot_t s;
    chl_slot_from_gpd(g, &s);
    switch (chl_classify(&s))
    {
    case CHL_ROM_KBD: return s_last_state = RS_KBD;
    case CHL_ROM_LEFT: return s_last_state = RS_LEFT;
    default: return s_last_state = RS_OTHER;
    }
}

// May a symbol be sent now? handshake: the ROM shows the beacon until it has seen HELLO.
static bool may_send(bool handshake)
{
    if (s_mode == MODE_FORCE)
    {
        return true;
    }
    const RomState st = rom_state();
    return st == RS_OTHER || (handshake && st == RS_KBD);
}

// Waits until the microsecond clock reaches t_us. The tick is 10 ms, so long waits use vTaskDelay and the last few
// milliseconds a short busy wait (it never exceeds 10 ms, and the FPGA reply the link task waits for is already in).
static void wait_until(int64_t t_us)
{
    for (;;)
    {
        const int64_t rem = t_us - esp_timer_get_time();
        if (rem <= 0) return;
        if (rem >= 10000)
        {
            vTaskDelay(pdMS_TO_TICKS((uint32_t)(rem / 1000)));
        }
        else
        {
            esp_rom_delay_us((uint32_t)rem);
        }
    }
}

// Sends the symbols. The ROM is looked at before the first symbol, and again before every later one: that
// look is made at the END of the previous symbol's hold (the FPGA needs about 7 ms to answer), so it costs
// no extra time. Returns false (and releases the buttons) if the ROM is no longer on the keyboard screen; the
// packet is then left half sent, which the ROM drops by itself.
static bool send_symbols(const uint8_t *syms, int n, bool handshake)
{
    if (!may_send(handshake))
    {
        FPGA_Tx_RawPoke(0);
        s_aborted++;
        s_armed = false;
        return false;
    }
    for (int i = 0; i < n; i++)
    {
        const int64_t t0 = esp_timer_get_time();
        const int64_t hold_us = (int64_t)s_hold_ms * 1000;
        FPGA_Tx_RawPoke(chl_buttons(s_phase, syms[i]));
        s_phase ^= 1;
        if (i + 1 < n)
        {
            int64_t est = s_check.last ? (int64_t)s_check.last : 8000;   // how long the look takes
            if (est > 20000) est = 20000;
            wait_until(t0 + hold_us - est - 500);
            if (!may_send(handshake))
            {
                FPGA_Tx_RawPoke(0);
                s_aborted++;
                s_armed = false;
                return false;
            }
        }
        wait_until(t0 + hold_us);
    }
    FPGA_Tx_RawPoke(0);
    delay_ms(GAP_MS);
    s_sent++;
    return true;
}

static bool do_play(bool on, uint8_t note, uint8_t vel)
{
    uint8_t s[CHL_PLAY_SYMBOLS];
    chl_encode_play(on, note, vel, s);
    return send_symbols(s, CHL_PLAY_SYMBOLS, false);
}

// A queued note: records how long it waited and how long the packet took (note-ons only).
static bool do_play_timed(const chl_cmd_t *c)
{
    const int64_t t0 = esp_timer_get_time();
    const bool ok = do_play(c->a != 0, c->b, c->c);
    if (c->a != 0 && ok && c->t_us != 0)
    {
        stat_add(&s_wait, (uint32_t)((uint32_t)t0 - c->t_us));
        stat_add(&s_packet, (uint32_t)(esp_timer_get_time() - t0));
    }
    return ok;
}

static bool do_midi(uint8_t b0, uint8_t b1, uint8_t b2, bool handshake)
{
    uint8_t s[CHL_GENERAL_SYMBOLS];
    chl_encode_general(b0, b1, b2, s);
    return send_symbols(s, CHL_GENERAL_SYMBOLS, handshake);
}

// A stray one-symbol "packet": if the ROM expects this phase it accepts it (and drops the half packet
// later), otherwise it ignores it as a held symbol. Either way both sides expect the other phase next.
static bool do_sync(void)
{
    const uint8_t zero = 0;
    const bool ok = send_symbols(&zero, 1, true);
    delay_ms(SYNC_PAUSE_MS);
    return ok;
}

// sync + HELLO; armed only if the ROM then shows an ordinary (linked) slot.
static bool handshake(void)
{
    s_handshakes++;
    for (int attempt = 0; attempt < 3; attempt++)
    {
        if (!do_sync() || !do_midi(0xFE, 0x43, 0x53, true))
        {
            return s_armed = false;
        }
        delay_ms(100);
        if (s_mode == MODE_FORCE || rom_state() == RS_OTHER)
        {
            return s_armed = true;
        }
    }
    return s_armed = false;
}

static void link_task(void *arg)
{
    (void)arg;
    TickType_t last_tx = xTaskGetTickCount();
    for (;;)
    {
        chl_cmd_t cmds[32];
        int n = 0;
        if (xQueueReceive(s_q, &cmds[0], pdMS_TO_TICKS(POLL_MS)) == pdTRUE)
        {
            n = 1;
            while (n < 32 && xQueueReceive(s_q, &cmds[n], 0) == pdTRUE) n++;
            const int before = n;
            n = chl_coalesce(cmds, n);
            s_dropped += (uint32_t)(before - n);
        }
        if (s_mode == MODE_OFF)
        {
            s_armed = false;
            continue;
        }
        if (s_mode == MODE_AUTO)
        {
            const RomState st = rom_state();
            if (st == RS_LEFT || (st == RS_OTHER && !s_armed))
            {
                s_armed = false;           // not on the keyboard screen: nothing to do, drop what we have
                s_dropped += (uint32_t)n;
                continue;
            }
            // RS_UNKNOWN (no reply in 30 ms): carry on while armed, so that a note-off is not lost; every
            // symbol is checked again before it is sent.
            if (st == RS_UNKNOWN && !s_armed)
            {
                s_dropped += (uint32_t)n;
                continue;
            }
            if (st == RS_KBD)              // the ROM wants HELLO (first time, or its link timed out)
            {
                s_armed = false;
                if (!handshake())
                {
                    s_dropped += (uint32_t)n;
                    continue;
                }
                last_tx = xTaskGetTickCount();
            }
        }
        for (int i = 0; i < n && s_armed; i++)
        {
            bool ok = true;
            switch (cmds[i].kind)
            {
            case CHL_CMD_PLAY: ok = do_play_timed(&cmds[i]); break;
            case CHL_CMD_MIDI: ok = do_midi(cmds[i].a, cmds[i].b, cmds[i].c, false); break;
            case CHL_CMD_HELLO: ok = handshake(); break;
            case CHL_CMD_SYNC: ok = do_sync(); break;
            }
            last_tx = xTaskGetTickCount();
            if (!ok)
            {
                s_dropped += (uint32_t)(n - i - 1);
                break;
            }
        }
        if (s_armed && (xTaskGetTickCount() - last_tx) >= pdMS_TO_TICKS(KEEPALIVE_MS))
        {
            (void)do_play(false, 0, 0);   // note 0 off: does nothing in a linked ROM, but counts as a packet
            last_tx = xTaskGetTickCount();
        }
    }
}

static bool queue_cmd(uint8_t kind, uint8_t a, uint8_t b, uint8_t c)
{
    if (s_q == NULL || s_mode == MODE_OFF)
    {
        return false;
    }
    const chl_cmd_t cmd = {kind, a, b, c, (uint32_t)esp_timer_get_time()};
    return xQueueSend(s_q, &cmd, 0) == pdTRUE;
}

bool ChLinkLink_Note(bool on, uint8_t note, uint8_t vel127)
{
    return queue_cmd(CHL_CMD_PLAY, on, note, vel127);
}

bool ChLinkLink_Midi(uint8_t b0, uint8_t b1, uint8_t b2)
{
    return queue_cmd(CHL_CMD_MIDI, b0, b1, b2);
}

static const char *state_name(RomState s)
{
    return s == RS_KBD ? "keyboard screen, waiting for HELLO" : s == RS_LEFT ? "left the keyboard screen"
           : s == RS_OTHER ? "other (linked, or not on the keyboard screen)" : "no reply";
}

static int cmd_link(int argc, char **argv)
{
    if (argc >= 2 && !strcmp(argv[1], "auto"))
    {
        s_mode = MODE_AUTO;
        printf("link auto: sends only while the ROM shows that it is on the keyboard screen\n");
    }
    else if (argc >= 2 && !strcmp(argv[1], "on"))
    {
        xQueueReset(s_q);
        s_mode = MODE_FORCE;
        s_armed = true;                 // (the task only works through its commands while armed)
        queue_cmd(CHL_CMD_HELLO, 0, 0, 0);
        printf("link FORCED on, no ROM check (the ROM must be on its KEYBOARD screen). sync + HELLO queued\n");
    }
    else if (argc >= 2 && !strcmp(argv[1], "off"))
    {
        s_mode = MODE_OFF;
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
        printf(queue_cmd(CHL_CMD_HELLO, 0, 0, 0) ? "HELLO queued\n" : "link is off\n");
    }
    else if (argc >= 2 && !strcmp(argv[1], "sync"))
    {
        printf(queue_cmd(CHL_CMD_SYNC, 0, 0, 0) ? "sync queued\n" : "link is off\n");
    }
    else if (argc >= 2 && !strcmp(argv[1], "lat"))
    {
        printf("latency inside the MCU (note-ons only; add the ROM's 1-2 frames, about 17-33 ms, and the BLE/Mac side):\n");
        stat_print("queue wait", &s_wait);
        stat_print("packet (symbols)", &s_packet);
        stat_print("one gpd check", &s_check);
        if (s_wait.n && s_packet.n)
            printf("  => MCU part of a note-on: avg %u ms (wait + packet)\n", (unsigned)((s_wait.sum / s_wait.n + s_packet.sum / s_packet.n) / 1000));
    }
    else if (argc >= 2 && !strcmp(argv[1], "stat"))
    {
        printf("mode %s, armed %s, hold %u ms, next phase %c\n", s_mode == MODE_AUTO ? "auto" : s_mode == MODE_FORCE ? "FORCE" : "off",
               s_armed ? "yes" : "no", (unsigned)s_hold_ms, s_phase ? 'B' : 'A');
        printf("packets sent %u, aborted %u, dropped %u, handshakes %u, queued %u\n", (unsigned)s_sent, (unsigned)s_aborted,
               (unsigned)s_dropped, (unsigned)s_handshakes, (unsigned)uxQueueMessagesWaiting(s_q));
        uint8_t g[8];
        if (ChLink_ReadGpdTimeout(g, 500))
        {
            chl_slot_t s;
            chl_slot_from_gpd(g, &s);
            printf("gpd %02X %02X %02X %02X %02X %02X %02X %02X -> slot len %u seq %u ack %c nack %u data %02X %02X %02X\n",
                   g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7], s.len, s.seq, s.ack ? 'B' : 'A', s.nack, s.data[0],
                   s.data[1], s.data[2]);
            RomState st = RS_OTHER;
            switch (chl_classify(&s))
            {
            case CHL_ROM_KBD: st = RS_KBD; break;
            case CHL_ROM_LEFT: st = RS_LEFT; break;
            default: break;
            }
            printf("ROM: %s\n", state_name(st));
        }
        else
        {
            printf("gpd timeout\n");
        }
    }
    else
    {
        printf("usage: link auto|on|off|hello|sync|stat|lat | link hold <ms>\n");
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
    s_q = xQueueCreate(32, sizeof(chl_cmd_t));
    const esp_console_cmd_t cmds[] = {
        {.command = "link", .help = "ROM link: auto|on|off|hello|sync|stat, hold <ms>", .func = &cmd_link},
        {.command = "note", .help = "play a note over the link: note on <n> [vel] | off <n> | <n> [ms [vel]]", .func = &cmd_note},
        {.command = "midi", .help = "send a MIDI message over the link (hex): midi 90 3c 64", .func = &cmd_midi},
    };
    for (size_t i = 0; i < sizeof(cmds) / sizeof(cmds[0]); i++)
    {
        (void)esp_console_cmd_register(&cmds[i]);
    }
    (void)xTaskCreate(link_task, "chlink_link", 4096, NULL, 17, NULL);
}
