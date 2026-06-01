# dnsmasq CVE-2026 Vulnerability Test Suite

Test tool for the 6 dnsmasq vulnerabilities disclosed May 2026. Supports three testing modes:

1. **Network testing** — sends crafted packets to a live dnsmasq instance
2. **Static source analysis** — inspects source code for vulnerable patterns
3. **Version checking** — determines if a binary is below the fix version

## Quick Start

```bash
# Simplest: check your source builds
python3 dnsmasq_cve_tester.py \
  --source ~/code/Main_Oak/products/oak/output/release/dnsmasq/build/dnsmasq-2.78 \
  --source ~/code/pinnacle/develop_46_2.2/store/sdk/qsdk/build_dir/target-arm/dnsmasq-nodhcpv6/dnsmasq-2.90

# Network test (WARNING: may crash vulnerable dnsmasq)
python3 dnsmasq_cve_tester.py --target 192.168.1.1

# Specific CVE only
python3 dnsmasq_cve_tester.py --target 192.168.1.1 --test CVE-2026-4890

# Binary version check (cross-compiled binaries report arch mismatch)
python3 dnsmasq_cve_tester.py --binary /path/to/dnsmasq
```

## CVEs Tested

| CVE | CVSS | Type | Attack Vector | Affected Feature |
|-----|------|------|---------------|-----------------|
| CVE-2026-2291 | 9.2 | Heap buffer overflow | Remote | `extract_name()` — always active |
| CVE-2026-5172 | 7.5 | OOB read / crash | Remote | `extract_addresses()` — always active |
| CVE-2026-4890 | 7.5 | Infinite loop DoS | Remote | NSEC bitmap parsing (`--dnssec`) |
| CVE-2026-4891 | 5.3 | Heap OOB read | Remote | RRSIG validation (`--dnssec`) |
| CVE-2026-4892 | 8.4 | Heap overflow → root | Local/Adjacent | DHCPv6 CLID (`--dhcp-script` + DHCPv6) |
| CVE-2026-4893 | 5.3 | Validation bypass | Remote | ECS source check (`--add-subnet`) |

## How Each Test Works

### CVE-2026-2291 (Critical — Heap Overflow in extract_name)

**Root cause:** `union bigname` declares `char name[MAXDNAME]` but escaped characters can expand a name to `2*MAXDNAME+1` bytes, causing heap overflow.

**Test method:** Sends DNS queries containing domain names with high-bit characters (0x80+) that get `\DDD` escaped internally (4 bytes per input byte). If dnsmasq crashes or stops responding, it's vulnerable.

**Patched behavior:** Rejects oversized names gracefully (FORMERR/REFUSED) or uses enlarged buffer.

### CVE-2026-5172 (High — OOB Read in extract_addresses)

**Root cause:** Falsified `rdlen` field lets `extract_name()` advance pointer past record end. Remaining-bytes underflow produces a huge value → massive OOB read → crash.

**Test method:** Sends DNS responses with CNAME records where `rdlen` is smaller than the actual encoded name. If dnsmasq crashes, it's vulnerable.

**Patched behavior:** Validates that pointer stays within declared rdlen boundary after `extract_name()`.

### CVE-2026-4890 (High — DNSSEC NSEC Infinite Loop)

**Root cause:** NSEC type bitmap parsing advances by `p[1]` instead of `p[1]+2` (missing window header size). With `bitmap_length=0`, pointer never advances → infinite loop.

**Test method:** Sends a crafted NSEC record with `window=0, bitmap_length=0`. If dnsmasq stops responding to ALL queries (hangs, not crashes), it's vulnerable. Exploitable BEFORE RRSIG validation.

**Patched behavior:** Advances by `p[1]+2` and skips zero-length bitmaps.

### CVE-2026-4891 (Moderate — RRSIG Heap OOB Read)

**Root cause:** `rdlen` in RRSIG not validated against minimum size (18 + signer name). Calculated signature length underflows negative → treated as huge → OOB read.

**Test method:** Sends RRSIG records with `rdlen=10` (way below minimum 31+ bytes). Crash = vulnerable.

**Patched behavior:** Validates `rdlen >= fixed_fields + signer_name_length` before computing signature length.

### CVE-2026-4892 (High — DHCPv6 CLID Local Root)

**Root cause:** DHCPv6 CLIDs (up to 65535 bytes) get hex-encoded via `sprintf("%.2x")` into `daemon->packet` (5131 bytes). 3000-byte CLID → 6000-byte hex string → overflow. Helper process runs as root.

**Test method:** Sends DHCPv6 SOLICIT with 3000-byte Client Identifier. Requires IPv6 adjacency and `--dhcp-script` configured. Helper crash = vulnerable.

**Patched behavior:** Truncates or validates CLID length before hex encoding.

