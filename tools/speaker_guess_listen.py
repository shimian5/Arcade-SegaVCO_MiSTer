#!/usr/bin/env python3
"""Presentation-only GUESS of a 30 cm woofer in a cabinet (Sega 130-0022, 8 ohm, 40 W) applied to WAV files.

NOT derived from the board: no Thiele-Small data exists for the part.  Assumed: sealed-box high-pass 2nd order
(fc 55 Hz, Q 0.8), cone low-pass 2nd order (fc 2.5 kHz), optional small-room tail (RT60 0.35 s, wet -14 dB).
usage: speaker_guess_listen.py OUT_DIR SRC.wav[@start@end] ...   -> OUT_DIR/<name>_raw.wav, _woofer.wav, _woofer_room.wav
"""
import sys
from pathlib import Path
import numpy as np
import scipy.io.wavfile as w
from scipy.signal import butter, sosfilt, fftconvolve

FC_HP, Q_HP, FC_LP, RT60, WET_DB = 55.0, 0.8, 2500.0, 0.35, -14.0


def sos_hp2(fc, q, fs):
    W = 2 * np.pi * fc / fs; a = np.sin(W) / (2 * q); c = np.cos(W)
    b = np.array([(1 + c) / 2, -(1 + c), (1 + c) / 2]); den = np.array([1 + a, -2 * c, 1 - a])
    return np.array([np.r_[b, den] / den[0]])


def woofer(x, fs):
    y = sosfilt(sos_hp2(FC_HP, Q_HP, fs), x)
    return sosfilt(butter(2, FC_LP, "low", fs=fs, output="sos"), y)


def room(x, fs):
    rng = np.random.default_rng(3); n = int(RT60 * fs)
    ir = rng.standard_normal(n) * np.exp(-6.91 * np.arange(n) / n); ir /= np.sqrt((ir ** 2).sum())
    wet = fftconvolve(x, ir)[:len(x)]
    return x + wet * 10 ** (WET_DB / 20)


def norm(x, target=0.1):
    return x * target / np.sqrt((x ** 2).mean())


def main():
    out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
    for spec in sys.argv[2:]:
        p, *t = spec.split("@"); fs, x = w.read(p); x = x.astype(float)
        if x.ndim > 1: x = x.mean(1)
        if t: x = x[int(float(t[0]) * fs):int(float(t[1]) * fs)]
        x /= 32768.0 if np.abs(x).max() > 2 else 1.0
        name = Path(p).stem
        for tag, y in (("raw", x), ("woofer", woofer(x, fs)), ("woofer_room", room(woofer(x, fs), fs))):
            w.write(out / f"{name}_{tag}.wav", fs, (np.clip(norm(y), -1, 1) * 32767).astype(np.int16))
    print("wrote", out)


if __name__ == "__main__":
    main()
