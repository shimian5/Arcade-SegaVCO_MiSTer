#!/usr/bin/env python3
"""Diff the golden sprite-path model (sim/golden_buckrog.py) against the RTL
dump (rtl/video/sprite_engine.v + sim/tb_z80_3d.cpp's VERILATOR_SIM debug
harness) for one frame. Reports data only -- does not attempt a fix.

Usage: python3 sim/compare_spr.py [--out-dir sim/out] [--rows 224]
"""
import argparse
import os
import re
import sys

ACTIVE_W = 512
ACTIVE_H = 224


def load_spr_bin(path, rows):
    with open(path, "rb") as f:
        data = f.read()
    expected = ACTIVE_W * rows * 5
    if len(data) < expected:
        raise ValueError(f"{path}: only {len(data)} bytes, expected {expected}")
    return data


def compare_pixels(golden, rtl, rows):
    first = None
    total_mismatch = 0
    per_row = [0] * rows

    for y in range(rows):
        row_base = y * ACTIVE_W * 5
        for x in range(ACTIVE_W):
            i = row_base + x * 5
            g = golden[i:i + 5]
            r = rtl[i:i + 5]
            if g != r:
                total_mismatch += 1
                per_row[y] += 1
                if first is None:
                    g_sprbits = g[0] | (g[1] << 8) | (g[2] << 16) | (g[3] << 24)
                    g_plb = g[4]
                    r_sprbits = r[0] | (r[1] << 8) | (r[2] << 16) | (r[3] << 24)
                    r_plb = r[4]
                    first = (y, x, r_sprbits, r_plb, g_sprbits, g_plb)

    return first, total_mismatch, per_row


LEVEL_RE = re.compile(r"y=(\d+) lvl=(\d+) step=([0-9a-fA-F]+) offset=([0-9a-fA-F]+) ve=(\d+)")


def load_levels(path):
    """First occurrence wins for each (y, lvl) -- see sprite_engine.v's
    VERILATOR_SIM comment: because y_target is truncated to 8 bits (VTOTAL=264
    needs 9), the RTL's dbg_rtl_levels.txt legitimately contains y=0..7 TWICE
    per frame -- once for the real scanline, once again ~256 lines later for
    a spurious re-run using vblank scanlines 256..263 mislabeled as y=0..7.
    The first occurrence is the one that actually drove the displayed frame;
    the second is evidence of the corruption itself, counted separately."""
    out = {}
    dup_diffs = 0
    with open(path) as f:
        for line in f:
            m = LEVEL_RE.match(line.strip())
            if not m:
                continue
            y, lvl, step, offset, ve = m.groups()
            key = (int(y), int(lvl))
            val = (int(step, 16), int(offset, 16), int(ve))
            if key in out:
                if out[key] != val:
                    dup_diffs += 1
            else:
                out[key] = val
    return out, dup_diffs


