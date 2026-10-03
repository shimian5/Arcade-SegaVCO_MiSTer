#!/usr/bin/env python3
"""Study: what do the relaxation-cell comparators' finite output slew do to each cell's rate, and how do the capacitor offsets that
reproduce the recorded cabinet's rates change once that delay is included?  (Offline modelling study, no RTL change.)

Cell (D-6/11, D-8/11): integrator + Schmitt comparator + switching transistor.  At the top trip the comparator output starts to slew
from VOH toward VOL; the transistor (base via 10k / diode / 2.2k) turns off when Vo crosses VTR (~4.2 V), so the integrator keeps ramping up for
d1 = (VOH-VTR)/SR.  At the bottom trip Vo slews from VOL toward VOH, transistor on at VTR, d2 = (VTR-VOL)/SR.  With up-slope a and
down-slope b (both proportional to 1/C) the period is
    P = W/a + W/b + d1*(1 + a/b) + d2*(1 + b/a)
so the extra term does not depend on C.  Slew-only: no overload-recovery time (not in the 1979 Fairchild / National data); SR is the
datasheets' typical 0.5 V/us (0.2 and 1.0 shown as bounds).  Nominal cell rates are the schematic values; targets are the recorded cabinet's lines.
"""
import sys

VOH, VOL, VTR = 10.5, 0.1, 4.2
# name, nominal Hz (schematic), target Hz (cabinet), up/down slope ratio a/b (up faster when >1), note
CELLS = [
    ("tone T (IC6, C5)        ", 324.30, 326.766, 1.25,   "C5 4700 pF"),
    ("sub S (IC6, C19)        ", 26.98,  27.594,  1.2031, "C19 0.068 uF"),
    ("IC7 cell (C21)          ", 397.2,  385.469, 1.2031, "C21 6.8 nF"),
    ("SLF IC3 (C7)            ", 22.66,  23.18,   1.25,   "C7 0.1 uF"),
    ("SLF IC5 (C154)          ", 40.14,  36.92,   1.2059, "C154 0.1 uF"),
    ("Other Cars A (C34)      ", 83.051, 77.130,  (1-0.4545)/0.4545, "C34 0.022 uF"),
    ("Other Cars B (C36)      ", 195.220, 202.310, (1-0.3704)/0.3704, "C36 4700 pF"),
    ("Other Cars C (C37)      ", 210.874, 202.396, (1-0.4533)/0.4533, "C37 6800 pF"),
]

def extra(ab, sr):
    d1 = (VOH - VTR) / sr * 1e-6          # seconds
    d2 = (VTR - VOL) / sr * 1e-6
    return d1 * (1 + ab) + d2 * (1 + 1 / ab)

def main():
    print("Capacitor offset needed to hit the cabinet's rate = (P_target - extra) / P_nominal_ideal - 1\n")
    print(f"{'cell':26s} {'nominal':>9s} {'target':>9s} {'no delay':>9s} | " + " | ".join(f"SR {s:3.1f} V/us: extra us, offset" for s in (0.2, 0.5, 1.0)))
    for name, fn, ft, ab, note in CELLS:
        pn, pt = 1 / fn, 1 / ft
        base = pt / pn - 1
        cols = []
        for sr in (0.2, 0.5, 1.0):
            e = extra(ab, sr)
            cols.append(f"{e*1e6:6.1f} us {((pt - e) / pn - 1) * 100:+6.2f} %")
        print(f"{name} {fn:9.3f} {ft:9.3f} {base*100:+8.2f}% | " + " | ".join(cols))
    print("\nRate lowered by the delay alone (nominal parts, SR 0.5 V/us):")
    for name, fn, ft, ab, note in CELLS:
        e = extra(ab, 0.5)
        print(f"  {name} {fn:8.2f} Hz -> {1/(1/fn+e):8.2f} Hz ({(1/(1/fn+e)/fn-1)*100:+.2f} %)")
    # warble (IC7 - T) - 2S with delay, nominal parts
    t, s, i = [1/(1/CELLS[k][1] + extra(CELLS[k][3], 0.5)) for k in (0, 1, 2)]
    print(f"\nnominal-part warble (IC7-T)-2S: ideal {397.2-324.30-2*26.98:.2f} Hz ; with 0.5 V/us delay {i-t-2*s:.2f} Hz")

if __name__ == "__main__":
    main()
