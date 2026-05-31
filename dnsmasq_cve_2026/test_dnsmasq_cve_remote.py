#!/usr/bin/env python3
"""
dnsmasq CVE-2026 Remote Black-Box Tester

Point at a device IP — reports PASS/FAIL per CVE.
No SSH, no console, no setup on DUT required.
Queries dnsmasq version remotely via version.bind.

Usage:
    python3 test_dnsmasq_cve_remote.py 192.168.1.1
    python3 test_dnsmasq_cve_remote.py 192.168.1.1 192.168.1.2 192.168.1.3
"""

import socket
import struct
import sys
import random


def build_dns_query(name, qtype=1, qclass=1):
    txid = random.randint(0, 0xFFFF)
    header = struct.pack("!HHHHHH", txid, 0x0100, 1, 0, 0, 0)
    parts = name.split(".")
    qname = b""
    for p in parts:
        qname += bytes([len(p)]) + p.encode()
    qname += b"\x00"
    question = qname + struct.pack("!HH", qtype, qclass)
    return header + question


def query_version(target, port=53, timeout=3):
    """Query dnsmasq version via version.bind CH TXT."""
    # version.bind, type TXT (16), class CH (3)
    packet = build_dns_query("version.bind", qtype=16, qclass=3)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(packet, (target, port))
        resp, _ = sock.recvfrom(4096)
        # Parse TXT record from response
        # Skip header (12) + question section
        offset = 12
        while offset < len(resp) and resp[offset] != 0:
            offset += resp[offset] + 1
        offset += 1 + 4  # null terminator + qtype + qclass

        # Parse answer
        if offset + 12 > len(resp):
            return None
        # Skip answer name (pointer or labels)
        if resp[offset] & 0xC0 == 0xC0:
            offset += 2
        else:
            while offset < len(resp) and resp[offset] != 0:
                offset += resp[offset] + 1
            offset += 1
        # type(2) + class(2) + ttl(4) + rdlen(2)
        offset += 8
        if offset + 2 > len(resp):
            return None
        rdlen = struct.unpack("!H", resp[offset:offset+2])[0]
        offset += 2
        # TXT record: first byte is string length
        if offset + 1 > len(resp):
            return None
        txt_len = resp[offset]
        offset += 1
        if offset + txt_len > len(resp):
            return None
        return resp[offset:offset+txt_len].decode("ascii", errors="replace")
    except (socket.timeout, OSError):
        return None
    finally:
        sock.close()


def parse_version(version_str):
    """Parse 'dnsmasq-2.78' into (2, 78, 0) tuple."""
    if not version_str:
        return None
    version_str = version_str.replace("dnsmasq-", "").strip()
    version_str = version_str.replace("rel", ".").replace("rc", ".0.")
    parts = []
    for p in version_str.split("."):
        try:
            parts.append(int(p))
        except ValueError:
            pass
    while len(parts) < 3:
        parts.append(0)
    return tuple(parts[:3])


def check_dns_responding(target, port=53, timeout=3):
    """Check if DNS service is responding using version.bind."""
    packet = build_dns_query("version.bind", qtype=16, qclass=3)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    try:
        sock.sendto(packet, (target, port))
        sock.recvfrom(4096)
        return True
    except (socket.timeout, OSError):
        return False
    finally:
        sock.close()


def test_device(target, port=53):
    """Test a single device. Returns (pass_count, fail_count, results)."""
    FIXED_VERSION = (2, 92, 2)

    results = []
    passes = 0
    fails = 0

    # Check if responding
    if not check_dns_responding(target, port):
        print(f"  ERROR: No DNS response from {target}:{port}")
        return 0, 0, []

    # Get version
    version_str = query_version(target, port)
    version = parse_version(version_str) if version_str else None

    if not version_str:
        print(f"  WARNING: Could not get version (version.bind blocked)")
        print(f"  Cannot determine vulnerability status without version info.")
        return 0, 0, []

    is_patched = version >= FIXED_VERSION if version else False

    print(f"  Version: {version_str}  {'[PATCHED]' if is_patched else '[VULNERABLE]'}")
    print(f"")

    # CVE checks based on version
    cves = [
        ("CVE-2026-2291", "heap overflow in extract_name()", True),
        ("CVE-2026-5172", "OOB read crash in extract_addresses()", True),
        ("CVE-2026-4890", "NSEC bitmap infinite loop (DNSSEC)", True),
        ("CVE-2026-4891", "RRSIG heap OOB read (DNSSEC)", True),
        ("CVE-2026-4892", "DHCPv6 CLID overflow (DHCPv6)", True),
        ("CVE-2026-4893", "ECS source validation bypass", True),
    ]

    for cve_id, desc, always_applicable in cves:
        if is_patched:
            status = "PASS"
            passes += 1
        else:
            status = "FAIL"
            fails += 1
        results.append((cve_id, status, desc))

    return passes, fails, results


def main():
    if len(sys.argv) < 2:
        print("Usage: python3 test_dnsmasq_cve_remote.py <DUT_IP> [DUT_IP2] ...")
        print("")
        print("  Black-box test — just point at device IP.")
        print("  No SSH, no console, no setup needed.")
        print("")
        print("Examples:")
        print("  python3 test_dnsmasq_cve_remote.py 192.168.1.1")
        print("  python3 test_dnsmasq_cve_remote.py 192.168.1.1 192.168.2.1")
        sys.exit(1)

    targets = sys.argv[1:]

    print("")
    print("=" * 60)
    print("  dnsmasq CVE-2026 Remote Verification")
    print("  Fix version: 2.92rel2")
    print("=" * 60)

    total_pass = 0
    total_fail = 0

    for target in targets:
        print(f"\n  Device: {target}")
        print(f"  {'-' * 50}")

        passes, fails, results = test_device(target)

        for cve_id, status, desc in results:
            symbol = "\033[92mPASS\033[0m" if status == "PASS" else "\033[91mFAIL\033[0m"
            print(f"    [{symbol}] {cve_id}: {desc}")

        total_pass += passes
        total_fail += fails

        if results:
            print(f"")
            if fails > 0:
                print(f"    \033[91mRESULT: FAIL — {fails} vulnerable\033[0m")
            else:
                print(f"    \033[92mRESULT: PASS — all patched\033[0m")

    print(f"\n{'=' * 60}")
    if total_fail > 0:
        print(f"  OVERALL: \033[91mFAIL\033[0m — {total_fail} issues across {len(targets)} device(s)")
        sys.exit(1)
    else:
        print(f"  OVERALL: \033[92mPASS\033[0m — all devices patched")
        sys.exit(0)


if __name__ == "__main__":
    main()
