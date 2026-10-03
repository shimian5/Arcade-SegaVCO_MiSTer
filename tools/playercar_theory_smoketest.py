#!/usr/bin/env python3
"""Render D8 player-car hypotheses without changing RTL or fitting the cabinet.

All oscillator rates and lower-branch parts come from 834-0123 D-8/11. The
existing fast model supplies the upper diode node and 12 V MC3340 control
shape. The Motorola MC3340 sheet gives +13 dB maximum gain and about 7.3 Vpp
output swing at 12 V. Applying those limits to IC17 is a *proxy* experiment,
not a measured MB4391 transfer. The D11 monitor sum uses the drawn R303/R306
ratio but omits the D9 BSEL2 VCA and so is not a board-exact W mix.

Run: python tools/playercar_theory_smoketest.py --acc 41 \
     --population revb_photo
"""
from __future__ import annotations

import argparse
import math
from pathlib import Path

import numpy as np
from scipy.io import wavfile
from scipy.signal import lfilter

import playercar_d8_ic17_reference as ref
import playercar_fast_model as fast
import playercar_loaded_node_check as loaded

FS = fast.FS
GAIN_MAX = 10 ** (13 / 20)  # MC3340 sheet: +13 dB maximum gain
SWING_HALF_V = 7.3 / 2       # MC3340 Figure 6 at Vcc = 12 V
OUT = Path(__file__).resolve().parents[1] / "sim" / "out" / "playercar_theory"


def render(acc: int, seconds: float, population: str = "schematic",
           timing: str = "unloaded_10p5"
           ) -> tuple[dict[str, np.ndarray], dict[str, float]]:
    n = int(seconds * FS)
    vl = ref.ladder_v(acc)
    if timing == "unloaded_10p5":
        vb, swing_scale = fast.DIV * vl, 1.0
    elif timing == "identified_load_10p0":
        # Ideal DC load is from D8's drawn resistors. The 10 V Schmitt high
        # extrapolates Fujitsu's 30 V/2k typical; it is not specified at 12 V.
        vb, swing_scale = loaded.loaded_ratio()[1] * vl, 10.5 / 10.0
    else:
        raise ValueError(f"unknown timing scenario {timing}")
    rng = np.random.default_rng(0)
    ft, fs, f7 = (ref.K_TONE * vb * swing_scale,
                  ref.K_SUB_SCHEM * vb * swing_scale,
                  ref.K_IC7 * vb * swing_scale)
    if population == "revb_photo":
        # C18 and C20 are visibly empty in the Rev B photo. C19=68 nF and
        # C21=6.8 nF come from the sheet/BOM; C21's body is unreadable there.
        fs *= 0.090 / 0.068
        f7 *= 0.0136 / 0.0068
    elif population != "schematic":
        raise ValueError(f"unknown population {population}")
    tone = fast.tri(fast.phases(ft, n, rng.random()), fast.RATIO_TONE)
    sub = fast.tri(fast.phases(fs, n, rng.random()), fast.RATIO_SUB)
    ic7 = fast.tri(fast.phases(f7, n, rng.random()), fast.RATIO_SUB)

    # Mirror current RTL D7/D13/R79 and C76 in volts, then IC17 upper CONT.
    td, sd = tone - fast.VF, sub - fast.VF
    node = np.maximum(np.maximum(233 / 256 * td, 233 / 256 * sd),
                      61 / 128 * (td + sd))
    node = np.clip(node, 0, 10.5)
    alpha = 14 / 65536
    upper_in = node - lfilter([alpha], [1, -(1 - alpha)], node)
    ci = min(191, max(0, int(vl * 16)))
    upper_cont = fast.CLAMP[ci] + (fast.TH_LO + fast.TH_HI) / 2 - ic7
    upper_gain_idx = np.clip(np.floor((upper_cont - 3) * 64).astype(int), 0, 192)
    upper_normalized = upper_in * fast.GAIN17[upper_gain_idx]
    upper_mc3340 = np.clip(GAIN_MAX * upper_normalized,
                           -SWING_HALF_V, SWING_HALF_V)
    upper_mc3340_soft = SWING_HALF_V * np.tanh(
        GAIN_MAX * upper_normalized / SWING_HALF_V)

    # D8: IC3 cell -> D8 -> R51/R52 -> C47 -> IC17 lower IN.
    # IC5 cell -> C17 -> R70/R69 amplifier -> IC17 lower CONT.
    def cell_k(r_in: float, r_switch: float, cap_f: float) -> float:
        r_eff = r_in + 1 / (1 / r_switch - 1 / r_in)
        return 1 / (2 * (fast.TH_HI - fast.TH_LO) * cap_f * r_eff)

    # IC3/C7 is 2.901 Hz/V nominal. An older review used 2.80 Hz/V from a
    # nonideal limit-cycle run; it is not the ideal law of the drawn parts.
    f3 = cell_k(270e3, 120e3, 0.1e-6) * vl
    f5 = cell_k(150e3, 68e3, 0.1e-6) * vl
    ic3 = fast.tri(fast.phases(f3, n, rng.random()), 270 / 120 - 1)
    ic5 = fast.tri(fast.phases(f5, n, rng.random()), 150 / 68 - 1)
    lower_input_dc = np.maximum(ic3 - fast.VF, 0) * 10 / (39 + 10)
    lower_in = lower_input_dc - np.mean(lower_input_dc)
    lower_bias = 12 * 2.7 / (8.2 + 2.7)  # R65/R67; R68/R66 parallel
    lower_cont = lower_bias - (10 / 15) * (ic5 - np.mean(ic5))
    lower_gain_idx = np.clip(np.floor((lower_cont - 3) * 64).astype(int), 0, 192)
    lower_mc3340 = np.clip(GAIN_MAX * lower_in * fast.GAIN17[lower_gain_idx],
                           -SWING_HALF_V, SWING_HALF_V)

    signals = {
        "upper_current": upper_normalized,
        "upper_mc3340_proxy": upper_mc3340,
        "upper_mc3340_soft_bound": upper_mc3340_soft,
        "slf_lower_mc3340_proxy": lower_mc3340,
        "monitor_d11_resistor_sum": upper_mc3340 + (100 / 68) * lower_mc3340,
    }
    freqs = {"T": ft, "S": fs, "IC7": f7, "IC3": f3, "IC5": f5,
             "IC3+IC5": f3 + f5, "2IC3-IC5": 2 * f3 - f5}
    return signals, freqs


