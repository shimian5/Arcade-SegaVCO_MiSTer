#!/usr/bin/env python3
"""Generate the sprite X-scale and palette lookup tables for the Z80-3D core.

Both tables replace floating-point maths that the real hardware did in the analog
domain and that MAME does with doubles at runtime. We precompute them once here
and load the results into BRAM via $readmemh.

  roms/xscale_<game>.hex    256 entries, 32-bit Q8.24 fractional step per DAC input
  roms/palette_<game>.hex   256 (turbo) or 1024 (buckrog) entries, 24-bit RRGGBB

Sources, ported line for line:
  sprite_xscale()             docs/reference/turbo_v.cpp:176
  <game>_state::palette()     docs/reference/turbo_v.cpp:33 (turbo), :89 (buckrog)
  compute_resistor_weights()  MAME src/emu/video/resnet.cpp
  combine_weights()           docs/reference/resnet.h:180

Usage:
    python tools/gen_tables.py                 # write the tables
    python tools/gen_tables.py --check         # verify invariants, write nothing
    python tools/gen_tables.py --check-mame    # diff palettes against headless MAME
"""

import argparse
import math
import os
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
ROMS = REPO / "roms"

# Local MAME install, used only by --check-mame as a golden reference.
MAME_DIR = Path(r"C:\MiSTerDev\mame")
MAME_EXE = MAME_DIR / "mame.exe"

# MAME driver name to read each palette from. buckrogn is the unencrypted set;
# its palette is identical to buckrog/zoom909 since palette() ignores encryption.
MAME_DRIVER = {"turbo": "turbo", "buckrog": "buckrogn"}

# turbo.h: sprites are scaled in the analog domain; MAME (and this core) render at
# 2x horizontal to approximate that on a discrete pixel grid.
TURBO_X_SCALE = 2

# turbo_v.cpp comments the pixel clock the VCO fraction is taken against as 5 MHz.
# Note this is the nominal figure used by the scaling maths, not MASTER_CLOCK/4.
PIXEL_CLOCK_NOMINAL = 5e6

Q824_ONE = 1 << 24


# --------------------------------------------------------------------------
# resnet: MAME's compute_resistor_weights / combine_weights
# --------------------------------------------------------------------------

def compute_resistor_weights(minval, maxval, scaler, nets):
    """Port of MAME's compute_resistor_weights (src/emu/video/resnet.cpp).

    `nets` is a list of (resistances, pulldown, pullup) tuples, one per channel.
    Returns a list of weight lists, in the same order.

    For each resistor n the function works out the output when only that resistor
    is driven high: R1 is the parallel resistance to Vcc (pullup + resistor n),
    R0 the parallel resistance to ground (pulldown + every other resistor), and
    the output is the divider between them, expressed directly in the
    minval..maxval range rather than in volts.

    The autoscale case (scaler < 0) uses a SINGLE scale factor derived from
    whichever net has the largest summed output — not one factor per net. That is
    why Turbo's 2-resistor blue channel tops out below 255 while red and green
    reach it exactly: fewer resistors really do mean less current on the board.
    """
    assert minval < maxval

    weights = []
    for resistances, pulldown, pullup in nets:
        net = []
        for n in range(len(resistances)):
            # conductances, mirroring resnet.cpp's use of 1/1e12 for "absent"
            g_gnd = 1.0 / 1e12 if pulldown == 0 else 1.0 / pulldown
            g_vcc = 1.0 / 1e12 if pullup == 0 else 1.0 / pullup

            for j, rj in enumerate(resistances):
                if rj == 0.0:
                    continue
                if j == n:
                    g_vcc += 1.0 / rj
                else:
                    g_gnd += 1.0 / rj

            r_gnd = 1.0 / g_gnd
            r_vcc = 1.0 / g_vcc

            vout = (maxval - minval) * r_gnd / (r_vcc + r_gnd) + minval
            net.append(min(max(vout, float(minval)), float(maxval)))
        weights.append(net)

    sums = [sum(net) for net in weights]
    scale = (maxval / max(sums)) if scaler < 0.0 else scaler

    return [[w * scale for w in net] for net in weights]


