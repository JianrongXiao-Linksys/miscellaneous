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
│   enx24f5a2f20603 (LAN)          enp0s31f6 (WAN)                   │
│   192.168.1.254                   10.0.0.211                        │
│        │                               │                            │
│   ┌────┴──────────────┐               │                            │
│   │ Malicious DNS     │               │   (not used for this test) │
│   │ Server (port 53)  │               │                            │
│   │ + DHCPv6 client   │               │                            │
│   └────┬──────────────┘               │                            │
│        │                               │                            │
└────────┼───────────────────────────────┼────────────────────────────┘
         │ LAN (192.168.1.0/24)          │ WAN (10.0.0.0/24)
         │                               │
┌────────┼───────────────────────────────┼────────────────────────────┐
│        │                               │                            │
│   br0: 192.168.1.1               eth4: 10.0.0.214                  │
│   (LAN gateway)                   (WAN uplink)                      │
│                                                                      │
│              DUT (Oak / Pinnacle Router)                             │
│              dnsmasq 2.78 / 2.90                                    │
│                                                                      │
│   resolv-file=/etc/resolv.conf                                      │
│   → nameserver 192.168.1.254  ← forwards queries to our server     │
│   dhcp-script=/etc/init.d/.../dnsmasq_dhcp.script                   │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### How It Works

```
┌──────────┐     ┌───────────┐     ┌──────────────────┐     ┌──────────┐
│  SETUP   │ ──► │  TRIGGER  │ ──► │  STATE INSPECT   │ ──► │  VERDICT │
│          │     │           │     │                  │     │          │
│ Start    │     │ Send DNS  │     │ SSH to DUT:      │     │ PASS:    │
│ malicious│     │ query to  │     │ - pidof dnsmasq  │     │ survived │
│ DNS srv  │     │ DUT→DUT   │     │ - PID changed?   │     │          │
│ on laptop│     │ forwards  │     │ - dmesg crash?   │     │ FAIL:    │
│          │     │ to us→we  │     │ - /var/log/msg   │     │ crashed/ │
│ Config   │     │ reply w/  │     │                  │     │ hung     │
│ DUT DNS  │     │ exploit   │     │ Liveness query   │     │          │
│ upstream │     │ payload   │     │ (version.bind)   │     │          │
└──────────┘     └───────────┘     └──────────────────┘     └──────────┘
```

### Running the Tool

```bash
# Full test — all 6 CVEs (requires sudo for port 53)
sudo python3 dnsmasq_cve_verify.py

# Test specific CVE(s)
sudo python3 dnsmasq_cve_verify.py --cve CVE-2026-5172
sudo python3 dnsmasq_cve_verify.py --cve CVE-2026-4892 --cve CVE-2026-5172

# Custom DUT/laptop IPs
sudo python3 dnsmasq_cve_verify.py --dut 192.168.1.1 --laptop 192.168.1.254

# If DUT is already configured to forward DNS to this laptop
sudo python3 dnsmasq_cve_verify.py --skip-setup

# Non-root (uses high port — DUT must be manually configured to forward here)
python3 dnsmasq_cve_verify.py --dns-port 5353 --skip-setup

# Custom SSH credentials
sudo python3 dnsmasq_cve_verify.py --dut-user admin --dut-pass mypassword
```

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
| `--dut` | 192.168.1.1 | DUT IP address |
| `--laptop` | 192.168.1.254 | Laptop's LAN IP (binds DNS server here) |
| `--dut-user` | root | DUT SSH username |
| `--dut-pass` | 12345Asdf@ | DUT SSH password |
| `--dns-port` | 53 | Port for malicious DNS server |
| `--cve` | all 6 | Specific CVE(s) to test (repeatable) |
| `--skip-setup` | false | Skip DUT DNS configuration |

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
