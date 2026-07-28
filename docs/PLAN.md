# Sega Z80-3D MiSTer Core — Implementation Plan

## Status — 2026-07-28

**Phase 0 done. Phase 1a done** (Buck Rogers `buckrogn` attract-mode text +
background dressing render correctly in simulation) **and hardware-hardened**:
Quartus full compile (synthesis + fit + assembler + TimeQuest) succeeds clean,
0 errors, positive timing slack (+0.356 ns worst-case setup), 20% ALM / 14%
block-memory / 19% RAM-block utilization on the DE10-Nano's 5CSEBA6 — ready
for an on-hardware smoke test. `Arcade-Z80-3D.rbf`/`.sof` build in
`output_files/` (gitignored, not committed — rebuild with
`quartus_sh --flow compile Arcade-Z80-3D`). Working tree is
`.claude/worktrees/phase0-1a`, branch `worktree-phase0-1a` — not yet merged.

| Item | State |
|---|---|
| `tools/gen_tables.py` | done — X-scale + palette tables, self-checks, MAME golden diff |
| `roms/xscale_{turbo,buckrog}.hex` | generated, 256 × Q8.24 |
| `roms/palette_{turbo,buckrog}.hex` | generated; **bit-exact vs MAME**, all 1280 entries |
| `tools/render_sheets.py` | done — renders schematic PDF pages to PNG |
| `tools/mame/dump_palette.lua` | done — headless palette dump for the golden diff |
| `docs/hardware-audio.md` | done — full sound board trace |
| `docs/schematics/` | sound sheets 1-3 + assembly drawing rendered at 400 dpi |
| `mra/{buckrogn,buckrog,turbo}.mra` | done — `tools/gen_mra.py`, all CRCs verified byte-for-byte against the real MAME zips |
| MiSTer template scaffolding (`sys/`, `Arcade-Z80-3D.{sv,qpf,qsf,sdc,srf}`, `files.qip`) | done — pulled as-is from `C:\MiSTerDev\Template_MiSTer`; `sys/` untouched |
| `rtl/T80/` | done — Sorgelig's T80 v350, vendored (plain files, not a submodule) from `Arcade-DonkeyKong_MiSTer`, for real synthesis |
| `rtl/tv80/` | done — hutch31/tv80 (pure Verilog Z80), vendored from `SuperOffRoad_MiSTer`, **simulation only** |
| `rtl/cpu_z80.v` | done — wraps T80 (synthesis) / TV80 (Verilator sim) behind one interface |
| `rtl/rom_download.v`, `rtl/video/video_timing.v`, `rtl/video/fg_tilemap.v`, `rtl/z80_3d.v` | done — phase 1a scope (see below) |
| `sim/` Verilator harness | done — see "Sim harness" below |
| Phase 1b (sprite engine), 1c (sub CPU/bitmap/full mixer), 1d (decryption), phase 3 (Turbo) | not started |

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
3. `pll`'s `locked` output is now wired into the top-level `reset`, so the
   core stays in reset until the PLL has actually locked.

**Known simplification still open before phase 1b's bit-exact MAME frame-diff:**

`cpu_z80.v`'s TV80 (simulation-only) path runs the CPU at the **full core
clock**, undivided — TV80's `tv80s.v` wrapper ties its internal `cen`
permanently to 1 (no usable clock-enable input; confirmed against the tv80
repo's own reference testbench, which does the same). So in simulation the
CPU currently runs ~8x faster relative to video than real hardware. Fine for
"does the attract screen render" but wrong for cycle-accurate frame diffing.
Fix by driving `tv80_core` directly (it does expose a `cen` port) with a real
per-T-state enable, or by giving the CPU its own free-running clock domain.
T80 (real synthesis target) is unaffected — it takes a genuine `CEN`
clock-enable and was never part of this problem.

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

**Next step:** phase 1b — sprite engine, pipelined (BRAM-correct) fg tilemap
reads, TV80 cen/clocking fix, and the first real MAME frame-diff.

## Context

`C:\MiSTerDev\Arcade-Z80-3D_MiSTer` currently contains only `docs/reference` (MAME driver
sources `turbo.cpp` / `turbo_v.cpp` / `turbo_a.cpp` / `turbo.h` / `resnet.h`, plus
`Turbo_Schematics.pdf` and `Buck_Schematics.pdf`). There is no MiSTer core for Sega's
Z80-3D board family — **Turbo** (1981), **Subroc-3D** (1982) and **Buck Rogers: Planet
of Zoom / Zoom 909** (1982). The goal is one FPGA core targeting the DE10-Nano, built
in stages around the single video/sprite architecture all these boards share.

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
decodes `ioctl_addr` into regions. Fixed download map (pad each region), as
implemented in `tools/gen_mra.py`'s `REGIONS` dict and `rtl/rom_download.v`
(source of truth — update both together if this ever changes):

| Offset | Region |
|---|---|
| `0x000000` | maincpu (32 KB) |
| `0x008000` | subcpu (8 KB) |
| `0x00A000` | fgtiles (4 KB) |
| `0x00C000` | proms (8 KB — bumped from an earlier 4 KB draft; Turbo's proms ROM_REGION is 4128 bytes) |
| `0x00E000` | road / bgcolor (32 KB) |
| `0x016000` | sprites (256 KB, 8 × 32 KB) |

Total blob size: `0x056000` (344 KB).

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