def combine_weights(weights, *bits):
    """resnet.h: int(sum(weight[i] * bit[i]) + 0.5)."""
    assert len(weights) == len(bits), "weight/bit count mismatch"
    return int(sum(w * b for w, b in zip(weights, bits)) + 0.5)


# --------------------------------------------------------------------------
# sprite X scaling (the analog VCO)
# --------------------------------------------------------------------------

def sprite_xscale(dacinput, vr1, vr2, cext):
    """Port of turbo_base_state::sprite_xscale (turbo_v.cpp:176).

    Models the VCO that clocked sprite pixels out in the analog domain. Returns
    the per-output-pixel step as a Q8.24 fraction of the 2x pixel clock.
    """
    # control voltage to the VCO
    iref = 5.0 / (1.5e3 + vr2)
    iout = iref * (dacinput / 256.0)
    vref = 5.0 * 1e3 / (3.8e3 + 1e3 + vr1)
    vco_cv = (2.2e3 * iout) + vref

    vco_cv = min(max(vco_cv, 0.0), 5.0)

    if cext < 1e-11:
        # datasheet curve for a 50pF external cap, then scaled for the real one.
        # Neither Turbo (100pF) nor Buck Rogers (220pF) takes this branch; kept
        # so the port stays faithful to the original.
        if vco_cv < 1.33:
            vco_freq = (0.68129 + pow(vco_cv + 0.6, 1.285)) * 1e6
        elif vco_cv < 4.3:
            vco_freq = (3 + (8 - 3) * ((vco_cv - 1.33) / (4.3 - 1.33))) * 1e6
        else:
            vco_freq = (-1.560279 + pow(vco_cv - 4.3 + 6, 1.26)) * 1e6
        vco_freq *= 50e-12 / cext
    else:
        # figure 6 of the datasheet
        vco_freq = (-0.9892942 * math.log10(cext)
                    - 0.0309697 * vco_cv * vco_cv
                    + 0.344079975 * vco_cv
                    - 4.086395841)
        vco_freq = pow(10.0, vco_freq)

    return int((vco_freq / (PIXEL_CLOCK_NOMINAL * TURBO_X_SCALE)) * float(Q824_ONE))


# --------------------------------------------------------------------------
# per-game configuration
# --------------------------------------------------------------------------

class Game:
    def __init__(self, name, vr1, vr2, cext, palette_size, nets, channel_bits):
        self.name = name
        self.vr1 = vr1
        self.vr2 = vr2
        self.cext = cext
        self.palette_size = palette_size
        self.nets = nets                    # [(resistances, pulldown, pullup)] x3
        self.channel_bits = channel_bits    # [(pen bit per weight)] x3, LSB weight first

    def xscale_table(self):
        return [sprite_xscale(d, self.vr1, self.vr2, self.cext) for d in range(256)]

    def palette_table(self):
        weights = compute_resistor_weights(0, 255, -1.0, self.nets)
        table = []
        for pen in range(self.palette_size):
            rgb = []
            for net_weights, bits in zip(weights, self.channel_bits):
                selected = [(pen >> b) & 1 for b in bits]
                rgb.append(combine_weights(net_weights, *selected))
            table.append(tuple(rgb))
        return table


# turbo_v.cpp:290 — pots read from a real board were VR1 310R, VR2 910R.
# turbo_v.cpp:33  — R and G share {1000,470,220}; B uses the last two only.
TURBO = Game(
    name="turbo",
    vr1=310.0, vr2=910.0, cext=100e-12,
    palette_size=256,
    nets=[
        ([1000, 470, 220], 470, 0),   # red
        ([1000, 470, 220], 470, 0),   # green
        ([470, 220], 470, 0),         # blue
    ],
    channel_bits=[(0, 1, 2), (3, 4, 5), (6, 7)],
)

# turbo_v.cpp:854 — "820 verified in schematics".
# turbo_v.cpp:89  — note the shuffled blue bits: 8, 9, 6, 7 (LSB weight first).
BUCKROG = Game(
    name="buckrog",
    vr1=1.2e3, vr2=820.0, cext=220e-12,
    palette_size=1024,
    nets=[
        ([1000, 500, 250], 1000, 0),          # red
        ([1000, 500, 250], 1000, 0),          # green
        ([2200, 1000, 500, 250], 1000, 0),    # blue
    ],
    channel_bits=[(0, 1, 2), (3, 4, 5), (8, 9, 6, 7)],
)

