/*
 * USB-MIDI device on the ESP32-S3's native USB, through the esp_tinyusb component.
 * The descriptor setup and the call sequence follow ESP-IDF's examples/peripherals/usb/device/tusb_midi
 * (TinyUSB / Espressif, MIT license). NOT compiled against ESP-IDF yet -- see docs/FIRMWARE.md.
 */
#include "usb_midi.h"

#include "esp_err.h"
#include "tinyusb.h"
#include "tinyusb_default_config.h"

enum interface_count {
    ITF_NUM_MIDI = 0,
    ITF_NUM_MIDI_STREAMING,
    ITF_COUNT
};

enum usb_endpoints {
    EP_EMPTY = 0,
    EPNUM_MIDI,
};

#define TUSB_DESCRIPTOR_TOTAL_LEN (TUD_CONFIG_DESC_LEN + CFG_TUD_MIDI * TUD_MIDI_DESC_LEN)

static const char *s_str_desc[5] = {
    (char[]){0x09, 0x04}, /* 0: supported language is English (0x0409) */
    "ChromaSynth",        /* 1: manufacturer */
    "ChromaSynth Bridge", /* 2: product */
    "000001",             /* 3: serial (TODO: derive from the chip ID) */
    "ChromaSynth MIDI",   /* 4: the MIDI interface; this is the port name the DAW shows */
};

static const uint8_t s_cfg_desc[] = {
    /* configuration number, interface count, string index, total length, attribute, power in mA */
    TUD_CONFIG_DESCRIPTOR(1, ITF_COUNT, 0, TUSB_DESCRIPTOR_TOTAL_LEN, 0, 100),
    /* interface number, string index, EP out and EP in address, EP size */
    TUD_MIDI_DESCRIPTOR(ITF_NUM_MIDI, 4, EPNUM_MIDI, (0x80 | EPNUM_MIDI), 64),
};

void usb_midi_init(void)
{
    tinyusb_config_t cfg = TINYUSB_DEFAULT_CONFIG();
    cfg.descriptor.string = s_str_desc;
    cfg.descriptor.string_count = sizeof(s_str_desc) / sizeof(s_str_desc[0]);
    cfg.descriptor.full_speed_config = s_cfg_desc;
    ESP_ERROR_CHECK(tinyusb_driver_install(&cfg));
}

bool usb_midi_mounted(void)
{
    return tud_midi_mounted();
}

size_t usb_midi_read(uint8_t *buf, size_t cap)
{
    /* The MIDI interface always has an input jack: incoming data must be read (even if thrown
     * away) or the host blocks. TODO(verify at build time): tud_midi_stream_read is the raw byte
     * counterpart of tud_midi_stream_write; the example uses tud_midi_packet_read instead. */
    if (!tud_midi_available()) {
        return 0;
    }
    return tud_midi_stream_read(buf, (uint32_t)cap);
}

void usb_midi_write(const uint8_t *buf, size_t len)
{
    if (len == 0 || !tud_midi_mounted()) {
        return;
    }
    tud_midi_stream_write(0, buf, (uint32_t)len); /* cable number 0 */
}
