#!/bin/bash
#
# dnsmasq CVE-2026 Test Cases for Pinnacle Platform
#
# Platform: Pinnacle (OpenWrt/QSDK) - Linksys routers (ARM/IPQ)
# dnsmasq version: 2.90 (upgrading to 2.92rel2)
# Build variant: nodhcpv6 (-DNO_DHCP6)
# DNSSEC: configurable (may be enabled in full variant)
#
# Applicable CVEs:
#   CVE-2026-2291 (CRITICAL) - Always applicable (DNS core)
#   CVE-2026-5172 (HIGH)     - Always applicable (DNS core)
#   CVE-2026-4890 (HIGH)     - Applicable if DNSSEC enabled
#   CVE-2026-4891 (MODERATE) - Applicable if DNSSEC enabled
#   CVE-2026-4893 (MODERATE) - Applicable if --add-subnet configured
#   CVE-2026-4892 (HIGH)     - NOT applicable (nodhcpv6 variant, -DNO_DHCP6)
#
# Usage:
#   # Static source analysis — before patch (shows VULNERABLE):
#   ./test_pinnacle_cve_2026.sh source-before
#
#   # Static source analysis — after upgrade to 2.92rel2 (shows PATCHED):
#   ./test_pinnacle_cve_2026.sh source-after
#
#   # Network test against device:
#   ./test_pinnacle_cve_2026.sh network <DUT_IP>
#
#   # Full test:
#   ./test_pinnacle_cve_2026.sh full <DUT_IP>
#

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTER="$SCRIPT_DIR/dnsmasq_cve_tester.py"

# Default paths - adjust for your environment
PINNACLE_SRC_BEFORE="${PINNACLE_SRC_BEFORE:-/home/jianrong/code/pinnacle/develop_46_2.2/store/sdk/qsdk/build_dir/target-arm/dnsmasq-nodhcpv6/dnsmasq-2.90}"
PINNACLE_SRC_AFTER="${PINNACLE_SRC_AFTER:-}"
PINNACLE_BINARY="${PINNACLE_BINARY:-/home/jianrong/code/pinnacle/develop_46_2.2/store/sdk/qsdk/build_dir/target-arm/dnsmasq-nodhcpv6/dnsmasq-2.90/src/dnsmasq}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BOLD}================================================================${NC}"
    echo -e "${BOLD}  dnsmasq CVE-2026 Test Suite — Pinnacle Platform${NC}"
    echo -e "${BOLD}================================================================${NC}"
    echo ""
    echo "  Platform config:"
    echo "    Build variant: nodhcpv6 (-DNO_DHCP6)"
    echo "    DNSSEC:        Configurable (disabled in nodhcpv6, enabled in full)"
    echo "    DHCPv6:        DISABLED (CVE-2026-4892 not applicable)"
    echo ""
    echo "  Fix approach: Upgrade dnsmasq 2.90 → 2.92rel2"
    echo "  sdk_patch: 2113_upgrade_dnsmasq_2.92rel2_fix_CVE-2026.patch"
    echo ""
}

