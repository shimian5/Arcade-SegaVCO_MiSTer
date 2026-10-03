#!/usr/bin/env python3
"""Sensitivity probe: does the IC17-upper VCA need control FEEDTHROUGH and/or a steeper gain law to show
the cabinet's IC7-related lines?  Production timing population (C18, C20 unfitted), divided bus 0.7614.

Both knobs are DEVICE properties of the unknown MB4391 (its control law and its CONT->OUT leakage), not board
parts.  This script only reports which one produces the cabinet's line STRUCTURE; it proposes no RTL constant.

  gate power p : gain = GAIN17_LUT[idx] ** p   (p=1 is the MC3340 data-sheet law; p>1 steeper, p<1 softer)
  feedthrough k: output += k * (IC7 triangle AC, volts) * 4096   (leakage of the CONT signal into OUT)

Prints line levels in dB relative to the tone T.  Cabinet (763-767 s residual): 444.16 Hz ~ +5 dB over 357.86 Hz,
743.33 ~ +4.7 dB, i.e. IC7-related lines are as strong as the tone.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import playercar_fast_model as M      # noqa: E402
import playercar_d8_ic17_reference as R  # noqa: E402
import gen_playercar_ic17_tables as G  # noqa: E402

FS = M.FS


def render(acc, secs, p, k, seed=1, comp=False, law="mc3340", comp2=False):
    n = int(secs * FS)
    vl = R.ladder_v(acc)
    rng = np.random.default_rng(seed)
    fT = R.K_TONE * M.DIV * vl
    fS = G.K_SUB * M.DIV * vl
    f7 = G.K_IC7 * M.DIV * vl
    t = M.tri(M.phases(fT, n, rng.random()), M.RATIO_TONE)
    s = M.tri(M.phases(fS, n, rng.random()), M.RATIO_SUB)
    v7 = M.tri(M.phases(f7, n, rng.random()), M.RATIO_SUB)
    a, b = 233 / 256, 61 / 128
    td, sd = t - M.VF, s - M.VF
    node = np.clip(np.maximum(np.maximum(a * td, a * sd), b * (td + sd)), 0, 10.5)
    from scipy.signal import lfilter
    alpha = 14.0 / 65536.0
    node_ac = node - lfilter([alpha], [1, -(1 - alpha)], node)
    idx = int(np.clip(np.floor(vl * 16), 0, 191))
    v2 = M.CLAMP[idx] + 0.5 * (M.TH_LO + M.TH_HI) - v7
    gi = np.clip(np.floor((v2 - 3.0) * 64), 0, 192).astype(int)
    gain = M.GAIN17[gi] ** p
    if law == "linear":   # MAME netlist guess for another Sega game (brdrline): gain linear in CONT volts, 1 at 2.84 V, 0 at 4.76 V
        gain = np.clip((4.759384 - v2) / (4.759384 - 2.839579), 0.0, 1.0)
    if comp:   # MC3340 large-signal proxy: +13 dB maximum gain, 7.3 Vpp output limit (tanh bound), volts
        v = node_ac * gain * 4.4667
        out = 3.65 * np.tanh(v / 3.65) + k * (v7 - v7.mean())
        if comp2:   # second MC3340 stage (IC28-lower, BSEL2), full gain: +13 dB again, same 7.3 Vpp limit
            out = 3.65 * np.tanh(4.4667 * out / 3.65)
    else:
        out = node_ac * gain + k * (v7 - v7.mean())
    return out, dict(T=fT, S=fS, f7=f7)


def level(x, f0, bw=1.5, skip=1.0):
    x = x[int(skip * FS):]
    N = 1 << 19
    S = np.abs(np.fft.rfft(x * np.hanning(len(x)), N))
    f = np.fft.rfftfreq(N, 1 / FS)
    m = (f > f0 - bw) & (f < f0 + bw)
    return S[m].max()


def main():
    acc = int(sys.argv[1]) if len(sys.argv) > 1 else 42
    lines = None
    print(f"production population, ACC{acc}, divided bus")
    for law in ("mc3340", "linear"):
     for comp in (False, True):
      for p in (1.0,):
        for k in (0.0,):
            x, r = render(acc, 4.0, p, k, comp=comp, law=law)
            T, S, F7 = r["T"], r["S"], r["f7"]
            probes = {"T": T, "f7": F7, "T-2S": T - 2 * S, "T+f7-2S": T + F7 - 2 * S, "2f7": 2 * F7,
                      "2T": 2 * T, "S": S, "2S": 2 * S, "T+f7": T + F7, "f7-(T-2S)": F7 - (T - 2 * S)}
            base = level(x, T)
            row = "  ".join(f"{name}:{20 * np.log10(level(x, f) / base):6.1f}" for name, f in probes.items())
            print(f"{law:6s} comp={int(comp)} k={k:4.2f}  T={T:6.1f} S={S:5.2f} f7={F7:6.1f} |  {row}")


if __name__ == "__main__":
    main()
