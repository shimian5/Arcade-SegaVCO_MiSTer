# Title-logo garbling: investigation state

Status as of session end. Branch `worktree-phase0-1a`. **Read the update immediately
below before the rest of this document — it retracts the TL;DR that follows it.**

---

## UPDATE 2026-07-29 (post-reboot): the write-timing suspect is REFUTED. Measured.

The "TL;DR" section below is **wrong** and is kept only so the reasoning is auditable.
Both our RTL and MAME write sprite RAM **in VBLANK, in the same vpos range**. There is
no write-timing discrepancy.

Measured directly, same coin/start schedule on both sides (coin frames 90-99, start
150-159), frame 150:

| Side | writes at frame 150 | vpos range | in active display? |
|---|---|---|---|
| RTL (`sim/out/dbg_rtl_writes.txt`) | 235 events / 130 addrs | **225-253** | none |
| MAME (`tools/mame/dump_sprite_write_trace.lua`) | 160 | **225-253** | none |

VBSTART=224, VTOTAL=264, so 225-253 is entirely VBLANK on both. MAME's whole-run vpos
histogram is concentrated in 224-253 with only a ~140-write one-time burst at vpos 36-65
during the first few boot frames.

**Why the original inference was wrong.** The harness defines "start of frame N" as
`hblank_rise && vpos == VTOTAL-1` (vpos 263) — the *end* of VBLANK. The CPU's writes for
a given frame land at vpos 225-253, i.e. **before** that boundary but after the previous
one. So "all slots disabled at the frame-150 start snapshot, four slots programmed by the
frame-150 end snapshot" is exactly what correct VBLANK-time programming looks like
through this instrument: the logo is simply set up during frame 150's VBLANK and first
displays on frame 151. Nothing was ever written during active display. The engine's
live-per-scanline sprite-RAM read is fine, and MAME's whole-frame rendering is not hiding
anything here.

**Beware of one measurement trap, since it nearly inverted this result.** A first pass at
the MAME side discarded the objects returned by `install_write_tap`. Lua then
garbage-collected them and the taps **silently stopped firing** — no error, the log just
ends. That produced an apparently solid finding that MAME's CPU stops writing sprite RAM
after frame ~13 and writes nothing at frame 150, and an inference that sim and MAME had
diverged in CPU control flow. Both were artifacts. With the taps rooted in `_G`, MAME
writes ~160 times per frame indefinitely. The script now roots them and prints
`last_tap_frame`; **check that line before trusting any trace from it.**

**What this leaves.** The garbling itself is still unexplained, but the open threads are
now the schematic ones (§2/3/4 below) plus one new harness question:

- **Frame-index alignment in the harness (check this first).** The RTL *image* dump for
  "frame 150" shows a rendered logo, yet no sprite slot is enabled during frame 150's
  active display per the snapshot above. Those two cannot both describe the same frame,
  so `tb_z80_3d.cpp`'s frame counter (which selects the image dump) and
  `sprite_engine.v`'s `dbg_cur_frame` (which selects the RAM snapshots) are most likely
  **off by one relative to each other**. Verify before drawing any conclusion from a
  co-sim run, and re-baseline both dumps to a frame where the logo is fully programmed
  (151+), not the transitional frame.
- The co-sim's "18,812 mismatching pixels" result remains vacuous for the reason given
  further below, but the *reason* is now clearer: the golden model was fed a snapshot
  from a moment when the logo genuinely was not yet programmed, so an empty reference was
  the correct output for that input.

---

## TL;DR — RETRACTED, see the update above

**The claim in this section — that the CPU writes sprite RAM during active display — was
measured and is false.** Retained for auditability only.

The sprite engine is probably **not** the bug. The evidence now points at **when the CPU
writes sprite RAM**.

At the start of the visible frame, **all 16 sprite slots are disabled**; by the end of the
same frame, four of them have been programmed. That means the CPU is writing sprite RAM
*during active display* rather than during VBLANK. Our engine consumes sprite RAM live,
per scanline (as the hardware does), so a sprite programmed at scanline N is invisible and
un-accumulated for scanlines 0..N-1 — its ROM row pointer is then wrong for the rest of
the frame. That produces exactly the observed symptom: **correct position, correct size,
scrambled interior.**

MAME does not have this problem because it renders the whole frame in one pass at
`screen_update` time using the end-of-frame sprite RAM. So MAME is *insensitive* to write
timing and we are not. This is a real MAME-vs-hardware modelling difference, and it means
a CPU/interrupt-timing bug can present as a video bug.

---

## Verified raw data (I read these files directly, not via an agent summary)

`sim/out/dbg_sprram.hex`, captured at `hblank_rise` of `vpos == VTOTAL-1` (263), i.e. the
last line of VBLANK, immediately before scanline 0 of frame 150 (title-logo frame):

