#!/usr/bin/env python3
"""Build the flat ioctl-download ROM blob for a game, straight from the real
MAME ROM zips, using the exact same region layout as tools/gen_mra.py (so the
sim harness loads bytes at the same offsets rom_download.v expects).

MAME's zip entry filenames don't always match the "part name" used in
ROM_LOAD/MRA (e.g. buckrogn.zip's cpu-ic3.bin vs the driver's
epr-5257.cpu-ic3), so parts are matched by CRC32, not filename.

Usage: python sim/build_rom.py <game> <output.rom> [mame_roms_dir]
  <game>          one of tools/gen_mra.py's GAMES keys (e.g. buckrogn)
  mame_roms_dir   defaults to C:/MiSTerDev/mame/roms
"""
import sys
import os
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
from gen_mra import GAMES, REGIONS, region_blob  # noqa: E402

REGION_ORDER = ["maincpu", "subcpu", "fgtiles", "proms", "road", "bgcolor", "sprites"]


def load_crc_map(zip_paths):
    crc_map = {}
    for zp in zip_paths:
        if not os.path.exists(zp):
            continue
        with zipfile.ZipFile(zp) as zf:
            for info in zf.infolist():
                if info.CRC not in crc_map:
                    crc_map[info.CRC] = zf.read(info)
    return crc_map


def build_blob(game_key, mame_roms_dir):
    game = GAMES[game_key]
    zip_names = [z.strip() for z in game["zip"].split("|")]
    zip_paths = [os.path.join(mame_roms_dir, z) for z in zip_names]
    crc_map = load_crc_map(zip_paths)

    total_size = max(base + size for base, size in REGIONS.values())
    blob = bytearray([0xFF]) * total_size

    for region_name in REGION_ORDER:
        if region_name not in game["regions"]:
            continue
        base, size = REGIONS[region_name]
        parts = game["regions"][region_name]
        blob_plan = region_blob(parts, size)
        cursor = base
        for item in blob_plan:
            if item[0] == "FILL":
                cursor += item[1]
            else:
                _, name, psize, crc_hex = item
                crc = int(crc_hex, 16)
                if crc not in crc_map:
                    raise KeyError(f"{game_key}: part {name} (crc {crc_hex}) not found in {zip_paths}")
                data = crc_map[crc]
                if len(data) != psize:
                    raise ValueError(f"{name}: expected {psize} bytes, zip has {len(data)}")
                blob[cursor:cursor + psize] = data
                cursor += psize
    return bytes(blob)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    game_key = sys.argv[1]
    out_path = sys.argv[2]
    mame_roms_dir = sys.argv[3] if len(sys.argv) > 3 else "C:/MiSTerDev/mame/roms"

    blob = build_blob(game_key, mame_roms_dir)
    with open(out_path, "wb") as f:
        f.write(blob)
    print(f"wrote {out_path}: {len(blob)} bytes ({len(blob)/1024:.1f} KB)")


if __name__ == "__main__":
    main()
