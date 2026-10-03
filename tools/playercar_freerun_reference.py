"""Checkpoint 2: complete free-running Turbo player-car (D-8/D-9) reference.

This module closes the one gap left open by the Gate 1/Gate 2 prior art in
`reference/TurboAudio_Rework_20260812/model/tools/gate1_playercar_reference.py`
(imported directly below, not re-derived): that module's `D8SourceBoundary`
only supports a HELD/injected upstream waveform (`d8_waveform_mode in
("external","sine","ic7_feedback")`, see its own docstring and
`D8_UPSTREAM_WAVEFORM_CONTRACT`). Per the current task mandate, production
audio may not consume a held/injected/verification-only waveform, so this
file adds `FreeRunningD8Source`, a genuinely free-running oscillator, and
reuses every other stage (ACC ladder, BCONT0/1/2, five MB4391M VCA halves,
SLF, protected upright mixer contract) byte-for-byte from the Gate 1 module.

Confidence labels (see reference/.../00_CURRENT_STATE_AND_RULES.md):

* TRACED: the IC7-B integrator's C_FB = C20+C21 = 47.68 nF and R87 feedback
  topology (model/GATE1_PLAYER_CAR_EQUATIONS.md section 8; also IC7-B/IC7-C
  rows of model/GATE0B_PLAYER_CAR_PIN_NETLIST.md, which names IC7-C the
  "comparator/mixer drive" fed by R81/R82/C6 -- i.e. the traced topology
  class is integrator (IC7-B) + hysteretic comparator (IC7-C), the same
  family already built elsewhere in this codebase as rtl/audio/relax_vco.sv).
* BOUNDED: the comparator hysteresis band. R81/R82/C6's exact values are not
  legible on the recovered evidence, so the half-band is an explicit named
  parameter, not a measured threshold.
* BEHAVIORAL: the TR1/TR2 charge-current law. model/GATE1_COMPLETION_REVIEW.md
  names this the exact remaining blocker (PC-D8-01: LM324 package rail
  continuity and the IC3/IC5/TR1/TR2/IC7 hybrid loop's device/load values are
  not closed). Per the mandate, this is bridged with an explicit bounded
  behavioral current law -- charge current is a function of the ACC-ladder
  speed voltage (N_IC3A_OUT, the pin netlist's own "actual D8 speed/shaper
  source") -- rather than blocking the whole model on unavailable Vbe/hFE
  data. This is a declared engineering abstraction, not a claimed
  board-exact D8 waveform.

The result is a pure function of ACC(0-63)/BSEL(0-3) and elapsed time: no
external/injected audio input exists anywhere in this file.
"""
from __future__ import annotations

import math
import sys
from pathlib import Path

REFERENCE_TOOLS = next(iter(sorted(Path(__file__).resolve().parents[1].parents[2].glob(
    "*/reference/TurboAudio_Rework_20260812/model/tools"))), Path("."))
if str(REFERENCE_TOOLS) not in sys.path:
    sys.path.insert(0, str(REFERENCE_TOOLS))

import gate1_playercar_reference as g1  # noqa: E402  (path set above)


