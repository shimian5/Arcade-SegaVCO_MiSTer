# Title-logo garbling: investigation state

Status as of session end. Branch `worktree-phase0-1a`.

**Read the LAST section first.** This document is append-only and its sections
retract each other in order, so the newest one is the current state and everything
above it is kept for auditability. As of 2026-07-29 (session 6, continued still
further) the video-pipeline sprite-rendering bugs are fixed and verified; the
remaining open thread is a CPU/game-state divergence between sim's Z80 (TV80)
and MAME's Z80 emulation. TV80's interrupt-accept cost has been directly
measured against the Zilog spec and confirmed exact (13T, every interrupt,
whole run) — that suspect is closed. A per-frame diff of three RAM flag bytes
against MAME pinpointed a concrete, observable symptom (coin-insert response
fires on a different input edge in each run) and traced it to being a likely
*downstream consequence* of an already-located branch-point divergence around
frame 44-45, not a new independent bug. The one open question is which
specific instruction(s) TV80 executes with a wrong T-state count during
frames 9-44's busy-wait loop — see the newest section below for the full
chain of evidence. Jump there; the sections between here and it are settled
history, including the session-4 suspect writeup, which explains the
background-layer fix but turned out not to fully explain the sprite-layer
symptom, and the session-6 rendering-bug fixes/game-state-divergence framing
that prompted this follow-up.

Current one-line status: the intra-pipeline coordinate-skew bug (session 4) is
fixed in `rtl/video/fg_tilemap.v` and `rtl/z80_3d.v`, and **confirmed fixed by
visual review**: the tunnel-wall tearing and the star layer both render clean
now (`tools/measure_wall_profile.py` monotonic, and the user reviewed rendered
sim frames directly). **The title logo and the multi-colour UFO/ship sprites are
still visibly torn** in those same rendered frames — this fix did not resolve
them, so the sprite path needs its own investigation next session (see the note
at the end of the session-5 section below). Also **not yet re-verified on a
DE10-Nano capture** for the part that is fixed.

Older navigation note, still true of the sections below: the update after this
header retracts the TL;DR that follows *it*.

---

## UPDATE 2026-07-29 (session 3): the VBLANK-writeback FSM bug is FIXED. Logo still garbled. Measured.

The "one real RTL bug found so far" below (`y_target` truncation causing
`prepare_sprites` to spuriously re-run during VBLANK) is now **fixed** in
`rtl/video/sprite_engine.v`: `ST_IDLE` only launches when a new
`run_prepare_sprites` wire (derived from the full 9-bit `vpos`, not the
truncated `y_target_next`) is true, which happens exactly once per visible
scanline y=0..223 and never during VBLANK — matching MAME's
`for (y = cliprect.min_y; y <= cliprect.max_y; y++)`. `y_target` itself and
the enable ALU were left untouched, so the ported arithmetic is unchanged.

**Verified structurally, directly:**
- Rebuilt and re-ran `make -C sim dump`. `RASTER ALIGNMENT: 0/25681920 ce_pix
  ticks deviating` — clean run, instrument trustworthy.
