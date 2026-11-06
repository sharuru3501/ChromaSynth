#!/bin/bash
# Writes ONE image into the app slot (0x10000) of the Chromatic's ESP32, with the safety guards of docs/MCU_FLASH_SAFETY.md.
# NEVER run it without the user's explicit yes for THIS write, after showing the pre-checks (backups intact, the current app slot
# equals the previous build, the image guard below). The ESP32 must be reachable (console on, cartridge in, USB-C connected).
#
#   chromatic-mcu/flash.sh <image.bin> <first 16 hex digits of the image's sha256>
#
# Guards (any failure = nothing is written): the sha256 prefix matches; ESP-IDF image header; app version 0.13.8 and project mcu_fw;
# size <= 1 MB. Afterwards: the app slot is read back and must equal the image, and the first 64 KB (bootloader, partition table,
# phy_init; NVS excluded) must equal the original backup. Restore the stock firmware with ~/Documents/ChromaticBackup/restore_stock.sh.
set -u
IMG=${1:?usage: flash.sh <image.bin> <sha256 prefix, 16 hex digits>}
WANT=${2:?usage: flash.sh <image.bin> <sha256 prefix, 16 hex digits>}
D=${CHROMATIC_BACKUP_DIR:-$HOME/Documents/ChromaticBackup}
. "${IDF_V53:-$HOME/esp/esp-idf-v5.3}/export.sh" >/dev/null 2>&1
P=$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)
[ -n "$P" ] || { echo "No /dev/cu.usbmodem* port: connect the Chromatic (USB-C data cable) with a cartridge in it, console on."; exit 1; }
A=$(ls "$D"/mcu_flash_*_A.bin 2>/dev/null | head -1)
[ -n "$A" ] || { echo "GUARD FAILED: no original backup (mcu_flash_*_A.bin) in $D"; exit 1; }
[ "$(shasum -a 256 "$IMG" | cut -c1-16)" = "$WANT" ] || { echo "GUARD FAILED: the image's sha256 is not $WANT"; exit 1; }
python3 - "$IMG" <<'P' || { echo "GUARD FAILED: not writing"; exit 1; }
import sys
d = open(sys.argv[1], 'rb').read()
assert len(d) <= 0x100000 and d[0] == 0xE9
i = d.find(bytes.fromhex("3254cdab"), 0, 0x1000); assert i > 0
ver = d[i+16:i+48].split(b'\0')[0]; proj = d[i+48:i+80].split(b'\0')[0]
print("guard: size", len(d), "free", 0x100000 - len(d), "version", ver, "project", proj)
assert ver == b'0.13.8' and proj == b'mcu_fw'
P
echo "=== write $(date +%H:%M:%S)"
esptool.py --port "$P" --baud 115200 write_flash 0x10000 "$IMG" 2>&1 | tr '\r' '\n' | grep -E "Wrote|Hash|error|Error|Fatal|Leaving|Flash will"
echo "=== readback $(date +%H:%M:%S)"
N=$(stat -f%z "$IMG")
esptool.py --port "$P" --baud 115200 read_flash 0x10000 "$N" /tmp/rb_app.bin >/dev/null 2>&1
if cmp -s /tmp/rb_app.bin "$IMG"; then echo "APP: readback identical to the image"; else echo "APP: DIFFERENT"; fi
esptool.py --port "$P" --baud 115200 read_flash 0x0 0x10000 /tmp/rb_head.bin >/dev/null 2>&1
dd if="$A" of=/tmp/exp_head.bin bs=1 count=$((0x10000)) 2>/dev/null
python3 - <<'P'
a = open("/tmp/exp_head.bin", "rb").read(); r = open("/tmp/rb_head.bin", "rb").read()
print("HEAD (bootloader, partition table, phy_init; NVS excluded):", "identical to the backup" if a[:0x9000] == r[:0x9000] and a[0xF000:] == r[0xF000:] else "DIFFERENT")
P
echo "done $(date +%H:%M:%S)"
