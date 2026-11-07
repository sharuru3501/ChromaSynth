#!/bin/bash
# Writes a new image, runs the hardware tests, and WRITES THE KNOWN-GOOD IMAGE BACK if anything fails. For unattended use only after
# the user has said that writes may proceed without asking (it still never touches anything but the app slot: see flash.sh).
#
#   chromatic-mcu/flash_verify.sh <new.bin> <new sha16> <known-good.bin> <known-good sha16> [soak seconds, default 60]
#
# Tests: tools/mcu_mode_test.py (mode switching, BLE start/stop leak check, `m` rules) and tools/mcu_soak_test.py (a random melody and
# fast bursts through the wired path, OFF in the middle of a stream). The ChromaSynth ROM should be on its KEYBOARD screen (the soak test
# says if it is not). Exit code 0 = the new image stays; 1 = it failed and the known-good image was restored (and checked).
set -u
NEW=${1:?usage}; NEWSHA=${2:?usage}; GOOD=${3:?usage}; GOODSHA=${4:?usage}; SOAK=${5:-60}
HERE=$(cd "$(dirname "$0")" && pwd); REPO=$(cd "$HERE/.." && pwd)
PY=${CHROMATIC_PY:-$HOME/.espressif/python_env/idf5.3_py3.11_env/bin/python}
LOG=${TMPDIR:-/tmp}/flash_verify_$(date +%H%M%S); mkdir -p "$LOG"
fail=0
echo "=== 1. write the new image"
"$HERE/flash.sh" "$NEW" "$NEWSHA" 2>&1 | tee "$LOG/flash.log"
grep -q "APP: readback identical" "$LOG/flash.log" || fail=1
grep -q "HEAD (bootloader, partition table, phy_init; NVS excluded): identical" "$LOG/flash.log" || fail=1
if [ $fail = 0 ]; then
    echo "=== 2. mode test"
    "$PY" "$REPO/tools/mcu_mode_test.py" --cycles 6 --no-sleep-test 2>&1 | tee "$LOG/mode.log" | grep -E "FAIL|ALL PASSED|FAILED"
    grep -q "ALL PASSED" "$LOG/mode.log" || fail=1
fi
if [ $fail = 0 ]; then
    echo "=== 3. soak test ($SOAK s)"
    "$PY" "$REPO/tools/mcu_soak_test.py" --seconds "$SOAK" 2>&1 | tee "$LOG/soak.log" | grep -E "FAIL|ALL PASSED|FAILED|INFO"
    grep -q "ALL PASSED" "$LOG/soak.log" || fail=1
fi
if [ $fail != 0 ]; then
    echo "=== FAILED: restoring the known-good image"
    "$HERE/flash.sh" "$GOOD" "$GOODSHA" 2>&1 | tee "$LOG/rollback.log"
    if grep -q "APP: readback identical" "$LOG/rollback.log"; then
        echo "=== rollback: the known-good image is back (readback identical). Logs in $LOG"
    else
        echo "=== ROLLBACK DID NOT VERIFY: the stock firmware can be restored with ~/Documents/ChromaticBackup/restore_stock.sh. Logs in $LOG"
    fi
    exit 1
fi
echo "=== the new image passed everything and stays. Logs in $LOG"
exit 0
