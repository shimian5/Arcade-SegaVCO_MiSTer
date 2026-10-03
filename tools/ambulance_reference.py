#!/usr/bin/env python3
"""Schematic-derived model of the D-10/11 ambulance oscillators (no fitted constants).

IC9 555 (R90 6.2k charge via D20 || R124, R124 330k discharge, C38 1.5 uF, 4..8 V) -> IC71 follower
-> Vin.  Vin drives two relaxation cells (integrator + Schmitt with TR current sink):
  cell 1 (IC11 A/B): R134 30k, R133/R132 30k/30k half-bias, C44 0.033 uF, R135 9.9k sink
  cell 2 (IC4 A/B) : R18 30k, R17/R16 30k/30k, C3+C4 0.0288 uF, R60 15k sink
  Schmitt: R104 47k to 6 V, R102 120k feedback, output 0..10.5 V -> thresholds 4.311..7.266 V
Squares go through R101 82k / R105 68k (+ C31/C14) and R100/R61 33k into IC11-C (R99 5.1k, inverting).
"""
import math, numpy as np

FS = 47_998.875
VOH, VOL = 10.5, 0.0
V_TH_LO = 6 + (VOL - 6) * 47 / 167
V_TH_HI = 6 + (VOH - 6) * 47 / 167
DV = V_TH_HI - V_TH_LO
R90, R124, C38, VD, VCC = 6.2e3, 330e3, 1.5e-6, 0.6, 12.0


def cell_rates(r_in, c, r_sink):
    """u-per-second per volt of Vin for the charge phase (output low) and sink phase (output high)."""
    a = 1.0 / (2 * r_in) if False else 1.0 / (2 * r_in)          # half-bias: Vin/2 across r_in
    i_chg = 1.0 / (2 * r_in)                                      # A per V
    i_snk = 1.0 / (2 * r_sink)
    return i_chg / (c * DV), (i_snk - i_chg) / (c * DV)


CELL1 = cell_rates(30e3, 0.033e-6, 9.9e3)
CELL2 = cell_rates(30e3, 0.0288e-6, 15e3)


def vin_wave(n):
    v = np.empty(n); x = 6.0; charging = False
    for i in range(n):
        if charging:
            x += (VCC - VD - x) * (1 / FS) / (R90 * C38)
            if x >= 8.0: charging = False
        else:
            x -= x * (1 / FS) / (R124 * C38)
            if x <= 4.0: charging = True
        v[i] = x
    return v


def cell(vin, rates):
    n = len(vin); u = 0.5; up = True; out = np.empty(n)
    for i in range(n):
        r = rates[1] if up else rates[0]
        u += (r * vin[i]) / FS * (1 if up else -1) * (-1 if False else 1) if False else 0
        if up: u += rates[1] * vin[i] / FS
        else: u -= rates[0] * vin[i] / FS
        if u >= 1.0: u = 1.0; up = False
        elif u <= 0.0: u = 0.0; up = True
        out[i] = VOH if up else VOL
    return out


def render(secs=3.0):
    n = int(secs * FS)
    vin = vin_wave(n)
    s1, s2 = cell(vin, CELL1), cell(vin, CELL2)
    g1, g2 = 5.1 / (82 + 33), 5.1 / (68 + 33)
    a1, a2 = (s1 - s1.mean()) * g1, (s2 - s2.mean()) * g2
    return vin, s1, s2, a1 + a2


if __name__ == "__main__":
    print("thresholds", V_TH_LO, V_TH_HI, "cell1", CELL1, "cell2", CELL2)
    vin, s1, s2, y = render(2.0)
    print("Vin range", vin.min(), vin.max(), "period estimate s:",
          (np.argmax(np.diff((vin > 7.9).astype(int)) == 1) if False else ""))
    up = np.where(np.diff((vin > 7.99).astype(int)) == 1)[0]
    print("rises at", up[:6] / FS)
    for name, s, k in (("cell1", s1, CELL1), ("cell2", s2, CELL2)):
        for v in (8.0, 4.0):
            per = (1 / (k[0] * v) + 1 / (k[1] * v))
            print(name, "Vin", v, "f=%.1f Hz" % (1 / per))
