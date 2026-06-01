#!/bin/sh
# test_miniupnpd_cve_on_device.sh
# Run directly on the DUT to check miniupnpd version and binary info.
# Does NOT send exploit payloads — use miniupnpd_cve_verify.py for that.
#
# Usage: scp this to DUT, then run:
#   sh /tmp/test_miniupnpd_cve_on_device.sh

echo "=============================================="
echo " CVE-2021-27137 miniupnpd On-Device Check"
echo " Date: $(date)"
echo "=============================================="
echo ""

# Check if miniupnpd is running
PID=$(pidof miniupnpd)
if [ -n "$PID" ]; then
    echo "[OK] miniupnpd is running (PID: $PID)"
else
    echo "[WARN] miniupnpd is NOT running"
fi

# Get version
echo ""
echo "--- Version Info ---"
if command -v miniupnpd >/dev/null 2>&1; then
    miniupnpd --version 2>&1 | head -3
else
    echo "miniupnpd binary not found in PATH"
    # Try common locations
    for bin in /usr/sbin/miniupnpd /usr/bin/miniupnpd /sbin/miniupnpd; do
        if [ -x "$bin" ]; then
            echo "Found: $bin"
            $bin --version 2>&1 | head -3
            break
        fi
    done
fi

# Check listening port
echo ""
echo "--- Listening Port ---"
if command -v netstat >/dev/null 2>&1; then
    netstat -tlnp 2>/dev/null | grep miniupnpd
elif command -v ss >/dev/null 2>&1; then
    ss -tlnp | grep miniupnpd
fi

# Check UPnP config
echo ""
echo "--- UPnP Configuration ---"
if [ -f /etc/config/upnpd ]; then
    cat /etc/config/upnpd
elif [ -f /etc/miniupnpd/miniupnpd.conf ]; then
    head -30 /etc/miniupnpd/miniupnpd.conf
else
    echo "No config file found"
fi

# Check if the fix is applied (look for the bounds check in binary)
echo ""
echo "--- Binary Vulnerability Check ---"
BINARY=""
for bin in /usr/sbin/miniupnpd /usr/bin/miniupnpd /sbin/miniupnpd; do
    if [ -x "$bin" ]; then
        BINARY="$bin"
        break
    fi
done

if [ -n "$BINARY" ]; then
    # Check binary size and date
    ls -la "$BINARY"
    echo ""

    # Check compile-time strings for version hints
    if command -v strings >/dev/null 2>&1; then
        VERSION_STR=$(strings "$BINARY" | grep -i "miniupnpd.*[0-9]\.[0-9]" | head -3)
        if [ -n "$VERSION_STR" ]; then
            echo "Version strings in binary:"
            echo "$VERSION_STR"
        fi
    fi

    echo ""
    echo "NOTE: Cannot definitively check patch status from binary alone."
    echo "      Use miniupnpd_cve_verify.py from testing laptop for live verification."
fi

# Check dmesg for past crashes
echo ""
echo "--- Recent Crash History (dmesg) ---"
dmesg 2>/dev/null | grep -i "miniupnpd\|segfault" | tail -5
if [ $? -ne 0 ]; then
    echo "(no miniupnpd crash entries found)"
fi

echo ""
echo "=============================================="
echo " Check complete."
echo " For live exploit testing, use miniupnpd_cve_verify.py from laptop."
echo "=============================================="
