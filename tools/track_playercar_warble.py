#!/usr/bin/env python3
"""Track resolved odd-harmonic frequency motion without adding an audio model."""
from __future__ import annotations

import argparse
import wave

import numpy as np


def read(path: str) -> tuple[np.ndarray, int]:
    with wave.open(path, "rb") as wav:
        x = np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2")
        if wav.getnchannels() > 1:
            x = x.reshape(-1, wav.getnchannels()).mean(axis=1)
        return x.astype(float), wav.getframerate()


def track(path: str, start: float, end: float, f0: float) -> None:
    x, rate = read(path)
    x = x[int(start * rate):int(end * rate)]
    nfft = 8192
    frame = int(round(0.050 * rate))
    hop = int(round(0.010 * rate))
    window = np.hanning(frame)
    freqs = np.fft.rfftfreq(nfft, 1.0 / rate)
    rows: list[tuple[float, float, float]] = []
    for offset in range(0, max(0, len(x) - frame), hop):
        spectrum = np.abs(np.fft.rfft(x[offset:offset + frame] * window, nfft))
        values = []
        for harmonic in (3, 5):
            lo, hi = harmonic * f0 - 25.0, harmonic * f0 + 25.0
            mask = (freqs >= lo) & (freqs <= hi)
            if not np.any(mask):
                values.append(float("nan"))
            else:
                indices = np.where(mask)[0]
                values.append(float(freqs[indices[np.argmax(spectrum[indices])]] / harmonic))
        rows.append((start + (offset + frame / 2) / rate, values[0], values[1]))
    data = np.asarray(rows, dtype=float)
    for column, name in ((1, "h3"), (2, "h5")):
        finite = data[np.isfinite(data[:, column]), column]
        if len(finite):
            print(
                f"{name}: n={len(finite)} median={np.median(finite):.3f}Hz "
                f"min={np.min(finite):.3f} max={np.max(finite):.3f} "
                f"std={np.std(finite):.3f} peak_to_peak={np.ptp(finite):.3f}"
            )
    if len(data):
        print("samples (time,h3_f0,h5_f0):")
        for row in data[::max(1, len(data) // 20)]:
            print(f"  {row[0]:.3f} {row[1]:.3f} {row[2]:.3f}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("path")
    ap.add_argument("start", type=float)
    ap.add_argument("end", type=float)
    ap.add_argument("--f0", type=float, required=True)
    args = ap.parse_args()
    print(f"{args.path}: {args.start:.3f}..{args.end:.3f}s reference f0={args.f0:.3f}Hz")
    track(args.path, args.start, args.end, args.f0)


if __name__ == "__main__":
    main()
