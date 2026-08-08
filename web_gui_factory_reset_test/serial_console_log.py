#!/usr/bin/env python3
"""Timestamped serial console logger — QCA case 08621084, step 2.

Pranjal asked for console logs captured from a Linux PC on the DUT LAN while the
factory-reset stress loop runs. This writes every console line to a file with a
host timestamp and a monotonic offset, so a panic can be lined up against the
stress-loop log to the second.

It also flags the two signatures QCA named (step 4) as they appear:
  overlayfs      -- any overlayfs message
  -116 / ESTALE  -- the stale-file-handle error they want to catch
plus kernel panic / BUG markers, so the run does not have to be watched.

Usage:
    python3 serial_console_log.py [--port /dev/ttyUSB0] [--baud 115200]
                                  [--out logs/console_<ts>.log]

The port is usually root:dialout, so run it with sudo unless your user is in the
dialout group:
    sudo python3 serial_console_log.py

Ctrl-C to stop; a summary of the flagged lines is printed on exit.
"""
import argparse
import datetime
import os
import re
import sys
import time

try:
    import serial
except ImportError:
    sys.exit("pyserial is required: pip3 install pyserial")

# Signatures QCA asked us to watch for, plus crash markers worth never missing.
PATTERNS = [
    ("OVERLAYFS", re.compile(r"overlayfs", re.I)),
    ("ESTALE-116", re.compile(r"(?<![\d-])-116(?![\d])|ESTALE", re.I)),
    ("PANIC", re.compile(r"Kernel panic|Internal error: Oops|kernel BUG at", re.I)),
    ("RESET-REASON", re.compile(r"System Reset Reason|Crashdump magic", re.I)),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default="/dev/ttyUSB0")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    if args.out:
        out_path = args.out
    else:
        here = os.path.dirname(os.path.abspath(__file__))
        logs = os.path.join(here, "logs")
        os.makedirs(logs, exist_ok=True)
        stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
        out_path = os.path.join(logs, "console_%s.log" % stamp)

    try:
        ser = serial.Serial(args.port, args.baud, timeout=1)
    except Exception as exc:
        sys.exit("cannot open %s: %s\n(try: sudo python3 %s)"
                 % (args.port, exc, os.path.basename(__file__)))

    print("logging %s @ %d -> %s" % (args.port, args.baud, out_path))
    print("watching for: overlayfs, -116/ESTALE, panic/BUG.  Ctrl-C to stop.")

    start = time.monotonic()
    hits = []
    buf = b""

    with open(out_path, "a", buffering=1) as fh:
        fh.write("==== console capture started %s (%s @ %d) ====\n"
                 % (datetime.datetime.now().isoformat(), args.port, args.baud))
        try:
            while True:
                chunk = ser.read(4096) or b""
                if chunk:
                    buf += chunk
                    while b"\n" in buf:
                        raw, buf = buf.split(b"\n", 1)
                        line = raw.decode("utf-8", "replace").rstrip("\r")
                        ts = datetime.datetime.now().strftime("%H:%M:%S.%f")[:-3]
                        off = time.monotonic() - start
                        fh.write("[%s +%08.3f] %s\n" % (ts, off, line))
                        for label, rx in PATTERNS:
                            if rx.search(line):
                                msg = "*** %s *** [%s] %s" % (label, ts, line)
                                print(msg)
                                fh.write(msg + "\n")
                                hits.append((label, ts, line))
                                break
                else:
                    time.sleep(0.05)
        except KeyboardInterrupt:
            fh.write("==== console capture stopped %s ====\n"
                     % datetime.datetime.now().isoformat())
        finally:
            ser.close()

    print("\nsaved: %s" % out_path)
    if hits:
        print("flagged %d line(s):" % len(hits))
        for label, ts, line in hits:
            print("  %-12s %s  %s" % (label, ts, line[:120]))
    else:
        print("no overlayfs / -116 / panic signatures seen.")


if __name__ == "__main__":
    main()
