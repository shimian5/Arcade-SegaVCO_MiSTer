#!/usr/bin/env python3
"""Implicit, bounded D8 reference model.

This module is a reference-side implementation of the reconciled D8 graph.
It is deliberately not release RTL.  The LM324 sections are ideal within the
documented 0..10.5 V output envelope; the capacitor companion equations are
solved at the summing nodes, and the 2SC458/MA150 parameters are explicit
corner inputs rather than cabinet-tuned values.

The model's most important job is negative as well as positive evidence: if a
corner settles with no N_BOUT limit cycle, that is a source-boundary result,
not permission to insert an invented oscillator.
"""
from __future__ import annotations

from dataclasses import dataclass
from math import isfinite
from typing import Iterable

from playercar_d8_bounded_reference import (
    DeviceCorner,
    TRACED_D8,
    solve_common_emitter_branch,
)


FS_HZ = 39_935_064.0 / 832.0
DT_S = 1.0 / FS_HZ
VCC = 12.0
VREF = 6.0
VMAX = 10.5


def clamp(value: float, low: float = 0.0, high: float = VMAX) -> float:
    return max(low, min(high, value))


@dataclass
class ImplicitState:
    # C110 is the explicit IC34 ladder hold capacitor.  The caller supplies
    # the held-code Thevenin target/resistance; keeping this state here makes
    # the D8 reference cover the complete ACC -> IC34/C110 -> IC3-A -> lower
    # IC3-B/N_SRC boundary instead of silently treating N_SRC as an ideal
    # external voltage.
    v_c110: float = 0.0
    # Capacitor voltages use the positive-minus-negative endpoint convention
    # from PLAYERCAR_D8_IMPLICIT_MNA_SPEC_20220822.md.
    q_c7: float = 0.0       # IC3-B minus - N_BOUT
    q_c154: float = 0.0     # IC5-A minus - N_5AOUT
    q_c17: float = 0.0      # N_5AOUT - N_C17
    q_cfb: float = 0.0      # IC7-B minus - N_7BOUT
    q_c6: float = 0.0       # N_LOOP - IC7-C minus
    q_c16: float = 0.0      # N_TACHO_BIAS - ground
    q_c47: float = 0.0      # N_D8 - IC17 pin 1; downstream load is unknown
    v_tacho: float = 0.0
    # Rail states of the positive-feedback LM324 stages. These are separate
    # from capacitor voltages because the schematic gives them hysteresis.
    ic3d_out_v: float = 0.0
    ic5b_out_v: float = 0.0
    ic7c_out_v: float = 0.0


@dataclass(frozen=True)
class ImplicitSample:
    n_a: float
    n_bplus: float
    n_bminus: float
    n_bout: float
    n_dout: float
    n_5aplus: float
    n_5aminus: float
    n_5aout: float
    n_5bout: float
    n_c17: float
    n_loop: float
    n_7bplus: float
    n_7bminus: float
    n_7bout: float
    n_7cout: float
    c6_current_a: float
    n_d8: float
    v_tacho: float
    tr1_region: str
    tr2_region: str
    tr6_region: str

    @property
    def n_src(self) -> float:
        """Explicit lower-IC3 pin-8 source boundary (legacy field is n_a)."""
        return self.n_a


def _ideal_d_from_minus(vminus: float, r_to_ref: float, r_feedback: float) -> float:
    """Output needed to make (VREF/Rref + Vout/Rfb) equal vminus."""
    return clamp((vminus * (r_to_ref + r_feedback) - VREF * r_feedback) / r_to_ref)


def _schmitt_from_minus(previous_output: float, vminus: float,
                        r_to_ref: float = 51_000.0,
                        r_feedback: float = 100_000.0) -> float:
    """Bounded LM324 Schmitt stage with 6-V/output positive feedback.

    The D8 drawings place the 6-V trim and the op-amp output on the ``+``
    input (R54/R25, R26/R25 and R82/R81).  Those are not linear inverting
    amplifiers: the supported 0..10.5-V LM324 envelope gives two switching
    thresholds, and the previous rail state supplies hysteresis inside the
    interval.  Keeping this as a rail state is both synthesizable later and
    avoids inventing a mid-rail transfer that the schematic cannot produce.
    """
    low_threshold = VREF * r_feedback / (r_to_ref + r_feedback)
    high_threshold = (VREF * r_feedback + VMAX * r_to_ref) / (
        r_to_ref + r_feedback)
    previous = VMAX if previous_output >= (VMAX * 0.5) else 0.0
    if previous <= 0.0:
        return VMAX if vminus <= low_threshold else 0.0
    return 0.0 if vminus >= high_threshold else VMAX


