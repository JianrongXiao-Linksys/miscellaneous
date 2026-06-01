#!/bin/bash
# detect_cve_on_device.sh
# Detect whether CVE-2021-27137 fix is applied on a live device via SSH.
#
# Works by disassembling the parseatt() function in the miniupnpd binary
# and counting the number of comparison instructions against xmlend.
# The fix adds ONE extra comparison — patched binary has more cmp instructions.
#
# No code access needed. Only needs SSH to the device.
#
# Usage:
#   ./detect_cve_on_device.sh <device_ip> <ssh_password>
#   ./detect_cve_on_device.sh 192.168.1.1 '12345Asdf@'

set -euo pipefail

DEVICE_IP="${1:-}"
SSH_PASS="${2:-}"
SSH_USER="root"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $0 <device_ip> <ssh_password>"
    echo ""
    echo "Detects CVE-2021-27137 fix status by analyzing the miniupnpd binary"
    echo "on the device. Requires SSH access only."
    echo ""
    echo "Example: $0 192.168.1.1 '12345Asdf@'"
    exit 1
}

if [ -z "$DEVICE_IP" ] || [ -z "$SSH_PASS" ]; then
    usage
fi

# Check sshpass
if ! command -v sshpass &>/dev/null; then
    echo "ERROR: sshpass required. Install: sudo apt install sshpass"
    exit 1
fi

SSH_CMD="sshpass -p $SSH_PASS ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no $SSH_USER@$DEVICE_IP"

echo "=============================================="
echo " CVE-2021-27137 On-Device Detection"
echo " Target: $DEVICE_IP"
echo "=============================================="
echo ""

# Test SSH connectivity
echo -e "${CYAN}[INFO]${NC} Testing SSH connection..."
VERSION=$($SSH_CMD "miniupnpd --version 2>&1 | head -1" 2>/dev/null) || {
    echo -e "${RED}[ERROR]${NC} Cannot SSH to $DEVICE_IP"
    exit 1
}
echo -e "${GREEN}[OK]${NC} Connected. Version: $VERSION"

# Get PID
PID=$($SSH_CMD "pidof miniupnpd" 2>/dev/null) || PID=""
if [ -n "$PID" ]; then
    echo -e "${GREEN}[OK]${NC} miniupnpd running (PID: $PID)"
else
    echo -e "${YELLOW}[WARN]${NC} miniupnpd not running"
fi

echo ""
echo "--- Detection Method 1: Binary size comparison ---"
echo ""

# Get binary details
BINARY_INFO=$($SSH_CMD "ls -l /usr/sbin/miniupnpd" 2>/dev/null)
echo -e "${CYAN}[INFO]${NC} $BINARY_INFO"

BINARY_SIZE=$($SSH_CMD "wc -c < /usr/sbin/miniupnpd" 2>/dev/null)
echo -e "${CYAN}[INFO]${NC} Binary size: ${BINARY_SIZE} bytes"

# The fix adds ~12-20 bytes of machine code (one cmp + one conditional branch)
# This alone isn't conclusive but is a data point

echo ""
echo "--- Detection Method 2: Disassembly analysis ---"
echo ""

# Check if objdump is available on device
HAS_OBJDUMP=$($SSH_CMD "which objdump 2>/dev/null || echo 'none'" 2>/dev/null)