| slot | y_lo | y_hi | xscale | yscale | rowbytes | offset |
|---|---|---|---|---|---|---|
| 2 | 00 | **ff** | 90 | 01 | 0040 | 1f80 |
| all others | 00 | **ff** | 00 | 00 | 0000 | 0000 |

`sim/out/dbg_sprram_end.hex`, same frame, last HBLANK: slots **7, 8, 9, 13** now hold real
data (e.g. slot 7 = `ff d8 a9 02 29 00 44 5c`). 33 bytes changed, all in bytes 0-5 —
which **only the CPU writes** (the engine only ever writes bytes 6/7).

### Why "y_hi = ff" means every sprite is disabled

MAME's enable ALU (turbo_v.cpp:818-825):

```
sum  = y + rambase[0];          clo = (sum >> 8) & 1;
sum += (y << 8) + (rambase[1] << 8);   chi = (sum >> 16) & 1;
enabled = clo & !chi;
```

With `y_lo = 0x00`: `sum1 = y < 256`, so `clo = 0`, so `enabled = 0` — **always**, on every
scanline, for every slot, for the whole frame. Confirmed independently for `y_hi = 0xff`:
`chi = 0` would require `sum1 + 256y < 256`, which contradicts `clo = 1`.

### Consequence for the co-sim harness

The golden model was fed this snapshot, so **it renders an entirely empty frame**. The
reported "18,812 mismatching pixels / first divergence at y=82" is just *"the RTL drew a
logo and the golden model drew nothing."* It carries **no diagnostic weight**, and the
sub-agent's conclusion that the fault "sits in the real-time get_sprite_bits/he/lst path"
does **not** follow. Likewise its claim that the RTL renders sprite data while `ve == 0` is
an artifact of comparing against an empty reference — do not chase it as stated.

The `step_reg`/`offset_reg` "bit-exact on fresh commits" result is also vacuous: there were
no fresh commits, because nothing was ever enabled.

**The harness is sound in construction; it was fed an unrepresentative input.** See "next
steps" for the fix (drive it from a timestamped write trace, not a snapshot).

---

## The one solid RTL bug found so far

`rtl/video/sprite_engine.v` — `y_target` is declared `[7:0]` but `VTOTAL = 264` needs 9 bits:

```verilog
reg  [7:0] y_target;
wire [7:0] y_target_next = (vpos == VTOTAL-1) ? 8'd0 : (vpos[7:0] + 8'd1);
```

At `vpos == 255` the `vpos[7:0] + 1` wraps to 0, so `prepare_sprites` re-runs for
`y = 0..7` during VBLANK lines 256-262 before the real `vpos == 263` wrap. That is **9
spurious passes per frame**, each of which can perform the `offset += rowbytes` writeback
(`ST_COMMIT`/`ST_COMMIT2`), advancing every enabled sprite's ROM row pointer by up to
9 extra rows per frame.

Real and worth fixing. **But note it is currently latent**, because nothing is enabled
during those lines in the captured frame. Do not assume fixing it fixes the logo.

Open question it raises (needs the schematic, not MAME): does the hardware's
`prepare_sprites` equivalent run during VBLANK at all? MAME only ever calls it for
`y` in the visible cliprect, so MAME cannot answer this. The `BLANK` input to the per-level
LS109 gating network (EPROM board sheet 3, PDF p.37) is the place to look.

---

## Ruled out (do not re-investigate without new evidence)

| Suspect | How it was ruled out |
|---|---|
| Cross-level conflicts, fetch/addressing, Y-scale accumulation, mixer bit-layout | Prior session, bit-exact/line-for-line |
| Horizontal-enable / sprite-position-RAM path | Traced `{hi,lo}` bank split, one-column prefetch, and the hpos 639→0 wrap. `he_*_dout` holds exactly `sprpos[xx_now]` on the correct `ix0` cycle. **Clean.** |
| `prepare_sprites` FSM read pipeline, carry ALU, PR-5196 addressing, offset writeback | Walked state-by-state against turbo_v.cpp:803-857. Every `eng_sprram_addr` issue lands its data in the right state; `rambase[0..7]` all map correctly |
| MUX / priority / palette chain | `find_lsb` ≡ `countl_zero(bitswap<8>(plb,0..7))` with the `mux==8→0xf` clamp; `sprcolor_table` address packing matches turbo_v.cpp:969-992 |
| Accumulator cadence being 2× off | **My early theory, wrong.** MAME calls `get_sprite_bits()` *inside* the `ix` loop (turbo_v.cpp:957-966), so it steps once per 2×-domain output pixel exactly as we do. Threshold `0x800000` is correct for our cadence |
| Hidden ÷2 between VCO and pixel counter | Schematic: `CLKn` reaches the 74LS191 chain on a single unbroken net (EPROM bd sheet 3, PDF p.37) |
| VCO analogue model being a MAME fabrication | Schematic confirms SN74LS626 ×4 = 8 independent oscillators, 220 pF Cext on all 8, and R2=2.2K / R7=1.5K / R3=1K / R5=1.2K("VR1") / R6=820Ω("VR2") exactly as MAME's formula. See `docs/reference/VCO_schematic_findings.md` |

