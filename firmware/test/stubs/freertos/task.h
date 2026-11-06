#ifndef STUB_FREERTOS_TASK_H
#define STUB_FREERTOS_TASK_H
#include <stdint.h>
#include "FreeRTOS.h"
typedef void *TaskHandle_t;
BaseType_t xTaskCreatePinnedToCore(void (*fn)(void *), const char *name, uint32_t stack, void *arg, unsigned prio,
                                   TaskHandle_t *handle, int core);
void vTaskDelay(TickType_t ticks);
#endif