if [ "$HAS_OBJDUMP" != "none" ] && [ -n "$HAS_OBJDUMP" ]; then
    echo -e "${CYAN}[INFO]${NC} objdump available, disassembling parseatt..."

    # Disassemble and look at the parseatt function
    # Count comparison instructions (the fix adds one extra cmp/ldr pair)
    PARSEATT_DUMP=$($SSH_CMD "objdump -d /usr/sbin/miniupnpd | sed -n '/parseatt>:/,/^$/p' | head -200" 2>/dev/null)

    if [ -n "$PARSEATT_DUMP" ]; then
        # Count comparison-and-branch patterns (ARM: cmp + bcs/bge)
        # The fix adds an additional bounds check = one more cmp+branch pair
        CMP_COUNT=$(echo "$PARSEATT_DUMP" | grep -c "cmp\|ldr.*xmlend" 2>/dev/null || echo "0")
        echo -e "${CYAN}[INFO]${NC} Found $CMP_COUNT comparison instructions in parseatt()"

        # For ARM (Cortex-A7), the unpatched parseatt has ~5 bounds checks
        # The patched version has ~6 bounds checks
        if [ "$CMP_COUNT" -ge 6 ]; then
            echo -e "${GREEN}[LIKELY PATCHED]${NC} Extra bounds check detected ($CMP_COUNT comparisons)"
        else
            echo -e "${RED}[LIKELY VULNERABLE]${NC} Missing bounds check ($CMP_COUNT comparisons, expected >= 6)"
        fi
    else
        echo -e "${YELLOW}[WARN]${NC} Could not find parseatt function in disassembly"
    fi
else
    echo -e "${YELLOW}[INFO]${NC} objdump not available on device, trying alternative..."

    # Alternative: use strings + grep for the comment (unlikely to survive strip)
    FIX_STRING=$($SSH_CMD "strings /usr/sbin/miniupnpd | grep -c 'right after'" 2>/dev/null || echo "0")
    if [ "$FIX_STRING" -gt 0 ]; then
        echo -e "${GREEN}[PATCHED]${NC} Fix signature string found in binary"
    else
        echo -e "${CYAN}[INFO]${NC} No fix string in binary (expected — release builds are stripped)"
    fi
fi

echo ""
echo "--- Detection Method 3: MD5 fingerprint ---"
echo ""

BINARY_MD5=$($SSH_CMD "md5sum /usr/sbin/miniupnpd" 2>/dev/null)
echo -e "${CYAN}[INFO]${NC} $BINARY_MD5"
echo ""
echo "  Compare this MD5 against your known-good (patched) build output:"
echo "  md5sum pinnacle/develop_46_2.2/store/sdk/qsdk/build_dir/target-arm/miniupnpd-nftables/miniupnpd-2.3.3/miniupnpd"
echo ""
echo "  If MD5 matches patched build → FIX APPLIED"
echo "  If MD5 matches unpatched build → VULNERABLE"

echo ""
echo "--- Detection Method 4: Package version (opkg) ---"
echo ""

PKG_INFO=$($SSH_CMD "opkg info miniupnpd-nftables 2>/dev/null || opkg info miniupnpd 2>/dev/null" 2>/dev/null)
if [ -n "$PKG_INFO" ]; then
    PKG_VER=$(echo "$PKG_INFO" | grep "^Version:" | head -1)
    echo -e "${CYAN}[INFO]${NC} $PKG_VER"

    # Check if PKG_RELEASE was bumped (e.g., 2.3.3-3 means patched)
    if echo "$PKG_VER" | grep -qE "2\.3\.3-[3-9]|2\.3\.[4-9]|2\.[4-9]|[3-9]\."; then
        echo -e "${GREEN}[PATCHED]${NC} Package release indicates fix applied"
    else
        echo -e "${RED}[VULNERABLE]${NC} Package version 2.3.3-2 does not include CVE fix"
        echo "  Recommendation: bump PKG_RELEASE to 3 in SDK patch when applying fix"
    fi
else
    echo -e "${YELLOW}[WARN]${NC} opkg not available or package not found"
fi

echo ""
echo "=============================================="
echo " SUMMARY"
echo "=============================================="
echo ""
echo "  Version on device: $VERSION"
echo "  The most reliable method is MD5 comparison against your build."
echo ""
echo "  To make future QA detection trivial, update the SDK patch to"
echo "  also bump PKG_RELEASE from 2 to 3. Then QA only needs:"
echo "    opkg info miniupnpd-nftables | grep Version"
echo "    2.3.3-3 = patched, 2.3.3-2 = vulnerable"
echo ""
echo "=============================================="
