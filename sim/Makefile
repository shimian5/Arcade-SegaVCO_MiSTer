# Verilator harness for rtl/segavco.v (phase 1a).
#
# Requires Verilator (WSL2/Linux -- this repo has it under the "archlinux"
# WSL distro; there is no Windows-native Verilator in this environment).
# Run via: wsl -d archlinux -e make -C /mnt/c/.../sim
#
# cpu_z80.v always instantiates TV80 (pure Verilog) -- T80 (VHDL) has been
# removed from the project entirely; see rtl/cpu_z80.v.

VERILATOR ?= verilator
TOP = segavco

RTL_DIR = ../rtl

SOURCES = \
	$(RTL_DIR)/segavco.v \
	$(RTL_DIR)/cpu_z80.v \
	$(RTL_DIR)/rom_download.v \
	$(RTL_DIR)/video/video_timing.v \
	$(RTL_DIR)/video/fg_tilemap.v \
	$(RTL_DIR)/video/sprite_engine.v \
	$(RTL_DIR)/video/road_gen.v \
	$(RTL_DIR)/video/mixer_turbo.v \
	$(wildcard $(RTL_DIR)/audio/*.sv) \
	$(RTL_DIR)/io/i8255.v \
	$(RTL_DIR)/io/i8279.v \
	$(RTL_DIR)/tv80/rtl/core/tv80_core.v \
	$(RTL_DIR)/tv80/rtl/core/tv80_alu.v \
	$(RTL_DIR)/tv80/rtl/core/tv80_mcode.v \
	$(RTL_DIR)/tv80/rtl/core/tv80_reg.v

# TV80_REFRESH: real Z80 I/R (memory-refresh) register behavior -- must
# match the Quartus build (Arcade-SegaVCO.qsf's VERILOG_MACRO) so sim results
# stay representative of hardware. See Arcade-SegaVCO.qsf's comment: without
# this, `LD A,R` is hardcoded to 0, which broke Buck Rogers' sub-CPU
# star-field LFSR (it seeds from R).
VFLAGS = --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE \
	+define+VERILATOR_SIM +define+TV80_REFRESH -Mdir obj_dir --top-module $(TOP) -O2

all: obj_dir/V$(TOP)

obj_dir/V$(TOP): $(SOURCES) tb_z80_3d.cpp
	$(VERILATOR) $(VFLAGS) $(SOURCES) tb_z80_3d.cpp

# segavco.v does $readmemh("rtl/tables/palette_*.hex", ...) relative to the
# repo root, so the built binary must be run with cwd = repo root, not sim/.
run: obj_dir/V$(TOP) buckrogn.rom
	mkdir -p out
	cd .. && sim/obj_dir/V$(TOP) --rom sim/buckrogn.rom --frames 410 --out sim/out/buckrogn_

buckrogn.rom:
	python3 build_rom.py buckrogn buckrogn.rom /mnt/c/MiSTerDev/mame/roms

# PPI2 probe: build with --public-flat-rw for internal signal access
obj_dir_ppi2probe/Vsegavco: $(SOURCES) tb_ppi2_probe.cpp
	$(VERILATOR) --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-CASEINCOMPLETE \
		+define+VERILATOR_SIM +define+TV80_REFRESH --public-flat-rw \
		-Mdir obj_dir_ppi2probe --top-module $(TOP) -O2 $(SOURCES) tb_ppi2_probe.cpp

ppi2-probe: obj_dir_ppi2probe/Vsegavco turbo.rom
	mkdir -p out
	cd .. && sim/obj_dir_ppi2probe/Vsegavco --turbo --rom sim/turbo.rom --frames 900 --coin 60 --start 120 --accelframe 200 --noppm --out sim/out/ppi2probe_

turbo.rom:
	python3 build_rom.py turbo turbo.rom /mnt/c/MiSTerDev/mame/roms

clean:
	rm -rf obj_dir out *.rom

.PHONY: all run ppi2-probe clean

# ---------------------------------------------------------------------------
# Discrete-audio harness (rtl/audio -> WAV). Independent of the segavco rules
# above: separate obj dir, separate output dir, separate target names, so
# `make` / `make run` keep meaning exactly what they always meant.
#
#   make audio        build the audio sim
#   make audio-run    render every scenario to out/audio/scenN.wav
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
	--top-module $(AUDIO_TOP) -O2 --public-flat-rw \
	+define+VERILATOR_SIM

.PHONY: audio audio-run audio-run-selected audio-clean

audio: $(AUDIO_OBJ_DIR)/V$(AUDIO_TOP)

$(AUDIO_OBJ_DIR)/V$(AUDIO_TOP): $(AUDIO_SOURCES) audio_tb.cpp
	$(VERILATOR) $(AUDIO_VFLAGS) $(AUDIO_SOURCES) audio_tb.cpp

audio-run: $(AUDIO_OBJ_DIR)/V$(AUDIO_TOP)
	mkdir -p $(AUDIO_OUT_DIR)
	status=0; \
	for s in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do \
		TURBO_AUDIO_OUT_DIR=$(AUDIO_OUT_DIR) ./$(AUDIO_OBJ_DIR)/V$(AUDIO_TOP) $$s || status=1; \
	done; \
	exit $$status

# Focused remediation gate.  Keep the long historical 0..30 sweep available
# above, but use only the source/mix/cadence/decoder checkpoints while the
# Player-Car v2 path is being closed.
audio-run-selected: $(AUDIO_OBJ_DIR)/V$(AUDIO_TOP)
	mkdir -p $(AUDIO_OUT_DIR)
	status=0; \
	for s in 29 30 33 34; do \
		TURBO_AUDIO_OUT_DIR=$(AUDIO_OUT_DIR) ./$(AUDIO_OBJ_DIR)/V$(AUDIO_TOP) $$s || status=1; \
	done; \
	exit $$status

audio-clean:
	rm -rf $(AUDIO_OBJ_DIR) $(AUDIO_OUT_DIR)

# Direct Mixer-II unit bench. The bench keeps sample_ce high because
# turbo_mixer has no meaningful between-sample state.
TURBO_MIXER_OBJ_DIR ?= obj_dir_turbo_mixer

.PHONY: turbo-mixer-test turbo-mixer-clean

turbo-mixer-test: $(TURBO_MIXER_OBJ_DIR)/Vturbo_mixer
	./$(TURBO_MIXER_OBJ_DIR)/Vturbo_mixer

$(TURBO_MIXER_OBJ_DIR)/Vturbo_mixer: ../rtl/audio/turbo_mixer.sv turbo_mixer_tb.cpp
	$(VERILATOR) --cc --exe --build -Wno-fatal -Wno-WIDTH -Mdir $(TURBO_MIXER_OBJ_DIR) \
		--top-module turbo_mixer -O2 +define+VERILATOR_SIM $^

turbo-mixer-clean:
	rm -rf $(TURBO_MIXER_OBJ_DIR)

# Direct D8 transient boundary trace.  The C++ output is intentionally a
# simple text stream so a Python checker can compare it against the implicit
# MNA reference without involving the full player-car source sequencer.
TURBO_PLAYER_CAR_D8_OBJ_DIR ?= obj_dir_turbo_playercar_d8

.PHONY: turbo-playercar-d8-transient-test turbo-playercar-d8-transient-clean

turbo-playercar-d8-transient-test: $(TURBO_PLAYER_CAR_D8_OBJ_DIR)/Vturbo_playercar_d8_transient
	./$(TURBO_PLAYER_CAR_D8_OBJ_DIR)/Vturbo_playercar_d8_transient

$(TURBO_PLAYER_CAR_D8_OBJ_DIR)/Vturbo_playercar_d8_transient: ../rtl/audio/turbo_playercar_d8_transient.sv turbo_playercar_d8_transient_tb.cpp
	$(VERILATOR) --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Mdir $(TURBO_PLAYER_CAR_D8_OBJ_DIR) \
		--top-module turbo_playercar_d8_transient -O2 +define+VERILATOR_SIM $^

turbo-playercar-d8-transient-clean:
	rm -rf $(TURBO_PLAYER_CAR_D8_OBJ_DIR)

# Direct STK439 output-stage bench. sample_ce is held high by the C++ bench;
# it independently derives gain, 8-ohm normalization, pot Thevenin load,
# coupling pole, sine response, DC rejection, symmetric clipping and wrap.
STK439_OBJ_DIR ?= obj_dir_stk439

.PHONY: stk439-test stk439-clean

stk439-test: $(STK439_OBJ_DIR)/Vstk439_tb
	./$(STK439_OBJ_DIR)/Vstk439_tb

$(STK439_OBJ_DIR)/Vstk439_tb: ../rtl/audio/stk439.sv stk439_tb.sv stk439_tb.cpp
	$(VERILATOR) --cc --exe --build -Wno-fatal -Wno-WIDTH -Mdir $(STK439_OBJ_DIR) \
		--top-module stk439_tb -O2 +define+VERILATOR_SIM $^

stk439-clean:
	rm -rf $(STK439_OBJ_DIR)

# Exact wide-on-27x27 shared multiplier unit bench.
SHARED_MUL_OBJ_DIR = obj_dir_shared_mul

.PHONY: shared-mul-test shared-mul-clean

shared-mul-test: $(SHARED_MUL_OBJ_DIR)/Vshared_mul_lane
	./$(SHARED_MUL_OBJ_DIR)/Vshared_mul_lane

$(SHARED_MUL_OBJ_DIR)/Vshared_mul_lane: ../rtl/audio/shared_mul_lane.sv shared_mul_tb.cpp
	$(VERILATOR) --cc --exe --build -Wno-fatal -Mdir $(SHARED_MUL_OBJ_DIR) \
		--top-module shared_mul_lane -O2 $^

shared-mul-clean:
	rm -rf $(SHARED_MUL_OBJ_DIR)

# Direct D-4 scheduled/reference equivalence bench.
TURBO_CRASH_D4_OBJ_DIR = obj_dir_turbo_crash_d4
.PHONY: turbo-crash-d4-test turbo-crash-d4-clean

turbo-crash-d4-test: $(TURBO_CRASH_D4_OBJ_DIR)/Vturbo_crash_d4_model
	./$(TURBO_CRASH_D4_OBJ_DIR)/Vturbo_crash_d4_model

$(TURBO_CRASH_D4_OBJ_DIR)/Vturbo_crash_d4_model: ../rtl/audio/shared_mul_lane.sv ../rtl/audio/turbo_crash_d4_model.sv turbo_crash_d4_tb.cpp
	$(VERILATOR) --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Mdir $(TURBO_CRASH_D4_OBJ_DIR) \
		--top-module turbo_crash_d4_model -O2 +define+VERILATOR_SIM $^

turbo-crash-d4-clean:
	rm -rf $(TURBO_CRASH_D4_OBJ_DIR)

# Direct CRASH preamp scheduler/reference equivalence bench.
TURBO_CRASH_PREAMP_OBJ_DIR = obj_dir_turbo_crash_preamp
.PHONY: turbo-crash-preamp-test turbo-crash-preamp-clean

turbo-crash-preamp-test: $(TURBO_CRASH_PREAMP_OBJ_DIR)/Vturbo_crash_chan
	./$(TURBO_CRASH_PREAMP_OBJ_DIR)/Vturbo_crash_chan

$(TURBO_CRASH_PREAMP_OBJ_DIR)/Vturbo_crash_chan: ../rtl/audio/shared_mul_lane.sv ../rtl/audio/turbo_crash_d4_model.sv ../rtl/audio/turbo_crash_chan.sv ../rtl/audio/ttl_74123.sv turbo_crash_preamp_tb.cpp
	$(VERILATOR) --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Mdir $(TURBO_CRASH_PREAMP_OBJ_DIR) \
		--top-module turbo_crash_chan -O2 +define+VERILATOR_SIM $^

turbo-crash-preamp-clean:
	rm -rf $(TURBO_CRASH_PREAMP_OBJ_DIR)

# Direct player-car pipeline/reference equivalence bench.
TURBO_PLAYERCAR_OBJ_DIR = obj_dir_turbo_playercar
.PHONY: turbo-playercar-test turbo-playercar-clean

turbo-playercar-test: $(TURBO_PLAYERCAR_OBJ_DIR)/Vturbo_playercar_chan
	./$(TURBO_PLAYERCAR_OBJ_DIR)/Vturbo_playercar_chan

$(TURBO_PLAYERCAR_OBJ_DIR)/Vturbo_playercar_chan: ../rtl/audio/relax_vco.sv ../rtl/audio/shared_mul_lane.sv ../rtl/audio/turbo_playercar_d8_source.sv ../rtl/audio/turbo_playercar_d8_transient.sv ../rtl/audio/turbo_playercar_d8_transient_pipe.sv ../rtl/audio/turbo_playercar_mycarsource.sv ../rtl/audio/turbo_playercar_slf.sv ../rtl/audio/turbo_playercar_chan.sv turbo_playercar_tb.cpp
	$(VERILATOR) --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Mdir $(TURBO_PLAYERCAR_OBJ_DIR) \
		--top-module turbo_playercar_chan -O2 +define+VERILATOR_SIM $^

turbo-playercar-clean:
	rm -rf $(TURBO_PLAYERCAR_OBJ_DIR)
# Direct S2688 scheduled/reference equivalence bench.
TURBO_S2688_OBJ_DIR = obj_dir_turbo_s2688
.PHONY: turbo-s2688-test turbo-s2688-clean

turbo-s2688-test: $(TURBO_S2688_OBJ_DIR)/Vturbo_s2688_noise
	./$(TURBO_S2688_OBJ_DIR)/Vturbo_s2688_noise

$(TURBO_S2688_OBJ_DIR)/Vturbo_s2688_noise: ../rtl/audio/shared_mul_lane.sv ../rtl/audio/turbo_s2688_noise.sv turbo_s2688_tb.cpp
	$(VERILATOR) --cc --exe --build -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Mdir $(TURBO_S2688_OBJ_DIR) \
		--top-module turbo_s2688_noise -O2 +define+VERILATOR_SIM $^

turbo-s2688-clean:
	rm -rf $(TURBO_S2688_OBJ_DIR)
# SHIP's local shared-MAC integration, including its 832-cycle deadline and
# response-tag assertions.  This intentionally bypasses audio_top because the
# channel-arbiter wiring is a separate migration step.
SHIP_SHARED_OBJ_DIR = obj_dir_ship_shared

.PHONY: ship-shared-test ship-shared-clean

ship-shared-test: $(SHIP_SHARED_OBJ_DIR)/Vship_shared_top
	./$(SHIP_SHARED_OBJ_DIR)/Vship_shared_top

$(SHIP_SHARED_OBJ_DIR)/Vship_shared_top: ship_shared_top.sv ship_shared_tb.cpp \
	../rtl/audio/ship_chan.sv ../rtl/audio/relax_vco.sv ../rtl/audio/dc_block.sv \
	../rtl/audio/shared_mul_lane.sv
	$(VERILATOR) --cc --exe --build -Wno-fatal +define+VERILATOR_SIM \
		-Mdir $(SHIP_SHARED_OBJ_DIR) --top-module ship_shared_top -O2 $^

ship-shared-clean:
	rm -rf $(SHIP_SHARED_OBJ_DIR)