- `sim/out/dbg_rtl_levels.txt` for slot 2 (the logo sprite, level 2): `ve=1`
  for exactly y=78..143 (66 visible scanlines), `offset` advancing by exactly
  `0x80` (rowbytes=0x40, preshifted <<1) per committed line, with the
  expected occasional same-line repeat where the Y-scale PROM skips a row
  (1-in-5, matching the intentional 4:5 vertical compression already
  established). **Zero** spurious advances anywhere outside y=78..143,
  including all of y=224..263 (VBLANK) where `y_target` is now simply frozen
  (the FSM doesn't run there at all, so nothing to log). Before the fix this
  same trace would have shown extra `offset` bumps during VBLANK for any
  sprite whose Y-range satisfied the ALU compare there; after the fix there
  are structurally none, because the FSM never launches during VBLANK.

**Tested against the visual symptom — the fix does NOT clear the garbling.**
Compared `sim/out/dbg_150.ppm` (native 512×224, no scaling needed — MAME's
`:screen` device is *also* 512×224 native for this driver, confirmed via
`screen.width`/`screen.height` in Lua; a naive `-video none` snapshot via
`manager.machine.video:snapshot()` is NOT usable for this — see harness note
below) against a MAME reference captured with a Lua script that reads
`screen:pixel(x,y)` directly.

**Game-state alignment, the trap this doc already warned about, hit again and
resolved by measurement, not assumption:** sim's own frame timeline runs
noticeably ahead of MAME's for the same coin(90-99)/start(150-159) input
schedule — sim shows "GAME OVER/INSERT COIN" at its frame 90 where MAME still
shows it at MAME's frame ~100, and sim reaches the post-start transition frame
(logo + blank "SPEED:" HUD + lives icons, no CREDIT text) at sim frame 150
while MAME reaches the *same* HUD content only at MAME frame 162. Confirmed
match by HUD text/layout, not just position: both show `SPEED:` with no
numeric value yet, lives icons bottom-left, `(C) SEGA 1982` bottom-right, no
`CREDIT` text, logo in the same position/size. (MAME frames 100-161 show the
"CREDIT 1" title/scoreboard screen instead — a different game state, and
exactly the kind of mismatch that produced a false result in an earlier
session.)

**Pixel diff, sim frame 150 vs. MAME frame 162, both native 512×224:** 8059 /
114688 pixels differ (7.0%), concentrated entirely inside the logo's
bounding box — the starfield, HUD text, lives icons and copyright line are
pixel-clean between the two. The logo interior is still visibly garbled in
sim (color noise / bleeding between letters) versus MAME's crisp render, in
the same way as before the fix.

**Conclusion, stated plainly: this was a real, worth-fixing RTL bug (VBLANK
writeback was corrupting ROM row pointers, a genuine fidelity gap vs. MAME
and vs. the schematic's BLANK-gates-everything behavior), but it is not the
cause of the title-logo garbling.** The garbling must come from somewhere
else. Given the FSM's writeback/offset path is now further confirmed clean
(bit-exact single advance per visible line, zero VBLANK contamination), the
remaining open threads are the schematic ones already tracked below
(nibble-select XOR, `END` source note already closed clean, VCO→pixel-clock
resync) — none of which this session touched.

**Harness note, worth keeping:** `manager.machine.video:snapshot()` (and
`-snapsize WxH`) on this driver returns a canvas that also includes the
cabinet's physical side scoreboard ("BEST 5" / "YOUR SCORE") panels, at a
non-native, seemingly-arbitrary width (646, or stretched/cropped to whatever
`-snapsize` requests) — this is MAME's default *view* compositing, not the
emulated screen's own framebuffer, and diffing against it manufactures
differences (wrong layout, wrong width) that have nothing to do with the
core. Reading `screen:pixel(x,y)` directly off
`manager.machine.screens[":screen"]` for `x` in `0..screen.width-1`, `y` in
`0..screen.height-1` and writing a raw PPM gives the actual 512×224 native
framebuffer with no side panels and no scaling — use that, not
`video:snapshot()`, for any future pixel-level sim-vs-MAME comparison on this
driver.

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

- **Frame-index alignment in the harness (check this first). CONFIRMED AND FIXED,
  2026-07-29 — see `docs/PLAN.md`'s logo section for the full writeup.** It was a real
  off-by-one: `sprite_engine.v`'s `dbg_cur_frame` initialised to `-1`, one behind the
  testbench's own `frame` counter, so engine frame N meant tb frame N+1. Fixed by
  initialising it to `0`. Re-running `make -C sim dump` afterward, `sim/out/dbg_sprram.hex`
  (start-of-frame-150 snapshot) now shows slot 2 enabled with the logo's payload, and
  `sim/out/dbg_150.ppm` shows the (garbled) logo for that same frame — the two dumps
  finally agree, and **frame 150 itself is the correct baseline**, not 151+.
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

## The one solid RTL bug found so far — FIXED 2026-07-29 (session 3), did not fix the logo

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

**Fixed.** `ST_IDLE` now only launches on `hblank_rise && run_prepare_sprites`, where
`run_prepare_sprites = (vpos == VTOTAL-1) || (vpos < VDISP-1)` is evaluated on the full
9-bit `vpos` (not the truncated `y_target_next`), so the FSM runs exactly once per visible
scanline y=0..223 and never during VBLANK. `y_target` itself stays 8 bits and the enable
ALU is untouched — only *when* the FSM is allowed to launch changed. See the UPDATE at the
top of this file for the measured verification (raster alignment, level-log offset trail,
and the pixel-diff test against MAME). **Confirmed real and worth keeping as a fidelity
fix vs. MAME/hardware, but it does not clear the title-logo garbling** — the symptom is
unchanged after the fix, measured via pixel diff.

The open schematic question below is now **closed in the "no VBLANK activity" direction**
by this fix matching MAME's behavior, but note the schematic evidence
(`docs/reference/VCO_schematic_findings.md`, SESSION 3) was the actual justification for
the fix's shape (gate on vpos, don't just widen y_target) — `BLANK` asynchronously clears
the per-level gating flip-flop, turning off the ROM address counter, gating off the
scaling VCO, and clearing the ROM data latch, so the hardware does not fetch sprite data
while `BLANK` is asserted. Whether that `BLANK` is composite (H+V) or horizontal-only
remains open and was **not** settled by this session — not needed for this fix, since
`prepare_sprites` firing once per visible scanline during active display is correct either
way.

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

---

## UPDATE 2026-07-29 (session 4): NEW PRIME SUSPECT — intra-pipeline coordinate
## skew in the video path. Measured off a real DE10-Nano capture.

Evidence: a hardware photo of the attract screen ("GAME OVER / INSERT COIN")
versus a matched MAME capture. Three reported symptoms: stars not confined to
the sky; the tunnel-wall top edge ragged (tabs sticking **up** on the left wall,
**down** on the right); the ship sprite garbled.

**The wall is the fg tilemap, not sprites.** Confirmed by dumping `c000-c7ff`
from MAME at the attract frame (`tmp/probe.lua` idiom): rows 6-23 of the 32x32
grid hold the V-shaped tunnel (codes 0x90-0xcf on the flanks, 0xe0 fill, 0x80
sky). So symptom 2 is a foreground-tilemap defect.

**Measured geometry of symptom 2** (hardware capture resampled to the core's
native 512x224 output grid, per-column top-of-wall scan):

- The defect is **exactly 2 output pixels wide** and recurs with a period of
  **exactly 16 output pixels** — i.e. **1 native pixel, at every 8-pixel tile
  column boundary** (the core runs 2x horizontal, so 512 output px = 256 native).
- Its magnitude is 3-4 scanlines, which is exactly how much the wall's cornice
  diagonal drops across **one tile column**. So the bad pixel is displaying the
  neighbouring tile column's art.
- The sign flips between the left and right walls, because the diagonal's slope
  flips. That is the "up on the left / down on the right" the user described,
  and it is a *horizontal* error rendered visible as vertical raggedness.

**Root cause hypothesis — `rtl/video/fg_tilemap.v` samples `xx`/`y` at four
different times inside one 4-stage fetch.** `xx_native`/`y_native` are fed in
combinationally from `hpos`/`vpos` and advance once every **8 core clocks**
(`hpos` steps on `ce_pix` = clk/4; `xx = hpos[9:1]`). But the stages are 1 clk
apart and each grabs a *different field of the live coordinate*:

| stage | clk | uses |
|---|---|---|
| 1 `xshift_dout` | t+0 | `xx[7:3]` (tile column) |
| 2 `vram_dout`   | t+1 | `y[7:3]` (tile row) |
| 3 `plane*_dout` | t+2 | `y[2:0]` (row within tile) |
| 4 `foreraw_reg` | t+3 | **`xx[2:0]` (pixel within tile)** |

So the tile is selected by `xx` at t and the pixel-within-tile by `xx` at t+3.
For 3 of every 8 clock phases those disagree by one native pixel. The module's
header comment claims safety because "xx/y are held stable for 8 clk" — true in
the middle of a native pixel, **false at every native-pixel boundary**, and
there is no sampling phase that rescues it: the two output sub-pixels of a
native pixel are 4 clk apart while the skew window is 3 clk wide out of 8, so at
least one sub-pixel per native pixel is guaranteed to mismatch. At a tile
boundary that mismatch means rendering the **leftmost pixel of the previous
tile** — precisely the measured defect.

**Why no earlier test caught it.** The only sim-vs-MAME pixel diff ever run was
the logo frame, where the fg content is text on blank tiles: the leftmost column
of a glyph tile is background anyway, so the error is invisible. The tunnel wall
is the first fg content with dense tile-to-tile variation *and* a shallow
diagonal, which amplifies a 1-pixel horizontal error into a 4-scanline vertical
one. MAME can never show it — MAME has no pipeline.

**Same defect class, sprite path — this is the logo/ship garbling suspect.**
`z80_3d.v` delays `sprbits`/`plb` by `SPR_TO_MIX_DELAY = 5` clk to meet
`forebits_reg2` at 6 and `star_bit`/`bgcolor_reg` at 6. Output pixels are 4 clk
apart, so 5 is **not** a whole number of pixels: the sprite layer lands one core
clock (1/4 pixel) off the layer it is being mixed with, and at the ce_pix
sampling instant the mixer sees the *previous* output pixel's `plb`/`cd`
combined with the current pixel's fg/star/bg. That predicts exactly what has
been observed all along:

- **solid-colour sprites render perfectly** (the HUD "TIME LEFT" bar — no
  interior pixel boundaries to get wrong) while **multi-colour artwork garbles**
  (logo, ship) — the single most diagnostic fact in this whole investigation,
  and this is the first theory that explains it;
- the earlier "consistent ~2-pixel rightward start-column shift" seen in the
  crude logo row-scan;
- everything *inside* `sprite_engine.v` measuring bit-exact — the engine is
  right, the **sampling of its output** is wrong;
- all previously ruled-out suspects stay ruled out.

This is the item PLAN.md currently files as **"Cosmetic/latent, fix after the
real bug"** ("mixer pipeline free-runs on `clk` not `ce_pix` ... depths mutually
consistent, so sub-pixel offset only"). **That dismissal is wrong.** Depths
being mutually consistent in core clocks is not the same as being consistent in
*pixels*, and it is not the same as each stage sampling a coordinate at the same
time. Promote it to prime suspect.

**Cheapest confirmations, in order:**

1. Register `xx`/`y` into a delay chain inside `fg_tilemap.v` so every stage
   consumes the *same* pixel's coordinate (stage 4 must use `xx[2:0]` delayed by
   3, stage 2 `y[7:3]` delayed by 1, stage 3 `y[2:0]` delayed by 2). Re-render
   an attract frame with the tunnel wall on screen and re-scan the top-of-wall
   profile — the 1-native-pixel tabs at every tile boundary should vanish.
2. Gate the whole `z80_3d.v` mixer pipeline with `ce_pix` (or re-time
   `SPR_TO_MIX_DELAY`/`COORD_DELAY` to whole pixels) and re-diff the logo frame.
3. **Add an attract frame *with the tunnel wall* to the sim-vs-MAME diff set.**
   Every diff so far used the logo frame, whose fg content structurally cannot
   expose a tile-boundary bug. This is the instrument gap that hid it.

**Symptom 1 (stars) is probably NOT this bug.** Checked directly: the wall
interior in the hardware capture has *no* star bleed-through, so fg tier-2
opacity is holding. The difference is that MAME's bitmap has stars only in an
upper band while hardware's has them all the way down to the wall — i.e. the
**sub CPU is drawing/erasing a different region**, a content issue. Note the
star-density work was validated in sim against TV80; hardware runs **T80**, a
CPU path no simulation result in this document has ever exercised. Treat it as a
separate thread.

### Raw evidence for the session-4 measurement, and the instruments

Both instruments are committed, so this is reproducible rather than a one-off
scrape. Neither existed before this session, and their absence is why the bug
survived four sessions.

