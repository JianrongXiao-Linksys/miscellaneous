#!/usr/bin/env python3
"""Network Stability Checker — tests WiFi and Ethernet connections."""

import subprocess
import time
import statistics
import json
import sys
from datetime import datetime
from dataclasses import dataclass, field, asdict
from typing import Optional

PING_TARGETS = ["8.8.8.8", "1.1.1.1", "208.67.222.222"]
PING_COUNT = 20
JITTER_WINDOW = 10
DNS_TARGETS = ["google.com", "cloudflare.com", "github.com"]
DOWNLOAD_URL = "http://speedtest.tele2.net/1MB.zip"

INTERFACES = {
    "ethernet": "enp0s31f6",
    "wifi": "wlp0s20f3",
}


@dataclass
class InterfaceResult:
    name: str
    interface: str
    link_up: bool = False
    ip_address: Optional[str] = None
    gateway: Optional[str] = None
    ping_loss_pct: float = 100.0
    ping_avg_ms: float = 0.0
    ping_min_ms: float = 0.0
    ping_max_ms: float = 0.0
    jitter_ms: float = 0.0
    dns_avg_ms: float = 0.0
    dns_failures: int = 0
    download_speed_mbps: float = 0.0
    stability_score: float = 0.0
    grade: str = "F"
    issues: list = field(default_factory=list)


