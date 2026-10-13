#!/usr/bin/env python3
"""Screenshots the tablet and reads two clock barcodes from the same frame:
the Mac's clock (drawn by LatencyProbe on the Mac display, arriving through the display path)
and the tablet's own clock (ProbeReceiver overlay).
latency = tablet clock at composition - Mac clock when drawn, corrected by the measured clock offset.
Usage: measure.py <adb-serial> <samples> <label>
"""
import gzip
import os
import statistics
import struct
import subprocess
import sys
import time

ADB = os.environ.get("ADB", "adb")
serial, samples, label = sys.argv[1], int(sys.argv[2]), sys.argv[3]


def clock_offset_ms():
    """tablet_realtime - mac_realtime, from the lowest-RTT round trip over a persistent adb shell."""
    p = subprocess.Popen([ADB, "-s", serial, "shell"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
    best = None
    for _ in range(40):
        t0 = time.time_ns()
        p.stdin.write("date +%s%N\n")
        p.stdin.flush()
        pad = int(p.stdout.readline().strip())
        t1 = time.time_ns()
        if best is None or t1 - t0 < best[0]:
            best = (t1 - t0, pad - (t0 + t1) // 2)
        time.sleep(0.02)
    p.stdin.close()
    p.wait()
    return best[1] / 1e6, best[0] / 1e6


def grab():
    out = subprocess.run([ADB, "-s", serial, "exec-out", "screencap | gzip -1"], capture_output=True, check=True).stdout
    raw = gzip.decompress(out)
    w, h, _ = struct.unpack("<III", raw[:12])
    return raw, w, h, len(raw) - w * h * 4


def luma(img, x, y):
    raw, w, _, hdr = img
    s = 0
    for dy in (-6, 0, 6):
        for dx in (-6, 0, 6):
            o = hdr + ((y + dy) * w + (x + dx)) * 4
            s += raw[o] + raw[o + 1] + raw[o + 2]
    return s / 27


def bar(img, x0, y0, block):
    v = 0
    for i in range(32):
        a = luma(img, x0 + i * block + block // 2, y0 + block // 2)
        b = luma(img, x0 + i * block + block // 2, y0 + block + block // 2)
        if abs(a - b) < 60:
            return None  # unreadable block
        v = (v << 1) | (1 if a > b else 0)
    return v


offset, rtt = clock_offset_ms()
print(f"[{label}] clock offset tablet-mac {offset:.1f} ms (adb rtt {rtt:.1f} ms)")
lat, bad = [], 0
for _ in range(samples):
    img = grab()
    mac = bar(img, 80, 120, 64)    # LatencyProbe: 40 pt / 60 pt from top-left, 32 pt blocks at 2x
    pad = bar(img, 80, 1900, 64)   # tablet overlay
    if mac is None or pad is None:
        bad += 1
        continue
    lat.append(((pad - mac + 2**31) % 2**32) - 2**31 - offset)
    time.sleep(0.15)
if lat:
    lat.sort()
    q = lambda p: lat[min(len(lat) - 1, int(len(lat) * p))]
    print(f"[{label}] n={len(lat)} unreadable={bad}  min {lat[0]:.0f}  p50 {statistics.median(lat):.0f}  p90 {q(0.9):.0f}  max {lat[-1]:.0f} ms")
    print(f"[{label}] samples: " + " ".join(f"{x:.0f}" for x in lat))
else:
    print(f"[{label}] no readable samples ({bad} unreadable)")
