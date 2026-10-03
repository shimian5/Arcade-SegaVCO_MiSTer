#!/usr/bin/env python3
"""Compare D8 cell-rate ratios with measured cabinet spectral lines.

The cabinet frequencies below are observations from the 763-767 s plateau of
turbo_cabinet_recording.weba. Their circuit assignments remain hypotheses;
this script never uses them to set synthesis coefficients. Run from the tools
directory or as ``python tools/playercar_triad_evidence.py``.
"""
from __future__ import annotations

import playercar_d8_ic17_reference as ref
import playercar_loaded_node_check as loaded


def cell_k(r_input: float, r_switch: float, capacitance: float,
           schmitt_swing: float = 10.5) -> float:
    """Hz/V for the D8 integrator/Schmitt circuit with an ideal switch."""
    gap = 51 / 151 * schmitt_swing
    falling_resistance = 1 / (1 / r_switch - 1 / r_input)
    return 1 / (2 * gap * capacitance * (r_input + falling_resistance))


def main() -> None:
    kt = cell_k(270e3, 120e3, 4700e-12)
    ks = cell_k(220e3, 100e3, (0.022 + 0.068) * 1e-6)
    k7 = cell_k(150e3, 68e3, (6800 + 6800) * 1e-12)
    tone = 444.156
    twice_sub = 55.188
    f7_plus_sub = 299.172
    sub = twice_sub / 2
    ic7 = f7_plus_sub - sub
    acc = 42  # MAME held-code ceiling, not measured synchronously in cabinet.
    raw = ref.ladder_v(acc)
    unloaded = 15 / 19.7
    _, identified_loaded = loaded.loaded_ratio()

    print("D8 fully populated ideal timing, reference Schmitt swing 10.5 V")
    print(f"Hz/Vbus: tone={kt:.6f}, sub={ks:.6f}, IC7={k7:.6f}")
    print(f"Predicted ratios: IC7/tone={k7/kt:.6f}, "
          f"tone/sub={kt/ks:.6f}, IC7/sub={k7/ks:.6f}")
    print("Cabinet candidate assignments, 763-767 s: "
          f"T={tone:.3f}, S={sub:.3f}, IC7={ic7:.3f} Hz")
    print(f"Observed ratios: IC7/T={ic7/tone:.6f}, "
          f"T/S={tone/sub:.6f}, IC7/S={ic7/sub:.6f}")
    print(f"Ratio errors vs schematic: IC7/T={100*(ic7/tone/(k7/kt)-1):+.3f}%, "
          f"T/S={100*(tone/sub/(kt/ks)-1):+.3f}%")
    for label, hz in (
        ("IC7+2S", ic7 + 2 * sub),
        ("IC7+3S", ic7 + 3 * sub),
        ("T+IC7", tone + ic7),
        ("T+IC7+S", tone + ic7 + sub),
    ):
        print(f"{label} = {hz:.3f} Hz")
    print(f"ACC{acc} Vraw={raw:.6f} V (separate MAME run)")
    for label, ratio in (("unloaded", unloaded),
                         ("identified ideal DC load", identified_loaded)):
        f_at_10p5 = kt * raw * ratio
        high_needed = 10.5 * f_at_10p5 / tone
        print(f"{label}: tap={ratio:.6f}, tone at 10.5 V swing="
              f"{f_at_10p5:.3f} Hz; swing for 444.156 Hz="
              f"{high_needed:.3f} V (inverse calculation, not a part spec)")


if __name__ == "__main__":
    main()
