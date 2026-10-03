#!/usr/bin/env python3
"""Compare the RTL's SLF (lower branch) spectrum with the schematic prediction and the cabinet.

usage: playercar_slf_spectrum_check.py OUT_DIR [ACC]
  OUT_DIR holds turbo_playercar_slf_scen35.wav, turbo_audio_l_scen35.wav, turbo_playercar_dcblock_f_scen35.wav
Predicted (ideal, raw ladder): f3 = 2.901*V, f5 = 5.138*V, lines f3+f5, 2*f5-f3, f5-f3, 2*f5, ...
Cabinet (763-767 s): 58.69 Hz (-4.3 dB re T), 117.4 Hz (-2.5 dB), 55.19 Hz, 23.2 Hz comb.
"""
import sys
from pathlib import Path

import numpy as np
import scipy.io.wavfile as w
from scipy.signal import find_peaks

sys.path.insert(0, str(Path(__file__).resolve().parent))
import playercar_d8_ic17_reference as R  # noqa: E402


def spec(x, fs, t0=1.0):
    x = x[int(t0 * fs):].astype(float)
    N = 1 << 19
    S = np.abs(np.fft.rfft(x * np.hanning(len(x)), N))
    return S, np.fft.rfftfreq(N, 1 / fs)


def top_lines(S, f, lo, hi, n=10, rel_db=-30):
    m = (f > lo) & (f < hi)
    pk, _ = find_peaks(S[m], height=S[m].max() * 10 ** (rel_db / 20), distance=int(1.5 / f[1]))
    idx = sorted(pk, key=lambda i: -S[m][i])[:n]
    return [(round(float(f[m][i]), 2), round(float(20 * np.log10(S[m][i] / S[m].max())), 1)) for i in idx]


def main():
    d = Path(sys.argv[1]); acc = int(sys.argv[2]) if len(sys.argv) > 2 else 42
    V = R.ladder_v(acc)
    f3, f5 = 2.901 * V, 5.138 * V
    print(f"ACC{acc}: raw ladder {V:.3f} V, ideal f3={f3:.2f} f5={f5:.2f} Hz; f3+f5={f3+f5:.2f}, 2f5-f3={2*f5-f3:.2f}, f5-f3={f5-f3:.2f}")
    fs, slf = w.read(d / "turbo_playercar_slf_scen35.wav")
    S, f = spec(slf, fs)
    print("SLF tap top lines (Hz, dB re strongest):", top_lines(S, f, 5, 300, 12))
    for name in ("turbo_audio_l_scen35.wav", "turbo_playercar_dcblock_f_scen35.wav"):
        fs2, y = w.read(d / name)
        S2, f2 = spec(y, fs2)
        ref_lines = top_lines(S2, f2, 250, 900, 3)
        ref = S2[(f2 > 250) & (f2 < 900)].max()
        def lvl(fc, bw=1.0):
            m = (f2 > fc - bw) & (f2 < fc + bw)
            return round(float(20 * np.log10(S2[m].max() / ref)), 1)
        print(name, "strongest upper lines:", ref_lines)
        print("   level re strongest 250-900 Hz line: ",
              {f"{fc:.2f}": lvl(fc) for fc in (f3 + f5, 2 * f5 - f3, f5 - f3, 2 * (f3 + f5), f3, f5, 58.69, 55.19, 117.38)})


if __name__ == "__main__":
    main()