GAMES = {g.name: g for g in (TURBO, BUCKROG)}


# --------------------------------------------------------------------------
# output
# --------------------------------------------------------------------------

def write_hex(path, values, digits, header):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="\n") as fh:
        for line in header:
            fh.write(f"// {line}\n")
        for value in values:
            fh.write(f"{value:0{digits}x}\n")
    return path


def generate(game):
    written = []

    steps = game.xscale_table()
    written.append(write_hex(
        ROMS / f"xscale_{game.name}.hex", steps, 8,
        [f"{game.name}: sprite X-scale step, Q8.24 fraction of the 2x pixel clock",
         f"VR1={game.vr1} VR2={game.vr2} Cext={game.cext}",
         "generated by tools/gen_tables.py - do not edit"]))

    palette = game.palette_table()
    packed = [(r << 16) | (g << 8) | b for r, g, b in palette]
    written.append(write_hex(
        ROMS / f"palette_{game.name}.hex", packed, 6,
        [f"{game.name}: {game.palette_size}-entry palette, 0xRRGGBB",
         "resistor-ladder DAC weights via MAME compute_resistor_weights()",
         "generated by tools/gen_tables.py - do not edit"]))

    return written


# --------------------------------------------------------------------------
# checks
# --------------------------------------------------------------------------

def check():
    """Assert the properties that would catch a real porting mistake."""
    failures = []

    def expect(condition, message):
        if condition:
            print(f"  ok    {message}")
        else:
            print(f"  FAIL  {message}")
            failures.append(message)

    for game in GAMES.values():
        print(f"\n{game.name}: X-scale")
        steps = game.xscale_table()

        # The whole memory architecture rests on this: if a single output pixel
        # could consume more than one source pixel, the sprite engine would need
        # more than one ROM fetch per level per pixel and the 8-independent-BRAM
        # plan collapses into an arbitration problem.
        expect(max(steps) < Q824_ONE,
               f"step always < 1.0 source pixel/output pixel "
               f"(max {max(steps)/Q824_ONE:.4f})")

        expect(all(b >= a for a, b in zip(steps, steps[1:])),
               "step is monotonically non-decreasing in the DAC input")
        expect(steps[0] > 0, f"step at DAC 0 is non-zero ({steps[0]/Q824_ONE:.4f})")
        expect(all(0 <= s < (1 << 32) for s in steps), "all steps fit in 32 bits")

        print(f"        DAC 0x00 -> {steps[0]/Q824_ONE:.4f}   "
              f"0x80 -> {steps[128]/Q824_ONE:.4f}   "
              f"0xff -> {steps[255]/Q824_ONE:.4f} src px/out px")

        print(f"\n{game.name}: palette")
        weights = compute_resistor_weights(0, 255, -1.0, game.nets)
        sums = [sum(w) for w in weights]
        for label, net_sum in zip("RGB", sums):
            print(f"        {label} full-scale = {net_sum:.2f}")

        # autoscale normalises the largest net to exactly 255
        expect(abs(max(sums) - 255.0) < 0.5,
               f"largest channel reaches full scale ({max(sums):.2f})")
        expect(all(s <= 255.5 for s in sums), "no channel exceeds full scale")

        table = game.palette_table()
        expect(len(table) == game.palette_size,
               f"{game.palette_size} palette entries")
        expect(table[0] == (0, 0, 0), "pen 0 is black")
        expect(all(0 <= c <= 255 for entry in table for c in entry),
               "all components in 0..255")

        # each channel must respond only to its own pen bits
        for idx, (label, bits) in enumerate(zip("RGB", game.channel_bits)):
            others = [b for i, cb in enumerate(game.channel_bits)
                      if i != idx for b in cb]
            leaked = [b for b in others if table[1 << b][idx] != 0]
            expect(not leaked,
                   f"{label} is unaffected by the other channels' pen bits")

            # ...and monotonically in weight order, LSB first
            values = [table[1 << b][idx] for b in bits]
            expect(all(x < y for x, y in zip(values, values[1:])),
                   f"{label} weights increase LSB->MSB: {values}")

    # Buck Rogers' blue channel takes pen bits 8,9,6,7 in that order. Getting the
    # shuffle wrong is invisible until the picture is subtly the wrong colour, so
    # pin it down explicitly.
    br = BUCKROG.palette_table()
    blue = [br[1 << b][2] for b in (8, 9, 6, 7)]
    print("\nbuckrog: blue bit shuffle")
    print(f"        pen bits (8,9,6,7) -> blue {blue}")
    expect(blue == sorted(blue) and len(set(blue)) == 4,
           "blue increases across pen bits 8,9,6,7 (the shuffle is applied)")
    expect(br[1 << 6][2] > br[1 << 9][2],
           "pen bit 6 outweighs pen bit 9 (bit 6 is a higher blue weight)")

    # Turbo's blue has only two of the three resistors, so it cannot reach 255.
    turbo_weights = compute_resistor_weights(0, 255, -1.0, TURBO.nets)
    blue_max = sum(turbo_weights[2])
    print("\nturbo: blue full-scale")
    print(f"        {blue_max:.2f} (red/green reach {sum(turbo_weights[0]):.2f})")
    expect(240 < blue_max < 255,
           "blue tops out just below full scale, as the 2-resistor ladder should")

    print()
    if failures:
        print(f"{len(failures)} check(s) FAILED")
        return 1
    print("all checks passed")
    return 0


