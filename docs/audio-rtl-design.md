# Discrete audio — RTL design contract

Companion to `docs/hardware-audio.md`, which holds the *hardware* facts. This file holds
the *implementation* decisions: numeric formats, clocking, module boundaries, and every
place we knowingly depart from the circuit. Nothing here may contradict
`hardware-audio.md`; if it seems to, the schematic wins and this file is the bug.

Status: **ALARM, FIRE and EXP built and connected.** The mixer is built for all six
channels from the start (see "Why the mixer is built whole"); SHIP, HIT and REBOUND are
still tied to zero.

---

## Approach

RTL is the single source of truth. There is no separate C reference model to drift out of
sync — the synthesizable `.sv` is driven by a Verilator testbench that renders WAV files,
so the thing we listen to *is* the thing that goes on the FPGA.

The discipline this buys only holds if we use it as a **validation** instrument, not an
exploration one. Every stage below is derived from the schematic on paper first and
committed with its numbers; Verilator then confirms or refutes. Filter topology errors and
fixed-point errors sound identical, and chasing both at once is how the title-logo
investigation burned three sessions.

---

## Clocking and sample rate

`clk_sys` = **39,935,064 Hz** (2× the 19.968 MHz board XTAL; see `Arcade-Z80-3D.sv`).

All *digital* hardware (555, 74393, 74123, 74LS38) is modelled at full `clk_sys` rate, so
edges land where the real board puts them. Only the analog tail runs at audio rate.

Audio sample rate: `clk_sys / 832` = **47,999.4 Hz**. MiSTer resamples downstream, so the
0.001 % error is irrelevant; 832 is chosen because it is the nearest integer divisor.

### Anti-aliasing — a deliberate deviation

The real ALARM path has **no** low-pass filter anywhere: R154/C88 is high-pass only, so the
board emits a raw square wave whose harmonics run into the MHz and are rolled off only by
the LA4460 and the speaker. Point-sampling that at 48 kHz would fold those harmonics down
into audible garbage.

So the node bit is **box-averaged over all 832 `clk_sys` cycles** of each output sample
before it enters the analog model. This is a 1st-order CIC decimator. It is not on the
schematic and is not trying to be — it is the minimum band-limiting the sample-rate target
forces on us. Recorded here so nobody later "fixes" it back out.

---

## Numeric formats

Decided now that the model exists (deferred earlier, correctly — the circuit told us the
range it needs rather than us guessing).

| Bus | Format | Scale | Range |
|---|---|---|---|
| Channel `*_MIX` outputs | `signed [15:0]` | **4096 LSB = 1 V** | ±8.000 V |
| Mixer internal / master out | `signed [15:0]` | 4096 LSB = 1 V | ±8.000 V |
| High-pass filter state | `signed [31:0]` | 4096·65536 LSB = 1 V | ±8.000 V |
| Filter coefficients | `unsigned [15:0]` | Q0.16 | — |

All channel buses are **AC quantities centred on zero**, representing volts relative to the
board's 6 V mid-rail. The 6 V rail is the model's zero; it is never represented explicitly.

The filter state carries **16** extra fractional bits because the high-pass pole is at
a = 0.9996, and a leaky integrator that close to unity quantizes to death in 16 bits.

8 extra bits is not enough, which only became visible once the power-on thump gave
`y_state` a negative initial condition. A leaky integrator **stalls** once its per-step
decrement falls below the rounding threshold, at |y| = 0.5/(1−a) = 1260 state LSB. At
4096·256 LSB/V that is 1.2 mV — a *permanent* +10 LSB DC offset on the channel, which six
channels would accumulate. At 4096·65536 LSB/V the same 1260 codes are 4.7 µV, under one
output LSB, and the channel reaches true silence.

Two things this is **not**. It is not coefficient precision: the stall point is 0.5/(1−a)
measured in state LSBs, so carrying the coefficient in Q0.24 does not move it — only
widening the state does. And it is separate from the pole-representation trap recorded
under FIRE, which *is* a coefficient-format problem. Both exist; check for both.

All fixed-point shifts in the analog tail **round to nearest** rather than truncating.
Truncation toward −∞ biases a negative state away from zero on every step, which doubles
the stall offset and gives it a sign.

---

## Module structure

```
rtl/audio/
  audio_top.sv      PPI1 taps, channel instances, mixer, output scaling
  ttl_74123.sv      retriggerable monostable        (reused by FIRE/EXP/HIT/REBOUND)
  ttl_555_astable.sv  free-running astable          (reused by SHIP, REBOUND)
  alarm_chan.sv      555 + 74393 + 4x74123 + wire-OR NAND -> node bit + analog tail
  audio_mixer.sv     passive summing node + IC28
```

`ttl_74123` and `ttl_555_astable` are written as general parts, parameterised by their
timing constants, because every remaining channel needs them. Resisting the urge to inline
them into `alarm_chan` is the whole reason phase 1 is worth doing first.

---

## ALARM channel — the contract

### Stage 1: IC15A 555 astable

Duty cycle is **irrelevant to the output** — the 74393 is a ripple counter, so every tap is
50 % duty regardless of what the 555 does. Modelled faithfully anyway so the part is
reusable by SHIP and REBOUND, where duty *does* matter.

```
t_high = 0.693 * (R29 + R30) * C15 = 0.693 * 740  * 0.1u = 51.282 us = 2048 clk_sys
t_low  = 0.693 *  R30        * C15 = 0.693 * 270  * 0.1u = 18.711 us =  747 clk_sys
period = 2795 clk_sys -> 14,287.3 Hz
```

