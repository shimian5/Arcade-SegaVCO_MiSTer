#!/usr/bin/env python3
"""Deterministic FFT report for the settled scenario-29 ACC36 plateau.

The scenario has eight 300-ms ACC plateaus after a 10-ms lead-in.  The
acceptance window is deliberately inside the fifth plateau (ACC36), after the
50-ms C110 settling guard used by the scenario and before its next code.
"""
from __future__ import annotations

import math
import os
import wave

import numpy as np


BASE = os.environ.get("PLAYER_CAR_WAV_BASE", os.path.join("sim", "out", "audio"))
FILES = (
    "turbo_playercar_raw_scen29.wav",
    "turbo_playercar_shaped_scen29.wav",
    "turbo_playercar_f_scen29.wav",
    "turbo_playercar_w_scen29.wav",
    "turbo_playercar_m_scen29.wav",
    "turbo_playercar_dcblock_f_scen29.wav",
    "turbo_playercar_dcblock_w_scen29.wav",
)


def read(path: str) -> tuple[np.ndarray, int]:
    with wave.open(path, "rb") as wav:
        return (
            np.frombuffer(wav.readframes(wav.getnframes()), dtype="<i2").astype(float),
            wav.getframerate(),
        )


def db(value: float, reference: float) -> float:
    return 20.0 * math.log10((value + 1.0e-12) / (reference + 1.0e-12))


def harmonic_report(block: np.ndarray, rate: int, f0: float) -> dict[int, float]:
    """Return H1..H9 magnitudes from a fixed settled window."""
    spectrum = np.abs(np.fft.rfft(block * np.hanning(len(block))))
    freqs = np.fft.rfftfreq(len(block), 1.0 / rate)
    return {
        multiple: float(spectrum[int(np.argmin(np.abs(freqs - multiple * f0)))])
        for multiple in (1, 2, 3, 5, 7, 9)
    }


def main() -> None:
    # Scenario 29 records 10 ms plus eight 300-ms ACC plateaus.  ACC36 is the
    # fifth plateau (1.210..1.510 s); use its final 100 ms so the 50-ms
    # one-pole transition guard is excluded.  The derived IC6/C5 law gives
    # ACC36's nominal line at 61.73*(15/19.7)*(27373/4096) ~= 314.1 Hz
    # (the IC6 cell hangs on the 4.7k/15k divider tap, sheet D-8/11).
    start_s, end_s, f0 = 1.41, 1.51, 61.73 * (15.0 / 19.7) * (27373.0 / 4096.0)
    print(f"ACC36 settled window {start_s:.2f}..{end_s:.2f} s, f0~{f0:.1f} Hz")
    for name in FILES:
        data, rate = read(os.path.join(BASE, name))
        block = data[int(start_s * rate):int(end_s * rate)]
        block -= block.mean()
        harmonic = harmonic_report(block, rate, f0)
        h1 = harmonic[1]
        print(
            f"{name}: rms={np.sqrt(np.mean(block * block)):.1f} "
            f"peak={np.max(np.abs(block)):.0f} "
            + " ".join(f"H{m}={db(harmonic[m], h1):+.2f} dBc"
                       for m in (1, 2, 3, 5, 7, 9))
        )


if __name__ == "__main__":
    main()
