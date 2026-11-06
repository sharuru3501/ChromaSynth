#ifndef LINK_H
#define LINK_H
#include <stdint.h>

/* The Game Boy link as seen from the bridge (the master): one byte out, one byte in. */
void link_init(void);
/* Clocks `tx` out and returns the byte shifted in at the same time. Busy-waits for ~250 us. */
uint8_t link_transfer(uint8_t tx);

#endif