(`t_high` landing on exactly 2048 cycles is a coincidence, not a design choice.)

### Stage 2: IC16 74LS393 ripple divider

Falling-edge triggered. `1CLR`/`2CLR` grounded — free-running, never reset. `2A` fed from
`1QD`, so the two halves cascade.

### Stage 3: IC3/IC7 74123 monostables — retriggerable

Negative-edge triggered on A; B and CL tied high. Width `tw = 0.45 * R * C`:

| Alarm | R / C | tw | clk_sys cycles |
|---|---|---|---|
| ALARM0 | 47 K / 6.8 µF | 143.82 ms | 5,743,600 |
| ALARM1 | 47 K / 6.8 µF | 143.82 ms | 5,743,600 |
| ALARM2 | 47 K / 6.8 µF | 143.82 ms | 5,743,600 |
| ALARM3 | 47 K / 10 µF  | 211.50 ms | 8,446,470 |

**Retriggerable** — a fresh falling edge restarts the full width, it does not queue.

### Stage 4: IC11 74LS38 open-collector wire-OR

Four OC NANDs share one node pulled to +5 V by R153 1 K. The node is a **single bit**:

```
node = ~( (q0 & tone_2QA) | (q1 & tone_1QD) | (q2 & tone_1QC) | (q3 & tone_1QB) )
```

Tap assignment is from `hardware-audio.md` and is schematic-derived. Resulting tones at the
14,287.3 Hz clock:

| Alarm | tap | divide | tone |
|---|---|---|---|
| ALARM0 | 2QA | ÷32 | 446.5 Hz |
| ALARM1 | 1QD | ÷16 | 893.0 Hz |
| ALARM2 | 1QC | ÷8  | 1785.9 Hz |
| ALARM3 | 1QB | ÷4  | 3571.8 Hz |

These are the **acceptance test**. Note they intentionally disagree with MAME's
`alarm1.wav`/`alarm2.wav`, which are swapped; see `hardware-audio.md`.

### Stage 5: analog tail (R154 / C88 / R155 / R156 / IC29 / R127 / R129 / IC25)

```
node --R154 5.1K-- C88 4.7uF --+-- R156 10K -- +12V
                               |
                               +-- R155 10K -- GND      (Thevenin: 6 V, 5 K)
                               |
                               +-- IC29 pin 5 (+), pin 6 tied to pin 7 = unity follower
                                    -> R127 100K -> IC25 pin 13 (-), R129 200K fb, gain -2
                                    -> C74 2.2uF -> ALARM MIX
```

One-pole high-pass, then ×(−2).

```
R_hp  = R153 1K + R154 5.1K + (R155||R156) 5K = 11.1 K
tau   = 11.1K * 4.7uF = 52.17 ms   (corner 3.051 Hz)
a     = exp(-1 / (47999.4 * 0.05217)) = 0.9996011   -> Q0.16 = 65510
```

Input levels, with the resistive divider applied per node state:

```
node high: 5.00 V * (5K / 11.1K)   = 2.2523 V   ->  9226 LSB
node low:  0.25 V * (5K / 10.11K)  = 0.1236 V   ->   506 LSB     (74LS38 VOL)
```

Because the decimator hands us a *linear average* of the node bit, interpolating between
these two endpoints is exact:

```
x[n] = 506 + ((9226 - 506) * acc) / 832        acc = sum of node bit over the 832 cycles
y[n] = (a * (y[n-1] + x[n] - x[n-1])) >> 16    high-pass, s32 state
ALARM_MIX = -2 * y[n]
```

Peak swing ≈ **±2.13 V** (±8720 LSB).

The high-pass is not cosmetic. Between bursts the node idles at a steady 5 V; at burst
onset its mean drops to the square's average, and C88 recovers over tau = 52 ms — which is
a third of the 144 ms burst. That transient *is* the characteristic click-and-settle of
this channel, so the filter must be a real one-pole, not a DC subtraction.

**Known simplification.** The node's source impedance actually switches: 1 K (R153) when
high, ~10 Ω (saturated gate) when low. We apply the correct divider for each state (the two
constants above) but use a **single** time constant computed from the high state. The error
is confined to the RC recovery rate, differing by ~9 % between half-cycles — far below the
spread in the real 74LS38's V_OL. Documented rather than modelled.

---

## Phase 2 — NOISE and FIRE

### The MB4391 VCA — resolved

The MB4391 is a Sega custom with no public datasheet, and it sets the entire shape of
FIRE, EXP and HIT. It is **two MC3340 electronic attenuators in one 16-pin package**
(community-established; the swap is reported to work in Monaco GP). `docs/reference/
MC3340.pdf` is therefore the primary source, and the schematic corroborates it: our pin
usage is 1 = input, 2 = control, 15 = output, 14 = roll-off with C19 **680 pF**, against
the MC3340's 1 = input, 2 = control, 7 = output, 6 = roll-off with a **620 pF** cap in the
datasheet's own figure. That also independently confirms the earlier "C19 is 680 pF, not
680 µF" correction.

Characteristics: **+13 dB** voltage gain at full open, **80 dB** attenuation range.
The board runs it on the **12 V** rail, so use the Vcc = 12 Vdc curve of datasheet
Figure 3, read as:

