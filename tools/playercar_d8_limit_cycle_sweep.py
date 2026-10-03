#!/usr/bin/env python3
"""Search the implicit D8 reference for a constant-control limit cycle."""
from __future__ import annotations

from playercar_d8_bounded_reference import DeviceCorner
from playercar_d8_implicit_reference import ImplicitState, step


def main() -> None:
    corner = DeviceCorner(diode_dynamic_ohm=10.0, bjt_input_ohm=10_000.0)
    candidates = []
    for n_a in [x / 2.0 for x in range(0, 25)]:
        state = ImplicitState()
        values = []
        for i in range(4_000):
            values.append(step(state, n_a, corner=corner, iterations=10).n_bout)
        tail = values[-1_000:]
        spread = max(tail) - min(tail)
        # A nonzero spread over the final 1000 samples would be evidence of a
        # cycle at this nominal corner, not proof that the board does so.
        if spread > 1e-3:
            candidates.append((n_a, spread, min(tail), max(tail)))
        print(f"N_A={n_a:5.1f} N_BOUT_tail={tail[-1]:8.5f} spread={spread:.6f}")
    print("limit_cycle_candidates=", candidates)


if __name__ == "__main__":
    main()
