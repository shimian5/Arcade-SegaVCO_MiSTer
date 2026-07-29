#!/usr/bin/env python3
"""Golden (software) re-implementation of MAME's buckrog sprite path, driven
from the RTL's OWN sprram/sprpos/obch snapshot (dumped by
rtl/video/sprite_engine.v's VERILATOR_SIM block via `make -C sim dump`),
instead of MAME's own runtime state -- so this is comparable to the RTL
output for the exact same frame, with no "different game state" variable.

Literal, line-for-line transcription of:
  buckrog_state::prepare_sprites   docs/reference/turbo_v.cpp:803-857
  buckrog_state::get_sprite_bits   docs/reference/turbo_v.cpp:860-906
  the he/lst logic + `for (ix...)` loop from
  buckrog_state::screen_update     docs/reference/turbo_v.cpp:924-966
(sprite path only -- no foreground/star/palette mixing, since that's not
needed to compare sprbits/plb).

Inputs:
  sim/out/dbg_sprram.hex, dbg_sprpos_lo.hex, dbg_sprpos_hi.hex   (Deliverable 1)
  sim/buckrogn.rom               sprite ROMs + PR-5196 (see sim/build_rom.py)
  roms/xscale_buckrog.hex        X-scale step table (tools/gen_tables.py)

Outputs:
  sim/out/dbg_golden_spr.bin     512*224*5 bytes, same layout as dbg_rtl_spr.bin
  sim/out/dbg_golden_levels.txt  same layout as dbg_rtl_levels.txt

Usage: python3 sim/golden_buckrog.py [--rom sim/buckrogn.rom] [--rows 224]
"""
import argparse
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

ACTIVE_W = 512
ACTIVE_H = 224
TURBO_X_SCALE = 2
XSCALE_THRESHOLD = 0x800000

# turbo_v.cpp:867
PLB_END = [0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 2]

# turbo_v.cpp:17
SPRITE_EXPAND = [
    0x00000000, 0x00000001, 0x00000100, 0x00000101,
    0x00010000, 0x00010001, 0x00010100, 0x00010101,
    0x01000000, 0x01000001, 0x01000100, 0x01000101,
    0x01010000, 0x01010001, 0x01010100, 0x01010101,
]

# gen_mra.py REGIONS / GAMES["buckrogn"] -- absolute offsets in the flat
# ioctl-download blob build_rom.py produces.
PROMS_BASE   = 0x00B000
PR5196_OFF   = PROMS_BASE + 0x100   # 512 bytes
SPRITES_BASE = 0x015000              # 8 levels x 32KB, level = addr>>15


def read_hex_bytes(path, count):
    """Parse a $writememh dump: one hex token per line, tolerating '@addr'
    lines (verilator emits these when it needs to restate the address) and
    '//' comment lines (used by tools/gen_tables.py's hex files)."""
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("//"):
                continue
            if line.startswith("@"):
                continue
            vals.append(int(line, 16))
    if len(vals) != count:
        raise ValueError(f"{path}: expected {count} values, got {len(vals)}")
    return vals


def load_inputs(out_dir, roms_dir, rom_path):
    sprram = read_hex_bytes(os.path.join(out_dir, "dbg_sprram.hex"), 128)
    sprpos_lo = read_hex_bytes(os.path.join(out_dir, "dbg_sprpos_lo.hex"), 256)
    sprpos_hi = read_hex_bytes(os.path.join(out_dir, "dbg_sprpos_hi.hex"), 256)
    with open(os.path.join(out_dir, "dbg_obch.hex")) as f:
        obch = int(f.read().strip(), 16)

    xscale = read_hex_bytes(os.path.join(roms_dir, "xscale_buckrog.hex"), 256)

    with open(rom_path, "rb") as f:
        blob = f.read()
    pr5196 = blob[PR5196_OFF:PR5196_OFF + 512]
    spriteroms = [blob[SPRITES_BASE + lvl * 0x8000: SPRITES_BASE + (lvl + 1) * 0x8000]
                  for lvl in range(8)]

    return sprram, sprpos_lo, sprpos_hi, obch, xscale, pr5196, spriteroms


def prepare_sprites(y, sprram, xscale, pr5196, level_state):
    """turbo_v.cpp:803-857, literal port.

    Mutates `sprram` in place (rambase[6]/[7] offset writeback) exactly like
    MAME/the RTL, and updates `level_state[level]` (dict with
    offset/step/frac/latched/plb) in place ONLY for levels whose owning
    sprite fires this scanline -- levels that don't fire keep whatever
    get_sprite_bits() last left them at (this is not a bug, it's the literal
    behavior of both MAME and the RTL: see sprite_engine.v's commit_now).

    Returns `ve`, the 16-bit per-sprnum enable mask (this one IS recomputed
    fresh every call, matching `m_sprite_info.ve = 0` at line 808).
    """
    ve = 0

    for sprnum in range(16):
        base = sprnum * 8
        rambase = sprram  # mutate the real array via rambase[base+n]
        level = sprnum & 7

        sum_ = (y + rambase[base + 0]) & 0xFFFFFFFF
        clo = (sum_ >> 8) & 1
        sum_ = (sum_ + (y << 8) + (rambase[base + 1] << 8)) & 0xFFFFFFFF
        chi = (sum_ >> 16) & 1

        if clo & (chi ^ 1):
            xscale_raw = rambase[base + 2] ^ 0xFF
            yscale = rambase[base + 3]
            offset = rambase[base + 6] + (rambase[base + 7] << 8)

            ve |= 1 << sprnum

            offs = (sum_ & 0xFF) | ((yscale & 0x08) << 5)
            if not ((pr5196[offs] >> (yscale & 0x07)) & 1):
                offset = (offset + rambase[base + 4] + (rambase[base + 5] << 8)) & 0xFFFF
                rambase[base + 6] = offset & 0xFF
                rambase[base + 7] = (offset >> 8) & 0xFF

            level_state[level] = {
                "latched": 0,
                "plb": 0,
                "offset": (offset << 1) & 0xFFFFFFFF,
                "frac": 0,
                "step": xscale[xscale_raw],
            }

    return ve


