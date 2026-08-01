# Discrete audio — RTL design contract

Companion to `docs/hardware-audio.md`, which holds the *hardware* facts. This file holds
the *implementation* decisions: numeric formats, clocking, module boundaries, and every
place we knowingly depart from the circuit. Nothing here may contradict
`hardware-audio.md`; if it seems to, the schematic wins and this file is the bug.

Status: **complete, from the PPI to the speaker terminals** — ALARM, FIRE, EXP, HIT, REBOUND
and SHIP, the passive mixer, the `GAME ON` / power-on mute, and the LA4460 output stage. The
mixer was built for all six from the start; see "Why the mixer is built whole" for why that was
not premature. The one thing deliberately left unmodelled is the **speaker**, which is not on
the schematic — see "Phase 7".

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
  audio_top.sv      PPI1 taps, IC2/IC6 latches, channel instances, mixer, output scaling
  ttl_74123.sv      retriggerable monostable        (ALARM/FIRE/EXP/HIT/REBOUND)
  ttl_555_astable.sv  free-running astable          (ALARM)
  relax_vco.sv      integrator + Schmitt + transistor relaxation oscillator (SHIP x3)
  dc_block.sv       one-pole coupling-cap high-pass (SHIP x3)
  noise_mm5837.sv   17-bit LFSR + the two buffered taps
  alarm_chan.sv     555 + 74393 + 4x74123 + wire-OR NAND -> node bit + analog tail
  fire_chan.sv exp_chan.sv hit_chan.sv rebound_chan.sv ship_chan.sv
  audio_mixer.sv    passive summing node + IC28
  mute_ctl.sv       GAME ON + the R107/C58/IC26 power-on timer -> LA4460 pin 6
  la4460.sv         C69/R45/VR1/C83 input network, the amp's two poles, the rail clip
