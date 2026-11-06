#ifndef STUB_ESP_LOG_H
#define STUB_ESP_LOG_H
#include <stdio.h>
#define ESP_LOGI(tag, fmt, ...) printf("I %s: " fmt "\n", tag, ##__VA_ARGS__)
#define ESP_LOGW(tag, fmt, ...) printf("W %s: " fmt "\n", tag, ##__VA_ARGS__)
#endif