| V2 (control, V) | ≤3.1 | 3.5 | 4.0 | 4.5 | 5.0 | ≥5.5 |
|---|---|---|---|---|---|---|
| attenuation (dB) | 0 | 20 | 40 | 60 | 80 | 90 (treat as mute) |

Piecewise model:

```
A(V2) = 0                        V2 <= 3.1
      = 50 * (V2 - 3.1)          3.1 < V2 <= 3.5      (soft knee)
      = 20 + 40 * (V2 - 3.5)     3.5 < V2 <= 5.0      (the linear 40 dB/V region)
      = 80 + 20 * (V2 - 5.0)     V2 > 5.0, clamped at 90
gain  = 10^((13 - A) / 20)
```

Implement as a LUT in V2 with linear interpolation between entries, since the RTL needs
gain, not dB. Figure 3's dashed limit curves span roughly ±0.5 V of the typical, which is
enormous — part-to-part spread, not measurement error. **The knee position is the one
tuning knob for all three VCA channels**; do not chase small discrepancies elsewhere first.

### NOISE — MM5837 (sheet 3)

17-bit LFSR, taps 17 and 14, XOR feedback. Clocked at `sample_ce` (47,999 Hz), inside the
part's nominal 32-64 kHz and avoiding any beat against the audio rate. The real part's
clock is notoriously variable, so this is a documented tuning knob.

**Output amplitude — RESOLVED** from `docs/reference/MM5837.PDF`. The MM5837 is a PMOS
part whose output swings essentially the full V_SS..V_DD span. The board wires
**V_SS (pin 4) = +12 V, V_DD (pin 2) = ground, and V_GG tied to V_DD** — the degraded-V_GG
case, so the datasheet's wider logic-0 limit applies:

```
logical 1: Vss - 1.5 .. Vss   = 10.5 .. 12.0 V
logical 0: Vdd .. Vdd + 3.5   =  0.0 ..  3.5 V     -> swing bounded to 7.0 .. 12.0 Vpp
```

No typical is given, so `NOISE_VPP` = **9.5 V**, the midpoint. Independently, the master
mixer's identical 10 K summing resistor on every channel implies the designer expected
comparable channel amplitudes; solving for the swing that puts FIRE alongside ALARM gives
**9.3 V**. Two unrelated routes to the same figure.

This is the single scaling knob for FIRE, EXP and HIT — all three are linear in it. Note
the datasheet spec is taken under a 20 K/20 K load while this board presents ~77 K, so if
anything the true swing sits above the midpoint.

Two buffered taps via IC29:

| Tap | Network | Gain | Feeds |
|---|---|---|---|
| NOISE·A | C86 10 µF, R140 100 K in, R139 10 K fb | −0.10 | FIRE, EXP |
| NOISE·B | C85 10 µF, R144 330 K in, R143 100 K fb | −0.303 | HIT |

### FIRE — laser (sheet 3)

```
/FIRE -> IC4 74123 sec.2 (pin 9 = A trigger), R7 47K / C4 1uF
         tw = 0.45*R*C = 21.15 ms, Q on pin 5
      -> R6 330 pull-up, D8 -> C3 6.8uF / R4 150K to ground
         charges within the gate; decays with tau = R4*C3 = 1.02 s
      -> IC20 sec.1 unity buffer (10+, 9-, 8 out) = Venv
```

`Venv` peak is **3.16 V**. That is the 74123's V_OH less D8's drop, and it is confirmed
by fire.wav: the recording holds flat for ~0.30 s before decaying, and 3.16 V is the peak
that puts the control voltage at the MC3340 knee at exactly that moment. Two independent
routes to the same number.

`Venv` then splits two ways.

**Control leg** — IC20 sec.2, inverting, R78 56 K in, R79 47 K feedback, `+` input at
`12 * 33/(100+33)` = 2.977 V from R74/R75, C37 33 µF decoupling:

```
V2 = 2.977 * (1 + 47/56) - Venv * (47/56) = 5.475 - 0.839 * Venv
```

so V2 sweeps **2.12 V → 5.475 V** as the envelope decays: full gain, then muted. C19
680 pF smooths the control node (negligible at audio rates; model as a wire).

**Filter leg** — Tr1, base fed through R77 15 K with R76 3.3 K to ground, emitter grounded,
collector loaded by R32 1.5 K to ground and tied through R31 100 Ω to the midpoint of
C32/C33.

**Note the topology carefully.** C32 and C33 (0.01 µF each) are in *series across* R35,
IC12's 47 K feedback resistor, with their midpoint shunted to ground through
R31 + (R32 ∥ Tr1). So:

* Tr1 **saturated** (envelope high): midpoint near AC ground, the series arm is defeated,
  feedback is just R35 → flat, gain −R35/R33 = **−4.7**. Bright.
* Tr1 **off** (envelope decayed): midpoint floats behind 1.6 K, C32+C33 in series
  (0.005 µF) sit across R35 → single-pole low-pass at
  `1/(2π · 47K · 0.005µF)` = **677 Hz**. Dull.

The laser therefore starts bright and darkens as it decays, on top of the VCA's amplitude
decay. (An earlier revision of `hardware-audio.md` recorded this as a fixed 340 Hz corner;
that assumed one 0.01 µF cap across R35 and missed both the series pair and the fact that
the midpoint is modulated.)

Tr1 is modelled as **piecewise-linear conduction**, not a full exponential:

```
Vbe   = Venv * R76/(R77+R76) = Venv * 0.1803
Ic/Ib region: off below Vbe = 0.6 V, linearly increasing conductance to saturation
gc    = 0                          Vbe <= 0.60
      = gsat * (Vbe-0.60)/0.15     0.60 < Vbe < 0.75
      = gsat                       Vbe >= 0.75            gsat = 1/50 ohm
shunt R at the cap midpoint = R31 + (R32 parallel 1/gc)
```

Full Ebers-Moll would trade one undocumented parameter (the MC3340 knee) for another
(2SC458 Is), which is not a good trade.

**Output**: IC18 pin 15 → C25 2.2 µF → R69 100 K → IC25 (R142 220 K fb, `+` at 6 V)
→ gain **−2.2** → C77 2.2 µF → FIRE MIX.

Input attenuator ahead of the VCA: R67 30 K into R68 3.3 K to ground = **0.0991**.

### Phase 2 results

Measured at the channel's own MIX node (`dbg_fire_mix`), which is the level that does not
move when `MASTER_VOL` is recalibrated: FIRE peaks at **6255 LSB = 1.53 V** against
ALARM's 17432 LSB = 4.26 V, so FIRE sits 8.9 dB below the alarm — consistent with the
equal 10 K mixer resistors. Scenario 8 (FIRE under a sustained ALARM0, the real gameplay
combination) shows no clipping at either channel or the master.

Earlier revisions quoted master-output figures (7168 against 19904, and 25616 for scenario
8). Those are still correct in ratio but no longer in absolute terms, because
`MASTER_VOL` moved from 256 to 128. **Quote per-channel MIX levels, not master levels**,
for anything meant to survive calibration.

**One bug found by the first run.** The envelope decay pole was written in Q0.16, which
cannot represent it: the ideal `exp(-1/(fs·1.02))` = 0.99997957 falls between two adjacent
codes, so 65535 gives tau = 1.365 s (+34 %) and 65534 gives 0.68 s (−33 %). Carried in
Q0.24 the realised tau is 1.0191 s. This is the identical trap already flagged for the
ALARM high-pass, and it will recur in every channel with a slow envelope — SHIP and EXP
both have one. **Check the pole precision before believing any envelope.**

### Open: FIRE decays faster than the recording

Our decay reaches −20 dB at t ≈ 0.29 s. MAME's `fire.wav` reaches −20 dB at t ≈ 0.78 s —
roughly **2.7× slower**. The shapes differ in character too: ours falls immediately and
smoothly, the recording holds nearly flat for 0.4 s and then collapses.

Deliberately **not** resolved by tuning to the recording. Every element of our chain is
primary-sourced — C3/R4 tau = 1.02 s off the schematic, the 40 dB/V slope off the MC3340
datasheet at the correct 12 V rail — and a recording does not override primary sources
without schematic backing. Recorded here rather than fitted away.

Candidates, if it is ever worth chasing:

* **MC3340 part spread.** Figure 3's dashed limit curves span roughly ±0.5 V, which is
  easily enough to account for the gap. The knee position is the documented tuning knob.
* **V_peak.** Taken as 3.16 V. Fitting the recording's onset against the 3.1 V knee instead
  of the 3.5 V point gives 3.80 V, which is equally plausible as a 74123 V_OH less D8.
* **The recording itself.** `fire.wav` is a hand-made MAME asset — possibly trimmed, faded,
  normalised, or captured from another board revision. It is 0.949 s long, suspiciously
  close to a round number.

Not worth chasing until a second channel is built and the relative levels can be judged
together; a systematic error would show up in EXP the same way.

## Phase 3 — EXP (sheet 2) — **BUILT AND CONNECTED**

> **Resolved.** The spec below was correct; the bug was in `ttl_74123`, not in EXP at all.
>
> `ttl_74123` reset its input-history register `a_n_d` to a hardcoded 1. That is the right
> idle value only when `a_n` is driven from a PPI line, which idles high. EXP is the first
> channel to **cascade** two one-shots — sec.B's `a_n` is sec.A's `q`, which idles **low** —
> so on the first clock after reset the module saw a falling edge that never happened and
> fired a phantom full-width pulse.
>
> That pulse discharged C89, putting the rumble control at (5 + 0.8)/2 = 2.9 V — the
> *bottom* of the MC3340 curve, i.e. full +13 dB, the loudest state the channel has — for
> 465 ms, recovering over the 4.4 s C89 tail. Every scenario is shorter than that tail,
> which is why ALARM-alone clipped too, and why it presented as a steady idle signal rather
> than a mis-scaled burst.
>
> Fix: reset `a_n_d` to the current value of `a_n`. No change for ALARM/FIRE.
>
> **All three ranked suspects were innocent**, and are ruled out by analysis rather than by
> the fix happening to work. The envelope recharge is an *exact* fixed point at
> `VHIGH_SCALED` (5242880 · 16777216 >> 24 = 5242880), so idle V2 is exactly 5.000 V and
> the LUT index is exactly 48. The rumble low-pass DC gain is
> (13175 + 26349 + 13175)/(2²⁴ − 33237369 + 16481232) = 52699/21079 = 2.500, as specced.
> The −4.700 weight matches the schematic. Recorded because "the fix worked" is not the
> same as "the suspects were wrong", and the next channel will have the same suspects.
>
> **Lesson worth carrying.** The bug was in the *shared TTL part*, exposed by the first
> channel to use it in a new topology. `ttl_555_astable` and `ttl_74123` are used by every
> remaining channel; SHIP and REBOUND will exercise the 555's duty cycle for the first
> time, which is likewise untested by ALARM.



