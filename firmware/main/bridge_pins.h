#ifndef BRIDGE_PINS_H
#define BRIDGE_PINS_H

/* Link cable <-> ESP32-S3. See docs/BRIDGE.md section 4 for the wiring, the level shifting
 * and, above all, the voltage measurement that must come first.
 *   Game Boy SC (pin 5, clock)       <- LINK_PIN_SCK   (bridge is the master)
 *   Game Boy SI (pin 3, data in)     <- LINK_PIN_MOSI
 *   Game Boy SO (pin 2, data out)    -> LINK_PIN_MISO
 *   Game Boy GND (pin 6)             -- GND            (VCC, pin 1, stays unconnected)
 * GPIO 11/12/13 are the IO_MUX pins of SPI2 on the ESP32-S3 (MOSI/SCLK/MISO). GPIO 19/20 are the
 * USB data lines and must not be used. */
#define LINK_SPI_HOST SPI2_HOST
#define LINK_PIN_MOSI 11
#define LINK_PIN_SCK  12
#define LINK_PIN_MISO 13

/* SCK frequency while a byte is shifted. 32 kHz = 250 us per byte (docs/BRIDGE.md section 2).
 * ESP-IDF does not document a minimum SPI clock: check the "actual" frequency in the boot log. */
#define LINK_SCK_HZ 32000

/* 1 = drive the link by bit-banging GPIOs instead of the SPI peripheral. Use this if the SPI
 * peripheral cannot make a clock this slow. Can be overridden from the build:
 *   idf.py build -DCMAKE_C_FLAGS=-DLINK_USE_BITBANG=1 */
#ifndef LINK_USE_BITBANG
#define LINK_USE_BITBANG 0
#endif

#endif
