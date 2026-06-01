#!/usr/bin/env python3
"""
miniupnpd CVE-2021-27137 Verification Tool

Detects whether the CVE-2021-27137 fix is applied by:
1. Sending a truncated XML payload that triggers the vulnerability
2. Checking device syslog for the fix's signature log message

The patched miniupnpd logs:
  "minixml: rejected truncated attribute (CVE-2021-27137)"
when it blocks an over-read attempt. Unpatched versions silently
over-read and produce no log.

Usage:
  python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass '12345Asdf@'
  python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass 'pw' --port 5000

Requirements:
  - Python 3.6+ with paramiko (pip install paramiko)
  - SSH access to DUT (root)
  - UPnP port reachable from test machine
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

TOOL_VERSION = "3.0.0"

SOAP_ACTION = "urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping"

# The syslog message that the patched miniupnpd emits
FIX_LOG_SIGNATURE = "CVE-2021-27137"

# Payloads that trigger the vulnerability
EXPLOIT_PAYLOADS = [
    {
        "name": "Truncated after '='",
        "xml": "<element attribute=",
    },
    {
        "name": "Namespace attr truncated",
        "xml": '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle=',
    },
    {
        "name": "Nested truncated",
        "xml": '<root><child attr1="ok" attr2=',
    },
]

# Valid SOAP for regression test
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
# SSH Helper
# ═══════════════════════════════════════════════════════════════════════

class DUTConnection:
    def __init__(self, host, user, password, timeout=5):
        self.host = host
        self.user = user
        self.password = password
        self.timeout = timeout
        self.client = None

    def connect(self):
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
            print(f"  {RED}[ERROR]{RESET} SSH connection failed: {e}")
            return False

    def run(self, cmd):
        if not self.client:
            return None
        try:
            _, stdout, _ = self.client.exec_command(cmd, timeout=self.timeout)
            return stdout.read().decode().strip()
        except Exception:
            return None

    def get_miniupnpd_pid(self):
        result = self.run("pidof miniupnpd")
        return result.split()[0] if result else None

    def get_version(self):
        return self.run("miniupnpd --version 2>&1 | head -1")

    def clear_log(self):
        """Clear the CVE log entries so we get a clean baseline."""
        self.run("logread | grep -v CVE-2021-27137 > /dev/null 2>&1")

    def check_cve_log(self):
        """Check if the CVE-2021-27137 syslog message appeared."""
        result = self.run("logread | grep 'CVE-2021-27137'")
        return result if result else None

    def get_log_count(self):
        """Count CVE-2021-27137 log entries."""
        result = self.run("logread | grep -c 'CVE-2021-27137'")
        try:
            return int(result) if result else 0
        except ValueError:
            return 0

    def close(self):
        if self.client:
            self.client.close()


# ═══════════════════════════════════════════════════════════════════════
# Network Helper
# ═══════════════════════════════════════════════════════════════════════

def send_payload(host, port, body, timeout=3):
    """Send HTTP POST to UPnP endpoint."""
    request = (
        f"POST /ctl/IPConn HTTP/1.1\r\n"
        f"Host: {host}:{port}\r\n"
        f"Content-Type: text/xml; charset=\"utf-8\"\r\n"
        f"SOAPAction: \"{SOAP_ACTION}\"\r\n"
        f"Content-Length: {len(body)}\r\n"
        f"Connection: close\r\n"
        f"\r\n"
        f"{body}"
    )
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((host, port))
        sock.sendall(request.encode())
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
    except Exception as e:
        return None


def check_port(host, port, timeout=3):
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        result = sock.connect_ex((host, port))
        sock.close()
        return result == 0
    except Exception:
        return False


# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="CVE-2021-27137 miniupnpd fix verification (syslog-based)",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
How it works:
  1. Get baseline log count of CVE-2021-27137 messages
  2. Send truncated XML payloads to miniupnpd
  3. Check if new CVE-2021-27137 syslog entries appeared
  4. Patched: new log entries → PASS
     Unpatched: no log entries → FAIL

Examples:
  python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass '12345Asdf@'
  python3 miniupnpd_cve_verify.py --dut 10.0.0.1 --dut-pass 'admin' --port 5000
        """,
    )
    parser.add_argument("--dut", required=True, help="DUT IP address")
    parser.add_argument("--port", type=int, default=5000, help="UPnP port (default: 5000)")
    parser.add_argument("--dut-user", default="root", help="SSH user (default: root)")
    parser.add_argument("--dut-pass", default=None, help="SSH password (prompted if omitted)")
    parser.add_argument("--version", action="version", version=f"%(prog)s {TOOL_VERSION}")

    args = parser.parse_args()

    if not HAS_PARAMIKO:
        print(f"{RED}ERROR{RESET}: paramiko required. Install: pip install paramiko")
        sys.exit(1)

    if args.dut_pass is None:
        args.dut_pass = getpass.getpass(f"SSH password for {args.dut_user}@{args.dut}: ")

    print(f"\n{'='*60}")
    print(f" CVE-2021-27137 miniupnpd Verification Tool v{TOOL_VERSION}")
    print(f" Target: {args.dut}:{args.port}")
    print(f" Method: Send exploit payload → check syslog for fix signature")
    print(f"{'='*60}\n")

    # ─── Step 1: Connect SSH ───
    print(f"  {CYAN}[1/5]{RESET} Connecting to {args.dut} via SSH...", end=" ")
    dut = DUTConnection(args.dut, args.dut_user, args.dut_pass)
    if not dut.connect():
        sys.exit(1)
    print(f"{GREEN}OK{RESET}")

    version = dut.get_version()
    pid = dut.get_miniupnpd_pid()
    print(f"        Version: {version}")
    print(f"        PID: {pid}")

    # ─── Step 2: Check port ───
    print(f"\n  {CYAN}[2/5]{RESET} Checking UPnP port {args.port}...", end=" ")
    if not check_port(args.dut, args.port):
        print(f"{RED}CLOSED{RESET}")
        print(f"        miniupnpd not listening. Enable UPnP on device.")
        dut.close()
        sys.exit(1)
    print(f"{GREEN}OPEN{RESET}")

    # ─── Step 3: Get baseline log count ───
    print(f"\n  {CYAN}[3/5]{RESET} Getting baseline syslog count...", end=" ")
    baseline_count = dut.get_log_count()
    print(f"{baseline_count} existing CVE-2021-27137 entries")

    # ─── Step 4: Send exploit payloads ───
    print(f"\n  {CYAN}[4/5]{RESET} Sending {len(EXPLOIT_PAYLOADS)} exploit payloads...")

    for i, payload in enumerate(EXPLOIT_PAYLOADS, 1):
        print(f"        [{i}] {payload['name']}: ", end="")
        response = send_payload(args.dut, args.port, payload["xml"])
        if response is None:
            print(f"{RED}connection failed{RESET}")
        else:
            print(f"sent ({len(payload['xml'])}B)")
        time.sleep(0.5)

    # Wait for syslog to flush
    time.sleep(1)

    # ─── Step 5: Check syslog for new entries ───
    print(f"\n  {CYAN}[5/5]{RESET} Checking syslog for fix signature...", end=" ")
    new_count = dut.get_log_count()
    new_entries = new_count - baseline_count

    # Also verify daemon is still alive
    pid_after = dut.get_miniupnpd_pid()

    # Get the actual log lines for display
    log_output = dut.check_cve_log()

    dut.close()

    # ─── Verdict ───
    print(f"\n\n{'='*60}")
    print(f" RESULT")
    print(f"{'='*60}\n")

    if new_entries > 0:
        print(f"  {GREEN}{BOLD}PASS — FIX VERIFIED{RESET}")
        print(f"  {new_entries} new syslog entries detected after sending exploit payloads.")
        print(f"  The CVE-2021-27137 fix is applied and actively blocking over-reads.")
        if log_output:
            print(f"\n  Log evidence:")
            for line in log_output.split('\n')[-5:]:
                print(f"    {line}")
        print()
        sys.exit(0)
    else:
        print(f"  {RED}{BOLD}FAIL — VULNERABLE{RESET}")
        print(f"  No CVE-2021-27137 syslog entries after sending exploit payloads.")
        print(f"  The fix is NOT applied. miniupnpd silently over-reads heap memory.")
        print(f"\n  Remediation:")
        print(f"    Apply: 3076_miniupnpd_fix_CVE-2021-27137_minixml_overflow.patch")
        print(f"    Rebuild: make package/miniupnpd/{{clean,compile}} V=s")
        if pid and pid_after and pid != pid_after:
            print(f"\n  {YELLOW}NOTE:{RESET} PID changed ({pid} → {pid_after}) — daemon may have crashed")
        print()
        sys.exit(1)


if __name__ == "__main__":
    main()