# ==========================================================================
# TEST CASE 1: Static Source Analysis — Before patch (confirm vulnerable)
# ==========================================================================
test_source_before() {
    local SRC="${1:-$PINNACLE_SRC_BEFORE}/src"
    echo -e "${BOLD}[TEST 1] Static Source Analysis — BEFORE patch${NC}"
    echo "  Source: ${1:-$PINNACLE_SRC_BEFORE}"
    echo "  Expected: ALL CVEs should show VULNERABLE"
    echo ""

    local VULN=0

    # TC-1.1: CVE-2026-2291
    echo -n "  TC-1.1 CVE-2026-2291 (bigname buffer): "
    if grep -q "char name\[MAXDNAME\]" "$SRC/dnsmasq.h" 2>/dev/null && \
       ! grep -q "2\*MAXDNAME" "$SRC/dnsmasq.h" 2>/dev/null; then
        echo -e "${RED}VULNERABLE${NC} (expected)"
        ((VULN++))
    else
        echo -e "${GREEN}PATCHED${NC} (unexpected — already fixed?)"
    fi

    # TC-1.2: CVE-2026-5172
    echo -n "  TC-1.2 CVE-2026-5172 (endrr bounds):   "
    if ! grep -q "p1 > endrr" "$SRC/rfc1035.c" 2>/dev/null; then
        echo -e "${RED}VULNERABLE${NC} (expected)"
        ((VULN++))
    else
        echo -e "${GREEN}PATCHED${NC} (unexpected)"
    fi

    # TC-1.3: CVE-2026-4890
    echo -n "  TC-1.3 CVE-2026-4890 (NSEC bitmap):    "
    if grep -q "p +=  p\[1\]" "$SRC/dnssec.c" 2>/dev/null && \
       ! grep -q "p\[1\] + 2\|p\[1\]+2" "$SRC/dnssec.c" 2>/dev/null; then
        echo -e "${RED}VULNERABLE${NC} (expected)"
        ((VULN++))
    else
        echo -e "${GREEN}PATCHED${NC} (unexpected)"
    fi

    # TC-1.4: CVE-2026-4891
    echo -n "  TC-1.4 CVE-2026-4891 (RRSIG rdlen):    "
    if ! grep -q "p - psav.*> rdlen\|p - psav.*>= rdlen\|p - psav.*rdlen" "$SRC/dnssec.c" 2>/dev/null; then
        echo -e "${RED}VULNERABLE${NC} (expected)"
        ((VULN++))
    else
        echo -e "${GREEN}PATCHED${NC} (unexpected)"
    fi

    # TC-1.5: CVE-2026-4893
    echo -n "  TC-1.5 CVE-2026-4893 (ECS plen vs n):  "
    if grep -q "check_source(header, plen," "$SRC/forward.c" 2>/dev/null; then
        echo -e "${RED}VULNERABLE${NC} (expected)"
        ((VULN++))
    else
        echo -e "${GREEN}PATCHED or N/A${NC}"
    fi

    # TC-1.6: CVE-2026-4892 (should be N/A for nodhcpv6)
    echo -n "  TC-1.6 CVE-2026-4892 (CLID overflow):  "
    echo -e "${YELLOW}N/A${NC} — nodhcpv6 variant (DHCPv6 disabled)"

    echo ""
    echo -e "  Confirmed ${RED}$VULN vulnerabilities${NC} in unpatched source."
    echo "  This validates the test can detect the issues."
    echo ""
}

