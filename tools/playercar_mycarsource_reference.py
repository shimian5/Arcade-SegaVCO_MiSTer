#!/usr/bin/env python3
"""Reference model for the proven IC6/D7 + IC6/D13 MYCAR source.

This is intentionally a small voltage-domain model, not a cabinet fit.  It
uses the recovered ACC ladder, the IC6/C5 and IC6/C18+C19 relaxation-cell
constants, bounded MA150 forward drop, and the actual two-diode/R79 KCL.  The
sub-cell rate is exposed as ``K_SUB_HZ_PER_V`` because its 2SC458 collector
operating point is not measurable from the paper schematic; 0.43 Hz/V is the
named cabinet-derived parameter in the remediation plan.  No IC17 transfer or
absolute MB4391 gain is represented here.

The default branch resistance is a deliberately explicit bounded model
parameter.  A zero value is the direct-op-amp/ideal-diode limit; a positive
value makes the KCL solver finite and is useful for sensitivity sweeps.  The
RTL keeps this parameter named and fixed rather than hiding it in an audio
gain or modulation-depth constant.
"""
from __future__ import annotations

import argparse
import math
from dataclasses import dataclass


FS = 48_000.0
VREF6 = 6.0
VLO = 3.9735
VHI = 7.5199
VF_MA150 = 0.70                 # bounded 0.45..0.95 V midpoint
R79_OHM = 10_000.0
C76_F = 10.0e-6
BUS_DIVIDER = 15.0 / (4.7 + 15.0)   # D-8/11: IC6 cell hangs on the 4.7k/15k divider TAP
K_TONE_CELL_HZ_PER_V = 61.73    # closed-form IC6/C5 cell law per volt of bus
K_TONE_HZ_PER_V = K_TONE_CELL_HZ_PER_V * BUS_DIVIDER   # per volt of V_ladder (47.0)
K_SUB_HZ_PER_V = 0.43           # named measurement-derived operating point
TONE_RISE_RATIO = 1.25          # R28/R31 - 1
SUB_RISE_RATIO = 1.20           # R78/R76 - 1
V_LADDER_Q12 = (
    0, 757, 1514, 2279, 3028, 3792, 4558, 5330,
    6057, 6820, 7585, 8356, 9118, 9889, 10663, 11442,
    12121, 12885, 13649, 14421, 15180, 15950, 16724, 17503,
    18252, 19022, 19794, 20572, 21345, 22122, 22904, 23690,
    24309, 25074, 25840, 26614, 27373, 28146, 28922, 29702,
    30448, 31220, 31993, 32774, 33547, 34326, 35110, 35897,
    36629, 37401, 38174, 38955, 39725, 40504, 41287, 42075,
    42844, 43622, 44404, 45191, 45975, 46760, 47552, 48346,
)


def ladder_v(acc: int) -> float:
    if not 0 <= acc < len(V_LADDER_Q12):
        raise ValueError("ACC must be in 0..63")
    return V_LADDER_Q12[acc] / 4096.0


def frequency_hz(acc: int, k_hz_per_v: float) -> float:
    return k_hz_per_v * ladder_v(acc)


def ramp_duty(rise_ratio: float) -> float:
    """Fraction of a cycle spent on the upward ramp."""
    if rise_ratio <= 0.0:
        raise ValueError("rise ratio must be positive")
    return 1.0 / rise_ratio / (1.0 + 1.0 / rise_ratio)


def cell_voltage(phase: float, rise_ratio: float) -> float:
    """Integrator triangle, including the component-derived unequal slopes."""
    duty = ramp_duty(rise_ratio)
    if phase < duty:
        return VLO + (VHI - VLO) * phase / duty
    return VHI - (VHI - VLO) * (phase - duty) / (1.0 - duty)


def diode_node(sources: tuple[float, ...], *, r_source_ohm: float,
               vf: float = VF_MA150, r_load_ohm: float = R79_OHM) -> float:
    """Solve the two-diode KCL at R79.

    For a direct low-impedance op-amp output (``r_source_ohm <= 0``), the
    solution is the limiting complementarity result.  For a finite branch
    resistance, the active-set/bisection solve is explicit: each MA150 branch
    contributes only when ``source - VF > node`` and R79 carries the return
    current.  The latter path is deliberately not a hand-written ``max``.
    """
    if r_load_ohm <= 0.0:
        raise ValueError("R79 load must be positive")
    if r_source_ohm <= 0.0:
        return max(0.0, *(source - vf for source in sources))

    def kcl(node: float) -> float:
        branch = sum(max(0.0, source - vf - node) / r_source_ohm
                     for source in sources)
        return branch - node / r_load_ohm

    lo, hi = 0.0, max(0.0, *(source - vf for source in sources))
    for _ in range(48):
        mid = 0.5 * (lo + hi)
        if kcl(mid) > 0.0:
            lo = mid
        else:
            hi = mid
    return 0.5 * (lo + hi)


