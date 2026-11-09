// MIDI mode: OFF / BLE / USB.
//   OFF  link idle, BLE stack stopped (memory freed), light sleep allowed again (the stock behaviour)
//   BLE  BLE stack on, link on, the ESP32 stays awake
//   USB  BLE stack stopped, link on, the ESP32 stays awake (the Mac helper writes `m 90 3c 64` on the serial console)
// The OSD menu item (System > MIDI MODE: A = next, B = previous) lives here too.
#include "chlink_mode.h"

#include "chlink_ble.h"
#include "chlink_link.h"
#include "chlink_proto.h"
#include "esp_console.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "lvgl.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "osd_shared.h"
#include "pwrmgr.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

LV_IMG_DECLARE(img_a_right);
LV_IMG_DECLARE(img_b_left);

static QueueHandle_t s_q;
static TaskHandle_t s_mode_task = NULL;
static volatile ChMidiMode s_mode = CHM_OFF;      // requested (shown by the menu)
static volatile ChMidiMode s_applied = CHM_OFF;   // what the mode task has finished setting up
static volatile uint32_t s_switches = 0;
// The Mac app (ChromaSynth Link) sends `hb` every 3 s while it holds the USB mode. Once a heartbeat has been seen, 10 s without
// one (the cable was pulled, the app quit) puts the saved mode back. The app sends `hb` every second: 3 s is quick, and still
// three missed beats. Helpers that never send `hb` are not affected.
static volatile bool s_requested = false;         // something has asked for a mode since the boot (then the saved mode is not applied over it)
static volatile int64_t s_hb_us = 0;
static volatile bool s_hb_seen = false;
static ChMidiMode s_boot_mode = CHM_OFF;          // the mode saved by the last OSD selection (applied a few seconds after boot)

// The mode chosen in the OSD menu (or by `mode set`) is kept in flash (NVS namespace "chlink", key "mode"), so the next boot starts
// in it. A `mode <m>` typed on the console (what the Mac helper does) is temporary and is not saved.
static void persist(ChMidiMode m)
{
    nvs_handle_t h;
    if (nvs_open("chlink", NVS_READWRITE, &h) != ESP_OK)
    {
        return;
    }
    uint8_t old = 0xFF;
    (void)nvs_get_u8(h, "mode", &old);
    if (old != (uint8_t)m)
    {
        (void)nvs_set_u8(h, "mode", (uint8_t)m);
        (void)nvs_commit(h);
    }
    nvs_close(h);
}

static ChMidiMode load_saved(void)
{
    nvs_handle_t h;
    uint8_t v = 0;
    ChMidiMode m = CHM_OFF;
    if (nvs_open("chlink", NVS_READONLY, &h) == ESP_OK)
    {
        if (nvs_get_u8(h, "mode", &v) == ESP_OK && v < CHM_COUNT)
        {
            m = (ChMidiMode)v;
        }
        nvs_close(h);
    }
    return m;
}

const char *ChMode_Name(ChMidiMode m)
{
    return m == CHM_BLE ? "BLE" : m == CHM_USB ? "USB" : "OFF";
}

ChMidiMode ChMode_Get(void)
{
    return s_mode;
}

void ChMode_Request(ChMidiMode m)
{
    if ((unsigned)m >= CHM_COUNT || s_q == NULL)
    {
        return;
    }
    s_mode = m;
    s_requested = true;
    (void)xQueueSend(s_q, &m, 0);
}

static void apply(ChMidiMode m)
{
    if (s_applied != CHM_OFF)
    {
        (void)ChLinkLink_Release();           // a note that the old source left sounding stops before the switch
        vTaskDelay(pdMS_TO_TICKS(150));       // (the link task sends it)
    }
    switch (m)
    {
    case CHM_BLE:
        PwrMgr_ChlinkKeepAwake(true);        // first: the BLE controller cannot coexist with light sleep
        ChLinkLink_SetEnabled(true);
        (void)ChLinkBle_Enable(true);
        break;
    case CHM_USB:
        PwrMgr_ChlinkKeepAwake(true);
        (void)ChLinkBle_Enable(false);
        ChLinkLink_SetEnabled(true);
        break;
    default:
        ChLinkLink_SetEnabled(false);
        (void)ChLinkBle_Enable(false);
        PwrMgr_ChlinkKeepAwake(false);       // last: the ESP32 may light-sleep again
        break;
    }
    s_applied = m;
    s_switches++;
}

