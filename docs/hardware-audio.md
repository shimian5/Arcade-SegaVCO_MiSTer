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

### CPU-side latch bits (from `turbo_a.cpp`, PPI1 at `d000-d003`)

**Port A** — bits 0-2 hit distance; bit 4 rising edge strobes hit volume; bit 5 rising
edge strobes `ACC0-3`; bit 6 `/ALARM0` (falling edge); bit 7 `/ALARM1` (falling edge).

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
IC15A 555 astable: R29 470R (Ra), R30 270R (Rb), C15 0.01uF, C17 0.01uF on CTRL
    f = 1.44 / ((Ra + 2*Rb) * C) = 1.44 / (1010 * 1e-8) ~ 142.6 kHz
  -> R66 1K -> IC16 74LS393 pin 1 (1A)
  -> ripple divider, taps QB (pin 4), QC (pin 5), QD (pin 6); 2A (pin 13) tied to 1QD
  -> IC11 74LS38 open-collector NAND x4: each ANDs one tap with one alarm enable,
     all four wire-OR'd onto a node pulled up by R153 1K

alarm enables, one 74123 section each:
    ALARM0  IC3 pin 1  -> Q13   R2  47K / C1 6.8uF   (tau ~ 9 ms)
    ALARM1  IC3 pin 9  -> Q5    R3  47K / C2 6.8uF   (tau ~ 9 ms)
    ALARM2  IC7 pin 1  -> Q13   R14 47K / C5 6.8uF   (tau ~ 9 ms)
    ALARM3  IC7 pin 9  -> Q5    R15 47K / C6 10uF    (tau ~ 13 ms, deliberately longer)

mix: R154 5.1K, C88 4.7uF -> IC29 -> R127 100K -> IC25 (R129 200K fb, ~2x)
     -> C74 2.2uF -> ALARM MIX
```

---

## Master mixer and output (sheet 1)

Six weighted inputs into IC28's inverting summing amp, feedback **R126 = 100 K**:

| Channel | Summing R | Gain (R126/Rch) |
|---|---|---|
| **HIT MIX** | **R136 = 5.1 K** | **≈ 19.6× — about 2× everything else** |
| SHIP MIX | R137 = 10 K | 10× |
| FIRE MIX | R131 = 10 K | 10× |
| EXP MIX | R133 = 10 K | 10× |
| REBOUND MIX | R130 = 10 K | 10× |
| ALARM MIX | R132 = 10 K | 10× |

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

**Still to resolve** (re-render the region at `--scale 800` when the block is being built):

1. **Connector pin → signal-name mapping**, sheet 1 zone D8. Pin numbers were not
   readable across a tile seam. Not blocking — every signal name and destination is
   known, and the CPU-side bit assignments come from `turbo_a.cpp`.
2. **74393 tap wiring**, sheet 3. The second counter section's cascade beyond
   `2A ← 1QD` is ambiguous, so the four alarm tone frequencies are not yet derivable.
   Must be resolved before the ALARM channel can be finished.
3. **R138 (200 K)** at the master summing junction, sheet 1 zone A6 — series element
   into IC28's inverting input, or a second bias source? Affects overall mix calibration.

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
