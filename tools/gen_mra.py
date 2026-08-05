#!/usr/bin/env python3
"""Generate MRA files for the SegaVCO core from the ROM lists transcribed out of
docs/reference/turbo.cpp's ROM_START blocks.

Each game's ROM regions are laid out at fixed offsets in the ioctl download
blob (see docs/PLAN.md "ROM loading" table). Within a region, parts are placed
at the same relative offsets MAME's ROM_LOAD lines use, and any gap either
between parts or at the end of the region is filled with 0xFF.

Usage: python tools/gen_mra.py
Writes mra/<game>.mra for every entry in GAMES.
"""
import os

# Fixed region offsets/sizes in the combined ROM blob, shared by every game.
# MUST be perfectly contiguous (each BASE == previous BASE+SIZE): the MRA
# generator below emits <part> elements strictly back-to-back with no
# inter-slot padding (only region_blob()'s intra-slot filling), since MRA is
# a sequential byte stream, not an addressed one. An earlier version of this
# table used "nice round hex" BASE offsets that didn't actually tile with
# the sizes (gaps after fgtiles and after road/bgcolor) -- invisible in
# sim/build_rom.py (which writes at absolute offsets, immune to stream-order
# bugs) but fatal on real hardware: everything from PROMS onward arrived at
# the wrong ioctl_addr window and got silently dropped by rom_download.v's
# decode. Keep rtl/rom_download.v's localparams byte-identical to this.
#
# (PROMS is 0x2000, not the original 0x1000 draft: Turbo's proms region is
# 0x1020 bytes, just over 4KB, so the slot needs headroom.)
REGIONS = {
    "maincpu":  (0x000000, 0x8000),
    "subcpu":   (0x008000, 0x2000),
    "fgtiles":  (0x00A000, 0x1000),
    "proms":    (0x00B000, 0x2000),
    "road":     (0x00D000, 0x8000),   # Turbo road / Buck Rogers bgcolor share this slot
    "bgcolor":  (0x00D000, 0x8000),
    "sprites":  (0x015000, 0x40000),
}
BLOB_SIZE = 0x055000

def region_blob(parts, region_size):
    """parts: list of (name, offset, size, crc) as transcribed from ROM_LOAD.
    Returns list of ('DATA', name, size, crc) | ('FILL', nbytes) covering the
    whole region_size, gaps filled with 0xFF."""
    parts = sorted(parts, key=lambda p: p[1])
    out = []
    cursor = 0
    for name, offset, size, crc in parts:
        if offset > cursor:
            out.append(("FILL", offset - cursor))
        elif offset < cursor:
            raise ValueError(f"overlapping ROM part {name} at {offset:#x}, cursor {cursor:#x}")
        out.append(("DATA", name, size, crc))
        cursor = offset + size
    if cursor > region_size:
        raise ValueError(f"parts overflow region size {region_size:#x} (cursor {cursor:#x})")
    if cursor < region_size:
        out.append(("FILL", region_size - cursor))
    return out

def build_rom_xml(game):
    lines = []
    zip_attr = game["zip"]
    lines.append(f'  <rom index="0" zip="{zip_attr}" md5="none">')
    # "road" (Turbo) and "bgcolor" (Buck Rogers) are mutually exclusive
    # alternatives sharing the SAME address slot (see REGIONS) -- each game
    # defines at most one of the two, so they must be emitted as a single
    # slot, not iterated independently (that would double-emit the slot: a
    # full-size filler for the absent one, then the real data for the
    # present one, shifting every region after it -- i.e. all of "sprites"
    # -- later in the stream than rom_download.v expects).
    slots = [["maincpu"], ["subcpu"], ["fgtiles"], ["proms"], ["road", "bgcolor"], ["sprites"]]
    for slot in slots:
        region_name = next((n for n in slot if n in game["regions"]), None)
        if region_name is None:
            # No parts for this slot in this game -- fill the whole slot.
            # All names in a slot share the same REGIONS entry, so any works.
            _, size = REGIONS[slot[0]]
            lines.append(f'    <part repeat="{size}">FF</part> <!-- {"/".join(slot)} (unused) -->')
            continue
        _, size = REGIONS[region_name]
        blob = region_blob(game["regions"][region_name], size)
        lines.append(f'    <!-- {region_name} @ {REGIONS[region_name][0]:#08x}, {size:#x} bytes -->')
        for item in blob:
            if item[0] == "DATA":
                _, name, psize, crc = item
                lines.append(f'    <part name="{name}" crc="{crc}"/>')
            else:
                _, n = item
                lines.append(f'    <part repeat="{n}">FF</part>')
    lines.append('  </rom>')
    return "\n".join(lines)

