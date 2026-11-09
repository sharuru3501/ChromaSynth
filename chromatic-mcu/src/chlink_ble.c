// BLE MIDI peripheral with NimBLE. The Mac (or any BLE MIDI central) writes packets to the MIDI Data I/O
// characteristic; chl_blemidi_parse() turns them into MIDI messages and the notes go to the link task.
// Console: `ble` (state and counters), `heap` (free memory: the BLE stack is big, check after it started).
#include "chlink_ble.h"

#include "chlink_config.h"
#include "chlink_link.h"
#include "chlink_proto.h"
#include "esp_console.h"
#include "esp_heap_caps.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <stdio.h>
#include <string.h>

#if CHLINK_WITH_BLE
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "nvs_flash.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static uint8_t s_addr_type;
static volatile bool s_started = false, s_connected = false;
static volatile uint32_t s_writes = 0, s_msgs = 0, s_notes = 0, s_queue_full = 0, s_connects = 0;
static volatile uint8_t s_last_note = 0xFF;   // the note the keyboard is holding (for all-notes-off)
static volatile int s_start_rc = -1;
static TaskHandle_t s_host_task = NULL;       // for `tasks` (the host task is ours: we pass host_task to nimble_port_freertos_init)
static volatile bool s_stopping = false;      // set while the stack is being stopped: no new advertising
static volatile uint16_t s_conn_handle = 0;
// Diagnostics for `ble`: where does a central stall?
static volatile uint32_t s_acc_read = 0, s_acc_write = 0, s_acc_other = 0, s_disconnects = 0, s_subscribes = 0;
static volatile int s_disc_reason = 0, s_conn_status = 0, s_enc_status = -1, s_upd_rc = -99, s_notify_on = 0;
static volatile uint16_t s_mtu = 0, s_conn_itvl = 0;
static uint8_t s_last_pkt[16];
// When the last BLE writes arrived (microseconds): the gaps show how the Mac/Live batches them (connection interval).
#define ARR_N 16
static volatile int64_t s_arr[ARR_N];
static volatile uint32_t s_arr_n = 0;
static volatile uint16_t s_last_pkt_len = 0;

static void advertise(void);

static void on_midi(void *ctx, uint8_t status, uint8_t d1, uint8_t d2)
{
    (void)ctx;
    s_msgs++;
    uint8_t note = 0, vel = 0;
    switch (chl_midi_action(status, d1, d2, &note, &vel))
    {
    case CHL_ACT_NOTE_ON:
        s_last_note = note;
        if (!ChLinkLink_Note(true, note, vel)) s_queue_full++;
        s_notes++;
        break;
    case CHL_ACT_NOTE_OFF:
        if (!ChLinkLink_Note(false, note, 0)) s_queue_full++;
        if (s_last_note == note) s_last_note = 0xFF;
        break;
    case CHL_ACT_ALL_OFF:
        (void)ChLinkLink_Release();      // always: this firmware may have restarted and not know what sounds
        s_last_note = 0xFF;
        break;
    default: break;
    }
}

static int midi_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn;
    (void)attr;
    (void)arg;
    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) s_acc_read++;
    else if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) s_acc_other++;
    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR)
    {
        s_acc_write++;
        uint8_t buf[128];
        uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
        if (len > sizeof buf) len = sizeof buf;
        uint16_t got = 0;
        if (ble_hs_mbuf_to_flat(ctxt->om, buf, len, &got) == 0)
        {
            s_arr[s_arr_n++ % ARR_N] = esp_timer_get_time();
            s_writes++;
            s_last_pkt_len = got;
            memcpy(s_last_pkt, buf, got < sizeof s_last_pkt ? got : sizeof s_last_pkt);
            (void)chl_blemidi_parse(buf, got, on_midi, NULL);
        }
    }
    return 0;   // a read returns an empty value, as the BLE MIDI spec asks
}

static const ble_uuid128_t kSvc = BLE_UUID128_INIT(0x00, 0xC7, 0xC4, 0x4E, 0xE3, 0x6C, 0x51, 0xA7, 0x33, 0x4B, 0xE8, 0xED, 0x5A, 0x0E, 0xB8, 0x03);
static const ble_uuid128_t kChr = BLE_UUID128_INIT(0xF3, 0x6B, 0x10, 0x9D, 0x66, 0xF2, 0xA9, 0xA1, 0x12, 0x41, 0x68, 0x38, 0xDB, 0xE5, 0x72, 0x77);
static uint16_t s_val_handle;
static const struct ble_gatt_svc_def kSvcs[] = {
    {.type = BLE_GATT_SVC_TYPE_PRIMARY,
     .uuid = &kSvc.u,
     .characteristics = (struct ble_gatt_chr_def[]){
         {.uuid = &kChr.u,
          .access_cb = midi_access,
          .val_handle = &s_val_handle,
          .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE_NO_RSP | BLE_GATT_CHR_F_NOTIFY},
         {0}}},
    {0}};