def _node_divider(*legs: tuple[float, float]) -> float:
    g = sum(1.0 / r for _, r in legs)
    return sum(v / r for v, r in legs) / g


def _be_tacho(previous: float, dt_s: float) -> float:
    """Backward-Euler R65/R67/C16 bias node, including its measured values."""
    r65 = 2_700.0
    r67 = 2_200.0
    c16 = 47e-6
    g_c = c16 / dt_s
    return (g_c * previous + VCC / r65) / (g_c + 1.0 / r65 + 1.0 / r67)


def _be_c110(previous: float, target: float, r_thevenin_ohm: float,
             dt_s: float) -> float:
    """Backward-Euler IC34/C110 ladder hold node.

    C110 is to ground at the IC34 ladder output.  The ladder target and its
    Thevenin resistance are already solved by the traced ladder reference;
    this helper deliberately accepts both rather than inventing a resistor
    value in the D8 network.
    """
    if r_thevenin_ohm <= 0.0 or dt_s <= 0.0:
        raise ValueError("C110 requires positive Thevenin resistance and timestep")
    target = clamp(target)
    g_c = 1.0e-6 / dt_s
    g_th = 1.0 / r_thevenin_ohm
    return (g_c * previous + g_th * target) / (g_c + g_th)


def _be_opamp_feedback_cap(previous_q: float, source_v: float, plus_v: float,
                           resistance_ohm: float, capacitance_f: float,
                           dt_s: float, load_current_a: float = 0.0
                           ) -> tuple[float, float, float]:
    """Advance a capacitor-feedback op-amp node with explicit rail recovery.

    ``q`` is V(minus)-V(output), the capacitor's physical voltage.  When the
    ideal-op-amp output is inside its 0..10.5-V envelope, V(minus)=V(plus)
    and the usual integrator relation applies.  At a rail, the input node is
    no longer forced to V(plus); the capacitor must continue charging through
    the source resistor so the stage can recover and switch again.  The old
    reference overwrote q with ``plus-output`` at a rail, which froze the
    integrator and falsely made the network settle instead of oscillate.
    """
    g_c = capacitance_f / dt_s
    g_r = 1.0 / resistance_ohm
    # The transistor collector resistor is connected to the op-amp's
    # inverting node on the primary sheet.  Its current therefore loads the
    # capacitor companion equation; it is not a load on the plus divider.
    q_pred = (previous_q +
              dt_s * (source_v - plus_v) /
              (resistance_ohm * capacitance_f) -
              dt_s * load_current_a / capacitance_f)
    output_pred = plus_v - q_pred
    if output_pred < 0.0:
        output = 0.0
        # V(minus)=q+V(output)=q at the low rail.
        q_new = (g_c * previous_q + g_r * source_v - load_current_a) / (g_c + g_r)
    elif output_pred > VMAX:
        output = VMAX
        # V(minus)=q+VMAX at the high rail.
        q_new = (g_c * previous_q + g_r * (source_v - VMAX) -
                 load_current_a) / (g_c + g_r)
    else:
        q_new = q_pred
        output = output_pred
    # q is V(minus)-V(output), including the rail case where the virtual
    # short is intentionally not imposed.
    return q_new, output, q_new + output


def _be_c17(previous_q: float, n_5bout: float, v_tacho: float, dt_s: float) -> float:
    """Solve C17 node KCL with R70 to the IC5-C inverting node.

    The D8 trace places C17's positive terminal on IC5-A output; IC5-B
    output is the following op-amp stage and is not the capacitor source.
    """
    c17 = 22e-6
    r70 = 15_000.0
    g_c = c17 / dt_s
    return (g_c * previous_q + (n_5bout - v_tacho) / r70) / (g_c + 1.0 / r70)


