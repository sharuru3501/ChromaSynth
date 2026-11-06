#ifndef USB_MIDI_H
#define USB_MIDI_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* The bridge as a class-compliant USB-MIDI device (shows up in the DAW without a driver). */
void usb_midi_init(void);
/* Raw MIDI bytes received from the computer; returns how many were copied (0 if none). */
size_t usb_midi_read(uint8_t *buf, size_t cap);
/* Raw MIDI bytes for the computer. Dropped if the host has not enumerated the device. */
void usb_midi_write(const uint8_t *buf, size_t len);
bool usb_midi_mounted(void);

#endif
