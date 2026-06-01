#!/bin/bash
# test_pinnacle_cve_2021_27137.sh
# Quick wrapper to test CVE-2021-27137 on Pinnacle devices.
#
# Usage: ./test_pinnacle_cve_2021_27137.sh [device_ip]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DUT_IP="${1:-192.168.1.1}"
DUT_USER="root"
UPNP_PORT=5000

echo "Testing Pinnacle device at $DUT_IP for CVE-2021-27137..."
echo ""

# Check if paramiko is available
python3 -c "import paramiko" 2>/dev/null
if [ $? -eq 0 ]; then
    python3 "$SCRIPT_DIR/miniupnpd_cve_verify.py" \
        --dut "$DUT_IP" \
        --port "$UPNP_PORT" \
        --dut-user "$DUT_USER"
else
    echo "paramiko not installed — running without SSH verification"
    echo "(install: pip install paramiko)"
    echo ""
    python3 "$SCRIPT_DIR/miniupnpd_cve_verify.py" \
        --dut "$DUT_IP" \
        --port "$UPNP_PORT" \
        --no-ssh
fi