def _be_series_cap(previous_q: float, source_v: float, target_v: float,
                   capacitance_f: float, resistance_ohm: float,
                   dt_s: float) -> float:
    """Backward-Euler q=source-node minus resistor-node companion state."""
    g_c = capacitance_f / dt_s
    return (g_c * previous_q + (source_v - target_v) / resistance_ohm) / (
        g_c + 1.0 / resistance_ohm
    )


def _series_cap_current(source_v: float, q_v: float, target_v: float,
                        resistance_ohm: float) -> float:
    """Current through the C6/R36 branch into the low-impedance node.

    ``q_v`` is the capacitor voltage ``N_LOOP - N_C6_RIGHT``.  The right
    capacitor plate drives the IC7-C/IC7-B output node through R36, so the
    instantaneous branch current is ``(N_C6_RIGHT - N_7BOUT)/R36``.  Keeping
    this current explicit prevents the old shortcut ``q_c6 = N_LOOP-N_7BOUT``
    from silently deleting R36 and the capacitor state.  The ideal-op-amp
    reduction does not feed this output-load current back into the virtual
    short; that remaining rail/output-impedance effect is an identified
    bounded uncertainty, not a hidden audio shaper.
    """
    return (source_v - q_v - target_v) / resistance_ohm


def _branch(*, drive: float, collector_drive: float, collector_r: float,
            corner: DeviceCorner):
    return solve_common_emitter_branch(
        feedback_drive_v=drive,
        collector_drive_v=collector_drive,
        collector_res_ohm=collector_r,
        corner=corner,
    )