def mame_palette(game):
    """Run MAME headless and read back the palette it computed. Golden reference."""
    driver = MAME_DRIVER[game.name]
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / f"{game.name}.txt"
        env = dict(os.environ, PALOUT=str(out))
        result = subprocess.run(
            [str(MAME_EXE), driver, "-video", "none", "-sound", "none",
             "-autoboot_script", str(REPO / "tools" / "mame" / "dump_palette.lua"),
             "-str", "5"],
            cwd=str(MAME_DIR), env=env, capture_output=True, text=True, timeout=180)
        if not out.exists():
            raise RuntimeError(
                f"MAME produced no palette for {driver}.\n"
                f"stdout: {result.stdout[-500:]}\nstderr: {result.stderr[-500:]}")
        return [int(line, 16) for line in out.read_text().split() if line]


def check_mame():
    """Diff every generated palette entry against MAME's own computation."""
    if not MAME_EXE.exists():
        print(f"MAME not found at {MAME_EXE} - skipping golden-reference check")
        return 0

    failures = 0
    for game in GAMES.values():
        mine = [(r << 16) | (g << 8) | b for r, g, b in game.palette_table()]
        try:
            theirs = mame_palette(game)
        except Exception as exc:                      # noqa: BLE001 - report and continue
            print(f"{game.name}: could not read MAME palette: {exc}")
            failures += 1
            continue

        if len(mine) != len(theirs):
            print(f"{game.name}: FAIL entry count, ours {len(mine)} vs MAME {len(theirs)}")
            failures += 1
            continue

        diffs = [(i, m, t) for i, (m, t) in enumerate(zip(mine, theirs)) if m != t]
        if diffs:
            print(f"{game.name}: FAIL {len(diffs)}/{len(mine)} entries differ from MAME")
            for i, m, t in diffs[:8]:
                print(f"        pen {i:4d}  ours {m:06x}  mame {t:06x}")
            failures += 1
        else:
            print(f"{game.name}: ok  all {len(mine)} palette entries match MAME exactly")

    return 1 if failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true",
                        help="verify invariants and write nothing")
    parser.add_argument("--check-mame", action="store_true",
                        help="diff the palettes against a headless MAME run")
    parser.add_argument("--game", choices=sorted(GAMES),
                        help="only generate for this game")
    args = parser.parse_args()

    if args.check or args.check_mame:
        status = check() if args.check else 0
        if args.check_mame:
            print()
            status |= check_mame()
        return status

    games = [GAMES[args.game]] if args.game else list(GAMES.values())
    for game in games:
        for path in generate(game):
            print(path.relative_to(REPO))
    return 0


if __name__ == "__main__":
    sys.exit(main())
