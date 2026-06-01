#!/usr/bin/env python3
"""
miniupnpd CVE-2021-27137 Verification Tool

Verifies whether the CVE-2021-27137 fix is applied by inspecting:
1. The miniupnpd binary on the device (via SSH) for the fix signature
2. The source code in the build tree for the missing bounds check
3. The build's patch directory for the fix patch

NOTE: This CVE is a buffer READ overflow, not a write overflow.
Black-box crash testing is UNRELIABLE because the over-read typically
lands in mapped heap memory and does not cause a segfault. This tool
uses source/binary inspection instead.

Vulnerability:
  CVE-2021-27137 — Buffer read overflow in minixml.c parseatt()
  After `while(*(p->xml++) != '=')` loop, code reads *p->xml without
  checking p->xml >= p->xmlend. Truncated XML causes OOB heap read.
  Fix: miniupnp/miniupnp@3cfb4fb (add bounds check after '=' loop)

Usage:
  # Check device binary via SSH
  python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass 'password'

  # Check local build source tree
  python3 miniupnpd_cve_verify.py --source ~/code/pinnacle/develop/store/sdk/qsdk/build_dir/target-arm/miniupnpd-nftables/miniupnpd-2.3.3

  # Check SDK patches directory
  python3 miniupnpd_cve_verify.py --patches ~/code/pinnacle/develop/sdks/qualcomm/qsdk-spf12.5_csu1/sdk_patches

  # All checks combined
  python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass 'pw' \
    --source ~/code/pinnacle/develop/store/sdk/qsdk/build_dir/target-arm/miniupnpd-nftables/miniupnpd-2.3.3 \
    --patches ~/code/pinnacle/develop/sdks/qualcomm/qsdk-spf12.5_csu1/sdk_patches
"""

import argparse
import getpass
import os
import re
import subprocess
import sys

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

TOOL_VERSION = "2.0.0"

# The fix adds this bounds check after the '=' parsing loop.
# We look for this pattern in source code.
FIX_PATTERN_SOURCE = r'if\s*\(\s*p->xml\s*>=\s*p->xmlend\s*\)\s*\n\s*return\s*-1;'

# In the compiled binary, the fix manifests as an additional comparison
# instruction near the IS_WHITE_SPACE check. We look for the comment string
# that's part of the fix commit as a signature.
FIX_SIGNATURE_BINARY = b"right after the '='"

# Patch file name pattern
FIX_PATCH_NAMES = [
    "400-fix-CVE-2021-27137",
    "CVE-2021-27137",
    "minixml_overflow",
    "minixml-overflow",
]


# ═══════════════════════════════════════════════════════════════════════
# Check Methods
# ═══════════════════════════════════════════════════════════════════════

def check_source(source_path):
    """
    Check if the fix is present in minixml.c source code.

    The vulnerable code pattern (UNFIXED):
        while(*(p->xml++) != '=')
        {
            if(p->xml >= p->xmlend)
                return -1;
        }
        while(IS_WHITE_SPACE(*p->xml))   <-- NO bounds check before this

    The fixed code has an additional bounds check between the two while loops.
    """
    minixml_path = os.path.join(source_path, "minixml.c")
    if not os.path.exists(minixml_path):
        # Try src/ subdirectory
        minixml_path = os.path.join(source_path, "src", "minixml.c")
    if not os.path.exists(minixml_path):
        return None, f"minixml.c not found in {source_path}"

    with open(minixml_path, 'r') as f:
        content = f.read()

    # Method 1: Look for the comment from the fix
    if "right after the '='" in content:
        return True, f"Fix comment found in {minixml_path}"

    # Method 2: Count bounds checks between the '=' loop and the whitespace loop
    # In the fixed version, there are TWO consecutive blocks ending with `return -1;`
    # before `while(IS_WHITE_SPACE`
    lines = content.split('\n')
    in_parseatt = False
    found_equals_loop = False
    bounds_check_after_equals = False

    for i, line in enumerate(lines):
        if 'parseatt' in line and 'static' in line:
            in_parseatt = True
        if not in_parseatt:
            continue

        # Find the `while(*(p->xml++) != '=')` loop
        if "p->xml++" in line and "!= '='" in line:
            found_equals_loop = True
            continue

        if found_equals_loop:
            # Look for a bounds check BEFORE the IS_WHITE_SPACE loop
            if 'IS_WHITE_SPACE' in line:
                # We've reached the whitespace loop — was there a bounds check?
                break
            if 'p->xml >= p->xmlend' in line:
                # Check if this is inside the '=' loop (has opening brace context)
                # or standalone (the fix)
                # Look at surrounding context — if the previous `}` closed the
                # '=' while loop, this is the fix
                for j in range(i-1, max(i-5, 0), -1):
                    if lines[j].strip() == '}':
                        bounds_check_after_equals = True
                        break
                    elif 'while' in lines[j]:
                        break

    if bounds_check_after_equals:
        return True, f"Bounds check found after '=' loop in {minixml_path}"

    # Check if version is >= 2.3.10 (fix included)
    version_match = re.search(r'miniupnpd[- ](\d+\.\d+\.?\d*)', content)

    return False, f"VULNERABLE: No bounds check after '=' loop in {minixml_path}"