def step(state: ImplicitState, n_a_v: float, *, dt_s: float = DT_S,
         corner: DeviceCorner, iterations: int = 24) -> ImplicitSample:
    """Advance one bounded implicit step through the corrected D8 topology."""
    corner.validate()
    if corner.diode_dynamic_ohm is None or corner.bjt_input_ohm is None:
        raise ValueError("explicit rd and rpi corners are required")
    if not isfinite(n_a_v) or dt_s <= 0.0:
        raise ValueError("invalid input or timestep")

    n_a = clamp(n_a_v)
    v_tacho = _be_tacho(state.v_tacho, dt_s)

    # The legacy API calls this argument N_A, but the proven electrical node
    # is the lower IC3 pin-8 output N_SRC.  IC3-A is a unity follower from
    # C110 into lower IC3-B; the lower follower output is the fork node.  The
    # remaining local R/C network is modeled below.  R13/R12 form the IC3-D
    # non-inverting divider; R14/C7 feed its inverting node.  The primary
    # image shows the IC5-A branch leaving this same N_A fork, not the later
    # IC3-D/IC3-A output.
    bplus = _node_divider((n_a, 51_000.0), (0.0, 51_000.0))
    bminus = bplus
    bout = clamp(bplus - state.q_c7)
    dout = _schmitt_from_minus(state.ic3d_out_v, bout)
    tr1 = None
    for _ in range(iterations):
        # R15 returns the TR1 collector to the IC3-D inverting node.  Include
        # that bounded collector current in the C7 companion KCL.
        q_trial, bout_trial, bminus = _be_opamp_feedback_cap(
            state.q_c7, n_a, bplus, 270_000.0, 0.1e-6, dt_s,
            load_current_a=0.0 if tr1 is None else tr1.collector_current_a)
        bout = clamp(bout_trial)
        dout = _schmitt_from_minus(state.ic3d_out_v, bout)
        tr1 = _branch(drive=dout, collector_drive=bminus,
                      collector_r=120_000.0, corner=corner)
    q_c7, bout, bminus = _be_opamp_feedback_cap(
        state.q_c7, n_a, bplus, 270_000.0, 0.1e-6, dt_s,
        load_current_a=0.0 if tr1 is None else tr1.collector_current_a)
    bout = clamp(bout)

    # IC5-A is the second branch from N_A.  R19/C154 feed its inverting node;
    # R20/R21 make the independent non-inverting divider.  TR2's collector
    # resistor returns to the IC5-A minus node, not to that divider.
    aplus = _node_divider((n_a, 51_000.0), (0.0, 51_000.0))
    aminus = aplus
    aout = clamp(aplus - state.q_c154)
    b5out = _schmitt_from_minus(state.ic5b_out_v, aout)
    tr2 = None
    for _ in range(iterations):
        q_trial, aout_trial, aminus = _be_opamp_feedback_cap(
            state.q_c154, n_a, aplus, 150_000.0, 0.1e-6, dt_s,
            load_current_a=0.0 if tr2 is None else tr2.collector_current_a)
        aout = clamp(aout_trial)
        # IC5-B plus node is (6V through 51k) || (output through 100k).
        b5out = _schmitt_from_minus(state.ic5b_out_v, aout)
        tr2 = _branch(drive=b5out, collector_drive=aminus,
                      collector_r=68_000.0, corner=corner)
    q_c154, aout, aminus = _be_opamp_feedback_cap(
        state.q_c154, n_a, aplus, 150_000.0, 0.1e-6, dt_s,
        load_current_a=0.0 if tr2 is None else tr2.collector_current_a)
    aout = clamp(aout)

    # IC5-C is biased by the measured 5.387755-V R65/R67 divider.  C17's
    # companion equation determines the IC5-C inverting-node voltage.
    q_c17 = _be_c17(state.q_c17, aout, v_tacho, dt_s)
    n_c17 = aout - q_c17
    loop = clamp(v_tacho + (10_000.0 / 15_000.0) * (v_tacho - n_c17))

    # IC7-B/C and TR6.  CFB is in the IC7-B summing-node KCL.  IC7-C pin 2(-)
    # is directly wired to IC7-B output; C6/R36 is an additional load/current
    # path into that low-impedance node, not the voltage source for a second
    # independent Schmitt input.
    b7plus = clamp(loop * 0.5)
    b7out = clamp(b7plus - state.q_cfb)
    q_c6 = state.q_c6
    b7minus = b7out
    c7out = 0.0
    tr6 = None
    cfb = 0.047e-6 + 680e-12
    for _ in range(iterations):
        b7minus = b7out
        c7out = _schmitt_from_minus(state.ic7c_out_v, b7minus)
        tr6 = _branch(drive=c7out, collector_drive=b7minus,
                      collector_r=68_000.0, corner=corner)
        i_res = ((b7plus - loop) / 150_000.0 +
                 (b7plus - tr6.collector_v) / 68_000.0)
        b7out = clamp(b7plus - state.q_cfb + dt_s * i_res / cfb)
        q_c6 = _be_series_cap(state.q_c6, loop, b7out,
                              22e-6, 10_000.0, dt_s)
    q_cfb = b7plus - b7out
    b7minus = b7out
    c6_current = _series_cap_current(loop, q_c6, b7minus, 10_000.0)

    # D8's measured electrical boundary.  C47's far-side impedance is absent
    # from the sheet, so preserve N_D8 as the auditable boundary and carry its
    # unknown-load capacitor voltage without pretending it is an audio pole.
    d8_overdrive = max(0.0, bout - corner.vf_v)
    n_d8 = d8_overdrive * 10_000.0 / (39_000.0 + corner.diode_dynamic_ohm + 10_000.0)
    q_c47 = n_d8  # zero-volt far-side reference only; no load claim is made

    state.q_c7 = q_c7
    state.q_c154 = q_c154
    state.q_c17 = q_c17
    state.q_cfb = q_cfb
    state.q_c6 = q_c6
    state.q_c16 = v_tacho
    state.q_c47 = q_c47
    state.v_tacho = v_tacho
    state.ic3d_out_v = dout
    state.ic5b_out_v = b5out
    state.ic7c_out_v = c7out

    assert tr1 is not None and tr2 is not None and tr6 is not None
    return ImplicitSample(
        n_a=n_a, n_bplus=bplus, n_bminus=bminus, n_bout=bout, n_dout=dout,
        n_5aplus=aplus, n_5aminus=aminus, n_5aout=aout, n_5bout=b5out,
        n_c17=n_c17, n_loop=loop, n_7bplus=b7plus, n_7bminus=b7minus,
        n_7bout=b7out, n_7cout=c7out, c6_current_a=c6_current,
        n_d8=n_d8, v_tacho=v_tacho,
        tr1_region=tr1.region, tr2_region=tr2.region, tr6_region=tr6.region,
    )