**`tools/mame/dump_vram.lua`** — dumps `c000-c7ff` (32x32 tile codes),
`e400-e47f` (16 sprite slots) and `e000-e0ff` (sprite-position RAM) off the main
CPU at a chosen frame. Frame 60 is the attract "GAME OVER / INSERT COIN" state.
Output at that frame, rows 6-23, is unambiguous — the tunnel is in the tilemap:

```
row  6: b0 b1 80 80 ... 80 80 ae af
row 10: 98 9a 99 98 9b 9c 9b 9c b6 b7 80 ... 80 a8 a9 96 97 96 97 98 99 9a 98
row 14: 98 9a 99 98 9b 9c 9b 9c 9d 9d 9e 9f a0 a1 a2 be bf 90 91 92 93 94 95 95 96 97 96 97 98 99 9a 98
row 22: e0 e0 e0 e0 e0 e0 e0 e3 e0 ... e0 ec e0 e0 e0 e0 e0 e0
```

0x80 is the blank/sky tile, the 0x90-0xcf run is the striped wall art (note the
mirrored left/right flanks, and repeating pairs like `9b 9c` / `96 97`), 0xe0 is
the floor fill. Sprite RAM at the same frame holds only the UFO, the ship, the
explosion and the HUD bars — nothing wall-shaped.

**`tools/measure_wall_profile.py`** — normalises any capture (hardware photo,
MAME PPM, `sim/out/*.ppm`) onto the native 512x224 output grid and prints the
first wall scanline per output column, then flags columns that jump *backwards*
against the local trend. On the DE10-Nano capture, columns 0-79:

```
top :  -- 49 49 49 49 49 49 51 51 51 51 51 52 52 52 [49 49] 53 53 53 54 54 54 55 55 55 55 55 56 56 56 [53 53]
       57 57 57 58 58 58 59 59 59 59 59 60 60 60 [57 57] 61 61 61 62 62 62 63 63 63 63 63 64 64 64 [61 61] 65 ...
cls :   -  G  G  G  G  G  G  G  G  G  G  G  G  G  G   G  G   T  T  T  T ...

backward notches at x = [15, 31, 47, 63, 79]
  x mod 16 = [15, 15, 15, 15, 15]
  spacing  = [16, 16, 16, 16]
```

Read that carefully, because every number in it is load-bearing:

- The ramp advances **4 scanlines per 16 output pixels** — the cornice diagonal.
- Each bracketed notch jumps back to **exactly the value the ramp held 16 output
  pixels earlier** (x=31 reads 53, which is the x=17-19 value; x=47 reads 57,
  the x=33-35 value; x=63 reads 61, the x=49-51 value). It is not noise and it
  is not a rounding artifact of the capture: it is one specific neighbouring
  tile column's art, reproduced exactly.
- Notch **spacing 16 output pixels = one 8-pixel tile column**; notch **width 2
  output pixels = one native pixel**.
- The notches straddle the boundary (x ≡ 15, 0 mod 16), i.e. the last sub-pixel
  of one native pixel and the first of the next — which is what a 3-clk skew
  inside an 8-clk native pixel produces, and is *not* what a whole-pixel layer
  offset would produce.
- The notches occur at tile boundaries **regardless of whether the stripe colour
  changes there** (x=31 and x=47 are both interior to the teal run), so this is
  a fetch-geometry error, not a colour-table or opacity error.

Run the same tool on a MAME capture of the same state as the control: the
profile is monotonic, no notches.

### One caveat to carry forward: hardware runs T80, simulation runs TV80

Every simulation result in this document comes from TV80 (`rtl/cpu_z80.v`'s
`VERILATOR_SIM` path); the DE10-Nano bitstream builds T80. That path has never
been simulated and never cross-checked. It does not affect the video-pipeline
theory above — that defect is in RTL that both builds share, is independent of
the CPU, and should reproduce in sim the moment a wall-bearing frame is diffed
(confirmation step 3). But it is the obvious first suspect for symptom 1, and it
means "sim is clean" is a weaker statement about hardware than it looks.

---

## UPDATE 2026-07-29 (session 5): FIX APPLIED AND VERIFIED IN SIM — intra-pipeline coordinate skew, not yet confirmed on hardware

Did the session-4 confirmation steps in order:

**A. `rtl/video/fg_tilemap.v`.** Added a small delay chain (`xx_d1/d2/d3`,
`y_d1/d2`) that captures `xx`/`y` once at stage 1 and re-times each field by
exactly how many stages it lags behind stage 1 (stage 2's `y[7:3]` → `y_d1`,
stage 3's `y[2:0]` → `y_d2`, stage 4's `xx[2:0]` → `xx_d3`). Every stage now
consumes the same `(xx,y)` sample instead of whatever is live on its own
clock. Rewrote the module header comment, which previously claimed a safety
property ("xx/y held stable for 8 clk") that does not hold at pixel
boundaries — it now states the actual failure mode and the fix.

**B. `rtl/z80_3d.v` mixer.** Chose "re-time the delays to whole pixels" over
gating the whole mixer on `ce_pix` (the header only offered the latter as an
alternative, and it would have meant touching every mixer stage's clocking,
not just its depth). The fg-tier path (`fg_tilemap`'s 4 + `color_table`'s 1 +
`forebits_reg2`'s 1 = 6 clk) and the sprite/star/bg paths (`SPR_TO_MIX_DELAY`
5 + 1, `COORD_DELAY` 5 + 1 = 6 clk each) were already *mutually* consistent
at 6 clk, exactly as the old dismissed comment said — but 6 clk = 1.5 output
pixels (`ce_pix` = clk/4), not a whole number, and that's what actually
mattered here (see below for why "mutually equal" wasn't sufficient on its
own). Bumped `SPR_TO_MIX_DELAY` and `COORD_DELAY` from 5 to 7, and added two
more register stages to the fg-tier path (`forebits_reg3`, `forebits_reg4`,
consumed in place of `forebits_reg2` everywhere downstream) so all three
paths land on a common 8-clk/2-pixel depth from their respective origins.
`VIDEO_PIPE_LATENCY` (the sync-bundle delay matching the mixer's total depth
to `rgb_reg`) moved from 7 to 9 accordingly.

**C. Verification.**

- `wsl -d archlinux -e make -C sim run` (410 frames, TV80 path) builds and
  runs clean.
- `tools/measure_wall_profile.py sim/out/buckrogn_060.ppm --cols 0 96` (frame
  60 = the attract "GAME OVER / INSERT COIN" wall-bearing frame, matching the
  MAME reference in `tools/mame/dump_vram.lua`) now reports **no backward
  notches — profile is monotonic**. Before the fix, the same tool on the same
  frame reproduced the session-4 measurement exactly (notches at
  x=15,31,47,63,79, spacing 16). This is the sim-side reproduction of the
  hardware-captured defect that confirmation step 3 called for.
- Frame 60 was chosen deliberately over the logo frame per the session-4
  writeup: the logo's fg content is text on blank tiles, which cannot expose
  a tile-boundary bug (the leftmost column of a glyph tile is background
  anyway). The wall's dense tile-to-tile art with a shallow diagonal is what
  makes a 1-native-pixel horizontal error visible as a multi-scanline
  vertical notch. This is now added as a standing case in the verification
  set, not a one-off: any future video-pipeline change should be checked
  against a wall-bearing frame, not just the logo frame.