def get_sprite_bits(lst, level_state, spriteroms):
    """turbo_v.cpp:860-906, literal port. Returns (sprdata, plb, new_lst)."""
    sprdata = 0
    plb = 0

    for level in range(8):
        if lst & (1 << level):
            st = level_state[level]
            sprdata |= st["latched"]
            plb |= st["plb"]
            st["frac"] = (st["frac"] + st["step"]) & 0xFFFFFFFF

            while st["frac"] >= XSCALE_THRESHOLD:
                offs = st["offset"]
                romaddr = (offs >> 1) & 0x7FFF
                byte = spriteroms[level][romaddr]
                pixdata = (byte >> ((~offs & 1) * 4)) & 0x0F

                st["latched"] = SPRITE_EXPAND[pixdata] << level
                st["plb"] = (PLB_END[pixdata] & 1) << level

                if PLB_END[pixdata] & 2:
                    lst &= ~(1 << level)

                st["offset"] = (offs + (-1 if (offs & 0x10000) else 1)) & 0xFFFFFFFF
                st["frac"] -= XSCALE_THRESHOLD

    return sprdata, plb, lst


def run(sprram, sprpos_lo, sprpos_hi, obch, xscale, pr5196, spriteroms, rows):
    level_state = {lvl: {"latched": 0, "plb": 0, "offset": 0, "frac": 0, "step": 0}
                   for lvl in range(8)}
    lst = 0  # persists across scanlines (only cleared explicitly below, matching m_sprite_info.lst)

    spr_out = bytearray(ACTIVE_W * rows * 5)
    level_lines = []

    for y in range(rows):
        lst = 0  # turbo_v.cpp:809 -- prepare_sprites() zeroes lst at the top of every call
        ve = prepare_sprites(y, sprram, xscale, pr5196, level_state)

        for lvl in range(8):
            st = level_state[lvl]
            ve_field = (1 if (ve & (1 << lvl)) else 0) | (2 if (ve & (1 << (lvl + 8))) else 0)
            level_lines.append(f"y={y} lvl={lvl} step={st['step']:08x} offset={st['offset']:05x} ve={ve_field}\n")

        for xx in range(ACTIVE_W // TURBO_X_SCALE):
            he = sprpos_lo[xx] | (sprpos_hi[xx] << 8)
            he &= ve
            lst |= (he & 0xFF) | (he >> 8)

            for ix in range(TURBO_X_SCALE):
                x = xx * TURBO_X_SCALE + ix
                sprdata, plb, lst = get_sprite_bits(lst, level_state, spriteroms)
                idx = (y * ACTIVE_W + x) * 5
                spr_out[idx + 0] = sprdata & 0xFF
                spr_out[idx + 1] = (sprdata >> 8) & 0xFF
                spr_out[idx + 2] = (sprdata >> 16) & 0xFF
                spr_out[idx + 3] = (sprdata >> 24) & 0xFF
                spr_out[idx + 4] = plb & 0xFF

    return spr_out, level_lines


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--rom", default=os.path.join(REPO, "sim", "buckrogn.rom"))
    ap.add_argument("--out-dir", default=os.path.join(REPO, "sim", "out"))
    ap.add_argument("--roms-dir", default=os.path.join(REPO, "roms"))
    ap.add_argument("--rows", type=int, default=ACTIVE_H,
                     help="scanlines to simulate (MAME only calls prepare_sprites for "
                          "the visible rows, 0..223 -- see report notes on vblank rows)")
    args = ap.parse_args()

    sprram, sprpos_lo, sprpos_hi, obch, xscale, pr5196, spriteroms = load_inputs(
        args.out_dir, args.roms_dir, args.rom)

    spr_out, level_lines = run(sprram, sprpos_lo, sprpos_hi, obch, xscale, pr5196, spriteroms, args.rows)

    spr_path = os.path.join(args.out_dir, "dbg_golden_spr.bin")
    with open(spr_path, "wb") as f:
        f.write(spr_out)
    print(f"wrote {spr_path}: {len(spr_out)} bytes")

    lvl_path = os.path.join(args.out_dir, "dbg_golden_levels.txt")
    with open(lvl_path, "w", newline="\n") as f:
        f.writelines(level_lines)
    print(f"wrote {lvl_path}: {len(level_lines)} lines")


if __name__ == "__main__":
    sys.exit(main())