def build_dip_xml(game):
    return game.get("dips", "")

def build_mod_xml(game):
    # One-RBF game strap (docs/WORKPLAN_TURBO_GRAPHICS.md Step 1): a single
    # byte at ioctl_index 1, latched into mod_game in Arcade-SegaVCO.sv.
    # 00 = Buck Rogers, 01 = Turbo.
    return f'  <rom index="1"><part>{game["mod"]:02X}</part></rom>'

def build_mra(game):
    rom_xml = build_rom_xml(game)
    mod_xml = build_mod_xml(game)
    dip_xml = build_dip_xml(game)
    xml = f'''<misterromdescription>
  <name>{game["name"]}</name>
  <setname>{game["setname"]}</setname>
  <year>{game["year"]}</year>
  <manufacturer>{game["manufacturer"]}</manufacturer>
  <rbf>Arcade-SegaVCO</rbf>
{rom_xml}
{mod_xml}
{dip_xml}
</misterromdescription>
'''
    return xml

GAMES = {
    "buckrogn": {
        "name": "Buck Rogers: Planet of Zoom (not encrypted)",
        "setname": "buckrogn",
        "zip": "buckrogn.zip|buckrog.zip",
        "year": 1982,
        "manufacturer": "Sega",
        "mod": 0,
        "regions": {
            "maincpu": [
                ("epr-5257.cpu-ic3", 0x0000, 0x4000, "7f1910af"),
                ("epr-5258.cpu-ic4", 0x4000, 0x4000, "5ecd393b"),
            ],
            "subcpu": [
                ("epr-5200.cpu-ic66", 0x0000, 0x1000, "0d58b154"),
            ],
            "fgtiles": [
                ("epr-5201.cpu-ic102", 0x0000, 0x0800, "7f21b0a4"),
                ("epr-5202.cpu-ic103", 0x0800, 0x0800, "43f3e5a7"),
            ],
            "bgcolor": [
                ("epr-5203.cpu-ic91", 0x0000, 0x2000, "631f5b65"),
            ],
            "proms": [
                ("pr-5194.cpu-ic39", 0x0000, 0x0020, "bc88cced"),
                ("pr-5195.cpu-ic53", 0x0020, 0x0020, "181c6d23"),
                ("pr-5196.cpu-ic10", 0x0100, 0x0200, "04204bcf"),
                ("pr-5197.cpu-ic78", 0x0300, 0x0200, "a42674af"),
                ("pr-5198.cpu-ic93", 0x0500, 0x0200, "32e74bc8"),
                ("pr-5199.cpu-ic95", 0x0700, 0x0400, "45e997a8"),
            ],
            "sprites": [
                ("epr-5216.prom-ic100", 0x00000, 0x2000, "8155bd73"),
                ("epr-5213.prom-ic84",  0x08000, 0x2000, "fd78dda4"),
                ("epr-5262.prom-ic68",  0x10000, 0x4000, "2a194270"),
                ("epr-5260.prom-ic52",  0x18000, 0x4000, "b31a120f"),
                ("epr-5259.prom-ic43",  0x20000, 0x4000, "d3584926"),
                ("epr-5261.prom-ic59",  0x28000, 0x4000, "d83c7fcf"),
                ("epr-5208.prom-ic58",  0x2c000, 0x2000, "d181fed2"),
                ("epr-5263.prom-ic75",  0x30000, 0x4000, "1bd6e453"),
                ("epr-5237.prom-ic74",  0x34000, 0x2000, "c34e9b82"),
                ("epr-5264.prom-ic91",  0x38000, 0x4000, "221f4ced"),
                ("epr-5238.prom-ic90",  0x3c000, 0x2000, "7aff0886"),
            ],
        },
    },
    "buckrog": {
        "name": "Buck Rogers: Planet of Zoom (encrypted, 315-5014)",
        "setname": "buckrog",
        "zip": "buckrog.zip",
        "year": 1982,
        "manufacturer": "Sega",
        "mod": 0,
        "regions": {
            "maincpu": [
                ("epr-5265.cpu-ic3", 0x0000, 0x4000, "f0055e97"),
                ("epr-5266.cpu-ic4", 0x4000, 0x4000, "7d084c39"),
            ],
            "subcpu": [
                ("epr-5200.cpu-ic66", 0x0000, 0x1000, "0d58b154"),
            ],
            "fgtiles": [
                ("epr-5201.cpu-ic102", 0x0000, 0x0800, "7f21b0a4"),
                ("epr-5202.cpu-ic103", 0x0800, 0x0800, "43f3e5a7"),
            ],
            "bgcolor": [
                ("epr-5203.cpu-ic91", 0x0000, 0x2000, "631f5b65"),
            ],
            "proms": [
                ("pr-5194.cpu-ic39", 0x0000, 0x0020, "bc88cced"),
                ("pr-5195.cpu-ic53", 0x0020, 0x0020, "181c6d23"),
                ("pr-5196.cpu-ic10", 0x0100, 0x0200, "04204bcf"),
                ("pr-5197.cpu-ic78", 0x0300, 0x0200, "a42674af"),
                ("pr-5198.cpu-ic93", 0x0500, 0x0200, "32e74bc8"),
                ("pr-5233.cpu-ic95", 0x0700, 0x0400, "1cd08c4e"),
            ],
            "sprites": [
                ("epr-5216.prom-ic100", 0x00000, 0x2000, "8155bd73"),
                ("epr-5213.prom-ic84",  0x08000, 0x2000, "fd78dda4"),
                ("epr-5262.prom-ic68",  0x10000, 0x4000, "2a194270"),
                ("epr-5260.prom-ic52",  0x18000, 0x4000, "b31a120f"),
                ("epr-5259.prom-ic43",  0x20000, 0x4000, "d3584926"),
                ("epr-5261.prom-ic59",  0x28000, 0x4000, "d83c7fcf"),
                ("epr-5208.prom-ic58",  0x2c000, 0x2000, "d181fed2"),
                ("epr-5263.prom-ic75",  0x30000, 0x4000, "1bd6e453"),
                ("epr-5237.prom-ic74",  0x34000, 0x2000, "c34e9b82"),
                ("epr-5264.prom-ic91",  0x38000, 0x4000, "221f4ced"),
                ("epr-5238.prom-ic90",  0x3c000, 0x2000, "7aff0886"),
            ],
        },
    },
    "turbo": {
        "name": "Turbo",
        "setname": "turbo",
        "zip": "turbo.zip",
        "year": 1981,
        "manufacturer": "Sega",
        "mod": 1,
        "regions": {
            "maincpu": [
                ("epr-1513.cpu-ic76",  0x0000, 0x2000, "0326adfc"),
                ("epr-1514.cpu-ic89",  0x2000, 0x2000, "25af63b0"),
                ("epr-1515.cpu-ic103", 0x4000, 0x2000, "059c1c36"),
            ],
            "fgtiles": [
                ("epr-1244.cpu-ic111", 0x0000, 0x0800, "17f67424"),
                ("epr-1245.cpu-ic122", 0x0800, 0x0800, "2ba0b46b"),
            ],
            "road": [
                ("epr-1125.cpu-ic1",  0x0000, 0x0800, "65b5d44b"),
                ("epr-1126.cpu-ic2",  0x0800, 0x0800, "685ace1b"),
                ("epr-1127.cpu-ic13", 0x1000, 0x0800, "9233c9ca"),
                ("epr-1238.cpu-ic14", 0x1800, 0x0800, "d94fd83f"),
                ("epr-1239.cpu-ic27", 0x2000, 0x0800, "4c41124f"),
                ("epr-1240.cpu-ic28", 0x2800, 0x0800, "371d6282"),
                ("epr-1241.cpu-ic41", 0x3000, 0x0800, "1109358a"),
                ("epr-1242.cpu-ic42", 0x3800, 0x0800, "04866769"),
                ("epr-1243.cpu-ic74", 0x4000, 0x0800, "29854c48"),
            ],
            "proms": [
                ("pr-1114.prom-ic13",  0x0000, 0x0020, "78aded46"),
                ("pr-1115.prom-ic18",  0x0020, 0x0020, "5394092c"),
                ("pr-1116.prom-ic20",  0x0040, 0x0020, "3956767d"),
                ("pr-1117.prom-ic21",  0x0060, 0x0020, "f06d9907"),
                ("pr-1118.cpu-ic99",   0x0100, 0x0100, "07324cfd"),
                ("pr-1119.cpu-ic50",   0x0200, 0x0200, "57ebd4bc"),
                ("pr-1120.cpu-ic62",   0x0400, 0x0200, "8dd4c8a8"),
                ("pr-1121.prom-ic29",  0x0600, 0x0200, "7692f497"),
                ("pr-1122.prom-ic11",  0x0800, 0x0400, "1a86ce70"),
                ("pr-1123.prom-ic12",  0x0c00, 0x0400, "02d2cb52"),
                ("pr-1279.sound-ic40", 0x1000, 0x0020, "b369a6ae"),
            ],
            "sprites": [
                ("epr-1246.prom-ic84",  0x00000, 0x2000, "555bfe9a"),
                ("epr-1247.prom-ic86",  0x04000, 0x2000, "c8c5e4d5"),
                ("epr-1248.prom-ic88",  0x08000, 0x2000, "82fe5b94"),
                ("epr-1249.prom-ic90",  0x0c000, 0x2000, "e258e009"),
                ("epr-1250.prom-ic108", 0x0e000, 0x2000, "aee6e05e"),
                ("epr-1251.prom-ic92",  0x10000, 0x2000, "292573de"),
                ("epr-1252.prom-ic110", 0x12000, 0x2000, "aee6e05e"),
                ("epr-1253.prom-ic94",  0x14000, 0x2000, "92783626"),
                ("epr-1254.prom-ic112", 0x16000, 0x2000, "aee6e05e"),
                ("epr-1255.prom-ic32",  0x18000, 0x2000, "485dcef9"),
                ("epr-1256.prom-ic47",  0x1a000, 0x2000, "aee6e05e"),
                ("epr-1257.prom-ic34",  0x1c000, 0x2000, "4ca984ce"),
                ("epr-1258.prom-ic49",  0x1e000, 0x2000, "aee6e05e"),
            ],
        },
    },
}

def main():
    out_dir = os.path.join(os.path.dirname(__file__), "..", "mra")
    os.makedirs(out_dir, exist_ok=True)
    for setname, game in GAMES.items():
        xml = build_mra(game)
        path = os.path.join(out_dir, f"{setname}.mra")
        with open(path, "w", newline="\n") as f:
            f.write(xml)
        print(f"wrote {path}")

if __name__ == "__main__":
    main()
