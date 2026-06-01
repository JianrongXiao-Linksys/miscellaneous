# miniupnpd CVE-2021-27137 Vulnerability Test Suite

Test tool for the minixml.c buffer read overflow in miniupnpd. Sends malformed XML payloads to a live miniupnpd instance and verifies whether the daemon crashes (vulnerable) or survives (patched).

## Quick Start

```bash
# Full verification with SSH PID checking (recommended)
python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass 'password'

# Without SSH (port-check only)
python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --no-ssh

# Platform-specific wrappers
./test_pinnacle_cve_2021_27137.sh 192.168.1.1
./test_oak_cve_2021_27137.sh 192.168.1.1

# Exploit reproducer (WARNING: will crash vulnerable targets)
python3 exploit_minixml_overflow.py 192.168.1.1

# On-device info check (run on DUT itself)
scp test_miniupnpd_cve_on_device.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "sh /tmp/test_miniupnpd_cve_on_device.sh"
```

## CVE Details

| Field | Value |
|-------|-------|
| **CVE** | CVE-2021-27137 |
| **Component** | miniupnpd `minixml.c` `parseatt()` function |
| **Type** | Buffer read overflow (heap OOB read) |
| **Attack Vector** | Network (LAN — UPnP SOAP endpoint) |
| **Impact** | Denial of service (crash), potential info disclosure |
| **Affected Versions** | miniupnpd <= 2.3.3 |
| **Fix** | [miniupnp/miniupnp@3cfb4fb](https://github.com/miniupnp/miniupnp/commit/3cfb4fb78d5ac04ed0dadc8dd842fc9e448916db) |
| **Fixed In** | miniupnpd 2.3.10 |

## How the Vulnerability Works

In `minixml.c`, the `parseatt()` function parses XML attribute key-value pairs:

```c
// Advance past '=' character
while(*(p->xml++) != '=')
{
    if(p->xml >= p->xmlend)
        return -1;
}
// BUG: No bounds check here! If buffer ends right after '=',
// the next read of *p->xml is out-of-bounds
while(IS_WHITE_SPACE(*p->xml))  // <-- OOB READ
{
    ...
}
```

With truncated input like `<element attribute=` (buffer ends after `=`), the parser:
1. Finds `=` and advances past it (p->xml now points past the buffer)
2. Attempts to read `*p->xml` for whitespace check
3. Reads garbage memory → crash or info leak

### The Fix (3 lines)

```c
while(*(p->xml++) != '=')
{
    if(p->xml >= p->xmlend)
        return -1;
}
+/* p->xml points now to the character right after the '=' */
+if(p->xml >= p->xmlend)
+    return -1;
while(IS_WHITE_SPACE(*p->xml))
```

## Our Builds — Affected Versions

| Build | miniupnpd Version | Affected? |
|-------|-------------------|-----------|
| Main_Oak (lego_overlay) | 1.4 | YES |
| Pinnacle QSDK 12.5 | 2.3.3 | YES |
| Pinnacle QSDK 14.0 | 2.3.3 | YES |

## Remediation

**Applied fix:** SDK patch `3076_miniupnpd_fix_CVE-2021-27137_minixml_overflow.patch`

Location: `sdks/qualcomm/qsdk-spf12.5_csu1/sdk_patches/`

This patch adds `patches/400-fix-CVE-2021-27137.patch` to the miniupnpd OpenWrt package, which inserts the bounds check. It's a 3-line addition to `minixml.c` with zero regression risk.

## Test Architecture

```
┌──────────────────────────────────────────────┐
│           Testing Laptop (LAN)                │
│                                              │
│   miniupnpd_cve_verify.py                   │
│   ┌────────────────────────────────────┐     │
│   │  1. SSH: get PID before            │     │
│   │  2. Send malformed XML to port 5000│     │
│   │  3. Wait 1.5s                      │     │
│   │  4. SSH: get PID after             │     │
│   │  5. Compare PIDs → verdict         │     │
│   └─────────────┬──────────────────────┘     │
│                  │                            │
└──────────────────┼────────────────────────────┘
                   │ LAN (192.168.1.x)
                   │
┌──────────────────┼────────────────────────────┐
│                  ▼                            │
│   DUT (192.168.1.1)                          │
│   miniupnpd listening on :5000               │
│                                              │
│   Receives: POST /ctl/IPConn                 │
│   Body: <element attribute=  (truncated XML) │
│                                              │
│   Vulnerable: segfault → procd restarts      │
│   Patched: graceful reject, daemon alive     │
│                                              │
└──────────────────────────────────────────────┘
```

## How Each Test Works

### Verification Tool (`miniupnpd_cve_verify.py`)

The primary QA tool. Runs 7 exploit payloads + 1 regression test:

| # | Payload | What It Tests |
|---|---------|---------------|
| 1 | `<e a=` | Core trigger — truncated after '=' |
| 2 | `<e a= ` | Whitespace after '=' with no value |
| 3 | `<s:Envelope ... s:encodingStyle=` | Realistic UPnP namespace truncation |
| 4 | `<root><child attr1="ok" attr2=` | Parser state after successful first attr |
| 5 | `<e AAAA...` (2048 chars, no '=') | First loop boundary (finding '=') |
| 6 | `<e attr="no_close` | Quoted value loop boundary |
| 7 | `<a x=<b y=<c z=` | Repeated truncation stress test |
| R | Valid SOAP GetExternalIPAddress | Regression — normal UPnP still works |

**Verdict logic:**
- PID unchanged → **PASS** (daemon survived)
- PID changed → **FAIL** (crashed, procd restarted it)
- Port closed → **FAIL** (crashed, not restarted)

### Exploit Reproducer (`exploit_minixml_overflow.py`)

Standalone tool to prove the bug. Intentionally crashes a vulnerable target:

```bash
# Single shot — prove the crash
python3 exploit_minixml_overflow.py 192.168.1.1

# All variants
python3 exploit_minixml_overflow.py 192.168.1.1 --exploit all

# Repeated (stress test)
python3 exploit_minixml_overflow.py 192.168.1.1 --repeat 10
```

### On-Device Script (`test_miniupnpd_cve_on_device.sh`)

Lightweight info-gathering only (no exploit). Run on the DUT:

```bash
ssh root@192.168.1.1 "sh /tmp/test_miniupnpd_cve_on_device.sh"
```

Reports: version, listening port, config, crash history in dmesg.

## QA Test Procedure

### Prerequisites

- Python 3.6+ on testing laptop
- `paramiko` installed (`pip install paramiko`) — optional but recommended
- SSH access to DUT (root)
- DUT has UPnP enabled (default on both Oak and Pinnacle)

### Step 1: Verify UPnP is Running

```bash
ssh root@192.168.1.1 "pidof miniupnpd; netstat -tlnp | grep 5000"
```

If not running, enable via GUI: **Connectivity → Internet Settings → UPnP: Enable**

### Step 2: Run the Verification Tool

```bash
# Pre-fix test (expect FAIL on vulnerable firmware)
python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass '12345Asdf@'

# Post-fix test (expect all PASS after applying patch 3076)
python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass '12345Asdf@'
```

### Step 3: Read Results

```
============================================================
 Results: 7 PASSED, 0 FAILED (of 7 tests)
============================================================

  PASSED: miniupnpd handled all malformed XML without crashing.
  The CVE-2021-27137 fix appears to be applied.
```

### Expected Results

**Pre-fix (miniupnpd 2.3.3 without patch):**

| Test | Result | Behavior |
|------|--------|----------|
| TRUNC_AFTER_EQUALS | FAIL | Crash (segfault) |
| Others | FAIL/PASS | May crash on first, never reaches rest |

**Post-fix (patch 3076 applied):**

| Test | Result | Behavior |
|------|--------|----------|
| All 7 payloads | PASS | Daemon rejects gracefully |
| Regression | PASS | Normal UPnP still works |

## Tools Summary

| Tool | Python | Root | SSH | Purpose |
|------|--------|------|-----|---------|
| `miniupnpd_cve_verify.py` | 3.6+ (+paramiko) | No | Optional | Full PASS/FAIL verification |
| `exploit_minixml_overflow.py` | 3.6+ stdlib | No | No | Prove the crash (pre-fix only) |
| `test_miniupnpd_cve_on_device.sh` | N/A (sh) | No | Run on DUT | Info gathering |
| `test_pinnacle_cve_2021_27137.sh` | 3.6+ | No | Optional | Pinnacle wrapper |
| `test_oak_cve_2021_27137.sh` | 3.6+ | No | Optional | Oak wrapper |

## References

- Upstream fix: https://github.com/miniupnp/miniupnp/commit/3cfb4fb78d5ac04ed0dadc8dd842fc9e448916db
- CVE-2021-27137 (dd-wrt): https://nvd.nist.gov/vuln/detail/CVE-2021-27137
- miniupnp releases: https://miniupnp.tuxfamily.org/files/
- SDK patch: `pinnacle/develop/sdks/qualcomm/qsdk-spf12.5_csu1/sdk_patches/3076_miniupnpd_fix_CVE-2021-27137_minixml_overflow.patch`