**Instrument-discipline note, in the spirit of "validate the probe before
trusting a comparison":** applying fix B (re-timing `VIDEO_PIPE_LATENCY` from
7 to 9) broke `sim/tb_z80_3d.cpp`'s `RASTER ALIGNMENT` self-check —
`RASTER_LAG`, a hardcoded testbench constant, was calibrated against the old
latency and went stale, producing a report of 25,681,904/25,681,920 ce_pix
ticks "deviating" (effectively 100%). This looked exactly like a real phase
bug but wasn't: `top->ce_pix` is z80_3d.v's *delayed* `ce_pix` output
(deliberately re-timed to align with `rgb_reg`), the testbench's own raster
counter only advances on that delayed pulse, and the lag between it and the
RTL's raw `dbg_hpos`/`dbg_vpos` is a pure simulation-harness artifact of
`VIDEO_PIPE_LATENCY` — not a hardware timing fact, and not something the
schematic has an opinion on. Re-measured it directly (dumping
`(tick, tbx, tby, hpos, vpos)` and reading off the wrap, same method the
original `RASTER_LAG=4` comment used) rather than trusting a naive
"add the latency delta" prediction, which was in fact wrong (predicted 6,
measured 5). Full run now reports `RASTER ALIGNMENT: 0/69273600` deviations.
**Takeaway carried forward:** any future change to `VIDEO_PIPE_LATENCY` must
re-measure `RASTER_LAG`, not extrapolate it — this is exactly the kind of
"validate the probe" trap the earlier sessions warned about, just in the
testbench itself rather than in a sim-vs-MAME comparison. A more robust fix
(self-calibrating `RASTER_LAG` at sim startup, or deriving it algebraically
from `VIDEO_PIPE_LATENCY` with the actual relationship worked out rather than
guessed) is a worthwhile follow-up but out of scope here.

**What is NOT yet done:**

- **Not re-verified on real DE10-Nano hardware.** The original defect was
  measured on a hardware capture (session 4's raw evidence, still in this
  document above); the fix has only been confirmed in sim so far. Building
  and running the updated bitstream on hardware, then re-running
  `tools/measure_wall_profile.py` against a fresh capture, is the step that
  actually closes this out.
- **T80 vs TV80 still uncross-checked** (see the caveat above this section) —
  the fix is in RTL shared by both CPU paths and is independent of the CPU,
  so there's no specific reason to expect it behaves differently under T80,
  but that's an expectation, not a measurement.
- **Symptom 1 (stars extending below the sky on hardware but not MAME)**
  remains a separate, uninvestigated thread, as established in session 4. Not
  to be confused with the sim-visible star-layer tearing fixed by this
  session's `COORD_DELAY` re-timing (below) — that was a rendering-pipeline
  defect in the `star_bit`/`bitmap_ram` read timing, not the sub-CPU
  content-region question symptom 1 is about.

---

## UPDATE 2026-07-29 (session 5, continued): visual review confirms wall + stars fixed, sprite layer (logo/UFO/ship) still garbled

Rendered several post-fix frames from the `make -C sim run` output
(`sim/out/buckrogn_060.ppm`, `_150.ppm`, `_155.ppm`) and reviewed them
directly with the user (not just the automated wall-profile check):

- **Fixed, confirmed by eye:** the tunnel wall (frames 60, 155) now renders
  with a clean, unbroken cornice line — no tile-boundary tearing. The
  starfield background also renders cleanly now (it reads through the same
  `COORD_DELAY`-gated `bitmap_ram`/`star_bit` path re-timed in this session).
- **NOT fixed:** the title logo (frame 150, "BUCK ROGERS / PLANET OF ZOOM")
  is still heavily torn — smeared/overlapping letterforms, colour bleed
  between adjacent columns, exactly the pre-fix appearance. The large
  multi-colour UFO/mothership sprite and the small player-ship sprite (both
  visible in frames 60 and 155) are similarly torn, while the small
  solid-colour ship icons in the lives HUD (bottom-left) remain clean — the
  same solid-vs-multi-colour split noted in session 4, unchanged by this fix.

**Conclusion: this session's fix is a real, verified partial fix — the
fg-tilemap/background-mixer alignment defect is resolved — but it is not the
(or not the only) cause of the logo/UFO/ship sprite garbling.** That symptom
needs its own investigation next session, starting from `sprite_engine.v`'s
internal pipeline (check for the same class of bug just fixed here: a stage
consuming a live coordinate or index field instead of one captured and
delay-chained from a single sample) rather than assuming the mixer-alignment
fix here is relevant to it. Do not re-run the session-4 fix reasoning
unmodified against the sprite engine without first confirming its actual
internal pipeline structure — it may not have the same stage layout as
`fg_tilemap.v` did.

---

## UPDATE 2026-07-29 (session 6): sprite garbling ROOT CAUSE FOUND AND FIXED — a ROM-nibble-select generation mismatch in `sprite_engine.v`

Followed session 5's suggested first step: built a per-pixel instrument for
the sprite path and compared it against a golden model, instead of continuing
to read the RTL statically. The tooling for this (`sim/golden_buckrog.py`,
`sim/compare_spr.py`, `rtl/video/sprite_engine.v`'s `dbg_rtl_spr.bin`/
`dbg_rtl_levels.txt` dumps) already existed from session 4 — it just hadn't
been *run* against a per-pixel comparison for a sprite-bearing frame since
before session 5's mixer changes. Running it immediately surfaced a real
signal.

### Instrument bug found and fixed first (don't skip this if re-deriving)

