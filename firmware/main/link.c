/*
 * The Game Boy link, master side. The Game Boy's "normal mode" serial port is SPI mode 3
 * (clock idles high, data changes on the falling edge and is sampled on the rising edge,
 * MSB first), and the Game Boy is the slave (external clock), so the SPI master peripheral
 * can drive it directly. Builds with ESP-IDF v5.5.6; not run on hardware yet -- see docs/FIRMWARE.md.
 */
#include "link.h"

#include "bridge_pins.h"
#include "esp_err.h"
#include "esp_log.h"

static const char *TAG = "link";

#if LINK_USE_BITBANG

#include "driver/gpio.h"
#include "esp_rom_sys.h"

#define HALF_BIT_US (500000 / LINK_SCK_HZ)

void link_init(void)
{
    gpio_config_t out = {
        .pin_bit_mask = (1ULL << LINK_PIN_SCK) | (1ULL << LINK_PIN_MOSI),
        .mode = GPIO_MODE_OUTPUT,
    };
    gpio_config_t in = {
        .pin_bit_mask = 1ULL << LINK_PIN_MISO,
        .mode = GPIO_MODE_INPUT,
    };
    ESP_ERROR_CHECK(gpio_config(&out));
    ESP_ERROR_CHECK(gpio_config(&in));
    gpio_set_level(LINK_PIN_SCK, 1); /* idle high */
    gpio_set_level(LINK_PIN_MOSI, 1);
    ESP_LOGI(TAG, "bit-banged link, %d us per half bit", HALF_BIT_US);
}

uint8_t link_transfer(uint8_t tx)
{
    uint8_t rx = 0;
    for (int i = 7; i >= 0; i--) {
        gpio_set_level(LINK_PIN_SCK, 0);             /* falling edge: the Game Boy shifts its bit out */
        gpio_set_level(LINK_PIN_MOSI, (tx >> i) & 1);
        esp_rom_delay_us(HALF_BIT_US);
        gpio_set_level(LINK_PIN_SCK, 1);             /* rising edge: both sides sample */
        rx = (uint8_t)((rx << 1) | (gpio_get_level(LINK_PIN_MISO) & 1));
        esp_rom_delay_us(HALF_BIT_US);
    }
    return rx;
}

#else /* SPI peripheral */

#include "driver/spi_master.h"

static spi_device_handle_t s_dev;

void link_init(void)
{
    spi_bus_config_t bus = {
        .mosi_io_num = LINK_PIN_MOSI,
        .miso_io_num = LINK_PIN_MISO,
        .sclk_io_num = LINK_PIN_SCK,
        .quadwp_io_num = -1,
        .quadhd_io_num = -1,
        .max_transfer_sz = 4,
    };
    ESP_ERROR_CHECK(spi_bus_initialize(LINK_SPI_HOST, &bus, SPI_DMA_DISABLED));

    spi_device_interface_config_t dev = {
        .clock_speed_hz = LINK_SCK_HZ,
        .mode = 3,           /* CPOL = 1, CPHA = 1 */
        .spics_io_num = -1,  /* no chip select on the link */
        .queue_size = 1,
    };
    ESP_ERROR_CHECK(spi_bus_add_device(LINK_SPI_HOST, &dev, &s_dev));

    int khz = 0;
    ESP_ERROR_CHECK(spi_device_get_actual_freq(s_dev, &khz));
    ESP_LOGI(TAG, "link SCK: requested %d Hz, actual %d kHz", LINK_SCK_HZ, khz);
    if (khz < 20 || khz > 40) {
        ESP_LOGW(TAG, "actual clock is far from the request: set LINK_USE_BITBANG 1 in bridge_pins.h");
    }
}

uint8_t link_transfer(uint8_t tx)
{
    spi_transaction_t t = {
        .flags = SPI_TRANS_USE_TXDATA | SPI_TRANS_USE_RXDATA,
        .length = 8, /* bits */
        .tx_data = {tx},
    };
    ESP_ERROR_CHECK(spi_device_polling_transmit(s_dev, &t));
    return t.rx_data[0];
}

#endif
