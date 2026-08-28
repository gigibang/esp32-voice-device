#!/usr/bin/env bash
# Restore a full-flash dump back to the device. Reverses dump_flash.sh.
#
# Usage:
#   ./tools/restore_flash.sh vendor_firmware/<stamp>/full_flash_16mb.bin [PORT]

set -euo pipefail
cd "$(dirname "$0")/.."

IMG="${1:?usage: restore_flash.sh <dump.bin> [port]}"
PORT="${2:-$(ls /dev/cu.usbmodem* 2>/dev/null | head -1 || true)}"

if [[ -z "$PORT" ]]; then
    echo "no /dev/cu.usbmodem* device found." >&2
    exit 1
fi

if [[ ! -f "$IMG" ]]; then
    echo "image not found: $IMG" >&2
    exit 1
fi

echo "==> restoring $IMG -> $PORT"
read -r -p "this will OVERWRITE the entire flash. type YES to continue: " ack
[[ "$ack" == "YES" ]] || { echo "aborted."; exit 1; }

python3 -m esptool --chip esp32s3 --port "$PORT" --baud 460800 \
    write_flash 0x0 "$IMG"
