/*
 * ChromaSynth MIDI <-> Game Boy link bridge (ESP32-S3).
 *
 *   USB-MIDI (computer/DAW) <--> bridge core <--> link task <--> Game Boy (link cable)
 *
 * All logic is in core/bridge_core.c (tested on the host against the Python reference model);
 * this file only moves bytes between the core, the USB stack and the link, on two tasks:
 *   link_task (core 1)  clocks one byte through the link at a time, with the timing the ROM needs
 *   midi_task (core 0)  USB-MIDI in/out, and the interpolated clock bytes at their due time
 * The core is not thread-safe: every call is wrapped in g_lock (a mutex: priority inheritance).
 * NOT compiled against ESP-IDF yet -- see docs/FIRMWARE.md.
 */
#include <stdint.h>

#include "bridge_core.h"
#include "esp_log.h"
#include "esp_rom_sys.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "link.h"
#include "usb_midi.h"

static const char *TAG = "bridge";

static bridge_t g_bridge;
static SemaphoreHandle_t g_lock;

#define LOCK()   xSemaphoreTake(g_lock, portMAX_DELAY)
#define UNLOCK() xSemaphoreGive(g_lock)

static inline uint32_t now_us(void)
{
    return (uint32_t)esp_timer_get_time(); /* the core copes with the 32-bit wrap (every 71 minutes) */
}

/* Wait after a link byte. Short gaps are busy-waited (the scheduler tick is 1 ms); long idle
 * waits sleep. An idle poll therefore takes 1-2 ms instead of exactly 2 ms: harmless. */
static void wait_us(uint32_t us)
{
    if (us <= 1000) {
        esp_rom_delay_us(us);
    } else {
        vTaskDelay(pdMS_TO_TICKS(us / 1000));
    }
}

static void link_task(void *arg)
{
    (void)arg;
    for (;;) {
        LOCK();
        br_link_step_t step = bridge_link_next(&g_bridge);
        UNLOCK();

        uint8_t reply = link_transfer(step.tx); /* ~250 us */

        LOCK();
        bridge_link_rx(&g_bridge, reply, now_us());
        UNLOCK();

        wait_us(step.wait_us);
    }
}

static void midi_task(void *arg)
{
    (void)arg;
    uint8_t in[64], out[32];
    for (;;) {
        size_t n = usb_midi_read(in, sizeof in);
        if (n > 0) {
            LOCK();
            bridge_host_in(&g_bridge, in, n);
            UNLOCK();
        }

        size_t k = 0;
        uint8_t x;
        LOCK();
        uint32_t t = now_us();
        while (k < sizeof out && bridge_host_out_pop_due(&g_bridge, t, &x)) {
            out[k++] = x;
        }
        UNLOCK();
        if (k > 0) {
            usb_midi_write(out, k);
        }

        vTaskDelay(1); /* 1 ms: clock bytes to the host are at most 1 ms late */
    }
}

static void stats_task(void *arg)
{
    (void)arg;
    for (;;) {
        vTaskDelay(pdMS_TO_TICKS(2000));
        LOCK();
        ESP_LOGI(TAG, "link %s, losses %u, dropped to GB %u / to host %u, USB %s",
                 g_bridge.link_up ? "UP" : "DOWN", (unsigned)g_bridge.link_down_events,
                 (unsigned)g_bridge.gb_dropped, (unsigned)g_bridge.out_dropped,
                 usb_midi_mounted() ? "mounted" : "not mounted");
        UNLOCK();
    }
}

void app_main(void)
{
    g_lock = xSemaphoreCreateMutex();
    bridge_init(&g_bridge);

    usb_midi_init();
    link_init();

    /* The link task busy-waits for the 250 us gaps; keep it on its own core at a high priority so
     * the USB stack (core 0) cannot delay a byte. TODO(verify): the TinyUSB task's core affinity. */
    xTaskCreatePinnedToCore(link_task, "link", 4096, NULL, configMAX_PRIORITIES - 2, NULL, 1);
    xTaskCreatePinnedToCore(midi_task, "midi", 4096, NULL, 5, NULL, 0);
    xTaskCreatePinnedToCore(stats_task, "stats", 3072, NULL, 1, NULL, 0);
    ESP_LOGI(TAG, "bridge started");
}