static void mode_task(void *arg)
{
    (void)arg;
    if (s_boot_mode != CHM_OFF)
    {
        vTaskDelay(pdMS_TO_TICKS(3000));      // let the rest of the firmware start first (the stock code is still initialising)
        if (!s_requested)                     // (a helper that already asked for a mode keeps what it asked)
        {
            ChMode_Request(s_boot_mode);
        }
    }
    for (;;)
    {
        ChMidiMode m;
        if (xQueueReceive(s_q, &m, pdMS_TO_TICKS(1000)) == pdTRUE)
        {
            while (xQueueReceive(s_q, &m, 0) == pdTRUE)
            {
            }                                // only the latest request counts
            apply(m);
        }
        else if (s_hb_seen && s_applied == CHM_USB && esp_timer_get_time() - s_hb_us > 3 * 1000 * 1000LL)
        {
            s_hb_seen = false;               // the Mac side is gone: back to the saved mode
            ChMode_Request(load_saved());
        }
    }
}

// ---------------------------------------------------------------- console
static int cmd_mode(int argc, char **argv)
{
    if (argc >= 2)
    {
        ChMidiMode m = CHM_COUNT;
        bool save = false;
        int arg = 1;
        if (!strcmp(argv[1], "set") && argc >= 3)
        {
            save = true;                      // `mode set ble`: also the mode of the next boot
            arg = 2;
        }
        if (!strcmp(argv[arg], "saved")) m = load_saved();      // `mode saved`: the mode of the next boot, now
        else if (!strcmp(argv[arg], "off")) m = CHM_OFF;
        else if (!strcmp(argv[arg], "ble")) m = CHM_BLE;
        else if (!strcmp(argv[arg], "usb")) m = CHM_USB;
        if (m == CHM_COUNT)
        {
            printf("usage: mode [set] [off|ble|usb|saved]   (`set` also saves it for the next boot)\n");
            return -1;
        }
        if (save)
        {
            persist(m);
        }
        ChMode_Request(m);
        for (int i = 0; i < 80 && s_applied != m; i++)
        {
            vTaskDelay(pdMS_TO_TICKS(10));   // let the mode task finish (starting BLE takes a moment): at most 0.8 s
        }
    }
    printf("MIDI mode %s (applied %s), saved for boot: %s, %u switches, hb %s\n", ChMode_Name(s_mode), ChMode_Name(s_applied),
           ChMode_Name(load_saved()), (unsigned)s_switches, s_hb_seen ? "seen" : "not seen");
    return 0;
}

static int cmd_hb(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    s_hb_us = esp_timer_get_time();
    s_hb_seen = true;
    return 0;
}

// A MIDI message from the wired helper: m <status> <d1> [d2] in hex, e.g. m 90 3c 64. Prints nothing (it is called for every
// note). Accepted only in the USB mode: BLE and wired input are never both live.
static int cmd_m(int argc, char **argv)
{
    if (argc < 3 || argc > 4 || s_applied != CHM_USB)
    {
        return 0;
    }
    const uint8_t st = (uint8_t)strtol(argv[1], NULL, 16);
    const uint8_t d1 = (uint8_t)strtol(argv[2], NULL, 16);
    const uint8_t d2 = (argc == 4) ? (uint8_t)strtol(argv[3], NULL, 16) : 0;
    uint8_t note = 0, vel = 0;
    static uint8_t held = 0xFF;
    switch (chl_midi_action(st, d1, d2, &note, &vel))
    {
    case CHL_ACT_NOTE_ON:
        held = note;
        (void)ChLinkLink_Note(true, note, vel);
        break;
    case CHL_ACT_NOTE_OFF:
        (void)ChLinkLink_Note(false, note, 0);
        if (held == note) held = 0xFF;
        break;
    case CHL_ACT_ALL_OFF:
        if (held != 0xFF)
        {
            (void)ChLinkLink_Note(false, held, 0);
            held = 0xFF;
        }
        break;
    default:
        break;
    }
    return 0;
}

static int cmd_tasks(int argc, char **argv)
{
    (void)argc;
    (void)argv;
    printf("least free stack, bytes: link %u of 3072, mode %u of 4096, console (this task) %u, NimBLE host %u (0 = stopped)\n",
           (unsigned)ChLinkLink_StackFree(), s_mode_task ? (unsigned)uxTaskGetStackHighWaterMark(s_mode_task) : 0u,
           (unsigned)uxTaskGetStackHighWaterMark(NULL), (unsigned)ChLinkBle_HostStackFree());
    return 0;
}

