#!/usr/bin/env python3
"""Independent schematic-derived reference for the Turbo MYCAR carrier (sheet D-8/11).

Everything here is read from the sheet, not from the earlier RTL:

  V_lad        : IC34 7417 open-collector R-2R ladder (100k legs, 50k series, 100k
                 termination, 2.2k pull-ups to +12 V), C110 1 uF (tau ~50 ms).
  V_bus        : the TAP of the 4.7k/15k divider on IC3 pin 7 = 0.7614 * V_lad.  It
                 feeds IC6 tone cell, IC6 sub cell, IC7 cell, IC7-top follower.
  IC6 tone     : R28 270k, R31 120k, C5 4700 pF, 51k/100k Schmitt  -> f = 61.73 * V_bus
  IC6 sub      : R78 220k, R76 100k, C18+C19 0.09 uF                -> f = 3.88 * V_bus
  IC7 cell     : R87 150k, R84 68k, C20||C21 13.6 nF               -> f = 37.8 * V_bus
                 (up/down ramp ratio R87/R84 - 1 = 1.206)
  D7/D13/R79   : two MA150 into R79 10k: node = max(tone, sub) - VF
  IC7-C        : + input = bus through 10k clamped by D5/D6 to the 3.92 V midpoint of
                 R38 680 / R39 330 (12 V); - input = R36 10k from C6 (IC7 cell AC);
                 R35 10k feedback  =>  V_CONT = V_clamp - (V_ic7 - mean)
  IC17 upper   : MC3340 gain law vs V_CONT (RTL table, -40 dB/V above ~3.1 V), audio in
                 = node via C76, out -> 4016 -> C106 -> MYCAR.

Usage:  python tools/playercar_d8_ic17_reference.py --render OUT_DIR
"""
from __future__ import annotations

import argparse
import math
import os
import wave

import numpy as np

FS = 96000.0
VLO, VHI = 3.9735, 7.5199
VF = 0.70
BUS_UNLOADED = 15.0 / (4.7 + 15.0)
# DC-loaded tap: the 4.7k/15k divider also feeds, through the same vertical, the three cells' 51k+51k bias arms
# (3 x 102k) and their integrator input resistors seen as 2x their value (R28 270k, R78 220k, R87 150k -> 540k,
# 440k, 300k).  See tools/playercar_loaded_node_check.py.
_R_LOAD = 1.0 / (3 / 102e3 + 1 / 540e3 + 1 / 440e3 + 1 / 300e3)
_R_BOT = 15e3 * _R_LOAD / (15e3 + _R_LOAD)
BUS_LOADED = _R_BOT / (4.7e3 + _R_BOT)                 # 0.67267
import os as _os
BUS_MODE = _os.environ.get("PLAYERCAR_BUS", "loaded")   # "loaded" (default) or "unloaded"
BUS_DIVIDER = BUS_LOADED if BUS_MODE == "loaded" else BUS_UNLOADED
K_TONE, K_SUB_SCHEM, K_SUB_RTL, K_IC7 = 61.73, 3.88, 0.43 / BUS_DIVIDER, 37.8   # Hz per V_bus (RTL sub: 0.43 Hz per V_ladder)
TONE_RISE, SUB_RISE, IC7_RISE = 1.25, 1.20, 150.0 / 68.0 - 1.0

V_LADDER_Q12 = (
    0, 757, 1514, 2279, 3028, 3792, 4558, 5330, 6057, 6820, 7585, 8356, 9118, 9889, 10663, 11442,
    12121, 12885, 13649, 14421, 15180, 15950, 16724, 17503, 18252, 19022, 19794, 20572, 21345, 22122, 22904, 23690,
    24309, 25074, 25840, 26614, 27373, 28146, 28922, 29702, 30448, 31220, 31993, 32774, 33547, 34326, 35110, 35897,
    36629, 37401, 38174, 38955, 39725, 40504, 41287, 42075, 42844, 43622, 44404, 45191, 45975, 46760, 47552, 48346)

# MC3340 attenuation (dB) vs control voltage, nominal solid VCC=12 V curve of Motorola MC3340/D Figure 3, digitised from the
# datasheet's vector paths (2026-09-30 validation, docs/PLAYERCAR_VCO_CURVE_VALIDATION_20260930.md), sampled every 1/16 V from 3.0 V.
# Normalised so 3.0 V = 1.0 (the RTL's full-gain reference).  The old hand table was steeper (-20 dB at 3.5 V vs -14.8 dB here).
MC3340_ATT_DB = np.array([0.598, 1.032, 1.610, 2.383, 3.411, 4.927, 7.825, 11.328, 14.831, 18.334, 21.291, 24.024, 26.714, 29.356, 31.957, 34.515, 37.033, 39.511, 41.952, 44.354, 46.722, 49.054, 51.353, 53.617, 55.851, 58.052, 60.223, 62.363, 64.475, 66.558, 68.614, 70.641, 72.643, 74.618, 76.567, 78.492, 80.392, 82.268, 84.121, 85.949, 87.756, 89.243, 89.301, 89.301, 89.301, 89.301, 89.301, 89.301, 89.301], float)
MC3340 = 10.0 ** (-(MC3340_ATT_DB - MC3340_ATT_DB[0]) / 20.0)


def ladder_v(acc: int) -> float:
    return V_LADDER_Q12[acc] / 4096.0


