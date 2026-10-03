#!/usr/bin/env python3
"""Compare a player-car WAV and a cabinet-reference WAV in a bounded FFT window."""
from __future__ import annotations

import argparse
import math
import wave

import numpy as np


def read(path: str) -> tuple[np.ndarray, int]:
    with wave.open(path, "rb") as wav:
        data = np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2")
        if wav.getnchannels() > 1:
            data = data.reshape(-1, wav.getnchannels()).mean(axis=1)
        return data.astype(float), wav.getframerate()


def report(path: str, start: float, end: float, f0: float | None) -> None:
    data, rate = read(path)
    block = data[int(start * rate):int(end * rate)]
    block -= block.mean()
    spectrum = np.abs(np.fft.rfft(block * np.hanning(len(block))))
    freqs = np.fft.rfftfreq(len(block), 1.0 / rate)
    if f0 is None:
        mask = (freqs >= 50.0) & (freqs <= 500.0)
        f0 = float(freqs[np.where(mask)[0][np.argmax(spectrum[mask])]])
    levels = []
    for multiple in (1, 3, 5):
        index = int(np.argmin(np.abs(freqs - multiple * f0)))
        levels.append(float(spectrum[index]))
    h5_h3 = 20.0 * math.log10((levels[2] + 1e-9) / (levels[1] + 1e-9))
    print(
        f"{path}: window={start:.3f}..{end:.3f}s f0={f0:.2f}Hz "
        f"H5-H3={h5_h3:+.2f}dB rms={np.sqrt(np.mean(block * block)):.1f} "
        f"peak={np.max(np.abs(block)):.0f}"
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("start", type=float)
    ap.add_argument("end", type=float)
    ap.add_argument("--f0", type=float)
    args = ap.parse_args()
    report(args.path, args.start, args.end, args.f0)


if __name__ == "__main__":
    main()
