#!/usr/bin/env python3
"""Bit-style mirror of the SKID FM chain (D-3/11) to choose shift/add coefficients before writing RTL.

IC1-A relaxation oscillator (R1 100k / R2 51k threshold network, R43 6.8k / C9 6.8 uF) -> buffer -> IC1-B summer
(-(10/68)*(C9-6) - 0.05*noise) -> 22 uF into IC37 CONT (3.333 k / 3.333 V Thevenin) -> NE555 astable (47k+68k charge, 68k discharge,
C130 0.01 uF) with thresholds CONT and CONT/2.  All voltages Q16.  Rates are exact exponential steps at fs = 47,998.875 Hz.
"""
import math, sys
import numpy as np

FS = 47998.875
Q = 1 << 24                   # Q24 volts (32-bit signed holds 10.5 V)
# exact exponential coefficients
a_c9 = 1 - math.exp(-1 / (FS * 6.8e3 * 6.8e-6))
a_c = 1 - math.exp(-1 / (FS * 115e3 * 0.01e-6))
a_d = 1 - math.exp(-1 / (FS * 68e3 * 0.01e-6))
a_hp = 1 - math.exp(-2 * math.pi * 2.17 / FS)

def shifts(target, terms=5):
    """Greedy signed power-of-two decomposition of a positive coefficient."""
    out, rem = [], target
    for _ in range(terms):
        k = round(-math.log2(abs(rem)))
        s = 1 if rem > 0 else -1
        out.append((s, k)); rem -= s * 2.0 ** -k
        if abs(rem) < target * 1e-4: break
    return out

def apply(v, sh):  # integer shift/add (arithmetic shifts, like the RTL)
    return sum(s * (v >> k) for s, k in sh)

C9SH, CSH, DSH, HPSH = shifts(a_c9), shifts(a_c), shifts(a_d), shifts(a_hp)
SLOW = [(1, 3), (1, 6), (1, 8), (1, 9)]       # 0.125+0.015625+0.00390625+0.001953 = 0.146484 ~ 10/68
NOI  = [(1, 5), (1, 6), (1, 9), (1, 11)]      # 0.03125+0.015625+0.001953+0.000488 = 0.049316 ~ 0.05

def run(seconds, noise=None, fm=True, trace=False):
    n = int(seconds * FS)
    vc9 = int(6.0 * Q); out14 = 1                     # C9 starts mid, comparator high
    vt = int(2.0 * Q); hi = 1
    hp_y = 0; x_prev = 0
    sq = np.zeros(n, np.int32); vcon_t = np.zeros(n, np.int32)
    VOH, VOL = int(10.5 * Q), int(0.02 * Q)
    flips = []
    for i in range(n):
        # IC1-A: C9 charges toward Vout through R43
        tgt = VOH if out14 else VOL
        d = tgt - vc9; vc9 += apply(d, C9SH)
        th = (100 * int(6 * Q) + 51 * (VOH if out14 else VOL)) // 151
        if out14 and vc9 >= th: out14 = 0
        elif (not out14) and vc9 <= th: out14 = 1
        # IC1-B output (AC about its bias), volts Q16
        n_q16 = (int(noise[i]) << 12) if noise is not None else 0    # noise_in Q12 -> Q24
        x = -apply(vc9 - int(5.75 * Q), SLOW) - apply(n_q16, NOI) if fm else 0
        # 22 uF coupling into CONT: first-order high-pass
        hp_y = hp_y + (x - x_prev) - apply(hp_y, HPSH); x_prev = x
        vcon = int(3.3333 * Q) + hp_y
        up, lo = vcon, vcon >> 1
        # NE555 timing node
        if hi:
            vt += apply(int(5.0 * Q) - vt, CSH)
            if vt >= up:                       # carry the overshoot into the discharge phase (rate ratio ~3.375 at nominal CONT)
                e = vt - up; hi = 0; vt = up - ((e << 1) + e + (e >> 2) + (e >> 3))
        else:
            vt += apply(0 - vt, DSH)
            if vt <= lo:                       # carry into the charge phase (rate ratio ~1.17)
                e = lo - vt; hi = 1; vt = lo + (e + (e >> 3) + (e >> 5) + (e >> 6))
        sq[i] = hi; vcon_t[i] = vcon
        if trace and i and sq[i] != sq[i-1]: flips.append(i)
    return sq, vcon_t

if __name__ == "__main__":
    print("coefficients: c9", a_c9, C9SH, "\n charge", a_c, CSH, "\n discharge", a_d, DSH, "\n hp", a_hp, HPSH)
    sq, vcon = run(1.0, fm=False)
    rises = np.flatnonzero(np.diff(sq) == 1)
    f = FS / np.mean(np.diff(rises)); duty = sq[2000:].mean()
    print(f"no FM: carrier {f:.2f} Hz (analytic 788.36), high duty {duty:.3f} (analytic 0.628)")
    sq, vcon = run(2.0, fm=True)
    rises = np.flatnonzero(np.diff(sq) == 1); inst = FS / np.diff(rises)
    print(f"slow FM only: carrier mean {inst.mean():.1f} Hz, min {inst.min():.1f}, max {inst.max():.1f}; CONT AC pk-pk {(vcon.max()-vcon.min())/Q:.3f} V")