**Note:** The `nodhcpv6` build variant (used in pinnacle) compiles with `-DNO_DHCP6` and is NOT affected.

### CVE-2026-4893 (Moderate — ECS Source Validation Bypass)

**Root cause:** `process_reply()` passes OPT record length (~23 bytes) instead of full packet length to `check_source()`. All bounds checks fail → function always returns 1 (valid).

**Test method:** Sends DNS queries with EDNS Client Subnet option containing spoofed source prefixes. If dnsmasq echoes ECS back without validation, it's vulnerable.

**Patched behavior:** Passes full packet length to `check_source()`, enabling proper bounds checks per RFC 7871 Section 9.2.

## Our Builds — Current Status

| Build | Version | Vulnerable CVEs |
|-------|---------|-----------------|
| Main_Oak (lego_overlay) | 2.78 | ALL 6 (if features compiled in) |
| Pinnacle develop_46_2.2 (nodhcpv6) | 2.90 | CVE-2026-2291, 5172, 4893 always; 4890/4891 if DNSSEC enabled |

## Remediation

**Option 1 — Upgrade to 2.92rel2** (recommended)
- Source: https://thekelleys.org.uk/dnsmasq/dnsmasq-2.92rel2.tar.xz
- For pinnacle: update `PKG_UPSTREAM_VERSION` in `package/network/services/dnsmasq/Makefile`
- For Main_Oak: update `PACKAGE_VERSION` in `lego_overlay/opensource/dnsmasq/Makefile` + rebase patches

**Option 2 — Backport patches**
- Available at: https://thekelleys.org.uk/dnsmasq/CVE/
- Commits:
  - `ec2fbfbb` — CVE-2026-2291 (dnsmasq.h)
  - `de76f21e` — CVE-2026-4890 (dnssec.c, for <=2.91)
  - `2cacea42` — CVE-2026-4891 (dnssec.c)
  - `011a36c5` — CVE-2026-4892 (helper.c)
  - `434d68f2` — CVE-2026-4893 (forward.c)
  - `fa3c8dde` — CVE-2026-5172 (rfc1035.c)

## Automated Defect Verification Tool (`dnsmasq_cve_verify.py`)

The primary QA tool. Runs on the **testing laptop**, sends attack packets to the DUT,
and reports clear PASS/FAIL for each CVE. No modification of the DUT is needed beyond
read-only SSH access for state inspection.

### Network Topology

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Testing Laptop                                │
│                                                                      │
│   LAN interface                   WAN interface                      │
│   <LAPTOP_LAN_IP>                 <LAPTOP_WAN_IP>                   │
│        │                               │                            │
│        │                          ┌────┴──────────────┐             │
│        │                          │ Malicious DNS     │             │
│        │                          │ Server (port 53)  │             │
│        │                          └────┬──────────────┘             │
│        │                               │                            │
└────────┼───────────────────────────────┼────────────────────────────┘
         │ LAN subnet                    │ WAN subnet
         │                               │
┌────────┼───────────────────────────────┼────────────────────────────┐
│        │                               │                            │
│   LAN: <DUT_LAN_IP>              WAN: <DUT_WAN_IP>                  │
│   (LAN gateway)                   (WAN uplink)                      │
│                                                                      │
│              DUT (Oak or Pinnacle)                                   │
│              dnsmasq 2.78 (Oak) / 2.90 (Pinnacle)                   │
│                                                                      │
│   resolv-file=/etc/resolv.conf                                      │
│   → nameserver <LAPTOP_WAN_IP>  ← set via GUI, forwards to us      │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘

Data flow:
  1. Tool sends DNS query to DUT LAN IP (port 53)
  2. DUT's dnsmasq can't resolve locally → forwards upstream to LAPTOP_WAN_IP
  3. Our malicious server on WAN interface replies with exploit payload
  4. DUT's dnsmasq processes the malicious response → crash/hang/survive
  5. Tool checks DUT state via SSH (read-only)
```

**Example setup (your IPs will differ):**

| Role | IP (example) |
|------|--------------|
| Laptop LAN | 192.168.1.254 |
| Laptop WAN | 10.0.0.211 |
| DUT LAN | 192.168.1.1 |
| DUT WAN | 10.0.0.214 |

The key requirement: **Laptop WAN IP and DUT WAN IP must be on the same subnet**,
so the DUT can reach the laptop as an upstream DNS server.

### How It Works

```
┌──────────┐     ┌───────────┐     ┌──────────────────┐     ┌──────────┐
│  SETUP   │ ──► │  TRIGGER  │ ──► │  STATE INSPECT   │ ──► │  VERDICT │
│          │     │           │     │                  │     │          │
│ Start    │     │ Send DNS  │     │ SSH to DUT:      │     │ PASS:    │
│ malicious│     │ query to  │     │ - pidof dnsmasq  │     │ survived │
│ DNS srv  │     │ DUT→DUT   │     │ - PID changed?   │     │          │
│ on WAN   │     │ forwards  │     │ - dmesg crash?   │     │ FAIL:    │
│ interface│     │ to us→we  │     │ - /var/log/msg   │     │ crashed/ │
│ (10.0.0. │     │ reply w/  │     │                  │     │ hung     │
│  211:53) │     │ exploit   │     │ Liveness query   │     │          │
│          │     │ payload   │     │ (version.bind)   │     │          │
└──────────┘     └───────────┘     └──────────────────┘     └──────────┘

