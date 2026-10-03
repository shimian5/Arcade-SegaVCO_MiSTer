#!/usr/bin/env python3
"""Check phase relationships among measured Turbo cabinet spectral lines.

The frequencies below are observations from the 763-767 s cabinet plateau,
not synthesis constants. Phase locking establishes coherent components but
does not identify which oscillator or nonlinear node generated them.

Run: python tools/playercar_cabinet_phase_check.py [--source RECORDING.weba]
"""
from __future__ import annotations

import argparse
from pathlib import Path
import subprocess

import imageio_ffmpeg
import numpy as np
from scipy.signal import butter, hilbert, sosfiltfilt


FS = 4000
DECODE_START = 738
DECODE_SECONDS = 52
WINDOWS = (748, 763)
DEFAULT_SOURCE = (Path(__file__).resolve().parents[2] / "turbo" / "docs"
                  / "reference" / "turbo_cabinet_recording.weba")

# Median-residual peak positions from a four-second Hann transform. Values are
# measured frequencies; the script checks their phase relations independently.
HZ = {
    "p23": 23.203,
    "p28": 27.609,
    "l55": 55.188,
    "l59": 58.688,
    "e86": 86.234,
    "o97": 97.031,
    "o202": 202.375,
    "p299": 299.172,
    "p327": 326.766,
    "p354": 354.359,
    "f271": 271.578,
    "t358": 357.859,
    "o405": 404.625,
    "p413": 413.094,
    "s441": 440.656,
    "h444": 444.156,
    "p743": 743.328,
}

RELATIONS = {
    "55 - 2*28 (weak base line)": {"l55": 1, "p28": -2},
    "271 + 28 - 299 (candidate IC7+S)":
        {"f271": 1, "p28": 1, "p299": -1},
    "299 + 28 - 327 (candidate +S)":
        {"p299": 1, "p28": 1, "p327": -1},
    "299 + 55 - 354 (candidate +2S)":
        {"p299": 1, "l55": 1, "p354": -1},
    "299 + 59 - 358": {"p299": 1, "l59": 1, "t358": -1},
    "358 + 55 - 413": {"t358": 1, "l55": 1, "p413": -1},
    "358 + 86 - 444": {"t358": 1, "e86": 1, "h444": -1},
    "444 + 299 - 743": {"h444": 1, "p299": 1, "p743": -1},
    "(59 - 55) - (444 - 441)":
        {"l59": 1, "l55": -1, "h444": -1, "s441": 1},
    "441 - 19*23": {"s441": 1, "p23": -19},
    "2*(441 - 358) - 3*55":
        {"s441": 2, "t358": -2, "l55": -3},
    # Nearby frequency sums are not automatically phase locked.
    "control: 202 + 97 - 299": {"o202": 1, "o97": 1, "p299": -1},
    "control: 2*202 - 405": {"o202": 2, "o405": -1},
}


def decode(source: Path) -> np.ndarray:
    cmd = [imageio_ffmpeg.get_ffmpeg_exe(), "-hide_banner", "-loglevel", "error",
           "-ss", str(DECODE_START), "-t", str(DECODE_SECONDS), "-i", str(source),
           "-ac", "1", "-ar", str(FS), "-f", "f32le", "-"]
    result = subprocess.run(cmd, check=True, stdout=subprocess.PIPE)
    return np.frombuffer(result.stdout, dtype="<f4").astype(np.float64)


def unit_analytic(signal: np.ndarray, freq: float) -> np.ndarray:
    sos = butter(3, (freq - 1, freq + 1), btype="bandpass",
                 fs=FS, output="sos")
    z = hilbert(sosfiltfilt(sos, signal))
    return z / np.maximum(np.abs(z), 1e-12)


def phase_result(traces: dict[str, np.ndarray], relation: dict[str, int],
                 start: int) -> tuple[float, float]:
    # Use the inner three seconds of each four-second plateau.
    lo = int((start + 0.5 - DECODE_START) * FS)
    hi = int((start + 3.5 - DECODE_START) * FS)
    combined = np.ones(hi - lo, dtype=np.complex128)
    for name, exponent in relation.items():
        combined *= traces[name][lo:hi] ** exponent
    mean = np.mean(combined)
    return float(np.abs(mean)), float(np.angle(mean))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    args = parser.parse_args()
    signal = decode(args.source)
    traces = {name: unit_analytic(signal, freq) for name, freq in HZ.items()}
    print(f"source={args.source}")
    print("PLV is 0..1 phase locking; phase is radians. A relation can run in"
          " either causal direction.")
    for label, relation in RELATIONS.items():
        results = [phase_result(traces, relation, start) for start in WINDOWS]
        print(f"{label:32} " + "  ".join(
            f"{start}s PLV={plv:.3f} phase={phase:+.3f}"
            for start, (plv, phase) in zip(WINDOWS, results)))


if __name__ == "__main__":
    main()
