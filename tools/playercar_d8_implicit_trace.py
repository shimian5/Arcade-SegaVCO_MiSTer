#!/usr/bin/env python3
"""Print a compact trace of the implicit D8 reference model."""
from __future__ import annotations

from playercar_d8_bounded_reference import DeviceCorner
from playercar_d8_implicit_reference import DT_S, ImplicitState, step


def main() -> None:
    corner = DeviceCorner(diode_dynamic_ohm=10.0, bjt_input_ohm=10_000.0)
    state = ImplicitState()
    rows = []
    regions = set()
    for i in range(40_000):
        # A control step, not an oscillator source.  Hold the high control
        # long enough to expose any self-sustained N_BOUT activity.
        n_a = 2.0 if i < 2_000 else 7.8
        sample = step(state, n_a, corner=corner, iterations=12)
        regions.update((sample.tr1_region, sample.tr2_region, sample.tr6_region))
        if i in (0, 100, 1_000, 2_000, 3_000, 5_000, 10_000, 20_000, 39_999):
            rows.append((i, sample))
    for i, sample in rows:
        print(
            f"i={i:5d} t_ms={i*DT_S*1e3:8.3f} "
            f"N_BOUT={sample.n_bout:8.4f} N_DOUT={sample.n_dout:8.4f} "
            f"N_5BOUT={sample.n_5bout:8.4f} N_LOOP={sample.n_loop:8.4f} "
            f"N_7BOUT={sample.n_7bout:8.4f} N_7COUT={sample.n_7cout:8.4f} "
            f"N_D8={sample.n_d8:8.4f} "
            f"regions={sample.tr1_region}/{sample.tr2_region}/{sample.tr6_region}"
        )
    print(f"regions_seen={','.join(sorted(regions))}")
    print("N_BOUT crossings over 6 V: none expected from this constant-control run")


if __name__ == "__main__":
    main()