def near_line(x: np.ndarray, hz: float, start: int) -> float:
    y = x[start:]
    a = abs(np.fft.rfft(y * np.hanning(len(y))))
    f = np.fft.rfftfreq(len(y), 1 / FS)
    band = (f > hz - 1) & (f < hz + 1)
    return float(np.max(a[band]))


def save_wav(path: Path, x: np.ndarray) -> None:
    # Each file is normalized for safe listening; use raw arrays for analysis.
    scale = 0.75 / max(float(np.max(np.abs(x))), 1e-12)
    pcm = np.round(np.clip(x * scale, -1, 1) * 32767).astype(np.int16)
    wavfile.write(path, round(FS), pcm)


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--acc", type=int, default=40)
    ap.add_argument("--seconds", type=float, default=9.0)
    ap.add_argument("--population", choices=("schematic", "revb_photo"),
                    default="schematic")
    ap.add_argument("--timing", choices=("unloaded_10p5", "identified_load_10p0"),
                    default="unloaded_10p5")
    args = ap.parse_args()
    if not 0 <= args.acc <= 63 or args.seconds < 5:
        ap.error("ACC must be 0..63 and seconds >= 5")
    signals, freqs = render(args.acc, args.seconds, args.population, args.timing)
    OUT.mkdir(parents=True, exist_ok=True)
    start = int(4 * FS)  # analyze settled interval; hardware image mutes initially
    print("ACC", args.acc, "population", args.population, "timing", args.timing,
          "frequencies", {k: round(v, 3) for k, v in freqs.items()})
    high_label = "IC7" if args.population == "revb_photo" else "2*IC7"
    high_hz = freqs["IC7"] * (1 if args.population == "revb_photo" else 2)
    print(f"{high_label} - (T + 3*S) = "
          f"{high_hz - freqs['T'] - 3*freqs['S']:+.3f} Hz; "
          f"S/T = {freqs['S'] / freqs['T']:.5f}; "
          f"{high_label}/T = {high_hz / freqs['T']:.5f}")
    print(f"MC3340 proxy: max gain {GAIN_MAX:.3f}, swing +/-{SWING_HALF_V:.2f} V")
    for name, x in signals.items():
        prefix = "" if args.population == "schematic" else f"{args.population}_"
        if args.timing != "unloaded_10p5":
            prefix += f"{args.timing}_"
        path = OUT / f"acc{args.acc}_{prefix}{name}.wav"
        save_wav(path, x)
        def db(num: float, den: float) -> float:
            return 20 * math.log10(max(num, 1e-12) / max(den, 1e-12))
        rms = float(np.sqrt(np.mean(x[start:] ** 2)))
        if name == "slf_lower_mc3340_proxy":
            a = near_line(x, freqs["IC3+IC5"], start)
            b = near_line(x, 2 * freqs["IC5"] - freqs["IC3"], start)
            print(f"{name}: (2IC5-IC3)/(IC3+IC5)={db(b, a):.1f} dB, "
                  f"rms={rms:.3f} V")
        else:
            t = near_line(x, freqs["T"], start)
            slf_sum = near_line(x, freqs["IC3+IC5"], start)
            if args.population == "revb_photo":
                ic7_line = near_line(x, freqs["IC7"], start)
                third_sub = near_line(x, freqs["T"] + 3 * freqs["S"], start)
                fourth_sub = near_line(x, freqs["T"] + 4 * freqs["S"], start)
                print(f"{name}: IC7/T={db(ic7_line, t):.1f} dB, "
                      f"(T+3S)/T={db(third_sub, t):.1f} dB, "
                      f"(T+4S)/T={db(fourth_sub, t):.1f} dB, "
                      f"(IC3+IC5)/T={db(slf_sum, t):.1f} dB, rms={rms:.3f} V")
            else:
                f7_2 = near_line(x, 2 * freqs["IC7"], start)
                lower = near_line(x, 2 * freqs["IC7"] - freqs["2IC3-IC5"], start)
                sideband = (f"{db(lower, f7_2):.1f} dB"
                            if db(f7_2, t) > -40 else "n/a (center below -40 dB)")
                print(f"{name}: 2IC7/T={db(f7_2, t):.1f} dB, "
                      f"lower_sideband/2IC7={sideband}, "
                      f"(IC3+IC5)/T={db(slf_sum, t):.1f} dB, rms={rms:.3f} V")
        print(path)


if __name__ == "__main__":
    main()
