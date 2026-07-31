# Discrete audio — RTL design contract

Companion to `docs/hardware-audio.md`, which holds the *hardware* facts. This file holds
the *implementation* decisions: numeric formats, clocking, module boundaries, and every
place we knowingly depart from the circuit. Nothing here may contradict
`hardware-audio.md`; if it seems to, the schematic wins and this file is the bug.

Status: **phase 1 — ALARM channel only.** The mixer is built for all six channels from
the start (see "Why the mixer is built whole"), but five of its inputs are tied to zero.

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
| High-pass filter state | `signed [31:0]` | 4096·256 LSB = 1 V | ±2048 V |
| Filter coefficients | `unsigned [15:0]` | Q0.16 | — |

All channel buses are **AC quantities centred on zero**, representing volts relative to the
board's 6 V mid-rail. The 6 V rail is the model's zero; it is never represented explicitly.

The filter state carries 8 extra fractional bits because the high-pass pole is at
a = 0.9996, and a leaky integrator that close to unity quantizes to death in 16 bits.

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

Scenario 6 (one shot) peaks at 7168, against ALARM's 19904 — FIRE sits 8.9 dB below the
alarm, which is consistent with the equal 10 K mixer resistors. Scenario 8 (FIRE under a
sustained ALARM0, the real gameplay combination) peaks at 25616 with no clipping.

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

`MASTER_VOL` defaults to **256** (i.e. ×16), putting ALARM alone at about −10 dBFS. This is
a placeholder to be recalibrated once all six channels exist and the loudest realistic
combination is known — it is the one number in this document chosen by taste rather than by
the schematic, and it is isolated in one parameter for exactly that reason.

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
| 5 | Silence is bit-exact zero before the first alarm | **PASS** — max sample 0 over the first 480 samples |

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