Two **parallel** VCA paths — a bright "crack" and a low "rumble" — summed at IC25 with
different weights. Both sections of IC19 (the MB4391 = two MC3340s) are used, so the
Phase-2 VCA model applies unchanged to both.

Three corrections to the trace recorded in `hardware-audio.md`, all confirmed at high
magnification:

1. **The audio source is NOISE·B, not NOISE·A.** The label above the block on sheet 2
   reads NOISE·B, and it is the same tap that feeds HIT.
2. **Both one-shots are IC8, cascaded, not independently triggered.** `/EXP` triggers
   section A; section A's **Q (pin 13)** drives section B's A input, so section B fires on
   the *falling* edge of Q — i.e. when the crack ends. The rumble follows the crack, it
   does not run underneath it. (The old note had NOISE·A triggering section B, which is
   not a thing a one-shot does.)
3. **Both envelopes are taken from Q̄, and D6/D7 point the opposite way to FIRE's D8**
   (cathode toward the 74123). This is verified on the drawing and is the only orientation
   that works: Q̄ idles high with the diode blocking, so the cap sits charged; the pulse
   pulls Q̄ low, the diode conducts and the cap **discharges**; then it recovers. FIRE
   uses Q and charges through its diode, which is why the two look inconsistent.

### Envelopes

```
/EXP -> IC8 sec.A: R16 47K / C7 4.7uF   -> tw = 0.45*R*C = 99.4 ms
        Q  (pin 13) -> IC8 sec.B A input (falling edge = crack end)
        Q'' (pin 4)  -> D6 (cathode to pin 4) -> R11 10K -> C88 1uF
IC8 sec.B: R17 47K / C8 22uF            -> tw = 465.3 ms
        Q'' (pin 12) -> D7 (cathode to pin 12) -> R151 470 -> C89 2.2uF
```

Each cap sits in a divider into a unity buffer, which is also its charging path:

| | discharge (gated) | recharge (idle) | buffer output |
|---|---|---|---|
| crack, C88 1 µF | R11 10 K, tau = **10 ms** | R10 470K + R9 470K = 940 K, tau = **0.94 s** | (5 + Vc88)/2 |
| rumble, C89 2.2 µF | R151 470 Ω, tau = **1.03 ms** | R150 1M + R149 1M = 2 M, tau = **4.4 s** | (5 + Vc89)/2 |

Both buffers are IC21 MB3614 sections wired unity (`-` tied to output), and both dividers
are equal-valued, so the control voltage is exactly the average of 5 V and the cap. It
therefore spans **2.9 V (full +13 dB) → 5.0 V (80 dB down)** — the right way round for the
MC3340, with no inverting stage needed. FIRE needed one; EXP gets its inversion from the
diode orientation instead.

### Shaping filters

**Crack** — IC21, R94 4.7 K in, R95 2.7 K to ground, C53 = C54 = 0.0068 µF, R98 220 K
feedback. Both caps sit between the node and the amplifier, so DC cannot reach the
inverting input: this is a **2-pole high-pass**.

```
f0 = 1 / (2*pi*C*sqrt((R94||R95) * R98)) = 1 / (2*pi*6.8n*sqrt(1715*220K)) = 1205 Hz
```

**Q is uncertain.** Taking the topology as textbook multiple-feedback gives Q ≈ 5.7, which
is high enough that I do not trust the identification. Implement with **Q = 0.707**
(Butterworth) and expose Q as a parameter. Flagged rather than guessed — a resonant crack
and a flat one sound quite different, and this is the one place in EXP I am not certain.

**Rumble** — Sallen-Key, R87 = R89 = 15 K, C51 = C52 = 0.039 µF, gain `1 + R99/R101` =
1 + 150K/100K = **2.5**.

```
f0 = 1 / (2*pi*15K*0.039u) = 272 Hz
Q  = 1 / (3 - K) = 1 / 0.5 = 2.0
```

That Q is deliberate and unambiguous — the designer chose a gain of 2.5 in a Sallen-Key,
which is a resonant low-pass. The 272 Hz resonance *is* the boom.

### Input attenuators and output

Both VCA inputs see the same divider: 10 K into 3.3 K to ground = **0.2481**
(crack R99/R100, rumble R73/R72).

```
crack  IC19 out pin 11 -> C28 2.2uF -> R71 220K -> IC25 (-)   gain -470/220 = -2.136
rumble IC19 out pin 15 -> C26 2.2uF -> R70 100K -> IC25 (-)   gain -470/100 = -4.700
IC25 R141 470K feedback, + at 6 V -> C76 2.2uF -> EXP MIX
```

The rumble is weighted **2.2× hotter** than the crack at the summing junction.

## Phase 4 — HIT (sheet 2)

Re-traced from sheet 2 at high magnification rather than taken from the summary in
`hardware-audio.md`, per the EXP lesson. `/HIT` is `ppi1_pb[4]`.

### Envelope — same shape as EXP, opposite to FIRE

```
/HIT -> IC13 74123 sec.1 (pin 1 = A, pin 2 = B tied to 5 V, pin 3 = CLR)
        R92 47K? / C42 4.7uF   -> tw = 0.45*R*C = 99.4 ms
        Q-bar (pin 4), pulled up by R93 4.7K
     -> D3 (CATHODE toward pin 4) -> R91 470 -> C48 0.68uF to ground
     -> R90 1M -> node -> R96 1M to 5 V -> IC20 sec.2 unity buffer -> IC24 pin 2
```

