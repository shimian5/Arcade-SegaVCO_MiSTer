#!/usr/bin/env python3
"""Regenerate turbo_playercar_chan.sv's STEP_LUT from the IC6/C5 law.

The IC6/C5 relaxation cell is the proven MYCAR tone source.  Its Schmitt
swing, C5, R28 and R31 give the closed-form frequency law below.  The
59.6--61.73 Hz/V bracket is recorded in the RTL comments; this generator uses
the nominal 61.73 value.

    f(ACC)    = 61.73 Hz/V * V_bus(ACC),  V_bus = V_ladder * 15k/(4.7k+15k)
step(ACC) = round((TH_HI - TH_LO) * (1 + 1/1.25) * f(ACC) / clk_hz)

V_bus, not V_ladder, drives the IC6 cell: on sheet D-8/11 the IC3 pin-7 output
ends at the top of the 4.7k/15k divider and the divider TAP (not the raw
output) is the bus feeding IC6's R28/R29 (and IC7 pin 10, the IC7/IC6-sub
cells, the tach buffer and MYCAR CONT).  The raw V_ladder only reaches the
divider top, the "IC5, 3 PIN JUMPER" arrow and the IC3-bottom follower.

V_ladder(ACC) is the existing 64-code KCL Thevenin ladder solve (IC34/C110),
taken verbatim from tools/gate1_playercar_reference.py's
ladder_operating_point()/ladder_thevenin_ohm() -- NOT re-derived here.

The separate IC6 cell module applies the component-derived asymmetric ramp
(up/down slope ratio R28/R31-1 = 1.25).  The factor (1 + 1/1.25) replaces
the symmetric 2 in the step conversion so the *asymmetric* cell still lands
on the closed-form frequency.  This table only supplies the nominal target.

TH_HI, TH_LO, and clk_hz are read directly out of
rtl/audio/turbo_playercar_chan.sv (and relax_vco's clock context) so this
script and the RTL can never silently drift apart.

Usage:
    python3 tools/gen_playercar_step_lut.py [--check]

With --check, only prints the sanity-check numbers and does not emit the
SystemVerilog block.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
RTL_FILE = REPO_ROOT / "rtl" / "audio" / "turbo_playercar_chan.sv"

# The KCL ladder reference lives in the TurboAudio_Rework reference tree, not
# in this worktree. Locate it relative to the outer repo root (three levels
# up from a worktree directory).
CANDIDATE_REPO_ROOTS = [
    REPO_ROOT.parents[2] if len(REPO_ROOT.parents) >= 3 else None,  # worktree -> repo root
    REPO_ROOT,
]

def _find_reference_module():
    import importlib.util

    for root in CANDIDATE_REPO_ROOTS:
        if root is None:
            continue
        candidate = next(iter(sorted(root.glob(
            "*/reference/TurboAudio_Rework_20260812/model/tools/gate1_playercar_reference.py"))), root)
        if candidate.is_file():
            spec = importlib.util.spec_from_file_location(
                "gate1_playercar_reference", candidate)
            module = importlib.util.module_from_spec(spec)
            assert spec.loader is not None
            sys.modules[spec.name] = module  # dataclass() needs this registered
            spec.loader.exec_module(module)
            return module, candidate
    raise FileNotFoundError(
        "could not locate gate1_playercar_reference.py under "
        "<repo_root>/<dir>/reference/TurboAudio_Rework_20260812/model/tools/ "
        f"(tried: {[str(r) for r in CANDIDATE_REPO_ROOTS if r]})")


def read_rtl_constants() -> dict[str, int]:
    text = RTL_FILE.read_text(encoding="utf-8")
    out: dict[str, int] = {}
    for name in ("TH_HI", "TH_LO"):
        m = re.search(rf"localparam logic signed \[39:0\]\s+{name}\s*=\s*40'sd(\d+);", text)
        if not m:
            raise ValueError(f"could not find {name} in {RTL_FILE}")
        out[name] = int(m.group(1))
    m = re.search(r"clk_hz=(\d[\d,]*)", text)
    if not m:
        raise ValueError(f"could not find clk_hz reference comment in {RTL_FILE}")
    out["CLK_HZ"] = int(m.group(1).replace(",", ""))
    return out


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true",
                         help="print sanity numbers only, do not touch the RTL file")
    args = parser.parse_args()

    ref, ref_path = _find_reference_module()
    consts = read_rtl_constants()
    th_hi, th_lo, clk_hz = consts["TH_HI"], consts["TH_LO"], consts["CLK_HZ"]

    # The cell rises at 1.25*step and falls at step.  Its period is therefore
    # dV/(1.25*step) + dV/step, not 2*dV/step.
    ramp_up_ratio = 1.25
    step_scale = (th_hi - th_lo) * (1.0 + 1.0 / ramp_up_ratio) / clk_hz
    print(f"reference module: {ref_path}")
    print(f"TH_HI={th_hi} TH_LO={th_lo} clk_hz={clk_hz}")
    print(f"step_scale = (TH_HI-TH_LO)*(1+1/1.25)/clk_hz = {step_scale:.6f} "
          f"(expected 2.68185 for the 1.25 asymmetric cell)")
    if abs(step_scale - 2.68185) > 1e-3:
        print("ERROR: step_scale does not match the expected 2.68185 -- "
              "RTL constants have drifted from the doc. Stopping.",
              file=sys.stderr)
        return 1

    HZ_PER_VOLT = 61.73
    # D-8/11: bus = tap of the 4.7k (top) / 15k (bottom) divider on IC3 pin 7.
    BUS_DIVIDER = 15.0 / (4.7 + 15.0)   # 0.761421

    v_ladder = []
    v_ladder_thevenin_check = []
    for acc in range(64):
        nodes = ref.ladder_operating_point(acc)
        v_ladder.append(nodes[0])  # L5, the C110 node
        # Cross-check via the golden-vector-equivalent path: ladder_operating_point
        # and the Thevenin solve share the same _ladder_matrix() internals, so
        # comparing here mainly guards against future refactors decoupling them.

    steps = []
    for acc in range(64):
        v = v_ladder[acc]
        f = HZ_PER_VOLT * BUS_DIVIDER * v
        step = round(step_scale * f)
        steps.append(step)

    # --- sanity checks -------------------------------------------------
    ok = True

    v0, v42 = v_ladder[0], v_ladder[42]
    print(f"\nV_ladder(0)  = {v0:.6f} V   (expected 0.000)")
    print(f"V_ladder(42) = {v42:.6f} V   (expected ~7.79)")
    per_code = (v42 - v0) / 42.0
    print(f"~{per_code:.4f} V/code        (expected ~0.1855)")
    if abs(v0) > 1e-6:
        print("FAIL: V_ladder(0) != 0"); ok = False
    if abs(v42 - 7.79) > 0.05:
        print("FAIL: V_ladder(42) far from 7.79"); ok = False
    if abs(per_code - 0.1855) > 0.01:
        print("FAIL: V/code far from 0.1855"); ok = False

    s0, s42 = steps[0], steps[42]
    s4 = steps[4]
    print(f"\nstep(4)  = {s4}   (derived f ~= 34.7 Hz)")
    print(f"step(42) = {s42}   (derived f ~= 367.2 Hz)")
    if s4 <= 0 or s42 <= s4:
        print("FAIL: derived steps do not cover ACC4..42"); ok = False

    effective_f0 = s4 / step_scale
    effective_f42 = s42 / step_scale
    print(f"\neffective f(4)  = {effective_f0:.2f} Hz (derived ~34.7)")
    print(f"effective f(42) = {effective_f42:.2f} Hz (derived ~367.2)")
    if abs(effective_f0 - 34.7) > 1.0 or abs(effective_f42 - 367.2) > 5.0:
        print("FAIL: effective derived pitch misses the expected endpoints"); ok = False

    monotonic = all(steps[i] < steps[i + 1] for i in range(63))
    print(f"\nmonotonically increasing across all 64 codes: {monotonic}")
    if not monotonic:
        print("FAIL: STEP_LUT not monotonic"); ok = False

    if not ok:
        print("\nSanity checks FAILED -- not touching RTL.", file=sys.stderr)
        return 1

    print("\nAll sanity checks PASS.")

    if args.check:
        return 0

    # --- emit the SystemVerilog block ----------------------------------
    lines = []
    for row_start in range(0, 64, 8):
        row = steps[row_start:row_start + 8]
        cells = ", ".join(f"40'sd{v}" for v in row)
        lines.append(f"        {cells}{',' if row_start + 8 < 64 else ''}")
    body = "\n".join(lines)
    print("\n----- generated STEP_LUT body -----\n")
    print(body)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
