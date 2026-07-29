# Buck Rogers (Z80-3D) Sprite-Scale VCO — Schematic Findings

Source: `docs/reference/Buck_Schematics.pdf` (scanned, no text layer), rendered with
`tools/render_sheets.py`. All page numbers below are **PDF page numbers** (see the
script's docstring for the printed-page offset). Cropped reference PNGs referenced
below were written to the scratchpad (outside the repo, per instructions) at:

`C:\Users\matt\AppData\Local\Temp\claude\C--MiSTerDev-Arcade-Z80-3D-MiSTer\b9ea1824-e4d1-49b0-9f37-1c27a6d5f707\scratchpad\`

The VCO circuitry is **not** on the CPU board (834-5120, pages 29-34, checked and
ruled out — that board only has the background/bitmap DAC and tilemap logic). It is
entirely on the **EPROM board (834-5121)**:

- **Sheet 1 of 10** (PDF page 35) — the DAC, control-voltage network, and the 8 VCO
  sections themselves.
- **Sheets 3-10 of 10** (PDF pages 37-44) — one sheet per "sprite level" (0-7), each
  containing that level's ROM address counter, ROM, and nibble-select mux, fed by
  `CLKn`/`CWEn` from sheet 1.

Overview crops: `01_eprom_sheet1_overview_p35.png`, `05_eprom_sheet3_level0_overview_p37.png`.

---

## 1. VCO part number, quantity, and independent oscillator count

**Finding: SN74LS626, four packages, 8 independent oscillator sections. This confirms
MAME's assumption of 8 independent oscillators.**

Sheet 1 (PDF p.35), zone D3, is labeled **"LS626 x4"** directly above a stack of 8
identical VCO blocks, instantiated as **IC18, IC18, IC19, IC19, IC20, IC20, IC21,
IC21** — i.e. 4 physical chips, each used twice. Each block has its own `CEXT`
(2 pins + a cap), `FREQ CON` input, active-low `EN` input, and a `CLKn` output, and
the 4 chips produce outputs `CLK0`...`CLK7` and `EN`/enable nets `CWE0`...`CWE7`.
`SN74LS626` is a real TI part (confirmed via web search): a 16-pin dual
voltage-controlled-oscillator, part of the same improved-linearity VCO family as the
`SN74LS624/625/627/628/629` that TI's own datasheet references (the family MAME's
code comment "figure 6 of datasheet" points at) — commonly used on arcade PCBs.
Every pin count and the "dual VCO per package" structure is fully consistent with
that family's 16-pin DIP pinout.

- Confidence: **high**. The chip designator, "x4" quantity note, and 8 distinct
  `CLKn`/`CWEn` output pairs are all directly legible.
- Evidence: `02_vco_array_LS626x4_Cext220pF_p35.png`, `07_vco_array_remaining_220pF_p35.png`
  (PDF p.35, zone C-D, columns 1-3).

---

## 2. External timing capacitor (Cext)

**Finding: 220 pF on every one of the 8 VCO sections. Exactly matches MAME's 220 pF
assumption for Buck Rogers.**

Every VCO section has its own dedicated `Cext` capacitor tied across its two `CEXT`
pins, and all 8 are silkscreened **"220P"**: `C25` (CLK0), `C13` (CLK1), `C26`
(CLK2), `C27` (CLK3), `C28` (CLK4), `C31` (CLK5), `C29` (CLK6), `C30` (CLK7).

- Confidence: **high**. All 8 values are individually legible and identical.
- Evidence: `02_vco_array_LS626x4_Cext220pF_p35.png`, `07_vco_array_remaining_220pF_p35.png`.

---

## 3. Control-voltage network (DAC → VCO FREQ CON)

**Finding: the topology and every resistor value in MAME's formula are directly
traceable in the schematic, including VR1=1200Ω and VR2=820Ω as fixed resistors (not
trimpots) on Buck Rogers. This is a single time-multiplexed DAC + 8-channel analog
sample-and-hold, not 8 independent DACs.**

### DAC and current-to-voltage stage (sheet 1, PDF p.35, zone D7-D4)

- **IC16**, silkscreened **"MPC624 OR DAC08"** — an 8-bit **current-output** DAC
  (industry-standard DAC-08/DAC0B pinout: `LSB`...`MSB` digital inputs, `V+`, `V-`,
  `REF+`, `REF-`, `COM`, and two `IOUT` current-output pins). It is **not**
  voltage-output.
  - Digital inputs are **HR0-HR7**, an 8-bit bus arriving over connector CN3 from
    the CPU board (traced back to a register on CPU board sheet 3, PDF p.31/33 —
    a hardware sprite-scale value computed by the CPU-board ALU/PROM logic, one
    value at a time).
- `IOUT` (pin 2) feeds through **R8 (1K)** into the inverting-input summing node of
  op-amp **IC1 (µPC159)**, with **R2 (2.2K)** + C1 (100 pF, compensation) as the
  feedback element — a current-to-voltage (transimpedance) converter. **R2 = 2.2K is
  exactly the "2.2e3" coefficient in MAME's `vco_cv = 2.2e3*iout + vref`.**
- The DAC's `REF+`/op-amp non-inverting bias network is a resistor bridge:
  `+5V → R5(1.2K) → node → {R6(820Ω) → REF+ pin 14 of DAC; R4(3.9K) → pin 3 of IC1}`,
  with **R3 (1K)** from IC1 pin 3 to ground and R7 (1.5K) in series with R6 up to
  REF+. **R7=1.5K and R3=1K are exactly the "1.5e3" and "1e3" terms in MAME's
  `iref`/`vref` formulas.** R6=820Ω and R5=1.2K are exactly MAME's **VR2=820, VR1=1200**
  for Buck Rogers. R4 is silkscreened **3.9K**, vs. MAME's hard-coded `3.8e3` — a
  small (~2.6%) discrepancy worth flagging (see below).
- **Both R5 (1.2K, "VR1") and R6 (820Ω, "VR2") are drawn as fixed resistors (plain
  zig-zag symbol, no wiper arrow) — confirming MAME's own comment that these are
  variable resistors on Turbo but fixed on other boards, Buck Rogers included.**

### Sample-and-hold demux (sheet 1, PDF p.35, zone A-D, columns 1-6)

The single op-amp output (the "current" scale voltage for whichever sprite level's
`HR` value is on the bus at that instant) is **not** wired to all 8 VCOs in parallel.
Instead:

- `H2`, `H3`, `H4` (3 bits of the horizontal counter) are decoded by **LS137 (IC7)**
  into 8 select lines `Y0`-`Y7`, buffered by **IC5 "TTL TO MOS DRIVER SN75365 x2"**
  into `ASW0`-`ASW7`.
- `ASW0`-`ASW7` drive two **MC14066B** quad bilateral switches (**IC3, IC4/IC6** on
  the schematic), which gate the op-amp's output onto one of 8 hold capacitors
  (100 pF each) — one per sprite level.
- Each hold capacitor is buffered by one section of a **TL084 ("BI-FET OP AMP")**
  quad op-amp (**IC2** for levels 0-3, **IC17** for levels 4-7), and the buffered
  voltage passes through a **560Ω resistor array (RA-1/RA-2)** into that VCO
  section's `FREQ CON` pin.

In other words, this is a genuine **time-division-multiplexed sample-and-hold DAC**:
the CPU board writes a fresh `HR` value while `H2-H4` selects which of the 8
per-level hold capacitors is currently being refreshed, giving each of the 8 VCOs
its own continuously-held analog control voltage between refreshes. Functionally
this still yields 8 independent per-level control voltages/oscillators (consistent
with MAME's 8-oscillator model and per-sprite `dacinput` parameter), but the
*mechanism* is a shared multiplexed DAC + hold caps, not 8 discrete DAC08 chips.

- Confidence: **high** on the DAC part, current-output nature, R2/R5/R6/R7/R3
  values and their correspondence to MAME's formula constants, and the
  fixed-resistor (non-trimpot) nature of VR1/VR2 on Buck Rogers.
  **Medium** on the exact multiplex/sample-hold sequencing (i.e., exactly how often
  each level's capacitor is refreshed relative to scanlines) — traced the signal
  path but did not fully decode the H2-H4/timing state machine.
- The R4=3.9K vs. MAME's `3.8e3` is a small numeric mismatch — flagged, not resolved;
  could be a rounding choice by the original MAME author (Frank Palazzolo, credited
  in the code comment) or a genuine difference between the Buck Rogers and Turbo
  schematics (Turbo's R4 was not checked in this pass).
- Evidence: `03_dac08_opamp_CVnetwork_p35.png` (DAC + IC1 stage),
  `04_analogmux_sampleHold_p35.png` (MC14066B mux + TL084 buffers).

---

## 4. VCO output routing — direct pixel clock, nibble fetch, no divider found

**Finding: CLKn from the VCO directly clocks the sprite ROM address counter with no
divider stage in between. One VCO edge advances the counter by one step. This is
consistent with MAME's "1 nibble per VCO tick" model.**

On the level-0 sheet (sheet 3 of 10, PDF p.37, zone A-D columns 5-8):

- `CLK0` and `CWEN0` arrive from sheet 1.
- `CLK0` is wired, via a single unbroken net with no intervening flip-flop, straight
  to pin 14 (`CLK`) of **IC96 (74LS191)**, a 4-bit synchronous up/down counter with
  parallel load. IC96's ripple-carry output (`RP`, pin 13) clocks the next stage,
  **IC97 (74LS191)**, whose `RP` clocks **IC98**, whose `RP` clocks **IC99** — a
  cascaded 16-bit up/down counter, parallel-loadable from `AL0`-`AL15` (the sprite's
  starting ROM address, loaded from connector CN2).
- The counter's outputs (`CW0`-`CW13`) directly drive the address pins `A0`-`A13` of
  the sprite ROMs (**IC100/IC101, 27128 16Kx8 EPROMs**). Each ROM byte (`PD0`-`PD7`)
  is latched (**IC102, 74LS273**) and split into two 4-bit halves by a **74LS157**
  2:1 mux (**IC103**) whose shared select line picks the low or high nibble,
  producing the 4-bit-per-pixel outputs **CDA/CDB/CDC/CDD** that feed the sprite
  color-plane logic on sheet 2 (PDF p.36).
- Since the counter's own low-order bit changes on every single `CLK0` edge (it's
  the LSB of a plain binary up/down counter with no separate divider flip-flop
  between the VCO and the clock pin), each VCO edge advances the address/nibble
  state by one step. This matches the MiSTer core / MAME model of "offset counter
  increments by 1 nibble per VCO tick" — **no evidence of a hardware /2 or /4
  divider between the VCO output and the pixel-fetch counter.**

- Confidence: **high** on "no divider between VCO output and the counter clock
  input" (directly traceable, single unbroken wire with a junction dot). **Medium**
  on the precise nibble-select bit assignment inside the LS157 mux (which counter
  bit, or which derived net, drives the mux's `S` select was not fully resolved —
  there is a `CW15`-labeled net near the counters that may be the up/down direction
  control common to all 4 stages rather than a counter output, and an `IC23`
  LS86 XOR gate feeds the mux select from a signal that wasn't fully traced back to
  its source in this pass).
- Evidence: `06_counter_directClocked_gating_p37.png`, `05_eprom_sheet3_level0_overview_p37.png`.

---

## 5. Free-running vs. gated/reset

**Finding: partially resolved. The VCO's own output/window pin is combined on each
level sheet with HP0, the 5M system clock, and BLANK through two JK flip-flops to
produce local gating signals — indicating some form of per-scanline or
per-sprite-window qualification of the clock train reaching the counter. Could not
fully confirm the exact reset/enable semantics.**

Sheet 1's `CWE0`-`CWE7` outputs (from pin 4 of each VCO section, adjacent to that
section's active-low `EN` pin) are distributed to every level sheet as `CWENn`.
On the level-0 sheet, two **74LS109** JK flip-flops (**IC35** x2) take `CWEN0`,
`CLK0`, `HP0` (horizontal position bit 0, from CPU board via CN3), `5M` (5 MHz
system clock), and `BLANK`, and produce two further "CWEN" signals used locally,
plus a feedback path involving a signal labeled `END` (likely a counter
terminal-count / end-of-sprite-data condition, possibly derived from one of the
LS191 counters' ripple-carry/terminal-count output, but this was not conclusively
traced to its source).

This circuit clearly exists to qualify *when* the counter is allowed to run/load —
which is the hardware's equivalent of "only draw sprite pixels during the active
window" — but whether the VCO *oscillator itself* free-runs continuously (with only
its output gated downstream) or is actually reset/held could not be established with
confidence from the legible portions of the schematic.

- Confidence: **low-medium**. The existence of a gating/qualification network per
  level, tied to HP0/BLANK/5M, is clear; its exact effect on phase (equivalent or
  not to MAME's per-scanline `frac=0` reset) is **not** confirmed. This should be
  treated as an open question rather than a settled answer — recommend not changing
  the core's per-scanline reset behavior based on this alone.
- Evidence: `06_counter_directClocked_gating_p37.png` (top portion, the two LS109
  flip-flops and their HP0/5M/BLANK/END inputs).

---

## 6. VCO datasheet characteristic vs. MAME's fitted curve

**Could not verify numerically — no internet datasheet PDF was fetched/read in this
pass (only web-search snippets, which did not surface the actual frequency-vs-Cext-
vs-Vcontrol graph or table).**

What can be said with confidence:

- The chip family is confirmed as TI's SN74LS624/625/626/627/628/629 "improved
  voltage-to-frequency linearity" VCO family, and TI's own product documentation
  explicitly references a "Figure 6" for choosing Cext/frequency — the **same
  "figure 6 of datasheet" that MAME's `sprite_xscale()` comment cites**. This is
  strong circumstantial confirmation that MAME's fit is based on the correct
  chip family's actual published curve, not a fabrication, even though it's
  admittedly a piecewise/log-fit approximation of that curve rather than an exact
  transcription.
- Qualitatively, the LS624-family datasheet's frequency-vs-control-voltage curve is
  known (from the general shape TI's family exhibits and from MAME's own three-piece
  fit) to be markedly non-linear near the 0V and 5V rails and roughly linear in the
  middle — which is exactly the shape MAME's piecewise fit (linear-ish 1.33-4.3V,
  power-law tails) is trying to approximate for the `cext < 1e-11` (50 pF reference)
  branch. For the actual 220 pF branch used by Buck Rogers, MAME instead uses a
  wholly different empirical log-quadratic fit (`-0.9892942*log10(cext) - ...`)
  which was not independently checked against a real datasheet curve in this pass.
- **Could not confirm or refute the specific numeric claim** ("~2.59 MHz at V=5.0V,
  220pF") against actual SN74LS626 datasheet data — this would require pulling the
  actual TI datasheet PDF (not just search snippets) and reading Figure 3/6
  numerically, which was out of scope for a schematic-reading pass and is flagged
  here as a follow-up if closer VCO-curve accuracy is wanted.

- Confidence: **low** on the numeric match; **medium-high** on "MAME's fit is based
  on the correct chip family's datasheet, referencing the same Figure 6."

---

## Summary of confidence levels

| # | Question | Confidence | One-line answer |
|---|----------|------------|------------------|
| 1 | VCO part / count | High | SN74LS626 x4 packages, 8 sections — confirms MAME's 8 oscillators |
| 2 | Cext value | High | 220 pF on all 8 sections — matches MAME |
| 3 | CV network / VR1,VR2 / DAC type | High (topology & values); Medium (mux timing) | DAC08/MPC624 current-output DAC; R5=1.2K, R6=820Ω are fixed resistors matching MAME's VR1/VR2; time-multiplexed sample-and-hold, not 8 discrete DACs |
| 4 | VCO output → pixel/ROM counter, divider? | High (no divider found); Medium (nibble-select bit) | CLKn directly clocks the 16-bit ROM address counter, no divider stage found |
| 5 | Free-running vs. gated | Low-Medium | A gating network (HP0/5M/BLANK/END via 2 JK flops) exists per level; exact reset semantics unresolved |
| 6 | Datasheet curve match | Low (numeric); Medium-High (chip family/figure match) | Correct chip family confirmed (TI Figure 6 reference matches MAME's comment); no datasheet PDF pulled to check numbers |

## Recommendation

Items 1-4 give solid schematic-backed support for keeping MAME's/the core's current
model largely as-is: 8 independent oscillators, 220 pF Cext, the CV-network formula
(including VR1=1200/VR2=820 as fixed resistors), and one-nibble-per-VCO-tick with no
divider. The R4=3.9K-vs-3.8K discrepancy (item 3) and the gating/reset semantics
(item 5) are the two loose threads worth chasing further if greater accuracy is
wanted — neither is resolved cleanly enough here to justify a code change.

---

## SESSION 2 CHECKPOINT NOTE

This session picked up Task A (nibble-select XOR) and Task B (LS109 gating / `END`
source) on the level-0 sheet (PDF p.37). It was cut short by a session-limit
checkpoint request **before Task A's second XOR input (IC23 pin 12) could be traced
to its source, before any cross-check of a second level sheet, and before Task B's
LS109/resync questions (1, 2, 4) could be re-examined.** Everything below is
genuinely partial. Two things ARE nailed down with high confidence and are the
highest-value results of this session — see the headline answers immediately below,
then the detailed per-item writeups, then an explicit UNRESOLVED list with exact
next-step crop coordinates so a future session does not have to re-derive the
approach.

**Headline answer, Task A Q3 (does the nibble on CDA-CDD depend on count
direction?):** **Partially yes, confidence medium.** The LS157 nibble-select mux's
`S` pin is driven by an LS86 XOR (IC23), and one of that XOR's two inputs (pin 13)
is directly and unambiguously wired to net `CW15` — which is itself the counter
chain's own top-bit output fed back as the shared up/down **direction control**
input to the LS191 counter stages. So direction *does* feed into the nibble-select
logic. But the XOR's *other* input (pin 12) was not resolved this session, so the
net boolean relationship (whether direction alone flips nibble order, or only in
some combination) is not yet provable. This is close to confirming the hypothesized
bug but is not proven yet.

**Headline answer, Task B Q3 (is `END` a counter terminal-count or derived from
DATA?):** **Derived from DATA. Confidence high.** `END` is the output of IC39, a
74LS20 dual 4-input NAND, whose four inputs are `CDA`/`CDB`/`CDC`/`CDD` (pins
10/9/13/12) — i.e. the same 4-bit nibble that comes out of the LS157 mux. A 4-input
NAND's output goes low only when all four inputs are high, so `END` (drawn with an
active-low bar) asserts exactly when `CDA=CDB=CDC=CDD=1`, i.e. **pixdata == 0xF
(15)**. This is an exact structural match to MAME's `plb_end[pixdata] & 2` /
`pixdata == 15` model. `END` is **not** a counter ripple-carry/terminal-count signal
— MAME's sprite-termination model is schematic-confirmed correct on this point.

---

## 7. Task A — the LS157 nibble-select XOR (IC23)

### 7.1 LS157 (IC103) nibble mapping — confirmed, high confidence

Traced directly from the ROM data latch (**IC102, 74LS273**) to the mux
(**IC103, 74LS157**):

- Latch inputs `PD0-PD7` (from the two ROMs' data bus) → latch outputs `1Q-8Q`.
- `1Q,2Q,3Q,4Q` (i.e. `PD0-PD3`, the ROM byte's **low nibble**) → LS157 `1A,2A,3A,4A`
  (the "A" input group).
- `5Q,6Q,7Q,8Q` (i.e. `PD4-PD7`, the ROM byte's **high nibble**) → LS157
  `1B,2B,3B,4B` (the "B" input group).
- LS157 outputs `1Y-4Y` (pins 4,7,9,12) = `CDA,CDB,CDC,CDD`, straight out to sheet 2.
- LS157 `G̅` (output-enable, pin 15) is tied to ground (always enabled) — not used as
  a gating signal.
- Standard 74LS157 behavior: `S=L` selects the A group (low nibble), `S=H` selects
  the B group (high nibble).

Evidence: `08_ls86_ls157_mux_p37.png`
(`python tools/render_sheets.py buck 37 --scale 1400 --crop 0.55,0.42,0.85,0.62`).

### 7.2 LS157 select source — confirmed, high confidence

`S` (pin 1 of IC103) is wired, via a single unbroken drawn trace with no
intervening logic, directly to **pin 11 of IC23, a 74LS86 XOR gate**. Nothing else
drives `S`. Confirmed both in the overview and in a tight crop.

Evidence: `09_ls86_select_p37.png`
(`python tools/render_sheets.py buck 37 --scale 1400 --crop 0.55,0.58,0.85,0.72`).

### 7.3 IC23 XOR input #1 (pin 13) = net `CW15` = counter's own MSB, fed back as
### the shared up/down direction control — confirmed, high confidence

Traced pin 13 of IC23 backward along a single continuous drawn wire (no junctions,
no other taps along the way) all the way to **pin 7 (`QD`) of IC99**, the topmost
(MSB) stage of the cascaded 74LS191 x4 counter chain (IC96→IC97→IC98→IC99). `QD` of
IC99 is bit 15 of the 16-bit counter (`CW15`).

Critically, within IC99's own schematic symbol, that same `CW15` net is *also*
shown wired to **pin 5 (`Ū/D`, the up/down direction-select input)** of IC99 itself
— i.e. the counter's own top output bit is fed back as its own direction control.
The original overview transcription (session 1, this session's re-read) shows the
identical `"5 CW15"` label under the `Ū/D` pin of **all four** stages (IC96, IC97,
IC98, IC99), meaning `CW15` is broadcast as the **shared direction-control input for
the entire 16-bit cascade**, not just IC99. (IC99's `pin5→pin7` local tie and the
unbroken wire to IC23 pin 13 were both re-verified this session at high resolution;
the IC96-98 `Ū/D` labels were read at overview scale only, not re-zoomed this
session — see confidence note below.)

**This means the counter is a self-reflecting (mirroring) counter**: once its own
MSB goes high, the chain's direction flips on its own, with no CPU-driven "count
down" mode needed — a ping-pong 0→32767→0 address sweep purely from feedback wiring.

- Confidence: **high** on "IC23 pin 13 = CW15, unbroken traced wire to IC99
  QD/pin7, which is also tied to IC99's own U/D/pin5" (re-verified this session at
  1600-DPI crop). **Medium-high** on "the same CW15 net also drives IC96/97/98's
  U/D pins" (read clearly at overview scale in session 1 and re-read this session,
  but not independently re-zoomed on each of those three chips this session).
- Evidence: `10_ic23_inputs_p37.png`
  (`--scale 1400 --crop 0.20,0.52,0.62,0.68`),
  `12_ic99_wire_tight_p37.png` (`--scale 1600 --crop 0.30,0.60,0.55,0.66`),
  `13_ic99_both_wires_p37.png` (`--scale 1600 --crop 0.10,0.58,0.55,0.68`) — this
  last one is the cleanest single image showing IC99's QD(7)/Ū-D(5) local tie and
  the unbroken wire to IC23 pin 13 in one frame.

### 7.4 IC23 XOR input #2 (pin 12) — UNRESOLVED

A vertical wire leaves IC23 pin 12 and runs upward, off the top of every crop tried
this session. In the widest crop obtained (`14_ic23_pin12_search_p37.png`), that
vertical wire appears to pass near — and possibly join, via a junction dot — the
same horizontal net labeled plain `CLK` that clocks pin 11 (`CLK`) of the ROM-data
latch **IC102 (74LS273)**. This is **not conclusively established**: the junction
dot's exact ownership (does the vertical wire actually tap that horizontal `CLK`
line, or does it merely cross over/near it without connecting?) could not be
resolved at the crop scales tried, and the wire continues further upward past the
crop's top edge toward the ROM `C̅E̅`/`O̅E̅` region, which was not captured.
**Do not treat "pin 12 = CLK" as established — it is a visual proximity, not a
confirmed connection.**

This is the single most important loose end from this session, because it directly
blocks Task A Q3's final answer.

- Confidence: **low** (unresolved).
- Evidence attempted: `14_ic23_pin12_search_p37.png`
  (`--scale 1600 --crop 0.48,0.40,0.65,0.66`).
- **NEXT STEP**: render page 37 with `--scale 1600 --crop 0.45,0.25,0.65,0.45` (the
  region directly above image 14's crop) to follow the pin-12 wire further up and
  read what it terminates at. Separately, crop tightly around IC102 pin 11's `CLK`
  label source (trace backward from the latch) with something like
  `--scale 1600 --crop 0.30,0.30,0.60,0.55` to determine whether that local `CLK`
  net is literally `CW0` (the counter's true LSB, renamed locally) or the raw
  `CLK0`/VCO signal, or something else. Resolving that will very likely also answer
  what feeds IC23 pin 12, since the wires appear to run through the same area.

### 7.5 Address-bit split (offset bit 0 = nibble, bits 1-15 = byte address)
### — CONTRADICTION FLAGGED, not resolved

The original session-1 overview transcription (re-read this session, not
re-verified with a fresh tight crop) reads the ROM address pins as:
`CW0→A0, CW1→A1, CW2→A2, ... CW13→A13` on **ROM0 (IC100)**, i.e. the counter's
**true LSB (`CW0`) is wired directly to ROM address bit A0** — it is a real address
bit, not reserved as a separate nibble-select tap.

This is a direct tension with the finding that nibble-select is generated by a
*separate* piece of logic (the IC23 XOR feeding the LS157 `S` pin) rather than by
tapping `CW0` (or any single low-order counter bit) straight into the mux select.
If `CW0` genuinely increments the ROM byte address on every VCO tick (not every
other tick), then either (a) this hardware fetches a new byte every tick and
something else must be discarding half of each byte's data on alternating ticks in
a way not yet identified, or (b) the "CLK" net feeding the IC102 latch (see 7.4) is
not simply `CLK0` but is itself derived from `CW0` in a way that makes the latch
(and therefore the visible ROM data) update only every other counter tick, which
would reconcile everything — but this was **not verified** this session.

**This item is flagged as an open contradiction, not resolved. Do not assume either
resolution is correct.**

- Confidence: **low** (unresolved contradiction).
- **NEXT STEP**: fresh tight crop of IC96 (the LSB stage) — its `CLK` (pin 14) and
  `QA`/pin 3 (`CW0`) — and independently re-verify the ROM0 address-pin labels
  (`--scale 1600`, crop around the ROM0 IC100 body and IC96, e.g.
  `--crop 0.30,0.20,0.55,0.45`) to settle whether `CW0` really lands on ROM `A0`
  the same tick it's produced, or whether there's a one-tick latch delay that
  reconciles this with the nibble-select architecture.

### 7.6 Cross-check on another level sheet — NOT DONE

No other level sheet (PDF p.38-44) was examined this session; only level 0 (p.37).

- **NEXT STEP**: render page 38 (level 1) overview first
  (`python tools/render_sheets.py buck 38 --scale 500`) to find the equivalent IC
  designators (they will differ from IC96-103/IC23/IC38/IC39 — read the new
  numbers off the overview first), then repeat the same tight crops used in 7.1-7.4
  above at the equivalent screen positions to confirm the wiring pattern is
  identical per level.

---

## 8. Task B — LS109 gating network and `END` source

### 8.1 `END` is derived from the DATA pattern (CDA-CDD), not a counter
### terminal-count — confirmed, high confidence

Directly adjacent to the LS157 nibble mux (same crop as 7.1/7.2), two 4-input gates
tap the mux's **output** (`CDA/CDB/CDC/CDD` — pins 10, 9, 13, 12 on both gates),
*after* nibble selection has already happened:

- **IC38, a 74LS25** (dual 4-input NOR with strobe) → output pin 8, feeding
  `P̅L̅B̅0̅` to sheet 2. (Its strobe/enable pins were visible but not traced this
  session; the exact boolean beyond "4-input NOR-family gate on CDA-CDD" is
  unconfirmed.)
- **IC39, a 74LS20** (dual 4-input NAND, no strobe pin, straightforward) → output
  pin 8, labeled with an overbar as `END`. A 4-input NAND's output is low only when
  **all four inputs are high**, i.e. `END` (active-low) asserts exactly when
  `CDA=CDB=CDC=CDD=1` → **pixdata == 0xF (15)**.

This is a clean structural match, gate-for-gate, with MAME's
`plb_end[pixdata] & 2` end-of-sprite-row detection (which for Buck Rogers reduces
to `pixdata == 15`) and its `plb_end[pixdata] & 1` transparency detection (`pixdata
== 0`, plausibly what IC38/`PLB0` implements, though this specific mapping — NOR
vs. NAND-of-complements etc. — was not independently verified against MAME's
`plb_end[]` table values this session).

**`END` is unambiguously downstream of the DATA nibble, not of any counter's
ripple-carry/terminal-count pin.** No wire from any LS191's `RP` (ripple-carry
output, pins 13 of IC96/97/98) was found feeding IC38 or IC39 — their only inputs
are the 4 `CD` data lines.

- Confidence: **high** for IC39/`END` (simple gate, clean 4-input NAND behavior,
  directly legible pin labels and connections). **Medium** for IC38/`PLB0`'s exact
  boolean function (gate type and inputs are certain; the LS25's strobe pins and
  the precise correspondence to a specific `pixdata` value were not traced).
- Evidence: `09_ls86_select_p37.png` (same crop as 7.1/7.2 — shows IC38, IC39,
  their CDA-CDD inputs, and the END/PLB0 outputs in one frame).

### 8.2 LS109 resync network (IC35 x2) — NOT RE-EXAMINED this session

Task B items 1 (does CLK0 clock the counter directly or through an LS109 resync
stage first?), 2 (5M vs. an HP0-qualified 2x-rate edge?), and 4 (does anything reset
the VCO's phase, or is it free-running?) were **not revisited** this session beyond
re-reading the same overview image already described in section 5 (session 1) of
this document. That section's low-medium-confidence finding — a gating/qualification
network involving `CWEN0`, `CLK0`, `HP0`, `5M`, `BLANK`, and a feedback signal
labeled `END` (now confirmed in 8.1 to be the data-pattern `pixdata==15` signal,
which strengthens the case that this network is about *qualifying/terminating* the
sprite fetch window rather than dividing/resyncing the VCO clock itself, but this
inference was **not verified** by a fresh trace this session) — should be treated as
still standing, neither confirmed nor refuted further.

- Confidence: unchanged from session 1 (**low-medium**), with one new supporting
  data point (8.1's confirmation of what `END` actually is) that was not yet used
  to re-interpret the LS109 network.
- **NEXT STEP**: tight crop of the top-left of page 37,
  `--scale 1600 --crop 0.18,0.10,0.45,0.30`, covering both IC35 (74LS109) packages
  and their `CWEN0`/`CLK0`/`HP0`/`5M`/`BLANK`/`END` connections. Specifically look
  for: (a) whether `CLK0`'s trace to IC96 pin 14 (`CLK`) passes through or merely
  runs alongside the LS109s (session 1 called this "a single unbroken net with no
  intervening flip-flop" at high confidence — re-verify this claim explicitly
  against the new crop rather than assuming it still holds); (b) which of `5M` or
  an `HP0`-qualified signal actually clocks each LS109's `CLK` pin (read the pin-13
  and pin-3/4 connections precisely); (c) confirm the now-identified `END` signal
  (8.1) is the same net feeding the second LS109's `K`/pin-12 input, closing the
  loop between "this level's sprite data just hit pixdata==15" and the `CWEN`
  outputs (pins 9, 10) that gate the counter/latch chain.

---

## Session 2 summary of confidence levels

| # | Question | Confidence | One-line answer |
|---|----------|------------|------------------|
| Task A Q1 | Is one XOR input the counter LSB? | Resolved differently: it's the counter **MSB** (`CW15`), not the LSB | High |
| Task A Q2 | What is the other XOR input? | **Unresolved** — pin 12 traced only partway, ambiguous proximity to a `CLK` net | Low |
| Task A Q3 | Does nibble depend on count direction? | **Partially yes** — direction (`CW15`) is one confirmed XOR input; full boolean unresolved pending pin 12 | Medium |
| Task A Q4 | Is counter LSB (`CW0`) kept off the ROM address? | **Contradicted** by overview reading (`CW0→A0` direct) — flagged, not resolved | Low |
| Task A Q5 | Cross-check another level sheet | **Not done** this session | — |
| Task B Q1 | CLK0 direct or through LS109 resync? | Not re-examined this session; session-1 finding stands unverified | Low-Medium (carried over) |
| Task B Q2 | 5M or HP0-qualified (2x) edge sampling? | Not re-examined this session | Unresolved |
| Task B Q3 | Is `END` data-derived or counter terminal-count? | **Data-derived, confirmed**: IC39 (74LS20 NAND) on CDA-CDD, asserts at pixdata==15 | **High** |
| Task B Q4 | Does anything reset VCO phase? | Not re-examined this session | Unresolved (carried over, low-medium) |

## Recommendation (session 2 addendum)

The single highest-confidence new result is **8.1: `END` is confirmed
schematic-side to be derived from the sprite data nibble (`pixdata == 15`), exactly
matching MAME's model.** This is a clean negative for that part of the
sprite-termination hypothesis — no RTL change indicated there.

Task A remains genuinely open. The confirmed fact that the LS157 nibble-select XOR
has the counter chain's own direction-feedback bit (`CW15`) as one input is
suggestive but not sufficient on its own to conclude MAME/the RTL has a nibble-order
bug — the second XOR input (7.4) must be identified first, and the `CW0`-to-ROM-A0
contradiction (7.5) must be reconciled, before recommending any code change. Both
are precisely scoped, low-effort next steps (see NEXT STEP notes in 7.4 and 7.5)
that a future session should tackle first, before spending time on Task B's
remaining items (8.2), since Task A is the top priority per the task brief.
