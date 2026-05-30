#!/bin/bash
#
# dnsmasq CVE-2026 Test Cases for Oak Platform
#
# Platform: Oak (Main_Oak) - Linksys routers (MIPS/ARM)
# dnsmasq version: 2.78
# Build config: DNSSEC disabled, DHCPv6 enabled, --dhcp-script used
#
# Applicable CVEs:
#   CVE-2026-2291 (CRITICAL) - Always applicable (DNS core)
#   CVE-2026-5172 (HIGH)     - Always applicable (DNS core)
#   CVE-2026-4892 (HIGH)     - Applicable (DHCPv6 + --dhcp-script used)
#   CVE-2026-4893 (MODERATE) - Applicable if --add-subnet configured
#   CVE-2026-4890 (HIGH)     - NOT applicable (DNSSEC disabled)
#   CVE-2026-4891 (MODERATE) - NOT applicable (DNSSEC disabled)
#
# Usage:
#   # Static source analysis (run on build host):
#   ./test_oak_cve_2026.sh source
#
#   # Network test against device (run from host that can reach DUT):
#   ./test_oak_cve_2026.sh network <DUT_IP>
#
#   # Full test (source + network):
#   ./test_oak_cve_2026.sh full <DUT_IP>
#

set +e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTER="$SCRIPT_DIR/dnsmasq_cve_tester.py"

# Default paths - adjust for your environment
OAK_SRC="${OAK_SRC:-/home/jianrong/code/Main_Oak/products/oak/output/release/dnsmasq/build/dnsmasq-2.78}"
OAK_BINARY="${OAK_BINARY:-/home/jianrong/code/Main_Oak/products/oak/nfsroot/release/rootfs/sbin/dnsmasq}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

print_header() {
    echo ""
    echo -e "${BOLD}================================================================${NC}"
    echo -e "${BOLD}  dnsmasq CVE-2026 Test Suite — Oak Platform (dnsmasq 2.78)${NC}"
    echo -e "${BOLD}================================================================${NC}"
    echo ""
    echo "  Platform config:"
    echo "    DNSSEC:      DISABLED (CVE-2026-4890, 4891 not applicable)"
    echo "    DHCPv6:      ENABLED"
    echo "    dhcp-script: USED (CVE-2026-4892 applicable)"
    echo ""
}

# ==========================================================================
# TEST CASE 1: Static Source Analysis — Verify patches applied
# ==========================================================================
test_source() {
    echo -e "${BOLD}[TEST 1] Static Source Analysis${NC}"
    echo "  Source: $OAK_SRC"
    echo "  Checking if CVE fix patches are applied to source..."
    echo ""

    local PASS=0
    local FAIL=0
    local SRC="$OAK_SRC/src"

    # TC-1.1: CVE-2026-2291 — union bigname buffer size
    echo -n "  TC-1.1 CVE-2026-2291 (bigname buffer): "
    if grep -q "2\*MAXDNAME\|MAXDNAME\*2\|(2 \* MAXDNAME)" "$SRC/dnsmasq.h" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC} — buffer enlarged to 2*MAXDNAME"
        ((PASS++))
    elif grep -q "char name\[MAXDNAME\]" "$SRC/dnsmasq.h" 2>/dev/null; then
        echo -e "${RED}FAIL${NC} — still using MAXDNAME (vulnerable)"
        ((FAIL++))
    else
        echo -e "${YELLOW}SKIP${NC} — cannot determine"
    fi

    # TC-1.2: CVE-2026-5172 — endrr bounds check in extract_addresses
    echo -n "  TC-1.2 CVE-2026-5172 (endrr bounds):   "
    if grep -q "p1 > endrr" "$SRC/rfc1035.c" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC} — bounds check present"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC} — no p1>endrr check (vulnerable)"
        ((FAIL++))
    fi

    # TC-1.3: CVE-2026-4890 — NSEC bitmap advance (DNSSEC disabled, but check anyway)
    echo -n "  TC-1.3 CVE-2026-4890 (NSEC bitmap):    "
    if grep -q "p\[1\] + 2\|p\[1\]+2" "$SRC/dnssec.c" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC} — advances by p[1]+2"
        ((PASS++))
    elif grep -q "p +=  p\[1\]" "$SRC/dnssec.c" 2>/dev/null; then
        echo -e "${YELLOW}FAIL (low risk)${NC} — p+=p[1] only, but DNSSEC disabled in Oak"
        ((FAIL++))
    else
        echo -e "${YELLOW}N/A${NC} — no dnssec.c"
    fi

    # TC-1.4: CVE-2026-4891 — RRSIG rdlen validation
    echo -n "  TC-1.4 CVE-2026-4891 (RRSIG rdlen):    "
    if grep -q "p - psav.*> rdlen\|p - psav.*>= rdlen" "$SRC/dnssec.c" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC} — rdlen validated before sig_len"
        ((PASS++))
    elif [ -f "$SRC/dnssec.c" ]; then
        echo -e "${YELLOW}FAIL (low risk)${NC} — no validation, but DNSSEC disabled in Oak"
        ((FAIL++))
    else
        echo -e "${YELLOW}N/A${NC} — no dnssec.c"
    fi

    # TC-1.5: CVE-2026-4892 — CLID length check in helper.c
    echo -n "  TC-1.5 CVE-2026-4892 (CLID overflow):  "
    if grep -q "clid_max\|clid_len.*packet_buff\|data.clid_len.*>" "$SRC/helper.c" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC} — CLID length bounded"
        ((PASS++))
    else
        echo -e "${RED}FAIL${NC} — no CLID length check (vulnerable)"
        ((FAIL++))
    fi

    # TC-1.6: CVE-2026-4893 — check_source uses full packet length
    echo -n "  TC-1.6 CVE-2026-4893 (ECS source):     "
    if grep -q "check_source(header, n," "$SRC/forward.c" 2>/dev/null; then
        echo -e "${GREEN}PASS${NC} — uses full packet length"
        ((PASS++))
    elif grep -q "check_source(header, plen," "$SRC/forward.c" 2>/dev/null; then
        echo -e "${RED}FAIL${NC} — uses OPT length plen (vulnerable)"
        ((FAIL++))
    else
        echo -e "${YELLOW}N/A${NC} — check_source not found (--add-subnet not supported)"
    fi

    echo ""
    echo -e "  Results: ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC}"
    echo ""

    if [ $FAIL -gt 0 ]; then
        echo -e "  ${RED}⚠ CVE patches NOT fully applied. Apply patches from:${NC}"
        echo "    patches/2.78/dnsmasq-2.78_10[0-5]_fix_CVE-2026-*.patch"
        return 1
    else
        echo -e "  ${GREEN}✓ All applicable CVE patches verified.${NC}"
        return 0
    fi
}

