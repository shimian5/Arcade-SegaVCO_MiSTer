#!/usr/bin/env python3
"""Cross-check the public bounded D8 API against the implicit authority.

The project previously had two subtly different transient reductions.  This
regression deliberately drives both APIs through ACC-style source changes and
device corners, then compares every exposed node and capacitor state.  It is
not a cabinet fit and it does not authorize a release RTL substitution.
"""
from __future__ import annotations

import math

from playercar_d8_bounded_reference import D8TransientState, DeviceCorner, step_d8_transient
from playercar_d8_implicit_reference import ImplicitState, step


FS_HZ = 39_935_064.0 / 832.0
DT_S = 1.0 / FS_HZ


def main() -> int:
    corners = (
        DeviceCorner(vbe_v=0.55, vf_v=0.55, beta=160.0,
                     diode_dynamic_ohm=10.0, bjt_input_ohm=10_000.0),
        DeviceCorner(vbe_v=0.75, vf_v=0.85, beta=320.0,
                     diode_dynamic_ohm=1_000.0, bjt_input_ohm=100_000.0),
        DeviceCorner(vbe_v=0.67, vf_v=0.70, beta=240.0,
                     diode_dynamic_ohm=100.0, bjt_input_ohm=30_000.0),
    )
    max_error = 0.0
    count = 0
    for corner in corners:
        bounded = D8TransientState()
        implicit = ImplicitState()
        for i in range(1_000):
            source = 0.5 if i < 200 else (7.8 if (i // 173) & 1 else 4.0)
            b = step_d8_transient(state=bounded, n_a_v=source,
                                  dt_s=DT_S, corner=corner)
            r = step(implicit, source, dt_s=DT_S, corner=corner)
            values = (
                (b.n_a_v, r.n_a), (b.n_bplus_v, r.n_bplus),
                (b.n_bminus_v, r.n_bminus), (b.n_bout_v, r.n_bout),
                (b.n_5aplus_v, r.n_5aplus), (b.n_5aminus_v, r.n_5aminus),
                (b.n_5aout_v, r.n_5aout), (b.n_5bout_v, r.n_5bout),
                (b.n_loop_v, r.n_loop), (b.n_7bplus_v, r.n_7bplus),
                (b.n_7bminus_v, r.n_7bminus), (b.n_7bout_v, r.n_7bout),
                (b.n_d8_v, r.n_d8), (b.c6_current_a, r.c6_current_a),
            )
            for lhs, rhs in values:
                if not (math.isfinite(lhs) and math.isfinite(rhs)):
                    raise AssertionError("non-finite D8 reference output")
                max_error = max(max_error, abs(lhs - rhs))
                count += 1
            assert b.branches.tr1.region == r.tr1_region
            assert b.branches.tr2.region == r.tr2_region
            assert b.branches.tr6.region == r.tr6_region
    assert max_error == 0.0
    print(f"PASS D8 bounded/implicit equivalence samples={count} max_error={max_error:.3g} V")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
