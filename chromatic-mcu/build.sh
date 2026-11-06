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
. "${IDF_V53:-$HOME/esp/esp-idf-v5.3}/export.sh" >/dev/null 2>&1
rm -f sdkconfig   # generated from sdkconfig.defaults (the patches add BLE and -Os there); a stale one would win
idf.py set-target esp32 >/dev/null 2>&1 || true
idf.py build 2>&1 | tail -4
ls -l build/mcu_fw.bin
shasum -a 256 build/mcu_fw.bin
