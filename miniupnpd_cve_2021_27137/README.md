# miniupnpd CVE-2021-27137 Vulnerability Test Suite

Verifies whether the CVE-2021-27137 fix is applied on a device running miniupnpd.

## Detection Method

The fix adds a `syslog(LOG_WARNING)` message when it blocks a truncated XML attribute over-read. This tool:

1. Sends malformed XML payloads to the UPnP port (triggers the vulnerability)
2. Checks device syslog via SSH for the fix's signature message
3. **Log appears → PASS (fix applied)** | **No log → FAIL (vulnerable)**

```
Patched miniupnpd logs:
  "minixml: rejected truncated attribute (CVE-2021-27137)"

Unpatched miniupnpd:
  (silence — silently over-reads heap memory)
```

## Quick Start

```bash
# Primary verification tool (requires SSH)
python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass '12345Asdf@'

# Platform wrappers
./test_pinnacle_cve_2021_27137.sh 192.168.1.1
./test_oak_cve_2021_27137.sh 192.168.1.1
```

## Expected Output

**After fix applied (PASS):**
```
============================================================
 RESULT
============================================================

  PASS — FIX VERIFIED
  3 new syslog entries detected after sending exploit payloads.
  The CVE-2021-27137 fix is applied and actively blocking over-reads.

  Log evidence:
    minixml: rejected truncated attribute (CVE-2021-27137)
```

**Before fix (FAIL):**
```
============================================================
 RESULT
============================================================

  FAIL — VULNERABLE
  No CVE-2021-27137 syslog entries after sending exploit payloads.
  The fix is NOT applied. miniupnpd silently over-reads heap memory.

  Remediation:
    Apply: 3076_miniupnpd_fix_CVE-2021-27137_minixml_overflow.patch
    Rebuild: make package/miniupnpd/{clean,compile} V=s
```

## CVE Details

| Field | Value |
|-------|-------|
| **CVE** | CVE-2021-27137 |
| **Component** | miniupnpd `minixml.c` `parseatt()` function |
| **Type** | Buffer read overflow (heap OOB read) |
| **Attack Vector** | Network (LAN — UPnP SOAP endpoint) |
| **Affected Versions** | miniupnpd <= 2.3.3 |
| **Fix** | [miniupnp/miniupnp@3cfb4fb](https://github.com/miniupnp/miniupnp/commit/3cfb4fb78d5ac04ed0dadc8dd842fc9e448916db) |
| **SDK Patch** | `3076_miniupnpd_fix_CVE-2021-27137_minixml_overflow.patch` |

## How the Fix Works

```c
// After the while(*(p->xml++) != '=') loop:

/* CVE-2021-27137: bounds check after '=' parsing */
if(p->xml >= p->xmlend) {
    syslog(LOG_WARNING, "minixml: rejected truncated attribute (CVE-2021-27137)");
    return -1;
}
```

Without this check, truncated input like `<element attribute=` causes the parser to read past the buffer into heap memory.

## Our Builds

| Build | miniupnpd Version | Affected? |
|-------|-------------------|-----------|
| Main_Oak (lego_overlay) | 1.4 | YES |
| Pinnacle QSDK 12.5 | 2.3.3 | YES |
| Pinnacle QSDK 14.0 | 2.3.3 | YES |

## Tools

| Tool | Purpose | Requires |
|------|---------|----------|
| `miniupnpd_cve_verify.py` | **Primary** — send exploit + check syslog | SSH + paramiko |
| `exploit_minixml_overflow.py` | Standalone exploit reproducer | Network only |
| `miniupnpd_cve_blackbox.py` | Black-box analysis (response/timing) | Network only |
| `detect_cve_on_device.sh` | Binary inspection via SSH | SSH + sshpass |
| `test_miniupnpd_cve_on_device.sh` | On-DUT info gathering | Run on device |
| `test_pinnacle_cve_2021_27137.sh` | Pinnacle wrapper | SSH |
| `test_oak_cve_2021_27137.sh` | Oak wrapper | SSH |

## QA Test Procedure

### Prerequisites

- Python 3.6+ with `paramiko` (`pip install paramiko`)
- SSH access to DUT (root credentials)
- UPnP enabled on device (default)

### Steps

1. **Run the tool:**
   ```bash
   python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass '12345Asdf@'
   ```

2. **Read the verdict:** PASS or FAIL

3. **If FAIL — apply the fix:**
   ```bash
   # In SDK build tree:
   cp 3076_miniupnpd_fix_CVE-2021-27137_minixml_overflow.patch sdk_patches/
   # Rebuild
   make package/miniupnpd/{clean,compile} V=s
   # Flash and re-test
   ```

### Manual Verification (without the tool)

```bash
# 1. Send exploit payload
echo -ne 'POST /ctl/IPConn HTTP/1.1\r\nHost: 192.168.1.1:5000\r\nContent-Type: text/xml\r\nContent-Length: 19\r\n\r\n<element attribute=' | nc -w 3 192.168.1.1 5000

# 2. Check syslog on device
ssh root@192.168.1.1 "logread | grep CVE-2021-27137"

# Output = PATCHED, No output = VULNERABLE
```

## References

- Upstream fix: https://github.com/miniupnp/miniupnp/commit/3cfb4fb78d5ac04ed0dadc8dd842fc9e448916db
- CVE-2021-27137: https://nvd.nist.gov/vuln/detail/CVE-2021-27137
- SDK patch: `pinnacle/develop/sdks/qualcomm/qsdk-spf12.5_csu1/sdk_patches/3076_miniupnpd_fix_CVE-2021-27137_minixml_overflow.patch`
