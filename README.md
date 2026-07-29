# Miscellaneous Tools

A collection of utility scripts and tools for network device management, monitoring, and automation tasks at Linksys.

## Table of Contents

- [Overview](#overview)
- [Tools](#tools)
  - [NowTV Multicast IPTV Test Suite](#nowtv-multicast-iptv-test-suite)
  - [WiFi Client Monitor](#wifi-client-monitor)
  - [Register Dump (5GHz Radio Debug)](#register-dump-5ghz-radio-debug)
  - [Strip Sensitive Data](#strip-sensitive-data)
  - [CVE-2021-27137 miniupnpd Exploit Test](#cve-2021-27137-miniupnpd-exploit-test)
  - [CVE-2026 dnsmasq Vulnerability Tester](#cve-2026-dnsmasq-vulnerability-tester)
  - [Network Stability Checker](#network-stability-checker)
  - [Web GUI Factory-Reset Test (Issue #451)](#web-gui-factory-reset-test-issue-451)
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
| [NowTV Multicast IPTV Test](#nowtv-multicast-iptv-test-suite) | [`nowtv_multicast_test/`](nowtv_multicast_test/) | IGMP proxy test suite for NowTV multicast IPTV (Issue #334) |
| [WiFi Client Monitor](#wifi-client-monitor) | [`monitor_wifi_clients.sh`](scripts/monitor_wifi_clients.sh) | Monitor client associations on wireless interface |
| [Register Dump](#register-dump-5ghz-radio-debug) | [`Reg_dump.sh`](scripts/Reg_dump.sh) | Capture MAC/PHY registers for 5GHz radio debugging |
| [CVE-2021-27137 Exploit Test](#cve-2021-27137-miniupnpd-exploit-test) | [`miniupnpd_cve_2021_27137/`](miniupnpd_cve_2021_27137/) | CVE-2021-27137 miniupnpd test suite (verify, exploit, on-device) |
| [Strip Sensitive Data](#strip-sensitive-data) | [`strip-sensitive.py`](scripts/strip-sensitive.py) | Remove PII/secrets from code/logs before sharing with LLMs |
| [CVE-2026 dnsmasq Tester](#cve-2026-dnsmasq-vulnerability-tester) | [`dnsmasq_cve_2026/dnsmasq_cve_tester.py`](dnsmasq_cve_2026/dnsmasq_cve_tester.py) | Network + static analysis test suite for 6 dnsmasq CVEs (May 2026) |
| [Network Stability Checker](#network-stability-checker) | [`scripts/net_stability.py`](scripts/net_stability.py) | Continuous ISP outage monitor — collects Cox SLA violation evidence |
| [Web GUI Factory-Reset Test](#web-gui-factory-reset-test-issue-451) | [`web_gui_factory_reset_test/`](web_gui_factory_reset_test/) | Reproduce/diagnose #451 — web GUI refused after repeated factory resets |

---

### NowTV Multicast IPTV Test Suite

**Directory:** [`nowtv_multicast_test/`](nowtv_multicast_test/) — Full test suite (see `nowtv_multicast_test/README.md` for details)

**Purpose:** Automated test suite to validate igmpproxy multicast IPTV functionality on Pinnacle 2.0 PW (NowTV) customer build.

**Related Issue:** [linksys/LinksysWRT#334](https://github.com/linksys/LinksysWRT/issues/334) — NowTV Multicast IPTV Feature

#### Description

Tests the full IGMP proxy multicast pipeline: join/leave relay, fast leave, multi-STB scenarios, channel switching, per-port snooping, ubus event notifications, and NAT coexistence. Simulates NowTV STB behavior using IGMPv2.

#### Components

| File | Purpose | Runs On |
|------|---------|---------|
| `run_tests.sh` | 12 automated test cases (20 assertions) | LAN PC (Ubuntu, sudo) |
| `mcast_stb_sim.py` | STB simulator — join/leave/switch/multi/stress | LAN PC |
| `mcast_source.py` | Multicast UDP source (simulates CDN headend) | WAN PC (Linux/Windows) |
| `windows/mcast_source.py` | Windows-specific source with `--bind` support | WAN PC (Windows) |

#### Test Topology

```
[WAN PC: mcast_source.py] --eth--> [DUT WAN port]
[DUT LAN port] --eth--> [LAN PC: run_tests.sh + mcast_stb_sim.py]
```

#### Test Cases

| TC | Test | Criteria |
|----|------|----------|
| 1 | igmpproxy service running | Service up, quickleave, upstream/downstream configured |
| 2 | Kernel multicast routing | VIFs registered in `/proc/net/ip_mr_vif` |
| 3 | Bridge IGMP snooping | Snooping disabled, IGMPv2 forced, querier enabled |
| 4 | Single STB join & receive | MRT route created, packets forwarded |
| 5 | Fast leave | Route removed after IGMPv2 leave |
| 6 | Multi-STB same group | One STB leaves, other keeps stream |
| 7 | Multiple channels | 3 simultaneous multicast groups |
| 8 | Ubus event notification | Join/leave events via `ubus listen igmp.client` |
| 9 | Channel switch | Leave old group + join new group |
| 10 | Per-port snooping | MRT tracks correct output interfaces |
| 11 | Fast leave timing | Leave-to-route-removal < 2000ms |
| 12 | NAT coexistence | Internet works during active multicast |

#### Usage

```bash
# On WAN PC (start multicast source)
python3 mcast_source.py multi 239.1.1.1 239.1.1.2 239.1.1.3 --bind 10.0.0.100

# On LAN PC (run test suite)
sudo ./run_tests.sh 192.168.1.1 '12345Asdf@'
```

#### Requirements

- DUT: Pinnacle 2.0 with PW customer firmware (igmpproxy enabled)
- LAN PC: Ubuntu with Python 3, `sshpass`, root access
- WAN PC: Any OS with Python 3 (connected to DUT WAN port)
- DUT WAN must have IP connectivity to WAN PC (static or DHCP)

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

**Directory:** [`miniupnpd_cve_2021_27137/`](miniupnpd_cve_2021_27137/) — Full test suite (see `miniupnpd_cve_2021_27137/README.md` for details)

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

### Network Stability Checker

**Script:** `scripts/net_stability.py`

**Purpose:** Continuous ISP monitoring tool that collects outage evidence against Cox (or any ISP) by separating gateway reachability from internet connectivity. Tests both WiFi and Ethernet to conclusively prove ISP-side faults.

#### Description

Designed specifically for documenting ISP outages and SLA violations. The tool separates "can I reach my router?" from "can I reach the internet?" — if the gateway is UP but internet is DOWN on both wired and wireless, the fault is conclusively in the ISP's network.

Two modes:
- **One-shot** (default): Quick diagnostic showing current state and fault location
- **Monitor** (`--monitor`): Continuous daemon that logs every sample, detects outages, and generates an ISP complaint report

#### Key Design for ISP Evidence

| Feature | Why It Matters for Cox Complaint |
|---------|----------------------------------|
| Gateway vs Internet separation | Proves fault is Cox, not your equipment |
| Both interfaces tested simultaneously | Rules out NIC/cable problems |
| Timestamped JSONL log | Proves exact outage start/end times |
| Accelerated polling during outages (10s) | Precise duration measurement |
| SLA comparison (99.9%) | Directly demonstrates contract violation |
| Auto-generated Markdown report | Ready to submit to Cox support |

#### Technical Details

| Aspect | Details |
|--------|---------|
| **Language** | Python 3.6+ |
| **Dependencies** | None (standard library only) |
| **External Tools** | `ping`, `dig`, `curl` (all standard on Linux) |
| **Platform** | Linux (uses `-I` flag for interface binding) |
| **Log Location** | `~/cox-network-logs/` |
| **Log Format** | JSONL (one JSON object per line per test cycle) |
| **Poll Interval** | 60s normal, 10s during outage |
| **Speed Test** | Every 5 minutes (not every cycle, to avoid saturating) |

#### Fault Location Logic

```
Link DOWN           → "local_nic" (your NIC/driver problem)
Gateway unreachable → "local_network" (cable/WiFi/router LAN issue)
Gateway OK + No Internet → "isp" (Cox's fault — KEY EVIDENCE)
Gateway OK + >10% loss   → "isp_degraded" (Cox degraded service)
All OK              → "ok"
```

#### Usage

**One-shot diagnostic (quick check):**

```bash
python3 scripts/net_stability.py
```

**Continuous monitor mode (evidence collection):**

```bash
# Run in foreground
python3 scripts/net_stability.py --monitor

# Run in background
nohup python3 scripts/net_stability.py --monitor > /dev/null 2>&1 &

# Generate interim report without stopping monitor
kill -USR1 $(pgrep -f "net_stability.*--monitor")

# Generate report from existing logs (without running monitor)
python3 scripts/net_stability.py --report
```

**Run as systemd service (survives reboot):**

```bash
# Create service file
sudo tee /etc/systemd/system/cox-monitor.service << 'EOF'
[Unit]
Description=Cox Network Stability Monitor
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=jianrong
ExecStart=/usr/bin/python3 /home/jianrong/code/claude/miscellaneous/scripts/net_stability.py --monitor
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now cox-monitor
```

#### Configuration

Edit the constants at the top of the script:

```python
GATEWAY = "10.0.0.1"            # Your Cox router IP
INTERFACES = {
    "ethernet": "enp0s31f6",
    "wifi": "wlp0s20f3",
}
POLL_INTERVAL_OK = 60           # Seconds between tests (normal)
POLL_INTERVAL_OUTAGE = 10       # Seconds between tests (during outage)
SPEED_TEST_INTERVAL = 300       # Speed test every 5 minutes
COX_SLA_UPTIME = 99.9           # Cox advertised SLA
```

Find your interface names: `ip -br link show`

#### Example Output (One-shot)

```
════════════════════════════════════════════════════════════════
  Cox Network Stability Checker (one-shot)
  Gateway: 10.0.0.1
════════════════════════════════════════════════════════════════

  ┌─ ETHERNET (enp0s31f6) — UP
  │  IP: 10.0.0.211
  │  Gateway:   1.6ms (OK)
  │  Internet:  avg=17.9ms  jitter=3.9ms  loss=0.0%
  │  DNS:       avg=36ms  failures=0/3
  │  Speed:     2.73 Mbps
  │  Fault:     No issues
  └─ Grade: A (100/100)

  ┌─ WIFI (wlp0s20f3) — UP
  │  IP: 10.0.0.188
  │  Gateway:   14.1ms (OK)
  │  Internet:  avg=27.5ms  jitter=5.7ms  loss=0.0%
  │  DNS:       avg=37ms  failures=0/3
  │  Speed:     2.00 Mbps
  │  Fault:     No issues
  └─ Grade: A (100/100)
```

#### Example Output (Monitor Mode)

```
  [08:30:01] ethernet:OK 18ms | wifi:OK 25ms | uptime=99.85%
  [08:31:01] ethernet:OK 17ms | wifi:OK 24ms | uptime=99.85%
  [08:32:01] !! OUTAGE STARTED — Fault: ISP (Cox)
             Gateway reachable: Yes
             Internet: DOWN on all interfaces
  [08:32:11] !! OUTAGE ONGOING — 10s — Fault: ISP (Cox)
  [08:32:21] !! OUTAGE ONGOING — 20s — Fault: ISP (Cox)
  [08:33:01] ✓ OUTAGE ENDED — duration: 60s
  [08:34:01] ethernet:OK 19ms | wifi:OK 26ms | uptime=99.80%
```

#### Generated Report (for Cox Complaint)

The tool generates `~/cox-network-logs/cox_complaint_report.md` containing:

- Monitoring period and methodology
- Uptime percentage vs Cox SLA (99.9%)
- Complete outage log with timestamps and durations
- Proof that fault was ISP-side (gateway reachable, internet dead, both interfaces)
- Speed test results
- Formal request for service credit

#### Log Files

```
~/cox-network-logs/
├── monitor.jsonl           # Every test sample (JSONL)
├── outages.jsonl           # Detected outages with duration
└── cox_complaint_report.md # Generated complaint report
```

#### Use Cases

1. **Cox outage evidence**: Run continuously to document SLA violations
2. **Fault isolation**: Quickly determine if issue is your equipment or Cox
3. **Service credit claims**: Generate formal report with timestamps
4. **Technician visits**: Prove to Cox tech that outages are real and recurring
5. **Pre-meeting check**: One-shot mode before important video calls

#### Requirements

- Linux with `ip`, `ping`, `dig`, `curl` commands
- Both WiFi and Ethernet interfaces configured
- No root required (uses standard ICMP ping)

---

### Web GUI Factory-Reset Test (Issue #451)

**Directory:** [`web_gui_factory_reset_test/`](web_gui_factory_reset_test/) — Full tool + root-cause writeup (see `web_gui_factory_reset_test/README.md` for details)

**Purpose:** Reproduce and diagnose the intermittent failure where the DUT web GUI becomes unreachable ("Connection Refused") after repeated factory resets, while the device still responds to ping.

**Related Issue:** [linksys/LinksysWRT#451](https://github.com/linksys/LinksysWRT/issues/451) — [M60PW] Sometimes web GUI is not accessible after DUT is reset to default

#### Description

With the LAN cable kept connected and **no power cycle**, the tool repeatedly triggers a JNAP `core/FactoryReset` and, after each reboot, verifies both ping and the web UI (`:443`/`:80`). Typically around the 4th–5th consecutive reset the web UI is refused while ping still works. On failure the tool SSHes in and captures the smoking-gun state.

#### Root Cause (confirmed against `pinnacle/develop`)

`lighttpd` (the web server) is **not enabled at boot** — there is no `rc.d` `S*` symlink. Its only start trigger is the one-shot LAN-ifup hotplug `/etc/hotplug.d/iface/50-lighttpd`. If that single start is missed/fails on a boot, nothing re-triggers it until the next LAN ifup — which only a power cycle provides. Ping keeps working because ICMP is kernel-side. `curl`/JNAP cannot self-recover (they all talk to the dead lighttpd).

**Proper fix:** enable lighttpd at boot (ship the `rc.d` enable symlink) and/or make `50-lighttpd` idempotent with a retry independent of a single ifup event.

#### What It Does

1. Baseline: confirm ping + web are up.
2. Trigger JNAP `core/FactoryReset` (adaptive auth: master pw / `admin` / no-auth across https+http; SSH `jffs2reset` fallback).
3. Wait for reboot and pingability.
4. SSH-gate on Auto_Master completion (so "web loads properly" is judged fairly).
5. Verify ping + web; log lighttpd process/socket state every iteration.
6. Repeat **without power cycle** until web fails or N iterations pass.

On web-refused it captures `logs/diag_*.txt` (lighttpd status, process list, listening sockets, config validation, missing `error.log`, absent boot symlink, hotplug logread); with `--recover` it runs `/etc/init.d/lighttpd start` to confirm the web comes straight back.

#### Usage

```bash
cd web_gui_factory_reset_test

# 15 resets, SSH diagnostics + recovery on failure.
# -p sets BOTH the SSH login password and the JNAP basic-auth password.
./reset_web_test.sh -i 192.168.1.1 -p '8xPghzqdr@' -n 15 --recover
```

| Option | Meaning | Default |
|--------|---------|---------|
| `-i IP` | DUT IP | `192.168.1.1` |
| `-p PASS` | SSH + JNAP master password | `8xPghzqdr@` |
| `-P PASS` | JNAP password only (override `-p`) | — |
| `-u USER` | SSH user | `root` |
| `-n N` | iterations | `15` |
| `-w SECONDS` | max boot wait | `180` |
| `-t SECONDS` | web reach timeout after ping | `90` |
| `-a SECONDS` | max Auto_Master completion wait | `240` |
| `--recover` | on failure, `/etc/init.d/lighttpd start` to confirm recovery | off |
| `--no-ssh` | skip SSH gating/diagnostics (repro only) | off |
| `--no-wan` | factory Born-On SOP: WAN unplugged, no Auto_Master, pw stays `admin` | off |
| `--factory-cgi` | also require `/factory.cgi` Born-On status == `Idle` after each reset | off |
| `--factory-flow` | aggressive timing: next reset on first ping (implies the two above) | off |
| `--grace N` | seconds after ping before the factory checks | `10` |
| `--jason-flow` | the reporter's own documented sequence, verbatim | off |
| `--iface IF` | bind pings + curl to this interface (reporter ran the loop over Wi-Fi) | default route |
| `--ssid SSID` | SSID to reconnect to on a ping timeout (doc 4.5 retry path) | — |
| `--extra-pass P` | add another per-unit `default_passphrase` candidate | `Da8@Wfqes4` |

#### No-WAN mode (factory Born-On validation SOP)

The reporter's scenario is the **Industrial Cloud / Born-On Date factory validation SOP**, not normal end-user use: the line connects WAN for cloud validation, then **removes the WAN cable**, factory-resets, and re-checks `factory.cgi` for `Idle`.

With WAN unplugged, **Auto_Master never runs** — the unit stays unconfigured (`smart_mode.mode=0`) and the web/admin password stays **`admin`** permanently. `--no-wan` skips the Auto_Master gate and tries `admin`/no-auth credentials first. `--factory-cgi` additionally asserts the Born-On status reads `Idle` after each reset (this also exercises lighttpd's CGI handler, a stronger check than a bare socket probe).

```bash
./reset_web_test.sh -i 192.168.1.1 -p admin -n 15 --no-wan --factory-cgi --recover
```

#### `--jason-flow` — the reporter's exact stress test

The reporter could not release the C++ source (internal test framework) but supplied a command/sequence reference, kept at [`web_gui_factory_reset_test/reference/FactoryResetConnectionStressTest.txt`](web_gui_factory_reset_test/reference/FactoryResetConnectionStressTest.txt). `--jason-flow` implements it verbatim so results are comparable 1:1 (implies `--no-wan` + `--factory-cgi`):

reset via `POST http://IP/JNAP/` (**plain :80**, `--connect-timeout 5 --max-time 20`) → require **both** `"result": "OK"` **and** `DeviceRestart` → confirm unreachable (**2 failed pings**, 90 s) → wait **20 s** → wait pingable (**3 good pings**; on timeout reconnect Wi-Fi + retry 60 s) → wait **10 s**, no Auto_Master check → `GET https://IP/factory.cgi` with `Authorization: Basic` (`--connect-timeout 5 --max-time 15`) → judge the **curl exit code only** → wait **10 s** → next cycle.

Key differences this closed versus our own `--factory-flow`:

- **Traffic path** — the reporter's PC had **both** wired and Wi-Fi connected; connectivity was pre-checked on wired, but the stress loop ran over **Wi-Fi**. A Wi-Fi client re-associates after every reset, so its first ping arrives later and by a different path. `--iface`/`--ssid` match that.
- HTTP (:80) rather than HTTPS for the reset; `DeviceRestart` also required.
- Explicit 2-failed-ping disconnect confirmation and a **20 s** post-disconnect wait (we had neither).
- **3** successful pings before proceeding, not one.
- `factory.cgi` judged by exit code only — a reachable CGI with an unexpected body passes for them.

```bash
nmcli device wifi connect Linksys00002 password '<passphrase>' ifname wlp0s20f3

./reset_web_test.sh -i 192.168.1.1 -p '<passphrase>' -n 20 --jason-flow \
    --iface wlp0s20f3 --ssid Linksys00002 --no-ssh
```

**Firmware note:** the reporter reproduced on **M60PW-HK fw 1.0.18.26042406**; our units run **1.2.3.26072311**. That difference is unresolved and should accompany any result.

Exit code `1` = bug reproduced (or DUT unreachable); `0` = all N resets recovered.

#### Requirements

- `sshpass`, `curl`, `ping` on the host
- SSH + JNAP access to the DUT

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
│   ├── strip-sensitive-config.example.json # Example config for strip-sensitive
│   └── net_stability.py                   # Network stability checker (WiFi vs Ethernet)
├── nowtv_multicast_test/                  # NowTV IGMP proxy multicast IPTV test suite
│   ├── run_tests.sh                      # 12 automated test cases (20 assertions)
│   ├── mcast_stb_sim.py                  # STB simulator (join/leave/switch/stress)
│   ├── mcast_source.py                   # Multicast UDP source (Linux/Windows)
│   ├── windows/mcast_source.py           # Windows-specific source with --bind
│   └── README.md                         # Detailed usage documentation
├── miniupnpd_cve_2021_27137/              # CVE-2021-27137 test suite (verify + exploit + on-device)
├── dnsmasq_cve_2026/                     # CVE-2026 dnsmasq vulnerability test suite
│   ├── dnsmasq_cve_tester.py            # Main test tool (network + static analysis)
│   └── README.md                         # Detailed usage documentation
├── web_gui_factory_reset_test/            # Issue #451 web-GUI-after-factory-reset repro/diagnosis
│   ├── reset_web_test.sh                 # Reset loop + ping/web verify + lighttpd diagnostics
│   └── README.md                         # Root-cause writeup + usage
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