void ChMode_Init(void)
{
    (void)nvs_flash_init();                 // the stock firmware has done it already; harmless then
    s_boot_mode = load_saved();
    s_q = xQueueCreate(4, sizeof(ChMidiMode));
    const esp_console_cmd_t cmds[] = {
        {.command = "mode", .help = "MIDI mode: mode [off|ble|usb]", .func = &cmd_mode},
        {.command = "hb", .help = "heartbeat of the Mac app (USB mode falls back to the saved mode after 10 s without it)", .func = &cmd_hb},
        {.command = "m", .help = "wired MIDI message (hex): m 90 3c 64", .func = &cmd_m},
        {.command = "tasks", .help = "least free stack of our tasks (bytes)", .func = &cmd_tasks},
    };
    for (size_t i = 0; i < sizeof(cmds) / sizeof(cmds[0]); i++)
    {
        (void)esp_console_cmd_register(&cmds[i]);
    }
    (void)xTaskCreate(mode_task, "chlink_mode", 4096, NULL, 5, &s_mode_task);   // measured: about 1.8 KB used at the BLE start (`tasks`)
}

// ---------------------------------------------------------------- OSD menu item (System > MIDI MODE)
enum { kLabelX_px = 99, kLabelY_px = 63, kArrowBX_px = 80, kArrowAX_px = 131, kArrowY_px = 63 };

static lv_obj_t *s_label, *s_img_a, *s_img_b;

OSD_Result_t ChMode_Draw(void *arg)
{
    if (arg == NULL)
    {
        return kOSD_Result_Err_NullDataPtr;
    }
    lv_obj_t *const pScreen = (lv_obj_t *const)arg;
    if (s_label == NULL)
    {
        s_label = lv_label_create(pScreen);
        lv_obj_add_style(s_label, OSD_GetStyleTextWhite_L(), 0);
        lv_obj_align(s_label, LV_ALIGN_TOP_LEFT, kLabelX_px, kLabelY_px);
    }
    if (s_img_b == NULL)
    {
        s_img_b = lv_img_create(pScreen);
        lv_obj_align(s_img_b, LV_ALIGN_TOP_LEFT, kArrowBX_px, kArrowY_px);
        lv_img_set_src(s_img_b, &img_b_left);
    }
    if (s_img_a == NULL)
    {
        s_img_a = lv_img_create(pScreen);
        lv_obj_align(s_img_a, LV_ALIGN_TOP_LEFT, kArrowAX_px, kArrowY_px);
        lv_img_set_src(s_img_a, &img_a_right);
    }
    lv_label_set_text(s_label, ChMode_Name(s_mode));
    lv_obj_move_foreground(s_label);
    lv_obj_move_foreground(s_img_a);
    lv_obj_move_foreground(s_img_b);
    return kOSD_Result_Ok;
}

OSD_Result_t ChMode_OnButton(const Button_t Button, const ButtonState_t State, void *arg)
{
    (void)arg;
    if (State != kButtonState_Pressed)
    {
        return kOSD_Result_Ok;
    }
    if (Button == kButton_A)
    {
        ChMode_Request((ChMidiMode)((s_mode + 1) % CHM_COUNT));
        persist(s_mode);                    // the OSD choice is kept for the next boot
    }
    else if (Button == kButton_B)
    {
        ChMode_Request((ChMidiMode)((s_mode + CHM_COUNT - 1) % CHM_COUNT));
        persist(s_mode);
    }
    if (s_label != NULL)
    {
        lv_label_set_text(s_label, ChMode_Name(s_mode));   // show the new mode at once; the mode task applies it
    }
    return kOSD_Result_Ok;
}

OSD_Result_t ChMode_OnTransition(void *arg)
{
    (void)arg;
    lv_obj_t **const objs[] = {&s_label, &s_img_a, &s_img_b};
    for (size_t i = 0; i < sizeof(objs) / sizeof(objs[0]); i++)
    {
        if (*objs[i] != NULL)
        {
            lv_obj_del(*objs[i]);
            *objs[i] = NULL;
        }
    }
    return kOSD_Result_Ok;
}