**D3's orientation is confirmed visually at high magnification: cathode on the left,
toward IC13.** That is the same orientation as EXP's D6/D7 and the opposite of FIRE's D8,
so the cap **discharges** when the one-shot fires:

| | gated (Q̄ low, D3 conducts) | idle (Q̄ high, D3 blocks) |
|---|---|---|
| C48 0.68 µF | R91 470 Ω, tau = **0.32 ms** | R90 + R96 = 2 M, tau = **1.36 s** |

R90 and R96 are equal, so the control voltage is again exactly `(5 + Vc48)/2`, spanning
**2.9 V (full +13 dB) → 5.0 V (80 dB down)**. Structurally identical to both EXP legs;
the VCA control model ports over unchanged.

> **OPEN — one unresolved value.** The 74123's timing resistor is drawn on sheet 2 with
> **no reference designator and no value**. R90/R91/R93 all exist, and R92 appears nowhere
> else, so it is R92 by elimination. The assembly drawing (page 20) is a scan with no
> extractable text, so confirming it means a visual search. **47 K is assumed**, because
> every other 74123 timing resistor on this board is 47 K (R2, R3, R14, R15, R7, R16, R17,
> R47) and this one is drawn identically — with C42 = 4.7 µF that gives tw = 99.4 ms,
> exactly EXP's crack. Flagged rather than presented as traced.

### Shaping filter — Sallen-Key, resonant

NOISE·B → C47 4.7 µF → **R84 15 K, R88 15 K, C49 = C50 = 0.0033 µF**, IC20 sec.1, with
R86 100 K to the 6 V rail and R85 150 K feedback:

```
K  = 1 + R85/R86 = 1 + 150/100 = 2.5
f0 = 1 / (2*pi*15K*0.0033u) = 3215 Hz
Q  = 1 / (3 - K) = 2.0
```

The same topology and the same **gain of 2.5** as EXP's rumble, an octave-and-a-half
higher. The designer reused the block; Q = 2.0 is again deliberate and unambiguous.

Then C38 2.2 µF → R80 33 K → R81 10 K to ground → C71 2.2 µF into IC24 pin 1:

```
input attenuator = 10 / (33 + 10) = 0.23256
```

### HIT DIS0-2 is a DISTANCE cue, not a volume control

IC24's output → C13 2.2 µF → three 4066 sections (IC10) gated by HIT DIS0-2, each in
series with its own resistor into a common node:

```
HIT DIS0 -> R25 100K    HIT DIS1 -> R26 22K    HIT DIS2 -> R27 10K
node: C9 0.01uF to ground, R28 100K to +12 V, R135 100K into IC28
IC28: R134 680K feedback, + at 6 V -> gain -R134/R135 = -6.8 -> C73 2.2uF -> HIT MIX
```

The node is **not** a virtual ground. R28 (to 12 V, an AC ground) and R135 (to IC28's
virtual ground at 6 V) put **50 K** across it, and C9 shunts it. So the selected resistors
form a one-pole low-pass whose corner *and* gain both move together:

| enabled | R_sel | LF gain | corner |
|---|---|---|---|
| DIS0 | 100 K | 0.333 | 478 Hz |
| DIS1 | 22 K | 0.694 | 1042 Hz |
| DIS2 | 10 K | 0.833 | 1910 Hz |
| DIS0+1 | 18.03 K | 0.735 | 1201 Hz |
| DIS0+2 | 9.09 K | 0.846 | 2069 Hz |
| DIS1+2 | 6.88 K | 0.879 | 2633 Hz |
| all three | 6.43 K | 0.886 | 2792 Hz |
| none | ∞ | 0 | — (muted) |

Only 8.5 dB of level across that range, but a **5.8:1 spread in corner frequency**. A distant
hit is quieter *and* duller, which is why the latch is named DIS — distance, not volume.
Modelling it as a plain gain would throw away most of what the circuit does.

Note HIT also has the hottest path into the master mixer: R136 is 5.1 K against everyone
else's 10 K, giving it 1.96× the weight (see the mixer table).

### Phase 4 results — and a cross-channel level problem worth resolving

Scenario 12 (one hit, DIS = 7), 13 (the DIS sweep), 14 (hits under ALARM0). Measured at
`dbg_hit_mix`:

| DIS | RMS | spectral centroid |
|---|---|---|
| 7 (all three) | −3.8 dB | 2947 Hz |
| 4 (DIS2) | −4.3 dB | 2834 Hz |
| 2 (DIS1) | −5.6 dB | 2459 Hz |
| 1 (DIS0) | −12.9 dB | 1935 Hz |

Level and brightness both fall monotonically as DIS decreases, which is the acceptance
test for the distance cue. It passes.

**But HIT pins the −6.00 V rail at every DIS setting** — the peak is an identical 27496 in
all seven, i.e. the rail, not the signal. Working the chain at full envelope:

```
noise_b 5895 LSB -> Sallen-Key (ENBW ~10.1 kHz, G 2.5) ~9550 RMS
  x 0.2326 atten  x 4.466 VCA  x 0.886 DIS  x 6.8 output  =  ~59,800 LSB = 14.6 V RMS
```

against a rail of 6 V. That is **~3× over**, so the channel is clipped essentially flat.

