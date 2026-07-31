#!/usr/bin/env python3
"""Check rendered audio WAVs against the phase-1 acceptance criteria.

Reads the scenario WAVs produced by `sim/` and reports, per file, the burst
fundamental and the burst length -- the two quantities `docs/audio-rtl-design.md`
says the ALARM channel must hit.

    python tools/analyze_audio.py sim/out/scen0.wav
    python tools/analyze_audio.py sim/out/*.wav
    python tools/analyze_audio.py --expect 446.5 sim/out/scen0.wav

The fundamental is found by autocorrelation over the loudest part of the burst
rather than by an FFT peak. A square wave's FFT peak is its fundamental only if
the window happens to resolve it; autocorrelation on a periodic signal gives the
period directly and does not care about harmonic weighting. Reported to 0.1 Hz.
"""

import argparse
import glob
import struct
import sys
import wave


def read_wav(path):
    with wave.open(path, "rb") as w:
        if w.getsampwidth() != 2:
            raise ValueError(f"{path}: expected 16-bit samples")
        sr = w.getframerate()
        ch = w.getnchannels()
        raw = w.readframes(w.getnframes())
    d = struct.unpack(f"<{len(raw)//2}h", raw)
    return list(d[::ch]), sr


def burst_extent(d, sr, floor_frac=0.10):
    """Extent of the *gated tone*, in seconds, plus the raw peak.

    Measured on the first difference of the signal, not on the signal itself.
    The ALARM channel's C88 high-pass has a 52 ms tau, so each burst is
    bracketed by slow exponential transients as the coupling cap recovers --
    physically real, and larger than the tone. An envelope threshold on the raw
    signal therefore reports the burst as roughly twice its true length.

    Differencing attenuates those transients (they are near-DC) while leaving
    the 446 Hz+ tone essentially untouched, so the threshold lands on the gate
    edges, which is what the acceptance criterion is about.
    """
    peak = max((abs(x) for x in d), default=0)
    if peak == 0:
        return None
    diff = [abs(d[i + 1] - d[i]) for i in range(len(d) - 1)]
    if not diff:
        return None
    # short-time envelope so a single zero-crossing does not read as silence
    w = max(1, int(sr * 0.002))
    env = []
    run = sum(diff[:w])
    env.append(run / w)
    for i in range(w, len(diff)):
        run += diff[i] - diff[i - w]
        env.append(run / w)

    dpeak = max(env)
    if dpeak == 0:
        return None
    thr = dpeak * floor_frac
    idx = [i for i, x in enumerate(env) if x > thr]
    if not idx:
        return None
    return idx[0] / sr, idx[-1] / sr, peak


def fundamental(d, sr, fmin=200.0, fmax=6000.0):
    """Period via normalised cross-correlation over the loudest window.

    Two details matter and both were got wrong on the first attempt:

    * The correlation must be **normalised** (NCCF) by the energy of both
      windows. An unnormalised sum divided by the overlap length inflates long
      lags, which reliably reports an octave (or worse) too low.
    * Even normalised, a periodic signal correlates just as well at 2T, 3T ...
      as at T, and noise decides which wins. So take the **first** lag whose
      correlation is within 15%% of the best, not the global maximum.
    """
    n = len(d)
    if n == 0:
        return None
    win = min(4096, n)
    best_e, best_s = -1.0, 0
    step = max(1, win // 8)
    for s in range(0, n - win + 1, step):
        e = sum(float(x) * x for x in d[s:s + win])
        if e > best_e:
            best_e, best_s = e, s
    seg = [float(x) for x in d[best_s:best_s + win]]
    mean = sum(seg) / len(seg)
    seg = [x - mean for x in seg]

    lag_min = max(2, int(sr / fmax))
    lag_max = min(len(seg) // 2, int(sr / fmin))
    if lag_max <= lag_min:
        return None

    def nccf(lag):
        m = len(seg) - lag
        num = sum(seg[i] * seg[i + lag] for i in range(m))
        e0 = sum(seg[i] * seg[i] for i in range(m))
        e1 = sum(seg[i + lag] * seg[i + lag] for i in range(m))
        den = (e0 * e1) ** 0.5
        return num / den if den > 0 else 0.0

    r = {lag: nccf(lag) for lag in range(lag_min, lag_max + 1)}
    rmax = max(r.values())
    if rmax <= 0:
        return None

    # first local maximum reaching 85% of the best correlation
    best_lag = max(r, key=r.get)
    for lag in range(lag_min + 1, lag_max):
        if r[lag] >= 0.85 * rmax and r[lag] >= r[lag - 1] and r[lag] >= r[lag + 1]:
            best_lag = lag
            break

    y0 = r.get(best_lag - 1, 0.0)
    y1 = r[best_lag]
    y2 = r.get(best_lag + 1, 0.0)
    denom = y0 - 2 * y1 + y2
    delta = 0.5 * (y0 - y2) / denom if denom != 0 else 0.0
    return sr / (best_lag + delta)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--expect", type=float, default=None,
                    help="expected fundamental in Hz; flags >0.5%% error")
    args = ap.parse_args()

    files = []
    for p in args.paths:
        files.extend(sorted(glob.glob(p)) or [p])

    print(f"{'file':<22} {'rate':>6} {'len':>8} {'peak':>7} "
          f"{'onset':>8} {'burst':>9} {'fund':>10}")
    print("-" * 76)

    rc = 0
    for path in files:
        try:
            d, sr = read_wav(path)
        except Exception as e:  # noqa: BLE001
            print(f"{path:<22} ERROR {e}")
            rc = 1
            continue

        ext = burst_extent(d, sr)
        if ext is None:
            print(f"{path.split('/')[-1]:<22} {sr:>6} {len(d)/sr:>7.3f}s "
                  f"{0:>7} {'-':>8} {'-':>9} {'silent':>10}")
            continue
        lo, hi, peak = ext
        f0 = fundamental(d, sr)

        note = ""
        if args.expect and f0:
            err = abs(f0 - args.expect) / args.expect
            note = f"  ({err*100:+.2f}% vs {args.expect} Hz)"
            if err > 0.005:
                note += " FAIL"
                rc = 1

        print(f"{path.split('/')[-1]:<22} {sr:>6} {len(d)/sr:>7.3f}s "
              f"{peak:>7} {lo:>7.3f}s {hi-lo:>8.3f}s "
              f"{f0:>9.1f}Hz{note}" if f0 else
              f"{path.split('/')[-1]:<22} {sr:>6} {len(d)/sr:>7.3f}s "
              f"{peak:>7} {lo:>7.3f}s {hi-lo:>8.3f}s {'n/a':>10}")

    return rc


if __name__ == "__main__":
    sys.exit(main())