# ==========================================================================
# TEST CASE 2: Static Source Analysis — After upgrade to 2.92rel2
# ==========================================================================
test_source_after() {
    local SRC_DIR="${1:-$PINNACLE_SRC_AFTER}"

    if [ -z "$SRC_DIR" ] || [ ! -d "$SRC_DIR" ]; then
        echo -e "${BOLD}[TEST 2] Static Source Analysis — AFTER patch${NC}"
        echo ""
        echo -e "  ${YELLOW}No patched source available yet.${NC}"
        echo "  After applying sdk_patch 2113 and rebuilding, set:"
        echo "    PINNACLE_SRC_AFTER=/path/to/build_dir/dnsmasq-2.92rel2"
        echo "  Then re-run: $0 source-after"
        echo ""
        echo "  Alternatively, download and test 2.92rel2 directly:"
        echo "    wget https://thekelleys.org.uk/dnsmasq/dnsmasq-2.92rel2.tar.xz"
        echo "    tar xf dnsmasq-2.92rel2.tar.xz"
        echo "    PINNACLE_SRC_AFTER=./dnsmasq-2.92rel2 $0 source-after"
        echo ""
        return 0
    fi

    local SRC="$SRC_DIR/src"
    echo -e "${BOLD}[TEST 2] Static Source Analysis — AFTER patch (2.92rel2)${NC}"
    echo "  Source: $SRC_DIR"
    echo "  Expected: ALL CVEs should show PATCHED"
    echo ""

    local PASS=0
    local FAIL=0

    # TC-2.1: CVE-2026-2291
    echo -n "  TC-2.1 CVE-2026-2291 (bigname buffer): "
    if grep -q "2\*MAXDNAME\|MAXDNAME\*2" "$SRC/dnsmasq.h" 2>/dev/null; then
        echo -e "${GREEN}PATCHED${NC}"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC} — still vulnerable"
        ((FAIL++))
    fi

    # TC-2.2: CVE-2026-5172
    echo -n "  TC-2.2 CVE-2026-5172 (endrr bounds):   "
    if grep -q "p1 > endrr\|> endrr" "$SRC/rfc1035.c" 2>/dev/null; then
        echo -e "${GREEN}PATCHED${NC}"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC} — no bounds check"
        ((FAIL++))
    fi

    # TC-2.3: CVE-2026-4890
    echo -n "  TC-2.3 CVE-2026-4890 (NSEC bitmap):    "
    if grep -q "p\[1\] + 2\|p\[1\]+2\|+ 2;" "$SRC/dnssec.c" 2>/dev/null; then
        echo -e "${GREEN}PATCHED${NC}"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC} — still uses p[1] only"
        ((FAIL++))
    fi

    # TC-2.4: CVE-2026-4891
    echo -n "  TC-2.4 CVE-2026-4891 (RRSIG rdlen):    "
    if grep -q "p - psav.*rdlen\|psav.*> rdlen" "$SRC/dnssec.c" 2>/dev/null; then
        echo -e "${GREEN}PATCHED${NC}"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC} — no rdlen validation"
        ((FAIL++))
    fi

    # TC-2.5: CVE-2026-4893
    echo -n "  TC-2.5 CVE-2026-4893 (ECS full length): "
    if grep -q "check_source(header, n," "$SRC/forward.c" 2>/dev/null; then
        echo -e "${GREEN}PATCHED${NC}"
        ((PASS++))
    elif ! grep -q "check_source" "$SRC/forward.c" 2>/dev/null; then
        echo -e "${YELLOW}N/A${NC} — no check_source"
    else
        echo -e "${RED}FAIL${NC}"
        ((FAIL++))
    fi

    # TC-2.6: CVE-2026-4892
    echo -n "  TC-2.6 CVE-2026-4892 (CLID overflow):  "
    echo -e "${YELLOW}N/A${NC} — nodhcpv6 variant"

    # TC-2.7: Version check
    echo -n "  TC-2.7 Version >= 2.92rel2:            "
    if grep -q "2.92rel2\|2.93\|2.94" "$SRC_DIR/CHANGELOG" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
        ((PASS++))
    else
        echo -e "${YELLOW}UNKNOWN${NC}"
    fi

    echo ""
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
    if [ $FAIL -eq 0 ]; then
        echo -e "  ${GREEN}✓ All CVEs fixed in 2.92rel2 source.${NC}"
    fi
    echo ""
}

# ==========================================================================
# TEST CASE 3: Network Testing — Live device verification
# ==========================================================================
test_network() {
    local TARGET="$1"
    if [ -z "$TARGET" ]; then
        echo -e "${RED}Error: DUT IP required for network test${NC}"
        echo "Usage: $0 network <DUT_IP>"
        exit 1
    fi

    echo -e "${BOLD}[TEST 3] Network Testing — Device: $TARGET${NC}"
    echo ""

    # TC-3.0: Verify DUT reachable
    echo -n "  TC-3.0 DUT reachable: "
    if ping -c1 -W2 "$TARGET" &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${RED}FAIL${NC} — cannot reach $TARGET"
        return 1
    fi

    # TC-3.1: DNS service check
    echo -n "  TC-3.1 DNS responding: "
    if dig +short +timeout=3 @"$TARGET" test.local A &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${YELLOW}WARN${NC} — no response (may use different port or ACL)"
    fi

    echo ""
    echo "  Running applicable CVE tests..."
    echo "  WARNING: May crash unpatched device!"
    echo ""

    # Test CVE-2026-2291 (always applicable)
    echo -e "  ${BOLD}--- CVE-2026-2291 (Critical — heap overflow) ---${NC}"
    python3 "$TESTER" --target "$TARGET" --test CVE-2026-2291 --timeout 5 2>&1 | grep -E "Testing|Severity|VULNERABLE|PATCHED|CRASH|details" | sed 's/^/  /'
    echo ""

    # Test CVE-2026-5172 (always applicable)
    echo -e "  ${BOLD}--- CVE-2026-5172 (High — OOB read crash) ---${NC}"
    python3 "$TESTER" --target "$TARGET" --test CVE-2026-5172 --timeout 5 2>&1 | grep -E "Testing|Severity|VULNERABLE|PATCHED|CRASH|details" | sed 's/^/  /'
    echo ""

    # Test CVE-2026-4890 (if DNSSEC enabled)
    echo -e "  ${BOLD}--- CVE-2026-4890 (High — NSEC DoS) ---${NC}"
    python3 "$TESTER" --target "$TARGET" --test CVE-2026-4890 --timeout 8 2>&1 | grep -E "Testing|Severity|VULNERABLE|PATCHED|CRASH|details|DNSSEC" | sed 's/^/  /'
    echo ""

    # TC-3.5: Post-test liveness
    echo -n "  TC-3.5 dnsmasq alive after all tests: "
    sleep 2
    if dig +short +timeout=3 @"$TARGET" alive-check.local A &>/dev/null || \
       nslookup alive-check.local "$TARGET" &>/dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC} — device survived"
    else
        echo -e "${RED}FAIL${NC} — dnsmasq not responding (CRASHED)"
        echo -e "  ${RED}⚠ Device is VULNERABLE. Apply sdk_patch 2113.${NC}"
        return 1
    fi

    echo ""
    echo -e "  ${GREEN}✓ Device survived all CVE network tests — likely patched.${NC}"
}

