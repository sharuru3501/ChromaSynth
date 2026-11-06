/* Reduced from esp_tinyusb ~3.0.0 / TinyUSB as used in ESP-IDF's tusb_midi example. */
#ifndef STUB_TINYUSB_H
#define STUB_TINYUSB_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
#define CFG_TUD_MIDI 1
#define TUD_CONFIG_DESC_LEN 9
#define TUD_MIDI_DESC_LEN 101
#define TUD_CONFIG_DESCRIPTOR(...) 0x09, 0x02
#define TUD_MIDI_DESCRIPTOR(...) 0x07, 0x24
typedef struct {
    struct { size_t size; uint8_t priority; int xCoreID; } task;
    struct {
        const char **string;
        int string_count;
        const uint8_t *full_speed_config;
    } descriptor;
} tinyusb_config_t;
#define TINYUSB_DEFAULT_CONFIG() ((tinyusb_config_t){0})
esp_err_t tinyusb_driver_install(const tinyusb_config_t *cfg);
bool tud_midi_mounted(void);
uint32_t tud_midi_available(void);
uint32_t tud_midi_stream_read(void *buffer, uint32_t bufsize);
uint32_t tud_midi_stream_write(uint8_t cable_num, const uint8_t *buffer, uint32_t bufsize);
#endif
