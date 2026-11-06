/* Declarations as published in ESP-IDF's driver/spi_master.h and spi_common.h (checked against the
 * GitHub sources while writing link.c), reduced to the parts we use. */
#ifndef STUB_SPI_MASTER_H
#define STUB_SPI_MASTER_H
#include <stddef.h>
#include <stdint.h>
#include "esp_err.h"
typedef enum { SPI2_HOST = 1 } spi_host_device_t;
typedef enum { SPI_DMA_DISABLED = 0, SPI_DMA_CH_AUTO = 3 } spi_common_dma_t;
typedef struct {
    int mosi_io_num, miso_io_num, sclk_io_num, quadwp_io_num, quadhd_io_num;
    int max_transfer_sz;
} spi_bus_config_t;
typedef struct {
    uint8_t mode;
    int clock_speed_hz;
    int spics_io_num;
    int queue_size;
    uint32_t flags;
} spi_device_interface_config_t;
#define SPI_TRANS_USE_RXDATA (1 << 2)
#define SPI_TRANS_USE_TXDATA (1 << 3)
typedef struct {
    uint32_t flags;
    size_t length;
    union { const void *tx_buffer; uint8_t tx_data[4]; };
    union { void *rx_buffer; uint8_t rx_data[4]; };
} spi_transaction_t;
typedef void *spi_device_handle_t;
esp_err_t spi_bus_initialize(spi_host_device_t host, const spi_bus_config_t *cfg, spi_common_dma_t dma);
esp_err_t spi_bus_add_device(spi_host_device_t host, const spi_device_interface_config_t *cfg, spi_device_handle_t *h);
esp_err_t spi_device_polling_transmit(spi_device_handle_t h, spi_transaction_t *t);
esp_err_t spi_device_get_actual_freq(spi_device_handle_t h, int *freq_khz);
#endif
