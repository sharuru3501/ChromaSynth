/* Host-side stub: just enough of ESP-IDF to type-check firmware/main with a normal C compiler.
 * It encodes OUR reading of the API (docs/FIRMWARE.md), so it cannot prove the API exists. */
#ifndef STUB_ESP_ERR_H
#define STUB_ESP_ERR_H
typedef int esp_err_t;
#define ESP_OK 0
#define ESP_ERROR_CHECK(x) do { esp_err_t _e = (x); (void)_e; } while (0)
#endif
