#!/usr/bin/env python3
"""Measure per-frame starfield motion from raw bitmap_ram dumps.

Reproduces the headline metric in docs/INVESTIGATION_starfield_2x_speed.md:
track individual stars frame-to-frame and report the per-frame (dx, dy).

Input is a directory of 57344-byte files (256 wide x 224 tall, one byte per
pixel, bit 0 = star) named <prefix><frame>.bin -- the format written by
sim/tb_z80_3d.cpp's --dumpbitmap and by tools/mame/dump_bitmap_ram.lua.

    python tools/measure_star_motion.py sim/out --prefix rtl_bitmap_
    python tools/measure_star_motion.py /c/MiSTerDev/mame --prefix bitmap_

Matching is optimal (scipy linear_sum_assignment) when scipy is available and
falls back to mutual-nearest-neighbour otherwise; both reject pairings beyond
--max-dist so stars entering/leaving the field are not matched to noise.
"""

import argparse
import os
import re
import statistics
import sys

import numpy as np

try:
    from scipy.optimize import linear_sum_assignment
except ImportError:
    linear_sum_assignment = None

W, H = 256, 224


def load(path):
    a = np.frombuffer(open(path, "rb").read(), dtype=np.uint8)
    if a.size != W * H:
        raise SystemExit(f"{path}: expected {W*H} bytes, got {a.size}")
    ys, xs = np.nonzero((a & 1).reshape(H, W))
    return np.stack([xs, ys], axis=1).astype(np.float64)


def match(a, b, max_dist):
    """Pair points in a with points in b; returns list of (dx, dy)."""
    if len(a) == 0 or len(b) == 0:
        return []
    d = np.hypot(a[:, None, 0] - b[None, :, 0], a[:, None, 1] - b[None, :, 1])
    if linear_sum_assignment is not None:
        rows, cols = linear_sum_assignment(d)
    else:
        # mutual nearest neighbour: keep only pairs that pick each other
        nb = d.argmin(axis=1)
        na = d.argmin(axis=0)
        rows = [i for i in range(len(a)) if na[nb[i]] == i]
        cols = [nb[i] for i in rows]
    return [(b[j, 0] - a[i, 0], b[j, 1] - a[i, 1])
            for i, j in zip(rows, cols) if d[i, j] <= max_dist]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("directory")
    ap.add_argument("--prefix", required=True)
    ap.add_argument("--max-dist", type=float, default=12.0,
                    help="reject pairings farther apart than this (default 12)")
    args = ap.parse_args()

    pat = re.compile(re.escape(args.prefix) + r"(\d+)\.bin$")
    frames = sorted(
        (int(m.group(1)), os.path.join(args.directory, n))
        for n in os.listdir(args.directory)
        if (m := pat.match(n))
    )
    if len(frames) < 2:
        raise SystemExit(f"need >=2 frames matching {args.prefix}*.bin")

    dxs, dys, counts = [], [], []
    prev_n, prev = frames[0][0], load(frames[0][1])
    counts.append(len(prev))
    for n, path in frames[1:]:
        cur = load(path)
        counts.append(len(cur))
        if n == prev_n + 1:
            for dx, dy in match(prev, cur, args.max_dist):
                dxs.append(dx)
                dys.append(dy)
        prev_n, prev = n, cur

    if not dxs:
        raise SystemExit("no stars matched -- check --max-dist / the dumps")

    print(f"frames {frames[0][0]}-{frames[-1][0]}  "
          f"matcher={'hungarian' if linear_sum_assignment else 'mutual-NN'}")
    print(f"  stars/frame  min {min(counts)}  max {max(counts)}  "
          f"mean {statistics.mean(counts):.1f}")
    print(f"  matched pairs {len(dxs)}")
    print(f"  mean   dx {statistics.mean(dxs):+.3f}   dy {statistics.mean(dys):+.3f}")
    print(f"  median dx {statistics.median(dxs):+.1f}     dy {statistics.median(dys):+.1f}")


if __name__ == "__main__":
    sys.exit(main())
