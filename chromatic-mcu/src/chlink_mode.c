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
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "lvgl.h"
#include "osd_shared.h"
#include "pwrmgr.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

LV_IMG_DECLARE(img_a_right);
LV_IMG_DECLARE(img_b_left);

static QueueHandle_t s_q;
static volatile ChMidiMode s_mode = CHM_OFF;      // requested (shown by the menu)
static volatile ChMidiMode s_applied = CHM_OFF;   // what the mode task has finished setting up
static volatile uint32_t s_switches = 0;

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
    (void)xQueueSend(s_q, &m, 0);
}

static void apply(ChMidiMode m)
{
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
    for (;;)
    {
        ChMidiMode m;
        if (xQueueReceive(s_q, &m, portMAX_DELAY) == pdTRUE)
        {
            while (xQueueReceive(s_q, &m, 0) == pdTRUE)
            {
            }                                // only the latest request counts
            apply(m);
        }
    }
}

// ---------------------------------------------------------------- console
static int cmd_mode(int argc, char **argv)
{
    if (argc >= 2)
    {
        ChMidiMode m = CHM_COUNT;
        if (!strcmp(argv[1], "off")) m = CHM_OFF;
        else if (!strcmp(argv[1], "ble")) m = CHM_BLE;
        else if (!strcmp(argv[1], "usb")) m = CHM_USB;
        if (m == CHM_COUNT)
        {
            printf("usage: mode [off|ble|usb]\n");
            return -1;
        }
        ChMode_Request(m);
        vTaskDelay(pdMS_TO_TICKS(800));   // let the mode task finish (starting BLE takes a moment)
    }
    printf("MIDI mode %s (applied %s), %u switches\n", ChMode_Name(s_mode), ChMode_Name(s_applied), (unsigned)s_switches);
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

void ChMode_Init(void)
{
    s_q = xQueueCreate(4, sizeof(ChMidiMode));
    const esp_console_cmd_t cmds[] = {
        {.command = "mode", .help = "MIDI mode: mode [off|ble|usb]", .func = &cmd_mode},
        {.command = "m", .help = "wired MIDI message (hex): m 90 3c 64", .func = &cmd_m},
    };
    for (size_t i = 0; i < sizeof(cmds) / sizeof(cmds[0]); i++)
    {
        (void)esp_console_cmd_register(&cmds[i]);
    }
    (void)xTaskCreate(mode_task, "chlink_mode", 6144, NULL, 5, NULL);
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
    }
    else if (Button == kButton_B)
    {
        ChMode_Request((ChMidiMode)((s_mode + CHM_COUNT - 1) % CHM_COUNT));
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
