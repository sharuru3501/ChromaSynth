#pragma once
#include <stdbool.h>
#include <stdint.h>
// BLE MIDI peripheral (docs/BLE_MIDI.md): Mac -> MIDI notes -> ChLinkLink_Note().
void ChLinkBle_Start(void);   // registers the `ble` and `heap` commands; does NOT start the stack (see ChLinkBle_Enable)
// Starts / fully stops the BLE stack (stopping frees its memory and lets the ESP32 light-sleep). Returns false if it failed;
// the rest of the firmware is unaffected. Not from the NimBLE host task; use a task with a big stack.
bool ChLinkBle_Enable(bool on);
uint32_t ChLinkBle_HostStackFree(void);   // the NimBLE host task's least free stack in bytes (0 when the stack is stopped)

// The uplink handler for the BLE mode (ChLinkLink_SetUpHandler): the ROM's MIDI out goes to the Mac as BLE MIDI notifications.
void ChLinkBle_UpHandler(const uint8_t *msg, int len, int64_t t_us);
