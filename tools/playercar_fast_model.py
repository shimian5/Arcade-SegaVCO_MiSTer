#!/usr/bin/env python3
"""Vectorized numpy mirror of the RTL MYCAR carrier chain (D-8/11) for fast closed-loop work.

Mirrors turbo_playercar_mycarsource.sv + the IC17 block of turbo_playercar_chan.sv at the
48-kHz sample level, using the RTL's own generated tables (tools/gen_playercar_ic17_tables.py):

  cells      : phase-accumulated asymmetric triangles sampled at sample_ce (tone 1.25, sub/IC7 1.203125 ramp ratios)
  node       : max of {233/256*(t-VF), 233/256*(s-VF), 61/128*((t-VF)+(s-VF))}, C76 = 14/65536 one-pole high-pass
  IC17 gain  : CLAMP_DC(V_ladder) + mean - V_ic7 -> 1/64-V bins -> GAIN17_LUT_Q16
  output     : sat16(node_ac * gain >> 16)

Free knobs (all default to the current RTL):  bus factor per cell (divided 0.7614 or raw 1.0) and
multiplicative scales, so alternative wirings/values can be tried in ~0.3 s per render.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_playercar_ic17_tables as G          # noqa: E402
import playercar_d8_ic17_reference as R        # noqa: E402

FS = 47_998.875
DIV = R.BUS_DIVIDER
TH_LO, TH_HI = 3.9735, 7.5199
VF = 0.70
RATIO_TONE, RATIO_SUB = 1.25, 1.203125

_block, _sub_block, _sub_lut, _ic7_lut, _clamp_lut, _gain_lut = G.build()
CLAMP = np.array(_clamp_lut, float) / 4096.0
GAIN17 = np.array(_gain_lut, float) / 65536.0
STEP_SCALE = (G.TH_HI - G.TH_LO) * (1 + 1 / 1.203125) / G.CLK   # steps per Hz for ratio 1.203125


def tri(phase: np.ndarray, ratio: float) -> np.ndarray:
    duty = (1.0 / ratio) / (1.0 + 1.0 / ratio)
    up = TH_LO + (TH_HI - TH_LO) * phase / duty
    dn = TH_HI - (TH_HI - TH_LO) * (phase - duty) / (1.0 - duty)
    return np.where(phase < duty, up, dn)


def phases(f_hz: np.ndarray | float, n: int, p0: float = 0.0) -> np.ndarray:
    f = np.broadcast_to(np.asarray(f_hz, float), (n,))
    return (p0 + np.cumsum(f) / FS) % 1.0


def model(acc: float | np.ndarray, secs: float = 4.0, *, dT: float = DIV, dS: float = DIV, d7: float = DIV,
          t_scale: float = 1.0, s_scale: float = 1.0, f7_scale: float = 1.0, k_sub: float = R.K_SUB_SCHEM,
          seed: int = 0, gating: bool = True):
    """acc may be an int (held) or a per-sample array of ladder volts if given as ('v', array)."""
    n = int(secs * FS)
    vl = R.ladder_v(int(acc)) if np.isscalar(acc) else np.asarray(acc, float)
    rng = np.random.default_rng(seed)
    fT = R.K_TONE * dT * vl * t_scale
    fS = k_sub * dS * vl * s_scale
    f7 = R.K_IC7 * d7 * vl * f7_scale
    t = tri(phases(fT, n, rng.random()), RATIO_TONE)
    s = tri(phases(fS, n, rng.random()), RATIO_SUB)
    v7 = tri(phases(f7, n, rng.random()), RATIO_SUB)
    a, b = 233 / 256, 61 / 128
    td, sd = t - VF, s - VF
    node = np.maximum(np.maximum(a * td, a * sd), b * (td + sd))
    node = np.clip(node, 0, 10.5)
    # C76: node_ac = node - lowpass(node), pole 14/65536 per sample
    from scipy.signal import lfilter
    alpha = 14.0 / 65536.0
    lp = lfilter([alpha], [1, -(1 - alpha)], node)
    node_ac = node - lp
    if not gating:
        return node_ac * 4096.0, dict(fT=np.mean(fT), fS=np.mean(fS), f7=np.mean(f7))
    idx = np.clip(np.floor(np.mean(vl) * 16), 0, 191).astype(int) if np.isscalar(acc) else np.clip((vl * 16).astype(int), 0, 191)
    v2 = CLAMP[idx] + 0.5 * (TH_LO + TH_HI) - v7
    gi = np.clip(np.floor((v2 - 3.0) * 64), 0, 192).astype(int)
    out = node_ac * 4096.0 * GAIN17[gi]
    return np.clip(out, -32768, 32767), dict(fT=float(np.mean(fT)), fS=float(np.mean(fS)), f7=float(np.mean(f7)))


def lines(x: np.ndarray, lo=50, hi=1500, rel_db=-34, skip=0.5):
    x = x[int(skip * FS):]
    N = 1 << 19
    S = np.abs(np.fft.rfft(x * np.hanning(len(x)), N)); f = np.fft.rfftfreq(N, 1 / FS)
    m = (f > lo) & (f < hi)
    from scipy.signal import find_peaks
    p, _ = find_peaks(S[m], height=S[m].max() * 10 ** (rel_db / 20), distance=int(2.5 / f[1]))
    return f[m][p], 20 * np.log10(S[m][p] / S[m].max())


def env_lines(x: np.ndarray, lo, hi, maxmod=200.0, skip=0.4):
    from scipy.signal import butter, filtfilt, hilbert, find_peaks
    b, a = butter(4, [lo, hi], "bandpass", fs=FS)
    y = filtfilt(b, a, x)
    env = np.abs(hilbert(y))[int(skip * FS):-int(0.15 * FS)]
    env = env / env.mean() - 1
    E = np.abs(np.fft.rfft(env * np.hanning(len(env)), 1 << 20)) / len(env) * 4
    fe = np.fft.rfftfreq(1 << 20, 1 / FS)
    m = (fe > 0.8) & (fe < maxmod)
    p, _ = find_peaks(E[m], height=E[m].max() * 0.2, distance=int(1.2 / fe[1]))
    return sorted([(round(float(fe[m][i]), 2), round(100 * float(E[m][i]), 1)) for i in p], key=lambda z: -z[1])


if __name__ == "__main__":
    import time
    t0 = time.time()
    x, info = model(42, 4.0)
    print("render 4 s in", round(time.time() - t0, 2), "s", info)
    fr, lv = lines(x)
    print("lines >-16 dB:", [(round(a, 1), round(b, 1)) for a, b in zip(fr, lv) if b > -16][:24])
