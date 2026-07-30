#!/usr/bin/env python3
"""Scan the top-of-wall profile out of a Buck Rogers attract-screen capture.

This is the instrument that localised the tunnel-wall raggedness (2026-07-29,
see docs/INVESTIGATION_title_logo_garbling.md). It takes any capture of the
attract "GAME OVER / INSERT COIN" screen -- a phone photo of a DE10-Nano on a
TV, a MAME PPM, one of sim/out/*.ppm -- normalises it onto the core's native
512x224 output grid, and prints, for each output column, the first scanline at
which the tunnel wall starts.

Read the output as follows. The wall's cornice is a shallow diagonal, so a
correct render gives a smooth monotonic ramp. A pipeline bug that renders one
native pixel from the neighbouring tile column shows up as a periodic 2-output-
pixel notch (the core runs 2x horizontal, so 1 native pixel = 2 output pixels)
recurring every 16 output pixels (= one 8-pixel tile column), jumping back by
however many scanlines the cornice drops across one tile.

    python tools/measure_wall_profile.py capture.png [--cols 0 96]

Note the 512 in "512x224" is the 2x output domain: 256 native pixels across.
"""

import argparse
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("needs Pillow: pip install Pillow")

# Core output geometry (video_timing.v: HBSTART 512, VBSTART 224).
OUT_W, OUT_H = 512, 224

# Wall stripes are grey or teal; sky is blue; floor is olive. Classify on hue
# rather than absolute level, so a photographed CRT/TV (different gamma, and
# noticeably brighter than MAME's framebuffer) still classifies the same way.
def classify(px):
    r, g, b = int(px[0]), int(px[1]), int(px[2])
    if g > 110 and 100 < b < 190:
        if r > 100:
            return "G"  # grey stripe
        if r < 80:
            return "T"  # teal stripe
    return "."


def profile(path, run=5, y0=25, y1=150):
    """First scanline per column where `run` consecutive rows are all wall."""
    img = Image.open(path).convert("RGB").resize((OUT_W, OUT_H), Image.NEAREST)
    px = img.load()
    out = []
    for x in range(OUT_W):
        top, kind = None, None
        for y in range(y0, y1 - run):
            if all(classify(px[x, y + k]) != "." for k in range(run)):
                top, kind = y, classify(px[x, y])
                break
        out.append((top, kind))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--cols", nargs=2, type=int, default=[0, 96],
                    metavar=("FIRST", "LAST"))
    args = ap.parse_args()

    rows = profile(args.capture)
    a, b = args.cols
    print("x   :", " ".join("%3d" % x for x in range(a, b)))
    print("top :", " ".join(("%3d" % r[0]) if r[0] is not None else " --"
                            for r in rows[a:b]))
    print("cls :", " ".join("  %s" % (r[1] or "-") for r in rows[a:b]))

    # Flag columns whose top jumps backwards against the local trend -- the
    # signature of a tile-boundary pixel taken from the wrong tile column.
    tops = [r[0] for r in rows]
    notches = [x for x in range(a + 1, min(b, OUT_W - 1))
               if tops[x] is not None and tops[x - 1] is not None
               and tops[x + 1] is not None and tops[x] < tops[x - 1] - 1]
    if notches:
        print("\nbackward notches at x =", notches)
        print("  x mod 16          =", [x % 16 for x in notches])
        print("  spacing           =", [j - i for i, j in zip(notches, notches[1:])])
        print("\n  A spacing of 16 means one per tile column -- see the module")
        print("  header in rtl/video/fg_tilemap.v and the session-4 update in")
        print("  docs/INVESTIGATION_title_logo_garbling.md.")
    else:
        print("\nno backward notches -- profile is monotonic.")


if __name__ == "__main__":
    main()
