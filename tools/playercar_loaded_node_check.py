#!/usr/bin/env python3
"""Calculate the ideal D8 loaded speed tap and timing sensitivities.

The three 51k/51k bias arms and three integrator input resistors are on the
same 4.7k/15k tap. An ideal integrator holds its inverting input at Vbus/2,
so each input resistor loads Vbus as twice its marked resistance to ground.
No cabinet frequency enters this calculation. The 10.0 V Schmitt high is an
illustrative extrapolation of the Fujitsu MB3614's 28 V typical output high
at 30 V supply and 2k load, not a 12 V part specification or RTL setting.

Run: python tools/playercar_loaded_node_check.py --acc 41
"""
from __future__ import annotations

import argparse

import playercar_d8_ic17_reference as ref


UPPER = 4_700.0
LOWER = 15_000.0
BIAS_ARMS = (102_000.0,) * 3
INPUT_ARMS = (2 * 270_000.0, 2 * 220_000.0, 2 * 150_000.0)
REFERENCE_SWING = 10.5  # existing oscillator model's 0..10.5 V assumption


def loaded_ratio() -> tuple[float, float]:
    shunt = 1 / sum(1 / r for r in BIAS_ARMS + INPUT_ARMS)
    lower = 1 / (1 / LOWER + 1 / shunt)
    return shunt, lower / (UPPER + lower)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--acc", type=int, default=41)
    args = parser.parse_args()
    if not 0 <= args.acc <= 63:
        parser.error("ACC must be 0..63")
    shunt, ratio = loaded_ratio()
    v_raw = ref.ladder_v(args.acc)
    print(f"ACC={args.acc} V7={v_raw:.6f} V")
    print(f"identified ideal shunt={shunt:.3f} ohm; "
          f"loaded divider={ratio:.8f}; "
          f"unloaded divider={LOWER / (UPPER + LOWER):.8f}")
    for high in (10.5, 10.0):
        scale = v_raw * ratio * REFERENCE_SWING / high
        tone = ref.K_TONE * scale
        sub_full = ref.K_SUB_SCHEM * scale
        sub_photo = sub_full * .090 / .068  # C18 empty; C19 fitted
        ic7_full = ref.K_IC7 * scale
        ic7_photo = ic7_full * .0136 / .0068  # C20 empty; C21 fitted
        print(f"Schmitt high={high:.1f} V: tone={tone:.3f}, "
              f"sub schematic={sub_full:.3f}, sub photo={sub_photo:.3f}, "
              f"IC7 schematic={ic7_full:.3f}, IC7 photo={ic7_photo:.3f}, "
              f"tone+4*sub photo={tone + 4 * sub_photo:.3f} Hz")
    print(f"S/T schematic={ref.K_SUB_SCHEM / ref.K_TONE:.5f}; "
          f"S/T photo={ref.K_SUB_SCHEM * .090 / .068 / ref.K_TONE:.5f}")


if __name__ == "__main__":
    main()