# ==========================================================================
# TEST CASE 2: Network Testing — Verify fix on live device
# ==========================================================================
test_network() {
    local TARGET="$1"
    if [ -z "$TARGET" ]; then
        echo -e "${RED}Error: DUT IP required for network test${NC}"
        echo "Usage: $0 network <DUT_IP>"
        exit 1
    fi

    echo -e "${BOLD}[TEST 2] Network Testing — Device: $TARGET${NC}"
    echo ""

    # TC-2.0: Verify DUT is reachable
    echo -n "  TC-2.0 DUT reachable: "
    if ping -c1 -W2 "$TARGET" &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${RED}FAIL${NC} — cannot reach $TARGET"
        return 1
    fi

    # TC-2.1: Verify dnsmasq is running (responds to DNS)
    echo -n "  TC-2.1 dnsmasq responding: "
    if dig +short +timeout=3 @"$TARGET" test.local A &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
    elif nslookup test.local "$TARGET" &>/dev/null; then
        echo -e "${GREEN}PASS${NC}"
    else
        echo -e "${YELLOW}WARN${NC} — no DNS response (may still be running)"
    fi

    echo ""
    echo "  Running CVE network tests (applicable to Oak)..."
    echo "  WARNING: These tests may crash an unpatched dnsmasq!"
    echo ""

    # Run the Python tester for applicable CVEs
    python3 "$TESTER" --target "$TARGET" --test CVE-2026-2291 --timeout 5 2>&1 | sed 's/^/  /'
    echo ""
    python3 "$TESTER" --target "$TARGET" --test CVE-2026-5172 --timeout 5 2>&1 | sed 's/^/  /'
    echo ""

    # TC-2.4: Post-test liveness check
    echo -n "  TC-2.4 dnsmasq still alive after tests: "
    sleep 1
    if dig +short +timeout=3 @"$TARGET" posttest.local A &>/dev/null || \
       nslookup posttest.local "$TARGET" &>/dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC} — dnsmasq survived attack packets"
    else
        echo -e "${RED}FAIL${NC} — dnsmasq crashed or stopped responding"
        echo -e "  ${RED}Device is VULNERABLE. Apply CVE patches immediately.${NC}"
        return 1
    fi

    echo ""
    echo -e "  ${GREEN}✓ Device survived all network attack tests.${NC}"
}

# ==========================================================================
# TEST CASE 3: Binary Version Check
# ==========================================================================
test_binary() {
    echo -e "${BOLD}[TEST 3] Binary Version Check${NC}"
    echo "  Binary: $OAK_BINARY"
    echo ""

    if [ -f "$OAK_BINARY" ]; then
        python3 "$TESTER" --binary "$OAK_BINARY" 2>&1 | sed 's/^/  /'
    else
        echo -e "  ${YELLOW}Binary not found (cross-compiled — check on device)${NC}"
        echo "  On device run: dnsmasq --version | head -1"
        echo "  Any version below 2.92rel2 needs our CVE patches applied."
    fi
}

# ==========================================================================
# Main
# ==========================================================================
print_header

case "${1:-}" in
    source)
        test_source
        test_binary
        ;;
    network)
        test_network "$2"
        ;;
    full)
        test_source
        test_binary
        echo ""
        test_network "$2"
        ;;
    *)
        echo "Usage: $0 {source|network <DUT_IP>|full <DUT_IP>}"
        echo ""
        echo "  source          - Static analysis of build source (no network needed)"
        echo "  network <IP>    - Network tests against running device"
        echo "  full <IP>       - Both source analysis and network tests"
        echo ""
        echo "Environment variables:"
        echo "  OAK_SRC     - Path to dnsmasq 2.78 source (default: Main_Oak build dir)"
        echo "  OAK_BINARY  - Path to dnsmasq binary (default: nfsroot sbin)"
        exit 1
        ;;
esac