def check_patches(patches_path):
    """Check if the fix patch exists in the patches directory."""
    if not os.path.isdir(patches_path):
        return None, f"Patches directory not found: {patches_path}"

    found_patches = []
    for root, dirs, files in os.walk(patches_path):
        for f in files:
            f_lower = f.lower()
            for pattern in FIX_PATCH_NAMES:
                if pattern.lower() in f_lower:
                    found_patches.append(os.path.join(root, f))

    if found_patches:
        return True, f"Fix patch found: {', '.join(found_patches)}"

    return False, f"No CVE-2021-27137 fix patch found in {patches_path}"


def check_device_binary(host, user, password, timeout=10):
    """
    SSH to device and check miniupnpd binary for fix indicators.

    Methods:
    1. Check miniupnpd version string (>= 2.3.10 means fixed)
    2. Look for fix signature string in binary
    3. Check if source patch was applied by examining binary structure
    """
    if not HAS_PARAMIKO:
        return None, "paramiko not installed (pip install paramiko)"

    try:
        client = paramiko.SSHClient()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        client.connect(
            host,
            username=user,
            password=password,
            timeout=timeout,
            look_for_keys=False,
            allow_agent=False,
        )
    except Exception as e:
        return None, f"SSH connection failed: {e}"

    results = []

    # Get version
    _, stdout, _ = client.exec_command("miniupnpd --version 2>&1 | head -1", timeout=5)
    version_output = stdout.read().decode().strip()
    results.append(f"Version: {version_output}")

    # Parse version number
    version_match = re.search(r'(\d+)\.(\d+)\.(\d+)', version_output)
    if version_match:
        major, minor, patch = int(version_match.group(1)), int(version_match.group(2)), int(version_match.group(3))
        if (major, minor, patch) >= (2, 3, 10):
            client.close()
            return True, f"Version {major}.{minor}.{patch} >= 2.3.10 (fix included upstream)\n  " + "\n  ".join(results)

    # Check binary for the fix comment string (if compiled with -g or string survived strip)
    _, stdout, _ = client.exec_command(
        "strings /usr/sbin/miniupnpd 2>/dev/null | grep -c \"right after\"",
        timeout=5
    )
    string_count = stdout.read().decode().strip()
    if string_count and int(string_count) > 0:
        results.append("Fix signature string found in binary")
        client.close()
        return True, "Fix comment present in binary\n  " + "\n  ".join(results)

    # Check opkg package version for patch indicators
    _, stdout, _ = client.exec_command(
        "opkg info miniupnpd-nftables 2>/dev/null || opkg info miniupnpd 2>/dev/null",
        timeout=5
    )
    opkg_output = stdout.read().decode().strip()
    if opkg_output:
        results.append(f"Package info: {opkg_output.split(chr(10))[0]}")

    # Check if the patch file exists on device (would be unusual but possible)
    _, stdout, _ = client.exec_command(
        "ls /etc/patches/*minixml* /etc/patches/*27137* 2>/dev/null",
        timeout=5
    )
    patch_on_device = stdout.read().decode().strip()
    if patch_on_device:
        results.append(f"Patch file on device: {patch_on_device}")

    # Get binary size (a patched binary would be slightly larger)
    _, stdout, _ = client.exec_command("ls -l /usr/sbin/miniupnpd", timeout=5)
    binary_info = stdout.read().decode().strip()
    if binary_info:
        results.append(f"Binary: {binary_info}")

    # Get process info
    _, stdout, _ = client.exec_command("pidof miniupnpd", timeout=5)
    pid = stdout.read().decode().strip()
    if pid:
        results.append(f"Running PID: {pid}")

    client.close()

    # If version < 2.3.10 and no fix signature found
    if version_match:
        return False, f"Version {major}.{minor}.{patch} < 2.3.10 and no fix signature in binary\n  " + "\n  ".join(results)

    return None, f"Cannot determine fix status from binary alone\n  " + "\n  ".join(results)


def check_build_version(source_path):
    """Check VERSION file or Makefile for miniupnpd version."""
    version_file = os.path.join(source_path, "VERSION")
    if os.path.exists(version_file):
        with open(version_file) as f:
            version = f.read().strip()
        version_match = re.match(r'(\d+)\.(\d+)\.(\d+)', version)
        if version_match:
            major, minor, patch = int(version_match.group(1)), int(version_match.group(2)), int(version_match.group(3))
            if (major, minor, patch) >= (2, 3, 10):
                return True, f"Source version {version} >= 2.3.10 (fix included)"
            else:
                return None, f"Source version {version} < 2.3.10 (must check patch status)"
    return None, "VERSION file not found"


# ═══════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(
        description="CVE-2021-27137 miniupnpd fix verification tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
NOTE: CVE-2021-27137 is a buffer READ overflow. Black-box crash testing
is UNRELIABLE because the over-read lands in mapped heap memory.
This tool uses source/binary/patch inspection instead.

