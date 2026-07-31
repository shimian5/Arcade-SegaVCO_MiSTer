# Verilator harness for rtl/z80_3d.v (phase 1a).
#
# Requires Verilator (WSL2/Linux -- this repo has it under the "archlinux"
# WSL distro; there is no Windows-native Verilator in this environment).
# Run via: wsl -d archlinux -e make -C /mnt/c/.../sim
#
# cpu_z80.v always instantiates TV80 (pure Verilog) -- T80 (VHDL) has been
# removed from the project entirely; see rtl/cpu_z80.v.

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
	$(wildcard $(RTL_DIR)/audio/*.sv) \
	$(RTL_DIR)/io/i8255.v \
	$(RTL_DIR)/io/i8279.v \
	$(RTL_DIR)/tv80/rtl/core/tv80_core.v \
	$(RTL_DIR)/tv80/rtl/core/tv80_alu.v \
	$(RTL_DIR)/tv80/rtl/core/tv80_mcode.v \
	$(RTL_DIR)/tv80/rtl/core/tv80_reg.v

# TV80_REFRESH: real Z80 I/R (memory-refresh) register behavior -- must
# match the Quartus build (Arcade-Z80-3D.qsf's VERILOG_MACRO) so sim results
# stay representative of hardware. See Arcade-Z80-3D.qsf's comment: without
# this, `LD A,R` is hardcoded to 0, which broke Buck Rogers' sub-CPU
# star-field LFSR (it seeds from R).
VFLAGS = --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE \
	+define+VERILATOR_SIM +define+TV80_REFRESH -Mdir obj_dir --top-module $(TOP) -O2

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

# ---------------------------------------------------------------------------
# Discrete-audio harness (rtl/audio -> WAV). Independent of the z80_3d rules
# above: separate obj dir, separate output dir, separate target names, so
# `make` / `make run` keep meaning exactly what they always meant.
#
#   make audio        build the audio sim
#   make audio-run    render all six ALARM scenarios to out/audio/scenN.wav
#   make audio-clean
#
# Analyse the results from the repo root with:
#   python tools/analyze_audio.py sim/out/audio/*.wav
# ---------------------------------------------------------------------------
AUDIO_TOP     = audio_top
AUDIO_OBJ_DIR = obj_dir_audio
AUDIO_OUT_DIR = out/audio
AUDIO_SOURCES = $(wildcard ../rtl/audio/*.sv)

AUDIO_VFLAGS = --cc --exe --build -Wno-fatal -Mdir $(AUDIO_OBJ_DIR) \
	--top-module $(AUDIO_TOP) -O2

.PHONY: audio audio-run audio-clean

audio: $(AUDIO_OBJ_DIR)/V$(AUDIO_TOP)

$(AUDIO_OBJ_DIR)/V$(AUDIO_TOP): $(AUDIO_SOURCES) audio_tb.cpp
	$(VERILATOR) $(AUDIO_VFLAGS) $(AUDIO_SOURCES) audio_tb.cpp

audio-run: $(AUDIO_OBJ_DIR)/V$(AUDIO_TOP)
	mkdir -p $(AUDIO_OUT_DIR)
	for s in 0 1 2 3 4 5 6 7 8 9 10 11; do ./$(AUDIO_OBJ_DIR)/V$(AUDIO_TOP) $$s; done

audio-clean:
	rm -rf $(AUDIO_OBJ_DIR) $(AUDIO_OUT_DIR)