def step_with_c110(state: ImplicitState, ladder_target_v: float,
                   ladder_thevenin_ohm: float, *, dt_s: float = DT_S,
                   corner: DeviceCorner,
                   iterations: int = 24) -> ImplicitSample:
    """Advance the full traced boundary including the ACC/C110 source state.

    ``ladder_target_v`` and ``ladder_thevenin_ohm`` must come from the
    independently recovered IC34 resistor ladder.  This wrapper closes the
    final previously external D8 input state through the proven
    ``IC34/C110 -> IC3-A -> IC3-B/N_SRC`` chain, without assigning an
    oscillator law to the ladder itself.
    """
    state.v_c110 = _be_c110(state.v_c110, ladder_target_v,
                            ladder_thevenin_ohm, dt_s)
    return step(state, state.v_c110, dt_s=dt_s, corner=corner,
                iterations=iterations)


def _corners() -> Iterable[DeviceCorner]:
    for vbe in (0.55, 0.75):
        for vf in (0.55, 0.85):
            for beta in (160.0, 320.0):
                for rd in (10.0, 1000.0):
                    for rpi in (10_000.0, 100_000.0):
                        yield DeviceCorner(vbe_v=vbe, vf_v=vf, beta=beta,
                                           diode_dynamic_ohm=rd,
                                           bjt_input_ohm=rpi)


def _self_check() -> None:
    corners = list(_corners())
    for corner in corners:
        state = ImplicitState()
        lo, hi = float("inf"), float("-inf")
        for i in range(1_200):
            # Exercise the ACC/C110 boundary without claiming this is the
            # oscillator source: a bounded control transition only.
            n_a = 2.0 if i < 200 else 8.0
            sample = step(state, n_a, corner=corner, iterations=10)
            values = (sample.n_bplus, sample.n_bout, sample.n_dout,
                      sample.n_5aplus, sample.n_5aout, sample.n_5bout,
                      sample.n_loop, sample.n_7bplus, sample.n_7bout,
                      sample.n_7cout, sample.n_d8, sample.v_tacho)
            assert all(isfinite(v) and -1e-9 <= v <= VMAX + 1e-9 for v in values)
            lo = min(lo, *values)
            hi = max(hi, *values)
        assert lo >= -1e-9 and hi <= VMAX + 1e-9
    # A constant-control run is a deliberate negative test for an unevidenced
    # free-running oscillator.  It must not be reinterpreted as a failure of
    # the bounded electrical model.
    state = ImplicitState()
    values = []
    corner = DeviceCorner(diode_dynamic_ohm=10.0, bjt_input_ohm=10_000.0)
    for _ in range(8_000):
        values.append(step(state, 7.8, corner=corner, iterations=10).n_bout)
    assert all(isfinite(v) for v in values)
    print(f"PASS implicit D8 reference corners={len(corners)} "
          f"N_BOUT_range={min(values):.6f}..{max(values):.6f} "
          f"final={values[-1]:.6f}")

    # Explicit C110 boundary check: the ACC ladder transition is now part of
    # the reference state, not an ideal voltage injected at N_A.  The
    # 50-kOhm corner is the documented approximately-50-ms IC34/C110 pole;
    # it is a timing check, not an audio fit.
    c110_state = ImplicitState()
    for i in range(2_000):
        target = 0.0 if i < 200 else 8.0
        sample = step_with_c110(c110_state, target, 50_000.0,
                                dt_s=DT_S, corner=corner, iterations=10)
        assert 0.0 <= sample.n_a <= VMAX
    assert c110_state.v_c110 > 0.0
    print(f"PASS implicit D8 C110 state N_A={c110_state.v_c110:.6f} V")


if __name__ == "__main__":
    _self_check()