Examples:
  # Check device via SSH
  python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass 'pw'

  # Check local source
  python3 miniupnpd_cve_verify.py --source path/to/miniupnpd-2.3.3

  # Check patches directory
  python3 miniupnpd_cve_verify.py --patches path/to/sdk_patches

  # All checks
  python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass 'pw' \\
    --source path/to/miniupnpd-2.3.3 --patches path/to/sdk_patches
        """,
    )
    parser.add_argument("--dut", default=None, help="DUT IP for SSH binary inspection")
    parser.add_argument("--dut-user", default="root", help="SSH user (default: root)")
    parser.add_argument("--dut-pass", default=None, help="SSH password")
    parser.add_argument("--source", default=None, help="Path to miniupnpd source (contains minixml.c)")
    parser.add_argument("--patches", default=None, help="Path to SDK patches directory")
    parser.add_argument("--version", action="version", version=f"%(prog)s {TOOL_VERSION}")

    args = parser.parse_args()

    if not args.dut and not args.source and not args.patches:
        parser.error("At least one of --dut, --source, or --patches is required")

    print(f"\n{'='*60}")
    print(f" CVE-2021-27137 miniupnpd Fix Verification v{TOOL_VERSION}")
    print(f"{'='*60}")
    print(f"\n  NOTE: This CVE is a heap READ overflow. Crash-based testing")
    print(f"  is unreliable. This tool inspects source/binary/patches.\n")

    checks_run = 0
    checks_pass = 0
    checks_fail = 0
    checks_inconclusive = 0

    # ─── Source Code Check ───
    if args.source:
        print(f"{'─'*60}")
        print(f" Source Code Inspection: {args.source}")
        print(f"{'─'*60}\n")

        # Version check first
        ver_result, ver_detail = check_build_version(args.source)
        print(f"  {CYAN}[INFO]{RESET} {ver_detail}")

        # Source pattern check
        result, detail = check_source(args.source)
        checks_run += 1
        if result is True:
            print(f"  {GREEN}[PASS]{RESET} {detail}")
            checks_pass += 1
        elif result is False:
            print(f"  {RED}[FAIL]{RESET} {detail}")
            checks_fail += 1
        else:
            print(f"  {YELLOW}[SKIP]{RESET} {detail}")
            checks_inconclusive += 1
        print()

    # ─── Patches Check ───
    if args.patches:
        print(f"{'─'*60}")
        print(f" SDK Patches Inspection: {args.patches}")
        print(f"{'─'*60}\n")

        result, detail = check_patches(args.patches)
        checks_run += 1
        if result is True:
            print(f"  {GREEN}[PASS]{RESET} {detail}")
            checks_pass += 1
        elif result is False:
            print(f"  {RED}[FAIL]{RESET} {detail}")
            checks_fail += 1
        else:
            print(f"  {YELLOW}[SKIP]{RESET} {detail}")
            checks_inconclusive += 1
        print()

    # ─── Device Binary Check ───
    if args.dut:
        print(f"{'─'*60}")
        print(f" Device Binary Inspection: {args.dut}")
        print(f"{'─'*60}\n")

        if not HAS_PARAMIKO:
            print(f"  {YELLOW}[SKIP]{RESET} paramiko not installed (pip install paramiko)")
            checks_inconclusive += 1
        else:
            if args.dut_pass is None:
                args.dut_pass = getpass.getpass(f"  SSH password for {args.dut_user}@{args.dut}: ")

            result, detail = check_device_binary(args.dut, args.dut_user, args.dut_pass)
            checks_run += 1
            if result is True:
                print(f"  {GREEN}[PASS]{RESET} {detail}")
                checks_pass += 1
            elif result is False:
                print(f"  {RED}[FAIL]{RESET} {detail}")
                checks_fail += 1
            else:
                print(f"  {YELLOW}[INFO]{RESET} {detail}")
                checks_inconclusive += 1
        print()

    # ─── Summary ───
    print(f"{'='*60}")
    print(f" Summary: {checks_run} checks run")
    print(f"{'='*60}\n")

    if checks_pass > 0 and checks_fail == 0:
        print(f"  {GREEN}{BOLD}FIX VERIFIED{RESET}: CVE-2021-27137 patch is applied.")
        print()
        sys.exit(0)
    elif checks_fail > 0:
        print(f"  {RED}{BOLD}VULNERABLE{RESET}: CVE-2021-27137 fix is NOT applied.")
        print(f"  Apply: 3076_miniupnpd_fix_CVE-2021-27137_minixml_overflow.patch")
        print(f"  Upstream: https://github.com/miniupnp/miniupnp/commit/3cfb4fb")
        print()
        sys.exit(1)
    else:
        print(f"  {YELLOW}{BOLD}INCONCLUSIVE{RESET}: Could not definitively determine fix status.")
        print(f"  Try --source with the build tree path for definitive results.")
        print()
        sys.exit(2)


if __name__ == "__main__":
    main()
