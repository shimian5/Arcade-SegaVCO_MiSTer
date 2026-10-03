#!/usr/bin/env python3
"""Label strong lines of the cabinet (763-767 s) and of the RTL engine tap as i*T + j*IC7 + k*S combinations.

usage: playercar_lattice_compare.py RTL_WAV_DIR CAB_WAV
  RTL_WAV_DIR: sim output dir with turbo_playercar_dcblock_f_scen35.wav (steady engine, ACC42)
  CAB_WAV: mono 8 kHz wav of turbo_cabinet_recording.weba starting at 700 s (scratchpad weba_700_820.wav)
Cabinet fundamentals: T 326.77, IC7 385.47, S 27.594 (assignment: loaded tap, production caps, ACC42).
RTL fundamentals: T 324.4, IC7 397.3, S 27.1 (nominal).  Combination coefficients |i|,|j| <= 3, |k| <= 4.
Levels are dB relative to the strongest line in 250-900 Hz.  Only peaks within 0.15 Hz of a combination are labelled.
"""
import itertools
import sys
from pathlib import Path

import numpy as np
import scipy.io.wavfile as w
from scipy.signal import find_peaks


def peaks(x, fs, lo=20, hi=1000, n=40, skip=0.0, rel=-40, resid=None):
    x = x[int(skip * fs):].astype(float)
    N = 1 << 19
    S = np.abs(np.fft.rfft(x * np.hanning(len(x)), N))
    f = np.fft.rfftfreq(N, 1 / fs)
    if resid is not None:
        S = np.maximum(S - resid, 0)
    ref = S[(f > 250) & (f < 900)].max()
    m = (f > lo) & (f < hi)
    pk, _ = find_peaks(S[m], height=ref * 10 ** (rel / 20), distance=int(1.0 / f[1]))
    idx = sorted(pk, key=lambda i: -S[m][i])[:n]
    return [(float(f[m][i]), float(20 * np.log10(S[m][i] / ref))) for i in idx]


def label(fr, T, F7, S, tol=0.15):
    best = None
    for i, j, k in itertools.product(range(-3, 4), range(-3, 4), range(-4, 5)):
        v = i * T + j * F7 + k * S
        if v <= 0:
            continue
        e = abs(v - fr)
        cost = abs(i) + abs(j) + abs(k)
        if e <= tol and (best is None or cost < best[1]):
            best = ((i, j, k), cost, e)
    return best


def show(name, pk, T, F7, S):
    print(f"--- {name}  (T {T}, IC7 {F7}, S {S})")
    for fr, db in sorted(pk, key=lambda p: -p[1])[:24]:
        b = label(fr, T, F7, S)
        lab = f"{b[0][0]:+d}T{b[0][1]:+d}I{b[0][2]:+d}S" if b else "-"
        print(f"  {fr:8.2f} Hz {db:6.1f} dB  {lab}")


def main():
    rtl_dir, cab = Path(sys.argv[1]), Path(sys.argv[2])
    fs, x = w.read(rtl_dir / "turbo_playercar_dcblock_f_scen35.wav")
    show("RTL dcblock_f", peaks(x, fs, skip=1.0), 324.4, 397.3, 27.1)
    fs2, y = w.read(cab)
    seg = y[int((763 - 700) * fs2):int((767 - 700) * fs2)].astype(float) / 32768
    N = 1 << 19
    meds = np.median(np.stack([np.abs(np.fft.rfft(y[int((t - 700) * fs2):int((t + 4 - 700) * fs2)].astype(float) / 32768 *
                                                   np.hanning(int(4 * fs2)), N)) for t in (738, 742, 746, 750, 754, 758, 769, 773, 777, 781, 785)]), axis=0)
    show("cabinet 763-767 s (median-subtracted)", peaks(seg, fs2, resid=meds), 326.77, 385.47, 27.594)


if __name__ == "__main__":
    main()