The first run of `sim/compare_spr.py` against frame 150 showed 5560/114688
mismatching pixels, starting at y=82. Before trusting that, per this
document's own "instrument discipline" rule, the probe was checked — and it
had a real bug, independent of anything above: `sim/tb_z80_3d.cpp`'s
`dbg_rtl_spr.bin` writer sampled `dbg_sprbits`/`dbg_plb` on `top->ce_pix`
(z80_3d.v's **mixer-delayed** `ce_pix` output) but indexed the output buffer
by the testbench's own `(x,y)` raster counter, which only advances on that
same delayed pulse. `sprite_engine.v`'s outputs are explicitly **real-time,
0-latency vs. raw `hpos`/`vpos`** (see its header) — so every sample was
written under the wrong raster address, off by the session-5-documented
`RASTER_LAG` (5 ce_pix ticks) in the *full* 640-wide raw-hpos domain, which
straddles the 512-visible/128-blanking split unevenly and so does **not**
reduce to a simple shift within the 512-wide visible window (confirmed
empirically: shifting the RTL buffer by every offset from -8..+8 in the
visible window never got mismatches close to zero). Fixed in
`sim/tb_z80_3d.cpp` by sampling on every raw `dbg_hpos`/`dbg_vpos` change
directly (independent of the delayed `ce_pix`/`(x,y)` bookkeeping used for
the PPM framebuffer, which was never wrong and is untouched) and indexing by
that same raw position — `video_timing.v`'s `HBSTART=512`/`VBSTART=224`
mean the raw visible-region values already equal the desired buffer index
with no translation needed.

Re-running after that fix moved the mismatch to 5947/114688 (similar
magnitude, different exact pixels) — confirming the instrument bug was real
but was not the (or not the only) source of the original signal. This is
exactly the two-bug situation the "validate the probe" rule exists for:
fixing the instrument doesn't make a real defect disappear, it just stops
lying about where it is.

### The real bug: nibble-select and ROM-byte-fetch pull from different fire generations

With the instrument fixed, a narrow `$display` trace (level 2, y=82,
hpos 415-445, one line per raw clk) showed `pixdata` — the nibble selected
from `rom_dout` — visibly **changing value partway through a single output
pixel's 4-clk window**, the same class of symptom as the intra-pipeline
coordinate skew session 4/5 fixed in `fg_tilemap.v`, but this time inside
`sprite_engine.v`'s own per-pixel path, not in the cross-module mixer.

Root cause, precisely: on each `fire` (X-scale accumulator crossing
threshold), the old code did

```verilog
offset_reg[lvl]         <= offset_reg[lvl] + (±1);     // -> O_k
nibble_sel_pending[lvl] <= ~offset_reg[lvl][0];         // uses PRE-increment O_(k-1)
```

`rom_raddr[lvl]` is combinational off `offset_reg[lvl]` and the ROM bank read
is itself a registered (1-clk-latency) BRAM port, so a fetch takes **2**
clock edges end-to-end from a fire (address settles the edge after the fire,
data lands the edge after that) — but `nibble_sel_pending` landed only **1**
edge after the fire, using the offset value from *before* that fire's own
increment. By the time `fire_pending` is consumed one X-scale period later
(when `rom_dout` has fully settled to reflect the fetch this fire triggered,
i.e. offset `O_k`), the paired `nibble_sel_pending` was still describing
`O_(k-1)` — one fire generation stale.

This is **not** an occasional glitch: `offset_reg` changes by exactly ±1
every fire, so consecutive offsets *always* alternate LSB parity. Using
`O_(k-1)`'s parity instead of `O_k`'s therefore selects the **opposite**
nibble half of the byte on every single fetch, unconditionally. It is
invisible exactly when both nibbles of the ROM byte at that address happen
to encode the same pixel value — which is common in a flat-colour sprite
region (explaining the clean HUD lives icons) and false in detailed,
multi-colour art (the logo, the UFO, the player ship) — reproducing the
solid-vs-multicolour split that has been the central diagnostic clue since
session 4, without needing a second, unrelated explanation for it.

**Fix** (`rtl/video/sprite_engine.v`, the per-level `always` block in the
`get_sprite_bits` generate loop): compute the post-increment offset
explicitly (`offset_next`) and derive `nibble_sel_pending` from *that*, not
from the pre-increment `offset_reg[lvl]`:

```verilog
wire [OFFSET_WIDTH-1:0] offset_next = offset_reg[lvl] + (±1, same as before);
...
offset_reg[lvl]         <= offset_next;
nibble_sel_pending[lvl] <= ~offset_next[0];   // was: ~offset_reg[lvl][0]
```

Both the byte fetch (via `rom_raddr`/`rom_dout`, still 2 edges from the fire)
and the nibble select (now also `O_k`-based, 1 edge from the fire) now
describe the same offset generation by the time `fire_pending` consumes them
a full X-scale period later — the 1-clk transient right after the fire, where
`rom_dout` briefly still shows the old byte while `nibble_sel_pending` has
already updated, is harmless because nothing reads `pixdata` at that instant
(`fire_pending` is only consumed at the *end* of the following period, by
which point `rom_dout` has long settled).

### Verification

- `sim/compare_spr.py` on frame 150: mismatches dropped from 5947/114688 to
  4810/114688, and — more importantly than the count — the *character* of
  the remaining mismatches changed. Before the fix, a level's sprite colour
  would flicker on/off/on again with the correct-but-displaced colour data
  (a "double echo" — see the raw trace and `sim/compare_spr.py` output
  captured in this session for y=82, x≈415-445). After the fix, the same
  region shows one clean, contiguous run that merely starts ~2 native pixels
  earlier than golden and ends in the same place — a much smaller, different
  kind of discrepancy (see "Remaining open item" below), not interior colour
  corruption.
- **Visual confirmation is unambiguous.** Rendered and inspected
  `sim/out/dbg_150.ppm` (logo), `sim/out/buckrogn_060.ppm` and `_155.ppm`
  (UFO mothership + player ship): all three are now clean. The "BUCK ROGERS
  / PLANET OF ZOOM" logo renders with crisp, correctly-coloured letterforms
  (compare against the "heavily torn, smeared/overlapping letterforms"
  description in the previous update) and the UFO mothership's internal
  multi-colour detail (portholes, hull shading) is intact and stable across
  both sampled frames.
- **No regression**: `tools/measure_wall_profile.py` on the regenerated
  frame 60 still reports "no backward notches -- profile is monotonic" for
  the tunnel wall (session 5's fix untouched and still holding).
- The `$display` trace added for diagnosis was temporary and has been
  removed from `rtl/video/sprite_engine.v`; only the `offset_next` fix and
  the `sim/tb_z80_3d.cpp` instrument fix remain in the diff.

### Remaining open item: ~2-native-pixel-early turn-on at some sprite-region edges

`sim/compare_spr.py` still reports 4810/114688 mismatching pixels, all
still confined to the sprite-bearing scanlines (y=82-121ish for this
sprite). Spot-checked (y=82, x=415-445): golden's sprite run is x=430-436;
RTL's is x=428-436 — RTL turns the level on 2 native pixels early but turns
it off at the identical pixel. This reads as a horizontal-enable/lst_active
turn-on edge being sampled ~1 xx-column too early (a smaller, different bug
from the one just fixed — likely in the `ix0`/`he_or_mask` sampling cadence
or the sprite-position-RAM prefetch alignment, not the ROM-fetch pipeline),
not a recurrence of the nibble-select bug (the interior of every mismatched
run now carries the *correct* colour data, just shifted at the leading
edge). Given the visual result is already clean at normal viewing scale,
this is lower priority than the fix above, but worth closing out before
calling the sprite path bit-exact against MAME. Suggested next step: repeat
this session's method (narrow trace on `he_masked`/`ix0`/`lst_active`
around a mismatching leading edge) rather than re-deriving from a cold
read of the code.

**Not yet done:** hardware re-verification (this fix, like session 5's, is
sim-only so far); the residual edge-timing item above; T80-vs-TV80 remains
uncross-checked (unrelated to this fix, same caveat as session 5).

---

## UPDATE 2026-07-29 (session 6, continued): MAME cross-check confirms the nibble fix; found and fixed a SECOND real bug (ROM fetch-address must be a captured register, not a live combinational tap); remaining mothership discrepancy is a game-state mismatch, not a rendering bug

Picked a real MAME capture (`mame.exe buckrogn -video none -sound none
-autoboot_script tools/mame/dump_frames_60_155.lua`, same coin/start
schedule as `sim/tb_z80_3d.cpp`) to compare against sim's frame 60 pixel by
pixel instead of eyeballing. The logo fix from the previous update held up.
But side-by-side crops of frame 60's UFO mothership showed something the
`sim/compare_spr.py` per-pixel counts alone hadn't made obvious: a small
mismatch in one specific region (the left engine pod, hardware level 5).

### Second real bug: `rom_raddr` must be captured at fire time, not tap the live offset

`sim/golden_buckrog.py` extended with a per-fire trace (fetch address,
pixdata, termination) confirmed fire *timing* and *offset progression* are
bit-exact between RTL and golden for level 5 — the FSM-level check
(step/offset/ve matching every scanline) was not lying. The remaining
difference was in *when fetched content becomes visible*: an exhaustive
shift search (`shift_search_lvl5.py`, isolating just level 5's nibble/plb
bits from the 32-bit `sprbits` word) found RTL displaying every colour
transition a constant, exact **2 native pixels early** relative to golden,
for the entire width of the level's run.

Root cause: `rom_raddr[lvl]` was `assign`ed straight from the **live**
`offset_reg[lvl]` — a plain combinational tap, not a captured value. Since
`offset_reg[lvl]` advances to its post-increment value at the very same
edge as the fire that's supposed to read the *pre*-increment byte, `rom_dout`
(which needs 1 clock to settle after `rom_raddr` changes) ends up settling
to the **next** generation's byte just 1 clock into the following period —
long before `fire_pending` actually consumes it 3 clocks later. Every fire's
consumption therefore silently picked up the *next* fire's data instead of
its own, structurally analogous to the nibble-select bug above but in the
address side of the pipeline rather than the nibble-select side, and
independent of it (this one exists regardless of the nibble fix).

**Fix**: added a real captured register, `fetch_addr_reg[lvl]`, updated only
at fire time (and at `commit_now`) from the *pre*-increment `offset_reg[lvl]`
— matching `sim/golden_buckrog.py`'s own `offs = st["offset"]` (fetch, then
increment afterward). `rom_raddr[lvl]` now reads `fetch_addr_reg[lvl]`
instead of tapping `offset_reg[lvl]` live, so the address (and hence
`rom_dout`) stays stable for the entire period until the *next* fire, the
same pattern already used correctly for the sprite-position-RAM prefetch.
`nibble_sel_pending` was reverted to the pre-increment `offset_reg[lvl][0]`
to match (the previous update's fix to make it post-increment was
compensating for this same bug from the wrong side, and is superseded by
this fix, not stacked with it).