---

## Open threads, in priority order

### 1. CPU write timing — CLOSED, refuted by measurement (see the UPDATE at the top)
Both sides write in VBLANK, vpos 225-253. Do not re-open without new evidence. The
original text of this thread follows, for auditability.

Log the `vpos`/`hpos` of every `cpu_sprram_we` and `cpu_sprpos_we` for one frame. Then do
the same in MAME via a `memory write tap` on the sprite RAM range plus
`screen:vpos()`. Compare.

- If MAME's writes land in VBLANK and ours land in active display → the bug is **CPU or
  interrupt timing**, not video. Suspects: Z80 clock divider, VBLANK IRQ assert/clear
  timing, the `WAIT` synchronisation the theory-of-operation doc mentions (p.70-71 of
  `docs/reference/Buck_theory.txt`), or leftover TV80 clocking issues (cf. commit 529d7ae).
- If MAME *also* writes mid-frame, then MAME's whole-frame rendering is hiding a real
  hardware behaviour, our live-read engine is more correct, and the reference image itself
  is suspect. Say so explicitly and re-baseline.

### 2. Nibble-select XOR (schematic, agent was mid-trace)
The 74LS157 nibble mux (IC103, level-0 sheet PDF p.37) has its select driven via an LS86
XOR (IC23) whose second input was not traced. MAME has **no XOR**: it uses
`>> ((~offs & 1) * 4)` (turbo_v.cpp:890) with no dependence on count direction, and we copy
that. If hardware XORs against the LS191 up/down direction bit, mirrored sprites emit their
two nibbles in the opposite order from MAME — invisible on unmirrored sprites, scrambling
on mirrored ones. Check `docs/reference/VCO_schematic_findings.md` §7 for the agent's
partial result.

### 3. `END` source (schematic)
MAME derives `END` from the *data pattern* (`plb_end[pixdata] & 2`, i.e. `pixdata == 15`,
turbo_v.cpp:867/895). The schematic shows an `END` net feeding the per-level LS109 gating
alongside the LS191 ripple-carry outputs. If `END` is really a counter terminal-count,
MAME's entire sprite-termination model is wrong. See §8.

### 4. VCO → pixel-clock resync (schematic)
`HP0` (2× sub-pixel bit) and `5M` (4.992 MHz native pixel clock) both feed the per-level
LS109 network. If the async VCO edge is resynchronised to `5M`, a sprite source pixel is
always an integer number of *native* pixels wide and can never be an odd number of 2×
sub-pixels — MAME models no resync at all. Directly observable in output if true.

### 5. Cosmetic / latent, fix after the real bug
- `rtl/z80_3d.v:521-632`: the mixer pipeline free-runs on `clk`, not `ce_pix`. Since
  `ce_pix = clk/4`, `SPR_TO_MIX_DELAY=5`, `COORD_DELAY=5` and `VIDEO_PIPE_LATENCY=7` are
  counted in **core clocks, not pixels** — "5 stages" is 1.25 pixels. Depths are mutually
  consistent so it shows as a sub-pixel offset, not garbling, but the comments say pixels
  and will mislead. Either gate the pipeline with `ce_pix` or fix the comments.
- `tools/gen_tables.py`: R4 is silkscreened **3.9K** on the schematic; MAME hardcodes
  `3.8e3` and we inherited it. <1% frequency effect. Fix for correctness, not for this bug.

---

## Harness built this session (works, keep it)

- `rtl/video/sprite_engine.v`, `rtl/z80_3d.v` — `ifdef VERILATOR_SIM` debug dump blocks +
  `dbg_sprbits`/`dbg_plb`/`dbg_hpos`/`dbg_vpos` ports. **Debug-only, engine logic untouched.**
- `sim/tb_z80_3d.cpp` — `--dumpframe N`, writes `sim/out/dbg_rtl_spr.bin` (512×224×5 B).
- `sim/Makefile` — `dump` target (`--frames 152 --dumpframe 150`).
- `sim/golden_buckrog.py` — literal transcription of MAME's buckrog sprite path.
- `sim/compare_spr.py` — diff tool.

**Required fix before the co-sim means anything:** drive `golden_buckrog.py` from a
*timestamped write trace* (`(vpos, addr, data)` for every CPU write to sprite RAM and
sprite-position RAM), replaying each write at the right scanline, instead of from a single
start-of-frame snapshot. Only then does it model what the engine actually consumes.

**Structural caveat, permanent:** the co-sim compares our RTL against MAME-with-our-tables.
It is **blind by construction** to open threads 2, 3 and 4 — those are cases where MAME
itself is wrong. A clean co-sim result does not exonerate the engine.
