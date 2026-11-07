#!/bin/bash
# Build the ChromaSynth test firmware for the Chromatic's built-in ESP32:
#   ModRetro's MCU firmware v4.6 (GPL-3.0) + the patches in chromatic-mcu/patches/.
# Needs ESP-IDF v5.3 in ~/esp/esp-idf-v5.3 (the version v4.6 is built with). Does NOT flash anything.
# usage: chromatic-mcu/build.sh [work dir]      (default: ~/chromatic-mcu-build)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=${1:-$HOME/chromatic-mcu-build}
TAG=v4.6
if [ ! -d "$WORK/.git" ]; then
    git clone --depth 1 --branch "$TAG" https://github.com/ModRetro/oss-chromatic-console-mcu "$WORK"
fi
cd "$WORK"
git reset -q --hard && git clean -fdq main   # back to the pristine tag, keep build/ and managed_components/
for p in "$HERE"/patches/*.patch; do git apply "$p"; echo "applied $(basename "$p")"; done
cp "$HERE"/src/*.c "$HERE"/src/*.h main/   # the link core and task (src/ is also what the host tests build)
if [ "${CHLINK_BLE:-1}" = "0" ]; then   # -Os without the BLE stack: to tell the effect of -Os from that of BLE
    echo "#pragma once" > main/chlink_config.h
    echo "#define CHLINK_WITH_BLE 0" >> main/chlink_config.h
    grep -v -E "CONFIG_BT_|CONFIG_BTDM_" sdkconfig.defaults > sdkconfig.defaults.tmp && mv sdkconfig.defaults.tmp sdkconfig.defaults
    echo "built WITHOUT BLE (CHLINK_BLE=0)"
fi
. "${IDF_V53:-$HOME/esp/esp-idf-v5.3}/export.sh" >/dev/null 2>&1
if [ "${CHLINK_BLE_TRIM:-0}" = "1" ]; then   # CANDIDATE, not verified with a Mac: no BLE security (pairing) and fewer BLE buffers
    cat >> sdkconfig.defaults <<'TRIM'
# chlink BLE trim (CHLINK_BLE_TRIM=1): about 95 KB less flash. Needs a real BLE MIDI connection test from a Mac before it is flashed.
CONFIG_BT_NIMBLE_SECURITY_ENABLE=n
CONFIG_BT_NIMBLE_MSYS_1_BLOCK_COUNT=8
CONFIG_BT_NIMBLE_MSYS_2_BLOCK_COUNT=12
TRIM
    echo "built with the BLE trim (CHLINK_BLE_TRIM=1): NOT verified with a Mac"
fi
rm -f sdkconfig   # generated from sdkconfig.defaults (the patches add BLE and -Os there); a stale one would win
idf.py set-target esp32 >/dev/null 2>&1 || true
idf.py build > build.log 2>&1 || { grep -E "error|Error|undefined|FAILED" -A3 build.log | head -30; echo "BUILD FAILED (full log: $WORK/build.log)"; exit 1; }
tail -4 build.log
ls -l build/mcu_fw.bin
shasum -a 256 build/mcu_fw.bin
