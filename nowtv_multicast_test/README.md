# NowTV Multicast IPTV Test Tools

Verification tools for [NowTV Multicast IPTV with Multiple STBs (Issue #334)](https://github.com/linksys/LinksysWRT/issues/334). Simulates STBs and multicast CDN to test IGMP proxy, snooping, and fast leave — **no physical STB hardware required**.

## Requirements

- **DUT**: Pinnacle 2.0 with PW customer firmware (igmpproxy enabled)
- **Windows PC**: Python 3.x — connects to DUT WAN port (multicast source)
- **Ubuntu PC**: Python 3 + SSH access to DUT — connects to DUT LAN port (STB simulator)

## Network Setup

```
[Windows PC]                  [DUT Pinnacle 2.0]               [Ubuntu PC]
 mcast_source.py  ──ETH──>    WAN        LAN    ──ETH──>   mcast_stb_sim.py
 IP: 10.0.0.100              igmpproxy                      IP: 192.168.1.x (DHCP)
```

## Quick Start

### 1. Windows PC (WAN — multicast source)

```cmd
:: Set static IP 10.0.0.100/24 on WAN-connected adapter
:: Open cmd.exe:
cd windows
python mcast_source.py multi 239.1.1.1 239.1.1.2 239.1.1.3
```

### 2. Ubuntu PC (LAN — STB simulator)

```bash
# Single STB join:
sudo python3 mcast_stb_sim.py join 239.1.1.1

# Multiple STBs (3 channels):
sudo python3 mcast_stb_sim.py multi 239.1.1.1 239.1.1.2 239.1.1.3

# Channel switch:
sudo python3 mcast_stb_sim.py switch 239.1.1.1 239.1.1.2

# Fast leave stress test:
sudo python3 mcast_stb_sim.py stress 239.1.1.1 20 0.5
```

### 3. Automated Test Suite

```bash
sudo ./run_tests.sh 192.168.1.1
```

Runs all test cases and reports PASS/FAIL.

## What It Tests

| # | Test Case | Issue #334 Criteria |
|---|-----------|---------------------|
| TC-1 | igmpproxy service running with quickleave | Service health |
| TC-2 | Kernel multicast routing active | IGMP Proxy |
| TC-3 | Bridge IGMP snooping + IGMPv2 forced | IGMP Snooping |
| TC-4 | STB joins group, receives multicast from WAN | ✅ Multicast traffic from WAN reaches subscribed LAN ports |
| TC-5 | Fast leave — route removed immediately | ✅ IGMP Fast Leave enabled |
| TC-6 | **Multi-STB: one leaves, others continue** | ✅ Multiple STBs view same channel simultaneously |
| TC-7 | Multiple different channels simultaneously | ✅ Multiple STBs view different channels simultaneously |
| TC-8 | Ubus event notification (join/leave) | Event integration |
| TC-9 | **Channel switch — other STBs uninterrupted** | ✅ One STB changing channel does not interrupt other STBs |
| TC-10 | Per-port IGMP snooping (bridge MDB) | ✅ IGMP Snooping tracks group membership per port |
| TC-11 | Fast leave timing < 2 seconds | ✅ IGMP Fast Leave for quick channel switching |
| TC-12 | NAT coexistence — regular traffic works | ✅ Regular PC/Tablet traffic continues via NAT |

## DUT Verification (SSH)

```bash
ssh root@192.168.1.1

# Is igmpproxy running?
pidof igmpproxy && cat /var/etc/igmpproxy.conf

# Active multicast routes:
cat /proc/net/ip_mr_cache

# IGMP snooping status:
cat /sys/devices/virtual/net/br-lan/bridge/multicast_snooping

# Watch IGMP in real-time:
tcpdump -i br-lan -n igmp

# Bridge multicast database (per-port):
bridge mdb show

# Listen for client events:
ubus listen igmp.client
```

## Pass Criteria (Issue #334 Acceptance Criteria)

| # | Acceptance Criteria | Test Case | How Verified |
|---|---|---|---|
| 1 | PPPoE frames (0x8863, 0x8864) from LAN bridged to WAN | — | *Task B (PPPoE passthrough) — not IGMP scope* |
| 2 | Multicast traffic from WAN reaches subscribed LAN ports | TC-4 | STB receives packets, `tcpdump` confirms |
| 3 | IGMP Snooping correctly tracks group membership per port | TC-10 | `bridge mdb show` has port-specific entry |
| 4 | IGMP Fast Leave enabled for quick channel switching | TC-5, TC-11 | Route removed < 2 seconds after leave |
| 5 | Multiple STBs can view same channel simultaneously | TC-6 | Two STBs joined, one leaves, route persists |
| 6 | Multiple STBs can view different channels simultaneously | TC-7 | 3 routes in `ip_mr_cache` simultaneously |
| 7 | One STB changing channel does not interrupt other STBs | TC-9 | STB-A switches, STB-B's route still active |
| 8 | Regular PC/Tablet traffic continues to work via NAT | TC-12 | `ping 8.8.8.8` works during multicast |
