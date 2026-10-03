#!/usr/bin/env python3
"""Compare schematic D8 bus hypotheses without fitting cabinet frequencies.

Uses the marked R/C timing and the existing upper-node/VCA Python proxy.
The raw bus is a wiring hypothesis, not a proposed RTL change. All amplitude
numbers are within one modeled output; the proxy omits MB4391 device-specific
distortion and the D9 BSEL2/amp transfer.
"""
from __future__ import annotations

import math
import numpy as np
from scipy.signal import lfilter

import playercar_d8_ic17_reference as ref
import playercar_fast_model as fast
import playercar_loaded_node_check as loaded

FS = fast.FS
SECONDS = 8
START = 4
GAIN_MAX = 10 ** (13 / 20)
OUTPUT_HALF_SWING = 7.3 / 2


def cell_k(r_input: float, r_switch: float, cap: float) -> float:
    """Ideal Hz/Vbus from the 51k/100k Schmitt and 10.5 V high assumption."""
    gap = 51 / 151 * 10.5
    r_fall = 1 / (1 / r_switch - 1 / r_input)
    return 1 / (2 * gap * cap * (r_input + r_fall))


def cell_rate_with_switch(vbus: float, r_input: float,
                          r_switch: float, cap: float,
                          collector_saturation: float) -> float:
    """Exact ideal integrator slopes if the C458 collector sits above ground.

    The data sources do not specify VCE(sat) at this board's ~30-uA collector
    current, so callers use this only for a displayed sensitivity sweep.
    """
    gap = 51 / 151 * 10.5
    i_source = vbus / (2 * r_input)
    i_sink = (vbus / 2 - collector_saturation) / r_switch - i_source
    return 1 / (gap * cap / i_source + gap * cap / i_sink)


K_TONE = cell_k(270e3, 120e3, 4700e-12)
K_SUB = cell_k(220e3, 100e3, 90e-9)
K_IC7 = cell_k(150e3, 68e3, 13.6e-9)


def synth(acc: int, bus_ratio: float) -> tuple[np.ndarray, dict[str, float]]:
    vl = ref.ladder_v(acc)
    vb = bus_ratio * vl
    freqs = {'T': K_TONE * vb, 'S': K_SUB * vb, 'F7': K_IC7 * vb}
    rng = np.random.default_rng(0)
    n = round(SECONDS * FS)
    tone = fast.tri(fast.phases(freqs['T'], n, rng.random()), fast.RATIO_TONE)
    sub = fast.tri(fast.phases(freqs['S'], n, rng.random()), fast.RATIO_SUB)
    ic7 = fast.tri(fast.phases(freqs['F7'], n, rng.random()), fast.RATIO_SUB)

    # Existing upper-node proxy, which already overstates what a memoryless
    # diode/MC3340 gain law can establish. No cabinet-derived parameter.
    td, sd = tone - fast.VF, sub - fast.VF
    node = np.maximum(np.maximum(233 / 256 * td, 233 / 256 * sd),
                      61 / 128 * (td + sd))
    node = np.clip(node, 0, 10.5)
    alpha = 14 / 65536
    c76 = node - lfilter([alpha], [1, -(1 - alpha)], node)
    cont = ref.clamp_dc(vb) + (fast.TH_LO + fast.TH_HI) / 2 - ic7
    idx = np.clip(np.floor((cont - 3) * 64).astype(int), 0, 192)
    upper = np.clip(GAIN_MAX * c76 * fast.GAIN17[idx],
                    -OUTPUT_HALF_SWING, OUTPUT_HALF_SWING)
    return upper, freqs


def line_spectrum(x: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    y = x[round(START * FS):]
    return np.fft.rfftfreq(len(y), 1 / FS), np.abs(np.fft.rfft(y * np.hanning(len(y))))


def line(f: np.ndarray, a: np.ndarray, hz: float) -> float:
    sel = (f >= hz - .5) & (f <= hz + .5)
    return float(np.max(a[sel]))


def db(a: float, b: float) -> float:
    return 20 * math.log10(max(a, 1e-12) / max(b, 1e-12))


def main() -> None:
    _, r_loaded = loaded.loaded_ratio()
    ratios = {'loaded': r_loaded, 'divided_unloaded': 15 / 19.7, 'raw': 1.0}
    print('All frequencies in Hz; 10.5 V Schmitt high; schematic/BOM C18+C19,C20+C21')
    print('Bus ratios:', ', '.join(f'{name}={ratio:.6f}' for name, ratio in ratios.items()))
    print('Model relative dB after D8 upper IC17 MC3340 proxy; T=0 dB')
    print('hypothesis ACC    T      S      F7     2F7   F7+S  F7+2S  T+F7+S  T-F7')
    for name, ratio in ratios.items():
        for acc in (39, 41, 42):
            x, q = synth(acc, ratio)
            f, a = line_spectrum(x)
            t, s, f7 = q['T'], q['S'], q['F7']
            base = line(f, a, t)
            products = (2*f7, f7+s, f7+2*s, t+f7+s, t-f7)
            strengths = [db(line(f,a,h),base) for h in products]
            print(f'{name:18} {acc:2d} {t:6.2f} {s:6.2f} {f7:6.2f}  '
                  + ' '.join(f'{v:+6.1f}' for v in strengths))
            print('    product Hz:', ' '.join(f'{h:.2f}' for h in products))
    print('C458 collector saturation sensitivity, raw ACC39 (VCEsat is not measured):')
    for vsat in (0, .02, .03, .05, .10):
        vb = ref.ladder_v(39)
        t = cell_rate_with_switch(vb,270e3,120e3,4700e-12,vsat)
        s = cell_rate_with_switch(vb,220e3,100e3,90e-9,vsat)
        f7 = cell_rate_with_switch(vb,150e3,68e3,13.6e-9,vsat)
        print(f'  {vsat:.3f} V: T={t:.3f}, S={s:.3f}, F7={f7:.3f}, '
              f'F7+S={f7+s:.3f}, F7+2S={f7+2*s:.3f}, '
              f'T+F7+S={t+f7+s:.3f} Hz')
    print('Tone Schmitt high source load (D4+R34+TR3, R32/R27 feedback):')
    for high in (10.5, 8.678, 7.667):
        base_ma = max(0, (high - .7 - .2) / 10_000) * 1000
        feedback_ma = (high - 6) / (100_000 + 51_000) * 1000
        print(f'  H={high:.3f} V: base path {base_ma:.3f} mA, '
              f'feedback {feedback_ma:.3f} mA, total '
              f'{base_ma+feedback_ma:.3f} mA')
    print('6 V D1 divider: 1k||1k = 500 ohm DC; 470 uF to ground '
          'has |Z|=1.13 ohm at 300 Hz.')
    print('MC3340 representative input: 20k bias link in parallel with '
          'a degenerated transistor base (~18-20k AC total).')
    r79 = 10_000
    rin = 18_000
    r_loaded_node = 1/(1/r79+1/rin)
    for r_source in (100, 500, 1000):
        with_input = r_loaded_node/(r_loaded_node+r_source)
        without_input = r79/(r79+r_source)
        print(f'  diode source R={r_source} ohm: active-node amplitude '
              f'{with_input/without_input:.3f}x of open-input case')
    print('Cabinet observed: state A 444.156, S candidate 27.594, F7 candidate 271.578,')
    print('  products 299.172,326.766,354.359,743.328; state B 482.6.')
    print('  These observations are comparisons only; none sets a model parameter.')


if __name__ == '__main__':
    main()