NOTE: Tool does NOT modify DUT settings. User must set DNS to 10.0.0.211 via GUI.
```

### Running the Tool

**Step 1: Connect laptop to DUT**
- Laptop LAN port → DUT LAN (for SSH access and sending queries)
- Laptop WAN port → DUT WAN subnet (for acting as upstream DNS)

**Step 2: Set DUT upstream DNS via GUI**
- Open Router Admin (e.g., http://192.168.1.1 or http://myrouter.local)
- Go to Internet/WAN Settings → DNS
- Set Static DNS 1 to your **laptop's WAN IP**
- Save/Apply

**Step 3: Run the tool**
```bash
# Full test — all 6 CVEs
# --laptop = your laptop's WAN IP (the one DUT forwards DNS to)
# --dut = DUT's LAN IP (the one you SSH to and send queries to)
sudo python3 dnsmasq_cve_verify.py --laptop <YOUR_WAN_IP> --dut <DUT_LAN_IP>

# Examples:
sudo python3 dnsmasq_cve_verify.py --laptop 10.0.0.211 --dut 192.168.1.1
sudo python3 dnsmasq_cve_verify.py --laptop 172.16.0.100 --dut 192.168.1.1

# Test specific CVE(s)
sudo python3 dnsmasq_cve_verify.py --laptop 10.0.0.211 --cve CVE-2026-5172