def compare_levels(golden_path, rtl_path, rows):
    golden, golden_dupdiffs = load_levels(golden_path)
    rtl, rtl_dupdiffs = load_levels(rtl_path)

    max_y_rtl = max((y for (y, _l) in rtl), default=-1)
    print(f"RTL dbg_rtl_levels.txt: {rtl_dupdiffs} (y,lvl) entries where the spurious "
          f"second pass (vpos=256..263 mislabeled y=0..7) committed a DIFFERENT "
          f"step/offset/ve than the real first pass (this is corruption evidence, "
          f"see sprite_engine.v's VERILATOR_SIM comment)")

    # "fresh" = golden's ve for this (y,lvl) is nonzero, i.e. prepare_sprites
    # actually recommitted this level's offset/step THIS scanline from
    # sprram -- an apples-to-apples comparison independent of history before
    # the captured frame. "stale" = neither owning sprnum fired this
    # scanline, so the compared value is whatever was left over from BEFORE
    # the snapshot -- the golden model has no such history (it starts from
    # all-zero level state at the snapshot), so stale mismatches are
    # EXPECTED and not evidence of an RTL bug by themselves.
    step_mismatches_fresh, step_mismatches_stale = [], []
    offset_mismatches_fresh, offset_mismatches_stale = [], []
    ve_mismatches = []

    for y in range(rows):
        for lvl in range(8):
            g = golden.get((y, lvl))
            r = rtl.get((y, lvl))
            if g is None or r is None:
                continue
            gs, go, gv = g
            rs, ro, rv = r
            fresh = gv != 0
            if gs != rs:
                (step_mismatches_fresh if fresh else step_mismatches_stale).append((y, lvl, rs, gs))
            if go != ro:
                (offset_mismatches_fresh if fresh else offset_mismatches_stale).append((y, lvl, ro, go))
            if gv != rv:
                ve_mismatches.append((y, lvl, rv, gv))

    return (step_mismatches_fresh, step_mismatches_stale,
            offset_mismatches_fresh, offset_mismatches_stale,
            ve_mismatches, max_y_rtl)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-dir", default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "sim", "out"))
    ap.add_argument("--rows", type=int, default=ACTIVE_H)
    args = ap.parse_args()

    golden_bin = os.path.join(args.out_dir, "dbg_golden_spr.bin")
    rtl_bin = os.path.join(args.out_dir, "dbg_rtl_spr.bin")
    golden_lvl = os.path.join(args.out_dir, "dbg_golden_levels.txt")
    rtl_lvl = os.path.join(args.out_dir, "dbg_rtl_levels.txt")

    print("=== (c) per-pixel sprite-path comparison ===")
    golden = load_spr_bin(golden_bin, args.rows)
    rtl = load_spr_bin(rtl_bin, args.rows)
    first, total, per_row = compare_pixels(golden, rtl, args.rows)

    if first is None:
        print("NO per-pixel mismatches.")
    else:
        y, x, r_sprbits, r_plb, g_sprbits, g_plb = first
        print(f"FIRST divergence: y={y} x={x}")
        print(f"  RTL:    sprbits={r_sprbits:08x} plb={r_plb:02x}")
        print(f"  golden: sprbits={g_sprbits:08x} plb={g_plb:02x}")
    print(f"total mismatching pixels: {total} / {ACTIVE_W * args.rows}")
    nz_rows = [(y, c) for y, c in enumerate(per_row) if c]
    print(f"scanlines with any mismatch: {len(nz_rows)} / {args.rows}")
    if nz_rows:
        print("per-scanline mismatch histogram (first 40 nonzero rows):")
        for y, c in nz_rows[:40]:
            print(f"  y={y:3d}  {c:4d} px")

    print()
    print("=== (b)/(c) per-scanline level-state comparison (step_reg/offset_reg/ve) ===")
    (step_fresh, step_stale, off_fresh, off_stale, ve_mm, max_y_rtl) = compare_levels(golden_lvl, rtl_lvl, args.rows)
    print(f"RTL dbg_rtl_levels.txt covers y up to {max_y_rtl} "
          f"(golden only covers y=0..{args.rows - 1}; RTL's FSM runs every HBLANK "
          f"including vblank scanlines {args.rows}..{max_y_rtl}, which MAME's "
          f"prepare_sprites() never processes at all -- see report)")

    if not step_fresh:
        print(f"step_reg (FRESH commits, ve!=0): MATCHES golden for every (y,level) in y=0..{args.rows - 1}")
    else:
        y0, l0, r0, g0 = step_fresh[0]
        print(f"step_reg (FRESH commits): {len(step_fresh)} mismatches. FIRST at y={y0} lvl={l0}: "
              f"RTL={r0:08x} golden={g0:08x} (delta={r0 - g0:+d})")
    print(f"step_reg (STALE/carry-over, ve==0): {len(step_stale)} mismatches -- expected, golden has no "
          f"pre-snapshot history (see comment above); not evidence of an RTL bug by itself")

    if not off_fresh:
        print(f"offset_reg (FRESH commits, ve!=0): MATCHES golden for every (y,level) in y=0..{args.rows - 1}")
    else:
        y0, l0, r0, g0 = off_fresh[0]
        print(f"offset_reg (FRESH commits): {len(off_fresh)} mismatches. FIRST at y={y0} lvl={l0}: "
              f"RTL={r0:05x} golden={g0:05x} (delta={r0 - g0:+d})")
    print(f"offset_reg (STALE/carry-over, ve==0): {len(off_stale)} mismatches -- expected, see above")

    if not ve_mm:
        print("ve: MATCHES golden for every (y,level) in y=0.." + str(args.rows - 1))
    else:
        y0, l0, r0, g0 = ve_mm[0]
        print(f"ve: {len(ve_mm)} mismatches. FIRST at y={y0} lvl={l0}: RTL={r0} golden={g0}")


if __name__ == "__main__":
    sys.exit(main())