@dataclass
class SourceSample:
    tone: float
    sub: float
    node: float
    ac: float


def render(acc: int, seconds: float = 2.0, *, k_sub: float = K_SUB_HZ_PER_V,
           r_source_ohm: float = 0.0) -> list[SourceSample]:
    """Render both cells and C76's bounded AC-coupling state."""
    tone_f = frequency_hz(acc, K_TONE_HZ_PER_V)
    sub_f = frequency_hz(acc, k_sub)
    beta = 1.0 - math.exp(-1.0 / (FS * R79_OHM * C76_F))
    tone_phase = 0.0
    sub_phase = 0.0
    lp = 0.0
    out: list[SourceSample] = []
    for _ in range(int(round(seconds * FS))):
        tone = cell_voltage(tone_phase, TONE_RISE_RATIO)
        sub = cell_voltage(sub_phase, SUB_RISE_RATIO)
        node = diode_node((tone, sub), r_source_ohm=r_source_ohm)
        lp += beta * (node - lp)
        out.append(SourceSample(tone, sub, node, node - lp))
        tone_phase = (tone_phase + tone_f / FS) % 1.0
        sub_phase = (sub_phase + sub_f / FS) % 1.0
    return out


def _self_test() -> None:
    assert abs(frequency_hz(42, K_TONE_HZ_PER_V) - 367.2) < 1.0
    assert abs(frequency_hz(4, K_TONE_HZ_PER_V) - 34.7) < 1.0
    assert abs(frequency_hz(42, K_SUB_HZ_PER_V) - 3.36) < 0.15
    assert abs(ramp_duty(TONE_RISE_RATIO) - 4.0 / 9.0) < 1.0e-12
    assert diode_node((6.0, 5.0), r_source_ohm=0.0) > 5.25
    finite = diode_node((6.0, 5.0), r_source_ohm=1_000.0)
    assert 0.0 < finite < 6.0
    samples = render(42, seconds=1.0, r_source_ohm=1_000.0)
    assert max(s.tone for s in samples) <= VHI + 1.0e-9
    assert min(s.tone for s in samples) >= VLO - 1.0e-9
    assert max(s.node for s in samples) > min(s.node for s in samples)
    print("playercar_mycarsource_reference: PASS")
    print(f"  ACC4 tone={frequency_hz(4, K_TONE_HZ_PER_V):.3f} Hz")
    print(f"  ACC42 tone={frequency_hz(42, K_TONE_HZ_PER_V):.3f} Hz")
    print(f"  ACC42 sub={frequency_hz(42, K_SUB_HZ_PER_V):.3f} Hz "
          f"(nominal schematic bound={frequency_hz(42, 3.88):.3f} Hz)")
    print(f"  duty tone={ramp_duty(TONE_RISE_RATIO):.6f} "
          f"sub={ramp_duty(SUB_RISE_RATIO):.6f}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--acc", type=int, default=42)
    parser.add_argument("--seconds", type=float, default=1.0)
    parser.add_argument("--k-sub", type=float, default=K_SUB_HZ_PER_V)
    parser.add_argument("--r-source-ohm", type=float, default=0.0)
    args = parser.parse_args()
    if args.self_test:
        _self_test()
        return 0
    samples = render(args.acc, args.seconds, k_sub=args.k_sub,
                     r_source_ohm=args.r_source_ohm)
    values = [sample.ac for sample in samples]
    print(f"ACC={args.acc} tone={frequency_hz(args.acc, K_TONE_HZ_PER_V):.3f}Hz "
          f"sub={frequency_hz(args.acc, args.k_sub):.3f}Hz "
          f"node=[{min(s.node for s in samples):.3f},"
          f"{max(s.node for s in samples):.3f}]V "
          f"ac_rms={math.sqrt(sum(v*v for v in values)/len(values)):.5f}V")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
