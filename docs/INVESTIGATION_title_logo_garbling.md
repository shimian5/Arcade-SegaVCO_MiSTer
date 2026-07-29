# Title-logo garbling: investigation state

Status as of session end. Branch `worktree-phase0-1a`. **Read the update immediately
below before the rest of this document — it retracts the TL;DR that follows it.**

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
