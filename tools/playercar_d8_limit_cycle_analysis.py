#!/usr/bin/env python3
"""Measure bounded D8 control-network cycles without fitting cabinet audio.

The input is the explicit upstream ``N_SRC`` boundary from the primary D8
sheet, not an assertion that ACC/C110 drives that node.  A repeatable cycle is
useful evidence that the corrected capacitor/transistor network is dynamic;
its frequency is not automatically the player-car audio fundamental.
"""
from __future__ import annotations

from playercar_d8_bounded_reference import DeviceCorner
from playercar_d8_implicit_reference import DT_S, ImplicitState, step


def _period(samples: list[float], *, threshold: float = 6.0) -> int | None:
    signs = [v >= threshold for v in samples]
    crossings = [i for i in range(1, len(signs)) if signs[i] != signs[i - 1]]
    if len(crossings) < 4:
        return None
    periods = [crossings[i] - crossings[i - 2]
               for i in range(2, len(crossings))]
    if not periods:
        return None
    candidate = periods[-1]
    if all(abs(p - candidate) <= 2 for p in periods[-3:]):
        return candidate
    return None


def run(n_src: float, *, total: int = 12_000) -> tuple[float, float, int | None]:
    corner = DeviceCorner(diode_dynamic_ohm=10.0, bjt_input_ohm=10_000.0)
    state = ImplicitState()
    values: list[float] = []
    for _ in range(total):
        values.append(step(state, n_src, corner=corner, iterations=24).n_bout)
    tail = values[2_000:]
    period = _period(tail)
    return min(tail), max(tail), period


def main() -> None:
    print(f"sample_rate={1.0 / DT_S:.6f} Hz")
    for n_src in (2.0, 4.0, 6.0, 7.8, 9.0, 10.5):
        lo, hi, period = run(n_src)
        if period is None:
            freq = "-"
        else:
            freq = f"{1.0 / (period * DT_S):.6f}"
        print(f"N_SRC={n_src:4.1f} N_BOUT={lo:.6f}..{hi:.6f} "
              f"period_samples={period if period is not None else '-'} "
              f"freq_hz={freq}")


if __name__ == "__main__":
    main()
