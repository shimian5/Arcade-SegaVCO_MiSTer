#!/usr/bin/env python3
"""Generate the D-8/11 IC17-gating tables used by turbo_playercar_chan.sv.

All numbers come from the sheet (see tools/playercar_d8_ic17_reference.py):

  V_bus          = V_ladder * 15k/(4.7k+15k)           (divider tap feeds every cell)
  SUB_STEP_LUT   : IC6 sub cell  f = 3.88*(0.09/C) Hz/V_bus  (R78 220k, R76 100k; C = C19 only, 0.068 uF, in production)
  IC7_STEP_LUT   : IC7 cell      f = 37.8*(13.6/C) Hz/V_bus  (R87 150k, R84 68k; C = C21 only, 6.8 nF, in production)
  CLAMP_LUT      : IC7-C + input DC = bus via 10k clamped by D5/D6 to the R38/R39 midpoint
  GAIN17_LUT     : IC17 (MC3340) relative gain vs control voltage, 1/64-V bins from 3.0 V,
                   log-linear interpolation of the RTL's existing 49-entry datasheet table.

Usage:  python tools/gen_playercar_ic17_tables.py [--patch]
        --patch rewrites the block between the BEGIN/END GENERATED IC17 TABLES markers
        in rtl/audio/turbo_playercar_chan.sv (and replaces SUB_STEP_LUT).
"""
from __future__ import annotations

import argparse
import math
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
RTL = REPO / "rtl" / "audio" / "turbo_playercar_chan.sv"
sys.path.insert(0, str(REPO / "tools"))
import playercar_d8_ic17_reference as R  # noqa: E402

TH_HI, TH_LO, CLK = 126162442, 66664434, 39_935_064
DIV = R.BUS_DIVIDER


# Timing-capacitor population. The 834-0123 schematic draws C18 in parallel with C19 (sub cell) and C20 in
# parallel with C21 (IC7 cell); the rev-0 parts-layout drawing, the Rev B photo and a second production
# board photo all show C18 and C20 UNFITTED (C19 = 0.068 uF and C21 = 6800 pF only). "production" is the
# nominal default; "board" = production caps at in-tolerance (+-5 %) values that put the tone, sub and IC7 cells on the cabinet board's
# measured fundamentals (T 326.77, S 27.594, IC7 385.47 Hz: C5 -0.75 %, C19 -2.2 %, C21 +3.05 %), which makes the near-degenerate
# (IC7-T)-2S warble 3.5 Hz instead of the nominal 18.9 Hz; "full" reproduces the schematic's parallel pairs (C18+C19 = 0.090 uF, C20+C21 = 13.6 nF).
POPULATION = __import__("os").environ.get("PLAYERCAR_POPULATION", "production")
C_SUB_UF = {"production": 0.068, "full": 0.090, "board": 0.06649}[POPULATION]
C_IC7_NF = {"production": 6.8, "full": 13.6, "board": 7.007}[POPULATION]
K_SUB = R.K_SUB_SCHEM * 0.090 / C_SUB_UF     # R.K_SUB_SCHEM is the C18+C19 = 0.09 uF law
K_IC7 = R.K_IC7 * 13.6 / C_IC7_NF            # R.K_IC7 is the C20||C21 = 13.6 nF law


def step_lut(k_hz_per_vbus: float, rise_ratio: float) -> list[int]:
    scale = (TH_HI - TH_LO) * (1.0 + 1.0 / rise_ratio) / CLK
    return [round(scale * k_hz_per_vbus * DIV * R.ladder_v(a)) for a in range(64)]


def sv_rows(values, width, per_row=8):
    rows = []
    for i in range(0, len(values), per_row):
        chunk = values[i:i + per_row]
        rows.append("        " + ", ".join(f"{width}'sd{v}" for v in chunk))
    return ",\n".join(rows)


