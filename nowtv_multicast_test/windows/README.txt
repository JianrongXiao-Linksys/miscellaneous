================================================================
  NowTV Multicast IPTV Test Tool - Windows PC (WAN Side)
================================================================

This Windows PC simulates the NowTV CDN headend (multicast source).
Connect it to the DUT's WAN port.

================================================================
  SETUP
================================================================

1. Install Python 3
   - Download: https://www.python.org/downloads/
   - During install, CHECK "Add Python to PATH"
   - Verify: open cmd.exe and type: python --version

2. Network
   - Connect Ethernet cable from this PC to DUT WAN port
   - Open: Control Panel > Network > Adapter Settings
   - Right-click the WAN-connected adapter > Properties > IPv4
   - Set static IP:
       IP address:    10.192.0.100
       Subnet mask:   255.255.255.0
       Gateway:       (leave empty)
   - Note: Match DUT WAN subnet. Check DUT WAN IP with:
       ssh root@192.168.1.1 "ubus call network.interface.wan status"

3. Windows Firewall
   - If prompted, click "Allow" for Python
   - Or: Windows Security > Firewall > Allow an app > Add Python

4. Download tool
   - Option A: git clone https://github.com/JianrongXiao-Linksys/nowtv-multicast-test.git
   - Option B: Download mcast_source.py directly from GitHub

================================================================
  HOW TO RUN
================================================================

Open cmd.exe (or PowerShell), navigate to this folder:

  cd nowtv-multicast-test\windows

--- Single Channel (basic test) ---

  python mcast_source.py 239.1.1.1

--- Multiple Channels (multi-STB test) ---

  python mcast_source.py multi 239.1.1.1 239.1.1.2 239.1.1.3

--- Specify Network Adapter (if multiple adapters) ---

  python mcast_source.py 239.1.1.1 --bind 10.192.0.100

--- Higher Bitrate (simulate HD stream, 20 Mbps) ---

  python mcast_source.py 239.1.1.1 5004 20

--- Stop ---

  Press Ctrl+C

================================================================
  EXPECTED OUTPUT
================================================================

  ===================================================
   NowTV Multicast Source (Windows)
  ===================================================

  [SOURCE] Starting 239.1.1.1:5004 at 10 Mbps
    [TX] Sending to 239.1.1.1:5004 at 10 Mbps (950 pps, 1316B/pkt)
    [TX] 239.1.1.1: 1000 pkts, 10.0 Mbps
    [TX] 239.1.1.1: 2000 pkts, 10.0 Mbps
    ...

================================================================
  TEST PROCEDURE
================================================================

Step 1: Start source on THIS PC (Windows, WAN side):
        python mcast_source.py multi 239.1.1.1 239.1.1.2 239.1.1.3

Step 2: On Ubuntu PC (connected to DUT LAN port):
        sudo python3 mcast_stb_sim.py join 239.1.1.1 5004

Step 3: If Ubuntu receives packets -> IGMP proxy working!

Step 4: Run full automated test on Ubuntu:
        sudo ./run_tests.sh 192.168.1.1

================================================================
  NETWORK TOPOLOGY
================================================================

  [This Windows PC]            [DUT Pinnacle 2.0]         [Ubuntu PC]
   mcast_source.py  --ETH-->   WAN        LAN  --ETH-->  mcast_stb_sim.py
   IP: 10.192.0.100           igmpproxy                  IP: 192.168.1.x
                              (192.168.1.1)

================================================================
  TROUBLESHOOTING
================================================================

Problem: "No route to host" or "Network unreachable"
Fix:     Check cable. Check static IP is on same subnet as DUT WAN.
         Run: ipconfig    (to see your IP)

Problem: Source is running but Ubuntu PC receives nothing
Fix:     1. Windows Firewall may be blocking. Disable temporarily:
            netsh advfirewall set allprofiles state off
         2. Check DUT: ssh root@192.168.1.1
            - pidof igmpproxy  (should show a PID)
            - cat /proc/net/ip_mr_cache  (should show routes)
         3. Wrong adapter? Use --bind with correct IP:
            python mcast_source.py 239.1.1.1 --bind 10.192.0.100

Problem: "python is not recognized as an internal command"
Fix:     Python not in PATH. Reinstall with "Add to PATH" checked.
         Or use full path: C:\Users\<you>\AppData\Local\Programs\Python\Python3x\python.exe

================================================================
  WHAT THIS TESTS (Issue #334 Acceptance Criteria)
================================================================

  [x] Multicast traffic from WAN reaches subscribed LAN ports
  [x] IGMP Snooping tracks group membership per port
  [x] IGMP Fast Leave for quick channel switching
  [x] Multiple STBs view same channel simultaneously
  [x] Multiple STBs view different channels simultaneously
  [x] One STB changing channel does not interrupt other STBs
  [x] Regular PC/Tablet traffic continues via NAT

================================================================
