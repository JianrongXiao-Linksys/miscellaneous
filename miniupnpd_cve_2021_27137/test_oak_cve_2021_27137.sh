#!/bin/bash
# test_oak_cve_2021_27137.sh
# Quick wrapper to test CVE-2021-27137 on Oak (Main_Oak) devices.
# Note: Oak uses miniupnpd 1.4 which is also affected by this CVE.
#
# Usage: ./test_oak_cve_2021_27137.sh [device_ip]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DUT_IP="${1:-192.168.1.1}"
DUT_USER="root"
UPNP_PORT=5000

echo "Testing Oak device at $DUT_IP for CVE-2021-27137..."
echo "NOTE: Oak uses miniupnpd 1.4 (ancient) — same vulnerability exists."
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
