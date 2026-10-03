#!/usr/bin/env python3
"""Bounded D8 common-emitter branch primitives.

This is the numerical-reference starting point for the existing D8 netlist,
not shipping RTL and not a cabinet-fitted oscillator.  Its immediate purpose
is to prevent the obsolete emitter-follower abstraction from returning.

The primitive solves the traced topology used by TR1, TR2 and TR6:

  feedback/op-amp drive -- MA150 -- series R -- base node
                                           |-- 2.2k -- GND
                                           |-- 2SC458 base
  collector drive -- collector R -- 2SC458 collector; emitter -- GND

The unknown low-current MA150 resistance and BJT input resistance are named
corner parameters.  They are swept by callers; no value is selected to fit
the cabinet spectrum.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


# This is deliberately data, rather than a second hand-drawn reduced
# schematic.  Keeping the instances in one audit-able manifest lets the
# reference solver and any future RTL use the *same* corrected topology.
# The values are from D8/11.  ``None`` means the rendered primary evidence
# does not establish the value, so a caller must provide/bound it explicitly.
TRACED_D8 = {
    "rails": {"VCC": 12.0, "VREF": 6.0, "LM324_LO": 0.0,
              "LM324_HI_BOUND": 10.5, "IC7A_DIVIDER": 12.0 * 330.0 / 1010.0},
    "ic3b": {"r_input": 270_000.0, "r_plus_top": 51_000.0,
             "r_plus_bottom": 51_000.0, "c_feedback": 0.1e-6,
             "collector_r": 120_000.0, "branch": "TR1"},
    "ic3d": {"r_plus": 51_000.0, "r_feedback": 100_000.0,
             "base_r": 10_000.0, "base_diode": "D9"},
    "ic5a": {"r_input": 150_000.0, "r_plus_top": 51_000.0,
             "r_plus_bottom": 51_000.0, "c_feedback": 0.1e-6,
             "collector_r": 68_000.0, "branch": "TR2"},
    "ic5b": {"r_plus": 51_000.0, "r_feedback": 100_000.0,
             "base_r": 10_000.0, "base_diode": "D3"},
    # Board-photo recovery, 2026-08-22: R68 and R66 are visibly unpopulated
    # option footprints.  The fitted tacho/reference divider is R65=2.7k
    # from +12 V and R67=2.2k to GND, bypassed by C16.  This closes the
    # formerly open IC5-C + input without inventing a BOM assignment.
    "ic5c": {"r_input": 15_000.0, "r_feedback": 10_000.0,
             "c_input": 22e-6, "r65_top": 2_700.0,
             "r67_bottom": 2_200.0, "plus_bias": 12.0 * 2_200.0 / 4_900.0,
             "dnp_options": ("R66", "R68")},
    "ic7b": {"r_input": 150_000.0, "r_plus_top": 51_000.0,
             "r_plus_bottom": 51_000.0, "c_feedback": 0.047e-6,
             "c_feedback_hf": 680e-12, "collector_r": 68_000.0,
             "branch": "TR6"},
    "ic7c": {"r_plus": 51_000.0, "r_feedback": 100_000.0,
             "base_r": 10_000.0, "base_diode": "D14", "c_input": 22e-6},
    "d8_to_ic17": {"diode": "D8", "r": 39_000.0, "r_shunt": 10_000.0,
                    "c_couple": 10e-6},
}


def validate_traced_d8() -> None:
    """Fail closed if a later edit loses the board-photo-proven D8 recovery."""
    assert TRACED_D8["ic5c"]["dnp_options"] == ("R66", "R68")
    assert abs(TRACED_D8["ic5c"]["plus_bias"] - (12.0 * 2_200.0 / 4_900.0)) < 1e-12
    assert TRACED_D8["ic3b"]["branch"] == "TR1"
    assert TRACED_D8["ic5a"]["branch"] == "TR2"
    assert TRACED_D8["ic7b"]["branch"] == "TR6"
    assert TRACED_D8["ic7c"]["base_diode"] == "D14"
    assert abs(TRACED_D8["rails"]["IC7A_DIVIDER"] - 3.9207920792) < 1e-6


@dataclass(frozen=True)
class DeviceCorner:
    """Explicit non-fitted semiconductor/LM324 boundaries in volts/ohms."""

    lm324_low_v: float = 0.0
    lm324_high_v: float = 10.5
    vbe_v: float = 0.67          # 2SC458C published 2-mA typical corner
    vf_v: float = 0.70           # midpoint of explicit MA150 low-I bound
    beta: float = 160.0          # published C-rank low corner
    vce_sat_v: float = 0.20      # published 10-mA upper bound
    # Neither the MA150 low-current dynamic resistance nor 2SC458 small-
    # signal input resistance is supplied by the available primary evidence.
    # They must be supplied as a documented corner sweep by a caller.
    diode_dynamic_ohm: Optional[float] = None
    bjt_input_ohm: Optional[float] = None

    def validate(self) -> None:
        if not (0.0 <= self.lm324_low_v < self.lm324_high_v):
            raise ValueError("invalid LM324 output interval")
        if not (0.55 <= self.vbe_v <= 0.75):
            raise ValueError("VBE must remain in the declared 2SC458 bound")
        if not (0.45 <= self.vf_v <= 0.95):
            raise ValueError("VF must remain in the declared MA150 bound")
        if not (160.0 <= self.beta <= 320.0):
            raise ValueError("beta must remain in the 2SC458C data-sheet sweep")
        if not (0.0 <= self.vce_sat_v <= 0.30):
            raise ValueError("VCE(sat) must remain bounded")
        if self.diode_dynamic_ohm is not None and self.diode_dynamic_ohm < 0.0:
            raise ValueError("diode dynamic resistance must be non-negative")
        if self.bjt_input_ohm is not None and self.bjt_input_ohm <= 0.0:
            raise ValueError("BJT input resistance must be positive")


@dataclass(frozen=True)
class CommonEmitterBranch:
    """Solved state of one TR1/TR2/TR6 topology instance."""

    base_v: float
    collector_v: float
    diode_current_a: float
    base_current_a: float
    collector_current_a: float
    region: str


@dataclass(frozen=True)
class D8BranchDrives:
    """Instantaneous, named D8 op-amp-node voltages for a DC/KCL snapshot.

    These are inputs rather than hidden fitted waveform controls.  A transient
    MNA step supplies them after it solves the capacitor/op-amp equations.
    Keeping this interface explicit makes the three common-emitter branches
    independently testable and prevents the historic (incorrect) serial
    TR1->TR2->TR6 interpretation.
    """

    ic3d_out_v: float
    ic3b_plus_v: float
    ic5b_out_v: float
    ic5a_plus_v: float
    ic7c_out_v: float
    ic7b_minus_v: float


@dataclass(frozen=True)
class D8BranchSnapshot:
    """All independently traced common-emitter states at one MNA time step."""

    tr1: CommonEmitterBranch
    tr2: CommonEmitterBranch
    tr6: CommonEmitterBranch


@dataclass
class D8TransientState:
    """Physical capacitor voltages and bounded op-amp outputs for D8.

    Capacitor values are stored as V(positive endpoint)-V(negative endpoint),
    matching the MNA specification.  This state is a numerical-reference
    artifact; it is intentionally not fixed-point RTL.
    """

    c7_v: float = 0.0       # IC3-B pin13(-) - IC3-B out
    c154_v: float = 0.0     # IC5-A pin13(-) - IC5-A out
    c17_v: float = 0.0      # IC5-B out - C17/R70 node
    cfb_v: float = 0.0      # IC7-B pin6(-) - IC7-B out
    c6_v: float = 0.0       # N_LOOP - IC7-B/IC7-C shared output node
    v_tacho_v: float = 0.0  # IC5-C R65/R67/C16 bias state
    ic3d_out_v: float = 0.0
    ic5b_out_v: float = 0.0
    ic7c_out_v: float = 0.0


@dataclass(frozen=True)
class D8TransientSample:
    """Auditable output of one bounded D8 numerical time step."""

    n_a_v: float
    n_bplus_v: float
    n_bminus_v: float
    n_bout_v: float
    n_5aplus_v: float
    n_5aminus_v: float
    n_5aout_v: float
    n_5bout_v: float
    n_loop_v: float
    n_7bplus_v: float
    n_7bminus_v: float
    n_7bout_v: float
    n_d8_v: float
    c6_current_a: float
    branches: D8BranchSnapshot

    @property
    def n_src_v(self) -> float:
        """Explicit lower-IC3 pin-8 source boundary (legacy field is n_a_v)."""
        return self.n_a_v


def _clamp(value: float, low: float, high: float) -> float:
    return min(high, max(low, value))


def solve_common_emitter_branch(*, feedback_drive_v: float,
                                collector_drive_v: float,
                                collector_res_ohm: float,
                                series_res_ohm: float = 10_000.0,
                                base_shunt_ohm: float = 2_200.0,
                                corner: DeviceCorner = DeviceCorner()) -> CommonEmitterBranch:
    """Solve the bounded static KCL for one traced common-emitter branch.

    The MA150 feed is a complementarity diode with a named dynamic-resistance
    corner. The BJT is cutoff below VBE, forward-active at beta*IB, then
    collector-resistor/VCE-saturation limited. This is a DC primitive: the
    caller's implicit transient solver owns all D8 capacitor companion models.
    """
    corner.validate()
    if corner.diode_dynamic_ohm is None or corner.bjt_input_ohm is None:
        raise ValueError("unmeasured diode/BJT dynamic resistances require explicit sweep corners")
    if min(collector_res_ohm, series_res_ohm, base_shunt_ohm) <= 0.0:
        raise ValueError("traced branch resistors must be positive")
    drive = _clamp(feedback_drive_v, corner.lm324_low_v, corner.lm324_high_v)
    cdrive = _clamp(collector_drive_v, corner.lm324_low_v, 12.0)
    rfeed = series_res_ohm + corner.diode_dynamic_ohm

    # The base-node KCL is monotonic, so bisection is deterministic and avoids
    # choosing a non-physical root.  iD = Vb/Rshunt + iB.
    def residual(vb: float) -> float:
        diode = max(0.0, (drive - corner.vf_v - vb) / rfeed)
        ib = max(0.0, (vb - corner.vbe_v) / corner.bjt_input_ohm)
        return diode - vb / base_shunt_ohm - ib

    lo, hi = 0.0, max(0.0, drive - corner.vf_v)
    # 40 bisection iterations leave <10 pico-volt error over the 10.5-V
    # bounded interval, while keeping corner sweeps practical.
    for _ in range(40):
        mid = (lo + hi) * 0.5
        if residual(mid) > 0.0:
            lo = mid
        else:
            hi = mid
    base_v = (lo + hi) * 0.5
    diode_i = max(0.0, (drive - corner.vf_v - base_v) / rfeed)
    base_i = max(0.0, (base_v - corner.vbe_v) / corner.bjt_input_ohm)
    active_ic = corner.beta * base_i
    saturated_ic = max(0.0, (cdrive - corner.vce_sat_v) / collector_res_ohm)
    collector_i = min(active_ic, saturated_ic)
    collector_v = _clamp(cdrive - collector_i * collector_res_ohm,
                         corner.vce_sat_v if collector_i else 0.0, cdrive)
    region = "cutoff" if base_i == 0.0 else ("saturation" if active_ic > saturated_ic else "forward_active")
    return CommonEmitterBranch(base_v, collector_v, diode_i, base_i,
                               collector_i, region)


def solve_d8_common_emitter_snapshot(*, drives: D8BranchDrives,
                                     corner: DeviceCorner) -> D8BranchSnapshot:
    """Solve TR1/TR2/TR6 from their corrected *physical* D8 connections.

    The series/base paths are D9/R10->D9, R24->D3, and R80->D14. In each
    case the output drives a diode then 10 kOhm into the 2.2-kOhm base shunt.
    Collector feeds are respectively IC3-B+ through R15=120k, IC5-A+ through
    R22=68k, and IC7-B- through R84=68k. This is the point where voltage and
    current derive from the full traced topology rather than a generic clamp.
    """
    return D8BranchSnapshot(
        tr1=solve_common_emitter_branch(
            feedback_drive_v=drives.ic3d_out_v,
            collector_drive_v=drives.ic3b_plus_v,
            collector_res_ohm=TRACED_D8["ic3b"]["collector_r"],
            corner=corner),
        tr2=solve_common_emitter_branch(
            feedback_drive_v=drives.ic5b_out_v,
            collector_drive_v=drives.ic5a_plus_v,
            collector_res_ohm=TRACED_D8["ic5a"]["collector_r"],
            corner=corner),
        tr6=solve_common_emitter_branch(
            feedback_drive_v=drives.ic7c_out_v,
            collector_drive_v=drives.ic7b_minus_v,
            collector_res_ohm=TRACED_D8["ic7b"]["collector_r"],
            corner=corner),
    )


def _weighted_node(*legs: tuple[float, float]) -> float:
    """Voltage at a resistor-only node; each leg is (voltage, resistance)."""
    conductance = sum(1.0 / resistance for _, resistance in legs)
    return sum(voltage / resistance for voltage, resistance in legs) / conductance


def _rail_comparator(*, plus_v: float, minus_v: float,
                     corner: DeviceCorner) -> float:
    """Ideal LM324 comparator reduction with only documented output bounds."""
    return corner.lm324_high_v if plus_v > minus_v else corner.lm324_low_v


def step_d8_transient(*, state: D8TransientState, n_a_v: float, dt_s: float,
                      corner: DeviceCorner) -> D8TransientSample:
    """Advance the traced D8 network using the authoritative implicit solver.

    ``n_a_v`` is retained as a compatibility name for the proven lower-IC3
    pin-8 ``N_SRC`` source boundary; callers that include C110 should use the
    implicit reference's ``step_with_c110`` wrapper first.  The earlier local
    reduction used explicit Euler updates at the rail and
    therefore produced a spurious ~170-Hz cycle.  The rail companion equation
    is part of the physical feedback path: when an LM324 is saturated its
    inverting node is *not* forced to the virtual-short voltage.  The
    authoritative implementation lives in ``playercar_d8_implicit_reference``
    and solves that piecewise/backward-Euler network.  This wrapper keeps the
    historical bounded-reference API and exposes the same named nodes for
    traces and corner tests, so the two references cannot silently diverge.
    """
    corner.validate()
    if corner.diode_dynamic_ohm is None or corner.bjt_input_ohm is None:
        raise ValueError("D8 transient solve requires explicit rd and rBE corners")
    if not (dt_s > 0.0):
        raise ValueError("D8 transient timestep must be positive")

    # Keep one numerical authority.  The implicit model owns the rail-aware
    # backward-Euler companion equations; this compatibility wrapper merely
    # adapts its state/result to the older bounded-reference API.
    from playercar_d8_implicit_reference import ImplicitState, step

    implicit_state = ImplicitState(
        q_c7=state.c7_v,
        q_c154=state.c154_v,
        q_c17=state.c17_v,
        q_cfb=state.cfb_v,
        q_c6=state.c6_v,
        v_tacho=state.v_tacho_v,
        ic3d_out_v=state.ic3d_out_v,
        ic5b_out_v=state.ic5b_out_v,
        ic7c_out_v=state.ic7c_out_v,
    )
    sample = step(implicit_state, n_a_v, dt_s=dt_s, corner=corner)

    state.c7_v = implicit_state.q_c7
    state.c154_v = implicit_state.q_c154
    state.c17_v = implicit_state.q_c17
    state.cfb_v = implicit_state.q_cfb
    state.c6_v = implicit_state.q_c6
    state.v_tacho_v = implicit_state.v_tacho
    state.ic3d_out_v = implicit_state.ic3d_out_v
    state.ic5b_out_v = implicit_state.ic5b_out_v
    state.ic7c_out_v = implicit_state.ic7c_out_v

    branches = solve_d8_common_emitter_snapshot(
        drives=D8BranchDrives(sample.n_dout, sample.n_bplus,
                              sample.n_5bout, sample.n_5aplus,
                              sample.n_7cout, sample.n_7bminus),
        corner=corner)
    return D8TransientSample(
        sample.n_a, sample.n_bplus, sample.n_bminus, sample.n_bout,
        sample.n_5aplus, sample.n_5aminus, sample.n_5aout,
        sample.n_5bout, sample.n_loop, sample.n_7bplus,
        sample.n_7bminus, sample.n_7bout, sample.n_d8,
        sample.c6_current_a, branches)


def _self_check() -> None:
    validate_traced_d8()
    synthetic_corner = DeviceCorner(diode_dynamic_ohm=1.0,
                                    bjt_input_ohm=10_000.0)
    off = solve_common_emitter_branch(feedback_drive_v=0.0, collector_drive_v=6.0,
                                      collector_res_ohm=68_000.0,
                                      corner=synthetic_corner)
    on = solve_common_emitter_branch(feedback_drive_v=10.5, collector_drive_v=6.0,
                                     collector_res_ohm=68_000.0,
                                     corner=synthetic_corner)
    assert off.region == "cutoff" and abs(off.collector_current_a) < 1e-15
    assert on.collector_current_a > 0.0 and on.collector_v < 6.0
    snapshot = solve_d8_common_emitter_snapshot(
        drives=D8BranchDrives(10.5, 6.0, 0.0, 6.0, 10.5, 6.0),
        corner=synthetic_corner)
    assert snapshot.tr1.collector_current_a > 0.0
    assert snapshot.tr2.region == "cutoff"
    assert snapshot.tr6.collector_current_a > 0.0
    transient = D8TransientState()
    for _ in range(100):
        sample = step_d8_transient(state=transient, n_a_v=6.0, dt_s=1e-6,
                                   corner=synthetic_corner)
    assert 0.0 <= sample.n_d8_v <= 10.5
    assert 0.0 <= sample.n_loop_v <= 10.5
    print("PASS playercar_d8_bounded_reference topology + common-emitter primitive")


if __name__ == "__main__":
    _self_check()
