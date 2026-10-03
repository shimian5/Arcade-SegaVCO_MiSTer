#!/usr/bin/env python3
"""Bounded D9 MYCAR-CONT control/reference numbers.

This is deliberately a control-path reference, not an audio-fit model.  It
uses the recovered IC34/C110 ladder, the primary D8 trace's IC3-A follower,
and the D9 4.7k/15k divider.  The D9 555/IC23/IC24 transfer remains a separate
open boundary; no oscillator or synthetic warble is generated here.
"""
from __future__ import annotations

import importlib.util
import math
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REF = next(iter(sorted(ROOT.parents[2].glob(
	"*/reference/TurboAudio_Rework_20260812/model/tools/gate1_playercar_reference.py"))), ROOT / "gate1_playercar_reference.py")
FS = 39_935_064 / 832.0
Q12 = 4096.0
LM324_HI = 10.5


def load_reference():
    spec = importlib.util.spec_from_file_location("gate1_playercar_reference", REF)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {REF}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


def divider(v_ic3: float) -> float:
    # D8 image: IC3 pin 7 -> 4.7k (top) / 15k (bottom), tap = MYCAR CONT.
    return v_ic3 * 15.0 / (4.7 + 15.0)


def main() -> int:
    ref = load_reference()
    ladder = [float(ref.ladder_operating_point(acc)[0]) for acc in range(64)]
    ic3 = [min(max(v, 0.0), LM324_HI) for v in ladder]
    cont = [divider(v) for v in ic3]

    # Board BOM/photo evidence: the single 1.5-uF tantalum is the D9 C155
    # timing part.  R196 is the traced 10-k input leg at the nominal corner.
    c155 = 1.5e-6
    r196 = 10_000.0
    tau_c155 = r196 * c155
    alpha_c155 = 1.0 - math.exp(-1.0 / (FS * tau_c155))
    alpha_q16 = round(alpha_c155 * 65536.0)

    # D9 BSEL0's two traced 4.7-nF shaping corners: C75 follows the nominal
    # 10-k source leg and C93 follows the 100-k IC21 leg.  These are fast
    # shaping poles, not a carrier.
    tau_bsel0_fast = 10_000.0 * 4.7e-9
    tau_bsel0_slow = 100_000.0 * 4.7e-9
    alpha_bsel0_fast = 1.0 - math.exp(-1.0 / (FS * tau_bsel0_fast))
    alpha_bsel0_slow = 1.0 - math.exp(-1.0 / (FS * tau_bsel0_slow))

    # C97 is the traced IC24-B bias-node capacitor with the 51-k R195 feed.
    tau_c97 = 51_000.0 * 1.0e-6
    alpha_c97 = 1.0 - math.exp(-1.0 / (FS * tau_c97))

    assert all(cont[i] <= cont[i + 1] for i in range(63))
    assert min(cont) >= 0.0 and max(cont) <= LM324_HI
    print(f"fs={FS:.9f} Hz")
    print(f"V_ladder(0)={ladder[0]:.6f} V V_ladder(42)={ladder[42]:.6f} V V_ladder(63)={ladder[63]:.6f} V")
    print(f"IC3-clamped(63)={ic3[63]:.6f} V")
    print(f"MYCAR_CONT(0)={cont[0]:.6f} V MYCAR_CONT(42)={cont[42]:.6f} V MYCAR_CONT(63)={cont[63]:.6f} V")
    print(f"C155 corner: R=10k C=1.5u tau={tau_c155*1e3:.3f} ms alpha={alpha_c155:.9f} q16={alpha_q16}")
    print(f"BSEL0 C75 corner: R=10k C=4.7n tau={tau_bsel0_fast*1e6:.3f} us alpha={alpha_bsel0_fast:.9f} q16={round(alpha_bsel0_fast*65536)}")
    print(f"BSEL0 C93 corner: R=100k C=4.7n tau={tau_bsel0_slow*1e6:.3f} us alpha={alpha_bsel0_slow:.9f} q16={round(alpha_bsel0_slow*65536)}")
    print(f"BSEL1 C97 corner: R=51k C=1u tau={tau_c97*1e3:.3f} ms alpha={alpha_c97:.9f} q16={round(alpha_c97*65536)}")
    print("PASS D9 MYCAR-CONT bounds/monotonicity")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
