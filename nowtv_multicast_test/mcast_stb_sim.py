#!/usr/bin/env python3
"""
NowTV STB Multicast Simulator — simulates STB IGMP join/leave behavior.
Run on Ubuntu PCs connected to LAN ports of the DUT (Pinnacle 2.0).

Usage:
  # Simulate STB joining a channel and receiving multicast:
  sudo python3 mcast_stb_sim.py join 239.1.1.1 5004

  # Simulate STB leaving:
  sudo python3 mcast_stb_sim.py leave 239.1.1.1

  # Simulate STB channel switch (leave old, join new):
  sudo python3 mcast_stb_sim.py switch 239.1.1.1 239.1.1.2 5004

  # Run multiple STBs on same PC (different groups):
  sudo python3 mcast_stb_sim.py multi 239.1.1.1 239.1.1.2 239.1.1.3

Requires: root (for raw sockets)
"""

import socket
import struct
import sys
import time
import threading
import signal
import os

IGMP_MEMBERSHIP_REPORT_V2 = 0x16
IGMP_LEAVE_GROUP_V2 = 0x17
IGMP_ALL_ROUTERS = "224.0.0.2"

running = True


def signal_handler(sig, frame):
    global running
    running = False
    print("\nStopping...")


signal.signal(signal.SIGINT, signal_handler)


def checksum(data):
    if len(data) % 2:
        data += b'\x00'
    s = 0
    for i in range(0, len(data), 2):
        w = (data[i] << 8) + data[i + 1]
        s += w
    s = (s >> 16) + (s & 0xffff)
    s += s >> 16
    return ~s & 0xffff


def build_igmp_report(group_ip):
    igmp_type = IGMP_MEMBERSHIP_REPORT_V2
    max_resp = 0
    group = socket.inet_aton(group_ip)
    header = struct.pack('!BBH4s', igmp_type, max_resp, 0, group)
    cs = checksum(header)
    return struct.pack('!BBH4s', igmp_type, max_resp, cs, group)


def build_igmp_leave(group_ip):
    igmp_type = IGMP_LEAVE_GROUP_V2
    max_resp = 0
    group = socket.inet_aton(group_ip)
    header = struct.pack('!BBH4s', igmp_type, max_resp, 0, group)
    cs = checksum(header)
    return struct.pack('!BBH4s', igmp_type, max_resp, cs, group)


def send_igmp_join(group_ip, iface=None):
    """Send IGMPv2 Membership Report to join a group."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_IGMP)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
        if iface:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, iface.encode())
        report = build_igmp_report(group_ip)
        sock.sendto(report, (group_ip, 0))
        sock.close()
        print(f"  [JOIN] Sent IGMPv2 Report for {group_ip}")
    except PermissionError:
        print("ERROR: Need root. Run with sudo.")
        sys.exit(1)


def send_igmp_leave(group_ip, iface=None):
    """Send IGMPv2 Leave to 224.0.0.2."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_IGMP)
        sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 1)
        if iface:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE, iface.encode())
        leave = build_igmp_leave(group_ip)
        sock.sendto(leave, (IGMP_ALL_ROUTERS, 0))
        sock.close()
        print(f"  [LEAVE] Sent IGMPv2 Leave for {group_ip}")
    except PermissionError:
        print("ERROR: Need root. Run with sudo.")
        sys.exit(1)


