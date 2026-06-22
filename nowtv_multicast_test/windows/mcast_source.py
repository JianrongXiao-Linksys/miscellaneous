#!/usr/bin/env python3
"""
Multicast Source for Windows — simulates NowTV CDN headend.
Run on Windows PC connected to WAN port of DUT.

Requirements:
  - Python 3.x installed (https://python.org)
  - PC connected to DUT WAN port
  - PC configured with static IP on same subnet as DUT WAN (e.g., 10.0.0.100/24)
    OR DHCP if DUT WAN is DHCP client to this PC

Usage (in cmd.exe or PowerShell):
  python mcast_source.py 239.1.1.1
  python mcast_source.py 239.1.1.1 5004 10
  python mcast_source.py multi 239.1.1.1 239.1.1.2 239.1.1.3

Note: No admin/elevated privileges needed for sending multicast.
      Windows Firewall may need an exception for Python.
"""

import socket
import struct
import sys
import time
import threading
import signal
import os

running = True


def signal_handler(sig, frame):
    global running
    running = False
    print("\nStopping...")


signal.signal(signal.SIGINT, signal_handler)


def send_multicast_stream(group_ip, port=5004, bitrate_mbps=10, pkt_size=1316, ttl=10, bind_ip=''):
    """Send UDP multicast stream at specified bitrate."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, ttl)
    if bind_ip:
        sock.bind((bind_ip, 0))
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_IF,
                        socket.inet_aton(bind_ip))
    else:
        sock.bind(('0.0.0.0', 0))

    bits_per_pkt = pkt_size * 8
    pkts_per_sec = (bitrate_mbps * 1_000_000) / bits_per_pkt
    delay = 1.0 / pkts_per_sec

    payload = os.urandom(pkt_size)

    # Pre-resolve destination to avoid getaddrinfo on every send
    dest = (group_ip, port)
    try:
        socket.inet_aton(group_ip)
    except socket.error:
        print(f"  [TX] ERROR: Invalid multicast address: {group_ip}")
        sock.close()
        return

    print(f"  [TX] Sending to {group_ip}:{port} at {bitrate_mbps} Mbps "
          f"({pkts_per_sec:.0f} pps, {pkt_size}B/pkt)")
    if bind_ip:
        print(f"  [TX] Bound to interface {bind_ip}")

    pkt_count = 0
    start = time.time()

    while running:
        try:
            sock.sendto(payload, dest)
            pkt_count += 1
            if pkt_count % 1000 == 0:
                elapsed = time.time() - start
                actual_rate = (pkt_count * pkt_size * 8) / elapsed / 1_000_000
                print(f"  [TX] {group_ip}: {pkt_count} pkts, {actual_rate:.1f} Mbps")
            time.sleep(delay)
        except OSError as e:
            if 'getaddrinfo' in str(e) or '11001' in str(e):
                print(f"\n  [TX] ERROR: Network adapter has no IP address!")
                print(f"  Fix: Check your adapter has an IP (run: ipconfig)")
                print(f"  Then use: python mcast_source.py {group_ip} --bind <YOUR_IP>")
                sock.close()
                return
            print(f"  [TX] Error: {e}")
            time.sleep(1)

    sock.close()
    elapsed = time.time() - start
    print(f"  [TX] {group_ip}: Sent {pkt_count} pkts in {elapsed:.1f}s")


def cmd_multi(args, bind_ip=''):
    """Send multiple multicast streams."""
    bitrate = 10
    threads = []
    for i, group in enumerate(args):
        port = 5004 + i
        print(f"[CH-{i+1}] {group}:{port} at {bitrate} Mbps")
        t = threading.Thread(
            target=send_multicast_stream,
            args=(group, port, bitrate, 1316, 10, bind_ip),
            daemon=True
        )
        t.start()
        threads.append(t)
        time.sleep(0.1)

    print(f"\n[SOURCE] {len(args)} channels active. Press Ctrl+C to stop.\n")
    try:
        while running:
            time.sleep(1)
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    print("=" * 50)
    print(" NowTV Multicast Source (Windows)")
    print("=" * 50)
    print()

    if len(sys.argv) < 2:
        print("Usage:")
        print("  python mcast_source.py <group> [port] [bitrate_mbps] [--bind IP]")
        print("  python mcast_source.py multi <group1> <group2> ... [--bind IP]")
        print()
        print("Examples:")
        print("  python mcast_source.py 239.1.1.1")
        print("  python mcast_source.py 239.1.1.1 5004 20")
        print("  python mcast_source.py multi 239.1.1.1 239.1.1.2 239.1.1.3")
        print("  python mcast_source.py 239.1.1.1 --bind 10.0.0.100")
        print()
        print("If you have multiple network adapters, use --bind to select")
        print("the adapter connected to DUT WAN port.")
        sys.exit(1)

    # Parse --bind option
    bind_ip = ''
    args = sys.argv[1:]
    if '--bind' in args:
        idx = args.index('--bind')
        bind_ip = args[idx + 1]
        args = args[:idx] + args[idx+2:]

    if args[0] == 'multi':
        cmd_multi(args[1:], bind_ip)
    else:
        group = args[0]
        port = int(args[1]) if len(args) > 1 else 5004
        bitrate = float(args[2]) if len(args) > 2 else 10
        print(f"[SOURCE] Starting {group}:{port} at {bitrate} Mbps")
        send_multicast_stream(group, port, bitrate, bind_ip=bind_ip)
