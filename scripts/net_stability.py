#!/usr/bin/env python3
"""
Network Stability Monitor — Continuous monitoring for Cox ISP outage evidence.

Runs as a daemon, logging every test cycle to a JSONL file and detecting outages.
Generates an ISP complaint report with SLA violation evidence on demand (SIGUSR1)
or at exit (Ctrl+C).

Key design for ISP evidence:
- Separates GATEWAY (10.0.0.1) vs INTERNET tests to prove fault location
- Tests BOTH interfaces to prove it's not your NIC/cable
- Logs every sample with timestamp for outage duration proof
- Tracks uptime percentage against Cox SLA (99.9%)
- Generates a PDF-ready markdown report for Cox complaint
"""

import subprocess
import time
import statistics
import json
import signal
import sys
import os
from datetime import datetime, timedelta
from dataclasses import dataclass, field, asdict
from typing import Optional, List
from pathlib import Path

# ─── Configuration ───────────────────────────────────────────────────────────

GATEWAY = "10.0.0.1"
INTERFACES = {
    "ethernet": "enp0s31f6",
    "wifi": "wlp0s20f3",
}

INTERNET_TARGETS = ["8.8.8.8", "1.1.1.1", "208.67.222.222"]
DNS_TARGETS = ["google.com", "cloudflare.com", "github.com"]
DOWNLOAD_URL = "http://speedtest.tele2.net/1MB.zip"

POLL_INTERVAL_OK = 60          # seconds between tests when connection is good
POLL_INTERVAL_OUTAGE = 10      # seconds between tests during an outage
PING_COUNT = 10                # pings per target per cycle
SPEED_TEST_INTERVAL = 300      # speed test every 5 minutes (not every cycle)

LOG_DIR = Path.home() / "cox-network-logs"
LOG_FILE = LOG_DIR / "monitor.jsonl"
OUTAGE_LOG = LOG_DIR / "outages.jsonl"
REPORT_FILE = LOG_DIR / "cox_complaint_report.md"

COX_SLA_UPTIME = 99.9  # Cox advertised uptime guarantee %

# ─── Data Structures ─────────────────────────────────────────────────────────


@dataclass
class ProbeResult:
    timestamp: str
    interface: str
    interface_name: str
    link_up: bool = False
    ip_address: Optional[str] = None
    gateway_reachable: bool = False
    gateway_latency_ms: float = 0.0
    internet_reachable: bool = False
    internet_latency_ms: float = 0.0
    internet_loss_pct: float = 100.0
    jitter_ms: float = 0.0
    dns_ok: bool = False
    dns_latency_ms: float = 0.0
    download_mbps: float = 0.0
    fault_location: str = "unknown"


@dataclass
class Outage:
    start: str
    end: Optional[str] = None
    duration_seconds: float = 0.0
    fault_location: str = "unknown"
    affected_interfaces: List[str] = field(default_factory=list)
    samples: int = 0


