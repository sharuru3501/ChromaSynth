#ifndef STUB_FREERTOS_SEMPHR_H
#define STUB_FREERTOS_SEMPHR_H
#include "FreeRTOS.h"
typedef void *SemaphoreHandle_t;
SemaphoreHandle_t xSemaphoreCreateMutex(void);
BaseType_t xSemaphoreTake(SemaphoreHandle_t h, TickType_t t);
BaseType_t xSemaphoreGive(SemaphoreHandle_t h);
#endif