class FreeRunningD8Source(g1.D8SourceBoundary):
    """Genuinely free-running IC7-B/IC7-C relaxation oscillator.

    Structurally: an integrator (real C_FB=47.68 nF, real R87) whose charge
    current alternates sign at a symmetric hysteretic comparator threshold
    around the IC7-B non-inverting bias -- the same triangle/relax-VCO class
    already used by rtl/audio/relax_vco.sv, but grounded in the recovered
    IC7-B time constant instead of an arbitrary placeholder one, and with the
    charge current itself (not just an output LUT) driven by the ACC ladder.
    """

    # BOUNDED: comparator half-band. R81/R82/C6 exact values are unread.
    HYST_V = 0.35

    # BEHAVIORAL: TR1/TR2 charge-current law. The base class's own
    # `d8_behavioral_hz_at_0v`/`d8_behavioral_hz_per_v` (35 Hz idle,
    # +28 Hz/V, ~371 Hz at V_SUPPLY=12 V ladder voltage -- g1.Parameters,
    # its established engine-pitch behavioral calibration) is the target;
    # these currents are solved from freq = i_charge / (2*C_FB*HYST_V) so the
    # free-running relaxation oscillator lands on that same calibrated
    # frequency law instead of inventing a separate, unchecked one:
    #   i_base  = 35 Hz * 2*C_FB*HYST_V = 1.1682e-6 A
    #   i_per_v = 28 Hz * 2*C_FB*HYST_V = 9.3453e-7 A/V
    # (An earlier draft picked 3.6e-5/5.0e-5 A without checking the resulting
    # frequency -- that landed near 1.1 kHz, not the intended engine range;
    # corrected here.)
    I_CHARGE_BASE_A = 1.1682e-6
    I_CHARGE_PER_V_A = 9.3453e-7

    def __init__(self, p: g1.Parameters):
        super().__init__(p)
        self.osc_v: float | None = None
        self.rising = True

    def step(self, speed_v: float, dt: float,
              injected_v: float | None = None) -> dict[str, float | str]:
        # `injected_v` is accepted only for base-class signature compatibility
        # (PlayerCarReference.step always tries to pass source_inputs) and is
        # never read: this oscillator never consumes external/injected audio.
        p = self.p
        ic3a_out = g1.clamp(speed_v, 0.0, g1.V_SUPPLY)
        slf_source, _ = g1.slf_source_thevenin(ic3a_out, p)
        cfb = g1.ic7b_feedback_capacitance(p)

        divider_g = 1.0 / p.ic7b_r85_ohm + 1.0 / p.ic7b_r86_ohm
        # IC7-B non-inverting bias is source-independent once the source is
        # this self-generated oscillator rather than an external V_SRC.
        bias_v = (g1.V_BIAS / p.ic7b_r85_ohm) / divider_g

        if self.osc_v is None:
            self.osc_v = bias_v

        i_charge = self.I_CHARGE_BASE_A + self.I_CHARGE_PER_V_A * ic3a_out
        direction = 1.0 if self.rising else -1.0
        self.osc_v += direction * (i_charge / cfb) * dt

        hi = bias_v + self.HYST_V
        lo = bias_v - self.HYST_V
        if self.rising and self.osc_v >= hi:
            self.osc_v = hi
            self.rising = False
        elif (not self.rising) and self.osc_v <= lo:
            self.osc_v = lo
            self.rising = True

        self.osc_v = g1.clamp(self.osc_v, p.d8_opamp_low_v, p.d8_opamp_high_v)
        audio_v = self.osc_v - bias_v
        frequency = i_charge / (cfb * 2.0 * self.HYST_V) if self.HYST_V > 0 else 0.0

        return {
            "ic3a_out_v": ic3a_out,
            "slf_source_v": slf_source,
            "frequency_hz": frequency,
            "audio_v": audio_v,
            "d8_upstream_v": 0.0,
            "d8_source_boundary_v": bias_v,
            "d8_waveform_contract": "FREE-RUNNING-IC7B-IC7C-RELAX-v1",
            "audio_status": (
                "TRACED IC7-B C_FB/R87 topology; BOUNDED comparator "
                "hysteresis; BEHAVIORAL ACC-driven charge current "
                "(no injected/external input)"
            ),
        }


class FreeRunningPlayerCarReference(g1.PlayerCarReference):
    """Same as g1.PlayerCarReference but with a genuinely free-running D8."""

    def __init__(self, parameters: g1.Parameters | None = None,
                 state: g1.State | None = None):
        self.p = parameters or g1.Parameters()
        self.p.validate()
        self.s = state or g1.State()
        self.d8 = FreeRunningD8Source(self.p)

    def step(self, acc: int, bsel: int,
              dt: float = 1.0 / g1.FS) -> dict[str, object]:
        # source_inputs is intentionally never passed: this reference has no
        # injected-audio path at all, unlike the base class.
        return super().step(acc, bsel, dt, source_inputs=None)


def _self_check() -> None:
    fs = g1.FS
    print(f"FS = {fs:.4f} Hz")
    for acc in (0, 4, 32, 63):
        for bsel in (0, 1, 2, 3):
            model = FreeRunningPlayerCarReference()
            # Settle the ACC ladder / BCONT RC networks well past their
            # longest traced time constant before sampling.
            settle_samples = int(0.6 * fs)
            for _ in range(settle_samples):
                model.step(acc, bsel)
            f_vals, w_vals, m_vals, slf_vals = [], [], [], []
            n = int(0.05 * fs)
            for _ in range(n):
                row = model.step(acc, bsel)
                upright = row["upright_two_speaker"]
                stk = upright["stk439_inputs_v"]
                f_vals.append(stk["IN1_from_F_OUT"])
                w_vals.append(stk["IN2_from_W_OUT"])
                m_vals.append(upright["mixer_ii_bus_v"]["M"])
                slf_vals.append(row["slf"])

            def rms(xs: list[float]) -> float:
                return math.sqrt(sum(x * x for x in xs) / len(xs))

            def pp(xs: list[float]) -> float:
                return max(xs) - min(xs)

            print(
                f"ACC={acc:2d} BSEL={bsel} "
                f"F rms={rms(f_vals):.5f} pp={pp(f_vals):.5f} "
                f"W rms={rms(w_vals):.5f} pp={pp(w_vals):.5f} "
                f"M rms={rms(m_vals):.5f} pp={pp(m_vals):.5f} "
                f"SLF pp={pp(slf_vals):.5f}"
            )
            if bsel != 3:
                assert pp(f_vals) > 1e-6, "expected continuously audible F tap"
                assert pp(w_vals) > 1e-6, "expected continuously audible W tap"
            else:
                assert pp(f_vals) < 1e-3, "expected BSEL=3 mute on F tap"
    print("PASS playercar_freerun_reference self-check "
          "(non-degenerate, no injected audio anywhere)")


if __name__ == "__main__":
    _self_check()
