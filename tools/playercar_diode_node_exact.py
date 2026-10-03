#!/usr/bin/env python3
"""Exact D7/D13/R79 diode-OR node vs the RTL's 'max of three conduction cases' heuristic.

Node: tone triangle -> D7 -> N, sub triangle -> D13 -> N, N -> R79 10k -> ground.  Cell outputs are op-amp
outputs (treated as ideal voltage sources).  Diode = small-signal silicon switching diode, 1N4148-class
SPICE numbers (Is 2.52 nA, n 1.752); MA150 has no local data sheet, so this is a device assumption, not a fit.
Solves I_D7(v_t - N) + I_D13(v_s - N) = N / R79 per sample by bisection.

Reports line levels (dB re the T line) of the node's AC part after C76, production population, ACC as given.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import playercar_fast_model as M      # noqa: E402
import playercar_d8_ic17_reference as R  # noqa: E402
import gen_playercar_ic17_tables as G  # noqa: E402

FS = M.FS
IS, NVT = 2.52e-9, 1.752 * 0.02585
R79 = 10e3


def exact_node(vt, vs):
    lo = np.zeros_like(vt)
    hi = np.maximum(vt, vs)
    for _ in range(42):
        mid = 0.5 * (lo + hi)
        i = IS * (np.expm1(np.clip((vt - mid) / NVT, -50, 50)) + np.expm1(np.clip((vs - mid) / NVT, -50, 50)))
        too_low = i > mid / R79          # diodes deliver more than R79 draws -> node must rise
        lo = np.where(too_low, mid, lo)
        hi = np.where(too_low, hi, mid)
    return 0.5 * (lo + hi)


def heuristic_node(vt, vs):
    a, b = 233 / 256, 61 / 128
    td, sd = vt - M.VF, vs - M.VF
    return np.clip(np.maximum(np.maximum(a * td, a * sd), b * (td + sd)), 0, 10.5)


def level(x, f0, bw=1.5, skip=1.0):
    x = x[int(skip * FS):]
    N = 1 << 19
    S = np.abs(np.fft.rfft(x * np.hanning(len(x)), N))
    f = np.fft.rfftfreq(N, 1 / FS)
    m = (f > f0 - bw) & (f < f0 + bw)
    return S[m].max()


def main():
    acc = int(sys.argv[1]) if len(sys.argv) > 1 else 42
    n = int(4.0 * FS)
    vl = R.ladder_v(acc)
    rng = np.random.default_rng(1)
    T, S = R.K_TONE * M.DIV * vl, G.K_SUB * M.DIV * vl
    vt = M.tri(M.phases(T, n, rng.random()), M.RATIO_TONE)
    vs = M.tri(M.phases(S, n, rng.random()), M.RATIO_SUB)
    from scipy.signal import lfilter
    alpha = 14.0 / 65536.0
    print(f"production population, ACC{acc}: T={T:.1f} S={S:.2f} Hz")
    for name, node in (("heuristic", heuristic_node(vt, vs)), ("exact diodes", exact_node(vt, vs))):
        ac = node - lfilter([alpha], [1, -(1 - alpha)], node)
        base = level(ac, T)
        probes = {"T": T, "S": S, "2S": 2 * S, "3S": 3 * S, "T-S": T - S, "T-2S": T - 2 * S, "T-3S": T - 3 * S,
                  "T+S": T + S, "T+2S": T + 2 * S, "2T": 2 * T, "2T-2S": 2 * T - 2 * S}
        row = "  ".join(f"{k}:{20 * np.log10(level(ac, f) / base):6.1f}" for k, f in probes.items())
        print(f"{name:13s} rms={np.std(ac):.3f} V | {row}")


if __name__ == "__main__":
    main()
