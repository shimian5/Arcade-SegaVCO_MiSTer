#!/usr/bin/env python3
"""Trace one nominal D8 control-network transient for audit/debug only."""
from __future__ import annotations

import math
from playercar_d8_bounded_reference import D8TransientState, DeviceCorner, step_d8_transient


FS_HZ = 39935064.0 / 832.0
DT_S = 1.0 / FS_HZ


def main() -> int:
    corner = DeviceCorner(
        vbe_v=0.67,
        vf_v=0.70,
        beta=240.0,
        diode_dynamic_ohm=100.0,
        bjt_input_ohm=30_000.0,
    )
    state = D8TransientState()
    prev = None
    crossings = []
    mins = {"bout": math.inf, "d8": math.inf, "loop": math.inf}
    maxs = {"bout": -math.inf, "d8": -math.inf, "loop": -math.inf}
    total = 40_000
    for i in range(total):
        sample = step_d8_transient(
            state=state,
            n_a_v=7.80,
            dt_s=DT_S,
            corner=corner,
        )
        values = {"bout": sample.n_bout_v, "d8": sample.n_d8_v, "loop": sample.n_loop_v}
        for name, value in values.items():
            mins[name] = min(mins[name], value)
            maxs[name] = max(maxs[name], value)
        sign = sample.n_bout_v >= 6.0
        if prev is not None and sign != prev:
            crossings.append(i)
        prev = sign
        if i % 1000 == 0 or i == total - 1:
            print(
                "i={:5d} t_ms={:8.3f} N_BOUT={:8.4f} N_D8={:8.4f} "
                "N_LOOP={:8.4f} N_5BOUT={:8.4f} I_C6={: .3e} "
                "regions={}/{}/{}".format(
                    i,
                    1000.0 * i * DT_S,
                    sample.n_bout_v,
                    sample.n_d8_v,
                    sample.n_loop_v,
                    sample.n_5bout_v,
                    sample.c6_current_a,
                    sample.branches.tr1.region,
                    sample.branches.tr2.region,
                    sample.branches.tr6.region,
                )
            )
    print("envelope:", mins, maxs)
    print("N_BOUT crossings over 6 V:", len(crossings), crossings[:20])
    print("spectrum status: this trace is the D8 control network only; MB4391/IC17 audio transfer is not modeled")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