def build() -> str:
    # rise ratio used by the RTL shift/add (1 + 1/4 - 1/32 - 1/64 = 1.203125) for sub AND IC7
    sub = step_lut(K_SUB, 1.203125)
    ic7 = step_lut(K_IC7, 1.203125)
    # clamp DC vs ladder voltage, 1/16-V bins (index = v_ladder_q12 >> 8), 0 .. 191
    clamp = [round(R.clamp_dc(((i + 0.5) / 16.0) * DIV) * 4096) for i in range(192)]
    # MC3340 gain, 1/64-V bins from 3.0 V (index = (v2_q12 - 12288) >> 6), 0 .. 192, Q16
    xs = [i / 16.0 for i in range(49)]
    ys = [max(v, 1e-6) for v in R.MC3340]
    gain = []
    for i in range(193):
        v = i / 64.0
        pos = min(v * 16.0, 48.0)
        lo = int(pos); hi = min(lo + 1, 48); f = pos - lo
        g = math.exp(math.log(ys[lo]) * (1 - f) + math.log(ys[hi]) * f)
        gain.append(max(1, round(g * 65536)))
    out = []
    out.append("    // BEGIN GENERATED IC17 TABLES (tools/gen_playercar_ic17_tables.py) -- do not hand-edit")
    out.append(f"    // IC7 relaxation cell step LUT: f = {K_IC7:.1f} Hz/V_bus ({POPULATION} population, C = {C_IC7_NF} nF), V_bus = V_ladder*{DIV:.4f} ({R.BUS_MODE} 4.7k/15k tap)")
    out.append("    localparam logic signed [39:0] IC7_STEP_LUT [0:63] = '{")
    out.append(sv_rows(ic7, "40") + "\n    };")
    out.append("    // IC7-C + input DC (bus via 10k, D5/D6 clamp to the 3.92-V R38/R39 midpoint), Q12 volts,")
    out.append("    // indexed by v_ladder_q12 >> 8 (1/16 V of ladder voltage)")
    out.append("    localparam logic signed [20:0] CLAMP_DC_LUT_Q12 [0:191] = '{")
    out.append(sv_rows(clamp, "21") + "\n    };")
    out.append("    // IC17 MC3340 relative gain vs CONT voltage, Q16, 1/64-V bins from 3.0 V")
    out.append("    localparam logic signed [26:0] GAIN17_LUT_Q16 [0:192] = '{")
    out.append(sv_rows(gain, "27") + "\n    };")
    out.append("    // END GENERATED IC17 TABLES")
    block = "\n".join(out)
    sub_block = ("    localparam logic signed [39:0] SUB_STEP_LUT [0:63] = '{\n" + sv_rows(sub, "40") + "\n    };")
    return block, sub_block, sub, ic7, clamp, gain


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--patch", action="store_true")
    args = ap.parse_args()
    block, sub_block, sub, ic7, clamp, gain = build()
    f_sub42 = sub[42] / ((TH_HI - TH_LO) * (1 + 1 / 1.203125) / CLK)
    f_ic7_42 = ic7[42] / ((TH_HI - TH_LO) * (1 + 1 / 1.203125) / CLK)
    print(f"ACC42: sub {f_sub42:.2f} Hz (step {sub[42]}), IC7 {f_ic7_42:.1f} Hz (step {ic7[42]}), "
          f"clamp DC {clamp[int(R.ladder_v(42)*16)]/4096:.2f} V")
    print(f"gain17 LUT: idx0 {gain[0]/65536:.3f}  idx32 (3.5V) {gain[32]/65536:.4f}  idx64 (4.0V) {gain[64]/65536:.5f}  idx192 {gain[192]/65536:.2e}")
    if not args.patch:
        print(block); print(sub_block); return 0
    text = RTL.read_text(encoding="utf-8")
    nl = "\r\n" if "\r\n" in text else "\n"
    t = text.replace("\r\n", "\n")
    m = re.search(r"    // BEGIN GENERATED IC17 TABLES.*?    // END GENERATED IC17 TABLES", t, re.S)
    if not m:
        raise SystemExit("markers not found in chan.sv; add them first")
    t = t[:m.start()] + block + t[m.end():]
    m2 = re.search(r"    localparam logic signed \[39:0\] SUB_STEP_LUT \[0:63\] = '\{.*?\n    \};", t, re.S)
    if not m2:
        raise SystemExit("SUB_STEP_LUT block not found")
    t = t[:m2.start()] + sub_block + t[m2.end():]
    RTL.write_text(t.replace("\n", nl), encoding="utf-8")
    print("patched", RTL)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