// The ROM's MIDI out (clock, start/stop, the sequencer's notes) to the Mac: one BLE MIDI notification per message, stamped with the
// time the ESP32 read it (13 bits of milliseconds). Only while the Mac has subscribed.
void ChLinkBle_UpHandler(const uint8_t *msg, int len, int64_t t_us)
{
    if (!s_connected || (s_notify_on & 1) == 0 || len < 1 || len > 3)
    {
        return;
    }
    uint8_t pkt[5];
    const uint16_t ts = (uint16_t)((t_us / 1000) & 0x1FFF);
    pkt[0] = 0x80 | ((ts >> 7) & 0x3F);
    pkt[1] = 0x80 | (ts & 0x7F);
    memcpy(pkt + 2, msg, (size_t)len);
    struct os_mbuf *om = ble_hs_mbuf_from_flat(pkt, (uint16_t)(2 + len));
    if (om != NULL)
    {
        (void)ble_gatts_notify_custom(s_conn_handle, s_val_handle, om);
    }
}

static int gap_event(struct ble_gap_event *ev, void *arg)
{
    (void)arg;
    switch (ev->type)
    {
    case BLE_GAP_EVENT_CONNECT:
        s_conn_status = ev->connect.status;
        if (ev->connect.status != 0)
        {
            s_connected = false;
            advertise();
        }
        else
        {
            s_connected = true;
            s_conn_handle = ev->connect.conn_handle;
            s_connects++;
            // 7.5..15 ms: Apple recommends a connection interval of 15 ms or less for BLE MIDI.
            struct ble_gap_upd_params p = {.itvl_min = 6, .itvl_max = 12, .latency = 0, .supervision_timeout = 400};
            s_upd_rc = ble_gap_update_params(ev->connect.conn_handle, &p);
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        s_disconnects++;
        (void)ChLinkLink_Release();              // the Mac is gone: a note that was held must not hang
        s_last_note = 0xFF;
        s_disc_reason = ev->disconnect.reason;   // 0x13 remote user terminated, 0x08 supervision timeout, ...
        s_connected = false;
        s_notify_on = 0;
        ChLinkLink_SetUp(false);
        advertise();
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        s_connected = false;
        advertise();
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        s_subscribes++;
        s_notify_on = ev->subscribe.cur_notify;
        ChLinkLink_SetUp((ev->subscribe.cur_notify & 1) != 0);   // the Mac wants the ROM's MIDI out
        break;
    case BLE_GAP_EVENT_MTU:
        s_mtu = ev->mtu.value;
        break;
    case BLE_GAP_EVENT_ENC_CHANGE:
        s_enc_status = ev->enc_change.status;
        break;
    case BLE_GAP_EVENT_CONN_UPDATE:
        {
            struct ble_gap_conn_desc d;
            if (ble_gap_conn_find(ev->conn_update.conn_handle, &d) == 0) s_conn_itvl = d.conn_itvl;
        }
        break;
    default: break;
    }
    return 0;
}

static void advertise(void)
{
    if (s_stopping)
    {
        return;
    }
    // The 128-bit service UUID fills the advertisement (3 + 18 of 31 bytes); the name goes into the scan response.
    struct ble_hs_adv_fields f;
    memset(&f, 0, sizeof f);
    f.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    f.uuids128 = (ble_uuid128_t *)&kSvc;
    f.num_uuids128 = 1;
    f.uuids128_is_complete = 1;
    (void)ble_gap_adv_set_fields(&f);
    struct ble_hs_adv_fields r;
    memset(&r, 0, sizeof r);
    const char *name = ble_svc_gap_device_name();
    r.name = (const uint8_t *)name;
    r.name_len = (uint8_t)strlen(name);
    r.name_is_complete = 1;
    (void)ble_gap_adv_rsp_set_fields(&r);
    struct ble_gap_adv_params ap;
    memset(&ap, 0, sizeof ap);
    ap.conn_mode = BLE_GAP_CONN_MODE_UND;
    ap.disc_mode = BLE_GAP_DISC_MODE_GEN;
    (void)ble_gap_adv_start(s_addr_type, NULL, BLE_HS_FOREVER, &ap, gap_event, NULL);
}

static void on_sync(void)
{
    (void)ble_hs_id_infer_auto(0, &s_addr_type);
    advertise();
}

static void host_task(void *p)
{
    (void)p;
    s_host_task = xTaskGetCurrentTaskHandle();
    nimble_port_run();
    nimble_port_freertos_deinit();
}

static int cmd_ble(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    printf("BLE MIDI: %s (init rc %d), %s, %u connections\n", s_started ? "started" : "NOT started", s_start_rc,
           s_connected ? "connected" : "not connected", (unsigned)s_connects);
    printf("writes %u, MIDI messages %u, note-ons %u, queue full %u\n", (unsigned)s_writes, (unsigned)s_msgs,
           (unsigned)s_notes, (unsigned)s_queue_full);
    printf("GATT callbacks: read %u, write %u, other %u; subscribed %u (notify %d); MTU %u; interval %u x1.25 ms\n",
           (unsigned)s_acc_read, (unsigned)s_acc_write, (unsigned)s_acc_other, (unsigned)s_subscribes, s_notify_on,
           (unsigned)s_mtu, (unsigned)s_conn_itvl);
    printf("disconnects %u (last reason 0x%02X), connect status %d, encryption status %d, conn-param request rc %d\n",
           (unsigned)s_disconnects, s_disc_reason & 0xFF, s_conn_status, s_enc_status, s_upd_rc);
    {
        const uint32_t n = s_arr_n;
        printf("gaps between the last BLE writes (ms):");
        for (uint32_t i = (n > ARR_N ? n - ARR_N + 1 : 1); i < n; i++)
            printf(" %.1f", (double)(s_arr[i % ARR_N] - s_arr[(i - 1) % ARR_N]) / 1000.0);
        printf("\n");
    }
    printf("last write: %u bytes:", (unsigned)s_last_pkt_len);
    for (unsigned i = 0; i < s_last_pkt_len && i < sizeof s_last_pkt; i++) printf(" %02X", s_last_pkt[i]);
    printf("\n");
    return 0;
}

#endif  // CHLINK_WITH_BLE

static int cmd_heap(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    printf("free heap %u B, lowest ever %u B, largest free block %u B\n", (unsigned)esp_get_free_heap_size(),
           (unsigned)esp_get_minimum_free_heap_size(), (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_8BIT));
    return 0;
}

#if CHLINK_WITH_BLE
void ChLinkBle_Start(void)
{
    const esp_console_cmd_t cmds[] = {
        {.command = "ble", .help = "BLE MIDI state and counters", .func = &cmd_ble},
        {.command = "heap", .help = "free heap memory", .func = &cmd_heap},
    };
    for (size_t i = 0; i < sizeof(cmds) / sizeof(cmds[0]); i++)
    {
        (void)esp_console_cmd_register(&cmds[i]);
    }
    (void)nvs_flash_init();   // the stock firmware has already done this; it is harmless then
}

// Starts (on) or fully stops (off) the BLE stack. Off frees its memory and lets the ESP32 light-sleep again: the BLE
// controller must be shut down for that. Call it from a task with a big enough stack (the mode task), never from the
// NimBLE host task itself.
uint32_t ChLinkBle_HostStackFree(void)
{
    TaskHandle_t t = s_started ? s_host_task : NULL;
    return t ? (uint32_t)uxTaskGetStackHighWaterMark(t) : 0;
}

bool ChLinkBle_Enable(bool on)
{
    if (on == s_started)
    {
        return true;
    }
    if (!on)
    {
        s_stopping = true;
        if (s_connected)
        {
            // Tell the Mac that we are going away (otherwise it keeps showing "connected" until a timeout).
            (void)ble_gap_terminate(s_conn_handle, BLE_ERR_REM_USER_CONN_TERM);
            for (int i = 0; i < 25 && s_connected; i++)
            {
                vTaskDelay(pdMS_TO_TICKS(20));
            }
        }
        (void)ble_gap_adv_stop();
        const int rc = nimble_port_stop();   // waits until the host task has ended
        if (rc == 0)
        {
            nimble_port_deinit();
        }
        s_connected = false;
        s_started = false;
        s_host_task = NULL;
        return rc == 0;
    }
    s_stopping = false;
    s_start_rc = nimble_port_init();
    if (s_start_rc != 0)
    {
        printf("BLE MIDI: nimble_port_init failed (%d); the rest of the firmware is unaffected\n", s_start_rc);
        return false;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    if (ble_gatts_count_cfg(kSvcs) != 0 || ble_gatts_add_svcs(kSvcs) != 0)
    {
        printf("BLE MIDI: GATT setup failed\n");
        return false;
    }
    (void)ble_svc_gap_device_name_set("ChromaSynth");
    nimble_port_freertos_init(host_task);
    s_started = true;
    return true;
}
#else
void ChLinkBle_Start(void)
{
    const esp_console_cmd_t heap = {.command = "heap", .help = "free heap memory", .func = &cmd_heap};
    (void)esp_console_cmd_register(&heap);
    printf("BLE MIDI: not built into this firmware (CHLINK_BLE=0)\n");
}

bool ChLinkBle_Enable(bool on)
{
    return !on;
}

uint32_t ChLinkBle_HostStackFree(void)
{
    return 0;
}
#endif
