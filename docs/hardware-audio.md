# Buck Rogers Sound Board (Gremlin/Sega 834-5122) — hardware notes

Traced from `docs/reference/Buck_Schematics.pdf`. Renders of the sheets are in
`docs/schematics/` (regenerate with `python tools/render_sheets.py buck 20,45-47`).

| What | Where |
|---|---|
| Sound board schematic, sheets 1-3 | PDF pages **45, 46, 47** (printed 191-193) |
| Sound board PCB assembly drawing (every R/C value) | PDF page **20** |
| Theory of operation prose | PDF pages 1-16 |

Board numbers: CPU **834-5120**, EPROM **834-5121**, Sound **834-5122**.
Printed page number = PDF page + 146. Drawn by Dyna-Pac, Dec 1982.

The board is entirely discrete/analog apart from the digital noise source and the alarm
tone divider. MAME does **not** emulate any of it — `turbo_a.cpp` plays hand-made WAV
samples, and its `DISCRETE_SOUND_START` netlist is compiled out behind
`#define DISCRETE_TEST (0)`. Every set carries `MACHINE_IMPERFECT_SOUND`. This schematic
is therefore the only accurate reference.

---

## Interface from the CPU board

The sound generator is the **8255A-5 at IC113** on CPU board sheet 4, reaching the sound
board over a 20-pin flat cable. Connector lines are pulled up by **RA1 (4.7 K × 16)** and
**RA2 / RA3 (47 K × 8)** and buffered by **IC1 / IC5 (7417 hex open-collector buffers)**.

Two of the buses are latched on-board rather than used directly:

| Latch | Part | Output |
|---|---|---|
| IC2 | 4175B quad D flip-flop | `HIT DIS0-2` — hit volume |
| IC6 | 4175B quad D flip-flop | `ACC0-3` — ship engine pitch (MAME's `myship`) |

Everything else is buffered straight through:

| Signal | Polarity | Consumer |
|---|---|---|
| `/ALARM0` … `/ALARM3` | active low | sheet 3, IC3 / IC7 one-shots |
| `/FIRE` | active low | sheet 3, IC4 one-shot |
| `/EXP`, `/HIT`, `/REBOUND` | active low | sheet 2 |
| `SHIP ON` | active high, level | sheet 1 engine gate |
| `GAME ON` | active high, level | global mute |

These names match MAME's `turbo_a.cpp` handlers 1:1, which is good evidence the driver's
latch decode was taken directly off this schematic.

### Connector pinout (RESOLVED — sheet 1, IC1/IC2/IC6 wiring traced)

The 20-pin flat cable `FAP-20-07`. IC1 (7417) buffers connector pins 1-6; its six outputs
split into a shared 4-bit **data nibble** and **two independent latch clocks**:

| Conn pin | IC1 in → out | Destination |
|---|---|---|
| 1 | 1 → 2 | D0 — IC2 `D0` **and** IC6 `D0` |
| 2 | 13 → 12 | D1 — IC2 `D1` **and** IC6 `D1` |
| 3 | 3 → 4 | D2 — IC2 `D2` **and** IC6 `D2` |
| 4 | 11 → 10 | D3 — IC6 `D3` only (IC2's D3 is unused) |
| 5 | 5 → 6 | **IC2 `CK` (pin 9)** — latches `HIT DIS0-2` |
| 6 | 9 → 8 | **IC6 `CK` (pin 9)** — latches `ACC0-3` |
| 7-10 | (direct) | `/ALARM0` … `/ALARM3` |
| 11 | (direct) | `/FIRE` |
| 12, 13, 14 | (direct) | `/EXP`, `/HIT`, `/REBOUND` |
| 15, 16 | IC5 (7417) | `SHIP ON`, `GAME ON` |
| 17-20 | — | to the power/ground block, bottom left |

Both latches are **4175B quad D** parts sharing one nibble; IC2 simply ignores D3. So the
CPU writes a 4-bit value and then strobes whichever latch it means. This matches
`turbo_a.cpp` exactly.

### CPU-side latch bits (from `turbo_a.cpp`, PPI1 at `d000-d003`)

**Port A** — bits 0-3 are the shared data nibble (`HIT DIS` uses only bits 0-2, `ACC` uses
all four); bit 4 rising edge strobes hit volume; bit 5 rising edge strobes `ACC0-3`; bit 6
`/ALARM0` (falling edge); bit 7 `/ALARM1` (falling edge).

**Port B** — bit 0 `/ALARM2`; bit 1 `/ALARM3`; bit 2 `/FIRE`; bit 3 `/EXP`; bit 4 `/HIT`;
bit 5 `/REBOUND` (all falling edge); bit 6 `SHIP` (level, engine on/off); bit 7 `GAME ON`
(level, active low mutes).

**Port C** — bits 0-2 `OBCH0-2` (video, sprite color bank); bit 4/5 coin meters; bit 6
start lamp; bit 7 documented as "BODY SONIC", unimplemented.

---

## Channels

Six channels feed one weighted summing amplifier. Op-amps run single-supply against a
**6 V mid-rail** used as AC ground throughout — any DSP model must adopt the same DC bias
convention or the envelope followers misbehave.

### NOISE — the shared source (sheet 3)

**IC33 = National MM5837.** Not an analog noise diode: it is a **17-bit LFSR with taps at
17 and 14**, clocked by an on-chip RC oscillator nominally 32-64 kHz (notoriously
part-to-part variable). It is therefore reproducible bit-exactly in ~15 lines of Verilog;
only the clock rate needs tuning by ear. ~48 kHz is the usual choice.

Two buffered/attenuated taps, both via IC29 (LM324):

| Tap | Network | Gain | Feeds |
|---|---|---|---|
| NOISE·A | C86 10 µF, R140 100 K in, R139 10 K fb | ≈ -0.1 | FIRE (sheet 3), EXP (sheet 2) |
| NOISE·B | C85 10 µF, R144 330 K in, R143 100 K fb | ≈ -0.3 | HIT (sheet 2) |

No band shaping happens here — that is downstream, per effect.

### SHIP — engine drone (sheet 1)

> **This summary is WRONG in its middle. Do not build from it.** The block it calls an
> "envelope-follower + 2-pole filter chain" is nothing of the kind: Tr2, Tr4 and Tr5 are
> three instances of one *relaxation oscillator*, SHIP uses no NOISE at all, D1 is in the
> 555's CHARGE path (not the discharge path), the 4066 inputs tie to +12 V so ACC is a DC
> level ladder rather than an audio gate, and ACC drives nothing but Tr4 — which is the
> VCA's control voltage, not audio. The component list below is accurate and useful; the
> topology around it is not. See `audio-rtl-design.md`, "Phase 6", for the traced circuit.
> Left in place rather than rewritten so the correction stays visible.

```
IC14 555 astable     R24 6.8K charge, R23 200K + D1 discharge, C12 1uF, C88 0.01uF ctrl
  -> IC17 LM324 buffer
  -> IC9 4066 x4, gated by ACC0-3, series weights:
         ACC0 -> R20 82K   ACC1 -> R21 30K   ACC2 -> R18 16K   ACC3 -> R19 2K
     (all summed at a common node; parallel conductance, NOT a binary DAC)
  -> IC17 / IC22 / IC26 LM324 envelope-follower + 2-pole filter chain
         Tr2 path: R51 10K, R59 150K, R60 51K, R61 51K, R58 68K, D10, R57 10K,
                   R48 51K, R49 100K, C22 0.01uF
         Tr4 path: R112 100K, R113 51K, R114 51K, D4, R52 2.2K, R53 51K
         Tr5 path: C66 0.033uF fb, R116 150K, R117 51K, R121 51K, R111 56K,
                   R108 51K, R110 2.2K, D11, R122 10K
         then C65 2.2uF, R118 220K, C64 0.0022uF high-pass
  -> C72 2.2uF -> IC24 MB4391 VCA (control from R103 51K, C68 680pF on RO)
  -> C10 2.2uF -> IC10 4066 -> R124 100K / R125 220K -> IC28
  -> C70 2.2uF -> SHIP MIX
```

The 555's discharge resistor is shunted by D1, giving a strongly asymmetric waveform —
that asymmetry is what makes it a buzz rather than a clean square, so model it.

### HIT — percussive noise burst (sheet 2)

```
NOISE·B -> C47 4.7uF
  -> IC20 LM324 2-pole low-pass: R84 15K, R88 15K, C49 0.0033uF, C50 0.0033uF,
                                 R86 100K / R85 150K fb
  -> C38 2.2uF, R80 33K, R81 10K bias, C71 2.2uF
  -> IC24 MB4391 VCA
       control = IC13 74123 one-shot fired by /HIT, C42 4.7uF timing,
                 shaped by R90 1M / R91 470R / C48 0.68uF / R96 1M
  -> C13 2.2uF -> IC10 4066 x3 gated by HIT DIS0-2:
         HIT DIS0 -> R25 100K   HIT DIS1 -> R26 22K   HIT DIS2 -> R27 10K
         summing node biased 12 V through R28 100K, C9 0.01uF
  -> C14 2.2uF -> R135 100K -> IC28 LM324 (R134 680K fb) -> C73 2.2uF -> HIT MIX
```

### EXP — explosion (sheet 2)

Two envelopes of very different length are combined, which is what separates the initial
crack from the rumble:

```
/EXP -> IC8 74123 section A: R16 47K, C7 4.7uF   (fast)
        -> D6 -> R11 10K, R10 470K, C88 1uF
NOISE·A -> IC8 74123 section B: R17 47K, C8 22uF (slow rumble)
        -> D7 -> R151 470R, R150 1M, C89 2.2uF

IC21 MB3614, two sections:
  sec.1  R98 220K fb, C53 0.0068uF, C54 0.0068uF, R94 4.7K, C46 4.7uF, R95 2.7K
         -> C55 2.2uF, R99 10K -> IC19 MB4391 control
  sec.2  R101 100K / R99 150K fb, R87 15K, R89 15K, C51 0.039uF, C52 0.039uF
         -> C36 2.2uF, R73 10K, R72 3.3K -> IC19 MB4391 audio in

IC19 out -> C28 2.2uF, R71 220K -> IC25 LM324 (R141 470K fb)
         second tap C26 2.2uF, R70 100K also into IC25
         -> C76 2.2uF -> EXP MIX
```

### REBOUND — tone burst (sheet 2)

```
/REBOUND -> IC13 74123 section A: R47 47K, C44 1uF
  -> D2 -> R44 470R, R43 330K, C43 2.2uF
  -> IC12 LM324 buffer
  -> IC15B 555 tone burst: R64 33K, C31 1uF, R65 10K pull-up
  -> IC12 gain stage: R37 12K / R36 4.7K
  -> Tr3 gate
  -> C45 2.2uF, R82 3.3K, R83 10K bias, C24 2.2uF
  -> IC18 MB4391 VCA (control from the R38 51K / C40 0.022uF envelope, C21 680pF on RO)
  -> C20 2.2uF, R62 100K -> IC22 LM324 (R128 330K fb) -> C75 2.2uF -> REBOUND MIX
```

### FIRE — laser (sheet 3)

```
/FIRE -> IC4 74123: R7 47K, C4 1uF  (tau ~ 0.28*R*C ~ 13 ms), Q pin 5
  -> D8 -> R4 150K, C3 6.8uF decay
  -> IC20 LM324 sec.1 (pins 10+/9-/8out)
  -> R77 15K into Tr1 base (R76 3.3K bias, R32 1.5K emitter, R31 100R load)
  -> IC20 sec.2 (R78 56K in, R79 47K fb; reference R74 100K / R75 33K / C37 33uF)
  -> IC18 MB4391 control pin 2, C19 680pF integrating the control node

NOISE·A -> C30 4.7uF, R33 10K
  -> IC12 LM324 (R35 47K fb, C32 0.01uF, C33 0.01uF -> corner ~340 Hz)
  -> C16 2.2uF, R67 30K, C23 2.2uF -> IC18 audio in

IC18 out pin 15 -> C25 2.2uF, R69 100K -> IC25 (R142 220K fb, ~ -2.2x)
  -> C77 2.2uF -> FIRE MIX
```

### ALARM0-3 — gated tones (sheet 3)

Fully digital up to the mix, so it ports almost literally:

```
IC15A 555 astable: R29 470R (Ra), R30 270R (Rb), C15 0.1uF (NOT .01 -- see below),
                   C17 0.01uF on CTRL
    f = 1.44 / ((Ra + 2*Rb) * C) = 1.44 / (1010 * 1e-7) ~ 14.26 kHz
  -> R66 1K pull-up -> IC16 74LS393 pin 1 (1A)
  -> IC16 pin 2 (1CLR) and pin 12 (2CLR) are tied together and GROUNDED (free-running)
  -> 2A (pin 13) is tied to 1QD (pin 6), so the two halves cascade into one 8-stage ripple
  -> IC11 74LS38 open-collector NAND x4: each ANDs one tap with one alarm enable,
     all four wire-OR'd onto a node pulled up by R153 1K

RESOLVED tap -> gate -> alarm mapping (sheet 3; the four one-shot lines do not cross):

| Alarm | 74123 | one-shot R/C | IC11 gate (in,in -> out) | IC16 tap | divide | tone |
|---|---|---|---|---|---|---|
| ALARM0 | IC3 pin 1  -> Q13 | R2 47K / C1 6.8uF  | 1,2 -> 3    | pin 11 = 2QA | /32 | 446 Hz |
| ALARM1 | IC3 pin 9  -> Q5  | R3 47K / C2 6.8uF  | 12,13 -> 11 | pin 6 = 1QD  | /16 | 891 Hz |
| ALARM2 | IC7 pin 1  -> Q13 | R14 47K / C5 6.8uF | 4,5 -> 6    | pin 5 = 1QC  | /8  | 1782 Hz |
| ALARM3 | IC7 pin 9  -> Q5  | R15 47K / C6 10uF  | 9,10 -> 8   | pin 4 = 1QB  | /4  | 3565 Hz |

Every element of this table is read directly off sheet 3 at high magnification. The tap
verticals are unambiguous (2QA -> gate pin 2, 1QD -> gate pin 13, 1QC -> gate pin 5,
1QB -> gate pin 10) and the four one-shot enable lines run to gate pins 1/12/4/9 in
top-to-bottom order without crossing.

One-shot gate lengths are ~0.45*R*C: 144 ms for the three 6.8 uF sections, 211 ms for
ALARM3's 10 uF. (An earlier revision of this document said "tau ~ 9 ms"; that was a
decimal slip and is wrong by more than 10x.)

### When the game uses ALARM

**The end-of-level score count-up.** Each point tick fires an alarm pulse, which is why
the lines are driven as a dense retrigger train rather than as discrete beeps.

Confirmed by `tools/mame/dump_sound_triggers.lua`: **zero** alarm activity in 50 s of
attract mode, then a burst during play driven from two code sites -- PC `4d09` writes
ALARM0 and ALARM1, PC `4bc5` writes ALARM2. Retrigger interval was **50-100 ms**, well
inside the 144 ms one-shot width, so the 74123s never time out mid-tally and the tone is
continuous for as long as the score is rolling.

Two consequences for the model, both load-bearing:

1. The 74123s **must** be retriggerable. If they merely re-fired on timeout the tally
   would stutter instead of sustaining.
2. ALARM0/1/2 overlap during the tally, so the four open-collector NANDs are wire-ORing
   several tones at once. Simultaneous alarms **intermodulate** -- the node is one bit,
   so the tones multiply rather than sum. This is the normal case in gameplay, not an
   edge case, which is why it is a phase-1 acceptance criterion.

mix: R154 5.1K, C88 4.7uF -> IC29 -> R127 100K -> IC25 (R129 200K fb, ~2x)
     -> C74 2.2uF -> ALARM MIX
```

---

## Master mixer and output (sheet 1)

**This is not a virtual-ground summing amp.** R138 (200 K) sits *in series* between the
common mix node and IC28 pin 13 — resolved by tracing sheet 1 zone A6. The six channel
resistors therefore meet at a **passive** node that is **not** held at AC ground, and
IC28 (feedback R126 = 100 K, non-inverting input tied to the 6 V rail) is a following
gain stage of −R126/R138 = **−0.5**.

```
Vnode = (SUM Vch/Rch) / (SUM 1/Rch + 1/R138)
Vout  = -(R126/R138) * Vnode = -0.5 * Vnode
```

With SUM 1/Rch = 5x(1/10K) + 1/5.1K = 6.961e-4 and 1/R138 = 5e-6, denominator = 7.011e-4:

| Channel | Summing R | Node share | Effective gain to IC28 out |
|---|---|---|---|
| **HIT MIX** | **R136 = 5.1 K** | 0.280 | **−0.140 — 1.96× everything else** |
| SHIP MIX | R137 = 10 K | 0.143 | −0.0713 |
| FIRE MIX | R131 = 10 K | 0.143 | −0.0713 |
| EXP MIX | R133 = 10 K | 0.143 | −0.0713 |
| REBOUND MIX | R130 = 10 K | 0.143 | −0.0713 |
| ALARM MIX | R132 = 10 K | 0.143 | −0.0713 |

The *relative* weighting an earlier revision recorded (HIT ≈ 2×, everything else equal)
survives, but the absolute figures there (10×, 19.6×) were computed as if R138 did not
exist and are wrong by a factor of ~140. Because the node is passive, the channels also
**load each other**: a channel's gain depends on the source impedance of all five others,
so the outputs feeding this node must be modelled as low-impedance drivers or the
weighting will drift.

Output stage:

```
IC28 -> C69 4.7uF -> R45 100K -> VR1 20K volume pot -> C83 4.7uF -> LA4460 pin 2
LA4460: pin 10 = +12 V (C80 470uF), pin 6 = NFB/ripple (fed from D5 off the SHIP chain),
        pins 4/5 bootstrap C82 47uF / C81 47uF / R145 1.5K, pin 3 gnd C84 0.01uF,
        pins 7 & 9 = speaker out, each with a Zobel: 0.033uF + 4.7R 1/2W
On-board supply filtering: R147 1K, R148 1K, C60-C63 470uF (12 V / 6 V / 5 V rails)
```

---

## IC roster (assembly drawing, PDF page 20)

| IC | Part | Sheet | Role |
|---|---|---|---|
| IC1, IC5 | 7417 | 1 | connector input buffers |
| IC2, IC6 | 4175B | 1 | latch `HIT DIS0-2` / `ACC0-3` |
| IC3, IC7 | 74123 | 3 | ALARM0-3 one-shots |
| IC4 | 74123 | 3 | FIRE one-shot |
| IC8, IC13 | 74123 | 2 | EXP / HIT + REBOUND one-shots |
| IC9, IC10 | 4066B | 1, 2 | ACC0-3 and HIT DIS0-2 resistor-select switches |
| IC11 | 7438 | 3 | open-collector NAND alarm tone gating |
| IC12 | LM324 | 2, 3 | noise shaping, REBOUND stages |
| IC14 | 555 | 1 | SHIP engine astable |
| IC15 A/B | dual 555 | 3, 2 | alarm clock (A) / REBOUND tone burst (B) |
| IC16 | 74LS393 | 3 | alarm tone divider |
| IC17, IC20-IC22, IC25, IC26, IC29 | LM324 / MB3614 | all | filters, envelopes, buffers |
| IC18, IC19, IC24 | MB4391 | 3, 2, 1+2 | VCAs (FIRE / REBOUND, EXP, SHIP + HIT) |
| IC28 | LM324 | 1, 2 | **master summing amp** + HIT mix |
| IC33 | **MM5837** | 3 | noise source |
| LA4460 | Sanyo power amp | 1 | speaker output |
| VR1 | 20 K pot | 1 | master volume |
| Tr1-Tr5 | 2SC458 | 1, 2, 3 | envelope-follower / gate stages |
| D1-D11 | MA150 | all | rectifiers in decay networks; D9 is a 12 V zener reference |

---

## Corrections and open questions

**Value corrections** — where the schematic scan and the assembly drawing disagree, the
assembly drawing wins:

- **C19 and C21 are 680 pF ceramic, not 680 µF.** The schematic scan reads as "µf"; the
  assembly drawing says "680p CER", and 680 pF is the only plausible value smoothing an
  MB4391 control node at audio rates. Assume the same for C68.
- The power amp is **LA4460** per the schematic title block, not "LA446" as the manual's
  prose section calls it.
- Transistors are **2SC458**; diodes are **MA150**.

**Previously open, now CLOSED** (traced at high magnification, 2026-07-30):

1. ~~Connector pin → signal-name mapping~~ — resolved; see the pinout table above.
2. ~~74393 tap wiring~~ — resolved; `1CLR`/`2CLR` grounded, `2A ← 1QD`, taps are
   `1QB`/`1QC`/`1QD`/`2QA`. Full tap→alarm mapping table above.
3. ~~R138~~ — resolved; it is a **series** element, and the mixer is passive-summing
   followed by a −0.5 gain stage, not a virtual-ground summer. See above.

4. **C15 is 0.1 µF, not the 0.01 µF the schematic letters.** Taking the schematic
   literally gives a 142.6 kHz alarm clock and tones of 4.46 k / 8.91 k / 17.8 k /
   35.6 kHz — two ultrasonic, one inaudible outright, which no 1982 cabinet shipped.
   At 0.1 µF the clock is 14.26 kHz and the tones are 446 / 891 / 1782 / 3565 Hz.

   Primary evidence, in order of weight:
   - **Assembly drawing (page 20)** — a 0.1 µF part sits immediately beside IC15A. It is
     lettered ambiguously and was previously transcribed here as "C19"; the 5/9 glyphs
     are near-identical in this draftsman's hand. Per the standing rule that the assembly
     drawing wins on values, this is C15.
   - **MAME's own Turbo netlist**, `turbo_a.cpp:648`:
     `DISCRETE_555_ASTABLE(NODE_50,1,470,120,0.1e-6,...)`. Turbo's alarm 555 is the same
     circuit from the same vendor in the same year, with the same 470 Ω Ra and a 0.1 µF
     timing cap. This is reverse-engineered netlist, not a recording.

   Corroborating only (a recording, not a primary source): an FFT of the `buckrog`
   WAV samples gives 470 / 942 / 1885 / 3770 Hz, implying a 15.07 kHz clock — 5.7 % above
   the 14.26 kHz nominal, comfortably inside 555 + electrolytic tolerance. **Model the
   nominal 14.26 kHz**, and treat the clock rate as the one tuning knob if it sounds off.

## Reference recording of a real cabinet

`docs/reference/buckrog_cabinet_recording.mp4` — 35.3 s of a **real Buck Rogers cabinet**,
capturing SHIP, FIRE and a crash. Extract the audio with:

```
ffmpeg -y -i docs/reference/buckrog_cabinet_recording.mp4 -vn -ac 1 -ar 48000        -c:a pcm_s16le docs/reference/buckrog_cabinet_audio.wav
```

(The WAV is gitignored — it is derived, and 3.4 MB.)

**Status: corroborating evidence, not primary.** It is a phone/camera capture of a cabinet
in a room: lossy-compressed, almost certainly AGC'd, and coloured by room acoustics and the
mic. It cannot override the schematic. But it is *far* better evidence than MAME's
hand-made WAVs, because it is the real board through the real LA4460 and the real speaker —
which is exactly the part of the chain we do not model yet.

First-pass structure, for whoever picks this up:

| t (s) | what |
|---|---|
| 0.4, 2.46, 11.28 | transients (2.2–3.1× rises) |
| 0.0–2.5 | SHIP drone, low level (med RMS ~480) |
| 2.5–7.0 | SHIP drone, high level (med ~1300) |
| 7.0–11.2 | back to low (~420) |
| 11.5–34.0 | sustained high (~1300) |
| 34.0+ | drops (~690) |

The stepped drone levels are the engine responding to **ACC0-3** — a ready-made reference
for SHIP's 4066 pitch/level network.

Already corroborated: FIRE is audibly a **quiet, thin, metallic** laser, which is what the
schematic independently predicts (its attenuator × output gain is 0.218 against HIT's
1.582 — see the level analysis in `audio-rtl-design.md`).

**On the MAME samples as a comparison target** — they are a recording of one board and
are not authoritative. Concretely, `alarm1.wav` (1885 Hz) and `alarm2.wav` (942 Hz) are
**swapped** relative to what the schematic wires: ALARM1 is gated by 1QD (÷16 = 891 Hz)
and ALARM2 by 1QC (÷8 = 1782 Hz). MAME's own comments betray the same confusion —
`turbo_a.cpp:522,525` label sample indices 2 and 3 as "/ALARM3" and "/ALARM4". Follow the
schematic; use the WAVs for timbre and rough level only, never for signal assignment.

---

## Turbo

Turbo's sound board has not been traced yet. `docs/reference/Turbo_Schematics.pdf` is on
hand; find its sound sheets the same way (the manual's "List of Illustrations" gives
printed page numbers — determine the printed-to-PDF offset from any one known page).

Turbo used a 4-speaker cockpit (front L/R, centre, rear); `turbo_a.cpp` documents the
analog mixer bus names it fed (F.OUT / W.OUT / R.OUT / L.OUT / M.OUT). The upright
cabinet had two speakers (upper/lower), which is the simpler default.

The compiled-out `turbo_discrete` netlist in `turbo_a.cpp` is a genuine
reverse-engineering of Turbo's alarm circuit and is almost entirely digital — 555
astable → cascaded 74393 counters → four 74123 one-shots retriggered by TRIG1-4 → NAND4
→ op-amp buffer feeding Mono/Front/Rear/Left. Useful as a starting structure, but verify
against the schematic; it never ran in a shipped MAME build.
