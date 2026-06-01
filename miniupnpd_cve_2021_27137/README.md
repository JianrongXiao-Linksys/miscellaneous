# miniupnpd CVE-2021-27137 Vulnerability Test Suite

Verifies whether the CVE-2021-27137 fix is applied on a device running miniupnpd.

## Detection Method

The fix adds a `syslog(LOG_WARNING)` message when it blocks a truncated XML attribute over-read. This tool:

1. Sends malformed XML payloads via `AddPortMapping` SOAP action (which triggers XML body parsing)
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

# Platform wrapper
./test_pinnacle_cve_2021_27137.sh 192.168.1.1 '12345Asdf@'
```

## Test Results

### Before fix (FAIL) — miniupnpd 2.3.3 unpatched:
```
============================================================
 CVE-2021-27137 miniupnpd Verification Tool v3.0.0
 Target: 192.168.1.1:5000
 Method: Send exploit payload → check syslog for fix signature
============================================================

  [1/5] Connecting to 192.168.1.1 via SSH... OK
        Version: miniupnpd 2.3.3 May 29 2026
        PID: 21563

  [2/5] Checking UPnP port 5000... OPEN

  [3/5] Getting baseline syslog count... 0 existing CVE-2021-27137 entries

  [4/5] Sending 3 exploit payloads...
        [1] Truncated after '=': sent (19B)
        [2] Namespace attr truncated: sent (80B)
        [3] Nested truncated: sent (30B)

  [5/5] Checking syslog for fix signature...

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

### After fix (PASS) — miniupnpd 2.3.3 with patch 3076 applied:
```
============================================================
 CVE-2021-27137 miniupnpd Verification Tool v3.0.0
 Target: 192.168.1.1:5000
 Method: Send exploit payload → check syslog for fix signature
============================================================

  [1/5] Connecting to 192.168.1.1 via SSH... OK
        Version: miniupnpd 2.3.3 May 27 2026
        PID: 20773

  [2/5] Checking UPnP port 5000... OPEN

  [3/5] Getting baseline syslog count... 3 existing CVE-2021-27137 entries

  [4/5] Sending 3 exploit payloads...
        [1] Truncated after '=': sent (19B)
        [2] Namespace attr truncated: sent (80B)
        [3] Nested truncated: sent (30B)

  [5/5] Checking syslog for fix signature...

============================================================
 RESULT
============================================================

  PASS — FIX VERIFIED
  3 new syslog entries detected after sending exploit payloads.
  The CVE-2021-27137 fix is applied and actively blocking over-reads.

  Log evidence:
    Sun May 31 22:39:01 2026 daemon.warn miniupnpd[20773]: minixml: rejected truncated attribute (CVE-2021-27137)
    Sun May 31 22:39:01 2026 daemon.warn miniupnpd[20773]: minixml: rejected truncated attribute (CVE-2021-27137)
    Sun May 31 22:39:29 2026 daemon.warn miniupnpd[20773]: minixml: rejected truncated attribute (CVE-2021-27137)
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

## Affected Builds

| Build | miniupnpd Version | Affected? |
|-------|-------------------|-----------|
| Pinnacle QSDK 12.5 | 2.3.3 | YES |
| Pinnacle QSDK 14.0 | 2.3.3 | YES |

Note: Oak and other legacy platforms do not use miniupnpd.

## Tools

| Tool | Purpose | Requires |
|------|---------|----------|
| `miniupnpd_cve_verify.py` | **Primary** — send exploit + check syslog | SSH + paramiko |
| `exploit_minixml_overflow.py` | Standalone exploit reproducer | Network only |
| `miniupnpd_cve_blackbox.py` | Black-box analysis (response/timing) | Network only |
| `detect_cve_on_device.sh` | Binary inspection via SSH | SSH + sshpass |
| `test_miniupnpd_cve_on_device.sh` | On-DUT info gathering | Run on device |
| `test_pinnacle_cve_2021_27137.sh` | Pinnacle wrapper | SSH |

## Why AddPortMapping SOAPAction?

The tool uses `AddPortMapping` (not `GetExternalIPAddress`) because:
- `GetExternalIPAddress` doesn't parse the XML body — it returns WAN IP directly
- `AddPortMapping` calls `ParseNameValue()` → `parsexml()` → `parseatt()` — this is the code path that triggers the vulnerability

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
   patch -p1 -d store/sdk < sdks/qualcomm/qsdk-spf12.5_csu1/sdk_patches/3076_miniupnpd_fix_CVE-2021-27137_minixml_overflow.patch
   # Rebuild miniupnpd
   VENDOR_SDK=qualcomm/qsdk-spf12.5_csu1 ./docker-dev.sh \
     make -C store/sdk/qsdk package/miniupnpd/{clean,compile} V=s
   # Push binary to device for quick test
   scp store/sdk/qsdk/staging_dir/target-arm/root-ipq53xx/usr/sbin/miniupnpd root@192.168.1.1:/usr/sbin/
   ssh root@192.168.1.1 "/etc/init.d/miniupnpd restart"
   # Re-run verify
   python3 miniupnpd_cve_verify.py --dut 192.168.1.1 --dut-pass '12345Asdf@'
   ```

### Manual Verification (without the tool)

```bash
# 1. Send exploit payload (uses AddPortMapping to trigger XML parsing)
echo -ne 'POST /ctl/IPConn HTTP/1.1\r\nHost: 192.168.1.1:5000\r\nContent-Type: text/xml\r\nSOAPAction: "urn:schemas-upnp-org:service:WANIPConnection:1#AddPortMapping"\r\nContent-Length: 19\r\n\r\n<element attribute=' | nc -w 3 192.168.1.1 5000

# 2. Check syslog on device
ssh root@192.168.1.1 "logread | grep CVE-2021-27137"

# Output = PATCHED, No output = VULNERABLE
```

## References

- Upstream fix: https://github.com/miniupnp/miniupnp/commit/3cfb4fb78d5ac04ed0dadc8dd842fc9e448916db
- CVE-2021-27137: https://nvd.nist.gov/vuln/detail/CVE-2021-27137
- SDK patch: `pinnacle/develop/sdks/qualcomm/qsdk-spf12.5_csu1/sdk_patches/3076_miniupnpd_fix_CVE-2021-27137_minixml_overflow.patch`
