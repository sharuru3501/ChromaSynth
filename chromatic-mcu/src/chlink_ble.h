#pragma once
// BLE MIDI peripheral (docs/BLE_MIDI.md): Mac -> MIDI notes -> ChLinkLink_Note().
void ChLinkBle_Start(void);   // never aborts: if the BLE stack cannot start it only prints why