This is now a cross-channel pattern rather than a HIT quirk, and it is exactly the
comparison the FIRE section said to wait for:

| channel | peak at its MIX node | vs rails |
|---|---|---|
| ALARM | 4.26 V | under |
| FIRE | 1.53 V | 3× under |
| EXP | 6.00 V | clipped |
| HIT | 6.00 V | clipped, ~3× over |

All three VCA channels share `NOISE_VPP` and the MC3340 LUT, so a systematic error would
land on EXP and HIT together — which is what we see. Two candidates, neither yet tested:

* **`NOISE_VPP` = 9.5 V is too high.** It is the datasheet *midpoint* of a 7.0–12.0 V
  bound, chosen because it also made FIRE sit alongside ALARM. But FIRE is the channel
  that is 3× *under*, so that corroboration is weaker than it looked.
* **The MC3340 knee.** Documented as the one tuning knob for all three VCA channels, with
  ±0.5 V of part spread. EXP and HIT both sit at V2 = 2.9 V at full open, which is below
  the 3.1 V knee and therefore pinned at the full +13 dB. FIRE bottoms out at 2.82 V, also
  below the knee — so the knee position alone does not explain the split.

Note the split is partly *by design*: FIRE's input attenuator is 0.0991 against HIT's
0.2326, and its output gain is −2.2 against HIT's −6.8, so FIRE is ~10× quieter straight
off the schematic. Resolve this before the LA4460 stage, not after — it changes what the
output stage is being asked to reproduce.

## Op-amp output rails — a real clipping mechanism

Every op-amp on this board (LM324 / MB3614) runs on the **12 V single supply** with its
`+` input at the **6 V mid-rail**. Its output therefore cannot leave roughly 0 .. 10.5 V,
which referred to the 6 V rail is about:

```
RAIL_HI = +4.50 V   (Vcc - 1.5 V headroom)   = +18432 LSB
RAIL_LO = -6.00 V   (sinks nearly to ground) = -24576 LSB
```

Note the **asymmetry** — an LM324 pulls down almost to ground but stops well short of Vcc.
That asymmetry is itself audible: it clips one half-cycle before the other, generating even
harmonics.

This is not a format guard, it is the circuit. A full-gain explosion through EXP's −4.700
rumble weight drives well past +4.5 V, so **the real board clips here too**, and that
clipping is part of what an explosion on this hardware sounds like. Saturating at the
numeric format's ±8.000 V instead — a voltage no LM324 on a 12 V rail can reach — both
misses the distortion and lets a channel run about 5 dB hotter than the circuit permits.
EXP was doing exactly that: `exp_mix` pinned at 32768 = 8.00 V.

Currently applied at **EXP's IC25 output only**, because that is the only place it is
demonstrably reached. ALARM peaks at 4.26 V and FIRE at 1.53 V, both under RAIL_HI, so
adding it there today would be a no-op — but it belongs on every op-amp output stage, and
must be added as each channel lands rather than retrofitted once levels drift.

**Both figures are now datasheet-backed** (`docs/reference/LM324.pdf` p11,
`docs/reference/MB3614.pdf` p2):

| | V_OH | V_OL |
|---|---|---|
| LM324 | VCC − 1.5 V at RL = 2 K, 25 °C → +4.50 V | 5 mV typ / 20 mV max → −6.00 V |
| MB3614 | typ 28 V at VCC = 30 V, i.e. VCC − 2.0 V → +4.00 V | 5 mV typ / 20 mV max → −6.00 V |

The V_OH spec is quoted at RL = 2 K while the loads here are 100 K–470 K, an order of
magnitude lighter, so +4.50 V is conservative. The remaining uncertainty is **0.5 V on the
positive rail only**: the IC roster lists IC17/IC20–IC22/IC25/IC26/IC29 as "LM324 /
MB3614" without saying which socket holds which, and that is exactly the spread between
the two parts. We take the LM324 figure. V_OL is identical for both, so RAIL_LO is firm.

## Power-on thump — modelled deliberately

The real board thumps at power-on and this is reproduced, at the correct amplitude, rather
than skipped. An earlier revision of this file recorded the opposite decision; that has
been reversed.

At power-on C88 (4.7 µF) is uncharged, so it is momentarily a **short**, and the op-amp
`+` input is a plain resistive divider between the idle node (5 V through R153 + R154 =
6.1 K) and the 6 V Thevenin of R155/R156 (5 K):

```
Vp(0) = (5/6.1 + 6/5) / (1/6.1 + 1/5) = 2.019672 / 0.363934 = 5.5495 V
y(0)  = Vp(0) - 6 = -0.45045 V,  which is exactly (5 - 6) * 5/11.1
```

In model units the 6 V rail's share of the divider is 6 · (5/11.1) · 4096 = 11071 LSB, so
`y(0)` = X_IDLE − X_SIXV = 9226 − 11071 = **−1845 LSB**, decaying over the 52.17 ms tau.
After the ×(−2) stage that is a **+0.90 V** thump at ALARM MIX. Measured tau in scenario
11 is 52.8 ms.

**This is not the old bug.** The pre-phase-1 code reset `x_scaled_d` to `X_LOW`, modelling
C88 pre-charged to the node-*low* level — a state the board is never in — and produced an
18452 LSB click, 5× too large and of the wrong sign. The correct initial condition is the
cap uncharged.

