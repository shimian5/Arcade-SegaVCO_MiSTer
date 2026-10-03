#!/usr/bin/env python3
"""Small reproducible spectrum comparison for the 2026-08-23 PlayerCar pass."""
from __future__ import annotations

import os
import wave
import numpy as np


ROOT = os.path.dirname(os.path.dirname(__file__))
EVIDENCE = os.path.join(ROOT, "docs", "evidence")
SIM = os.path.join(ROOT, "sim", "out", "audio_overnight_20260823_final")


def read_wav(path: str) -> tuple[np.ndarray, int]:
    with wave.open(path) as w:
        x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(float)
        return x / 32768.0, w.getframerate()


def peaks(x: np.ndarray, sr: int, start: float = 0.0, end: float | None = None,
          n: int = 65536, count: int = 12) -> list[tuple[float, float]]:
    i0 = int(start * sr)
    i1 = len(x) if end is None else min(len(x), int(end * sr))
    y = x[i0:i1]
    if len(y) < n:
        y = np.pad(y, (0, n - len(y)))
    else:
        y = y[:n]
    f = np.fft.rfftfreq(n, 1.0 / sr)
    a = np.abs(np.fft.rfft(y * np.hanning(n)))
    m = (f >= 25.0) & (f <= 1200.0)
    ff, aa = f[m], a[m]
    idx = [i for i in range(1, len(aa) - 1)
           if aa[i] > aa[i - 1] and aa[i] >= aa[i + 1]]
    idx.sort(key=lambda i: aa[i], reverse=True)
    return [(float(ff[i]), float(20.0 * np.log10(max(aa[i], 1e-12)))) for i in idx[:count]]


def line(x: np.ndarray, sr: int, label: str, start: float, end: float) -> None:
    print(f"{label} {start:.3f}-{end:.3f}s:",
          ", ".join(f"{f:.1f}Hz/{db:.1f}dB" for f, db in peaks(x, sr, start, end)))


def main() -> None:
    video_full, sr_v = read_wav(os.path.join(EVIDENCE, "videoplayback_fullspeed_0756_0801.wav"))
    video_acc, sr_a = read_wav(os.path.join(EVIDENCE, "videoplayback_accel_0814_0816.wav"))
    sim_f, sr_s = read_wav(os.path.join(SIM, "turbo_playercar_f_scen29.wav"))
    sim_raw, _ = read_wav(os.path.join(SIM, "turbo_playercar_raw_scen29.wav"))
    print(f"video_full sr={sr_v} rms={np.sqrt(np.mean(video_full**2)):.6f}")
    print(f"video_acc  sr={sr_a} rms={np.sqrt(np.mean(video_acc**2)):.6f}")
    print(f"sim_f      sr={sr_s} rms={np.sqrt(np.mean(sim_f**2)):.6f}")
    line(video_full, sr_v, "video-full", 0.0, 5.0)
    line(video_full, sr_v, "video-full", 2.0, 3.0)
    line(video_acc, sr_a, "video-acc ", 0.0, 1.0)
    # Scenario 29 capture begins at ACC0 and advances every 300 ms. The final
    # ACC63 plateau occupies approximately 2.1-2.4 s of the captured window.
    line(sim_f, sr_s, "sim-f     ", 2.10, 2.40)
    line(sim_raw, sr_s, "sim-raw   ", 2.10, 2.40)
    line(sim_f, sr_s, "sim-f     ", 0.0, 0.3)


if __name__ == "__main__":
    main()
