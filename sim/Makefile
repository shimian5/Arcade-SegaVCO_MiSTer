# Verilator harness for rtl/z80_3d.v (phase 1a).
#
# Requires Verilator (WSL2/Linux -- this repo has it under the "archlinux"
# WSL distro; there is no Windows-native Verilator in this environment).
# Run via: wsl -d archlinux -e make -C /mnt/c/.../sim
#
# T80 (VHDL) is not part of this build -- Verilator can't compile VHDL.
# cpu_z80.v selects TV80 (pure Verilog) instead when VERILATOR_SIM is
# defined; see rtl/cpu_z80.v.

VERILATOR ?= verilator
TOP = z80_3d

RTL_DIR = ../rtl

SOURCES = \
	$(RTL_DIR)/z80_3d.v \
	$(RTL_DIR)/cpu_z80.v \
	$(RTL_DIR)/rom_download.v \
	$(RTL_DIR)/video/video_timing.v \
	$(RTL_DIR)/video/fg_tilemap.v \
	$(RTL_DIR)/video/sprite_engine.v \
	$(RTL_DIR)/io/i8255.v \
	$(RTL_DIR)/io/i8279.v \
	$(RTL_DIR)/tv80/rtl/core/tv80_core.v \
	$(RTL_DIR)/tv80/rtl/core/tv80_alu.v \
	$(RTL_DIR)/tv80/rtl/core/tv80_mcode.v \
	$(RTL_DIR)/tv80/rtl/core/tv80_reg.v

VFLAGS = --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE \
	+define+VERILATOR_SIM -Mdir obj_dir --top-module $(TOP) -O2

all: obj_dir/V$(TOP)

obj_dir/V$(TOP): $(SOURCES) tb_z80_3d.cpp
	$(VERILATOR) $(VFLAGS) $(SOURCES) tb_z80_3d.cpp

# z80_3d.v does $readmemh("roms/palette_buckrog.hex", ...) relative to the
# repo root, so the built binary must be run with cwd = repo root, not sim/.
run: obj_dir/V$(TOP) buckrogn.rom
	mkdir -p out
	cd .. && sim/obj_dir/V$(TOP) --rom sim/buckrogn.rom --frames 410 --out sim/out/buckrogn_

buckrogn.rom:
	python3 build_rom.py buckrogn buckrogn.rom /mnt/c/MiSTerDev/mame/roms

# Phase0-1a sprite debug harness: dump the RTL's sprite-engine inputs
# (dbg_sprram*.hex, dbg_sprpos_*.hex, dbg_obch*.hex from sprite_engine.v),
# per-scanline level state (dbg_rtl_levels.txt) and per-pixel outputs
# (dbg_rtl_spr.bin) for frame 150 (title-logo screen, matches
# tools/mame/dump_frames.lua's start1 schedule -- see tb_z80_3d.cpp). Only
# runs 151 frames (not the full 410) since nothing past frame 150 is needed.
dump: obj_dir/V$(TOP) buckrogn.rom
	mkdir -p out
	cd .. && sim/obj_dir/V$(TOP) --rom sim/buckrogn.rom --frames 152 --out sim/out/dbg_ --dumpframe 150

clean:
	rm -rf obj_dir out *.rom

.PHONY: all run dump clean
