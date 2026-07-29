# Sega Z80-3D MiSTer Core — Implementation Plan

## Status — 2026-07-28

**Phase 0 done. Phase 1a done** (Buck Rogers `buckrogn` attract-mode text +
background dressing render correctly in simulation) **and hardware-hardened**:
Quartus full compile (synthesis + fit + assembler + TimeQuest) succeeds clean,
0 errors, positive timing slack (+0.356 ns worst-case setup), 20% ALM / 14%
block-memory / 19% RAM-block utilization on the DE10-Nano's 5CSEBA6.
`Arcade-Z80-3D.rbf`/`.sof` build in `output_files/` (gitignored, not
committed — rebuild with `quartus_sh --flow compile Arcade-Z80-3D`). Working
tree is `.claude/worktrees/phase0-1a`, branch `worktree-phase0-1a` — not yet
merged.

**First on-hardware test found a real bug the sim harness structurally could
not catch** (see "MRA ROM-download gap bug" below) — fixed. Awaiting retest.

**Phase 1b done in simulation** (sprite engine): `rtl/video/sprite_engine.v`
implements the 16-entry/8-level sprite RAM, the per-scanline
`prepare_sprites` carry-ALU + Y-scale-PROM FSM, and the per-pixel
`get_sprite_bits` X-scale-accumulator/ROM-fetch/self-termination path, wired
into `rtl/z80_3d.v` (sprite RAM `e400-e7ff`, sprite-position RAM `e000-e3ff`,
8×32KB sprite-ROM banks off the existing `sprites_we`/`sprites_wraddr`,
PR-5196 Y-scale PROM forwarded from the shared PROMS blob) and composited
through an extended mixer (PR-5199 sprite-color-table branch, real
mux/cd priority logic) that now sits ahead of the fg-tier-1 fallback. Verified
in `sim/`: an attract-mode explosion sprite renders, visibly grows across
frames (X/Y-scale zoom working), and is correctly composited over the road
— confirmed by inspecting rendered frames together with the user. Not yet
verified bit-exact against MAME (no frame-diff tooling exists yet — see
"Next step"), not yet synthesized in Quartus. PR-5195 ("sprite state
machine" per its ROM label) has no consumer in MAME's own emulation of this
board — it drives a physical sequencer chip that MAME (and this module)
replicate directly as boolean logic instead of a table lookup — so it's
downloaded as part of the PROMS blob but intentionally unused; see
`sprite_engine.v`'s header comment.

**Background/starfield was missing on purpose through phase 1b** — Buck Rogers'
`bitmap_ram` "star" layer and `bgcolorrom` lookup (the last two branches of
`mixer_buckrog.v`'s priority chain) are driven by the **sub CPU**
(`bitmap_w`), which wasn't implemented yet at that point. That was phase 1c
scope (sub CPU + bitmap + bgcolor + full priority chain). **Phase 1c is now
done in simulation** — see below.

**Phase 1c done in simulation** (sub CPU + bitmap/starfield + bgcolor + full
mixer priority chain): `rtl/io/i8255.v` (generic mode-0 PPI, including BSR
bit-set/reset mode) and `rtl/io/i8279.v` (minimal, DSW1-via-RL only) are new;
`rtl/z80_3d.v` gained a second `cpu_z80` instance (the sub CPU, sharing the
main CPU's `ce_z80`), the sub program ROM / mirrored work RAM / bitmap RAM
(`bitmap_w`: `0000-dfff` write, `y=addr>>8`/`x=addr&0xff`), PPI0 (`c800-c803`)
and PPI1 (`d000-d003`) wired for real (replacing the `8'hFF`/dropped-write
stubs), i8279 (`d800-d801`), real IN0/IN1/DSW reads (`e800-e803`, wired from
`Arcade-Z80-3D.sv`'s hps_io joystick/OSD machinery), a registered-read
`bgcolorrom` BRAM off the shared road/bgcolor download slot, and the mixer's
remaining two branches (star, bgcolor) plus the real fg-tier-2 gate. The
main↔sub protocol is exactly the plan's three-step version (command register
= PPI0 port A, `/INT` = PPI0 port C bit 7 directly, ACK = a dedicated flag
overriding port C bit 6's readback) — MAME's `delayed_i8255_w`/600 Hz-quantum
scheduling was **not** reproduced, per the plan (no hardware analogue).
Verified in `sim/`: `tb_z80_3d.cpp` now drives real IN0/IN1 and pulses
coin-in then start1; the core boots, coins up, and reaches actual gameplay
(HUD "TIME LEFT"/"UFO COUNT" bars, an enemy ship, the road scrolling) with a
correct-looking gradient sky, scattered starfield, and road/tunnel dressing —
confirmed by direct comparison against real headless-MAME reference frames
(`tools/mame/dump_frames.lua`, `mame.exe buckrogn -video none`, coin/start
pulsed via the Lua ioport API). Not yet synthesized-and-fitted end-to-end on
real hardware; a synthesis-only Quartus pass (`quartus_map`) succeeds clean,
0 errors, 1372 RAM segments inferred (up from 939 in phase 1b, consistent
with the two new PPIs/i8279/sub-CPU memories/bgcolor ROM).

Three real bugs found and fixed during phase 1c bring-up, all instructive
about the "trust the hardware, not MAME's C++ shortcuts" principle above:

1. **i8255 reset state.** A real 8255 powers up with its control word at
   0x9B (all ports in **input mode**) — nothing drives the output pins until
   firmware configures and writes them, so a physical net left undriven
   sits at its pulled-up idle level. The first RTL draft reset the internal
   port-C output latch to `0x00`, and since `sub_int_n` taps that latch
   directly (`= ppi0_pc[7]`), this asserted the sub CPU's `/INT` from the
   instant of reset, before the main CPU ever touched PPI0. The sub CPU
   spun forever re-servicing a phantom interrupt and never ran its real
   program — no bitmap writes, no sprite RAM content past the initial
   POST-clear pass. Fixed by resetting the output latches to `0xFF` (idle
   high, this project's standard idle-bus convention) instead of `0x00`.
2. **8255 BSR mode not implemented.** Also found (and fixed) while chasing
   bug 1: the first `i8255.v` draft only implemented the mode-set control
   word and silently ignored BSR (bit set/reset) writes, control-register
   writes with D7=0 that toggle a single port-C output bit — the standard
   real-8255 idiom for a single control line like `/INT`, and (per the
   trace evidence) what this ROM's firmware actually uses. Implemented:
   `pc[din[3:1]] <= din[0]` on a BSR write.
3. **Palette-address truncation + bgcolor-ROM download aliasing**, found
   by directly comparing rendered frames against real headless-MAME output
   (`tools/mame/dump_frames.lua`) after bug 1/2 fixed sprites/stars but the
   sky was still a flat, wrong-hued fill instead of MAME's dark-to-light
   gradient:
   - `repack_bg()`'s shifts genuinely overflow 8 bits in MAME's C++ (`int
     palbits`) — Buck Rogers' palette is 1024 entries (10-bit index), and
     the bgcolor branch's overflow is *how* it reaches the upper 3/4 of the
     palette (the other three branches all happen to stay under 256). The
     RTL had `palbits` truncated to 8 bits with the palette address's top 2
     bits forced to `00`, silently routing every bgcolor pixel to the wrong
     bank. Fixed by widening `palbits`/`repack_bg` to 10 bits end to end.
   - Separately, `bgcolorrom` (8192 entries) was fed `road_wraddr[12:0]`
     with no range gate, but `road_wraddr` spans the *full* 32KB shared
     road/bgcolor download slot — Buck Rogers' real bgcolor ROM only fills
     the first 8KB of it, the rest is `0xFF` filler
     (`sim/build_rom.py`'s blob-fill default, standing in for "no ROM chip
     here" on real hardware). Truncating to 13 bits aliased those filler
     writes back onto the same 8192 entries, and since they arrive *later*
     in the sequential download stream, they silently overwrote every real
     byte with `0xFF`. Fixed by gating the write on `road_wraddr < 0x2000`,
     the same range-gated-forwarding idiom already used for
     `xshift_we`/`proms_is_colortab` elsewhere in this file.

**Star-density open item: root-caused and fixed (2026-07-29).** The gap
traced to the TV80 clocking bug flagged below ("Known simplification"), not
to game-state pacing or a bitmap-refresh bug: `rtl/cpu_z80.v`'s sim path
instantiated `tv80s`, whose internal `cen` is hardwired to 1 (confirmed
against the tv80 repo's own testbench) — both Z80 CPUs ran at the full
39.936 MHz core clock in sim instead of the correct 4.992 MHz (core_clk/8),
~8x too fast relative to video. Since the sub CPU's star/HUD-bar drawing is
paced by real elapsed time (vblank-relative), this desynced its output from
what the same number of *video frames* would produce on real hardware.
Fixed by instantiating `tv80_core` directly (it exposes a real `cen` port;
its FSM genuinely gates on it internally — confirmed in
`tv80_core.v`/`ClkEn = cen && ~BusAck`) with the bus-decode logic ported
verbatim from `tv80s.v`, driven by the same `ce_z80` (core_clk/8) already
used for T80. `sim/tb_z80_3d.cpp`'s coin/start pulse timing (previously
tuned empirically around the 8x-fast bug) was updated to match
`tools/mame/dump_frames.lua`'s real schedule exactly (coin 90-99, start
150-159), and default frame count raised to 410 to reach the same
post-start1 point MAME's reference snapshot uses (frame 400). Verified: a
30-frame MAME window (`tools/mame/dump_frames_range.lua`, frames 380-409)
gives a stable star-color-pixel baseline of ~599-610/frame (excluding a few
outlier frames with an unrelated bright explosion sprite); sim's equivalent
window is now in the same range, vs. wildly different pre-fix behavior
(matched MAME's attract-mode count almost exactly by coincidence, then
diverged sharply once gameplay started). Also fixed a real bug in the
`SIM_DEBUG_TRACE` counters (`dbg_tier1/sprite/tier2/star/bg` in
`rtl/z80_3d.v` were never reset per-frame, unlike their sibling counters —
made them cumulative-since-t=0 instead of per-frame, misleading for exactly
this kind of density comparison).

**New open item found while re-verifying visuals post-fix (2026-07-29,
NOT yet root-caused):** the title-logo screen ("BUCK ROGERS / PLANET OF
ZOOM", shown right at the start1 pulse, ~frame 150) renders badly garbled/
illegible in sim — letters bleed together with jagged color noise —
confirmed against a matched MAME reference frame
(`tools/mame/dump_frames_logo.lua`, frames 130-170) which shows it crisp
and clean. By contrast, a simple solid-color sprite (the gameplay "TIME
LEFT" bar, frame 399) renders correctly with zero pixel-level defects
(verified by exact color-run scan, not just eyeballing). That contrast
(simple solid-color sprite fine, complex multi-color artwork garbled)
points at something specific to multi-level/multi-color sprite compositing
in `sprite_engine.v` or `mixer_buckrog.v` — e.g. cross-level timing sync,
or wrong sprite-RAM-entry selection when multiple logo pieces have to share
one of the 8 hardware "levels" across different scanlines (only 16 sprite-
RAM entries fold onto 8 levels; entries 8-15 overwrite 0-7 for the same
level, "second half wins" per-scanline). Also reported (separately, not yet
re-verified against current code): a possibly-related distortion on an
in-game UFO/ship sprite, from an older pre-clocking-fix capture — re-check
this once the logo bug is understood, it may be the same root cause or may
already be fixed.

**Logo bug investigation, session 2026-07-29: several suspects ruled out,
root cause still open.** Instrumented `sprite_engine.v` with temporary
hierarchical `$display` probes (via `u_sprites.*` from `z80_3d.v`'s existing
`` `ifdef SIM_DEBUG_TRACE `` block, since forced with a Makefile-local
`+define+SIM_DEBUG_TRACE`; reverted afterward, not committed) and traced
frame 150's logo scanlines directly:

- Only **one sprite entry (idx=2, level=2)** ever commits during the whole
  logo Y-span (vpos 77-142+) — the logo art is a single wide multi-color
  sprite object on one hardware level, not multiple objects sharing levels.
  This rules out the "second-half-wins"/cross-entry-conflict theory entirely
  for this bug (there's no second entry to conflict with).
- Extracted the raw fetch address/byte sequence for level 2 at vpos=100
  (hpos 100-179) and diffed it byte-for-byte against the actual assembled
  ROM blob at the corresponding address (bank 2 = `sprites_base + 0x10000`,
  offset from the committed per-scanline `offset` register). **Bit-exact
  match, zero divergence** — the offset/frac accumulator, nibble
  high/low selection, and ROM addressing are reading the *exact* intended
  byte stream in order. This rules out an addressing/fetch-cadence bug in
  `get_sprite_bits`'s real-time path.
- Dumped the full per-scanline Y-scale/rowbytes commit trail for level 2
  (`y_lo`/`y_hi`/`yscale`/rowbytes bytes, the `writeback` decision, and the
  resulting `new_offset`) across the whole logo span: rowbytes is a
  constant 0x40/line, the writeback PROM test skips exactly 1 line in 5
  (an intentional 4:5 vertical compression), and the offset accumulates
  smoothly with no discontinuity or reset anywhere in the range. This rules
  out an accumulated Y-scale drift/skew theory.
- Verified the mixer's `sprite_expand`/`plb_end` bit layout, the
  `find_lsb`/`countl_zero` priority encoder, the `cd` bit-extraction
  (`bitswap<4>(sprbits>>mux,24,16,8,0)`), and the `sprcolor_table` address
  (`{obch,mux,cd}`) all match `docs/reference/turbo_v.cpp`'s
  `buckrog_state::get_sprite_bits`/`screen_update` line-for-line. Also
  reconfirmed the sprite ROM MRA region (`tools/gen_mra.py`'s `"sprites"`
  list, offsets like `0x08000`/`0x10000`/...) already gets correctly
  gap-filled to 32KB/bank boundaries by `region_blob()` — not a re-run of
  the earlier MRA-gap bug class.
- A crude row-by-row color-run comparison against the MAME reference
  (`ar_mame_logo.png`, aspect-corrected) shows large solid-color regions
  (e.g. the lower "SEGA"/ribbon band around native vpos~130) line up
  reasonably well in shape and width, while the fine-detail letter rows
  (vpos~90-120) show a lot of small-run color noise and what looked like a
  consistent ~2-pixel rightward start-column shift in sim vs. MAME at
  several rows — **not yet confirmed as a real, isolated offset** (could be
  an artifact of comparing frames from slightly different game states: the
  sim capture still shows the attract-mode "SPEED:" HUD text, while
  `ar_mame_logo.png` shows "CREDIT  1", so a credit had already been
  inserted for that MAME capture — these may not be exactly the same
  underlying frame content and the two should be re-captured from truly
  matching game states before trusting a pixel-position diff further).

**Superseded.** The X-shift / sprite-position-RAM (`he`) next steps listed
above were followed up in the next session and the `he`/`sprpos` path came
out **clean** (traced bank split, one-column prefetch, hpos 639→0 wrap).

**Logo bug, current state (session interrupted by reboot 2026-07-29) — read
`docs/INVESTIGATION_title_logo_garbling.md` before resuming; it is the
authoritative status and it changes the prime suspect.** Summary:

- **New prime suspect: CPU sprite-RAM write timing, not the sprite engine.**
  At the start of the visible logo frame all 16 sprite slots are disabled
  (`y_lo=00`/`y_hi=ff` ⇒ MAME's enable ALU yields 0); by the last HBLANK of
  the same frame slots 7/8/9/13 hold real data written by the CPU. So the
  CPU programs sprite RAM *during active display*. Our engine reads sprite
  RAM live per scanline (as hardware does) while MAME renders the whole
  frame once at `screen_update` from end-of-frame RAM — so MAME is blind to
  write timing and we are not. Symptom fits exactly: right position, right
  size, scrambled interior.
- **Consequence:** the sprite co-sim harness built that session
  (`sim/golden_buckrog.py`, `sim/compare_spr.py`, `--dumpframe`, debug dump
  ports — all uncommitted, all worth keeping) was fed a start-of-frame
  snapshot, so the golden model rendered an *empty* frame. Its "18,812
  mismatching pixels at y=82" result and the conclusion blaming
  `get_sprite_bits`/`he`/`lst` carry **no diagnostic weight**. Fix before
  reuse: drive the golden model from a *timestamped* `(vpos, addr, data)`
  write trace, replayed per scanline, not a snapshot.
- **One real RTL bug found (uncommitted fix pending):**
  `sprite_engine.v`'s `y_target` is `[7:0]` but `VTOTAL=264` needs 9 bits,
  so `vpos[7:0]+1` wraps at 255 and `prepare_sprites` re-runs 9 spurious
  times per frame during VBLANK lines 256-262, each able to advance every
  enabled sprite's `offset` writeback. Currently **latent** (nothing is
  enabled on those lines in the captured frame) — fixing it probably does
  not fix the logo. Raises an open schematic question: does hardware run
  `prepare_sprites` during VBLANK at all? (`BLANK` into the per-level LS109
  network, EPROM bd sheet 3, PDF p.37 — MAME cannot answer this.)
- **Ruled out, do not re-investigate without new evidence:** cross-level
  conflicts, fetch/addressing, Y-scale accumulation, mixer bit layout,
  horizontal-enable / sprite-position path, `prepare_sprites` FSM + carry
  ALU + PR-5196 addressing, MUX/priority/palette chain, accumulator cadence
  being 2× off, a hidden ÷2 between VCO and pixel counter, and the VCO
  analogue model being a MAME fabrication.
- **Schematic reading (`docs/reference/VCO_schematic_findings.md`,
  uncommitted, two sessions' worth):** VCO confirmed SN74LS626 ×4 = 8
  independent oscillators, 220 pF on all 8, and every resistor in MAME's
  CV formula traced (R2=2.2K, R7=1.5K, R3=1K, VR1=R5=1.2K, VR2=R6=820Ω,
  fixed not trimpots) — MAME's model is schematic-backed, keep it. `END`
  confirmed **data-derived** (IC39 74LS20 NAND on CDA-CDD ⇒ `pixdata==15`),
  exactly matching MAME — clean negative, no RTL change. `CLKn` directly
  clocks the LS191 chain, no divider. **Still open:** the LS157
  nibble-select XOR (IC23) — input pin 13 confirmed to be `CW15`, the
  counter's own up/down direction feedback, but pin 12 unresolved, plus a
  flagged contradiction that `CW0` appears wired straight to ROM `A0`; and
  the LS109 gating/VCO-phase-reset semantics (§8.2). Exact next-step crop
  commands are recorded in §7.4, §7.5, §7.6 and §8.2 of that doc.
- **Cosmetic/latent, fix after the real bug:** `rtl/z80_3d.v:521-632` mixer
  pipeline free-runs on `clk` not `ce_pix`, so `SPR_TO_MIX_DELAY`/
  `COORD_DELAY`/`VIDEO_PIPE_LATENCY` are core clocks, not pixels (depths
  mutually consistent, so sub-pixel offset only — but the comments lie).
  `tools/gen_tables.py` R4 is silkscreened 3.9K, MAME hardcodes 3.8e3.

**Immediate next step:** log `vpos`/`hpos` of every `cpu_sprram_we` /
`cpu_sprpos_we` for one frame, do the same in MAME via a sprite-RAM write
tap + `screen:vpos()`, and compare. If MAME writes in VBLANK and we write
mid-frame → the bug is CPU/interrupt timing (Z80 clock divider, VBLANK IRQ
assert/clear, the `WAIT` sync in `Buck_theory.txt` p.70-71, or residual TV80
clocking, cf. 529d7ae). If MAME *also* writes mid-frame, our live-read
engine is the more correct one and the reference image itself is suspect —
re-baseline and say so.

| Item | State |
|---|---|
| `tools/gen_tables.py` | done — X-scale + palette tables, self-checks, MAME golden diff |
| `roms/xscale_{turbo,buckrog}.hex` | generated, 256 × Q8.24 |
| `roms/palette_{turbo,buckrog}.hex` | generated; **bit-exact vs MAME**, all 1280 entries |
| `tools/render_sheets.py` | done — renders schematic PDF pages to PNG |
| `tools/mame/dump_palette.lua` | done — headless palette dump for the golden diff |
| `tools/mame/dump_frames.lua` | done (phase 1c) — headless MAME PNG snapshots with scripted coin/start, used for the phase 1c visual comparison above |
| `docs/hardware-audio.md` | done — full sound board trace |
| `docs/reference/Buck_theory.txt` | added — official theory-of-operation text; confirms the 8-level/EPROM-board sprite architecture, no new pinout-level detail |
| `docs/schematics/` | sound sheets 1-3 + assembly drawing rendered at 400 dpi |
| `mra/{buckrogn,buckrog,turbo}.mra` | done — `tools/gen_mra.py`, all CRCs verified byte-for-byte against the real MAME zips |
| MiSTer template scaffolding (`sys/`, `Arcade-Z80-3D.{sv,qpf,qsf,sdc,srf}`, `files.qip`) | done — pulled as-is from `C:\MiSTerDev\Template_MiSTer`; `sys/` untouched |
| `rtl/T80/` | done — Sorgelig's T80 v350, vendored (plain files, not a submodule) from `Arcade-DonkeyKong_MiSTer`, for real synthesis |
| `rtl/tv80/` | done — hutch31/tv80 (pure Verilog Z80), vendored from `SuperOffRoad_MiSTer`, **simulation only** |
| `rtl/cpu_z80.v` | done — wraps T80 (synthesis) / TV80 (Verilator sim) behind one interface |
| `rtl/rom_download.v`, `rtl/video/video_timing.v`, `rtl/video/fg_tilemap.v`, `rtl/z80_3d.v` | done — phase 1a scope (see below) |
| `rtl/video/sprite_engine.v` | done in sim (phase 1b) — see above; not synthesized yet |
| `rtl/io/i8255.v`, `rtl/io/i8279.v` | done (phase 1c) — see above |
| `sim/` Verilator harness | done — see "Sim harness" below; now also builds `rtl/video/sprite_engine.v`, `rtl/io/i8255.v`, `rtl/io/i8279.v`, and drives real IN0/IN1/DSW + coin/start stimulus |
| Phase 1c (sub CPU/bitmap/full mixer) | done in sim, not synthesized end-to-end on real hardware (see above) |
| Phase 1d (`315-5014` decryption), phase 3 (Turbo) | not started |

**Phase 1a scope, what's real vs. stubbed:**

Main CPU (T80/TV80) executes the real `buckrogn` program ROM, decodes the
`main_prg_map` (ROM, video RAM, work RAM), and drives the fg tilemap
(`fg_tilemap.v`, PR-5194 X-shift PROM included) through a phase-1a-only inline
version of `mixer_buckrog.v`'s fg-tier-1 path (PR-5198 char color table +
`repack()` + the real 1024-entry palette ROM). PPI0/PPI1/i8279/sprite
RAM/sprite-position RAM/IN0/IN1/DSW are **stubbed** (reads return `8'hFF`,
writes dropped) — sub CPU, bitmap, bgcolor, sprite engine, and the full
5-level mixer priority chain are not implemented yet (phases 1b/1c). Despite
the stubs, the real CPU reaches and renders the attract screen: verified
visually in `sim/out/` — the "SEGA" copyright text is legible, along with the
road/tunnel dressing and ship-lives icons (all fg-tilemap content).

**Hardware-hardening pass (done, post phase-1a):**

1. `fg_tilemap.v` and `z80_3d.v`'s memory reads (VRAM, tile ROM, X-shift/
   color-table PROMs, main program ROM, work RAM, palette ROM) were
   combinational array reads — fine for sim, but not synthesizable as
   single-cycle BRAM (Quartus was going to have to build a giant
   combinational mux, worst for the 32 KB program ROM). **Fixed**: all of
   these are now registered (synchronous) reads. No Z80 wait-state handling
   was needed for the CPU-side reads — `cpu_a` is held stable for the whole
   Z80 T-state (many core-clk cycles, since `ce_z80` only pulses once every
   8), far longer than the 1-cycle registration latency, so the registered
   value is always correct well before the CPU's next sample point. The
   video-side reads form a real fixed-depth pipeline instead (`fg_tilemap`'s
   4-stage tile fetch + 1 cycle for the color-table lookup + 1 cycle for the
   palette lookup = 6 cycles total); `z80_3d.v` delay-matches
   hblank/vblank/hsync/vsync/ce_pix through a 6-stage shift register so the
   sync bundle output stays aligned with the pixel data it describes.
   Verified in `sim/`: re-rendered the same attract frame post-pipelining,
   pixel-identical to the pre-pipeline version. Confirmed in Quartus too —
   Analysis & Synthesis reports 939 RAM segments inferred (`altsyncram`
   blocks), not combinational logic.
2. `pll.v` reconfigured for the 39.936 MHz core clock. The exact value isn't
   representable from the 50 MHz reference (39,936,000 Hz reduces to the
   coprime fraction 2496/3125 — no small-integer PLL ratio hits it), so
   `rtl/pll/pll_0002.v` targets Quartus's nearest **exactly legal** PLL
   setting instead, which the fitter itself reports: **39,935,064 Hz, ~23
   ppm low**. That's tighter than a real crystal's own tolerance and not a
   meaningful error. (First attempt used the rounded string `"39.936000
   MHz"`, which the fitter rejected outright — Quartus's PLL solver needs a
   frequency it can hit exactly, not merely close; it reports the nearest
   legal value in the error message.)
3. `pll`'s `locked` output was briefly wired into the top-level `reset`, then
   pulled back out (see "First on-hardware test" below) — untested-on-real-
   silicon logic added the same session as an on-hardware failure is exactly
   the wrong thing to leave in while isolating that failure. Re-add once the
   MRA fix below is confirmed to be the actual/whole story.

**First on-hardware test: MRA ROM-download gap bug (found and fixed).**

First DE10-Nano test came back showing a flat, uniform background fill with
no attract text — the flat color matched what character-code-0's tile
renders as with real ROM data (confirmed by reproducing the identical
pattern in an early, broken sim run where VRAM was never written but PROMs
still loaded), so the read was "CPU isn't producing real graphics," not "ROM
never loaded at all." Removing the `pll_locked`-gates-reset wiring (the only
other untested-on-hardware change) didn't fix it, which prompted a full
audit of the MRA against `rom_download.v`'s decode.

Found two real bugs in `tools/gen_mra.py`, both invisible to every test run
so far because `sim/build_rom.py` writes each ROM region directly at its
`REGIONS` offset into a pre-allocated buffer — immune to stream-order bugs
that only matter for the real sequential MRA byte stream:

1. **`"road"`/`"bgcolor"` double-emission.** They're mutually-exclusive
   alternatives sharing one address slot (Turbo's road generator vs. Buck
   Rogers' bgcolor), but the emission loop iterated both names
   independently: for `buckrogn` (which only defines `"bgcolor"`), it
   emitted a full-size filler for the absent `"road"` entry, then the real
   `"bgcolor"` data right after — doubling that slot and shifting every
   region after it (all of `"sprites"`) later in the stream. Fixed by
   collapsing them into one slot in the emission loop, picking whichever of
   the two names the game actually defines.
2. **Non-contiguous `REGIONS` base offsets (the real culprit).** The
   original offsets (`0x00A000`/`0x00C000`/`0x00E000`/`0x016000`) were
   picked as "nice round hex numbers" without checking they actually tile
   with the preceding region's size — there was a 4KB gap after `fgtiles`
   and another after `road`/`bgcolor`. The MRA generator emits `<part>`
   elements strictly back-to-back with **no** inter-region padding (MRA is
   a sequential byte stream, not an addressed one), so the real data is
   naturally contiguous — but `rom_download.v`'s decode used the gapped
   absolute offsets. Everything from PROMS onward (critically PR-5194, the
   X-shift PROM every fg-tilemap column lookup depends on) arrived at the
   wrong `ioctl_addr` window on real hardware and was silently dropped.
   Fixed by recomputing `REGIONS` as genuinely contiguous
   (`maincpu` 0x000000 / `subcpu` 0x008000 / `fgtiles` 0x00A000 / `proms`
   0x00B000 / `road`+`bgcolor` 0x00D000 / `sprites` 0x015000, total
   `0x055000`) and mirroring the same offsets in `rom_download.v`. Also
   replaced `rom_download.v`'s address subtraction (which sliced the
   *operands* before subtracting — only correct when BASE happens to be a
   round number in that field's bit width, true by luck for the old offsets
   but not guaranteed going forward) with full-width subtraction sliced
   *after*.

Added `tools/verify_mra_stream.py` as a permanent regression check: builds
the ROM blob two independent ways (parsing the actual generated MRA's
`<part>` stream in file order vs. `sim/build_rom.py`'s absolute-offset
writes) and asserts they're byte-identical. This is exactly the check that
would have caught the bug before it ever reached hardware — run it after any
`REGIONS`/MRA change. All three games pass post-fix.

**TV80 cen/clocking simplification: fixed (2026-07-29).** `cpu_z80.v`'s TV80
(simulation-only) path used to run the CPU at the full core clock,
undivided — TV80's `tv80s.v` wrapper ties its internal `cen` permanently to
1 (no usable clock-enable input; confirmed against the tv80 repo's own
reference testbench, which does the same), so sim ran the CPU ~8x faster
relative to video than real hardware. This turned out not to be a benign
simplification — it was the root cause of the star-density mismatch (see
above). Fixed by instantiating `tv80_core` directly instead of `tv80s`
(it exposes a real `cen` port and genuinely gates its internal FSM on it)
with `tv80s.v`'s bus-decode logic ported over unchanged. T80 (real
synthesis target) was never affected — it takes a genuine `CEN`
clock-enable.

ROM download map's PROMS slot was bumped from the original draft's 4 KB to
8 KB (Turbo's `proms` ROM_REGION is 4128 bytes, just over 4 KB) — see the
updated "ROM loading" table below. `tools/gen_mra.py`'s `REGIONS` dict is
the source of truth; keep `rom_download.v` in sync with it by hand.

**Sim harness (`sim/`):**

Verilator (5.050) is **not available natively on Windows** in this
environment, and cannot compile T80's VHDL regardless. It **is** installed in
the `archlinux` WSL2 distro, so the harness is designed to run there:
`wsl -d archlinux -e make -C sim run` (from the repo root; see `sim/Makefile`
for exact paths, since `cd` and `wsl` invocations here go through PowerShell,
not the WSL shell directly). `sim/build_rom.py` builds the flat ioctl-download
ROM blob straight from the real MAME zips (matched by CRC32, since MAME's zip
entry filenames don't match the ROM_LOAD part names), reusing
`tools/gen_mra.py`'s region tables so both stay in sync automatically.
`sim/tb_z80_3d.cpp` drives `rtl/z80_3d.v` directly (not the full
`Arcade-Z80-3D.sv`/`sys/` framework top, which needs real PLL/HPS hardware
this environment can't simulate), streams the ROM blob in over `ioctl_*`,
and dumps one 512x224 PPM per frame — ready for `sim/out/*.ppm` vs.
`mame buckrogn -snapshot` diffing once phase 1b needs bit-exactness.
`z80_3d.v` has an opt-in `` `ifdef SIM_DEBUG_TRACE `` block (instruction-fetch
and VRAM-write tracing) used to debug the TV80 clock-gating bug above; harmless
to leave in, off by default.

**Environment, verified working:**

- MAME at `C:\MiSTerDev\mame` (`mame.exe`, plus `nltool`/`nlwav` for the audio phase).
- ROM sets present and `-verifyroms` clean: `buckrog`, `buckrogn`, `buckrogn2`,
  `zoom909`, `turbo`, `turboa`-`turboe`, `turbobl`. Subroc-3D is absent (out of scope).
- Headless MAME reference runs work:
  `mame.exe buckrogn -video none -sound none -autoboot_script <lua> -str 5`
- Python has `pypdfium2` + `Pillow`. Poppler/`pdftoppm` is **not** installed, so the
  Read tool cannot rasterize PDFs — use `tools/render_sheets.py`.
- Verilator 5.050 is available in the `archlinux` WSL2 distro (`wsl -d archlinux`),
  not natively on Windows. GHDL/Icarus are not installed anywhere.
- ModelSim (Altera Starter Edition, via the Quartus 17.0 install) is also available
  and is what `SuperOffRoad_MiSTer/sim/` actually uses for VHDL+Verilog cosimulation
  — a fallback path if the Verilator+TV80 approach above ever becomes a bottleneck.

**Findings that changed the plan:**

- Max X-scale step is **0.566** (Turbo) / **0.259** (Buck Rogers) source pixels per
  output pixel — comfortably under 1.0. This confirms the memory architecture: one
  sprite-ROM fetch per level per output pixel, so 8 independent BRAMs with no
  arbitration. Sprites are always magnified, never minified. At native 1× horizontal
  Turbo would reach 1.13, which is exactly why `TURBO_X_SCALE = 2` exists.
- Turbo's blue channel tops out at **247**, not 255 — its ladder has 2 resistors where
  red/green have 3, and MAME's autoscale uses one global factor from the largest net.
  Confirmed correct against MAME. Do not "fix" this.

**Next step:** phase 1c is done in sim (see above) but not yet hardware-
hardened or fully bit-exact. Star density and the TV80 clocking bug are
now fixed (2026-07-29, see above); a new sprite/mixer corruption bug
(garbled title logo) was found while re-verifying visuals post-fix. Before
starting phase 1d, in rough priority order:

1. **Root-cause and fix the garbled title-logo sprite bug** (new, see
   above) — multi-color/multi-level sprite compositing is suspect
   (`sprite_engine.v` and/or `mixer_buckrog.v`); a simple solid-color
   sprite (HUD bar) renders correctly, so this isn't a wholesale sprite-
   engine failure. Also re-check the previously-reported UFO/ship sprite
   distortion once this is understood (that report predates the clocking
   fix, may be the same bug or may already be resolved).
2. Build real frame-diff tooling (`sim/*.ppm` vs. `mame buckrogn -snapshot`,
   pixel-diffed, not eyeballed) and get the sprite engine (phase 1b) and
   full mixer (phase 1c) to bit-exact, not just visually-plausible-and-
   matching-MAME-by-eye.
3. Hardware-harden phase 1c the same way phase 1a was: a Quartus
   synthesis-only pass already succeeds clean (1372 RAM segments, 0
   errors — see above), but a full fit + TimeQuest + DE10-Nano retest
   hasn't happened yet, and the two real bugs found by comparing against
   MAME in sim (see above) are a strong reminder that "synthesizes clean"
   and "correct" are different claims.
5. Only then phase 1d (`315-5014` decryption).

## Context

`C:\MiSTerDev\Arcade-Z80-3D_MiSTer` currently contains only `docs/reference` (MAME driver
sources `turbo.cpp` / `turbo_v.cpp` / `turbo_a.cpp` / `turbo.h` / `resnet.h`, plus
`Turbo_Schematics.pdf` and `Buck_Schematics.pdf`). There is no MiSTer core for Sega's
Z80-3D board family — **Turbo** (1981), **Subroc-3D** (1982) and **Buck Rogers: Planet
of Zoom / Zoom 909** (1982). The goal is one FPGA core targeting the DE10-Nano, built
in stages around the single video/sprite architecture all these boards share.

**Reference-source priority**: this core's goal is to be a faithful reimplementation of
the *real hardware*, not a port of MAME. When a question arises about how something
actually behaves — chip reset states, interrupt polarity, timing, bus contention, address
decode — **the schematics and the theory-of-operation manual
(`docs/reference/Buck_Schematics.pdf`, `docs/reference/Buck_theory.txt`, and the Turbo
equivalents) are the primary reference, not MAME's driver source.** MAME's C++ is a
software *behavioral* model built to reproduce the *outward result*, and it routinely
takes shortcuts that are invisible from the outside but wrong as a hardware description —
e.g. it initializes its i8255 model's output-latch state directly rather than modeling
the chip's real power-on reset (control word 0x9B, all ports default to input/undriven
until firmware configures them), which caused a real bug here: an RTL i8255 that reset
its port-C latch to 0x00 instead of "undriven/idle-high" asserted the sub-CPU's `/INT`
line from the instant of reset, before the main CPU ever touched the chip, and the sub
CPU spun forever re-servicing a phantom interrupt instead of running its real program
(see "Phase 1c" below). Use `docs/reference/turbo.cpp`/`turbo_v.cpp`/`turbo_a.cpp` for
memory maps, bit-for-bit formulas, and PROM semantics (they're accurate and save a lot of
schematic-tracing time for that kind of detail) — but treat MAME as **a check against
behavior**, confirming the RTL produces the right outward result, not as the source of
truth for *why* or *how* real hardware gets there. When the two disagree on a matter of
hardware truth (chip reset behavior, signal polarity, timing margins), trust the
schematic/datasheet.

Decisions already made:

- **Scope**: **Buck Rogers first** (no road generator, flat if/else priority chain,
  simple bitmap background), then **Turbo**. **Subroc-3D is out of scope for now** — it
  is an active-shutter stereoscopic game and there is no way to test it properly on
  hand. The sprite engine is still designed to accommodate it so it can be added later
  at low cost.
- **Audio**: **discrete netlist, not samples.** `Buck_Schematics.pdf` contains the full
  Buck Rogers sound board schematic (Gremlin/Sega drawing **834-5122**, 3 sheets, dated
  12-9-82, printed pages 191-193 = **PDF pages 45-47**), so the real circuit can be
  modeled directly rather than approximated with WAV playback. This also keeps SDRAM
  out of the design entirely. Audio work happens **after** video is playable.
- **Audio modeling style**: fixed-point DSP at an audio-rate clock enable (~48-192 kHz)
  — each 555 / op-amp / RC / VCA block becomes a discrete-time filter or oscillator.
  Standard MiSTer practice (Donkey Kong, Galaxian); cheap, tunable, accurate enough.
- **Base**: fresh from the standard MiSTer Arcade template + `sys/` submodule, T80 CPU.
- **Target/flow**: DE10-Nano (Cyclone V), Quartus 17.0.x, verified against MAME.
- **Packaging**: **one core**, with the game selected by the MRA. A game-ID strap
  enables either Turbo's road generator + bit-serial mixer or Buck Rogers' bitmap +
  bgcolor path; the sprite engine, tilemap, PPIs and video timing stay literally shared.
- **Deliverables location**: this plan and all collateral it produces (notes, extracted
  schematic renders, generated tables, design docs) live in
  `C:\MiSTerDev\Arcade-Z80-3D_MiSTer\docs`.

The single most important architectural fact from the research: **all these games share
one sprite generator** — 16 sprite-RAM entries × 8 bytes, mapped onto 8 hardware
"levels" (channels), each level with its own private sprite-ROM bank, a Q8.24
fractional horizontal-scale accumulator, and self-terminating ROM pattern data. Get
that engine right once and most of each remaining game is done.

---

## Target hardware model (shared by both games)

### Clocking

| Signal | Rate | Derivation |
|---|---|---|
| Master | 19.968 MHz | XTAL |
| Core clock | 39.936 MHz | PLL from `clk_50` (2× master) — gives 4 cycles of headroom per pixel |
| Pixel CE | 9.984 MHz | ÷4 — MAME's `PIXEL_CLOCK` (`MASTER_CLOCK/4 * TURBO_X_SCALE`) |
| Z80 CE | 4.992 MHz | ÷8 (`MASTER_CLOCK/4`) |

**Run the video pipeline at 2× horizontal (`TURBO_X_SCALE = 2`), same as MAME.**
Real hardware scales sprites in the analog domain with a VCO; MAME approximates it with
a doubled pixel grid, and matching that makes pixel-exact comparison against MAME
possible. Timing: HTOTAL 640, HBSTART 512, VTOTAL 264, VBSTART 224 → 512×224 active at
**59.09 Hz**. Set MiSTer aspect ratio to 4:3 (pixels are 2:1). Note in the README that
this is an intentional deviation from the board's native 320×264.

Screen rotation: Buck Rogers `ROT0`, Turbo `ROT270` — Turbo needs MiSTer's rotate
support (`screen_rotate.v` from sys, which uses the DDR3 framebuffer, not SDRAM).

### Memory placement — everything in BRAM, nothing in SDRAM

Sprite ROM is **8 private 32 KB banks** (level *n* at `n << 15`), and the engine fetches
at most one byte per level per output pixel (max VCO step is < 1.0 in Q8.24 given the
board's fixed R/C values — assert this in RTL). That means 8 independent single-port
BRAMs running in parallel, one access each per pixel — no arbitration, no SDRAM.

| Region | Size | Notes |
|---|---|---|
| sprite ROM | 256 KB (8 × 32 KB) | Turbo only uses 16 KB/level; pad |
| main program ROM | 32 KB max | |
| sub program ROM (Buck Rogers) | 8 KB | |
| fg tile ROM | 4 KB | 2bpp planar, 256 tiles |
| road ROM (Turbo) | 18 KB | 5 logical banks of 4 KB |
| bgcolor ROM (Buck Rogers) | 8 KB | |
| PROMs | ~3 KB | palette / priority / Y-scale / collision |
| bitmap RAM (Buck Rogers) | 57344 × 1 bit = 7 KB | 256 × 224, sub-CPU written |
| work/video/sprite RAM | ~6 KB | |

Total ≈ 320 KB against ~696 KB of M10K on the 5CSEBA6 — comfortable.

### The sprite engine (`rtl/video/sprite_engine.v`) — the critical module

Sprite RAM: 16 entries × 8 bytes. Byte layout (identical across games):

| Byte | Field |
|---|---|
| 0,1 | Y position (Turbo inverts: `^0xff`) |
| 2 | X-scale / VCO DAC input (Turbo inverts) |
| 3 | Y-scale |
| 4,5 | rowbytes increment |
| 6,7 | running ROM pointer — **written back to sprite RAM every scanline** |

**Per-scanline `prepare_sprites` state machine** (runs during HBLANK on the 39.936 MHz
clock; 16 slots × ~8 cycles fits in the 128-pixel blanking window):

1. Two-stage carry ALU: `sum = y + Ylo; clo = carry; sum += (y<<8) + (Yhi<<8); chi = carry`.
   Slot is vertically enabled iff `clo & ~chi` → set bit *n* of the 16-bit `VE` register.
2. Y-scale PROM lookup: `addr = (sum & 0xff) | ((yscale & 0x08) << 5)`; if
   `((prom[addr] >> (yscale & 7)) & 1) == 0`, then `offset += rowbytes` and write bytes
   6/7 back to sprite RAM. This is how vertical zoom works.
3. Reset the level's `latched`/`plb`/`frac`; set `offset` (Buck Rogers pre-shifts
   `offset << 1`); set `step` from the X-scale LUT.

**Per-pixel path** (`get_sprite_bits`), 8 levels in parallel:

- `LST` (8 bits, one per level) is built up *during* the scanline: at each logical
  column `xx`, read a 16-bit horizontal-enable word from sprite-position RAM
  (`sprpos[xx*2] | sprpos[xx*2+1]<<8`; Turbo uses `sprpos[xx] | sprpos[xx+0x100]<<8`),
  AND with `VE`, then `LST |= he | (he >> 8)`.
- For each live level: emit `latched[level]`; `frac += step`; when `frac >= 1.0`, fetch
  `rom[(level<<15) | ((offs>>1) & 0x7fff)]`, take the nibble selected by `~offs & 1`,
  expand it through `sprite_expand[]` (bit *n* → bit *8n*) shifted left by `level`, then
  `offs += (offs & 0x8000) ? -1 : +1` (bit 15 = horizontal flip / reverse walk).
- **Self-termination**: the fetched nibble encodes END/PLB. Turbo tests
  `(pixdata & 0x0c) == 0x04` → clear this level's `LST`. Buck Rogers uses a 16-entry
  `plb_end[]` table (bit0 = PLB, bit1 = END):
  `{0,1,1,1, 1,1,1,1, 1,1,1,1, 1,1,1,2}`. (Subroc-3D, if ever added, uses
  `{0,1,1,2, 1,1,1,1, 1,1,1,1, 0,1,1,2}` — make the table a parameter, not a constant.)
- Output is a packed 32-bit word: `CDB0-7 = D0-7`, `CDG0-7 = D8-15`, `CDR0-7 = D16-23`,
  `PLB0-7 = D24-31`.

Q8.24 fraction thresholds differ: Turbo `0x1000000`, Buck Rogers `0x800000`.

**X-scale LUT**: `sprite_xscale()` in `turbo_v.cpp` is an analog VCO model
(`pow`/`log10` datasheet curve fit). Precompute it offline into a **256-entry Q8.24
table per game** and load it as a BRAM init file. Constants:

| Game | VR1 | VR2 | Cext |
|---|---|---|---|
| Turbo | ~310 Ω (pot) | ~910 Ω (pot) | 100 pF |
| Buck Rogers | 1.2 kΩ | 820 Ω | 220 pF |

Both have `cext >= 1e-11`, so only the `log10` branch of the function is ever taken —
the generator script only needs that path.

### Foreground tilemap (`rtl/video/fg_tilemap.v`)

32×32 grid of 8×8 tiles, 2bpp planar, 1 KB of video RAM. Tile code = the raw VRAM byte;
color = `code >> 2`. The pixmap value the mixer sees is MAME's
`color*4 + pixel` = an 8-bit "raw" pen. Fetch address is shifted per game:

- Turbo: 8-pixel delay — `foreraw = (xx < 8 || xx >= 0x108) ? 0 : fore[xx-8]`
- Buck Rogers: always `fore[(pr5194[((xx>>3)-1)&0x1f] << 3) | (xx & 7)]`

### Palette (`rtl/video/palette.v`)

Resistor-ladder DACs — precompute RGB tables offline from `resnet.h` semantics:
weight *i* = `255 * (1/R_i) / (1/R_pulldown + Σ 1/R_j)`, per channel, normalized so
all-bits-on = 255.

- Turbo: 256 entries. R = pen bits 0-2, G = bits 3-5 (both over
  {1000, 470, 220} Ω, pulldown 470 Ω); B = bits 6,7 over {470, 220} Ω, pulldown 470 Ω.
- Buck Rogers: 1024 entries. R = bits 0-2, G = bits 3-5 over {1000, 500, 250} Ω,
  pulldown 1000 Ω; **B = bits 8,9,6,7 in that order** (LSB→MSB) over
  {2200, 1000, 500, 250} Ω, pulldown 1000 Ω. The shuffle is real — preserve it exactly.

### Support chips

- **`rtl/io/i8255.v`** — mode 0 only (both games use plain latched I/O). Buck
  Rogers additionally needs port C bit 6 as a readable input driven by the sub-CPU ACK.
- **`rtl/io/i8279.v`** — minimal. Only two functions are actually used: DSW1 read via
  the RL lines, and 7-segment digit output via `scanlines_w`/`digit_w` (LS48 decode
  table, 32 digits). Digits can be left unconnected in phase 1 but DSW1-through-RL is
  **required for Turbo** (that's Turbo's only path to DSW1).
- **T80** as a submodule; two instances for Buck Rogers.

---

## Phase 0 — Scaffolding and tooling

Create the repo skeleton from the MiSTer Arcade template:

```
Arcade-Z80-3D.sv          top level (sys wiring, video, OSD/status)
Arcade-Z80-3D.qsf/.qpf
sys/                      MiSTer framework submodule
rtl/z80_3d.v              system top: CPU(s), memory decode, chip selects
rtl/cpu/T80/              submodule
rtl/video/                sprite_engine.v fg_tilemap.v video_timing.v palette.v
                          mixer_buckrog.v mixer_turbo.v road_gen.v
rtl/audio/                sound_buckrog.v + per-block models (phase 4)
rtl/io/                   i8255.v i8279.v
rtl/rom_download.v        ioctl_download → BRAM writes + region decode
roms/                     generated .hex/.mif (xscale LUT, palette LUT)
mra/                      buckrogn.mra buckrog.mra turbo.mra
tools/gen_tables.py       generates xscale + palette tables from the MAME formulas
tools/render_sheets.py    renders schematic PDF pages to PNG (see note below)
sim/                      Verilator testbench + PPM dumper + MAME frame compare
docs/                     this plan, design notes, extracted schematic renders
```

**Note on reading the schematics**: poppler (`pdftoppm`) is not installed on this
machine, so the Read tool cannot rasterize PDF pages directly. `pypdfium2` + `PIL`
*are* installed and work well — render at `scale=400/72` (D-size sheets come out
6800×4400, fully legible) and tile with overlap. `tools/render_sheets.py` should
wrap this so schematic pages can be pulled up on demand during implementation.

**Build `tools/gen_tables.py` first.** It ports `sprite_xscale()` and the resnet weight
math verbatim from `docs/reference/turbo_v.cpp` and `resnet.h`, emitting:
- `roms/xscale_<game>.hex` — 256 × 32-bit Q8.24
- `roms/palette_<game>.hex` — 256 or 1024 × 24-bit RGB

**Build `sim/` second.** A Verilator harness that loads ROM images, runs the core
headless, and dumps one PPM per frame. Compare against MAME snapshots
(`mame buckrogn -snapshot ...`). Given how much of this design is PROM-driven bit
plumbing, a frame-diff loop is the difference between a week and a month on each mixer.

**ROM loading**: MRA files concatenate the MAME ROM set into one blob; `rom_download.v`
decodes `ioctl_addr` into regions. Fixed download map, as implemented in
`tools/gen_mra.py`'s `REGIONS` dict and `rtl/rom_download.v` (source of
truth — update both together if this ever changes, and re-run
`tools/verify_mra_stream.py` after). **Offsets must be perfectly
contiguous** — MRA is a sequential byte stream with no inter-region padding,
so any gap here silently misroutes everything after it on real hardware
(see "First on-hardware test" above; this table used to have gaps):

| Offset | Region |
|---|---|
| `0x000000` | maincpu (32 KB) |
| `0x008000` | subcpu (8 KB) |
| `0x00A000` | fgtiles (4 KB) |
| `0x00B000` | proms (8 KB — bumped from an earlier 4 KB draft; Turbo's proms ROM_REGION is 4128 bytes) |
| `0x00D000` | road / bgcolor (32 KB) |
| `0x015000` | sprites (256 KB, 8 × 32 KB) |

Total blob size: `0x055000` (340 KB).

---

## Phase 1 — Buck Rogers (unencrypted set `buckrogn`)

Start with `buckrogn` specifically: it uses a plain Z80, no `315-5014` decryption.

**CPU / memory** (`main_prg_map`):

| Range | Function |
|---|---|
| `0000-7fff` | program ROM |
| `c000-c7ff` | video RAM (fg tilemap) |
| `c800-c803` (m `07fc`) | PPI0 — read direct, **write goes through the sync wrapper** |
| `d000-d003` (m `07fc`) | PPI1 (sound) |
| `d800-d801` (m `07fe`) | i8279 |
| `e000-e3ff` | sprite-position RAM |
| `e400-e7ff` | sprite RAM |
| `e800/e801` | IN0 / IN1 |
| `e802` | DSW bitswap: `bitswap<4>(DSW1,6,4,3,0) \| bitswap<4>(DSW2,6,4,3,0)<<4` |
| `e803` | DSW bitswap: bits `{7,5,2,1}` from each |
| `f800-ffff` | work RAM |

Sub CPU: `0000-1fff` ROM (read), `0000-dfff` **write** → `bitmap_w` (stores `data & 1`
at pixel `(y = addr>>8, x = addr & 0xff)`), `e000-e7ff` mirrored work RAM. Its entire
I/O space reads the command latch.

**Main↔sub protocol** — in RTL this is trivially a register plus two flags, and the
MAME `delayed_i8255_w` / 600 Hz quantum machinery is purely an emulator scheduling
artifact with **no hardware analogue**:
1. Main writes PPI0 port A → 8-bit command register.
2. Main writes PPI0 port C bit 7 = 0 → assert sub `/INT` (bit 7 = 1 clears it).
3. Sub executes any `IN` → reads command, clears PPI0 PC6 (ACK, readable by main).

Main CPU IRQ: `irq0_line_hold` on VBLANK. Sub CPU has no VBLANK IRQ at all.

**Video registers**: `fchg` = PPI0 port C bits 0-2, `mov` = PPI0 port B bits 0-5,
`obch` = PPI1 port C bits 0-2 (port C also carries coin meters bits 4/5, start lamp bit 6).

**Mixer** (`mixer_buckrog.v`) — a straight 5-level priority chain:

```
forebits = pr5198[((foreraw & 0x03)) | ((foreraw & 0xf8) >> 1) | ((fchg & 0x03) << 7)]
mux      = countl_zero(bitswap<8>(plb,0,1,2,3,4,5,6,7));  if (mux==8) mux = 0xf
cd       = bitswap<4>(sprbits >> (mux & 7), 24,16,8,0)

if      (!(forebits & 0x80)) palbits = repack(forebits)              // fg tier 1
else if (!(mux & 0x08))      palbits = pr5199[(cd & 0x0f) | ((mux & 7) << 4)
                                              | ((obch & 7) << 7)]   // sprite
else if (!(forebits & 0x40)) palbits = repack(forebits)              // fg tier 2
else if (star)               palbits = 0xff                          // bitmap
else                         palbits = repack_bg(bgcolorrom[y | ((mov & 0x1f) << 8)])
```

where `repack(f) = ((f & 0x3c) << 2) | ((f & 0x06) << 1) | (f & 0x01)` and
`repack_bg(p) = (p & 0xc0) | ((p & 0x30) << 4) | ((p & 0x0f) << 2)`.
`countl_zero(bitswap<8>(...))` is just an LS148 priority encoder picking the
lowest-numbered set `plb` bit.

**Sound**: decode the latches into registers and expose them (they're documented below);
output silence. Buck Rogers latches — PPI1 port A: bits 0-2 hit-distance, bit 4 strobes
hit volume, bit 5 strobes `myship` (`data & 0x0f`, engine pitch), bits 6/7 `/ALARM0`,
`/ALARM1` (falling edge). Port B: bits 0-5 alarm2 / alarm3 / `/FIRE` / `/EXP` / `/HIT` /
`/REBOUND` (all falling edge), bit 6 `SHIP` (level: engine loop on/off), bit 7 `GAME ON`
(global mute, active low).

**Definition of done for phase 1**: boots, attract mode, coin-up, playable, frame-diffs
clean against MAME on the title screen, attract loop, and first wave.

---

## Phase 2 — Buck Rogers sound board (834-5122), discrete model

Done after phase 1 is playable. This is a from-schematic reimplementation, **not**
sample playback — MAME only ever ships samples for this game (its discrete netlist is
compiled out behind `#define DISCRETE_TEST (0)` and every set carries
`MACHINE_IMPERFECT_SOUND`), so there is no golden reference to match. The schematic is.

**Source**: `docs/reference/Buck_Schematics.pdf` — sound board schematic on **PDF pages
45-47** (sheets 1-3 of drawing 834-5122), plus the PCB **assembly drawing on PDF page
20** which carries every R/C value as a cross-check when a schematic value is smudged.
Theory-of-operation prose is on PDF pages 1-16.

### Board architecture (traced from sheets 1-2)

Six independent sound channels feed one weighted summing amplifier and a power amp:

```
connector (20-pin flat cable, RA1 4.7K / RA2,RA3 47K pull-ups)
  → IC1, IC5 (7417 hex buffers)
      → direct: /ALARM0-3, /FIRE  (sheet 3)
                /EXP, /HIT, /REBOUND (sheet 2)
                SHIP ON, GAME ON
      → IC2 (4175B quad D-FF) → HIT DIS0-2
      → IC6 (4175B quad D-FF) → ACC0-3

SHIP   : IC14 555 astable (R24 6.8K charge, R23 200K + D1 discharge, C12 1uF)
         → IC17 LM324 buffer
         → IC9 4066 ×4 gated by ACC0-3, weights R20 82K / R21 30K / R18 16K / R19 2K
         → IC17/IC22/IC26 LM324 envelope-follower + 2-pole filter chain (Tr2/Tr4/Tr5)
         → IC24 MB4391 VCA → IC28 → SHIP MIX
HIT    : NOISE·B (sheet 3) → IC20 LM324 2-pole LPF (R84/R88 15K, C49/C50 0.0033uF,
         R86 100K / R85 150K)
         → IC24 MB4391 VCA, control = IC13 74123 one-shot (C42 4.7uF) fired by /HIT
         → IC10 4066 ×3 gated by HIT DIS0-2, weights R25 100K / R26 22K / R27 10K
         → IC28 LM324 (R135 100K in, R134 680K fb) → HIT MIX
EXP    : /EXP → IC8 74123 (R16 47K, C7 4.7uF) fast envelope
         + NOISE·A path → second 74123 section (R17 47K, C8 22uF) slow rumble envelope
         → IC21 MB3614 dual bandpass (C53/C54 0.0068uF and C51/C52 0.039uF)
         → IC19 MB4391 VCA → IC25 LM324 (R141 470K fb) → EXP MIX
REBOUND: /REBOUND → IC13 74123 (R47 47K, C44 1uF) → IC12 LM324
         → IC15B 555 tone burst (R64 33K, C31 1uF, R65 10K pull-up)
         → IC12 gain (R37 12K / R36 4.7K) → Tr3 gate
         → IC18 MB4391 VCA (envelope on control pin) → IC22 (R128 330K fb) → REBOUND MIX
NOISE  : IC33 MM5837 noise chip → IC29 LM324 ×2 buffers
         → NOISE·A (R140 100K in / R139 10K fb, gain ≈ -0.1) → FIRE + sheet 2 EXP
         → NOISE·B (R144 330K in / R143 100K fb, gain ≈ -0.3) → sheet 2 HIT
FIRE   : /FIRE → IC4 74123 (R7 47K, C4 1uF, ~13 ms)
         → D8 → R4 150K / C3 6.8uF decay → IC20 LM324 → Tr1 (R77 15K base,
           R76 3.3K, R32 1.5K emitter, R31 100R) → IC20 sec.2 (R78 56K in,
           R79 47K fb, ref from R74 100K / R75 33K / C37 33uF)
         → MB4391 IC18 control pin 2 (C19 680pF integrates the control node)
         NOISE·A → C30 4.7uF / R33 10K → IC12 LM324 LPF (R35 47K fb,
           C32/C33 0.01uF → corner ≈ 340 Hz) → C16 2.2uF / R67 30K / C23 2.2uF
         → IC18 audio in → C25 2.2uF / R69 100K → IC25 (R142 220K fb, ≈ -2.2×)
         → C77 2.2uF → FIRE MIX
ALARM  : IC15A 555 astable (R29 470R, R30 270R, C15 0.01uF) ≈ 142.6 kHz
         → IC16 74LS393 ripple divider (taps QB/QC/QD; 2A tied to 1QD)
         → IC11 74LS38 open-collector NAND ×4, each gating one tap against one
           alarm enable; all four wire-OR'd onto a node pulled up by R153 1K
         alarm enables come from IC3 (ALARM0: R2 47K/C1 6.8uF; ALARM1: R3 47K/C2 6.8uF)
           and IC7 (ALARM2: R14 47K/C5 6.8uF; ALARM3: R15 47K/C6 **10uF** — longer)
         → R154 5.1K / C88 4.7uF → IC29 → R127 100K → IC25 (R129 200K fb, ≈2×)
         → C74 2.2uF → ALARM MIX
```

**Master mixer** — six weighted inputs into IC28's inverting summing amp, feedback
`R126 = 100K`:

| Channel | Summing R | Relative gain |
|---|---|---|
| HIT MIX | R136 = 5.1 K | ≈19.6× — **~2× louder than everything else** |
| SHIP MIX | R137 = 10 K | 10× |
| FIRE MIX | R131 = 10 K | 10× |
| EXP MIX | R133 = 10 K | 10× |
| REBOUND MIX | R130 = 10 K | 10× |
| ALARM MIX | R132 = 10 K | 10× |

Output: `C69 4.7uF → R45 100K → VR1 20K volume pot → C83 4.7uF → LA4460` power amp
(pin 2 in, pins 7/9 out with 0.033uF + 4.7Ω Zobel networks, C80 470uF supply decouple).
Note the manual's prose calls this part "LA446"; the schematic title block reads
**LA4460**. Trust the schematic.

Op-amps run single-supply with a **6 V mid-rail** as AC ground — every DSP block model
needs the same DC bias convention or the envelope followers behave wrongly.

### IC roster (from the assembly drawing, PDF page 20)

| IC | Part | Sheet | Role |
|---|---|---|---|
| IC1, IC5 | 7417 | 1 | connector input buffers (RA1 4.7K, RA2/RA3 47K×8 pull-ups) |
| IC2, IC6 | 4175B | 1 | latch HIT DIS0-2 / ACC0-3 |
| IC3, IC7 | 74123 | 3 | ALARM0-3 one-shots |
| IC4 | 74123 | 3 | FIRE one-shot |
| IC8, IC13 | 74123 | 2 | EXP / HIT + REBOUND one-shots |
| IC9, IC10 | 4066B | 1, 2 | ACC0-3 and HIT DIS0-2 resistor-select switches |
| IC11 | 7438 | 3 | open-collector NAND alarm tone gating |
| IC12 | LM324 | 2, 3 | noise shaping, REBOUND stages |
| IC14 | 555 | 1 | SHIP engine astable |
| IC15 A/B | dual 555 | 2, 3 | alarm clock (A) / REBOUND tone burst (B) |
| IC16 | 74LS393 | 3 | alarm tone divider |
| IC17, IC20-IC22, IC25, IC26, IC29 | LM324 / MB3614 | all | filters, envelopes, buffers |
| IC18, IC19, IC24 | MB4391 | 1, 2, 3 | VCAs (REBOUND, EXP, SHIP + HIT, FIRE) |
| IC28 | LM324 | 1, 2 | **master summing amp** + HIT mix |
| IC33 | **MM5837** | 3 | noise source |
| LA4460 | Sanyo power amp | 1 | speaker output |
| VR1 | 20K pot | 1 | master volume |
| Tr1-Tr5 | 2SC458 | 1, 2, 3 | envelope-follower / gate stages |
| D1-D11 | MA150 | all | rectifiers in decay networks (D9 = zener, 12 V ref) |

### The noise source is an MM5837 — model it bit-exact

**IC33 = National MM5837.** This is the single best piece of news in the whole audio
phase: it is not an analog avalanche-noise transistor, it is a **17-bit LFSR**
(taps 17 and 14) clocked by an on-chip RC oscillator at roughly 32-64 kHz. That is
about fifteen lines of Verilog and it is *exactly* right, not an approximation.

Every noise-based effect on the board (FIRE, HIT, EXP) derives from this one chip
through two buffered/attenuated taps, so getting it right fixes three channels at once.
The one genuine unknown is the clock rate — the MM5837's internal oscillator is
notoriously part-to-part variable (32-64 kHz range is the datasheet spec). Make it a
parameter and tune by ear against hardware recordings; ~48 kHz is the usual choice.

### Two recurring patterns worth building once

1. **Resistor-select attenuator** — SHIP's ACC0-3 (4 weights) and HIT's HIT DIS0-2
   (3 weights) are *identical* circuits: N 4066 switches, each in series with a
   resistor, all summed at a biased node. One parameterized module handles both.
   Note this is a *parallel conductance sum*, not a binary DAC — the gain is
   `Σ(enabled 1/R) / (1/R_bias + Σ(enabled 1/R))`, so precompute the 16 (resp. 8)
   possible gain values into a small LUT rather than computing at runtime.
2. **74123 one-shot → RC decay → MB4391 VCA control** — the envelope path for HIT, EXP
   and REBOUND. One parameterized envelope module (retriggerable pulse width from
   R/C, then an exponential decay with a configurable time constant) covers all three.

### Implementation approach

Fixed-point DSP on an audio-rate clock enable (**192 kHz** is a good target — it leaves
headroom for the 555 tone oscillators, which run in the hundreds of Hz to low kHz, and
divides cleanly from the 39.936 MHz core clock at ÷208 ≈ 192.0 kHz). Per block:

- **555 astable** → phase accumulator; increment derived from the R/C values. Model the
  asymmetric charge/discharge duty (the diode across the discharge resistor) since it is
  what gives SHIP its buzz rather than a clean square. Note IC15A runs at ~142.6 kHz,
  which is *above* the 192 kHz audio rate's Nyquist only after division — so run the
  555 + 74393 divider chain as **plain digital logic on the core clock**, not in the
  DSP domain, and hand the divider taps to the audio path as clean square waves.
- **MM5837 noise** → 17-bit LFSR, taps 17/14, clocked from its own parameterized
  ~48 kHz enable. Digital domain, feeds the DSP domain.
- **RC low-pass / bandpass** → one-pole or two-pole IIR, coefficients precomputed from
  the R/C values at build time by `tools/gen_audio_coeffs.py`.
- **74123 one-shot** → a down-counter loaded with the pulse width in samples,
  retriggerable, exactly like the real part.
- **RC envelope decay** → leaky integrator (`y -= y >> k`), `k` chosen per channel from
  the real time constant. EXP's slow path (22 µF / 1 MΩ ≈ 22 s nominal) vs. HIT's fast
  path is the audible difference between "rumble" and "thud" — get the ratio right.
- **MB4391 VCA** → a multiply. It is a gain-control element; no need to model its
  internal nonlinearity in a first pass.
- **Envelope follower** (Tr2/Tr4/Tr5 in the SHIP chain) → rectify + leaky integrate.
- **Summing** → shift-weighted adds using the table above, then a single output gain.
  Keep enough headroom that the HIT channel's ~2× weight cannot clip the bus.

Signal names map 1:1 onto the MAME latch decode already in phase 1 (`ALARM0-3`, `FIRE`,
`EXP`, `HIT`, `REBOUND`, `SHIP`, `GAME ON`, `ACC0-3`, `HIT DIS0-2`) — that naming came
straight off this schematic, which is a strong signal the latch decode is correct.
`GAME ON` gates the whole mix (mute when low).

### Verification

No MAME reference exists, so verify against the circuit rather than against an emulator:

1. **Per-block SPICE-free sanity check** — compute each 555 frequency and each RC corner
   by hand from the values above; assert the RTL block hits the same figure in a
   testbench before wiring it up.
2. **Testbench per channel** — pulse each trigger in isolation, dump the output to WAV,
   listen. Each channel should be individually recognizable (thud, rumble, boing,
   engine drone, laser, alarm).
3. **Compare against real hardware recordings** — YouTube captures of a real Buck Rogers
   cabinet are the only ground truth for overall balance. MAME's samples are a
   *secondary* reference at best; they were hand-made approximations.
4. **Mix balance** — confirm HIT sits noticeably above the other channels, per R136.

### Known gaps to close during implementation

All three sheets have been traced at block level; these specific details still need a
higher-zoom pass (re-render the region at `scale=800/72`) when the relevant block is
being built:

1. **Connector pin → signal-name mapping** (sheet 1, zone D8). The 20-pin flat cable's
   pin numbers were not readable across a tile boundary. Not blocking — the signal
   *names* and their destinations are all known, and the CPU-side latch bit assignments
   come from `turbo_a.cpp` regardless.
2. **74393 tap wiring** (sheet 3). The second counter section's cascade beyond
   `2A ← 1QD` was ambiguous, so the four alarm tone frequencies are not yet derivable.
   Needs a zoom on IC16 before the ALARM channel can be finished.
3. **R138 (200K) role** at the master summing junction (sheet 1, zone A6) — series
   element into IC28's inverting input, or a second bias source. Affects overall mix
   gain calibration.

**Value corrections already found** (the assembly drawing on PDF page 20 is the
tiebreaker when a schematic value is smudged):

- **C19 and C21 are 680 pF ceramic, not 680 µF.** The schematic scan reads as "µf";
  the assembly drawing clearly says "680p CER", and 680 pF is the only value that makes
  sense smoothing an MB4391 control node at audio rates. Assume the same for C68.
- The power amp is **LA4460** (schematic title block), not "LA446" as the manual's
  prose section calls it.
- Transistors Tr1-Tr5 are **2SC458**; diodes D1-D11 are **MA150**.

---

## Phase 3 — Turbo

The heaviest phase: the road generator, collision detection, and a genuinely different
mixing architecture.

**Memory map**: ROM `0000-5fff`; sprite RAM `a000-a0ff` mirror `0700` with address
folding `offset = (offset & 0x07) | ((offset & 0xf0) >> 1)` into 128 physical bytes;
LS259 output latch `a800-a807` (bit 0/1 coin meters, bit 3 start lamp);
sprite-position RAM `b000-b3ff`; `b800-bfff` write = analog reset; video RAM
`e000-e7ff`; `e800-efff` write = collision clear; work RAM `f000-f7ff`; PPIs at
`f800`/`f900`/`fa00`/`fb00`; i8279 `fc00`; IN0 `fd00`; collision read `fe00`.

**Registers**: PPI0 → `opa`/`opb`/`opc`; PPI1 → `ipa`/`ipb`/`ipc`; PPI2 = sound;
PPI3 port A reads the steering dial, port B reads DSW2, port C write → `fbpla = data & 0x0f`
(PLA0-3), `fbcol = (data >> 4) & 7` (COL0-2).

**Steering**: `analog_r` returns `dial - last_analog`, a *delta* since the last write to
`b800-bfff`. Implement as a free-running dial counter plus a snapshot register. Map the
MiSTer analog stick / spinner to the dial and a trigger axis to the pedal. The pedal is
a 2-bit Gray-coded opto pair: `(pedal >> 6) ^ (pedal >> 7) ^ 0x03`.

**Road generator** (`rtl/video/road_gen.v`), per pixel:

```
va = (y + opa) & 0xff;  if (!(opc & 0x80)) va ^= 0xff;
carry = (xx + opb) >> 8;
sel  = carry ? ipb : ipa;
coch = carry ? (ipc >> 4) : (ipc & 15);

offs = va | ((sel & 0x0f) << 8);
area  = ((road[0x0000|offs] + xx) >> 8) & 1;
area |= (((road[0x1000|offs] + xx) >> 8) & 1) << 1;
offs = va | ((sel & 0xf0) << 4);
area |= (((road[0x2000|offs] + xx) >> 8) & 1) << 2;
area |= (((road[0x3000|offs] + xx) >> 8) & 1) << 3;
area |= ((road[0x4000 | ((xx>>3) | ((opc & 0x3f) << 5))] << (xx & 7)) & 0x80) >> 3;

babit = pr1115[area];
bacol = pr1114[(coch & 0x0f) | ((fbcol & 1) << 4)]
      | (pr1117[(coch & 0x0f) | ((fbcol & 1) << 4)] << 8);
```

Each road ROM stores a per-scanline boundary byte; adding the column and testing the
carry out of bit 8 gives a "left/right of this edge" test — four edges plus a bitmap
overlay stripe from AREA5.

`babit` bits 4-5 are SLIPAR/ACCIAR. The `road` flag latches once SLIPAR is seen while
scanning left to right, and **gates sprite levels 3-7 off** (`sprlive &= 0x07`) until
then — a hardware bandwidth restriction, not an optional detail.

**Collision**: `collision |= pr1116[((sprbits >> 24) & 7) | (slipar_acciar >> 1)]`,
accumulated every visible pixel, read at `fe00` as `(DSW3 & 0xf0) | (collision & 0x0f)`,
cleared by any write to `e800-efff`. MAME's `update_partial()` calls exist purely so a
software renderer can be sampled mid-frame; in RTL this is naturally correct.

**Mixer** (`mixer_turbo.v`) — *not* an ordinal priority chain. It is a bit-serial 16:1
multiplexer, and should be implemented literally rather than "simplified":

```
priority = pr1122[((sprbits & 0xfe000000) >> 25) | ((fbpla & 0x07) << 7)];
mx = pr1123[ (priority & 7)
           | ((sprbits & 0x01000000) >> 21)   // PLB0
           | ((foreraw & 0x80) >> 3)          // PLBE
           | ((forebits & 0x08) << 2)         // PLBF
           | ((babit & 0x07) << 6)            // BABIT1-3
           | ((fbpla & 0x08) << 6) ];         // PLA3

red = (sprbits & 0xff) | ((forebits & 1) << 8) | ((bacol & 0x001f) << 9) | (1<<14);
grn = ((sprbits >> 8) & 0xff) | ((forebits & 2) << 7) | ((bacol & 0x03e0) << 4) | (1<<14);
blu = ((sprbits >> 16) & 0xff) | ((forebits & 4) << 6) | ((bacol & 0x7c00) >> 1) | (1<<14);

pen = pr1121[ mx | (((~red >> mx) & 1) << 4)
                 | (((~grn >> mx) & 1) << 5)
                 | (((~blu >> mx) & 1) << 6)
                 | ((fbcol & 6) << 6) ];
```

`mx` selects a *bit position* out of three pre-packed 16-bit words that interleave
sprite, foreground and road data. Load PR1114/1115/1116/1117/1121/1122/1123 verbatim
into BRAM and wire the mux; do not try to re-derive semantic layer ordering.

**ROM decryption**: the `turboa`–`turboe` sets use a static XOR-table descramble
(`rom_decode()`: 4 tables of 32 bytes, selected per 1 KB block by `findtable[offs>>10]`,
indexed by `src >> 2` with `^0x3f` when bit 7 is set). This is a pure ROM transform with
no runtime component — **do it in the MRA file** or in `tools/`, not in HDL. Ship
`turbo.mra` (the plain 1513-1515 set) first.

---

## Phase 4 — Turbo sound board, discrete model

Same method as phase 2, against `docs/reference/Turbo_Schematics.pdf`. Start by
locating the sound-board sheets in that PDF the same way the Buck Rogers ones were
found (its manual will have a "List of Illustrations" giving printed page numbers;
subtract the offset between printed and PDF page numbering).

Turbo's sound is a 4-speaker cockpit arrangement (front L/R, center, rear) — the MAME
driver's routing table in `turbo_a.cpp` documents the analog mixer bus names
(F.OUT / W.OUT / R.OUT / L.OUT / M.OUT) it fed. Decide whether to reproduce the quad
mix downmixed to stereo, or expose an OSD option; the upright cabinet used two speakers
(upper/lower), which is the simpler default.

Useful starting structure, from the disabled `turbo_discrete` netlist in `turbo_a.cpp`
(compiled out, but it is a genuine reverse-engineering of the alarm circuit and is
almost entirely digital, so it ports to Verilog nearly literally):

- 555 astable → cascaded 74393 counters → four 74123 one-shots retriggered by TRIG1-4
  → NAND4 → op-amp buffer distributing one tone to Mono/Front/Rear/Left outputs.
- Engine: the accelerator value `ACC0-5` (6 bits, PPI2 port B) sets pitch; `BSEL`
  (PPI2 port C bits 2-3) selects standard/tunnel/off. MAME approximates this as
  `freq = base * ((accel & 0x3f)/5.25 + 1)`, stopped when `BSEL == 3` — the schematic
  will give the real VCO.
- Other triggers: CRASH.S, CRASH.L, SLIP, SPIN, AMBU (looping siren, level-gated),
  and OSEL0-2 selecting the opponent-car sound.

Reuse everything built in phase 2 — the resistor-select attenuator, the 74123 envelope
module, the RC filter primitives, the summing bus.

---

## Sequencing

1. **Phase 0** — scaffolding, `gen_tables.py`, Verilator harness, MRA + ROM download.
2. **Phase 1a** — Buck Rogers main CPU + video RAM + fg tilemap → attract text visible.
3. **Phase 1b** — sprite engine → sprites correct.
4. **Phase 1c** — sub CPU + bitmap + bgcolor + full priority chain → `buckrogn` playable.
5. **Phase 1d** — `315-5014` opcode decryption (uses T80's `M1`) → `buckrog` / `zoom909`.
6. **Phase 2** — Buck Rogers sound board, discrete model (MM5837 + six channels).
7. **Phase 3** — Turbo: road generator, collision, bit-serial mixer, analog inputs,
   rotation. Video only; audio silent.
8. **Phase 4** — Turbo sound board, discrete model.

Subroc-3D is deliberately not in this list. The sprite engine's game-specific bits
(`plb_end` table, X-scale constants, offset pre-shift, sprite-position RAM addressing)
are parameterized so it can be slotted in later without reopening the engine.

---

## Verification

**Per phase, in this order:**

1. **Table generation** — `python tools/gen_tables.py --check --check-mame`.
   `--check` asserts the invariants (step < 1.0, monotonicity, channel isolation, the
   Buck Rogers blue shuffle); `--check-mame` runs MAME headless and diffs every palette
   entry against it. Both currently pass, the latter bit-exact. **Done.**
2. **Verilator frame diff** — `sim/run.sh <game>` boots the core headless for N frames
   and writes PPMs; compare against `mame <game> -str <N> -snapshot`. Target: bit-exact
   on attract mode. Any diff localizes to one PROM path.
3. **Targeted module benches** — for the sprite engine, drive a synthetic sprite RAM
   (one sprite, sweeping X-scale 0-255) and confirm the scanline output against a C
   reference transcribed from `get_sprite_bits()`. Do this before integrating.
4. **Quartus** — `quartus_sh --flow compile Arcade-Z80-3D`; watch for the sprite ROM
   inferring correctly as 8 separate M10K banks (check the fitter's RAM summary — if it
   collapses or fails to infer, the whole timing model breaks).
5. **DE10-Nano** — load the RBF and MRA-built `.rom`, then: attract loop runs clean;
   coin/start works; DIP switches take effect (specifically confirm Turbo's DSW1, since
   it is only reachable through the i8279 RL path); service mode / test screens render;
   Turbo's collision detection actually registers crashes.
6. **Regression** — after each phase, re-run the frame diff for every previously
   completed game. The shared sprite engine is the thing most likely to break
   retroactively.

**Audio phases verify differently** — see the verification notes in phase 2. There is no
emulator reference to diff against, so it is per-block frequency/time-constant asserts,
per-channel WAV dumps, and comparison against recordings of real hardware.

---

## Deliverables in `docs/`

Everything this work produces lands in `C:\MiSTerDev\Arcade-Z80-3D_MiSTer\docs`:

| File | Contents |
|---|---|
| `docs/PLAN.md` | this plan |
| `docs/hardware-video.md` | consolidated sprite engine / mixer / palette notes |
| `docs/hardware-audio.md` | the sound board trace above, expanded as sheets get zoomed |
| `docs/schematics/` | PNG renders of the sheets actually used, so they are readable without re-rendering |
| `docs/reference/` | already present — MAME sources and the two schematic PDFs |

## Key reference locations

- Sprite engine, palettes, both mixers: `docs/reference/turbo_v.cpp`
- Memory maps, PPI wiring, ROM regions, screen timing, CPU config:
  `docs/reference/turbo.cpp`
- Sound latch bit assignments and the (unused, compiled-out) Turbo discrete netlist:
  `docs/reference/turbo_a.cpp`
- Resistor-network weight math: `docs/reference/resnet.h`
- **Buck Rogers sound board schematic** (834-5122, sheets 1-3):
  `docs/reference/Buck_Schematics.pdf` **PDF pages 45, 46, 47**.
  PCB assembly drawing with all R/C values: **PDF page 20**.
  Theory-of-operation prose: PDF pages 1-16. Board numbers: CPU 834-5120,
  EPROM 834-5121, Sound 834-5122.
  (Printed page numbers in that manual are PDF page + 146.)
- Turbo board-level signals and its sound board: `docs/reference/Turbo_Schematics.pdf`
