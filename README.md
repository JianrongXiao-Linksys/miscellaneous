# Miscellaneous Tools

A collection of utility scripts and tools for network device management, monitoring, and automation tasks at Linksys.

## Table of Contents

- [Overview](#overview)
- [Tools](#tools)
  - [WiFi Client Monitor](#wifi-client-monitor)
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

### WiFi Client Monitor

**Script:** `scripts/monitor_wifi_clients.sh`

**Purpose:** Monitors WiFi client associations on a wireless interface and logs state changes (clients connecting/disconnecting) to a file.

#### Description

This script continuously monitors the `ath10` wireless interface on Qualcomm/Atheros-based routers and access points. It detects when clients associate or disassociate from the network and creates detailed log entries capturing the full station list at each state transition.

#### Features

- Real-time monitoring with configurable polling interval (default: 30 seconds)
- State change detection (associated → disassociated and vice versa)
- Timestamped log entries with full `wlanconfig` output
- Lightweight shell script compatible with BusyBox environments
- Console feedback for monitoring status

#### Technical Details

| Aspect | Details |
|--------|---------|
| **Language** | POSIX Shell (sh) |
| **Target Platform** | OpenWrt / QCA-based routers |
| **Interface Tool** | `wlanconfig` (Qualcomm Atheros wireless driver utility) |
| **Log Location** | `/tmp/clients.log` |
| **Default Interface** | `ath10` (5GHz radio) |
| **Polling Interval** | 30 seconds |

#### How It Works

1. **Initialization**: The script starts with an unknown previous state (`-1`)
2. **Client Detection**: Uses `wlanconfig <interface> list sta` to retrieve the station list
3. **Parsing**: Counts lines matching MAC address patterns (format: `xx:xx:xx:xx:xx:xx`)
4. **State Comparison**: Compares current client count with previous state
5. **Logging**: On state change, logs full station output with timestamp
6. **Loop**: Sleeps for the configured interval and repeats

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

**To monitor a different interface:**

```bash
# For 2.4GHz radio (commonly ath0 or ath1)
INTERFACE="ath0"

# For 6GHz radio (if available)
INTERFACE="ath20"
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

## Project Structure

```
miscellaneous/
├── README.md              # This file
├── scripts/
│   └── monitor_wifi_clients.sh   # WiFi client monitoring script
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