**It is also only the ALARM leg's share.** Most of a real cabinet's power-on thump is the
other coupling caps charging — C69 and C83 (4.7 µF) into the LA4460, plus C74/C76/C77 —
none of which are modelled yet. Expect this to be subtle on its own; the big one arrives
with the LA4460 output stage.

Scenarios 0–10 call `settle()` first, which runs 600 ms (11.5 tau) **without recording**,
so the thump has decayed to bit-exact zero and each scenario's timeline still starts at
t = 0. That models reality — a board has been powered for seconds before the game makes a
sound — and keeps acceptance criterion 5 meaningful. Scenario 11 skips the settle and
captures the thump itself.

## Mixer — why it is built whole

`hardware-audio.md` establishes that R138 (200 K) sits *in series* into IC28, so the six
channel resistors meet at a **passive** node that is not a virtual ground. The direct
consequence: **every channel's gain depends on the source impedance of all five others.**

Therefore the six-input mixer is implemented in full *now*, with the five unbuilt channels
driven by hard zero. A silent channel on real hardware is a low-impedance 0 V source (its
op-amp output through a coupling cap), which is exactly what a tied-off input models. Build
only the ALARM leg and the ALARM level would be wrong, and would silently change every time
another channel landed.

```
Vnode = (SUM Vch/Rch) / (SUM 1/Rch + 1/R138)
Vout  = -(R126/R138) * Vnode = -0.5 * Vnode
```

With `SUM 1/Rch` = 5×(1/10 K) + 1/5.1 K = 6.9608e-4 and 1/R138 = 5e-6, denominator
7.0108e-4. Per-channel effective gain to IC28's output:

| Channel | R | gain |
|---|---|---|
| HIT | 5.1 K | −0.13985 |
| SHIP, FIRE, EXP, REBOUND, ALARM | 10 K | −0.07132 |

ALARM at ±2.13 V therefore reaches IC28's output at **±0.152 V** (±622 LSB).

Implementation: a single constant-coefficient weighted sum. The coefficients are fixed
because the resistors are fixed — no runtime division.

## Output stage

`VR1` is a real 20 K panel pot, so a master volume is authentic hardware, not a fudge.

```
AUDIO_L = AUDIO_R = saturate16( mix_out * MASTER_VOL >>> 4 )
```

`MASTER_VOL` defaults to **128** (i.e. ×8). Still a placeholder to be settled once all six
channels exist and the loudest realistic combination is known — it is the one number in
this document chosen by taste rather than by the schematic, and it is isolated in one
parameter for exactly that reason.

It was 256 (×16) through phase 2. With EXP live that is demonstrably too hot: scenario 10
(EXP + FIRE + ALARM) clipped the master stage. At ×8 that combination peaks at 21720,
about −3.6 dBFS, leaving headroom for HIT — which will be the hottest channel of all, its
5.1 K summing resistor giving it 1.96× everything else.

`AUDIO_S = 1` (signed), `AUDIO_MIX = 0` (no MiSTer-side blending; the board is mono).

---

## Acceptance criteria for phase 1 — all PASSING

Rebuild and re-check with:

```
wsl -d archlinux -- bash -lc "cd /mnt/c/.../sim && make audio-run"
python tools/analyze_audio.py sim/out/audio/scen0.wav ...
```

| # | Criterion | Result |
|---|---|---|
| 1 | Each `/ALARMn` alone gives the tabled frequency within 0.5 % | **PASS** — 446.5 / 892.2 / 1784.1 / 3579.5 Hz vs 446.5 / 893.0 / 1785.9 / 3571.8 (worst error +0.22 %) |
| 2 | Burst lengths 144 ms (ALARM0-2) and 211 ms (ALARM3) within 1 % | **PASS** — 146 / 145 / 146 / 213 ms measured, less the 2 ms envelope window |
| 3 | Retrigger extends to a full width from the retrigger instant | **PASS** — scenario 4 retriggers at 80 ms and ends at 224 ms = 80 + 144 |
| 4 | Simultaneous alarms intermodulate, they do not sum | **PASS** — scenario 5 differs from `scen0 + scen2` by up to 18160 LSB; RMS 7288 vs 10687 for the linear sum |
| 5 | Silence is bit-exact zero before the first alarm | **PASS** — scen0 has 387 leading zero samples against an onset at sample 384. Now measured *after* `settle()`, since the power-on thump is deliberately modelled; see "Power-on thump" |

### Two findings from the first run, both now fixed

**The filter reset value.** `x_scaled_d` initially reset to `X_LOW`, but the idle node sits
*high*. Every reset therefore injected a full-scale step and rang for the whole 52 ms tau,
producing a click at twice the amplitude of the alarm itself — visible as an identical peak
of 19888 in all six scenarios regardless of content. It resets to `X_IDLE` now.

**The burst-length measurement.** `tools/analyze_audio.py` originally thresholded the raw
envelope, which measured the C88 recovery rather than the gate and reported every burst at
roughly twice its true length. It now measures on the first difference of the signal.

### On the burst envelope

The peak sample of a burst is about **2×** its late-burst amplitude, and this is correct.
At burst onset the node's mean steps from a steady 5 V to the square's average, so the
first excursion is the full node swing rather than half of it; C88 then recovers with
tau = 52 ms. The burst is only 2.8 tau long, so it never fully settles. Measured decay
tracks `9954 · (1 + exp(−(t−t₀)/52.17 ms))` to within a few percent across the whole burst,
which is the intended physics, not a gain error.
