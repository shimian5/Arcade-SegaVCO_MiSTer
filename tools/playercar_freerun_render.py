"""Checkpoint 3: render+check WAVs from the Checkpoint 2 free-running
player-car reference (tools/playercar_freerun_reference.py). No injected
audio anywhere -- ACC/BSEL/time are the only inputs. Outputs go to
sim/out/ (gitignored). Not RTL; not committed.

Monitoring-mix scaling: sum F+W+M taps unweighted (they are already in
volt-ish upright-contract units from the Gate 1 module, each well under 1 V
peak in the self-check), then normalize the whole render to 0.7 of full
scale so different scenarios stay comparably loud without per-file clipping
decisions. This is a monitoring convenience, not a claimed hardware mix.
"""
from __future__ import annotations

import struct
import wave
from pathlib import Path

from playercar_freerun_reference import FreeRunningPlayerCarReference, g1

FS = g1.FS
OUT_DIR = Path(__file__).resolve().parent.parent / "sim" / "out" / "playercar_freerun"
OUT_DIR.mkdir(parents=True, exist_ok=True)


def run_scenario(schedule):
    """schedule: list of (acc, bsel, duration_s). Returns list of raw float
    mix samples (F+W+M, unscaled) at FS, plus per-sample (acc,bsel) tags."""
    model = FreeRunningPlayerCarReference()
    samples = []
    for acc, bsel, dur in schedule:
        n = int(round(dur * FS))
        for _ in range(n):
            row = model.step(acc, bsel)
            upright = row["upright_two_speaker"]
            stk = upright["stk439_inputs_v"]
            f = stk["IN1_from_F_OUT"]
            w = stk["IN2_from_W_OUT"]
            m = upright["mixer_ii_bus_v"]["M"]
            samples.append(f + w + m)
    return samples


def dc_block(samples, fc_hz=20.0):
    """One-pole DC-blocking high-pass, standing in for the real hardware's
    output coupling caps (C112/C113/C114/C106 etc., named in the D-9/11
    header and GATE1_PLAYER_CAR_EQUATIONS.md section 4/7) that this reference
    model's raw node-voltage taps do not yet model. Without this, the WAV
    carries the physical bias-point DC level (up to ~0.84 of peak at high
    ACC) instead of just the audio swing riding on it -- inaudible as a
    steady DC term but it starves headroom and defeats zero-crossing-based
    sanity checks. R = 1 not used; standard difference-equation DC blocker:
    y[n] = x[n] - x[n-1] + a*y[n-1], a = 1 - 2*pi*fc/fs (BEHAVIORAL choice of
    cutoff, not a claimed physical cap value).
    """
    a = 1.0 - (2.0 * 3.141592653589793 * fc_hz / FS)
    out = []
    x_prev = 0.0
    y_prev = 0.0
    for x in samples:
        y = x - x_prev + a * y_prev
        out.append(y)
        x_prev = x
        y_prev = y
    return out


def check_and_write(name, samples, note=""):
    import math

    samples = dc_block(samples)
    n = len(samples)
    peak = max(abs(x) for x in samples)
    mean = sum(samples) / n
    has_bad = any((x != x) or math.isinf(x) for x in samples)  # NaN/inf
    # rail-bound: compare against the model's own d8_opamp bounds scaled by
    # downstream gain is not meaningful post-mixer, so instead just assert
    # finiteness + a generous absolute sanity ceiling (upright contract taps
    # were < 2 V peak across the whole Checkpoint-2 self-check sweep).
    rail_ok = peak < 20.0

    scale = 0.7 / peak if peak > 0 else 0.0
    scaled = [x * scale for x in samples]
    pcm = [max(-32768, min(32767, int(round(x * 32767)))) for x in scaled]
    clipped = sum(1 for v in pcm if v in (32767, -32768))

    path = OUT_DIR / f"{name}.wav"
    with wave.open(str(path), "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(int(round(FS)))
        wf.writeframes(struct.pack(f"<{n}h", *pcm))

    zc = sum(1 for i in range(1, n) if (samples[i - 1] < 0) != (samples[i] < 0))
    zcr_hz = zc / 2.0 / (n / FS)

    print(
        f"{name}: dur={n / FS:.3f}s peak_raw={peak:.4f} mean(DC)={mean:.6f} "
        f"nan_or_inf={has_bad} rail_ok={rail_ok} clipped_samples={clipped} "
        f"zcr~{zcr_hz:.1f}Hz {note}"
    )
    return path


def main():
    written = []

    # 1. Acceleration sweep, BSEL=2, ACC 0->63 over 4s then hold 1s.
    sweep_schedule = [(0, 2, 0.6)]
    steps = 40
    seg = 4.0 / steps
    for i in range(steps + 1):
        acc = round(i * 63 / steps)
        sweep_schedule.append((acc, 2, seg))
    sweep_schedule.append((63, 2, 1.0))
    s = run_scenario(sweep_schedule)
    written.append(check_and_write("01_acc_sweep_bsel2", s, "primary accel render"))

    # crude pitch-trend check: zcr in first 1s (low ACC) vs last 1s (high ACC)
    s = dc_block(s)
    n1 = int(1.0 * FS)
    zc_lo = sum(1 for i in range(1, n1) if (s[i - 1] < 0) != (s[i] < 0))
    zc_hi = sum(1 for i in range(len(s) - n1, len(s)) if (s[i - 1] < 0) != (s[i] < 0))
    print(f"  pitch-trend check: zc(first 1s, low ACC)={zc_lo} "
          f"zc(last 1s, high ACC)={zc_hi} rising={zc_hi > zc_lo}")

    # 2. Static low/med/high ACC, BSEL=2, 3s each (0.5s settle + 3s capture).
    for label, acc in (("low", 3), ("mid", 28), ("high", 60)):
        sched = [(acc, 2, 0.5), (acc, 2, 3.0)]
        s = run_scenario(sched)
        written.append(check_and_write(f"02_static_{label}_acc{acc}_bsel2", s))

    # 3. Every BSEL state at fixed mid ACC, 3s each (separate files).
    for bsel in (0, 1, 2, 3):
        sched = [(28, bsel, 0.5), (28, bsel, 3.0)]
        s = run_scenario(sched)
        written.append(check_and_write(f"03_bsel{bsel}_acc28", s))

    # 4. BSEL transition: 2 -> 3 -> 2, 3s each segment, single continuous file.
    sched = [(28, 2, 3.0), (28, 3, 3.0), (28, 2, 3.0)]
    s = run_scenario(sched)
    written.append(check_and_write("04_bsel_transition_2_3_2_acc28", s,
                                    "segments at 3.0s/6.0s boundaries"))

    # Determinism check: rerun scenario 2 (static mid) twice, compare bit-exact.
    sched = [(28, 2, 0.5), (28, 2, 1.0)]
    a = run_scenario(sched)
    b = run_scenario(sched)
    identical = a == b
    print(f"determinism check (static mid ACC, rerun): bit-identical={identical}")

    print("\nFiles written:")
    for p in written:
        print(f"  {p}")


if __name__ == "__main__":
    main()