def run(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout, r.returncode
    except subprocess.TimeoutExpired:
        return "", 1


def check_link(iface):
    out, _ = run(["ip", "-br", "addr", "show", iface])
    if not out.strip():
        return False, None, None
    parts = out.split()
    link_up = parts[1] == "UP" if len(parts) > 1 else False
    ip_addr = None
    for p in parts[2:]:
        if "/" in p and not p.startswith("fe80"):
            ip_addr = p.split("/")[0]
            break
    gw_out, _ = run(["ip", "route", "show", "default", "dev", iface])
    gateway = None
    if "via" in gw_out:
        gateway = gw_out.split("via")[1].strip().split()[0]
    return link_up, ip_addr, gateway


def ping_test(iface, target, count):
    out, rc = run(
        ["ping", "-I", iface, "-c", str(count), "-W", "2", "-i", "0.3", target],
        timeout=count * 2 + 10,
    )
    rtts = []
    loss = 100.0
    for line in out.splitlines():
        if "time=" in line:
            try:
                t = float(line.split("time=")[1].split()[0])
                rtts.append(t)
            except (ValueError, IndexError):
                pass
        if "packet loss" in line:
            try:
                loss = float(line.split("%")[0].split()[-1])
            except (ValueError, IndexError):
                pass
    return rtts, loss


def dns_test(iface, targets):
    times = []
    failures = 0
    ip_out, _ = run(["ip", "-4", "addr", "show", iface])
    src_ip = None
    for line in ip_out.splitlines():
        if "inet " in line:
            src_ip = line.strip().split()[1].split("/")[0]
            break
    for target in targets:
        start = time.time()
        cmd = ["dig", "+short", "+time=3", "+tries=1", target, "@8.8.8.8"]
        if src_ip:
            cmd.extend(["-b", src_ip])
        out, rc = run(cmd, timeout=5)
        elapsed = (time.time() - start) * 1000
        if rc != 0 or not out.strip():
            failures += 1
        else:
            times.append(elapsed)
    return times, failures


def download_test(iface):
    ip_out, _ = run(["ip", "-4", "addr", "show", iface])
    src_ip = None
    for line in ip_out.splitlines():
        if "inet " in line:
            src_ip = line.strip().split()[1].split("/")[0]
            break
    cmd = ["curl", "-o", "/dev/null", "-s", "-w", "%{speed_download}",
           "--max-time", "10", "--interface", iface, DOWNLOAD_URL]
    out, rc = run(cmd, timeout=15)
    if rc == 0 and out.strip():
        try:
            speed_bps = float(out.strip())
            return (speed_bps * 8) / 1_000_000
        except ValueError:
            pass
    return 0.0


def calculate_jitter(rtts):
    if len(rtts) < 2:
        return 0.0
    diffs = [abs(rtts[i] - rtts[i - 1]) for i in range(1, len(rtts))]
    return statistics.mean(diffs)


def calculate_score(result: InterfaceResult) -> float:
    if not result.link_up or not result.ip_address:
        return 0.0
    score = 100.0
    # Packet loss penalty (heavy)
    score -= result.ping_loss_pct * 2.5
    # Latency penalty
    if result.ping_avg_ms > 100:
        score -= min(20, (result.ping_avg_ms - 100) * 0.2)
    elif result.ping_avg_ms > 50:
        score -= (result.ping_avg_ms - 50) * 0.1
    # Jitter penalty
    if result.jitter_ms > 20:
        score -= min(15, (result.jitter_ms - 20) * 0.5)
    elif result.jitter_ms > 5:
        score -= (result.jitter_ms - 5) * 0.2
    # DNS penalty
    score -= result.dns_failures * 5
    if result.dns_avg_ms > 200:
        score -= min(10, (result.dns_avg_ms - 200) * 0.05)
    # Speed bonus/penalty
    if result.download_speed_mbps < 1:
        score -= 10
    return max(0.0, min(100.0, score))


def grade_from_score(score):
    if score >= 90:
        return "A"
    elif score >= 75:
        return "B"
    elif score >= 60:
        return "C"
    elif score >= 40:
        return "D"
    return "F"


def identify_issues(result: InterfaceResult):
    issues = []
    if not result.link_up:
        issues.append("Link is DOWN")
    elif not result.ip_address:
        issues.append("No IP address assigned")
    if result.ping_loss_pct > 5:
        issues.append(f"High packet loss: {result.ping_loss_pct:.1f}%")
    if result.ping_avg_ms > 100:
        issues.append(f"High latency: {result.ping_avg_ms:.1f}ms")
    if result.jitter_ms > 20:
        issues.append(f"High jitter: {result.jitter_ms:.1f}ms")
    if result.dns_failures > 0:
        issues.append(f"DNS failures: {result.dns_failures}/{len(DNS_TARGETS)}")
    if result.download_speed_mbps < 1 and result.link_up:
        issues.append(f"Very low throughput: {result.download_speed_mbps:.2f} Mbps")
    return issues


def test_interface(name, iface):
    print(f"\n{'─' * 50}")
    print(f"  Testing: {name} ({iface})")
    print(f"{'─' * 50}")
    result = InterfaceResult(name=name, interface=iface)

    # Link check
    print("  [1/5] Checking link status...", end=" ", flush=True)
    result.link_up, result.ip_address, result.gateway = check_link(iface)
    if not result.link_up:
        print("DOWN")
        result.issues = identify_issues(result)
        return result
    print(f"UP — {result.ip_address} via {result.gateway}")

    # Ping test
    print(f"  [2/5] Ping test ({PING_COUNT} packets × {len(PING_TARGETS)} targets)...",
          end=" ", flush=True)
    all_rtts = []
    all_loss = []
    for target in PING_TARGETS:
        rtts, loss = ping_test(iface, target, PING_COUNT)
        all_rtts.extend(rtts)
        all_loss.append(loss)
    if all_rtts:
        result.ping_avg_ms = statistics.mean(all_rtts)
        result.ping_min_ms = min(all_rtts)
        result.ping_max_ms = max(all_rtts)
        result.jitter_ms = calculate_jitter(all_rtts)
    result.ping_loss_pct = statistics.mean(all_loss) if all_loss else 100.0
    print(f"avg={result.ping_avg_ms:.1f}ms loss={result.ping_loss_pct:.1f}%")

    # DNS test
    print(f"  [3/5] DNS resolution test...", end=" ", flush=True)
    dns_times, result.dns_failures = dns_test(iface, DNS_TARGETS)
    result.dns_avg_ms = statistics.mean(dns_times) if dns_times else 0.0
    print(f"avg={result.dns_avg_ms:.0f}ms failures={result.dns_failures}")

    # Download test
    print(f"  [4/5] Download speed test...", end=" ", flush=True)
    result.download_speed_mbps = download_test(iface)
    print(f"{result.download_speed_mbps:.2f} Mbps")

    # Score
    print(f"  [5/5] Calculating stability score...", end=" ", flush=True)
    result.stability_score = calculate_score(result)
    result.grade = grade_from_score(result.stability_score)
    result.issues = identify_issues(result)
    print(f"{result.stability_score:.0f}/100 (Grade: {result.grade})")

    return result


def print_report(results):
    print(f"\n{'═' * 60}")
    print(f"  NETWORK STABILITY REPORT — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"{'═' * 60}\n")

    for r in results:
        status = "UP" if r.link_up else "DOWN"
        print(f"  ┌─ {r.name.upper()} ({r.interface}) — {status}")
        if not r.link_up:
            print(f"  │  ⚠ Interface is down, skipped tests")
            print(f"  └─ Grade: F (0/100)\n")
            continue
        print(f"  │  IP: {r.ip_address}  Gateway: {r.gateway}")
        print(f"  │")
        print(f"  │  Latency:    avg={r.ping_avg_ms:.1f}ms  "
              f"min={r.ping_min_ms:.1f}ms  max={r.ping_max_ms:.1f}ms")
        print(f"  │  Jitter:     {r.jitter_ms:.1f}ms")
        print(f"  │  Pkt Loss:   {r.ping_loss_pct:.1f}%")
        print(f"  │  DNS:        avg={r.dns_avg_ms:.0f}ms  "
              f"failures={r.dns_failures}/{len(DNS_TARGETS)}")
        print(f"  │  Throughput:  {r.download_speed_mbps:.2f} Mbps")
        print(f"  │")
        if r.issues:
            print(f"  │  Issues:")
            for issue in r.issues:
                print(f"  │    ⚠ {issue}")
            print(f"  │")
        print(f"  └─ Grade: {r.grade} ({r.stability_score:.0f}/100)\n")

    # Comparison
    up_results = [r for r in results if r.link_up and r.ip_address]
    if len(up_results) >= 2:
        best = max(up_results, key=lambda r: r.stability_score)
        print(f"  ★ Recommended: {best.name} — "
              f"score {best.stability_score:.0f}/100, "
              f"avg latency {best.ping_avg_ms:.1f}ms, "
              f"loss {best.ping_loss_pct:.1f}%")

    print(f"\n{'═' * 60}")


def save_json(results, path="report.json"):
    data = {
        "timestamp": datetime.now().isoformat(),
        "results": [asdict(r) for r in results],
    }
    with open(path, "w") as f:
        json.dump(data, f, indent=2)
    print(f"\n  JSON report saved to: {path}")


def main():
    print(f"\n{'═' * 60}")
    print("  Network Stability Checker")
    print(f"  Metrics: latency, jitter, packet loss, DNS, throughput")
    print(f"{'═' * 60}")

    results = []
    for name, iface in INTERFACES.items():
        results.append(test_interface(name, iface))

    print_report(results)
    save_json(results)


if __name__ == "__main__":
    main()
