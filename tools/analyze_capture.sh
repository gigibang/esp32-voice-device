#!/usr/bin/env bash
# Pull intel out of a device network capture.
#
# Requires: brew install wireshark   (for tshark)
#
# Usage:
#   ./tools/analyze_capture.sh vendor_firmware/captures/<stamp>/capture.pcap

set -euo pipefail
cd "$(dirname "$0")/.."

PCAP="${1:?usage: analyze_capture.sh <capture.pcap>}"
[[ -f "$PCAP" ]] || { echo "pcap not found: $PCAP" >&2; exit 1; }

OUT_DIR="$(dirname "$PCAP")"
REPORT="$OUT_DIR/report.txt"

have() { command -v "$1" >/dev/null 2>&1; }

{
    echo "===== capture summary ====="
    echo "file:  $PCAP"
    echo "size:  $(stat -f%z "$PCAP" 2>/dev/null || stat -c%s "$PCAP") bytes"
    if have capinfos; then
        capinfos "$PCAP" 2>/dev/null | grep -E '^(Number of packets|Capture duration|First packet|Last packet)' || true
    fi
    echo

    echo "===== DNS queries (what hostnames the device looked up) ====="
    if have tshark; then
        tshark -r "$PCAP" -Y 'dns.flags.response == 0' -T fields -e dns.qry.name 2>/dev/null | sort -u
    else
        tcpdump -nr "$PCAP" 'udp port 53' 2>/dev/null | awk -F'? ' 'NF>1 {print $2}' | awk '{print $1}' | sed 's/\.$//' | sort -u
    fi
    echo

    echo "===== TLS SNI (which HTTPS hosts it connected to) ====="
    if have tshark; then
        tshark -r "$PCAP" -Y 'tls.handshake.type == 1' \
               -T fields -e tls.handshake.extensions_server_name 2>/dev/null | sort -u | grep -v '^$' || echo "(none — install wireshark for SNI extraction)"
    else
        echo "(install wireshark: brew install wireshark)"
    fi
    echo

    echo "===== HTTP plaintext requests ====="
    if have tshark; then
        tshark -r "$PCAP" -Y 'http.request' \
               -T fields -e http.request.method -e http.host -e http.request.uri 2>/dev/null | sort -u || echo "(none)"
    fi
    echo

    echo "===== WebSocket connections ====="
    if have tshark; then
        tshark -r "$PCAP" -Y 'http.upgrade contains "websocket"' \
               -T fields -e ip.dst -e tcp.dstport -e http.host -e http.request.uri 2>/dev/null | sort -u || echo "(none, or wrapped in TLS — check SNI list for wss://)"
    fi
    echo

    echo "===== top destination IPs ====="
    if have tshark; then
        tshark -r "$PCAP" -T fields -e ip.dst 2>/dev/null \
            | grep -vE '^(192\.168|10\.|172\.(1[6-9]|2[0-9]|3[01])|224\.|239\.|255\.|0\.)' \
            | sort | uniq -c | sort -rn | head -15
    fi
    echo

    echo "===== protocols/ports breakdown ====="
    if have tshark; then
        tshark -r "$PCAP" -T fields -e ip.proto -e tcp.dstport -e udp.dstport 2>/dev/null \
            | awk 'NF>0 {print}' | sort | uniq -c | sort -rn | head -15
    fi
} | tee "$REPORT"

echo
echo "==> full report: $REPORT"
