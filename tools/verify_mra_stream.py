#!/usr/bin/env python3
"""Regression check for the MRA ROM download stream.

Builds the ROM blob two independent ways and asserts they're byte-identical:
  1. "sequential" -- parses the actual generated .mra XML and concatenates
     its <part> elements strictly in file order, exactly like a real MRA
     loader / the mra conversion tool would. This is what ships to hardware.
  2. "absolute" -- sim/build_rom.py, which writes each region directly at
     its REGIONS offset into a pre-allocated buffer.

These two only agree if REGIONS' base offsets are perfectly contiguous (see
the comment on REGIONS in tools/gen_mra.py). A gap between two regions is
invisible to sim/build_rom.py (it writes at absolute offsets regardless) but
corrupts the real sequential stream -- exactly the bug this script exists to
catch: an earlier version of REGIONS had "nice round hex" bases that didn't
actually tile with the region sizes, and every hardware test failed while
every simulation run passed, because the sim harness's ROM loading never
exercised the failure mode at all.

Usage: python tools/verify_mra_stream.py [game ...]
  Defaults to every game in tools/gen_mra.py's GAMES dict.
Exits non-zero if any game's two builds disagree.
"""
import sys
import os
import zipfile
import xml.etree.ElementTree as ET

sys.path.insert(0, os.path.join(os.path.dirname(__file__)))
from gen_mra import GAMES, build_mra  # noqa: E402

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "sim"))
from build_rom import build_blob  # noqa: E402

MAME_ROMS_DIR = "C:/MiSTerDev/mame/roms"


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


def build_sequential_stream(game):
    """Reproduce exactly what a real MRA loader streams: <part> elements in
    file order, no knowledge of REGIONS offsets at all."""
    xml_text = build_mra(game)
    root = ET.fromstring(xml_text)
    rom_el = root.find("rom")
    zip_paths = [os.path.join(MAME_ROMS_DIR, z.strip()) for z in rom_el.attrib["zip"].split("|")]
    crc_map = load_crc_map(zip_paths)

    stream = bytearray()
    for part in rom_el.findall("part"):
        if "repeat" in part.attrib:
            n = int(part.attrib["repeat"])
            val = bytes.fromhex((part.text or "00").strip())
            if not val:
                val = b"\x00"
            reps = (n // len(val)) + 1
            stream += (val * reps)[:n]
        elif "crc" in part.attrib:
            crc = int(part.attrib["crc"], 16)
            if crc not in crc_map:
                raise KeyError(f"part crc {part.attrib['crc']} not found in {zip_paths}")
            stream += crc_map[crc]
        else:
            stream += bytes.fromhex((part.text or "").strip())
    return bytes(stream)


def main():
    games = sys.argv[1:] or list(GAMES.keys())
    failed = []
    for game_key in games:
        game = GAMES[game_key]
        sequential = build_sequential_stream(game)
        absolute = build_blob(game_key, MAME_ROMS_DIR)
        if sequential == absolute:
            print(f"{game_key}: OK ({len(sequential)} bytes, sequential == absolute)")
        else:
            failed.append(game_key)
            print(f"{game_key}: MISMATCH! sequential={len(sequential)} bytes, absolute={len(absolute)} bytes")
            n = min(len(sequential), len(absolute))
            for i in range(n):
                if sequential[i] != absolute[i]:
                    print(f"  first diff at offset {i:#x}: sequential={sequential[i]:02x} absolute={absolute[i]:02x}")
                    break

    if failed:
        print(f"\nFAILED: {', '.join(failed)}")
        sys.exit(1)
    print("\nAll games OK.")


if __name__ == "__main__":
    main()