def join_multicast_group(group_ip, port=5004, iface=None):
    """Join multicast group via socket (triggers kernel IGMP) and receive data."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(('', port))

    mreq = struct.pack('4s4s', socket.inet_aton(group_ip), socket.inet_aton('0.0.0.0'))
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_ADD_MEMBERSHIP, mreq)
    sock.settimeout(1.0)

    print(f"  [RX] Listening on {group_ip}:{port} ...")
    pkt_count = 0
    bytes_total = 0
    start = time.time()

    while running:
        try:
            data, addr = sock.recvfrom(65535)
            pkt_count += 1
            bytes_total += len(data)
            elapsed = time.time() - start
            if pkt_count % 100 == 0:
                rate = (bytes_total * 8) / elapsed / 1_000_000
                print(f"  [RX] {group_ip}: {pkt_count} pkts, {rate:.1f} Mbps")
        except socket.timeout:
            continue

    # Leave on exit
    sock.setsockopt(socket.IPPROTO_IP, socket.IP_DROP_MEMBERSHIP, mreq)
    sock.close()
    elapsed = time.time() - start
    print(f"  [RX] {group_ip}: Total {pkt_count} pkts, {bytes_total} bytes in {elapsed:.1f}s")
    return pkt_count


def cmd_join(args):
    """Join a multicast group and receive traffic."""
    group = args[0]
    port = int(args[1]) if len(args) > 1 else 5004
    iface = args[2] if len(args) > 2 else None
    print(f"[STB] Joining {group}:{port}")
    send_igmp_join(group, iface)
    join_multicast_group(group, port, iface)


def cmd_leave(args):
    """Send IGMP leave for a group."""
    group = args[0]
    iface = args[1] if len(args) > 1 else None
    print(f"[STB] Leaving {group}")
    send_igmp_leave(group, iface)


def cmd_switch(args):
    """Channel switch: leave old group, join new group."""
    old_group = args[0]
    new_group = args[1]
    port = int(args[2]) if len(args) > 2 else 5004
    print(f"[STB] Switching {old_group} -> {new_group}")
    send_igmp_leave(old_group)
    time.sleep(0.1)
    send_igmp_join(new_group)
    join_multicast_group(new_group, port)


def cmd_multi(args):
    """Join multiple groups simultaneously (simulates multiple STBs on one PC)."""
    port = 5004
    threads = []
    for i, group in enumerate(args):
        p = port + i
        print(f"[STB-{i+1}] Joining {group}:{p}")
        send_igmp_join(group)
        t = threading.Thread(target=join_multicast_group, args=(group, p), daemon=True)
        t.start()
        threads.append((t, group))

    print(f"\n[INFO] {len(args)} STBs active. Press Ctrl+C to stop.\n")
    try:
        while running:
            time.sleep(1)
    except KeyboardInterrupt:
        pass

    for t, group in threads:
        send_igmp_leave(group)


def cmd_stress(args):
    """Rapid join/leave cycle to test fast-leave behavior."""
    group = args[0]
    cycles = int(args[1]) if len(args) > 1 else 10
    delay = float(args[2]) if len(args) > 2 else 1.0
    print(f"[STRESS] {cycles} join/leave cycles on {group}, delay={delay}s")
    for i in range(cycles):
        print(f"  Cycle {i+1}/{cycles}")
        send_igmp_join(group)
        time.sleep(delay)
        send_igmp_leave(group)
        time.sleep(delay)
    print("[STRESS] Done")


def usage():
    print("""
NowTV STB Multicast Simulator
==============================
Usage: sudo python3 mcast_stb_sim.py <command> [args...]

Commands:
  join <group> [port] [iface]       Join group and receive multicast traffic
  leave <group> [iface]             Send IGMP leave
  switch <old> <new> [port]         Channel switch (leave + join)
  multi <group1> <group2> ...       Multiple STBs (multiple groups)
  stress <group> [cycles] [delay]   Rapid join/leave stress test

Examples:
  sudo python3 mcast_stb_sim.py join 239.1.1.1 5004
  sudo python3 mcast_stb_sim.py multi 239.1.1.1 239.1.1.2 239.1.1.3
  sudo python3 mcast_stb_sim.py switch 239.1.1.1 239.1.1.2
  sudo python3 mcast_stb_sim.py stress 239.1.1.1 20 0.5
""")


if __name__ == '__main__':
    if os.geteuid() != 0:
        print("ERROR: Must run as root (sudo)")
        sys.exit(1)

    if len(sys.argv) < 2:
        usage()
        sys.exit(1)

    cmd = sys.argv[1]
    args = sys.argv[2:]

    commands = {
        'join': cmd_join,
        'leave': cmd_leave,
        'switch': cmd_switch,
        'multi': cmd_multi,
        'stress': cmd_stress,
    }

    if cmd in commands:
        commands[cmd](args)
    else:
        usage()
        sys.exit(1)
