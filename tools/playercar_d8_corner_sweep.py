#!/usr/bin/env python3
"""Exercise the bounded D8 transient reference over explicit device corners.

This is an audit tool, not a cabinet-timbre fitter and not shipping RTL.  It
uses the corrected D8 graph in ``playercar_d8_bounded_reference.py`` and
reports rail/device validity through an ACC-style control transition.  The
reference currently describes the control network up to the IC17 input; it
does not claim to be the MB4391 oscillator itself, so no H3/H5 spectrum is
invented here.
"""
from __future__ import annotations

import itertools
import math
from dataclasses import replace

from playercar_d8_bounded_reference import (
    D8TransientState,
    DeviceCorner,
    step_d8_transient,
)


FS_HZ = 39935064.0 / 832.0
DT_S = 1.0 / FS_HZ
RAIL_LO = 0.0
RAIL_HI = 10.5


def run_corner(corner: DeviceCorner, *, pre: int = 100, post: int = 800) -> dict:
    state = D8TransientState()
    samples = []
    valid = True
    max_state = 0.0
    min_state = float("inf")
    regions = set()
    for i in range(pre + post):
        # A bounded ladder/control transition: low idle, then a high ACC
        # operating point.  This tests the coupled capacitor/transistor
        # transient without using the cabinet recording to choose a value.
        n_a_v = 0.50 if i < pre else 7.80
        try:
            sample = step_d8_transient(
                state=state, n_a_v=n_a_v, dt_s=DT_S, corner=corner
            )
        except (FloatingPointError, ValueError, ZeroDivisionError):
            valid = False
            break
        values = (
            sample.n_a_v,
            sample.n_bplus_v,
            sample.n_bout_v,
            sample.n_5aplus_v,
            sample.n_5aout_v,
            sample.n_5bout_v,
            sample.n_loop_v,
            sample.n_7bplus_v,
            sample.n_7bout_v,
            sample.n_d8_v,
            state.ic3d_out_v,
            state.ic5b_out_v,
            state.ic7c_out_v,
        )
        if not all(math.isfinite(v) for v in values):
            valid = False
            break
        min_state = min(min_state, min(values))
        max_state = max(max_state, max(values))
        # The LM324 states are explicitly bounded by the solver.  Keep this
        # check here so a future change cannot silently turn clipping into a
        # successful corner.
        if any(v < RAIL_LO - 1e-9 or v > RAIL_HI + 1e-9 for v in values):
            valid = False
            break
        regions.update(
            (
                sample.branches.tr1.region,
                sample.branches.tr2.region,
                sample.branches.tr6.region,
            )
        )
        if i >= pre + post - 1000:
            samples.append(sample)
    return {
        "valid": valid,
        "min_v": min_state if valid else None,
        "max_v": max_state if valid else None,
        "regions": sorted(regions),
        "n_d8_final_v": samples[-1].n_d8_v if samples else None,
        "n_bout_final_v": samples[-1].n_bout_v if samples else None,
    }


def main() -> int:
    # Endpoints and midpoint are an explicit corner family, not a fit.  rd
    # and rpi have no board-supported single value, so both remain sweep axes.
    values = {
        # The default sweep is the documented low/high envelope.  A denser
        # grid is intentionally left to an explicitly requested future run;
        # this tool must remain practical as a pre-RTL regression.
        "vbe_v": (0.55, 0.75),
        "vf_v": (0.55, 0.85),
        "beta": (160.0, 320.0),
        "diode_dynamic_ohm": (10.0, 1000.0),
        "bjt_input_ohm": (10_000.0, 100_000.0),
    }
    rows = []
    for vbe, vf, beta, rd, rpi in itertools.product(
        values["vbe_v"],
        values["vf_v"],
        values["beta"],
        values["diode_dynamic_ohm"],
        values["bjt_input_ohm"],
    ):
        corner = DeviceCorner(
            vbe_v=vbe,
            vf_v=vf,
            beta=beta,
            diode_dynamic_ohm=rd,
            bjt_input_ohm=rpi,
        )
        result = run_corner(corner)
        rows.append((corner, result))

    valid_rows = [(c, r) for c, r in rows if r["valid"]]
    print(f"D8 corner sweep: {len(rows)} corners, {len(valid_rows)} rail-valid")
    if valid_rows:
        mins = min(r["min_v"] for _, r in valid_rows)
        maxs = max(r["max_v"] for _, r in valid_rows)
        print(f"valid node envelope: {mins:.6f}..{maxs:.6f} V")
    else:
        print("no rail-valid corners")
    for corner, result in rows:
        print(
            "corner vbe={:.2f} vf={:.2f} beta={:.0f} rd={:.0f} rpi={:.0f}: "
            "valid={} envelope={}..{} regions={} N_BOUT={} N_D8={}".format(
                corner.vbe_v,
                corner.vf_v,
                corner.beta,
                corner.diode_dynamic_ohm,
                corner.bjt_input_ohm,
                result["valid"],
                "-" if result["min_v"] is None else f"{result['min_v']:.4f}",
                "-" if result["max_v"] is None else f"{result['max_v']:.4f}",
                ",".join(result["regions"]),
                "-" if result["n_bout_final_v"] is None else f"{result['n_bout_final_v']:.4f}",
                "-" if result["n_d8_final_v"] is None else f"{result['n_d8_final_v']:.4f}",
            )
        )
    print("H3/H5: not measured by this tool; the MB4391 oscillator boundary is separate.")
    return 0 if valid_rows else 1


if __name__ == "__main__":
    raise SystemExit(main())
