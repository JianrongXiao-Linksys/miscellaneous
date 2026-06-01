#!/bin/bash
# test_pinnacle_cve_2021_27137.sh
# Quick wrapper to verify CVE-2021-27137 fix on Pinnacle devices.
#
# Usage: ./test_pinnacle_cve_2021_27137.sh <device_ip> [ssh_password]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DUT_IP="${1:-192.168.1.1}"
DUT_PASS="${2:-}"
UPNP_PORT=5000

if [ -z "$DUT_PASS" ]; then
    echo "Usage: $0 <device_ip> <ssh_password>"
    echo "Example: $0 192.168.1.1 '12345Asdf@'"
    exit 1
fi

python3 "$SCRIPT_DIR/miniupnpd_cve_verify.py" \
    --dut "$DUT_IP" \
    --port "$UPNP_PORT" \
    --dut-user root \
    --dut-pass "$DUT_PASS"
