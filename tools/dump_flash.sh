#!/usr/bin/env bash
# Dump the entire 16MB flash from an as-shipped ESP32-S3 device.
# Run BEFORE flashing anything custom — this is your only path back to stock.
#
# NOTE: written for a device whose USB-C port is CHARGE-ONLY (some consumer
# units wire only VBUS/GND, leaving the USB data lines unconnected). On those
# you must open the case, detach the battery, and connect an external
# USB-to-UART adapter to the programming pads: TX, RX, EN, IO0, GND, 3V3.
# Boards that expose the ESP32-S3 native USB (most dev boards) need none of
# that — pass their /dev/cu.usbmodem* port explicitly.
#
# Usage:
#   ./tools/dump_flash.sh                            # auto-detect adapter
#   ./tools/dump_flash.sh /dev/cu.usbserial-XXXX     # explicit port

set -euo pipefail

cd "$(dirname "$0")/.."

PORT="${1:-}"
if [[ -z "$PORT" ]]; then
    # CP210x, CH340, FT232 — typical UART adapter names on macOS
    PORT=$(ls /dev/cu.SLAB_USBtoUART /dev/cu.usbserial-* /dev/cu.wchusbserial* 2>/dev/null | head -1 || true)
    if [[ -z "$PORT" ]]; then
        echo "no USB-UART adapter found at /dev/cu.{SLAB_USBtoUART,usbserial-*,wchusbserial*}" >&2
        echo "if the device's USB-C is charge-only, wire an external UART dongle to the TX/RX/EN/IO0/GND/3V3 pads." >&2
        echo "if the board exposes native USB, pass its port explicitly: $0 /dev/cu.usbmodemXXXX" >&2
        exit 1
    fi
fi

STAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR="vendor_firmware/${STAMP}"
mkdir -p "$OUT_DIR"

echo "==> port:   $PORT"
echo "==> output: $OUT_DIR/"
echo

echo "[1/4] chip info"
python3 -m esptool --chip esp32s3 --port "$PORT" chip_id | tee "$OUT_DIR/chip_id.txt"
echo

echo "[2/4] flash id / size"
python3 -m esptool --chip esp32s3 --port "$PORT" flash_id | tee "$OUT_DIR/flash_id.txt"
echo

echo "[3/4] full 16MB flash dump (this takes ~3 minutes at 460800)"
python3 -m esptool --chip esp32s3 --port "$PORT" --baud 460800 \
    read_flash 0 0x1000000 "$OUT_DIR/full_flash_16mb.bin"
echo

echo "[4/4] partition table dump (offset 0x8000, 0x1000 bytes)"
python3 -m esptool --chip esp32s3 --port "$PORT" --baud 460800 \
    read_flash 0x8000 0x1000 "$OUT_DIR/partition_table.bin"
echo

echo "==> done. Archive:"
ls -lh "$OUT_DIR"
echo
echo "To inspect the partition table:"
echo "  python3 -m esptool --chip esp32s3 image_info $OUT_DIR/partition_table.bin"
