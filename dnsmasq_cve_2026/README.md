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

## Verifying the Fix

After patching, re-run the tool to confirm:

```bash
# Static analysis should show PATCHED for all CVEs
python3 dnsmasq_cve_tester.py --source /path/to/patched-dnsmasq-source/

# Network test should show dnsmasq survives all crafted packets
python3 dnsmasq_cve_tester.py --target <device-ip-with-patched-firmware>
```

Expected output after successful patch:
- Static analysis: all CVEs show `PATCHED` or `LIKELY PATCHED`
- Network tests: dnsmasq remains responsive after all attack packets
- Version check: reports version >= 2.92rel2

## Requirements

- Python 3.6+ (standard library only — no pip dependencies)
- Root/sudo for CVE-2026-4892 DHCPv6 test
- IPv6 connectivity to target for DHCPv6 test
- Network access to dnsmasq port 53 for DNS tests

## References

- ISPreview: https://www.ispreview.co.uk/index.php/2026/05/string-of-dnsmasq-vulnerabilities-threatens-uk-broadband-routers.html
- Help Net Security: https://www.helpnetsecurity.com/2026/05/12/dnsmasq-vulnerabilities-cve/
- Upstream patches: https://thekelleys.org.uk/dnsmasq/CVE/
- dnsmasq changelog: https://thekelleys.org.uk/dnsmasq/CHANGELOG
