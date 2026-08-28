#!/usr/bin/env bash
# Capture all network traffic from the device via macOS Internet Sharing.
#
# Setup (one-time):
#   1. System Settings → General → Sharing → Internet Sharing
#   2. Share from: Wi-Fi (or Ethernet if Mac is wired)
#   3. To: Wi-Fi
#   4. Click "Wi-Fi Options...": set SSID + WPA2 password (8+ chars)
#   5. Toggle Internet Sharing ON, approve the prompt
#
# Workflow:
#   1. Run this script (it waits for the bridge interface to appear)
#   2. Power on the device, enter SoftAP, configure it to connect to the Mac's hotspot SSID
#   3. The device is now bridged through your Mac — all traffic is captured
#   4. Activate the device (visit xiaozhi.me on your phone, etc.), test voice
#   5. Ctrl-C to stop

set -euo pipefail
cd "$(dirname "$0")/.."

STAMP=$(date +%Y%m%d-%H%M%S)
OUT_DIR="vendor_firmware/captures/${STAMP}"
mkdir -p "$OUT_DIR"

# macOS Internet Sharing exposes clients on bridge100 (or similar).
echo "==> waiting for bridge interface (enable Internet Sharing in System Settings)..."
BRIDGE=""
for _ in $(seq 1 60); do
    BRIDGE=$(ifconfig 2>/dev/null | grep -E '^bridge[0-9]+:' | head -1 | cut -d: -f1 || true)
    if [[ -n "$BRIDGE" ]]; then
        # Make sure it's actually up
        if ifconfig "$BRIDGE" 2>/dev/null | grep -q 'status: active'; then
            break
        fi
    fi
    sleep 1
done

if [[ -z "$BRIDGE" ]]; then
    echo "no bridge interface found after 60s." >&2
    echo "verify Internet Sharing is enabled: System Settings → General → Sharing → Internet Sharing" >&2
    exit 1
fi

echo "==> bridge:  $BRIDGE"
echo "==> output:  $OUT_DIR/"
echo "==> hint:    the device's SoftAP setup page wants the SSID/password of your Mac's hotspot"
echo "==> press Ctrl-C to stop and analyze"
echo

PCAP="$OUT_DIR/capture.pcap"

# tcpdump needs sudo for promiscuous capture
echo "==> sudo password may be required for tcpdump..."
sudo tcpdump -i "$BRIDGE" -w "$PCAP" -s 0 -n -U \
    'not (host 224.0.0.0/4 or host 239.0.0.0/8 or ether multicast)' &
TCPDUMP_PID=$!

cleanup() {
    echo
    echo "==> stopping capture..."
    sudo kill "$TCPDUMP_PID" 2>/dev/null || true
    wait "$TCPDUMP_PID" 2>/dev/null || true
    sudo chown "$(whoami)" "$PCAP" 2>/dev/null || true

    SIZE=$(stat -f%z "$PCAP" 2>/dev/null || echo 0)
    echo "==> saved: $PCAP ($SIZE bytes)"
    echo
    echo "next step:"
    echo "  ./tools/analyze_capture.sh $PCAP"
}
trap cleanup INT TERM EXIT

wait "$TCPDUMP_PID"
