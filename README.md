# Miscellaneous Tools

A collection of utility scripts and tools for network device management, monitoring, and automation tasks at Linksys.

## Table of Contents

- [Overview](#overview)
- [Tools](#tools)
  - [WiFi Client Monitor](#wifi-client-monitor)
  - [Register Dump (5GHz Radio Debug)](#register-dump-5ghz-radio-debug)
  - [Strip Sensitive Data](#strip-sensitive-data)
  - [CVE-2021-27137 miniupnpd Exploit Test](#cve-2021-27137-miniupnpd-exploit-test)
  - [CVE-2026 dnsmasq Vulnerability Tester](#cve-2026-dnsmasq-vulnerability-tester)
- [Installation](#installation)
- [Requirements](#requirements)
- [Contributing](#contributing)
- [License](#license)

---

## Overview

This repository contains various utility scripts designed to assist with daily work tasks, particularly focused on:

- Network device monitoring
- WiFi client management
- Router/AP diagnostics
- Automation scripts for repetitive tasks

Each tool is documented with its purpose, usage instructions, and technical details.

---

## Tools

| Tool | Script | Description |
|------|--------|-------------|
| [WiFi Client Monitor](#wifi-client-monitor) | [`monitor_wifi_clients.sh`](scripts/monitor_wifi_clients.sh) | Monitor client associations on wireless interface |
| [Register Dump](#register-dump-5ghz-radio-debug) | [`Reg_dump.sh`](scripts/Reg_dump.sh) | Capture MAC/PHY registers for 5GHz radio debugging |
| [CVE-2021-27137 Exploit Test](#cve-2021-27137-miniupnpd-exploit-test) | [`test_CVE-2021-27137_miniupnpd.sh`](test_CVE-2021-27137_miniupnpd.sh) | On-device exploit test for miniupnpd XML parser buffer overflow |
| [Strip Sensitive Data](#strip-sensitive-data) | [`strip-sensitive.py`](scripts/strip-sensitive.py) | Remove PII/secrets from code/logs before sharing with LLMs |
| [CVE-2026 dnsmasq Tester](#cve-2026-dnsmasq-vulnerability-tester) | [`dnsmasq_cve_2026/dnsmasq_cve_tester.py`](dnsmasq_cve_2026/dnsmasq_cve_tester.py) | Network + static analysis test suite for 6 dnsmasq CVEs (May 2026) |

---

### WiFi Client Monitor

**Script:** `scripts/monitor_wifi_clients.sh`

**Purpose:** Monitors WiFi client associations on a wireless interface and logs state changes (clients connecting/disconnecting) to a file.

**Related Issue:** [linksys/LinksysWRT#46](https://github.com/linksys/LinksysWRT/issues/46) - After 7 days 5GHz stopped broadcasting, and child nodes disconnected

#### Description

This script continuously monitors the `ath10` wireless interface on Qualcomm/Atheros-based routers and access points. It detects when clients associate or disassociate from the network and creates detailed log entries capturing the full station list at each state transition.

#### Features

- Real-time monitoring with configurable polling interval (default: 30 seconds)
- State change detection (associated → disassociated and vice versa)
- Timestamped log entries with full `wlanconfig` output
- Lightweight shell script compatible with BusyBox environments
- Console feedback for monitoring status
- Automated QDSS trace capture and upload to lab server via SCP on client disassociation
- Dropbear SSH key-based authentication (no password required after setup)
- Timestamped remote filenames to preserve multiple trace captures
- Fallback to local `/tmp/` copy if SCP upload fails

#### Technical Details

| Aspect | Details |
|--------|---------|
| **Language** | POSIX Shell (sh) |
| **Target Platform** | OpenWrt / QCA-based routers |
| **Interface Tool** | `wlanconfig` (Qualcomm Atheros wireless driver utility) |
| **Log Location** | `/tmp/clients.log` |
| **Default Interface** | `ath10` (5GHz radio) |
| **Polling Interval** | 30 seconds |
| **Trace Upload** | SCP to `linksys@192.168.5.85:/home/linksys/` |
| **SSH Auth** | Dropbear key at `/root/.ssh/id_dropbear` |

#### How It Works

1. **Initialization**: The script starts with an unknown previous state (`-1`)
2. **Client Detection**: Uses `wlanconfig <interface> list sta` to retrieve the station list
3. **Parsing**: Counts lines matching MAC address patterns (format: `xx:xx:xx:xx:xx:xx`)
4. **State Comparison**: Compares current client count with previous state
5. **Logging**: On state change, logs full station output with timestamp
6. **Diagnostic Collection** (on client disassociation):
   - Runs `wifistats_regdump.sh` for register dumps
   - Captures first QDSS trace via `cnsscli`
   - Uploads trace file to lab server via SCP (timestamped filename)
   - Captures second QDSS trace and triggers FW recovery
7. **Loop**: Sleeps for the configured interval and repeats

#### SSH Key Setup (One-Time)

Before the script can upload trace files, set up dropbear key-based auth on the router:

```bash
# Generate a dropbear RSA key
dropbearkey -t rsa -f /root/.ssh/id_dropbear

# Extract the public key
dropbearkey -y -f /root/.ssh/id_dropbear | grep "^ssh-rsa" > /tmp/id_dropbear.pub

# Copy it to the lab server (enter password once: LinksysLab123!)
ssh linksys@192.168.5.85 "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys" < /tmp/id_dropbear.pub
```

After this setup, all SCP uploads from the script will be passwordless.

#### Usage

**Basic usage on router:**

```bash
# Copy script to router
scp scripts/monitor_wifi_clients.sh root@<router-ip>:/tmp/

# SSH to router and run
ssh root@<router-ip>
chmod +x /tmp/monitor_wifi_clients.sh
/tmp/monitor_wifi_clients.sh
```

**Run in background:**

```bash
# Start in background with nohup
nohup /tmp/monitor_wifi_clients.sh > /dev/null 2>&1 &

# Or use screen/tmux for interactive monitoring
screen -S wifi-monitor
/tmp/monitor_wifi_clients.sh
# Detach with Ctrl+A, D
```

**Stop the monitor:**

```bash
# Find and kill the process
ps | grep monitor_wifi
kill <pid>

# Or kill by name
killall monitor_wifi_clients.sh
```

#### Configuration

You can modify these variables at the top of the script:

```bash
LOG_FILE="/tmp/clients.log"    # Output log file path
INTERFACE="ath10"              # Wireless interface to monitor
INTERVAL=30                    # Polling interval in seconds
```

The trace upload destination is configured in the diagnostic section:

```bash
REMOTE_HOST="192.168.5.85"    # Lab server IP
REMOTE_USER="linksys"         # SSH username
REMOTE_DIR="/home/linksys"    # Remote destination directory
```

**To monitor a different interface:**

```bash
# For 2.4GHz radio (commonly ath0 or ath1)
INTERFACE="ath0"

# For 6GHz radio (if available)
INTERFACE="ath30"
```

#### Log Output Format

```
========================================
Timestamp: 2026-04-19 10:30:15
Event: NO CLIENTS ASSOCIATED (was: 1 clients)
----------------------------------------
ADDR               AID CHAN TXRATE RXRATE RSSI MINRSSI MAXRSSI IDLE  TXSEQ  RXSEQ  CAPS ...

========================================
Timestamp: 2026-04-19 10:31:45
Event: CLIENTS ASSOCIATED (count: 2)
----------------------------------------
ADDR               AID CHAN TXRATE RXRATE RSSI MINRSSI MAXRSSI IDLE  TXSEQ  RXSEQ  CAPS ...
4c:b9:ea:f5:41:04    1   36 120M    150M  -45     -59     -39   18      0   65535  EPsR ...
 RSSI is combined over chains in dBm
 Minimum Tx Power        : 13
 Maximum Tx Power        : 21
 ...
```

#### Understanding the Output

The `wlanconfig list sta` command provides detailed information about each connected client:

| Field | Description |
|-------|-------------|
| `ADDR` | Client MAC address |
| `AID` | Association ID |
| `CHAN` | Operating channel |
| `TXRATE` | Transmit rate to client |
| `RXRATE` | Receive rate from client |
| `RSSI` | Received Signal Strength Indicator (dBm) |
| `MINRSSI/MAXRSSI` | Min/Max RSSI observed |
| `IDLE` | Seconds since last activity |
| `MODE` | PHY mode (e.g., 11AXA_HE160, 11NA_HT40) |
| `ASSOCTIME` | Time since association (HH:MM:SS) |

#### Use Cases

1. **Debugging connectivity issues**: Track when specific clients connect/disconnect
2. **Site surveys**: Monitor client density over time
3. **QA testing**: Verify roaming behavior during firmware testing
4. **Performance analysis**: Correlate client associations with performance metrics

#### Troubleshooting

**Script not detecting clients:**
- Verify the interface name: `iwconfig` or `ifconfig -a`
- Check if `wlanconfig` is available: `which wlanconfig`
- Ensure the interface is up: `ifconfig ath10`

**Permission denied:**
- Run as root: `su` or use `sudo`
- Check script permissions: `chmod +x monitor_wifi_clients.sh`

**Log file not created:**
- Verify `/tmp` is writable
- Check disk space: `df -h /tmp`

---

### Register Dump (5GHz Radio Debug)

**Script:** `scripts/Reg_dump.sh`

**Purpose:** Collects detailed MAC/PHY register dumps and WiFi statistics to debug 5GHz radio failures.

**Related Issue:** [linksys/LinksysWRT#46](https://github.com/linksys/LinksysWRT/issues/46) - After 7 days 5GHz stopped broadcasting, and child nodes disconnected

#### Description

This diagnostic script captures low-level hardware register values and WiFi statistics from Qualcomm Atheros wireless chipsets. It is designed to help debug intermittent 5GHz radio failures where the radio stops broadcasting after extended operation periods (e.g., 7+ days).

The script collects:
- **PMAC (Primary MAC) registers**: RX PCU counters, FSM states, crypto interface TLVs
- **DMAC (DMA Controller) registers**: RXDMA debug counters, MPDU/PPDU received counts
- **PHY registers**: RX time-domain controls, AGC power targets, 11b detection controls
- **WiFi statistics**: Per-radio stats via `wifistats` command
- **TXRX statistics**: Data path statistics via `cfg80211tool`

#### Technical Details

| Aspect | Details |
|--------|---------|
| **Language** | BusyBox ash (POSIX shell) |
| **Target Platform** | QCA IPQ-based routers (Linksys Pinnacle, etc.) |
| **Primary Tool** | `athdiag` (Atheros diagnostic utility) |
| **Supporting Tools** | `wifistats`, `cfg80211tool` |
| **Default Interface** | `wifi1` / `ath10` (5GHz radio) |
| **Collection Cycles** | 10 iterations, 1 second apart |

#### Registers Monitored

**PMAC0 RXPCU (Receive Protocol Control Unit) Registers:**

| Address | Register Name | Purpose |
|---------|---------------|---------|
| `0xA8D164` | RXPCU_R1_CRYPTO_INTF_TLV_RX_MPDU_END_CNT | MPDU end TLV count |
| `0xA8D168` | RXPCU_R1_CRYPTO_INTF_TLV_RX_MPDU_PCU_START_CNT | MPDU PCU start count |
| `0xA8D16C` | RXPCU_R1_CRYPTO_INTF_TLV_RX_PPDU_END_CNT | PPDU end count |
| `0xA8D170` | RXPCU_R1_CRYPTO_INTF_TLV_RX_PPDU_START_CNT | PPDU start count |
| `0xA8D0C8-D0` | RXPCU_R1_FSM_STATUS_0/1/2 | FSM state machine status |
| `0xA8D184` | RXPCU_R1_PKT_DEBUG_FILTER_IN_CNT | Packets entering filter |
| `0xA8D188` | RXPCU_R1_PKT_DEBUG_FILTER_OUT_CNT | Packets passing filter |
| `0xA8D18C` | RXPCU_R1_PKT_DEBUG_OVERFLOW_CNT | Overflow counter |

**DMAC RXDMA Registers:**

| Address | Register Name | Purpose |
|---------|---------------|---------|
| `0x94454C` | RXDMA_MC_R1_DEBUG_PPDU_RCVD | PPDUs received by DMA |
| `0x944550` | RXDMA_MC_R1_DEBUG_MPDU_RCVD | MPDUs received by DMA |
| `0x944554-58` | DEBUG_DEST_RING_MPDU_RCVD_1/2 | Destination ring counters |

**PHY Registers (RXTD - Receive Time Domain):**

| Address | Register Name | Purpose |
|---------|---------------|---------|
| `0x500438-448` | RX11B_DET_CTRL | 802.11b detection controls |
| `0x500450-470` | RXB_RX_* | RX configuration and diversity |
| `0x500358` | AGC_PWR_TARGET_3_L | AGC power target |
| `0x5003A8` | TFEST_CONTROL_L | Time/frequency estimation |

#### Usage

**Basic usage:**

```bash
# Copy to router
scp scripts/Reg_dump.sh root@<router-ip>:/tmp/

# SSH and run
ssh root@<router-ip>
chmod +x /tmp/Reg_dump.sh
/tmp/Reg_dump.sh > /tmp/reg_dump_output.txt 2>&1
```

**For debugging 5GHz failure:**

```bash
# Run when 5GHz stops working (before reboot!)
/tmp/Reg_dump.sh > /tmp/5ghz_failure_$(date +%Y%m%d_%H%M%S).txt 2>&1

# Collect system state as well
dmesg > /tmp/dmesg_5ghz_failure.txt
logread > /tmp/logread_5ghz_failure.txt
```

**Run periodically to capture state before failure:**

```bash
# Cron job example (every hour)
echo "0 * * * * /tmp/Reg_dump.sh >> /tmp/hourly_reg_dump.txt 2>&1" >> /etc/crontabs/root
```

#### Configuration

Modify these variables at the top of the script:

```bash
WIFI_INTERFACE=1      # WiFi radio index (0=2.4GHz, 1=5GHz, 2=6GHz)
WIFI_NAME=wifi1       # Radio name for wifistats
ATH_NAME=ath10        # VAP interface name for cfg80211tool
```

**For 2.4GHz radio:**
```bash
WIFI_INTERFACE=0
WIFI_NAME=wifi0
ATH_NAME=ath0
```

**For 6GHz radio (tri-band):**
```bash
WIFI_INTERFACE=2
WIFI_NAME=wifi2
ATH_NAME=ath30
```

#### Output Format

```
========================================
Collection 1 - Timestamp: Sat Apr 19 10:30:15 UTC 2026
========================================

--- MAC Register Reads ---
[0xA8D164] PMAC0_RXPCU_R1_CRYPTO_INTF_TLV_RX_MPDU_END_CNT = 0x00012345
[0xA8D168] PMAC0_RXPCU_R1_CRYPTO_INTF_TLV_RX_MPDU_PCU_START_CNT = 0x00012346
...

--- WIFISTATS Output ---
WIFISTATS 1:
<radio statistics>
WIFISTATS 2:
...

--- CFG80211 TXRX Stats ---
cfg80211tool ath10 txrx_stats 258:
<txrx statistics>
...
----------------------------------------

Collection 2 - Timestamp: ...
```

#### Interpreting Results

**Signs of RX path issues:**
- `FILTER_IN_CNT` increasing but `FILTER_OUT_CNT` stuck → RX filter problem
- `OVERFLOW_CNT` non-zero → Buffer overflow, packets being dropped
- FSM status stuck in unexpected state → State machine hung

**Signs of DMA issues:**
- `PPDU_RCVD` / `MPDU_RCVD` counters not incrementing → DMA not receiving
- Mismatch between PMAC and DMAC counters → Data path blockage

**Normal operation:**
- Counters incrementing steadily across collections
- No overflow counters
- FSM status cycling through expected states

#### Use Cases

1. **5GHz radio failure debugging**: Capture state when radio stops broadcasting
2. **Intermittent connectivity issues**: Periodic collection to catch anomalies
3. **Firmware regression testing**: Compare register states across versions
4. **QCA escalation support**: Provide detailed hardware state for vendor analysis

#### Requirements

- Root access to router
- QCA IPQ-based platform with `athdiag` utility
- `wifistats` and `cfg80211tool` commands available

---


### CVE-2021-27137 miniupnpd Exploit Test

**Script:** `test_CVE-2021-27137_miniupnpd.sh`

**Purpose:** On-device exploit test to verify that miniupnpd correctly handles truncated XML attributes (buffer read overflow in `minixml.c` `parseatt()` function).

**CVE:** CVE-2021-27137 | **Fix:** [miniupnp/miniupnp@3cfb4fb](https://github.com/miniupnp/miniupnp/commit/3cfb4fb78d5ac04ed0dadc8dd842fc9e448916db)

**Affected:** miniupnpd <= 2.3.3 (includes QSDK 12.5 and 14.0)

#### Description

The vulnerability is a buffer read overflow in `minixml.c` where the `parseatt()` function advances past `=` in XML attributes without bounds checking. Truncated input like `<element attribute=` (no value after `=`) causes out-of-bounds memory reads that can crash the daemon or leak memory contents.

This script sends multiple malformed XML payloads to the device and verifies the daemon stays alive after each one.

#### Technical Details

| Aspect | Details |
|--------|--------|
| **Language** | Bash |
| **Target** | Any device running miniupnpd (OpenWrt, QSDK) |
| **Protocol** | HTTP POST to UPnP SOAP endpoint |
| **Dependencies** | `nc` (netcat), `ping`, optional SSH |
| **Payloads** | 4 variants of truncated/malformed XML attributes |

#### Test Cases

| # | Payload | What It Tests |
|---|---------|---------------|
| 1 | `<element attribute=` | Core CVE trigger — truncated after `=` |
| 2 | `<s xmlns:u="urn:..." u:a=` | Namespaced attribute at buffer boundary |
| 3 | `<root><child attr1="ok" attr2=` | Nested elements with partial second attr |
| 4 | `<element verylongattributename` | Attribute name with no `=` (secondary bounds check) |
| 5 | Valid SOAP GetExternalIPAddress | Regression check — normal UPnP still works |

#### Usage

```bash
# Basic test
./test_CVE-2021-27137_miniupnpd.sh 192.168.1.1

# Custom port
./test_CVE-2021-27137_miniupnpd.sh 192.168.1.1 5000
```

#### Example Output

```
==============================================
 CVE-2021-27137 miniupnpd Exploit Tester
 Target: 192.168.1.1:5000
==============================================

[PASS] Device is reachable
[PASS] Port 5000 is open
[INFO] miniupnpd PID before tests: 1234

--- Running exploit payloads ---

[INFO] Test 1: Sending truncated attribute payload (core CVE trigger)...
[PASS] Test 1 (truncated attribute=) — daemon still alive
[INFO] Test 2: Sending attribute with = at end-of-buffer...
[PASS] Test 2 (attribute at buffer end) — daemon still alive
[INFO] Test 3: Sending nested elements with truncated attributes...
[PASS] Test 3 (nested truncated) — daemon still alive
[INFO] Test 4: Sending attribute name with no = (hits first boundary)...
[PASS] Test 4 (no equals sign) — daemon still alive

--- Running regression check ---

[PASS] Normal UPnP request returns valid response

--- Checking post-test daemon state ---

[PASS] Daemon PID unchanged (1234) — no crash/restart

==============================================
 Results: 7 PASSED, 0 FAILED
==============================================

PASSED: miniupnpd handled all malformed XML without crashing.
```

#### Interpreting Results

- **All PASS**: The CVE fix is applied (or the daemon survived by luck — run multiple times)
- **FAIL on Tests 1-4**: Daemon crashed from malformed XML — **vulnerable**, apply the patch
- **PID changed**: Daemon crashed but was auto-restarted by procd — still **vulnerable**
- **Test 5 (regression) fails**: Normal UPnP broken — may indicate incorrect patch application

---
### Strip Sensitive Data

**Script:** `scripts/strip-sensitive.py`

**Purpose:** Sanitizes code, logs, and text files by removing PII and secrets before sharing with external LLMs or posting publicly.

#### Description

This Python script automatically detects and redacts sensitive information from text content, making it safe to share code snippets, log files, or configuration data with external AI assistants, support forums, or documentation.

#### Features

- **API Keys & Tokens**: AWS keys, GitHub tokens, Slack tokens, generic API keys
- **Credentials**: Passwords, secrets, private keys, certificates
- **Personal Data**: Email addresses, phone numbers, SSNs, credit card numbers
- **Network Data**: IP addresses (distinguishes private/internal vs public), MAC addresses
- **System Data**: User paths (`/Users/username`, `C:\Users\username`), internal hostnames
- **Project Names**: Configurable list of proprietary names to redact (Linksys, Velop, etc.)
- **Custom Keywords**: Add your own sensitive terms via config file or CLI

#### Technical Details

| Aspect | Details |
|--------|---------|
| **Language** | Python 3.6+ |
| **Dependencies** | None (standard library only) |
| **Input** | File, stdin, or piped input |
| **Output** | File, stdout |
| **Config** | Optional JSON configuration file |

#### Usage

**Basic usage:**

```bash
# From file to file
./strip-sensitive.py input.log output.log

# From stdin (use '-' for stdin)
cat server.log | ./strip-sensitive.py - > clean.log

# Pipe directly
./strip-sensitive.py input.txt | pbcopy  # Copy to clipboard (macOS)
```

**With options:**

```bash
# Verbose mode (show redaction statistics)
./strip-sensitive.py input.log -o output.log -v

# Dry run (see what would be redacted without changing)
./strip-sensitive.py input.log --dry-run

# Add custom project names to redact
./strip-sensitive.py input.log --add-project "SecretProject" --add-project "InternalTool"

# Add custom keywords
./strip-sensitive.py input.log --add-keyword "confidential" --add-keyword "internal-api"

# Use custom config file
./strip-sensitive.py input.log -c my_config.json
```

#### Configuration

Create a JSON config file for persistent settings:

```json
{
  "project_names": [
    "linksys",
    "velop",
    "your-company-name"
  ],
  "custom_keywords": [
    "internal-service",
    "secret-project"
  ],
  "placeholders": {
    "email": "[EMAIL_REDACTED]",
    "ip_private": "[INTERNAL_IP]",
    "api_key": "[API_KEY_REDACTED]"
  }
}
```

See `scripts/strip-sensitive-config.example.json` for full configuration options.

#### Example

**Input:**
```
User john@company.com connected from 192.168.1.100
MAC: 00:1A:2B:3C:4D:5E
API_KEY=sk_live_abc123def456ghi789
Linksys device at 10.0.0.1
Path: /Users/jianrongxiao/Desktop/project
```

**Output:**
```
User [EMAIL_REDACTED] connected from [INTERNAL_IP]
MAC: [MAC_REDACTED]
[API_KEY_REDACTED]
[PROJECT_REDACTED] device at [INTERNAL_IP]
Path: /Users/[USER_REDACTED]/Desktop/project
```

#### Detected Patterns

| Category | Examples |
|----------|----------|
| **API Keys** | `AKIA...`, `ghp_...`, `xoxb-...`, `sk_live_...` |
| **Passwords** | `password=xxx`, `pwd: xxx`, `passwd=xxx` |
| **Emails** | `user@domain.com` |
| **Phone Numbers** | `555-123-4567`, `+1 (555) 123-4567` |
| **IP Addresses** | `192.168.x.x` (private), `8.8.8.8` (public) |
| **MAC Addresses** | `00:1A:2B:3C:4D:5E` |
| **SSN** | `123-45-6789` |
| **Credit Cards** | Visa, Mastercard, Amex patterns |
| **Private Keys** | `-----BEGIN PRIVATE KEY-----` |
| **User Paths** | `/Users/name/...`, `C:\Users\name\...` |

#### Use Cases

1. **Sharing logs with external LLMs**: Sanitize before pasting into ChatGPT, Claude, etc.
2. **Bug reports**: Clean sensitive data before posting to GitHub issues
3. **Documentation**: Redact real values when creating examples
4. **Code review**: Share code snippets without exposing credentials
5. **Support tickets**: Clean logs before sending to vendors

---

## Installation

### Clone the Repository

```bash
git clone https://github.com/JianrongXiao-Linksys/miscellaneous.git
cd miscellaneous
```

### Deploy to Router

```bash
# Copy specific script
scp scripts/monitor_wifi_clients.sh root@<router-ip>:/tmp/

# Or copy all scripts
scp -r scripts/* root@<router-ip>:/tmp/tools/
```

---

## Requirements

### For WiFi Client Monitor

- **Platform**: Linux-based router/AP with Qualcomm Atheros wireless drivers
- **Shell**: POSIX-compliant shell (sh, ash, bash)
- **Commands**: `wlanconfig`, `grep`, `date`, `sleep`
- **Access**: Root/admin access to the device

### Tested On

- Linksys routers with QCA IPQ series chipsets
- OpenWrt-based firmware
- BusyBox shell environment

---

### CVE-2026 dnsmasq Vulnerability Tester

**Script:** `dnsmasq_cve_2026/dnsmasq_cve_tester.py`

**Purpose:** Tests for the 6 dnsmasq vulnerabilities disclosed in May 2026 that threaten broadband routers. Supports network testing (against live dnsmasq instances), static source code analysis, and binary version checking.

**CVEs Covered:**

| CVE | CVSS | Impact | Prerequisite |
|-----|------|--------|--------------|
| CVE-2026-2291 | 9.2 (Critical) | Heap overflow in `extract_name()` → RCE/cache poisoning | DNS active (always) |
| CVE-2026-5172 | 7.5 (High) | OOB read in `extract_addresses()` → crash | DNS active (always) |
| CVE-2026-4890 | 7.5 (High) | NSEC bitmap infinite loop → complete DoS | `--dnssec` |
| CVE-2026-4891 | 5.3 (Moderate) | RRSIG heap OOB read → info leak | `--dnssec` |
| CVE-2026-4892 | 8.4 (High) | DHCPv6 CLID overflow → local root | `--dhcp-script` + DHCPv6 |
| CVE-2026-4893 | 5.3 (Moderate) | ECS source validation bypass | `--add-subnet` |

**Fix version:** dnsmasq 2.92rel2 (released 2026-05-11)

#### Usage

```bash
# Static source code analysis (no network needed, safe)
python3 dnsmasq_cve_2026/dnsmasq_cve_tester.py \
  --source ~/code/Main_Oak/products/oak/output/release/dnsmasq/build/dnsmasq-2.78 \
  --source ~/code/pinnacle/develop_46_2.2/store/sdk/qsdk/build_dir/target-arm/dnsmasq-nodhcpv6/dnsmasq-2.90

# Binary version check
python3 dnsmasq_cve_2026/dnsmasq_cve_tester.py --binary /usr/sbin/dnsmasq
```

#### QA Test Procedure — Verify on Device (No Source Code Needed)

**Step 1:** Copy script to DUT:
```bash
scp dnsmasq_cve_2026/test_dnsmasq_cve_on_device.sh root@192.168.1.1:/tmp/
```

**Step 2:** Run on DUT:
```bash
ssh root@192.168.1.1 "sh /tmp/test_dnsmasq_cve_on_device.sh"
```

**Step 3:** Read result:
```
  CVE-2026-2291 (heap overflow):     FAIL (version 2.78 < 2.92rel2)
  CVE-2026-5172 (OOB read crash):    FAIL (version 2.78 < 2.92rel2)
  CVE-2026-4890 (NSEC DoS):          N/A (DNSSEC not compiled)
  CVE-2026-4891 (RRSIG OOB read):    N/A (DNSSEC not compiled)
  CVE-2026-4892 (CLID overflow):     FAIL (version 2.78 < 2.92rel2)
  CVE-2026-4893 (ECS bypass):        FAIL (version 2.78 < 2.92rel2)

  RESULT: FAIL — 4/6 vulnerable
```

**After applying fix:** Re-run same script. Expect all PASS or N/A.

#### Requirements

- SSH access to DUT
- Script uses only `strings`, `grep`, `sh` — no Python needed on device

---

## Project Structure

```
miscellaneous/
├── README.md                              # This file
├── scripts/
│   ├── monitor_wifi_clients.sh            # WiFi client monitoring + QDSS trace upload
│   ├── wifistats_regdump.sh              # WiFi stats and register dump collection
│   ├── Reg_dump.sh                        # 5GHz radio register dump diagnostic
│   ├── strip-sensitive.py                 # PII/secrets stripping tool
│   └── strip-sensitive-config.example.json # Example config for strip-sensitive
├── test_CVE-2021-27137_miniupnpd.sh     # CVE-2021-27137 on-device exploit test
├── dnsmasq_cve_2026/                     # CVE-2026 dnsmasq vulnerability test suite
│   ├── dnsmasq_cve_tester.py            # Main test tool (network + static analysis)
│   └── README.md                         # Detailed usage documentation
└── (future tools...)
```

---

## Contributing

1. Create a new branch for your tool/feature
2. Add your script to the appropriate directory
3. Update this README with documentation
4. Submit a pull request

### Adding a New Tool

When adding a new tool, please include:

1. **Script file** in the appropriate directory
2. **Documentation** in this README with:
   - Purpose and description
   - Technical details
   - Usage instructions
   - Configuration options
   - Example output

---

## License

Internal use - Linksys

---

## Author

Jianrong Xiao - Linksys Firmware Team