# ==========================================================================
# TEST CASE 4: Version/SDK Patch Verification
# ==========================================================================
test_sdk_patch() {
    echo -e "${BOLD}[TEST 4] SDK Patch Verification${NC}"
    echo ""

    local PATCH_FILE="/home/jianrong/code/pinnacle/develop/sdks/qualcomm/qsdk-spf12.5_csu1/sdk_patches/2113_upgrade_dnsmasq_2.92rel2_fix_CVE-2026.patch"

    echo -n "  TC-4.1 sdk_patch exists: "
    if [ -f "$PATCH_FILE" ]; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${RED}FAIL${NC} — patch not found"
        return 1
    fi

    echo -n "  TC-4.2 Patch upgrades to 2.92rel2: "
    if grep -q "PKG_UPSTREAM_VERSION:=2.92rel2" "$PATCH_FILE" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${RED}FAIL${NC}"
    fi

    echo -n "  TC-4.3 Patch updates hash: "
    if grep -q "43d72b8c129bdf33d17bafedc98823f63e46b5005128066bf0d2a472a32ce06a" "$PATCH_FILE" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${RED}FAIL${NC}"
    fi

    echo -n "  TC-4.4 Patch removes upstream patches: "
    if grep -q "+++ /dev/null" "$PATCH_FILE" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC} — removes 0001/0002 (now upstream)"
    else
        echo -e "${YELLOW}WARN${NC} — check manually"
    fi

    echo -n "  TC-4.5 Patch rebases remaining patches: "
    local REBASED=$(grep -c "^+---\|^+\+\+\+" "$PATCH_FILE" 2>/dev/null || echo 0)
    if [ "$REBASED" -gt 10 ]; then
        echo -e "${GREEN}PASS${NC} — contains rebased inner patches"
    else
        echo -e "${YELLOW}WARN${NC} — verify inner patch content"
    fi

    echo ""
}

# ==========================================================================
# Main
# ==========================================================================
print_header

case "${1:-}" in
    source-before|source)
        test_source_before
        ;;
    source-after)
        test_source_after "$2"
        ;;
    network)
        test_network "$2"
        ;;
    sdk-patch|patch)
        test_sdk_patch
        ;;
    full)
        test_source_before
        test_sdk_patch
        echo ""
        test_network "$2"
        ;;
    *)
        echo "Usage: $0 {source-before|source-after [path]|network <IP>|sdk-patch|full <IP>}"
        echo ""
        echo "  source-before       - Verify current 2.90 source is vulnerable"
        echo "  source-after [path] - Verify 2.92rel2 source has fixes"
        echo "  network <IP>        - Network tests against live device"
        echo "  sdk-patch           - Verify sdk_patch 2113 content"
        echo "  full <IP>           - All tests combined"
        echo ""
        echo "Environment variables:"
        echo "  PINNACLE_SRC_BEFORE - Path to dnsmasq 2.90 source"
        echo "  PINNACLE_SRC_AFTER  - Path to dnsmasq 2.92rel2 source (after rebuild)"
        exit 1
        ;;
esac