```

`ttl_74123` and `ttl_555_astable` are written as general parts, parameterised by their
timing constants, because every remaining channel needs them. Resisting the urge to inline
them into `alarm_chan` is the whole reason phase 1 is worth doing first — and the EXP
one-shot bug, which lived in the shared part rather than in EXP, is the proof.

`relax_vco` earns its keep the same way and more cheaply: SHIP instantiates it **three
times**, because Tr2, Tr4 and Tr5 are one circuit drafted three times.

Note the two 555s are handled differently, and deliberately. `alarm_chan` uses
`ttl_555_astable` because it wants the square wave. REBOUND and SHIP both leave pin 3
unconnected and follow the *timing capacitor*, so both model the cap's exponentials inline
and neither instantiates the part at all.

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

`Venv` peak was first taken as 3.16 V (the 74123's V_OH less D8's drop, fit against fire.wav
holding flat for ~0.30 s). **Revised to 3.80 V** — see "FIRE decays faster than the
recording" below: 3.16 V fit the same V_OH-less-D8 reading against the MC3340's 3.5 V knee
point, while 3.80 V fits it against the 3.1 V point instead, equally schematic-plausible,
and matches a real cabinet recording far better than 3.16 V did.

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

### Open (RE-OPENED, then partially fixed): FIRE decays faster than the recording

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

**Update: this is exactly what happened, and the condition for revisiting is now met.**
Once SHIP, REBOUND, ALARM and LA4460 all existed and were timing-closed, a real hardware
test surfaced this as a *user-audible* bug, not a curiosity: FIRE was effectively inaudible
in actual gameplay, while every other channel sounded correct. A real cabinet recording
(`docs/reference/buckrog_cabinet_audio.wav`, a phone/camera capture of a real cabinet in
play) was isolated by cross-correlation and windowed-envelope analysis against MAME's own
sample WAVs (`mame/samples/buckrog/*.wav`) and confirms
FIRE sits at a comparable local peak/RMS to SHIP's engine and the explosion sound in that
recording — not the ~9-17 dB-down "thin, quiet laser" the old atten/gain-only comparison in
Phase 4 predicted. Re-tracing the attenuator (R67 30K / R68 3.3K = 0.0991), output gain
(R69 100K / R142 220K = −2.2) and the NOISE·A front-end tap directly against the schematic
scans (`tools/render_sheets.py buck 47`) confirmed all three are correct as coded — the gap
is upstream of them, in the envelope.

Fixed by taking the **V_peak candidate** from the list above: `VPEAK_SCALED` changed from
3.16 V to **3.80 V** (fitting the 74123's V_OH-less-D8 reading against the MC3340's 3.1 V
knee instead of the 3.5 V point — equally schematic-plausible, not a fit to the recording).
This is not just a level change: `V2 = 5.475 - 0.839*Venv` crosses the MC3340's 3.1 V knee
(full gain below it, i.e. the "flat" part of the envelope) at a **fixed** `Venv = 2.83 V`
regardless of `VPEAK` — so raising `VPEAK` doesn't move the knee, it lengthens how long the
envelope takes to decay down to it, directly reproducing the recording's own "holds flat,
then collapses" shape rather than the smooth immediate decay the old value produced.

Measured (scenario 6, one shot, `dbg`-node comparison against `fire.wav` using the same
−20 dB windowed-RMS method the original finding used): decay reaches −20 dB at **t ≈ 0.40 s**
(was 0.29 s), against MAME's 0.70 s (re-measured with the same method; the 0.78 s figure
above used a coarser method) — closes roughly a third of the 2.7× gap from a single
schematically-defensible constant change, not a curve fit. **Not fully closed** — the
remaining gap is still open, and the other two candidates (MC3340 part-to-part spread,
`fire.wav` itself being a possibly-processed asset) remain plausible contributors on top of
this. Verified: 112/112 DSP unchanged, Fitter Successful (only a constant changed, no width
or structure); all non-FIRE channels bit-exact across all 23 scenarios; the 700-frame
full-game regression is unaffected because that scripted playback never triggers `/FIRE`.

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

> **The 74123's timing resistor is drawn on sheet 2 with no designator and no value.**
> It is taken as **47 K** — inferred, not traced, but on strong evidence.
>
> The board sets every one-shot's width with its **capacitor**, holding the resistor at
> 47 K throughout:
>
> | one-shot | R | C | tw |
> |---|---|---|---|
> | ALARM0/1/2 | R2 / R3 / R14 47 K | 6.8 µF | 144 ms |
> | ALARM3 | R15 47 K | 10 µF | 211 ms |
> | FIRE | R7 47 K | 1 µF | 21.2 ms |
> | EXP crack | R16 47 K | 4.7 µF | 99.4 ms |
> | EXP rumble | R17 47 K | 22 µF | 465 ms |
> | REBOUND | R47 47 K | 1 µF | 21.2 ms |
> | **HIT** | **47 K (inferred)** | 4.7 µF | **99.4 ms** |
>
> Eight for eight, across a 22:1 spread of capacitor values, including **R47 — the other
> section of this very package** (IC13 sec.2). At 47 K / 4.7 µF, HIT is identical to EXP's
> crack in both R and C.
>
> Two dead ends, recorded so nobody re-walks them. It is **not R92**: R92 is 4.7 Ω ½ W, a
> Zobel resistor on the LA4460 speaker outputs, and a 4.7 Ω timing resistor would give
> tw = 10 µs. The assembly drawing (page 20) agrees — the bank beside IC13 reads R90 1 M,
> R91 470, an MA150 diode, R93 4.7 K, R94 4.7 K, R95 2.7 K, with no R92 present. It is
> also **not R97**, which sits by IC21/C51/C52 in EXP's rumble Sallen-Key.
>
> If a BOM ever contradicts this, only `WIDTH_CYCLES` changes. The envelope shape and every
> level in HIT are set by C48/R91/R90/R96 and are unaffected.

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

### Phase 4 results, and the cross-channel level question — RESOLVED, then partially revised

> **Note, added when FIRE's envelope was revisited (Phase 2 update).** The "FIRE really is a
> thin, quiet laser" conclusion below compares only the atten/output-gain stages and was
> correct as far as it went, but it doesn't set FIRE's *actual* peak level — the envelope's
> `VPEAK` does, and that value changed from 3.16 V to 3.80 V after this was written (see
> Phase 2). FIRE's MIX level and the 8.9 dB-below-ALARM figure quoted here are therefore
> stale; the structural gain-stage comparison (atten×gain ratios between FIRE/EXP/HIT) is
> still accurate and still a real, schematic-confirmed difference — it just isn't the whole
> story for how loud FIRE ends up.

Scenario 12 (one hit, DIS = 7), 13 (the DIS sweep), 14 (hits under ALARM0). Measured at
`dbg_hit_mix`:

| DIS | RMS | spectral centroid |
|---|---|---|
| 7 (all three) | −3.8 dB | 2947 Hz |
| 4 (DIS2) | −4.3 dB | 2834 Hz |
| 2 (DIS1) | −5.6 dB | 2459 Hz |
| 1 (DIS0) | −12.9 dB | 1935 Hz |

Level and brightness both fall monotonically as DIS decreases — the acceptance test for the
distance cue. It passes.

HIT pins the −6.00 V rail at every DIS setting, and EXP does the same, while FIRE sits
1.53 V, about 3× under. That looked like a systematic error shared by the three VCA
channels. **It is not.**

**`NOISE_VPP` cannot be the cause, by construction.** FIRE, EXP and HIT are all *linear*
in it, so changing it moves all three together and cannot alter their ratio. Confirmed by
measurement at 7.0 V pp, the datasheet floor and 26 % below our 9.5 V:

| | 9.5 V | 7.0 V |
|---|---|---|
| FIRE | 1.53 V | 1.01 V |
| EXP | 6.00 V (railed) | 6.00 V (still railed) |
| HIT | 6.00 V (railed) | 6.00 V (still railed) |

**The MC3340 knee cannot be the cause either**, for the same reason: at full envelope FIRE
sits at V2 = 2.82 V, EXP at 2.9 V and HIT at 2.9 V — all three *below* the 3.1 V knee, so
all three take the identical +13 dB. Moving the knee moves them together.

The split is **structural, and every term is off the schematic**:

```
FIRE:  atten 0.0991  x  output gain 2.2  = 0.218
EXP:   atten 0.2481  x  output gain 4.7  = 1.166   -> 5.3x FIRE
HIT:   atten 0.2326  x  output gain 6.8  = 1.582   -> 7.3x FIRE, i.e. 17.2 dB
```

So **EXP and HIT clip on the real board too**, and FIRE really is a thin, quiet laser. The
clipping is authentic behaviour rather than a defect — and it is one of the genuine
sources of the era-typical "crunch". Nothing here should be tuned away.

What this *does* leave open is `MASTER_VOL`: two channels that legitimately sit at the rail
mean the master stage must be set so it does not clip them a second time. Scenario 14
(HIT + ALARM) peaks at 32520 against a 32767 ceiling, which is uncomfortably tight, and
SHIP and REBOUND are not built yet. Revisit once all six exist.

## Phase 5 — REBOUND (sheet 2)

Re-traced at high magnification. `/REBOUND` is `ppi1_pb[5]`. Three things here contradict
the summary in `hardware-audio.md`, all confirmed visually.

### 1. The 555's output pin is not connected

`IC15(B)` runs as an astable (R65 10 K = Ra, R64 33 K = Rb, C31 1 µF), but **pin 3 goes
nowhere**. IC12 sec.2 (pins 13/12/14) is a unity follower whose `+` input sits on the
**C31 timing-capacitor node**. REBOUND therefore uses the 555's *exponential ramp*, not
its square wave.

### 2. It is sub-audio — a bounce rate, not a tone

The envelope drives the 555's **pin 5 control-voltage** input, so the oscillator sweeps:

| CV | period | rate |
|---|---|---|
| 2.53 V (envelope open) | 40.7 ms | **24.6 Hz** |
| 3.50 V | 56.1 ms | 17.8 Hz |
| 4.50 V | 96.2 ms | 10.4 Hz |
| 4.90 V | 162 ms | 6.2 Hz |
| → 5.0 V | ∞ | stops |

`t_low = ln2·Rb·C = 22.87 ms` is constant; only the charge phase stretches. None of this is
a pitch — it is the rate at which the channel is *gated*.

### 3. NOISE·A feeds it, and the filter is a BAND-PASS, not FIRE's low-pass

`hardware-audio.md` omits noise from REBOUND entirely. In fact **NOISE·A → C41 4.7 µF →
R39 10 K** runs the full width of the sheet into node **M**, the midpoint of C51/C40
(0.022 µF each) which sit in series across R38 51 K, IC12's feedback. Tr3 + R40 100 Ω
shunt that same node M.

This *looks* like FIRE's Tr1/R31/C32/C33/R35 trick but is not, and the difference matters:

* **FIRE** injects noise at the inverting input through R33, and Tr1 shunts the cap
  midpoint → a **switchable low-pass**.
* **REBOUND** injects noise **at the midpoint itself**, the same node Tr3 shunts.

Solving that network:

```
Vo/Vin = -s*C51*R38 / [1 + s*R39*(C51+C40) + s^2*R39*R38*C40*C51]

f0   = 1/(2*pi*sqrt(R39*R38*C40*C51)) = 320.3 Hz
Q    = 1/(w0*R39*(C51+C40))           = 1.129
peak gain                              = 2.550   (inverting)
```

A resonant band-pass. Tr3 does not retune it — it **gates** it: saturated, M is pulled to
ground through R40 100 Ω, which against R39 10 K is **−40.1 dB**.

### Envelope, gate and output

```
/REBOUND -> IC13 sec.2 (R47 47K / C44 1uF) -> tw = 21.15 ms -> WIDTH_CYCLES = 844627
         Q-bar (pin 12), pulled up by R46 4.7K
      -> D2 (cathode toward IC13, as D3/D6/D7) -> R44 470 -> C43 2.2uF
      -> R43 330K -> node -> R42 470K to 5 V -> IC12 sec.1 unity buffer
```

| | gated | idle |
|---|---|---|
| C43 2.2 µF | R44 470, tau = **1.034 ms** | R43+R42 = 800 K, tau = **1.76 s** |

**The divider is unequal here** — 330 K / 470 K, not the matched pairs EXP and HIT use — so
the control is *not* `(5+Vc)/2`:

```
V = (Vc*470K + 5*330K)/800K = 0.5875*Vc + 2.0625     spans 2.5325 V -> 5.0 V
```

That one node drives **both** the 555's pin 5 **and** IC18's VCA control, so rate and
level fall together.

Tr3's base sees the ramp through R37 12 K / R36 4.7 K = 0.28144, so it conducts above
**2.132 V** of ramp. Early on (CV ≈ 2.53, ramp 1.27–2.53 V) it crosses only near the peak,
so the gate is briefly closed each cycle; as CV rises past ~4.3 V the whole ramp sits above
threshold and the channel is held muted. Fade-out and slow-down are the same mechanism.

```
IC12 out -> C45 2.2uF -> R82 3.3K -> R83 10K to gnd  (divider 0.75188 -- note this is the
                                                      INVERSE of EXP/HIT's 0.248/0.233)
         -> C24 2.2uF -> IC18 MB4391 pin 5, control pin 6, C21 680 pF on RO
IC18 pin 11 -> C20 2.2uF -> R62 100K -> IC22 (R128 330K fb, + at 6 V) = -3.30
            -> C75 2.2uF -> REBOUND MIX
```

Fixed-point constants at fs = 47998.875:

```
discharge  a = 0.980052866  Q0.16 = 64229,  B = 1307   realised tau 1.0342 ms  (+0.020%)
recharge   a = 0.999988163  Q0.24 = 16777017, B = 199  realised tau 1.7564 s   (-0.202%)
output divider 0.751880 -> Q0.16 = 49275
output gain   -3.30      -> Q0.16 = -216269
```

The recharge pole again needs Q0.24; in Q0.16 it is unrepresentable.

### Phase 5 results

Scenario 15 (one rebound, 3.5 s), 16 (four rebounds at 700 ms, testing retrigger).

| | measured | design |
|---|---|---|
| bounce rate, early | 22.7 Hz | 24.6 Hz |
| bounce rate, late | 16.7 Hz | — |
| oscillator stops at | t = 0.98 s | — |
| band-pass peak | 281 Hz | 320 Hz |
| peak level, one rebound | 5.63 V | under the 6 V rail |
| idle | 1 LSB | silent |

**The channel stops before the 555 does, and that is correct.** The oscillator's own floor
is 6.2 Hz, but Tr3's gate latches shut once the whole ramp sits above its 2.132 V
threshold, which happens first. Deceleration and fade-out are the same mechanism, so the
sound ends while the rate is still ~17 Hz. Scenario 15 has only 2/3 of its samples
non-zero for exactly this reason.

Retrigger (scenario 16) restarts the sweep rather than queueing, and touches the rail at
24576 where two rebounds overlap.

**A caveat on the band-pass measurement.** The 281 Hz peak and the apparent Q of 1.71 come
from an analysis window that was Hann-windowed over 4096 samples but only summed over the
first 512, so the figures are smeared and good to no better than ~15 %. The *shape* — a
clear single-peaked band-pass rolling off on both sides, −3 dB somewhere around
200–360 Hz — is unambiguous and matches the design. Re-measure properly before treating
281 Hz as a discrepancy worth chasing.

## Phase 6 — SHIP (sheet 1) — **FRONT END TRACED, CHAIN STILL OPEN**

`SHIP ON` is `ppi1_pb[6]` (a level, not an edge). ACC0-3 is latched on-board by IC6
(4175B) from the shared port-A nibble on the **rising edge of port A bit 5** — the twin of
the IC2/bit-4 strobe that HIT uses.

### The 555 (IC14) — two corrections

```
pin R (reset) tied to 12 V;  C88 0.01 uF on CTRL;  C12 1 uF on TH/TR
R24 6.8K from 12 V to DIS;  R23 200K and D1 in PARALLEL between DIS and TH/TR
```

**D1's anode is at DIS and its cathode at TH/TR** — confirmed visually at high
magnification. That puts D1 in the **charge** path, where it shorts out R23; during
discharge it is reverse-biased and the cap drains through R23 alone.
`hardware-audio.md` records this as "R23 200K + D1 discharge", which has D1 in the wrong
phase.

```
t_high = 0.693 * R24 6.8K  * C12 = 4.712 ms    T_HIGH =   188,190 clk_sys
t_low  = 0.693 * R23 200K  * C12 = 138.600 ms  T_LOW  = 5,535,000 clk_sys
period = 143.31 ms -> 6.978 Hz, duty 3.29 %
```

**So this is a ~7 Hz sawtooth, not a tone** — sub-audio, exactly like REBOUND's 555. The
extreme asymmetry (fast rise, slow fall) is the whole point; it is what makes the engine a
lumpy putt rather than a hum.

As in REBOUND, **the 555's output pin 3 is unused**: IC17 (pins 2/3/1) is a unity follower
sitting on the **C12 node**, so the signal is the capacitor ramp itself.

### ACC0-3 is a DC level ladder, not an audio path

**The four 4066 inputs are tied to +12 V**, not to any "MY SHIP" signal — that label names
the block on the sheet. Each enabled switch puts its resistor from 12 V onto a common node
loaded by R22 10 K to ground and smoothed by C11 33 µF. Parallel conductance, not a binary
DAC.

| ACC bits | R_sel | node V | glide tau |
|---|---|---|---|
| 0000 | ∞ | 0.000 | 330.0 ms |
| ACC0 | 82 K | 1.304 | 294.1 ms |
| ACC1 | 30 K | 3.000 | 247.5 ms |
| ACC2 | 16 K | 4.615 | 203.1 ms |
| ACC3 | 2 K | 10.000 | 55.0 ms |
| ACC1+2 | 10.4 K | 5.872 | 168.5 ms |
| ACC0+1+2 | 9.26 K | 6.232 | 158.6 ms |
| all four | 1.65 K | 10.305 | 46.6 ms |

**ACC3 dominates** — its 2 K swamps the other three, so the ladder is strongly weighted
toward the top step. The C11/R22 time constant means every ACC change *glides* over
50–330 ms rather than stepping, and the glide is faster at high throttle. That glide is
directly visible in the cabinet recording, whose drone steps between roughly −27 dB and
−37 dB.

Full 16-entry table with Q0.24 pole codes is in the commit that added this section.

### SHIP is a VCO, not an envelope follower — the Tr2 loop

`hardware-audio.md` describes the middle of this channel as an "envelope-follower + 2-pole
filter chain". **It is not.** Traced at magnification, the first two IC17 stages after the
input buffer form a **relaxation oscillator**:

```
IC17 (6-, 5+, 7)   C22 0.01uF is its ONLY feedback element -> pure INTEGRATOR
                   input  R59 150K from the previous stage (pin 8)
                   + input at R60 51K / R61 51K = half of pin 8
                   summing node also pulled down by R58 68K -> Tr2 collector
IC17 (13-, 12+, 14) R49 100K from OUTPUT back to the + input, R48 51K to 6 V
                   -> POSITIVE feedback = SCHMITT TRIGGER
                   - input driven directly from pin 7
   pin 14 -> D10 -> R57 10K -> Tr2 base (R55 2.2K to ground), Tr2 emitter grounded
```

Integrator → Schmitt → D10/R57 → Tr2 → back into the integrator's summing node is a
textbook relaxation oscillator. Its frequency is set by the current into the integrator,
which comes from R59 150 K driven by the buffered/inverted 555 ramp.

**So the audible engine pitch is this VCO, and the 555 is a ~7 Hz LFO modulating it.** The
555's sawtooth is what makes the engine lumpy — a pitch wobble at 7 Hz, not a 7 Hz tone.
The ACC ladder sets the DC operating point and therefore the centre pitch: throttle up,
pitch up. That is exactly what an analog engine sound is built from, and it explains why
the cabinet recording's drone changes character and not just level between ACC steps.

This also means **no part of SHIP is a filter of the noise source** — SHIP does not use
NOISE at all. It is entirely self-oscillating.

### Tr4 and Tr5 — RESOLVED. They are two more copies of the same oscillator.

Traced at high magnification from sheet 1. Tr2, Tr4 and Tr5 are **three instances of one
circuit**, drafted identically, differing only in the integrator's three passives:

```
        Vs ---R_in--->|- \                        integrator
                      |    >--+--- Vint           (C is the ONLY feedback element)
        Vs --+--51K---|+ /    |
             |        |       |
            51K       +---C---+
             |
            GND                  summing node also pulled down by R_c -> Tr collector
                                 (emitter grounded)

        Vint ---------|- \                        Schmitt
                      |    >--+--- Vsq
        6V ---51K--+--|+ /    |
                   |          |
                   +---100K---+

        Vsq --10K--|>|-- base (2.2K to ground), collector -> R_c
```

| | integrator R_in | C | R_c | Schmitt R / R | series R + diode | base R |
|---|---|---|---|---|---|---|
| **Tr2** | R59 150 K | C22 0.01 µF | R58 68 K | R48 51 K / R49 100 K | R57 10 K + D10 | R55 2.2 K |
| **Tr4** | R112 100 K | C64 0.0022 µF | R114 51 K | R53 51 K / R54 100 K | R63 10 K + D4 | R52 2.2 K |
| **Tr5** | R116 150 K | C66 0.033 µF | R111 56 K | R108 51 K / R109 100 K | R122 10 K + D11 | R110 2.2 K |

All three diodes have the **anode toward the Schmitt output**, confirmed visually at high
magnification on D4 and D11 (D10 was already traced). That is the only orientation that
works: the Schmitt's high output sources base current through the diode, and the diode
blocks when it goes low so the base is never reverse-driven.

> **A designator ambiguity, recorded not hidden.** Tr4's stage carries **two** resistors
> both labelled *R114 51 K* on the sheet — the one from R113 to ground and the one from the
> summing node to Tr4's collector. One of them is presumably R115. Both read 51 K, and 51 K
> is what both slots need by analogy with Tr2 and Tr5, so nothing in the model turns on
> which is which.

**The `+` input is at `Vs/2`, referred to true ground, not to the 6 V rail.** The 51 K/51 K
divider goes from the source to *ground*. So the integrator's virtual node sits at `Vs/2`
and the current into it through `R_in` is `(Vs − Vs/2)/R_in = Vs/(2·R_in)`, always positive.
With the transistor saturated, `R_c` sinks `Vs/(2·R_c)` out of the same node. Because
`R_c < R_in` in all three, the net reverses sign:

```
Tr off:  dVint/dt = -(Vs/2) / (R_in · C)                     output falls
Tr on:   dVint/dt = +(Vs/2) · (1/R_c - 1/R_in) / C           output rises
```

**Frequency is exactly proportional to `Vs`.** These are voltage-controlled oscillators in
the linear sense, not just "roughly".

### Schmitt thresholds — shared by all three

`R48` (and R53, R108) goes to the **6 V rail**, `R49` (R54, R109) is the positive feedback
from the comparator output, which swings the LM324's full rails:

```
Vth = (6/51K + Vsq/100K) / (1/51K + 1/100K)
Vsq = V_OH = 10.5 V  ->  TH_HI = 7.519868 V
Vsq = V_OL =  0.0 V  ->  TH_LO = 3.973510 V
```

So every one of the three runs a triangle of **3.546358 Vpp about a mean of 5.746689 V**,
independent of frequency. The mean is *exactly* constant, which is what makes the DC blocks
downstream trivially correct (see below).

> **The one soft number in SHIP.** `V_OH` carries the same 0.5 V LM324-vs-MB3614 ambiguity
> flagged under "Op-amp output rails". At the MB3614's 10.0 V the hysteresis band narrows to
> 3.3775 V and **every SHIP frequency rises by exactly 5.0 %** — a uniform transposition, not
> a change of character. We take the LM324 figure, consistently with the rest of this file.
> This is SHIP's tuning knob, and it is the only one.

Duty cycle is set by `R_c`/`R_in` alone and does **not** move with frequency:

| | up | down | shape |
|---|---|---|---|
| Tr2 | 45.3 % | 54.7 % | near-triangle |
| Tr4 | 51.0 % | 49.0 % | near-symmetric |
| Tr5 | 37.3 % | 62.7 % | clearly sawtoothed |

### What drives each of the three — and this is the shape of the whole channel

```
IC14 555  --C12 ramp--> IC17 sec.A follower (pin 1) = Vramp, 4..8 V at 6.95 Hz
                          |
                          +--------------------------------> Tr5 VCO   (Vs = Vramp)
                          |
                          +-> IC17 sec.B, R50/R51 10K, + at 6V, gain -1
                                = 12 - Vramp  ------------> Tr2 VCO   (Vs = 12 - Vramp)

ACC0-3 4066 ladder -> R22/C11 -> IC22 sec.A follower ------> Tr4 VCO   (Vs = V_ACC)
```

| VCO | Vs range | Vs/2 | Hz per volt of Vs/2 | frequency |
|---|---|---|---|---|
| Tr2 | 4 → 8 V (inverted ramp) | 2 → 4 | 102.766 | **205.5 → 411.1 Hz** |
| Tr5 | 8 → 4 V (ramp) | 4 → 2 | 35.698 | **142.8 → 71.4 Hz** |
| Tr4 | 0 → 10.305 V (ACC) | 0 → 5.15 | 628.045 | **0 → 3236 Hz** |

**Tr2 and Tr5 are the audible engine and they sweep in opposite directions**, because one
takes the ramp and the other its inversion through IC17 sec.B. Tr2 covers an exact octave
(205.5–411.1 Hz) and Tr5 an exact octave an octave-and-a-half below (71.4–142.8 Hz),
crossing each other 6.95 times a second. That counter-motion is the whole reason the engine
reads as an engine and not as a siren.

**Tr4 is not audio: it is the VCA's control voltage.** It is the only thing ACC touches.

### The two output paths

**Audio** — Tr2's and Tr5's *integrator* outputs (not the Schmitt squares), each AC-coupled
into one inverting summing amp:

```
Tr2 IC17 pin 7  -> C65 2.2uF -> R118 220K --+
Tr5 IC26 pin 1  -> C59 2.2uF -> R120 220K --+-> IC26 sec.C (-), R119 30K fb, + at 6 V
                                               gain -30/220 = -0.136364  -> C72 2.2uF
                                               -> IC24 MB4391 pin 5 (I)
```

There is **no input attenuator** ahead of this VCA — the only channel without one. Peak
`±3.546 V · 0.136364 = ±0.4836 V` when the two happen to align.

**Control** — Tr4's integrator output, AC-coupled into an inverting stage sitting on a
2.977 V reference (the same R106 100 K / R104 33 K divider off 12 V that FIRE uses, here
with C57 33 µF):

```
Tr4 IC22 pin 7 -> C56 2.2uF -> R102 100K -> IC22 sec.C (-), R103 51K fb
                  + at 12 * 33/(100+33) = 2.977444 V   -> IC24 pin 6 (C)

V2 = 2.977444 - 0.51 * Vtr4_ac      Vtr4_ac = +/-1.773179 V
   -> V2 sweeps 2.0731 V .. 3.8818 V
```

Against the MC3340 curve that is **fully open (+13 dB) below 3.1 V, closing to about
35 dB down at 3.88 V**. So Tr4 *chops* the drone at an audio rate that tracks throttle. The
open half is 56.8 % of the voltage swing, so this is a deep asymmetric gate, not a gentle
tremolo — it is a ring-modulator in all but name, and the sum-and-difference sidebands it
throws off the 71–411 Hz drone are what makes the engine buzz.

### The DC blocks are exact, and that is worth stating

All three triangles have a mean of exactly 5.746689 V — the midpoint of two thresholds that
do not move — regardless of what the frequency is doing. So the three coupling networks
(C65/R118 and C59/R120 at tau = 0.484 s, C56/R102 at tau = 0.220 s) have a *constant* input
DC and are exact DC removers in steady state. They are still implemented as real one-pole
high-passes, for one reason: **at ACC = 0000 Tr4 stops dead** (Vs = 0, so both slew rates
are zero and the integrator freezes wherever it stood). The real C56 then bleeds that
frozen offset away over 0.22 s, leaving V2 at 2.977 V and the VCA wide open. A DC
subtraction would leave a permanent arbitrary offset instead.

```
audio  tau 0.484 s  a = 0.999956956  Q0.24 = 16776494  realised 0.484108 s (+0.022%)
ctrl   tau 0.220 s  a = 0.999905305  Q0.24 = 16775627  realised 0.219960 s (-0.018%)
```

Q0.24 is sufficient here (unlike FIRE's 1.02 s envelope, which needed it to be *usable at
all*). The stall floor 0.5/(1−a) is 11614 and 5280 state LSB; carried at 2^32 LSB/V those
are 2.7 µV and 1.2 µV, three orders under one output LSB.

### The 555 — corrected again, and now modelled as a real RC

The earlier `0.693·R·C` figures assumed the cap charges toward the full 12 V. It does not:
D1 is in the charge path, so the target is `12 − 0.6 = 11.4 V` and the ramp still has to
climb from 4 V to 8 V.

```
charge:  R24 6.8K, tau = 6.800 ms, target 11.4 V   t_high = 6.8m*ln(7.4/3.4) = 5.288 ms
discharge: R23 200K, tau = 200.0 ms, target 0 V    t_low  = 200m*ln(8/4)     = 138.629 ms
period 143.918 ms -> 6.9484 Hz, duty 3.675 %
```

(was 4.712 ms / 143.31 ms / 6.978 Hz / 3.29 %.) The discharge figure is unchanged because
the discharge transistor really does pull to ground. More to the point, **SHIP needs the
ramp's shape, not just its period** — IC17 sec.A follows the C12 node — so the 555 is
modelled the way `rebound_chan` models IC15B: two exponentials and a pair of comparators,
not a fixed-cycle square.

```
A_CHARGE_Q24    = 16725893   realised tau 6.8000 ms  (+0.0006%)
A_DISCHARGE_Q24 = 16775468   realised tau 199.95 ms  (-0.024%)
```

### ACC ladder — full table

Each enabled IC9 4066 section connects its resistor from **+12 V** to a common node loaded
by R22 10 K to ground and smoothed by C11 33 µF. `A_Q24` is the glide pole at
fs = 47,998.875 Hz.

| ACC3..0 | R_sel | V_ACC | glide tau | Tr4 | V·2^24 | A_Q24 |
|---|---|---|---|---|---|---|
| 0000 | ∞ | 0.0000 | 330.0 ms | stopped | 0 | 16776157 |
| 0001 | 82 K | 1.3043 | 294.1 ms | 409.6 Hz | 21883325 | 16776028 |
| 0010 | 30 K | 3.0000 | 247.5 ms | 942.1 Hz | 50331648 | 16775804 |
| 0011 | 21.96 K | 3.7542 | 226.8 ms | 1178.9 Hz | 62984856 | 16775675 |
| 0100 | 16 K | 4.6154 | 203.1 ms | 1449.3 Hz | 77433305 | 16775495 |
| 0101 | 13.39 K | 5.1309 | 188.9 ms | 1611.2 Hz | 86082051 | 16775366 |
| 0110 | 10.43 K | 5.8723 | 168.5 ms | 1844.0 Hz | 98521524 | 16775142 |
| 0111 | 9.26 K | 6.2316 | 158.6 ms | 1956.8 Hz | 104548201 | 16775013 |
| 1000 | 2 K | 10.0000 | 55.0 ms | 3140.2 Hz | 167772160 | 16770862 |
| 1001 | 1.95 K | 10.0398 | 53.9 ms | 3152.7 Hz | 168440575 | 16770733 |
| 1010 | 1.875 K | 10.1053 | 52.1 ms | 3173.3 Hz | 169538183 | 16770509 |
| 1011 | 1.833 K | 10.1411 | 51.1 ms | 3184.5 Hz | 170138719 | 16770380 |
| 1100 | 1.778 K | 10.1887 | 49.8 ms | 3199.5 Hz | 170937672 | 16770200 |
| 1101 | 1.740 K | 10.2214 | 48.9 ms | 3209.8 Hz | 171486953 | 16770071 |
| 1110 | 1.678 K | 10.2754 | 47.4 ms | 3226.7 Hz | 172393429 | 16769847 |
| 1111 | 1.645 K | 10.3052 | 46.6 ms | 3236.1 Hz | 172891776 | 16769718 |

ACC3's 2 K swamps the other three: everything from 1000 up is within 3 % of the top step.
The ladder is really a 9-step control with a coarse top half.

### Gate and output

```
IC24 pin 11 (O) -> C10 2.2uF -> IC10 4066 pin 11, control pin 12 = SHIP ON (active high)
   -> pin 10 -> R124 100K -> IC28 (-), R125 220K fb, + at 6 V  = -2.200
   -> C70 2.2uF -> SHIP MIX
```

The 4066 is a hard gate with no ramp, so SHIP ON produces a real click on the board. C10 and
C70 would soften it; they are not modelled, consistently with every other channel's coupling
caps.

### Predicted level, and where it clips

```
0.4836 V (IC26 out, both VCOs aligned) x 4.4668 (+13 dB) x 2.200 = 4.752 V
```

against `RAIL_HI` = +4.50 V, so SHIP just touches the positive rail on coincidences and is
otherwise under it. Same league as ALARM's 4.26 V and far short of EXP/HIT, which rail
outright. Apply the rails at IC28's output as every other channel does.

### One thing this trace does NOT explain: the recording's level steps

`buckrog_cabinet_recording.mp4` steps its drone between roughly −37 dB and −27 dB as
throttle changes. Nothing in the circuit above changes SHIP's *amplitude* with ACC: Tr4's
triangle has the same 3.546 Vpp swing at every ACC setting, so the VCA's duty and depth are
identical — only its rate moves. What ACC changes is **spectrum**: sidebands at 71–411 Hz ±
(410…3236 Hz), which slide from a low buzz to a bright whine.

Deliberately **not** resolved by adding a level term. Every element here is off the
schematic, and a recording does not override a primary source (same standing rule as FIRE's
decay). A band-limited measurement of the recording would very plausibly show the "level"
step as the spectral shift it actually is; whoever cares enough should measure it that way
before proposing a circuit change.

### RTL realisation — the VCOs run at clk_sys, not at fs

Every other channel's analog tail runs entirely at `sample_ce`. SHIP cannot: Tr4 reaches
3.2 kHz, which is only 15 audio samples per cycle, and a relaxation oscillator whose
threshold crossings are quantised to the audio grid jitters its period by up to 7 % and
aliases audibly.

So `relax_vco.sv` runs its integrator **at full `clk_sys`**, exactly like the 555/74123/74393
parts, and the result is box-averaged over the 832 cycles of each audio sample — the same
1st-order CIC decimator ALARM uses, and for the same reason. Two things make this cheap:

* the integrator ramp is **linear**, so a full-rate accumulator is *exact*, not an
  approximation of an exponential; and
* the slew rate only depends on `Vs`, which moves at 7 Hz, so the two step sizes are computed
  once per audio sample and merely *added* 832 times.

Threshold crossings then land within one `clk_sys` (25 ns) of the true instant.

```
Numeric formats inside ship_chan (they differ from the other channels on purpose):

  555 cap, VCO integrator state, Vs/2      2^24  LSB/V   signed [39:0]
  per-clock slew step  = (Vs/2) * K_Q40 >> 40           K in Q0.40
  DC-block state                           2^32  LSB/V   signed [47:0]
  audio tail and VCA control voltage       2^20  LSB/V   (= 4096*256, the house scale,
                                                          so the MC3340 LUT ports verbatim)
```

The 2^24 oscillator scale is set by the *smallest* step, Tr5 falling at Vs/2 = 2 V: 10.1 µV
per clock, which is 170 LSB — plenty of resolution. The largest, Tr4 rising at full
throttle, is 9450 LSB per clock. `K_Q40` carries the slew constants to a relative precision
of 4.5e−8, so period error from the coefficients is nil and all of it comes from the ±1 clk
crossing quantisation.

```
                K_UP (Q0.40)   K_DN (Q0.40)
  Tr2             22133960       18354991
  Tr4            120239916      125147668
  Tr5              9336413        5562119

  TH_HI = 126162442   TH_LO = 66664434   mean = 96413438     (all * 2^24 LSB/V)
```

`Vce_sat` is taken as 0 V. Base drive is ~0.6 mA against a collector current under 80 µA,
so all three transistors are saturated by more than 3 orders of magnitude; the real ~50 mV
`Vce_sat` shifts the rising slew rate by 1–3 % and nothing else.

### Phase 6 results — BUILT AND CONNECTED

Scenario 17 (held mid throttle), 18 (the ACC sweep), 19 (ACC = 0000, then full throttle,
then the SHIP ON gate), 20 (the gameplay pile-up).

**Frequencies**, measured on scenario 19's ACC = 0000 window — the one place the drone is
unmodulated and therefore cleanly analysable — by instantaneous frequency of the analytic
signal in each oscillator's band:

| | measured median | analytic mean | error |
|---|---|---|---|
| Tr5 | 104.1 Hz | 103.3 Hz | +0.8 % |
| Tr2 | 324.4 Hz | 319.2 Hz | +1.6 % |
| 555 LFO | 7.00 Hz | 6.948 Hz | within the 1 Hz bin |

Peak tracking over one LFO period shows the two in clean **counter-motion**: at the ramp's
reset Tr5 is at its top and Tr2 at its bottom, and they cross over the 138 ms discharge.
That is the design intent and it is unambiguous in the data.

**ACC moves spectrum, not level** — the acceptance test for the channel. Scenario 18, per
400 ms step:

| ACC | 1 | 3 | 5 | 7 | 9 | 11 |
|---|---|---|---|---|---|---|
| spectral centroid | 793 Hz | 2139 Hz | 3307 Hz | 4907 Hz | 4420 Hz | 4542 Hz |
| RMS | 3452 | 3552 | 3548 | 3539 | 3575 | 3543 |

Centroid climbs steeply through the low codes and then flattens above ACC3 — exactly what
the ladder table predicts, ACC3's 2 K putting everything from 1000 up within 3 % of the top
step. RMS is flat to ±1.8 % across the whole sweep.

Scenario 19 confirms the ACC = 0000 special case: centroid 645 Hz and RMS **4546**, i.e.
unmodulated and about 2.2 dB *louder* than any other setting, because Tr4 has stopped and
the VCA has parked wide open. That is the circuit's real behaviour, not a defect.

**Levels.** `dbg_ship_mix` peaks at **19330 LSB = 4.72 V**, against a prediction of 4.75 V.
The peak is on the *negative* excursion; the positive side is clamped at `RAIL_HI` = 18432.
The asymmetric LM324 rails are doing exactly what they are there for, and SHIP is the first
channel where the asymmetry is visible in the output rather than academic.

> **A probe that lied, recorded so nobody repeats it.** The first frequency check counted
> zero crossings of the band-passed signal and came out 10 % low on *both* oscillators.
> A common-mode error on two independent oscillators is a strong tell, and the cause was
> the instrument: these triangles are 37/63 and 45/55 asymmetric, so their second harmonics
> are strong and land inside any band wide enough to hold the whole octave sweep. A
> bit-exact Python replica of `relax_vco` + the 555 gave 103.00 / 318.00 Hz against the
> analytic 103.3 / 319.2 — 0.3 % — which is what proved the RTL right and the measurement
> wrong. **Validate the probe before believing a sim-vs-theory discrepancy.**

### Real hardware sounded like static; simulation is not proof against that

Everything above was validated in Verilator, including a full-system sim (real ROM, real
Z80 cores, coin+start driven through the actual game) — and it all sounds correct. A real
Quartus build of the same RTL did not: on a DE10-Nano the engine channel came out as solid
static while every other channel was merely in need of tuning. **This is not a contradiction
of Phase 6's results, because Verilator cannot see the failure mode at all.**

`ship_chan.sv`'s Stage 5-8 tail (IC26's gain, IC22 sec.C's control-leg gain, the MB4391
LUT's interpolation, the VCA multiply, IC28's output gain — five serial 64-bit multiplies)
was written as one combinational cloud between sample_ce edges, registered only once at the
end. A Quartus build of exactly this RTL missed setup timing on `clk_sys` (39.935 MHz,
25.04 ns period) by **-142 ns on its worst path**, with **-17.6 µs of total negative slack**
across the domain — Fmax restricted to 5.98 MHz, roughly a sixth of what the design is
clocked at. Verilator has no concept of gate delay: it resolves a combinational expression
to its final value regardless of depth, so a functionally-correct netlist and a
timing-broken one produce byte-identical WAVs in simulation. On real silicon, a flip-flop
sampling a signal that hasn't settled by the clock edge latches whatever it caught
mid-transition — which is what "solid static" is. SHIP was the worst-hit channel because it
chains more multiplies in one cycle than any other (three VCOs feeding a five-multiply
serial tail; the others have one or two), not because its logic was wrong.

**Fix, not a tuning knob:** the tail is now pipelined across multiple `clk_sys` cycles, one
multiply (or one cheap add/mux) per register hop — the same per-stage budget every other
channel's one-pole filters already keep to. There are 832 `clk_sys` cycles per audio sample
and the new pipeline is about 6 deep, so the added latency is inaudible; every intermediate
register free-runs on `clk` rather than waiting for `sample_ce`, because the values it reads
are already stable for hundreds of cycles on either side of any one sample boundary. The
ACC glide update (Stage 2) got the same treatment for the same reason — it sums two live
multiplies (`acc_a*v_acc` and `acc_b*acc_target`) in one step, the only other place in SHIP
that isn't a single-multiply one-pole.

**Lesson for the remaining channels.** `hit_chan.sv`, `exp_chan.sv` and `rebound_chan.sv`
each chain at least two multiplies (a VCA lookup plus one or more gain stages) in a single
combinational step the same way SHIP originally did, just shallower. They were not the
channel reported as broken, but "less broken" is not "correct" — the same Quartus build's
-17.6 µs of total negative slack almost certainly has contributions from all of them, and
each should get the same one-multiply-per-register-hop treatment before trusting its level
or timbre on real hardware, not just in Verilator. Re-run `quartus_sta` after each and
confirm the `clk_sys` domain's slack, not just that the audio sounds right — sounding right
in the WAV is necessary but was never sufficient.

## DSP block budget — the 32-bit mistake, and the fix

Pipelining SHIP/FIRE/REBOUND/HIT (the section above) fixed the *timing* failure mode but
created a second, independent one: a real Quartus build of that pipelined RTL came back
**129 / 112 DSP blocks (115 %)** — Fitter status `Failed`, over budget before placement even
starts — with `clk_sys` setup slack still at **-45.324 ns / -6974.228 ns TNS**. Both numbers
trace back to a single decision: every pipeline register introduced above was declared
`signed [31:0]` (and every product `signed [63:0]`), a width chosen for headroom, not
derived from the actual signal ranges.

**Why 32 bits is the worst choice on this device, not a neutral one.** Cyclone V's DSP
hard-block multiplies natively at **27×27** (or two independent 18×18s, or one sum-of-two
18×18). A 32-bit × 32-bit multiply doesn't fit either mode, so Quartus decomposes it —
`Arcade-Z80-3D.fit.rpt`'s DSP Block Usage Summary on the over-budget build showed the 129
blocks split as 62 `Independent 27x27`, 34 `Two Independent 18x18`, 33 `Sum of two 18x18`:
Quartus was already spending 2–3 blocks per 32-bit multiply where a right-sized operand
would spend one. Worse, a 32-bit operand also **defeats packing the multiplier's output
register into the DSP block itself** — the DSP Block Details table for the over-budget
build shows entries like `hit_chan:u_hit|Mult11~24` and `~365` as two *separate* DSP
instances for what should be one multiply-then-register hop, with `Output Register: no` on
every entry. When Quartus can't fold the register into the DSP, it falls back to a
soft-logic register plus a soft-logic adder tree to recombine the split multiply's partial
products — and *that* soft adder tree, not the multiply itself, is what was still blowing
the 25.04 ns `clk_sys` budget even after pipelining separated the multiplies onto their own
register hops.

**The fix is narrowing to the DSP's native width, derived from real signal ranges, not
copied.** Across every coefficient in HIT and EXP (the two files worked in this pass), the
worst-case Q24 coefficient is EXP's `RUMBLE_A1_Q24` at 33,237,369 — this needs 26 bits
signed (2^25 = 33,554,432 covers it; 2^24 does not). Filter/envelope state at this design's
voltage scale (`SCALE` = 4096×256 = 1,048,576 LSB/V, rails -6.00/+4.50 V) tops out under
2^23, needing about 24 bits signed. Both fit in **27 bits** with margin — which is also
exactly the DSP block's native operand width, so 27 is the target, not an arbitrary
round number picked for looking tidy. VCA gain values (from the shared 65-point
`VCA_GAIN_LUT`, max 292,739) get their own narrower `signed [20:0]`, since that multiply
was already small enough not to be a budget driver but still shouldn't force a wide operand
on whatever reads its result.

Concretely, in `hit_chan.sv` and `exp_chan.sv`:
- every coefficient/state `localparam` and pipeline register: `signed [31:0]` → `signed [26:0]`
- every raw product register: `signed [63:0]` → `signed [53:0]` (27×27 → 54-bit, not 64)
- the VCA gain path: `signed [31:0]` → `signed [20:0]`, its one 27×21 product → `signed [47:0]`
- `exp_chan.sv` additionally needed the same one-multiply-per-register-hop pipelining
  SHIP/FIRE/REBOUND/HIT already got — it was still "NOT YET PIPELINED" combinational MAC
  going into this pass, the same five-term shape that caused REBOUND's 98-node
  combinational loop, just narrowed at the operand-width level and never split into stages.

**What did *not* need to change:** the raw-product-then-narrow-next-stage pattern
established by SHIP/FIRE/REBOUND (`prod <= A * B;` in one stage, `y <= N'(prod >>> shift)`
in the next) was already the *correct* shape for DSP output-register packing — a bare
multiply feeding an assignment directly is exactly what Quartus's DSP inference looks for.
The 32-bit operand width, not the pipeline structure, was the defect. Narrowing without
also re-pipelining `exp_chan.sv` would not have been enough, since Quartus cannot safely
pack a register across a genuinely combinational 5-term MAC regardless of operand width.

**Verification order matters here more than usual.** Rebuilding the Verilator sim and
matching every scenario's per-channel peak against the pre-narrowing baseline (bit-exact,
all 23 scenarios) only proves the *arithmetic* survived the width change — narrower
operands with the same fixed-point scaling produce identical results as long as no real
value exceeds the new width, which the derivation above establishes. It says nothing about
DSP block count or timing, which can only be checked by an actual Quartus recompile; that
is why this file exists.

Before this pass (SHIP/FIRE/REBOUND/HIT pipelined, all still 32-bit): **129 / 112 DSP
blocks (115 %)**, `clk_sys` setup slack **-45.324 ns / -6974.228 ns TNS**, Fitter status
`Failed`.

After narrowing HIT and EXP to 27 bits (and pipelining EXP): **112 / 112 DSP blocks
(100 %)**, Fitter status **Successful** — the placement-time failure is gone, exactly at
budget with zero spare blocks. `clk_sys` setup slack improved to **-35.675 ns /
-4342.676 ns TNS**: real progress (from -45.324 ns and -6974.228 ns) but timing is not
closed yet.

**The new worst path is not in HIT or EXP anymore, and not in any of the five files
flagged below either.** `quartus_sta -t sim/report_worst_paths.tcl` puts it in
`alarm_chan.sv`: `acc[7]` to `alarm_mix[5]`, 60.277 ns data delay, the same -35.675 ns
that is now the domain's worst slack. ALARM was never pipelined or narrowed in any pass
so far — it predates the whole SHIP/timing-closure investigation — and this result says it
now needs the identical one-multiply-per-register-hop and 27-bit-operand treatment as
everything else in this file, not just the five below. Check `alarm_chan.sv` first the
next time this section's plan is revisited; it may turn out to be a bigger win than any
of the five.

REBOUND, FIRE, SHIP, `relax_vco.sv` and `la4460.sv` are flagged with a pointer to this
section but not yet narrowed — narrow them next, re-measuring after each, the same way
this pass followed HIT/EXP. Do not narrow all of them at once without an intermediate
Quartus recompile: DSP budget is already at zero spare blocks, so any narrowing pass that
widens anything by mistake will overflow it again immediately, and it's cheaper to catch
that after one file than after six.

**Update, after ALARM/LA4460/SHIP's own passes (see their subsections above): clk_sys
closes cleanly (+5.121 ns, 0 setup violations) without ever touching REBOUND or FIRE.**
Re-measuring after each fix, as this section already insisted on, is what caught that —
REBOUND and FIRE were never actually on the worst-path list once ALARM, then LA4460, then
SHIP were done; the plan to narrow them unconditionally would have been unnecessary work.
Leave them alone unless a future change reopens a violation that traces back to one of them.

### ALARM pass — division removed, not narrowed

`alarm_chan.sv`'s worst path was NOT a width/DSP-packing problem like HIT/EXP's — it was a
genuine runtime **division** (`(X_SPAN * acc) / 32'sd832`, a non-power-of-2 constant
divisor), which Verilog synthesizes as an iterative soft-logic divider regardless of
operand width. `acc` only takes 833 distinct values (0..832), so the division was replaced
with a precomputed 833-entry lookup table — exact, not an approximation, costing block RAM
instead of any multiplier (critical since DSP was already at 112/112 with zero spare
blocks). `hp_sum`/`y_state` were deliberately left at 32 bits, not narrowed to HIT/EXP's
27-bit width: this channel's own SCALE is 4096×65536 (not 4096×256), chosen specifically to
avoid a leaky-integrator rounding stall documented in the RTL, and needs ~31 bits regardless
of any DSP-packing concern.

One correctness trap surfaced during this pass, worth restating because it will recur: a
brand-new pipeline register (`acc_latched`) needs a reset value consistent with the design's
own assumed idle condition, not the "obvious" zero. `acc_latched <= 0` would mean "the wire-OR
node has been continuously LOW since power-on" — a state the board is never in — and it
corrupted the power-on-thump scenario (5.16 V measured against an expected 0.90 V) because
that scenario deliberately skips the settle time and captures the reset transient itself,
the one case where a wrong reset value doesn't get 800+ cycles to wash out before it matters.
Fixed by resetting `acc_latched` to 832 (idle, node continuously HIGH) and deriving every
downstream pipeline register's reset value from that same assumption via ordinary
elaboration-time constant arithmetic — not by hand-computing decimal constants, which is
exactly the kind of arithmetic a person gets subtly wrong and a synthesis tool does not.

Also hit, and worth flagging for whoever narrows the next file: Quartus 17.0 rejects
`localparam signed [N:0] NAME [0:M] = '{...}` (aggregate-initialized unpacked array)
with `parameter with complex/aggregate value must have a type` — it needs the explicit
`logic` keyword, `localparam logic signed [N:0] NAME [0:M] = '{...}`, matching every
existing LUT elsewhere in this codebase (`VCA_GAIN_LUT`, `ACC_V_LUT`). Verilator accepts
the form without `logic` and gives no diagnostic either way, so this only surfaces in a
real Quartus build — one more entry in the "sounds right in the WAV, wrong on real
hardware" category, though this one is a hard compile error rather than a silent one.

Before this pass: 112/112 DSP (100%, Successful), `clk_sys` slack -35.675 ns / -4342.676 ns
TNS. After: **112/112 DSP unchanged** (confirms the LUT approach added zero DSP blocks),
`clk_sys` slack improved to **-32.095 ns / -2678.023 ns TNS**. The new worst path moved
again, this time to `la4460.sv` (`x2_d[23]` to `audio_out[14]`, 56.311 ns data delay) —
already on the list below, next in line.

### LA4460 pass — narrowed and pipelined, same recipe as HIT/EXP

`la4460.sv`'s three cascaded highpass sections (C69/C83/CNF) plus the Cx lowpass and the
final output-gain multiply were all still one combinational expression per sample — the
same "settles fine in Verilator's zero-delay model, blows timing on real silicon" failure
mode as HIT/EXP, not a division like ALARM. Fix followed the established recipe: the five
filter/gain coefficients (`A_C69_Q24`, `A_C83_Q24`, `A_CNF_Q24`, `B_CX_Q24`,
`OUT_GAIN_Q16`) were narrowed from `signed [31:0]` to `signed [26:0]` (Cyclone V's native
27×27 DSP width), and the chain was split into one multiply per register-to-register hop —
four filter stages plus the output-gain stage, roughly nine pipeline registers total, all
free-running on `clk` since the 832-cycle sample window gives ample settling time for a
handful of extra clk-domain hops.

The recursive filter states themselves (`x1_d`/`y1`, `x2_d`/`y2`, `x3_d`/`y3`, `y4`, all
`signed [47:0]`) were deliberately **not** narrowed to 27 bits, unlike HIT/EXP's states —
this file's own header note already documents that the 0.282 Hz lowpass pole needs the
extra width to avoid a rounding stall floor, so cutting it back down would reopen a bug
this file was written to avoid. `audio_out` was changed from sample_ce-gated to
free-running-on-clk, matching every other channel's `_mix` output register
(`hit_mix`/`ship_mix`/`alarm_mix`/`exp_mix`); this shifted scenario 21's
`first_nonzero` by exactly one sample (73495 → 73494), which is `dc_mute`'s release now
landing on the clk cycle it actually happens rather than snapping forward to the next
sample_ce boundary — a resolution improvement, not a regression, and confirmed as such
because every per-channel level in that scenario (and all 22 others) stayed bit-exact.

No reset-value re-derivation was needed here, unlike ALARM: this file's recursive states
already reset to plain zero, and that genuinely is the board's true idle state (uncharged
coupling caps) rather than a non-zero idle condition needing careful arithmetic — and the
one scenario that captures reset-transient behavior (mute-release timing) has `audio_out`
forced to hard zero by `dc_mute` for the entire window that would matter, so no warm-up
transient could leak through even if the states were wrong.

Before this pass: 112/112 DSP (100%, Successful), `clk_sys` slack -32.095 ns / -2678.023 ns
TNS. After: **112/112 DSP unchanged**, `clk_sys` slack improved to **-10.787 ns**. The new
worst path moved to `ship_chan.sv` (`relax_vco:u_tr2|acc[40]` to `p0_vca_in_prod[55]`,
the VCA input multiply in SHIP's relaxation-oscillator chain) — next in line below.

### SHIP pass — three combinational multiplies in series, and a DSP-budget detour

SHIP's worst path wasn't inside `ship_chan.sv` itself but spanned three modules:
`relax_vco.sv`'s box-average divide (`acc * RECIP832_Q32`, a live 56x32 multiply straight
off a bare `assign`, valid only on the single clk_sys cycle sample_ce fires on and garbage
every other cycle) fed directly into `dc_block.sv`'s own one-pole multiply, which fed
directly into `ship_chan.sv`'s stage-0 gain multiply — three serial multiplies settling in
one clk_sys hop, worse than anything HIT/EXP/ALARM/LA4460 had. Fixed with the same
`acc_latched`-then-free-run pipeline as `alarm_chan.sv`, applied at each of the three
boundaries, with one correctness trap and one budget trap along the way:

**Correctness trap.** `dc_block.sv`'s recursive state update (`x_d`/`y_state`) must capture
a *prompt* pulse (`relax_vco.sv`'s new `vint_avg_ce`, firing a few clk_sys cycles after the
real sample_ce), not a full-audio-sample-late one the way `alarm_chan.sv` accepts for its
own near-DC control signal — Tr2/Tr4/Tr5 are oscillators down to ~15 samples/cycle, so a
full-sample lag there would be a real, audible phase error. Separately, `dc_block.sv`'s
output tap (`y_out`) must read off the *stable* `y_state` register (only changes at
`sample_ce`, held for the whole window), not off the continuously free-running
hp_sum/hp_prod/y_next chain — that chain sees `x_d` and the fresh `x_scaled_pA` momentarily
equal right after a capture (both just set to the same window's x[n]) and computes a pure
decay step (`y <= a*y`) on every one of the ~825 remaining clk_sys cycles if wired to it
directly, a ~3.5% amplitude error on SHIP's peak. Neither of these was caught by inspection
— both surfaced only via full-game regression, and were traced by directly comparing
instrumented traces of `vint_tr2`/`ac_tr2` against the same probe built from the unmodified
HEAD RTL to separate a genuine bug from an initially-suspected (and ultimately nonexistent)
one: the first regression run flagged looked like a real ~1.6% SHIP amplitude error, but it
turned out the comparison baseline itself was stale — the true HEAD baseline already
produced the "wrong" numbers. Rebuilding HEAD unmodified with the same debug probe and
diffing against it directly is what confirmed which discrepancies were real.

**DSP-budget trap.** With DSP already at 112/112 and zero spare blocks, turning these three
combinational multiplies into registered ones let Quartus DSP-infer computations that
previously cost nothing (soft logic, since they were never a clean register-to-register
multiply). Narrowing the *coefficient* operand of each multiply (`RECIP832_Q32`,
`A_Q24`, 32→27 bits, the usual playbook) was not sufficient and DSP count stayed at
121/112 (Fitter Failed) — because a Cyclone V 27x27 DSP packs an operand in
`ceil(width/27)` chunks, and it's the *wider* of the two operands that sets the chunk
count. `relax_vco.sv`'s `acc`/`acc_latched` was declared at 56 bits (needing 3 chunks)
despite only ever holding a ~38-bit value, because as a bare combinational divide its
declared width cost nothing either way. Narrowing it to 40 bits (2 chunks, matching
`vint`/`vs_half`'s own width) is what actually closed the gap.

Before this pass: 112/112 DSP (100%, Successful), `clk_sys` slack -10.787 ns. After:
**112/112 DSP unchanged**, `clk_sys` slack improved to **+5.121 ns** — the first *positive*
slack this whole pass has produced, and `quartus_sta`'s worst-path report confirms **0
setup violations remain on clk_sys** (new worst path is `exp_chan.sv`'s `exp_mix` into
`audio_mixer.sv`, already comfortably positive). REBOUND and FIRE, both still on the
original flagged list, never needed touching — clk_sys closes cleanly without them. The
only remaining setup violation in the whole design is on `pll_hdmi`'s divclk domain
(-3.222 ns), an HDMI video-timing domain unrelated to audio.

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

**It is also only the ALARM leg's share**, and — resolved in phase 7 — that is the whole of
it. This section used to predict that "the big one arrives with the LA4460 output stage". It
does not. C69/C83 charge behind the DC mute, which holds for 1.531 s, and the *reason* that
timer is on the board is to make exactly this inaudible. ALARM's thump is modelled, is
correct, and never reaches the speaker.

Scenarios 0–10 call `settle()` first, which runs **without recording** — 600 ms originally,
now 1700 ms, because since phase 7 the binding constraint is no longer the 52 ms high-pass
tau but the 1.531 s mute release. It runs long enough that
the thump has decayed to bit-exact zero and each scenario's timeline still starts at
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

## Phase 7 — the global mute and the LA4460 output stage

Until this phase the model stopped at IC28 and scaled its output by an integer `MASTER_VOL`.
That constant is gone: the amplifier, its input network and the board's mute are all on the
schematic and are now modelled. `mute_ctl.sv` and `la4460.sv`.

### GAME ON is the LA4460's DC mute, not an upstream gate

Traced from sheet 1. `hardware-audio.md` had pin 6 as "NFB/ripple, fed from D5 off the SHIP
chain"; both halves were wrong and are corrected there. Pin 6 is **DC Audio Muting**
(datasheet pin table: quiescent 5.6 V, attenuation **∞**). The *AC* mute, with its finite
38 dB, is pin 1 and this board does not use it — so the mute is total, not a fade.

Two pull-down-only drivers wire-OR onto that pin:

```
GAME ON (ppi1_pb[7]) -> IC5 7417 OPEN COLLECTOR, 47K pull-up to 12 V -> pin 6
12 V --R107 470K--+-- IC26 sec.D (12+), (13-) at 6 V, out 14 -> D5 (cathode at IC26) -> pin 6
                  +-- C58 4.7uF to ground
                  +-- D9 (anode here, cathode at 12 V)
```

* `GAME ON` low mutes — matching MAME's `system_mute(!BIT(data,7))`.
* The comparator mutes for the first **1.531 s** after power-on:
  `tau = 470K · 4.7 µF = 2.209 s`, crossing the 6 V reference at `2.209 · ln(12/6)`, which is
  **61,147,057 `clk_sys` cycles**.

D9 re-arms the mute at power-off by dumping C58 into the collapsing rail. There is no
power-off on an FPGA, so D9 is documented and not modelled. Reset is treated as power-on,
which means **a mid-session core reset re-arms the 1.5 s delay** where the real board would
not, C58 staying charged. Recorded as a deviation; it only shows on reload.

The power-on timer is implemented as a plain counter rather than an RC plus comparator. The
crossing is deterministic, nothing else observes the node, and this is the one place in the
design where the exponential shape has no consequence.

**This resolves the open item under "Power-on thump".** That section predicted "the big one
arrives with the LA4460 output stage". It does not: the mute is what the timer is *for*. Every
coupling capacitor on the board charges behind an infinite attenuation and is long settled
before pin 6 releases — 1.53 s is 2.9 tau of the slowest of them (C69, 0.53 s). ALARM's
modelled +0.90 V thump is now inaudible for the same reason, which is the correct behaviour
rather than a lost feature.

### The input network — VR1 is a divider, not a scalar

```
IC28 -> C69 4.7uF -> R45 100K -> VR1 20K (top at R45, bottom to GND, wiper out)
     -> C83 4.7uF -> LA4460 pin 2 (ri = 30 K typ, 21 K min)
```

At wiper fraction `k` the pot is a loaded divider, not a gain: `R_upper = (1−k)·20K` adds to
R45 while `R_lower = k·20K` shunts, in parallel with `ri` through C83. At the chosen
k = 0.100:

```
R_par = 2K || 30K = 1.875K
divider = 1.875 / (100 + 18 + 1.875) = 0.015641
C69 tau = 4.7u * (100K + 18K + 1.875K) = 0.5634 s   -> 0.282 Hz
C83 tau = 4.7u * (R_src 1.844K + 30K)  = 0.1502 s   -> 1.059 Hz
```

Both corners are subsonic and neither removes any DC, because the house format already carries
every channel as an AC quantity about the implicit 6 V rail — the caps reset *uncharged*, which
in that format is simply zero. They are still real one-poles: the 0.282 Hz pole is the slowest
in the whole design, so it is also the worst stall case, and it is what shapes ALARM's power-on
thump on its way to the (muted) amp.

### The amplifier

51 dB fixed gain (spec 49/51/53), bridged outputs, on the board's 12 V rail. Two poles, both
read off the datasheet's **f Response** graph, which plots exactly the component values this
board fits:

| | source | corner |
|---|---|---|
| low-pass | `Cx` = C84 0.01 µF (the graph's "0.01 µF" curve, against "C1 = 0" nearer 20 kHz) | **9 kHz** |
| high-pass | `CNF` = C82/C81 47 µF (the graph's 47 µF curve, −3 dB ≈ 47 Hz, −9 dB at 20 Hz) | **47 Hz** |

**These two are the roll-off this document has been pointing at since phase 1.** The note under
"Anti-aliasing" says the board's square waves "are rolled off only by the LA4460 and the
speaker"; the LA4460's half of that is now modelled and is datasheet-backed. The speaker's half
is not, and will not be: there is no part number on the schematic and no measurement, and
fitting a speaker response to a recording would break the standing rule that a recording does
not override a primary source. ALARM and HIT will therefore still read brighter than a cabinet.

Both corners are read off a printed log graph and are worth no better than ±20 %. **They are
the output stage's only tuning knobs**, and 9 kHz is the one to move first — it is what decides
how harsh the alarms sound.

```
fs = 47,998.875 Hz, all Q0.24
A_C69_Q24 = 16776596   0.282 Hz     A_CNF_Q24 = 16674312   47.000 Hz
A_C83_Q24 = 16774890   1.059 Hz     B_CX_Q24  = 11612258   9000.0 Hz (low-pass)
```

High-pass states are carried at 2^32 LSB/V in 48 bits, per "Numeric formats" — at 0.282 Hz the
stall floor bites harder here than anywhere else in the design.

### Clipping is now physical

```
AUDIO_L = AUDIO_R = saturate16( filtered * OUT_GAIN_Q16 >>> 16 )
OUT_GAIN_Q16 = 338322 = 0.01564129 (VR1) * 354.813389 (51 dB) * 0.9302042 (scale) * 65536
```

The last factor maps 4096 LSB/V onto an int16 whose full scale **is the amplifier's clip
point**, so the saturation in that line is the LA4460 running out of rail, not a format guard:

```
V_CLIP = 8.6 V differential
   datasheet: 12 W into 4 ohm at Vcc = 13.2 V  ->  9.8 V peak  ->  3.4 V dropped in the device
   the board runs it on 12 V                   ->  12 - 3.4    =  8.6 V
```

This is the same argument already made for the op-amp rails: a real clip in the right place is
part of what the hardware sounds like, and modelling it away costs both the distortion and the
level.

`VR1`'s setting remains the one number in this document chosen by taste rather than by the
schematic, and it is still isolated in a single constant — but it now has a physical meaning
(fraction of pot rotation) and a physical consequence (turn it up and the amp clips, as it does
on the board).

`AUDIO_S = 1` (signed), `AUDIO_MIX = 0` (no MiSTer-side blending; the board is mono).

### Phase 7 results

Scenario 21 (the power-on mute, no settle, engine running underneath), 22 (`GAME ON` toggled
with an alarm and a hit fired *while* muted). All 23 scenarios re-run.

| | measured | design |
|---|---|---|
| mute release | sample **73,494** | 61,147,057 / 832 = 73,494.06 |
| output before release | **bit-exact zero**, 73,494 samples | silent |
| scenario 11, the power-on thump | peak **0** at the output, 3688 LSB (0.90 V) at `dbg_alarm_mix` | thump modelled, never heard |
| `GAME ON` low | exactly 19,200 samples = 400.000 ms of zero | — |
| channels behind the mute | alarm 4.26 V and hit 6.00 V reached while silent, hit reappears mid-tail | not a reset |

**Scenario 11 is now the interesting one.** The power-on thump is still modelled, still 0.90 V,
and still visible on the channel probe — and the output is zero for the whole capture. That is
the correct hardware result and it is only checkable *because* the per-channel debug taps exist.
A master-only instrument would have read "no thump" and been unable to tell a modelled-then-muted
thump from a thump that was never built.

**Levels.** No scenario clips. The pile-up, scenario 20, peaks at **27,616 = −1.49 dBFS**
against the 8.6 V rail — near enough to the −1.66 dBFS the old `MASTER_VOL` was set to that the
smoke test should sound the same loudness, which is deliberate. Nothing else exceeds 27,000.
Per-channel MIX levels are unchanged to within 2 LSB, as they must be: phase 7 is downstream of
every one of them.

### The idle floor is 4 LSB, and it is not ours

Idle output is not bit-exact zero: it dithers over roughly −5..+2 LSB, about −78 dBFS. This is
**not** a filter stall and **not** new in phase 7 — it is the MC3340's finite attenuation.
80 dB down is not infinity, so the noise-fed channels leak a little of the MM5837 forever, which
is why every scenario's per-channel column reads `exp=10, fire=1` with nothing triggered. Through
the mixer and the amp that becomes ±4 LSB.

**Acceptance criterion 5 below ("silence is bit-exact zero") has therefore been stale since EXP
landed in phase 3**, and phase 7 is what made it visible by adding a `first_nonzero` probe.
The criterion should read: silence is the VCA leakage floor, ±4 LSB, and true zero only while
the DC mute is asserted. Chasing the 10 LSB at `dbg_exp_mix` would be chasing the circuit.

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
| 5 | Silence is bit-exact zero before the first alarm | **SUPERSEDED** — was PASS in phase 1 (387 leading zero samples against an onset at 384), but only because ALARM was then the only channel. Since phase 3 the floor is EXP's VCA leakage at ±4 LSB; since phase 7 true zero exists only under the DC mute. See "The idle floor is 4 LSB, and it is not ours" |

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