Also (found not to be the cause here, but a genuine correctness fix in its
own right, kept): `latched_masked`/`plb` were gated on `lst_eff` (`lst_active
| he_or_mask`), and `he_or_mask` is combinationally nonzero for exactly the
one clock where `ix0` pulses at a column boundary — i.e. `lst_eff` answers
"the window is open" one whole period before `lst_active` itself latches
that fact. Changed the *output* gating to `lst_active` (registered); `live`
(the fire-gating condition) intentionally still uses `lst_eff`, since fire
cadence was independently confirmed bit-exact with that unchanged. This
didn't move `sim/compare_spr.py`'s numbers (the debug port samples once per
raw-hpos change and never catches the 1-clock combinational blip), but it
removes a genuine sub-clock hazard from the signal the real mixer pipeline
*does* sample every clock, so it's correct to keep regardless.

### Verification

- `sim/compare_spr.py` on frame 60: total mismatches dropped from
  5482/114688 to 2972/114688 (all remaining ones consistent with a single,
  uniform **1-native-pixel-late** residual — re-running the shift search
  found shift=+1 gives **zero** mismatches for level 5 across its entire
  run). Given the underlying hardware genuinely has ROM access latency that
  MAME's software model doesn't simulate, this residual may not even be a
  bug relative to real silicon — see "Remaining item" below.
- `tools/measure_wall_profile.py` on the regenerated frame 60: still "no
  backward notches -- profile is monotonic" (no regression to session 5's
  fix).
- Re-rendered frame 150 (logo) after this fix: still clean.

### The "duplicate flame pod at the mothership's top corners" is NOT a rendering bug

Visually, frame 60's rendered UFO showed the same red/yellow engine-pod
graphic appearing at the top-left/top-right corners where MAME's reference
capture shows a small distinct cream-coloured strut/antenna instead. Before
chasing this as a third rendering bug, it was checked against the same
"validate the probe" discipline this document keeps needing to reapply:

`rtl/video/sprite_engine.v`'s own header explains this is an intentional
hardware trick — 16 sprite-RAM entries fold onto 8 hardware levels
(`level = sprnum & 7`), and if two different sprite-RAM entries that share a
level both fire on the same scanline, only the second one's offset/step
survives for the *entire* level's walk that scanline (whichever sprnum's
horizontal-enable window happens to be open just borrows whatever the
"winning" sprnum's accumulator is currently producing). A quick renderer
(`render_sprite_only.py`, colouring each pixel by its lowest-set `plb` bit)
run against **both** `dbg_golden_spr.bin` (MAME-logic golden model, fed
from RTL's own captured sprram) and `dbg_rtl_spr.bin` showed **identical**
shapes: the same "level 5 pod" silhouette at both the top and bottom
corners, in both models. Since the golden model is a literal, independent
port of MAME's own `prepare_sprites`/`get_sprite_bits` logic, and it
reproduces the exact same corner duplication RTL does, this is not a
rendering-pipeline defect — a real bug in `sprite_engine.v`'s logic would
make RTL *diverge* from golden, not agree with it.

That means the mismatch against the **actual MAME reference capture**
(which does *not* show this duplication) is a **content/game-state**
difference: at the instant our sim's frame 60 was captured, whichever
sprite-RAM entry (sprnum 5 vs. 13, sharing level 5) "won" the scanline
differs from what MAME's real CPU execution had at its own frame 60. This
is the same class of gap already flagged for T80-vs-TV80 and for symptom 1
(stars extending too far in hardware but not MAME) elsewhere in this
document: a divergence in *what the CPU has written to sprite RAM by this
point*, not in how `sprite_engine.v` renders whatever it's given. Chasing
this further means comparing CPU/game-state execution traces between sim
and MAME (attract-mode timing, which sprite entry table slot is currently
assigned to which on-screen ship, etc.) — a different, larger investigation
than the rendering-pipeline bugs this document has otherwise been tracking,
and out of scope for this session.

**Not yet done:** the ~1-native-pixel residual noted above (possibly not a
bug at all — see discussion); the game-state/content-divergence thread just
opened; hardware re-verification; T80-vs-TV80 (unrelated, longstanding).

## UPDATE 2026-07-29 (session 6, continued further): CPU/game-state divergence root-caused to a small, real sub-cycle timing skew that straddles a busy-wait loop's exit boundary — not a clock/interrupt-cadence bug, not a fundamentally different execution model

Followed up on the game-state-divergence thread opened above by comparing sim's
Z80 (TV80, `VERILATOR_SIM` path of `rtl/cpu_z80.v`) execution against MAME's own
Z80 core, per-frame, over the first 210 attract-mode frames (same coin/start
schedule as always: coin1 90-99, start1 150-159). This is about our sim's Z80
diverging from MAME's Z80 *emulation* — a different, separately-tracked question
from T80-vs-TV80 (sim vs our own real hardware), which remains untouched.

### Ruled out: clock-divider / frame-timing-budget mismatch (suspect 1)

Checked `rtl/z80_3d.v`'s clock enables against `docs/reference/turbo.cpp`'s
`buckrogn` machine config: `ce_z80 = clk/8` (4.992 MHz @ 39.936 MHz core) matches
`MASTER_CLOCK/4` (19.968 MHz/4 = 4.992 MHz) exactly; `ce_pix_int = clk/4` (9.984
MHz) matches `PIXEL_CLOCK = MASTER_CLOCK/4*TURBO_X_SCALE` (19.968/4*2 = 9.984
MHz) exactly; `video_timing.v`'s HTOTAL/HBSTART/VTOTAL/VBSTART (640/512/264/224)
match MAME's HTOTAL/HBSTART/VTOTAL/VBSTART (320*2/256*2/264/224) exactly. More
fundamentally: `vblank_rise` (and hence the VBLANK IRQ and every frame boundary)
is driven purely by `video_timing.v`'s free-running pixel counters, **not** by
CPU execution progress — so the Z80 T-state budget between interrupts (84480
T-states, unconditionally) is a hardware constant identical on both sides by
construction, not something a divider bug could desync. Suspect 1 is closed.

### Ruled out: interrupt cadence/vector-mode mismatch (suspect 2)

The VBLANK IRQ fires at the same raster instant (start of vblank) via
`vblank_rise` as MAME's `set_vblank_int`/screen-vblank-start callback. Checked
which interrupt mode the game actually uses (`sim/buckrogn.rom` reset vector:
`f3 ed 56` = `DI` then `IM 1`) — Buck Rogers runs IM1 throughout, so the
"data bus floats to FF during int-ack" comment in `z80_3d.v` (written for the
general IM0-compatible case) is moot here: IM1's RST 38 entry is vector-
independent and hardware-fixed at 13 T-states, same on real Z80, TV80, and
MAME's Z80 core. Cadence and mode both check out; suspect 2 is closed as a
*structural* mismatch (a fixed, exact per-interrupt T-state cost difference in
TV80's `IntCycle` state machine specifically remains unverified at the
T-state-table level and is the most likely remaining home for the small
residual timing skew found below, but that is a "TV80 has an N-T-state bug"
question, not an "interrupt fires at the wrong cadence/point" question).

### Built and ran suspect 3: a real PC-at-vblank trace diff

Added a small, `SIM_DEBUG_TRACE`-gated instrument to `rtl/z80_3d.v`: latches
the main CPU's PC at every opcode-fetch rising edge (`~cpu_m1_n & ~cpu_mreq_n &
~cpu_rd_n`, edge-detected — the naive level-gated version overcounts because
those signals stay asserted for multiple core-clock cycles per T-state) and
prints it at every `vblank_rise` as `PCTRACE frame=N pc=XXXX`. Paired with a new
`tools/mame/dump_pc_trace.lua` (same `register_periodic`/coin/start-schedule
pattern as `dump_frames_60_155.lua`, logging `maincpu.state["PC"]` once per
frame) to get the same measurement from MAME. Ran both for 210 frames
(`sim/obj_dir_trace` build with `+define+SIM_DEBUG_TRACE` added on top of the
normal `+define+VERILATOR_SIM`; `mame.exe buckrogn -video none -sound none
-autoboot_script dump_pc_trace.lua -str 8`) and diffed frame-by-frame.

**Result:**

- **Frames 1-43:** PC-at-vblank matches almost exactly. Frames 1-8 are
  bit-identical. From frame 9 on, both sides are executing the same 32768-
  iteration busy-wait/delay loop at `0x07b3-0x07b9` (`LD HL,8000h` / `DEC HL` /
  `LD A,L` / `OR H` / `JR NZ,-5` / `POP HL,AF` / `RET` — a pure CPU-cycle-count
  delay with **no I/O or state polled**, confirmed by disassembling
  `sim/buckrogn.rom` at that address), and the two runs stay within 1-2 HL-
  decrements of each other the whole time — a few T-states of real but tiny
  skew, not zero, but not compounding in any visible way either.
- **Frames 44-45:** both sides exit that loop (it's called from context, isn't
  itself frame-bounded) but at **different points relative to the video
  frame** — sim lands at PC=4ba2, MAME at PC=3479, and every frame from here on
  looks essentially uncorrelated (e.g. frame 60: sim=0cf7, MAME=21e3). This
  is not a rendering-relevant PC by itself; it's evidence of *which attract-
  mode subroutine got dispatched*, and the dispatch clearly differs from here
  on.

**Interpretation:** this is exactly the mechanism behind the sprite-RAM
game-state mismatch already documented above at frame 60. The 32768-iteration
loop (~851968 T-states at ~26 T/iteration) spans roughly 10 video frames/VBLANK
interrupts (851968/84480 ≈ 10.1) each call. A skew of only a handful of
T-states *per interrupt taken during that loop* — most plausibly in the exact
T-state cost of TV80's `IntCycle` (interrupt-acceptance) sequence relative to
MAME's Z80 core, since that is the one thing guaranteed to execute exactly once
per frame regardless of what code is running — accumulates across those ~10
interrupts into enough total drift that the loop's `JR NZ` exit, which is
otherwise purely a function of elapsed T-states, resolves on a **different
video frame** in sim than in MAME. Once that happens, whatever frame-driven
attract-sequence dispatcher runs next reads a different frame count / demo-step
value and branches into genuinely different code — so the divergence looks like
"total game-state chaos" from frame 45 onward, even though the underlying bug
is small, structural, and localized (order of single-digit T-states per
interrupt), not a wrong clock ratio and not a different execution model.

This also directly explains why the earlier "scan MAME's sprite RAM across
frames 1-500 for an exact match to sim's frame 60" search
(`docs/INVESTIGATION...` update above) found no clean fixed-offset match: past
the frame-44/45 branch point the two runs are executing different code, not the
same code shifted by a constant frame delta.

**Not yet done (next session), superseded by the update directly below:** the
paragraph that used to be here proposed comparing cumulative T-states consumed
between frames 9 and 44 against `84480 * 35`. That plan was wrong and never
run: since `vblank_rise`/every frame boundary is driven purely by the
free-running video counters (established under "Ruled out: suspect 1" above),
`ce_z80` fires unconditionally every 8 `clk` cycles regardless of CPU state —
there are no wait states anywhere in this design (`wait_n` is tied high) — so
"cumulative T-states elapsed per frame" is trivially and always exactly 84480,
by construction, in both sim and (assuming MAME's Z80 scheduler doesn't stall
either, which it doesn't for this architecture) MAME. Counting it would have
shown a match every time and proven nothing. The actually-informative
counter — measuring TV80's *own internal* T-state bookkeeping against the
Zilog spec, independent of wall-clock T-state totals — is below.

## UPDATE 2026-07-29 (session 6, continued yet further): TV80's IM1 interrupt-acceptance T-state count measured directly against the Zilog spec — exact match, every interrupt, whole run. Leading suspect refuted.

Prompted by "is it possible TV80 is more accurate than MAME's own Z80, and how
would we know rather than just trust whichever core agrees with our prior?" —
the answer is to check both against an independent ground truth (the Zilog Z80
Family CPU User Manual's timing tables) instead of treating either emulator as
the reference. Built exactly that check for the top suspect named in the
previous update: TV80's `IntCycle` (IM1 interrupt-acceptance) state machine in
`rtl/tv80/rtl/core/tv80_core.v`, spec value 13 T-states (extended 7T M1 cycle +
two 3T M-cycles pushing PC, vector-content-independent in IM1 — confirmed
`sim/buckrogn.rom` runs IM1 throughout via its `f3 ed 56` reset code, per the
prior update).

**Instrument added** (`rtl/z80_3d.v`, `SIM_DEBUG_TRACE`-gated, same block as
`PCTRACE`): counts `ce_z80` pulses (one per T-state) from the rising edge of
`int_ack` (the existing `~cpu_m1_n && ~cpu_iorq_n` signal already used for
`irq_pending`) to the very next main-CPU M1 opcode fetch — which, since
`main_m1_fetch` requires `mreq_n` low and the int-ack cycle holds `mreq_n`
high (only `iorq_n` asserted, per `cpu_z80.v`'s decode logic), can only be the
ISR's first real opcode fetch, not the int-ack pseudo-cycle itself. Prints
`INTACK_TSTATES frame=N tstates=T isr_pc=XXXX` at that point. This measures
TV80's actual, as-built interrupt-acceptance cost directly from RTL behavior —
no MAME involved, no comparison needed, just RTL vs. the datasheet number.

**Result:** ran 210 frames. Every single interrupt from frame 1 through frame
209 (209 events) printed `tstates=13 isr_pc=0038` — an exact match to spec, with
zero deviation, including every interrupt that fires during the frame-9-to-44
busy-wait loop this whole thread has been chasing. (Frame 0 prints a spurious
`tstates=348191 isr_pc=0000`, an artifact of `int_ack`/`intack_pending` briefly
seeing a stale combinational state in the few `clk` cycles between `reset`
deasserting and the CPU's first real fetch, before any genuine interrupt has
occurred — not a real event, consistent with the known post-reset startup
transient this testbench already documents elsewhere for `dbg_hpos`/`dbg_vpos`.)

**Conclusion: TV80's IM1 interrupt-acceptance sequence is spec-exact.** The
leading suspect from the previous update — a small T-state miscount in
`IntCycle`, multiplied by ~10 interrupts per loop call into the observed few-
iteration drift — is refuted by direct measurement, not just out-argued by
"MAME is probably more trustworthy." This is a genuine, useful negative
result: it rules out interrupt-acceptance cost as the mechanism and redirects
the search.

### Where the drift most plausibly lives instead

Disassembling the ISR itself (`sim/buckrogn.rom` @ `0x0038`: `JP 0e56`) shows
it is **not** a fixed-cost routine: `0x0e56` pushes AF, then reads and branches
on three RAM flags in sequence (`f834`, `f835`, `f836` — `AND A` / `JP Z,...`
chains), each guarding a further block of code (seen at `0x0e61`, `0x0e72`,
`0x0e9e` and beyond) before eventually popping AF, re-enabling interrupts, and
returning. Its *total* T-state cost is therefore data-dependent, varying frame
to frame with whatever those three flags hold — flags that are plausibly
written by the sub-CPU or by other main-CPU code running earlier in the same
frame. If the exact frame on which any one of those flags first goes non-zero
already differs by even one frame between sim and MAME — for reasons entirely
unrelated to TV80's correctness, e.g. ordinary sub-CPU/main-CPU handshake
timing — the ISR's *length* would differ on that frame, which is exactly the
kind of few-T-state-per-frame nudge needed to explain the observed drift, and
it would do so without implicating TV80 at all.

**Not yet done (next session):**
- Extend the `SIM_DEBUG_TRACE` block to log the three flag bytes (`f834`/
  `f835`/`f836`, work-RAM offsets `0x34`/`0x35`/`0x36`) and the ISR's total
  T-state length (same `int_ack`-to-next-fetch technique, but bounded by the
  ISR's own `RET`/`EI` instead of the fixed int-ack window) once per frame,
  and diff that per-frame ISR-length sequence between sim and MAME (needs a
  matching MAME-side read of the same work-RAM addresses, e.g. via
  `manager.machine.devices[":maincpu"].spaces["program"]:read_u8(0xf834)` in
  `tools/mame/dump_pc_trace.lua`) to find the first frame where ISR length (or
  flag state) disagrees — that pinpoints whichever main-CPU/sub-CPU
  interaction is the actual root cause, distinct from anything in TV80 itself.
- Independently verify the *measurement* isn't the artifact: confirm MAME's
  `emu.register_periodic` callback fires at the same T-state-precise instant
  as `vblank_rise` and not merely "once somewhere near vblank" — this
  investigation has been burned before by trusting an unvalidated probe (see
  the top of this document), and a several-T-state sampling-instant mismatch
  in the *measurement itself* would look identical to a real CPU-side
  divergence in the frames-9-to-44 data collected so far.
- The disassembly and per-opcode spec T-state costs used above are correct for
  the *specific* opcodes involved (`DEC`, `LD r,r`, `OR r`, `JR cc`, `POP`,
  `RET`, and now confirmed `IM1` interrupt-accept); a full opcode-by-opcode
  audit of TV80 against the Zilog tables for *every* opcode Buck Rogers uses
  has not been done and remains a lower-probability but still-open
  possibility if the ISR-flag-timing thread above doesn't pan out.

## UPDATE 2026-07-29 (session 6, continued still further): per-frame ISR-flag diff against MAME finds the game-state divergence directly, and dates it to a coin-input press-vs-release timing mismatch, not a CPU cycle-timing bug

Followed the "not yet done" plan above: added an `ISRFLAGS` probe to
`rtl/z80_3d.v` (same `SIM_DEBUG_TRACE` block) that logs `work_ram[0x34/0x35/
0x36]` (real addresses `0xf834/0xf835/0xf836`) at every `int_ack_rise`, and a
matching read of the same three addresses in `tools/mame/dump_pc_trace.lua`
via `maincpu.spaces["program"]:read_u8()`, once per frame. Also attempted the
other half of the plan — measuring the ISR's *total* T-state length — and hit
a real, informative dead end; see "ISR-length measurement abandoned" below
before the positive result.

### TV80's interrupt-accept T-state count re-confirmed spec-exact

Re-ran the `INTACK_TSTATES` probe from the previous update after these
changes: still `tstates=13` for all 209 real interrupt events across a fresh
210-frame run, zero deviation. No change to that conclusion; recorded here
only because this update's build regenerates the same log.

### ISR-length measurement abandoned: the ISR is (at least sometimes) re-entrant, and a single-level probe can't track that

Tried to measure the ISR's total T-state length by reconstructing the true
return address (not `pc_reg`, which is the address of the *last-fetched*
instruction, not the address `RET` restores — that address is never fetched
before the interrupt pre-empts it, so it's not directly observable) from the
interrupt-ack's own 2-byte PC push: watch `cpu_write` (`~cpu_mreq_n &
~cpu_wr_n`) for the first two write pulses after `int_ack_rise`, since IM1
entry pushes PC-high then PC-low as literal memory writes with nothing else
able to write in between. This correctly reconstructed `return_pc=0x0007` for
frame 1 (matches the disassembly exactly: `0x0004` is `CALL 06F0h`, a 3-byte
instruction, so `0x0007` is the very next instruction (`DI`) — i.e. frame 1's
interrupt landed right at the instruction boundary immediately after that
`CALL` returned, entirely plausible). But the following M1-fetch-matches-
return-PC check never fired even once in 60 frames, and a *second* interrupt
was captured on frame 2 with the exact same `return_pc=0x0007` — meaning a
second interrupt was accepted before the first one's `RET` had run. That's
only possible if the ISR chain re-enables interrupts (`EI`) before it
finishes, which the disassembly is consistent with: the `f834`-nonzero path
pops AF/`EI`s/`RET`s quickly (`0x0e5e`-`0x0e60`), but the observed `f834==0`
path dives past `0x0e61` into deeper code (`0x0e70`'s `PUSH BC/DE/HL` block)
whose own `EI` point hasn't been located. A single-level "watch the push,
watch for the matching return fetch" probe can't handle a re-entrant ISR — it
needs real call-depth tracking, which is out of scope for this pass. Removed
the broken machinery from `rtl/z80_3d.v` rather than leave dead/misleading
code; kept only the working `ISRFLAGS` byte-snapshot, below. (This is itself a
real data point, not just a probe failure: the ISR being structurally capable
of nesting is a plausible independent contributor to frame-to-frame scheduling
differences, separate from anything TV80 does wrong.)

### The positive result: ISRFLAGS diff pinpoints the divergence to coin-input edge timing

Ran both sides for 210 frames and diffed the per-frame `f834/f835/f836`
sequence. Frames 1-9 match exactly in both (a `f835` countdown 4→1 followed by
an `f836` countdown 4→1 — some kind of fixed-duration timer/sound-cue sequence
that fires once, early, unconditionally after reset). Frames 10-91 are flat
zero in both. Then:

- **Sim:** the same `f835: 4,3,2,1` / `f836: 4,3,2,1` sequence re-fires at
  frames **92-99** — 2 frames after `coin_active` goes true (coin1 pulsed
  frames 90-99 in both harnesses' schedules).
- **MAME:** the identical sequence re-fires at frames **101-108** — 1 frame
  *after* `coin_active` goes back false (coin1 released at frame 100).

Same 8-frame shape, same two-stage `f835`-then-`f836` structure, in both — so
this is unambiguously the same game-logic event (the coin-insert sound/counter
sequence) firing in both runs, not two unrelated pieces of code. The two runs
disagree only on *which edge of the coin signal* triggers it: sim reacts while
`in1`'s coin bit is still held active (press-triggered), MAME reacts only
after it's released (release-triggered) — a full 9-frame gap between them.

**This is not an RTL I/O-decode bug.** Checked `rtl/z80_3d.v`'s `in1` path
(`io2_reg <= in1` on the matching port address, `rtl/z80_3d.v` ~line 505): it's
a raw, undebounced level pass-through with no edge logic of any kind — any
debounce/edge-detection here is entirely done in Z80 software (typically:
read the port, XOR against last frame's value, mask the bit), and that
software runs identically regardless of which platform executes it. Since we
already know (from the `PCTRACE` diff two updates back) that sim and MAME are
executing **completely different code** by frame 44-45 — well before coin
insertion at frame 90 — the most likely explanation is that this is a
*downstream symptom* of that earlier divergence, not a second, independent
root cause: whichever attract-mode subroutine happens to be running on frame
90 differs between the two runs (different debounce-counter state, maybe even
different code implementing the debounce at all), so of course the coin
response fires on a different frame. This corroborates the frame-44/45 finding
with an independent, easily-observed signal rather than superseding it.

**Where this leaves the investigation:** the original question — "why does
sim's Z80 diverge from MAME's Z80 by frame 60" — now has a well-evidenced
answer chain: (1) TV80's clock ratio, interrupt cadence, and interrupt-accept
T-state cost are all independently verified correct against ground truth
(video timing math and the Zilog spec, not just "MAME agrees"); (2) despite
that, PC-at-vblank drifts by a handful of T-states across frames 9-44 inside a
disassembled, I/O-free busy-wait loop, for a reason not yet pinned to a
specific instruction; (3) that small drift is enough to flip which video frame
the loop's exit lands on, at frame 44-45, after which the two runs execute
genuinely different code; (4) everything observed afterward, including this
session's coin-response-timing mismatch, is consistent with being downstream
of that one branch-point event rather than a separate bug. The remaining gap
is step (2) specifically: which instruction(s) in that loop or its
surroundings TV80 executes with a different T-state cost than a real Z80. That
audit (opcode-by-opcode against the Zilog tables, for every opcode actually
exercised in frames 1-44, not just the six checked so far) is the next
concrete, scoped piece of work, and is now the *only* open question standing
between "we understand this divergence" and "we understand exactly which line
of TV80 causes it."
