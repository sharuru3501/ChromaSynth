#ifndef STUB_GPIO_H
#define STUB_GPIO_H
#include <stdint.h>
#include "esp_err.h"
typedef enum { GPIO_MODE_INPUT = 1, GPIO_MODE_OUTPUT = 2 } gpio_mode_t;
typedef struct { uint64_t pin_bit_mask; gpio_mode_t mode; int pull_up_en; int pull_down_en; int intr_type; } gpio_config_t;
esp_err_t gpio_config(const gpio_config_t *cfg);
esp_err_t gpio_set_level(int gpio, uint32_t level);
int gpio_get_level(int gpio);
#endif
