#!/usr/bin/env python3
"""Sensitivity sweep: which IC17-upper gate softness / offset reproduces the cabinet's IC7-line ratios?

The MB4391 is an undocumented Sega part, so its control law (window centre and width) and its input-referred
offset Vos are DEVICE unknowns, not board parts.  Model: out = (node_ac + Vos) * g(v2), with a linear-in-voltage
gate g = clip((c + w/2 - v2)/w, 0, 1) (window centre c, width w) and v2 the IC7-C output as in the RTL.
Production timing population, divided unloaded bus, ACC42.

Cabinet ratios (763-767 s, dB re T): f7 +5.0, T+f7 -12.6, f7-T -7.9, 2T -10.1, 2f7 -17.8.
This reports the RMS dB error of the model against those five and the best few grid points.  It is a search over
device unknowns, so any 'good' point is a hypothesis to cross-check on other recordings, not a proposed constant.
"""
import sys
from pathlib import Path

import numpy as np
from scipy.signal import lfilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
import playercar_fast_model as M      # noqa: E402
import playercar_d8_ic17_reference as R  # noqa: E402
import gen_playercar_ic17_tables as G  # noqa: E402

FS = M.FS
CAB = {"f7": 5.0, "T+f7": -12.6, "f7-T": -7.9, "2T": -10.1, "2f7": -17.8}


def base(acc, secs=3.0, seed=1):
    n = int(secs * FS)
    vl = R.ladder_v(acc)
    rng = np.random.default_rng(seed)
    T, S, F7 = R.K_TONE * M.DIV * vl, G.K_SUB * M.DIV * vl, G.K_IC7 * M.DIV * vl
    t = M.tri(M.phases(T, n, rng.random()), M.RATIO_TONE)
    s = M.tri(M.phases(S, n, rng.random()), M.RATIO_SUB)
    v7 = M.tri(M.phases(F7, n, rng.random()), M.RATIO_SUB)
    a, b = 233 / 256, 61 / 128
    td, sd = t - M.VF, s - M.VF
    node = np.clip(np.maximum(np.maximum(a * td, a * sd), b * (td + sd)), 0, 10.5)
    node_ac = node - lfilter([14 / 65536], [1, -(1 - 14 / 65536)], node)
    idx = int(np.clip(np.floor(vl * 16), 0, 191))
    v2 = M.CLAMP[idx] + 0.5 * (M.TH_LO + M.TH_HI) - v7
    return node_ac, v2, dict(T=T, S=S, f7=F7)


def lev(x, f0, bw=1.5, skip=0.6):
    x = x[int(skip * FS):]
    N = 1 << 18
    S = np.abs(np.fft.rfft(x * np.hanning(len(x)), N))
    f = np.fft.rfftfreq(N, 1 / FS)
    m = (f > f0 - bw) & (f < f0 + bw)
    return S[m].max()


def score(node_ac, v2, fr, c, w, vos):
    g = np.clip((c + w / 2 - v2) / w, 0.0, 1.0)
    out = (node_ac + vos) * g
    T, F7 = fr["T"], fr["f7"]
    ref = lev(out, T)
    pts = {"f7": F7, "T+f7": T + F7, "f7-T": F7 - T, "2T": 2 * T, "2f7": 2 * F7}
    m = {k: 20 * np.log10(lev(out, f) / ref) for k, f in pts.items()}
    err = np.sqrt(np.mean([(m[k] - CAB[k]) ** 2 for k in CAB]))
    return err, m


def main():
    acc = int(sys.argv[1]) if len(sys.argv) > 1 else 42
    node_ac, v2, fr = base(acc)
    print(f"ACC{acc}: T={fr['T']:.1f} S={fr['S']:.2f} f7={fr['f7']:.1f}; CONT range {v2.min():.2f}..{v2.max():.2f} V")
    res = []
    for c in (3.6, 4.0, 4.4, 4.8, 5.2):
        for w in (0.6, 1.2, 2.0, 3.0, 4.5, 7.0):
            for vos in (0.0, 0.02, 0.05, 0.1, 0.2):
                e, m = score(node_ac, v2, fr, c, w, vos)
                res.append((e, c, w, vos, m))
    res.sort(key=lambda r: r[0])
    for e, c, w, vos, m in res[:8]:
        print(f"err {e:5.1f} dB  centre {c:.1f} V width {w:.1f} V Vos {vos:.2f} V | " + "  ".join(f"{k}:{v:6.1f}" for k, v in m.items()))
    print("cabinet:", CAB)
    print("baseline MC3340-like sharp gate (c 3.9, w 0.8, vos 0):", score(node_ac, v2, fr, 3.9, 0.8, 0.0)[0])


if __name__ == "__main__":
    main()
