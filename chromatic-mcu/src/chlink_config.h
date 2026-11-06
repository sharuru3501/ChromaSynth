#pragma once
// Overwritten by build.sh: `CHLINK_BLE=0 build.sh` builds the -Os firmware WITHOUT the BLE stack (to tell the
// effect of -Os apart from the effect of BLE on the stock firmware).
#define CHLINK_WITH_BLE 1