def cell_voltage(phase: float, rise_ratio: float) -> float:
    duty = (1.0 / rise_ratio) / (1.0 + 1.0 / rise_ratio)
    if phase < duty:
        return VLO + (VHI - VLO) * phase / duty
    return VHI - (VHI - VLO) * (phase - duty) / (1.0 - duty)


def mc3340_gain(v_control):
    """Relative MC3340 attenuation law used by the RTL (1.0 at <=3 V, ~-40 dB/V above)."""
    x = np.clip((np.asarray(v_control, float) - 3.0) * 16.0, 0.0, 48.0)
    return np.interp(x, np.arange(len(MC3340)), MC3340)


def clamp_dc(vb: float) -> float:
    """IC7-C + input: bus via 10k, clamped by D5/D6 (MA150) to the R38/R39 midpoint."""
    vmid, rth, r10 = 12.0 * 330.0 / 1010.0, 680.0 * 330.0 / 1010.0, 10e3
    IS, NF, VT = 1.8e-9, 1.9, 0.02585
    vn = vmid
    for _ in range(60):
        i = (vb - vn) / r10
        vd = NF * VT * math.log(abs(i) / IS + 1.0) * (1.0 if i >= 0 else -1.0)
        vn = vmid + i * rth + vd
    return vn


_CLAMP_GRID = np.linspace(0.0, 9.0, 901)
_CLAMP_TAB = np.array([clamp_dc(v) for v in _CLAMP_GRID])


def render(acc_seq, code_ms, *, sub="schematic", gate=True, ic7_scale=1.0, tau_ms=50.0):
    """acc_seq: ACC code per step; code_ms: duration per code (list or scalar)."""
    if np.isscalar(code_ms):
        code_ms = [code_ms] * len(acc_seq)
    n_per = [int(FS * ms / 1000.0) for ms in code_ms]
    n = sum(n_per)
    a = 1.0 - math.exp(-1.0 / (FS * tau_ms / 1000.0))
    k_sub = K_SUB_SCHEM if sub == "schematic" else K_SUB_RTL
    vl = ladder_v(acc_seq[0])
    tp = sp = p7 = 0.0
    node = np.empty(n); v7 = np.empty(n); vbus = np.empty(n); tone = np.empty(n)
    i = 0
    for acc, cnt in zip(acc_seq, n_per):
        target = ladder_v(acc)
        for _ in range(cnt):
            vl += a * (target - vl)
            vb = vl * BUS_DIVIDER
            t = cell_voltage(tp, TONE_RISE); s = cell_voltage(sp, SUB_RISE)
            node[i] = max(t, s) - VF; tone[i] = t
            v7[i] = cell_voltage(p7, IC7_RISE); vbus[i] = vb
            tp = (tp + K_TONE * vb / FS) % 1.0
            sp = (sp + k_sub * vb / FS) % 1.0
            p7 = (p7 + K_IC7 * ic7_scale * vb / FS) % 1.0
            i += 1
    node_ac = node - _movavg(node, 2400)   # C76/IC17 AC coupling (~40 Hz corner ok for audio)
    v7_ac = v7 - _movavg(v7, 9600)          # C6 22 uF into R36 (sub-Hz) ~ mean removal
    vclamp = np.interp(vbus, _CLAMP_GRID, _CLAMP_TAB)
    v_control = vclamp - v7_ac
    g = mc3340_gain(v_control) if gate else np.ones(n)
    return tone - tone.mean(), node_ac, node_ac * g, g, v_control


def _movavg(x, n):
    c = np.cumsum(np.insert(x, 0, 0.0))
    y = np.empty_like(x)
    h = n // 2
    lo = np.clip(np.arange(len(x)) - h, 0, len(x)); hi = np.clip(np.arange(len(x)) + h, 0, len(x))
    return (c[hi] - c[lo]) / np.maximum(hi - lo, 1)


def write_wav(path, x, gain=1.0, sr_out=48000):
    from scipy.signal import resample_poly   # anti-aliased 96 k -> 48 k (plain decimation aliases the gating corners)
    y = resample_poly(x, 1, int(FS // sr_out)) * gain
    y = np.clip(y, -1, 1)
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr_out)
        w.writeframes((y * 32767).astype("<i2").tobytes())


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--render", metavar="OUT_DIR")
    args = ap.parse_args()
    if not args.render:
        ap.print_help(); return 0
    os.makedirs(args.render, exist_ok=True)
    codes = list(range(4, 43))
    ms = [173 - (173 - 109) * k / (len(codes) - 1) for k in range(len(codes))]
    ms += [0]
    codes += [42]
    ms[-1] = 1500.0                                                           # hold at ACC42
    cases = {"schematic_sub": dict(sub="schematic"), "rtl_fudge_sub": dict(sub="rtl")}
    ref = None
    for name, kw in cases.items():
        tone, node_ac, out, g, vc = render(codes, ms, **kw)
        if ref is None:
            ref = max(np.abs(node_ac).max(), 1e-9)
        write_wav(os.path.join(args.render, f"ic17_gated_{name}.wav"), out, 0.8 / ref)
        print(name, "rms(out)/rms(node) =", round(float(np.sqrt((out ** 2).mean()) / np.sqrt((node_ac ** 2).mean())), 3),
              " mean gain", round(float(g.mean()), 3))
    write_wav(os.path.join(args.render, "node_only_current_model.wav"), node_ac, 0.8 / ref)
    write_wav(os.path.join(args.render, "raw_tone.wav"), tone, 0.8 / ref)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