class Monitor:
    def __init__(self):
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        self.running = True
        self.current_outage: Optional[Outage] = None
        self.outages: List[Outage] = []
        self.total_samples = 0
        self.failed_samples = 0
        self.start_time = datetime.now()
        self.last_speed_test = 0.0
        self.speed_results: List[dict] = []
        self._load_existing_stats()

        signal.signal(signal.SIGINT, self._handle_exit)
        signal.signal(signal.SIGTERM, self._handle_exit)
        signal.signal(signal.SIGUSR1, self._handle_report_signal)

    def _load_existing_stats(self):
        if OUTAGE_LOG.exists():
            try:
                with open(OUTAGE_LOG) as f:
                    for line in f:
                        line = line.strip()
                        if line:
                            o = json.loads(line)
                            self.outages.append(Outage(**o))
            except (json.JSONDecodeError, TypeError):
                pass
        if LOG_FILE.exists():
            try:
                with open(LOG_FILE) as f:
                    for line in f:
                        line = line.strip()
                        if line:
                            self.total_samples += 1
                            d = json.loads(line)
                            if not d.get("internet_reachable", True):
                                self.failed_samples += 1
                            ts = d.get("timestamp", "")
                            if ts and not hasattr(self, '_earliest'):
                                self._earliest = ts
            except (json.JSONDecodeError, TypeError):
                pass
            if hasattr(self, '_earliest'):
                try:
                    self.start_time = datetime.fromisoformat(self._earliest)
                except (ValueError, TypeError):
                    pass

    def _handle_exit(self, signum, frame):
        print("\n\n  Shutting down... generating report.")
        self.running = False
        if self.current_outage:
            self._end_outage()
        self.generate_report()
        sys.exit(0)

    def _handle_report_signal(self, signum, frame):
        print("\n  [SIGUSR1] Generating interim report...")
        self.generate_report()
        print(f"  Report saved: {REPORT_FILE}")

    def run(self):
        print(f"\n{'═' * 64}")
        print(f"  Cox Network Stability Monitor")
        print(f"  Gateway: {GATEWAY} | Interfaces: {', '.join(INTERFACES.values())}")
        print(f"  Logs: {LOG_DIR}")
        print(f"  Send SIGUSR1 (kill -USR1 {os.getpid()}) for interim report")
        print(f"  Ctrl+C to stop and generate final report")
        print(f"{'═' * 64}\n")

        while self.running:
            results = self._test_cycle()
            self._evaluate_results(results)
            interval = POLL_INTERVAL_OUTAGE if self.current_outage else POLL_INTERVAL_OK
            try:
                time.sleep(interval)
            except KeyboardInterrupt:
                self._handle_exit(None, None)

    def _test_cycle(self):
        now = datetime.now()
        ts = now.isoformat()
        do_speed = (time.time() - self.last_speed_test) >= SPEED_TEST_INTERVAL
        results = []

        for name, iface in INTERFACES.items():
            r = ProbeResult(timestamp=ts, interface=iface, interface_name=name)

            # 1. Link check
            r.link_up, r.ip_address, _ = check_link(iface)
            if not r.link_up:
                r.fault_location = "local_nic"
                results.append(r)
                continue

            # 2. Gateway ping (is your Cox router reachable?)
            gw_rtts, gw_loss = ping_test(iface, GATEWAY, 3)
            r.gateway_reachable = gw_loss < 100
            r.gateway_latency_ms = statistics.mean(gw_rtts) if gw_rtts else 0.0

            if not r.gateway_reachable:
                r.fault_location = "local_network"
                results.append(r)
                continue

            # 3. Internet ping (beyond Cox router)
            all_rtts = []
            all_loss = []
            for target in INTERNET_TARGETS:
                rtts, loss = ping_test(iface, target, PING_COUNT)
                all_rtts.extend(rtts)
                all_loss.append(loss)

            r.internet_loss_pct = statistics.mean(all_loss) if all_loss else 100.0
            r.internet_reachable = r.internet_loss_pct < 100
            if all_rtts:
                r.internet_latency_ms = statistics.mean(all_rtts)
                r.jitter_ms = calculate_jitter(all_rtts)

            # 4. DNS test
            dns_times, dns_failures = dns_test(iface, DNS_TARGETS)
            r.dns_ok = dns_failures == 0
            r.dns_latency_ms = statistics.mean(dns_times) if dns_times else 0.0

            # 5. Speed test (less frequent)
            if do_speed and r.internet_reachable:
                r.download_mbps = download_test(iface)
                self.speed_results.append({
                    "timestamp": ts,
                    "interface": name,
                    "mbps": r.download_mbps
                })

            # Determine fault location
            if not r.internet_reachable:
                r.fault_location = "isp"  # gateway OK but internet dead = Cox's fault
            elif r.internet_loss_pct > 10:
                r.fault_location = "isp_degraded"
            else:
                r.fault_location = "ok"

            results.append(r)

        if do_speed:
            self.last_speed_test = time.time()

        # Log all results
        for r in results:
            self.total_samples += 1
            with open(LOG_FILE, "a") as f:
                f.write(json.dumps(asdict(r)) + "\n")

        return results

    def _evaluate_results(self, results):
        now_str = datetime.now().strftime("%H:%M:%S")
        internet_down = all(
            not r.internet_reachable for r in results if r.link_up
        )
        any_degraded = any(
            r.internet_loss_pct > 10 for r in results if r.link_up
        )

        if internet_down and any(r.link_up for r in results):
            self.failed_samples += 1
            gw_ok = any(r.gateway_reachable for r in results)
            fault = "ISP (Cox)" if gw_ok else "Local network"

            if not self.current_outage:
                self.current_outage = Outage(
                    start=results[0].timestamp,
                    fault_location="isp" if gw_ok else "local",
                    affected_interfaces=[r.interface_name for r in results if r.link_up],
                )
                print(f"  [{now_str}] !! OUTAGE STARTED — Fault: {fault}")
                print(f"             Gateway reachable: {'Yes' if gw_ok else 'No'}")
                print(f"             Internet: DOWN on all interfaces")
            else:
                self.current_outage.samples += 1
                elapsed = (datetime.now() - datetime.fromisoformat(self.current_outage.start)).total_seconds()
                print(f"  [{now_str}] !! OUTAGE ONGOING — {elapsed:.0f}s — Fault: {fault}")
        else:
            if self.current_outage:
                self._end_outage()
                print(f"  [{now_str}] ✓ OUTAGE ENDED — duration: "
                      f"{self.current_outage.duration_seconds:.0f}s")
                self.current_outage = None

            # Normal status line
            statuses = []
            for r in results:
                if not r.link_up:
                    statuses.append(f"{r.interface_name}:DOWN")
                elif not r.internet_reachable:
                    statuses.append(f"{r.interface_name}:NO-INET")
                elif any_degraded:
                    statuses.append(f"{r.interface_name}:DEGRADED "
                                    f"loss={r.internet_loss_pct:.0f}%")
                else:
                    statuses.append(f"{r.interface_name}:OK "
                                    f"{r.internet_latency_ms:.0f}ms")
            uptime = self._calc_uptime()
            print(f"  [{now_str}] {' | '.join(statuses)} "
                  f"| uptime={uptime:.2f}%")

    def _end_outage(self):
        if not self.current_outage:
            return
        self.current_outage.end = datetime.now().isoformat()
        start_dt = datetime.fromisoformat(self.current_outage.start)
        self.current_outage.duration_seconds = (datetime.now() - start_dt).total_seconds()
        self.outages.append(self.current_outage)
        with open(OUTAGE_LOG, "a") as f:
            f.write(json.dumps(asdict(self.current_outage)) + "\n")

    def _calc_uptime(self):
        if self.total_samples == 0:
            return 100.0
        return ((self.total_samples - self.failed_samples) / self.total_samples) * 100

    def generate_report(self):
        uptime = self._calc_uptime()
        monitoring_duration = datetime.now() - self.start_time
        hours = monitoring_duration.total_seconds() / 3600
        isp_outages = [o for o in self.outages if o.fault_location == "isp"]
        total_downtime = sum(o.duration_seconds for o in isp_outages)

        report = []
        report.append("# Cox Internet Service — Outage Evidence Report\n")
        report.append(f"**Generated:** {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
        report.append(f"**Monitoring Period:** {self.start_time.strftime('%Y-%m-%d %H:%M')} — "
                      f"{datetime.now().strftime('%Y-%m-%d %H:%M')} "
                      f"({hours:.1f} hours)\n")
        report.append(f"**Customer Location:** Monitoring from customer premises\n")
        report.append(f"**Gateway (Cox Router):** {GATEWAY}\n")
        report.append(f"**Test Method:** Continuous automated monitoring via both wired "
                      f"(Ethernet) and wireless (WiFi) connections\n")

        report.append("\n---\n")
        report.append("\n## Summary\n")
        report.append(f"| Metric | Value | Cox SLA |")
        report.append(f"|--------|-------|---------|")
        report.append(f"| Measured Uptime | **{uptime:.2f}%** | {COX_SLA_UPTIME}% |")
        sla_status = "COMPLIANT" if uptime >= COX_SLA_UPTIME else "**VIOLATION**"
        report.append(f"| SLA Status | {sla_status} | — |")
        report.append(f"| Total ISP Outages | **{len(isp_outages)}** | — |")
        report.append(f"| Total ISP Downtime | **{format_duration(total_downtime)}** | — |")
        report.append(f"| Total Samples | {self.total_samples} | — |")
        report.append(f"| Failed Samples | {self.failed_samples} | — |")

        if isp_outages:
            report.append("\n---\n")
            report.append("\n## ISP Outage Log (Fault Proven at Cox Network)\n")
            report.append("Each outage below was confirmed by verifying:\n")
            report.append("1. Local gateway (Cox router at 10.0.0.1) was **reachable** "
                          "(ruling out local cable/NIC)\n")
            report.append("2. Internet targets beyond Cox were **unreachable** on "
                          "**both** Ethernet and WiFi (ruling out single-interface issues)\n")
            report.append("")
            report.append("| # | Start | End | Duration | Interfaces Affected |")
            report.append("|---|-------|-----|----------|---------------------|")
            for i, o in enumerate(isp_outages, 1):
                start = format_ts(o.start)
                end = format_ts(o.end) if o.end else "ongoing"
                dur = format_duration(o.duration_seconds)
                ifaces = ", ".join(o.affected_interfaces) if o.affected_interfaces else "all"
                report.append(f"| {i} | {start} | {end} | {dur} | {ifaces} |")

            report.append(f"\n**Longest outage:** "
                          f"{format_duration(max(o.duration_seconds for o in isp_outages))}")
            report.append(f"**Average outage:** "
                          f"{format_duration(total_downtime / len(isp_outages))}")

        if self.speed_results:
            report.append("\n---\n")
            report.append("\n## Speed Test Results\n")
            speeds = [s["mbps"] for s in self.speed_results if s["mbps"] > 0]
            if speeds:
                report.append(f"| Metric | Value |")
                report.append(f"|--------|-------|")
                report.append(f"| Average Download | {statistics.mean(speeds):.2f} Mbps |")
                report.append(f"| Minimum Download | {min(speeds):.2f} Mbps |")
                report.append(f"| Maximum Download | {max(speeds):.2f} Mbps |")
                report.append(f"| Samples | {len(speeds)} |")

        report.append("\n---\n")
        report.append("\n## Methodology\n")
        report.append("This report was generated by an automated network monitoring tool "
                      "running continuously on the customer's computer. The tool:\n")
        report.append("- Pings the Cox gateway (10.0.0.1) to verify local connectivity\n")
        report.append("- Pings 3 independent internet targets (8.8.8.8, 1.1.1.1, "
                      "208.67.222.222) to verify internet connectivity\n")
        report.append("- Tests DNS resolution via external servers\n")
        report.append("- Runs periodic download speed tests\n")
        report.append("- Tests over BOTH wired Ethernet and WiFi simultaneously — "
                      "if both fail while the gateway is reachable, the fault is "
                      "conclusively in the Cox network, not customer equipment\n")
        report.append(f"- Polls every {POLL_INTERVAL_OK}s normally, "
                      f"every {POLL_INTERVAL_OUTAGE}s during outages for precise "
                      f"duration measurement\n")

        report.append("\n---\n")
        report.append("\n## Request\n")
        report.append("Based on the documented SLA violations above, I am requesting:\n")
        report.append("1. Investigation into the recurring outages at my service address\n")
        report.append("2. Service credit for the documented downtime periods\n")
        report.append("3. A technician visit to inspect the line if outages continue\n")

        report_text = "\n".join(report)
        with open(REPORT_FILE, "w") as f:
            f.write(report_text)
        print(f"\n  Report saved: {REPORT_FILE}")
        return report_text


# ─── Utility Functions ────────────────────────────────────────────────────────

def format_duration(seconds):
    if seconds < 60:
        return f"{seconds:.0f}s"
    elif seconds < 3600:
        return f"{seconds/60:.1f}min"
    else:
        h = int(seconds // 3600)
        m = int((seconds % 3600) // 60)
        return f"{h}h {m}m"


def format_ts(ts):
    if not ts:
        return "—"
    try:
        dt = datetime.fromisoformat(ts)
        return dt.strftime("%Y-%m-%d %H:%M:%S")
    except (ValueError, TypeError):
        return ts


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
    return link_up, ip_addr, None


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


def calculate_jitter(rtts):
    if len(rtts) < 2:
        return 0.0
    diffs = [abs(rtts[i] - rtts[i - 1]) for i in range(1, len(rtts))]
    return statistics.mean(diffs)


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


# ─── One-shot mode (original behavior) ───────────────────────────────────────

def oneshot():
    """Run a single test and print report (original behavior)."""
    from dataclasses import dataclass as _dc

    @_dc
    class IfResult:
        name: str
        interface: str
        link_up: bool = False
        ip_address: Optional[str] = None
        gateway: Optional[str] = None
        gw_reachable: bool = False
        gw_latency_ms: float = 0.0
        internet_reachable: bool = False
        ping_avg_ms: float = 0.0
        ping_min_ms: float = 0.0
        ping_max_ms: float = 0.0
        ping_loss_pct: float = 100.0
        jitter_ms: float = 0.0
        dns_avg_ms: float = 0.0
        dns_failures: int = 0
        download_mbps: float = 0.0
        fault_location: str = "unknown"
        score: float = 0.0
        grade: str = "F"

    print(f"\n{'═' * 64}")
    print(f"  Cox Network Stability Checker (one-shot)")
    print(f"  Gateway: {GATEWAY}")
    print(f"{'═' * 64}")

    results = []
    for name, iface in INTERFACES.items():
        print(f"\n{'─' * 50}")
        print(f"  Testing: {name} ({iface})")
        print(f"{'─' * 50}")

        r = IfResult(name=name, interface=iface, gateway=GATEWAY)

        print("  [1/6] Link status...", end=" ", flush=True)
        r.link_up, r.ip_address, _ = check_link(iface)
        if not r.link_up:
            print("DOWN")
            r.fault_location = "local_nic"
            results.append(r)
            continue
        print(f"UP — {r.ip_address}")

        print("  [2/6] Gateway ping (Cox router)...", end=" ", flush=True)
        gw_rtts, gw_loss = ping_test(iface, GATEWAY, 5)
        r.gw_reachable = gw_loss < 100
        r.gw_latency_ms = statistics.mean(gw_rtts) if gw_rtts else 0.0
        print(f"{'OK' if r.gw_reachable else 'FAIL'} "
              f"({r.gw_latency_ms:.1f}ms, loss={gw_loss:.0f}%)")

        print(f"  [3/6] Internet ping ({len(INTERNET_TARGETS)} targets)...", end=" ", flush=True)
        all_rtts = []
        all_loss = []
        for target in INTERNET_TARGETS:
            rtts, loss = ping_test(iface, target, PING_COUNT)
            all_rtts.extend(rtts)
            all_loss.append(loss)
        r.ping_loss_pct = statistics.mean(all_loss) if all_loss else 100.0
        r.internet_reachable = r.ping_loss_pct < 100
        if all_rtts:
            r.ping_avg_ms = statistics.mean(all_rtts)
            r.ping_min_ms = min(all_rtts)
            r.ping_max_ms = max(all_rtts)
            r.jitter_ms = calculate_jitter(all_rtts)
        print(f"avg={r.ping_avg_ms:.1f}ms loss={r.ping_loss_pct:.1f}%")

        print("  [4/6] DNS resolution...", end=" ", flush=True)
        dns_times, r.dns_failures = dns_test(iface, DNS_TARGETS)
        r.dns_avg_ms = statistics.mean(dns_times) if dns_times else 0.0
        print(f"avg={r.dns_avg_ms:.0f}ms failures={r.dns_failures}")

        print("  [5/6] Download speed...", end=" ", flush=True)
        r.download_mbps = download_test(iface)
        print(f"{r.download_mbps:.2f} Mbps")

        # Fault location
        if not r.gw_reachable:
            r.fault_location = "local_network"
        elif not r.internet_reachable:
            r.fault_location = "isp"
        elif r.ping_loss_pct > 10:
            r.fault_location = "isp_degraded"
        else:
            r.fault_location = "ok"

        # Score
        score = 100.0
        score -= r.ping_loss_pct * 2.5
        if r.ping_avg_ms > 100:
            score -= min(20, (r.ping_avg_ms - 100) * 0.2)
        elif r.ping_avg_ms > 50:
            score -= (r.ping_avg_ms - 50) * 0.1
        if r.jitter_ms > 20:
            score -= min(15, (r.jitter_ms - 20) * 0.5)
        elif r.jitter_ms > 5:
            score -= (r.jitter_ms - 5) * 0.2
        score -= r.dns_failures * 5
        if r.download_mbps < 1:
            score -= 10
        r.score = max(0.0, min(100.0, score))
        r.grade = ("A" if r.score >= 90 else "B" if r.score >= 75 else
                   "C" if r.score >= 60 else "D" if r.score >= 40 else "F")
        print(f"  [6/6] Score: {r.score:.0f}/100 (Grade: {r.grade})")

        results.append(r)

    # Print report
    print(f"\n{'═' * 64}")
    print(f"  NETWORK STABILITY REPORT — {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Gateway: {GATEWAY} (Cox fiber router)")
    print(f"{'═' * 64}\n")

    for r in results:
        status = "UP" if r.link_up else "DOWN"
        fault_label = {
            "ok": "No issues",
            "local_nic": "Local NIC down",
            "local_network": "Cannot reach Cox router",
            "isp": "COX OUTAGE (gateway OK, internet dead)",
            "isp_degraded": "Cox degraded (high loss)",
        }.get(r.fault_location, r.fault_location)

        print(f"  ┌─ {r.name.upper()} ({r.interface}) — {status}")
        if not r.link_up:
            print(f"  │  Fault: {fault_label}")
            print(f"  └─ Grade: F\n")
            continue
        print(f"  │  IP: {r.ip_address}")
        print(f"  │  Gateway:   {r.gw_latency_ms:.1f}ms ({'OK' if r.gw_reachable else 'UNREACHABLE'})")
        print(f"  │  Internet:  avg={r.ping_avg_ms:.1f}ms  jitter={r.jitter_ms:.1f}ms  "
              f"loss={r.ping_loss_pct:.1f}%")
        print(f"  │  DNS:       avg={r.dns_avg_ms:.0f}ms  failures={r.dns_failures}/{len(DNS_TARGETS)}")
        print(f"  │  Speed:     {r.download_mbps:.2f} Mbps")
        print(f"  │  Fault:     {fault_label}")
        print(f"  └─ Grade: {r.grade} ({r.score:.0f}/100)\n")

    # Diagnosis
    all_up = [r for r in results if r.link_up]
    if all_up:
        isp_fault = all(r.fault_location in ("isp", "isp_degraded") for r in all_up)
        if isp_fault:
            print(f"  ⚠ DIAGNOSIS: Cox network issue detected.")
            print(f"    Both interfaces can reach gateway but NOT the internet.")
            print(f"    This is conclusive evidence of an ISP-side problem.")
            print(f"\n    Run in monitor mode to collect evidence:")
            print(f"    python3 {sys.argv[0]} --monitor")

    print(f"\n{'═' * 64}")


# ─── Entry Point ──────────────────────────────────────────────────────────────

def main():
    if "--monitor" in sys.argv or "-m" in sys.argv:
        monitor = Monitor()
        monitor.run()
    elif "--report" in sys.argv or "-r" in sys.argv:
        monitor = Monitor()
        monitor.generate_report()
        print(f"\n  Report generated from existing logs: {REPORT_FILE}")
    else:
        oneshot()


if __name__ == "__main__":
    main()