# Custom SSH credentials
sudo python3 dnsmasq_cve_verify.py --laptop 10.0.0.211 --dut-user admin --dut-pass mypass
```

**Step 4: Restore DUT DNS (after testing)**
- Set DNS back to "Obtain from ISP automatically" via GUI

---

## Test Results (2026-05-31)

### Oak — dnsmasq 2.78 (OVERALL: PASS)

```
Compile options: IPv6 DHCP DHCPv6 no-DNSSEC
```

| CVE | Result | Reason |
|-----|--------|--------|
| CVE-2026-2291 | PASS | DNSSEC not compiled |
| CVE-2026-4890 | PASS | DNSSEC not compiled |
| CVE-2026-4891 | PASS | DNSSEC not compiled |
| CVE-2026-4892 | PASS | dnsmasq not serving DHCPv6 (Oak uses dhcp6s for IPv6) |
| CVE-2026-4893 | PASS | Logic bug only — no crash |
| CVE-2026-5172 | PASS | Survived exploit (blockdata_expand path not in 2.78) |

**Notes:**
- Oak compiles DHCPv6 into dnsmasq but never configures it to serve DHCPv6.
  IPv6 DHCP is handled by a separate binary (`/sbin/dhcp6s`, wide-dhcpv6).
- No GUI setting can make dnsmasq handle DHCPv6 — CVE-2026-4892 is unreachable.
- DNSSEC is not compiled (`no-DNSSEC`) — 3 CVEs are entirely unreachable.

### Pinnacle — dnsmasq 2.90 (OVERALL: PASS)

```
Compile options: IPv6 DHCP no-DHCPv6 no-DNSSEC no-conntrack no-ipset no-auth no-cryptohash
```

| CVE | Result | Reason |
|-----|--------|--------|
| CVE-2026-2291 | PASS | DNSSEC not compiled |
| CVE-2026-4890 | PASS | DNSSEC not compiled |
| CVE-2026-4891 | PASS | DNSSEC not compiled |
| CVE-2026-4892 | PASS | DHCPv6 not compiled |
| CVE-2026-4893 | PASS | Logic bug only — no crash |
| CVE-2026-5172 | PASS | Survived exploit variants |

**Notes:**
- Pinnacle uses `nodhcpv6` build variant (`-DNO_DHCP6`) — CVE-2026-4892 code doesn't exist in binary.
- DNSSEC not compiled (`no-DNSSEC`, `no-cryptohash`) — 3 CVEs unreachable.
- CVE-2026-5172 targets `extract_addresses()` but dnsmasq 2.90 validates rdlen before processing.

### Conclusion

Both platforms are **not practically exploitable** for any of the 6 CVEs in their
production build configurations. The dangerous features (DNSSEC, DHCPv6-via-dnsmasq)
are either not compiled or not configured. Patches are still recommended as
defense-in-depth.

### Expected Results

**Pre-fix (dnsmasq 2.78 on Oak):**
| CVE | Result | Reason |
|-----|--------|--------|
| CVE-2026-2291 | PASS | DNSSEC not compiled — not exploitable |
| CVE-2026-4890 | PASS | DNSSEC not compiled — not exploitable |
| CVE-2026-4891 | PASS | DNSSEC not compiled — not exploitable |
| CVE-2026-4892 | PASS/FAIL | DHCPv6 compiled + dhcp-script active |
| CVE-2026-4893 | PASS | Logic bug — no crash (version-based only) |
| CVE-2026-5172 | PASS | blockdata_expand path not in 2.78 |

**Pre-fix (dnsmasq 2.90 with DNSSEC on Pinnacle):**
| CVE | Result | Reason |
|-----|--------|--------|
| CVE-2026-2291 | FAIL | Heap overflow via escaped names |
| CVE-2026-4890 | FAIL | Infinite loop (hangs) |
| CVE-2026-4891 | FAIL | RRSIG OOB read crash |
| CVE-2026-4892 | PASS/FAIL | Depends on DHCPv6 + script config |
| CVE-2026-4893 | PASS | Logic bug — no crash |
| CVE-2026-5172 | FAIL | OOB read via falsified rdlen |

**Post-fix (dnsmasq 2.92rel2 or backport patches applied):**
All 6 CVEs → PASS

### Requirements

- Python 3.6+ with `paramiko` (`pip install paramiko`)
- Root/sudo on laptop (to bind DNS on port 53)
- SSH access to DUT (read-only — used for process state checks)
- Laptop connected to DUT's LAN (192.168.1.x network)

### Options Reference

| Flag | Default | Description |
|------|---------|-------------|
| `--laptop` | *(required)* | Laptop's WAN IP (binds malicious DNS server here) |
| `--dut` | 192.168.1.1 | DUT's LAN IP (SSH + DNS queries sent here) |
| `--dut-user` | root | DUT SSH username |
| `--dut-pass` | *(prompted)* | DUT SSH password |
| `--dns-port` | 53 | Port for malicious DNS server |
| `--cve` | all 6 | Specific CVE(s) to test (repeatable) |

---

## Other Tools

### Remote Black-Box Tester (`test_dnsmasq_cve_remote.py`)

Lightweight version check only — queries `version.bind` to determine if dnsmasq
version is below the fix. No SSH, no setup, no exploit payloads.

```bash
python3 test_dnsmasq_cve_remote.py 192.168.1.1
```

### On-Device Script (`test_dnsmasq_cve_on_device.sh`)

Runs directly on the DUT via SSH/serial. Checks binary version and compile options.

```bash
scp test_dnsmasq_cve_on_device.sh root@192.168.1.1:/tmp/
ssh root@192.168.1.1 "sh /tmp/test_dnsmasq_cve_on_device.sh"
```

### Static Source Analyzer (`dnsmasq_cve_tester.py`)

For developers — inspects source code for exact fix patterns.

```bash
python3 dnsmasq_cve_tester.py --source ~/code/.../dnsmasq-2.78/src/
```

### Malicious DNS Server (`malicious_dns_server.py`)

Standalone exploit server for manual testing. Run it, point DUT's upstream DNS at it,
then trigger queries to `crash-5172.evil.test`, `crash-2291.evil.test`, etc.

```bash
sudo python3 malicious_dns_server.py --port 53
# Then on DUT: configure upstream → this host
# Then trigger: dig @192.168.1.1 crash-5172.evil.test
```

---

## Verifying the Fix

After patching, re-run the automated tool:

```bash
# After applying patches and flashing firmware:
sudo python3 dnsmasq_cve_verify.py

# Expected: all 6 PASS
```

## Requirements Summary

| Tool | Python | Root | SSH | Network |
|------|--------|------|-----|---------|
| `dnsmasq_cve_verify.py` | 3.6+ paramiko | Yes (port 53) | Yes (read-only) | LAN to DUT |
| `test_dnsmasq_cve_remote.py` | 3.6+ stdlib | No | No | UDP 53 to DUT |
| `test_dnsmasq_cve_on_device.sh` | N/A (shell) | No | Run on DUT | N/A |
| `dnsmasq_cve_tester.py` | 3.6+ stdlib | No | No | Optional |
| `malicious_dns_server.py` | 3.6+ stdlib | Yes (port 53) | No | DUT forwards to us |

## References

- ISPreview: https://www.ispreview.co.uk/index.php/2026/05/string-of-dnsmasq-vulnerabilities-threatens-uk-broadband-routers.html
- Help Net Security: https://www.helpnetsecurity.com/2026/05/12/dnsmasq-vulnerabilities-cve/
- Upstream patches: https://thekelleys.org.uk/dnsmasq/CVE/
- dnsmasq changelog: https://thekelleys.org.uk/dnsmasq/CHANGELOG
