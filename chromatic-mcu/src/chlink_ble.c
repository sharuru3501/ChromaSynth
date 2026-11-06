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
        if (s_last_note != 0xFF)
        {
            (void)ChLinkLink_Note(false, s_last_note, 0);
            s_last_note = 0xFF;
        }
        break;
    default: break;
    }
}

static int midi_access(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn;
    (void)attr;
    (void)arg;
    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR)
    {
        uint8_t buf[128];
        uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
        if (len > sizeof buf) len = sizeof buf;
        uint16_t got = 0;
        if (ble_hs_mbuf_to_flat(ctxt->om, buf, len, &got) == 0)
        {
            s_writes++;
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

static int gap_event(struct ble_gap_event *ev, void *arg)
{
    (void)arg;
    switch (ev->type)
    {
    case BLE_GAP_EVENT_CONNECT:
        if (ev->connect.status != 0)
        {
            s_connected = false;
            advertise();
        }
        else
        {
            s_connected = true;
            s_connects++;
            // 7.5..15 ms: Apple recommends a connection interval of 15 ms or less for BLE MIDI.
            struct ble_gap_upd_params p = {.itvl_min = 6, .itvl_max = 12, .latency = 0, .supervision_timeout = 400};
            (void)ble_gap_update_params(ev->connect.conn_handle, &p);
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
    case BLE_GAP_EVENT_ADV_COMPLETE:
        s_connected = false;
        advertise();
        break;
    default: break;
    }
    return 0;
}

static void advertise(void)
{
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
    s_start_rc = nimble_port_init();
    if (s_start_rc != 0)
    {
        printf("BLE MIDI: nimble_port_init failed (%d); the rest of the firmware is unaffected\n", s_start_rc);
        return;
    }
    ble_hs_cfg.sync_cb = on_sync;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    if (ble_gatts_count_cfg(kSvcs) != 0 || ble_gatts_add_svcs(kSvcs) != 0)
    {
        printf("BLE MIDI: GATT setup failed\n");
        return;
    }
    (void)ble_svc_gap_device_name_set("ChromaSynth");
    nimble_port_freertos_init(host_task);
    s_started = true;
}
#else
void ChLinkBle_Start(void)
{
    const esp_console_cmd_t heap = {.command = "heap", .help = "free heap memory", .func = &cmd_heap};
    (void)esp_console_cmd_register(&heap);
    printf("BLE MIDI: not built into this firmware (CHLINK_BLE=0)\n");
}
#endif
