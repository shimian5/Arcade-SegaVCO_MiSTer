// Verilator testbench for rtl/segavco.v (phase 1a/1b/1c).
//
// Loads a flat ROM blob (built by sim/build_rom.py, same layout rom_download.v
// expects) via the ioctl_download port, free-runs the core, and dumps one PPM
// per frame for the 512x224 active area -- for diffing against
// `mame buckrogn -snapshot` (see docs/PLAN.md "Verilator frame diff").
//
// Phase 1c: drives IN0/IN1/DSW1/DSW2 directly (segavco.v's top-level ports,
// not through the HPS/OSD machinery Arcade-Z80-3D.sv uses on real hardware)
// and pulses coin-in then start1 partway through the run, to exercise the
// sub CPU/bitmap/mixer path far enough to reach actual gameplay instead of
// just the attract loop.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "verilated.h"
#include "Vsegavco.h"

static const int HTOTAL = 640, VTOTAL = 264;
static const int ACTIVE_W = 512, ACTIVE_H = 224;

static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

// --wav diagnostic: audio_l only changes once per audio sample (registered on
// audio_top's sample_ce, which isn't exposed at this port level), so recording
// on every VALUE CHANGE reconstructs the real 48 kHz stream with no need to
// re-derive the /832 divider here.
static void write_wav(const std::string &path, const std::vector<int16_t> &samples, uint32_t sample_rate = 48000) {
    FILE *f = fopen(path.c_str(), "wb");
    if (!f) { fprintf(stderr, "failed to open %s for write\n", path.c_str()); return; }
    uint32_t data_bytes = (uint32_t)samples.size() * 2;
    uint32_t byte_rate = sample_rate * 2;
    uint16_t block_align = 2;
    uint16_t bits_per_sample = 16;
    uint32_t riff_size = 36 + data_bytes;

    fwrite("RIFF", 1, 4, f);
    fwrite(&riff_size, 4, 1, f);
    fwrite("WAVE", 1, 4, f);
    fwrite("fmt ", 1, 4, f);
    uint32_t fmt_size = 16;
    fwrite(&fmt_size, 4, 1, f);
    uint16_t audio_format = 1; // PCM
    uint16_t num_channels = 1;
    fwrite(&audio_format, 2, 1, f);
    fwrite(&num_channels, 2, 1, f);
    fwrite(&sample_rate, 4, 1, f);
    fwrite(&byte_rate, 4, 1, f);
    fwrite(&block_align, 2, 1, f);
    fwrite(&bits_per_sample, 2, 1, f);
    fwrite("data", 1, 4, f);
    fwrite(&data_bytes, 4, 1, f);
    if (!samples.empty()) fwrite(samples.data(), 2, samples.size(), f);
    fclose(f);
}

static void tick(Vsegavco *top)
{
    top->clk = 1; top->eval();
    main_time++;
    top->clk = 0; top->eval();
    main_time++;
}

int main(int argc, char **argv)
{
    std::string rom_path = "sim/buckrogn.rom";
    std::string out_prefix = "sim/out/frame";
    // Phase0-1a sprite debug harness: --dumpframe N dumps the real-time
    // sprite_engine outputs (sprbits/plb) for every active pixel of frame N
    // to sim/out/dbg_rtl_spr.bin, 512*224*5 bytes (sprbits LE32 + plb byte),
    // in raster order -- see rtl/segavco.v's VERILATOR_SIM dbg_* ports and
    // rtl/video/sprite_engine.v's matching dbg_rtl_levels.txt dump. Frame
    // numbering here (tb's own `frame` counter, below) is driven by the same
    // hpos/vpos wraps sprite_engine.v's dbg_cur_frame counts, so the two are
    // directly comparable by index.
    int dumpframe = -1;
    // Star-motion investigation: dump the raw bitmap_ram (star layer) for
    // frames 420-459 (same window as tools/mame/dump_bitmap_ram.lua) to
    // sim/out/rtl_bitmap_NNN.bin, one byte-per-bit (0/1), 57344 bytes each,
    // same y*256+x addressing as the MAME memory_share -- so the two can be
    // fed through the identical star-trajectory tracker with no rendering/
    // capture step in between.
    bool dumpbitmap = false;
    // Star-motion investigation: dump the sub CPU's work RAM (0xe000-0xe7ff,
    // 2048 bytes) every frame from frame 1 through --workramframes (default
    // 250, covering boot/attract through well past coin+start) to
    // sim/out/rtl_workram_NNN.bin, for a per-frame byte diff against MAME's
    // subcpu program-space read of the same addresses -- finds the earliest
    // frame/byte offset the two engines' sub-CPU state actually disagrees.
    bool dumpworkram = false;
    bool dumpmainram = false;
    int workramframes = 250;
    // Now that cpu_z80.v drives TV80 with a real cen (see rtl/cpu_z80.v),
    // both CPUs run at the correct core_clk/8 rate in sim, same as real
    // hardware -- so frame counts here are directly comparable to real
    // time/MAME frame counts. 410 frames gives the same post-start1 runway
    // as tools/mame/dump_frames.lua's reference capture at frame 400 (see
    // docs/PLAN.md phase 1c notes).
    int frames = 410;
    // SECT-2 investigation. --hudtrace FILE writes one line per frame with
    // the HUD cells read straight out of the fg tilemap VRAM (RD: digit,
    // SECT: digit, the lives-icon row) plus a whole-tilemap checksum, in
    // exactly the format tools/mame/hud_trace.lua emits -- so a sim run and
    // a MAME run of the same input phase can be diffed line-for-line.
    // --noppm suppresses the per-frame PPM writes, which dominate runtime on
    // the multi-thousand-frame runs a full game needs.
    // --coin/--start move the input phase; the whole point of the sweep is
    // that both engines are deterministic, so the only knob that produces a
    // distribution is where the coin/start pulses land.
    std::string hudtrace_path;
    bool noppm = false;
    int coin_frame = 90, start_frame = 150;
    // --vramrange LO HI dumps the full 2KB fg tilemap to
    // sim/out/rtl_vram_NNN.bin for every frame in [LO,HI], matching
    // tools/mame/dump_vram_range.lua byte-for-byte.
    int vramlo = -1, vramhi = -1;
    // Factory DIP settings: DSW1 = 0xC0, DSW2 = 0x92 -- the PORT_DIPNAME
    // defaults in buckrog's INPUT_PORTS_START (docs/reference/turbo.cpp),
    // with the DSW1/DSW2 bit numbering confirmed against the schematic
    // (sheet 4, PDF p32: the two 8-position DIP packages feed I20-I27 and
    // I30-I37 through the LS253 muxes, which is exactly the 6,4,3,0 /
    // 7,5,2,1 bitswap pair). Previously 0x00/0x80, i.e. Difficulty HARD and
    // Accel-by-Pedal, which made the sim harder than the same ROM in MAME
    // and made every sim-vs-MAME game-state comparison invalid.
    int dsw1v = 0xC0, dsw2v = 0x92;
    std::string wav_path;
    // --turbo: docs/WORKPLAN_TURBO_GRAPHICS.md Step 7 visual sanity check.
    // segavco.v takes mod_turbo as a plain wire (Arcade-SegaVCO.sv derives
    // it from ioctl_index=1's mod byte, which this ROM-blob-only testbench
    // has no equivalent of), so it's just driven directly here. Turbo DSW
    // defaults below are turbo.cpp's factory PORT_DIPNAME sums (DSW1: lives
    // 0x03 + difficulty 0x08 + collision 0x10 + initial-entry 0x20 + the two
    // unknown bits 0x40+0x80 = 0xfb; DSW2: game-time 0x03 + coin B 0x1c +
    // coin A 0xe0 = 0xff).
    bool turbo_mode = false;
    int rasterlag_arg = -1; // -1 = use the default (5, Buck Rogers' measured value)
    int turbodump_frame = -1; // --turbodump N: CSV of road/mixer taps for frame N
    int accelframe_arg = -1;  // --accelframe N: hold pedal near-full-throttle from frame N
    int turbo_dsw1_arg = -1;  // --turbodsw1 N: override turbo_dsw1 (default 0xFB) for DIP-effect testing
    int turbo_dsw2_arg = -1;  // --turbodsw2 N: override turbo_dsw2 (default 0xFF) for Game-Time DIP-effect testing
    int midreset_frame = -1;  // --midreset N: assert reset for 10 frames starting at frame N (simulates pressing OSD Reset mid-session)
    int midreset_dsw1 = -1;   // --midresetdsw1 N: change turbo_dsw1 to this value at the same time (simulates changing a DIP then resetting)

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--rom" && i + 1 < argc) rom_path = argv[++i];
        else if (a == "--frames" && i + 1 < argc) frames = atoi(argv[++i]);
        else if (a == "--out" && i + 1 < argc) out_prefix = argv[++i];
        else if (a == "--dumpframe" && i + 1 < argc) dumpframe = atoi(argv[++i]);
        else if (a == "--dumpbitmap") dumpbitmap = true;
        else if (a == "--dumpworkram") dumpworkram = true;
        else if (a == "--dumpmainram") dumpmainram = true;
        else if (a == "--workramframes" && i + 1 < argc) workramframes = atoi(argv[++i]);
        else if (a == "--hudtrace" && i + 1 < argc) hudtrace_path = argv[++i];
        else if (a == "--noppm") noppm = true;
        else if (a == "--coin" && i + 1 < argc) coin_frame = atoi(argv[++i]);
        else if (a == "--start" && i + 1 < argc) start_frame = atoi(argv[++i]);
        else if (a == "--vramrange" && i + 2 < argc) { vramlo = atoi(argv[++i]); vramhi = atoi(argv[++i]); }
        else if (a == "--dsw1" && i + 1 < argc) dsw1v = (int)strtol(argv[++i], nullptr, 0);
        else if (a == "--dsw2" && i + 1 < argc) dsw2v = (int)strtol(argv[++i], nullptr, 0);
        else if (a == "--wav" && i + 1 < argc) wav_path = argv[++i];
        else if (a == "--turbo") turbo_mode = true;
        else if (a == "--rasterlag" && i + 1 < argc) rasterlag_arg = atoi(argv[++i]);
        else if (a == "--turbodump" && i + 1 < argc) turbodump_frame = atoi(argv[++i]);
        else if (a == "--accelframe" && i + 1 < argc) accelframe_arg = atoi(argv[++i]);
        else if (a == "--turbodsw1" && i + 1 < argc) turbo_dsw1_arg = (int)strtol(argv[++i], nullptr, 0);
        else if (a == "--turbodsw2" && i + 1 < argc) turbo_dsw2_arg = (int)strtol(argv[++i], nullptr, 0);
        else if (a == "--midreset" && i + 1 < argc) midreset_frame = atoi(argv[++i]);
        else if (a == "--midresetdsw1" && i + 1 < argc) midreset_dsw1 = (int)strtol(argv[++i], nullptr, 0);
    }

    FILE *hudf = nullptr;
    if (!hudtrace_path.empty()) {
        hudf = fopen(hudtrace_path.c_str(), "w");
        if (!hudf) { fprintf(stderr, "cannot write %s\n", hudtrace_path.c_str()); return 1; }
    }

    // Forward --dumpframe to the RTL side as a Verilator plusarg
    // (+dumpframe=N), which rtl/video/sprite_engine.v's VERILATOR_SIM block
    // reads via $value$plusargs, so the RTL-input snapshot (Deliverable 1)
    // and this testbench's per-pixel dump (Deliverable 2) key off the same
    // frame index.
    std::vector<std::string> plusarg_storage;
    std::vector<char *> vargv;
    for (int i = 0; i < argc; i++) vargv.push_back(argv[i]);
    if (dumpframe >= 0) {
        plusarg_storage.push_back("+dumpframe=" + std::to_string(dumpframe));
        vargv.push_back(const_cast<char *>(plusarg_storage.back().c_str()));
    }
    int vargc = (int)vargv.size();
    Verilated::commandArgs(vargc, vargv.data());

    FILE *rf = fopen(rom_path.c_str(), "rb");
    if (!rf) { fprintf(stderr, "cannot open rom %s\n", rom_path.c_str()); return 1; }
    fseek(rf, 0, SEEK_END);
    long rom_size = ftell(rf);
    fseek(rf, 0, SEEK_SET);
    std::vector<unsigned char> rom(rom_size);
    if (fread(rom.data(), 1, rom_size, rf) != (size_t)rom_size) { fprintf(stderr, "short read\n"); return 1; }
    fclose(rf);

    Vsegavco *top = new Vsegavco;

    // Reset. IN0/IN1 idle-high (active low, no buttons pressed); DSW1 = 0
    // (default coinage), DSW2 = 0x80 (Upright, MAME's real default).
    top->reset = 1;
    top->ioctl_download = 0;
    top->ioctl_wr = 0;
    top->ioctl_addr = 0;
    top->ioctl_dout = 0;
    top->in0 = 0xFF;
    top->in1 = 0xFF;
    top->dsw1 = (vluint8_t)dsw1v;
    top->dsw2 = (vluint8_t)dsw2v;
    top->mod_turbo   = turbo_mode ? 1 : 0;
    top->turbo_in0   = 0xFB; // idle: coin/service/start high, gear low, pedal-released gray=11
    top->turbo_dsw1  = (turbo_dsw1_arg >= 0) ? (vluint8_t)turbo_dsw1_arg : 0xFB;
    top->turbo_dsw2  = (turbo_dsw2_arg >= 0) ? (vluint8_t)turbo_dsw2_arg : 0xFF;
    top->turbo_dsw3  = 0x00;
    top->turbo_dial  = 0;
    for (int i = 0; i < 32; i++) tick(top);

    // Load ROM blob (ioctl_index=0, the main ROM blob's MRA index)
    top->ioctl_download = 1;
    top->ioctl_index = 0;
    for (long i = 0; i < rom_size; i++) {
        top->ioctl_addr = (vluint32_t)i;
        top->ioctl_dout = rom[i];
        top->ioctl_wr = 1;
        tick(top);
    }
    top->ioctl_wr = 0;
    top->ioctl_download = 0;
    printf("loaded %ld bytes from %s\n", rom_size, rom_path.c_str());

    // Reproduce the real MRA's ioctl_index=1 mod-byte transfer
    // (mra/*.mra's <rom index="1"><part>NN</part></rom>, addr=0, 1 byte)
    // that this testbench never sent before. Confirmed root cause of the
    // real-hardware Turbo hang (docs/WORKPLAN_TURBO_GRAPHICS.md Step 7):
    // rtl/rom_download.v used to have no ioctl_index qualifier at all, so
    // this exact transfer silently overwrote maincpu_rom[0] with the mod
    // byte right after the real ROM had already loaded -- benign for Buck
    // Rogers (0xF3 DI -> 0x00 NOP) but fatal for Turbo (0xC3 JP nnnn ->
    // 0x01 LD BC,nnnn, falling through into dead ROM space). Sending it
    // here now that rom_download.v is fixed (qualified on ioctl_index==0)
    // is a regression test: if the fix ever regresses, this will corrupt
    // maincpu_rom[0] again and the run should visibly hang/diverge.
    top->ioctl_download = 1;
    top->ioctl_index = 1;
    top->ioctl_addr = 0;
    top->ioctl_dout = turbo_mode ? 1 : 0;
    top->ioctl_wr = 1;
    tick(top);
    top->ioctl_wr = 0;
    top->ioctl_download = 0;
    top->ioctl_index = 0;

    top->reset = 0;

    std::vector<unsigned char> fb(ACTIVE_W * ACTIVE_H * 3, 0);
    int x = 0, y = 0, frame = 0;
    long tick_count = 0;
    long max_ticks = (long)HTOTAL * VTOTAL * 4 * (frames + 1) * 2; // safety cap

    // Deliverable 2: sim/out/dbg_rtl_spr.bin, ACTIVE_W*ACTIVE_H*5 bytes,
    // raster order, opened/closed exactly while frame == dumpframe.
    //
    // x/y here are meant to track the same raster position the RTL's own
    // hpos/vpos do. That was previously ASSERTED (on the grounds that both
    // reset to 0 as `reset` deasserts) and never checked -- and the whole
    // co-sim's frame indexing rests on it, so it is now measured against the
    // dbg_hpos/dbg_vpos ports every ce_pix. See the RASTER ALIGNMENT report
    // printed at the end of the run.
    //
    // MEASURED (not assumed) relationship: `top->ce_pix` is segavco.v's
    // *delayed* ce_pix (ce_pix_pipe[VIDEO_PIPE_LATENCY-1], deliberately
    // re-timed to line up with rgb_reg), and this tb's x/y only advance when
    // that delayed pulse fires -- so the lag between tb's (x,y) and the RTL's
    // raw dbg_hpos/dbg_vpos is purely a simulation-harness artifact of that
    // choice, not a hardware timing fact from the schematic. It tracks
    // VIDEO_PIPE_LATENCY, but NOT by a simple additive delta: it was 4
    // ce_pix ticks when VIDEO_PIPE_LATENCY was 7 (fg_tilemap's 4 +
    // color_table's 1 + sprcolor_table's 1 + palette_rom's 1), confirmed by
    // dumping (tick, tbx, tby, hpos, vpos) for the first ~700 ce_pix ticks of
    // a run (spanning the x=639->0 wrap and the following hpos=639->0 wrap):
    // tbx wraps 639->0 (tby 0->1) at tick 2543, hpos wraps 639->0 (vpos 0->1)
    // exactly 4 ticks later at tick 2559, and that 4-tick lag holds through
    // the wrap (one delay line over the coordinate pair, not two independent
    // per-axis offsets). VIDEO_PIPE_LATENCY became 9 when the fg-tier/
    // sprite/star-bg mixer paths were re-timed from a 6-clk/1.5-pixel common
    // depth to an 8-clk/2-pixel one (see segavco.v's SPR_TO_MIX_DELAY
    // comment) -- naively that predicts lag 4+(9-7)=6, but re-measuring the
    // same way gives 5, not 6 (RASTER_ALIGNMENT confirms 0/N deviations at
    // 5). Re-derive by measurement, don't extrapolate, whenever
    // VIDEO_PIPE_LATENCY changes, or every tick will appear to fail this
    // check even though the raster phase is genuinely constant -- as
    // happened here.
    //   - There is a short startup transient right after reset (the first
    //     ~7-9 ce_pix ticks), during which the lag climbs from -1 up to the
    //     steady value rather than being constant from tick 0 -- consistent
    //     with the RTL's ce_pix/pipeline generator filling after reset
    //     deasserts, not a genuine phase defect. The check below
    //     (RASTER_SKIP=16) skips this window.
    // The check maintains a RASTER_LAG-deep history of (x,y) and compares
    // hpos/vpos against the entry from RASTER_LAG ce_pix ticks back; any
    // deviation once past the startup window means a real phase glitch.
    // Default (5) is measured for Buck Rogers' VIDEO_PIPE_LATENCY=9 -- NOT
    // valid for a --turbo run (VIDEO_PIPE_LATENCY=12), which must pass its
    // own re-measured value via --rasterlag. Sized as a fixed-capacity
    // array (not VLA) since RASTER_LAG is now a runtime CLI value.
    int RASTER_LAG = (rasterlag_arg > 0) ? rasterlag_arg : 5;
    static const int RASTER_LAG_MAX = 32;
    static const int RASTER_SKIP = 16; // past the startup transient, comfortably
    int hist_x[RASTER_LAG_MAX] = {0}, hist_y[RASTER_LAG_MAX] = {0};
    long align_checked = 0, align_bad = 0;
    int  first_bad_x = -1, first_bad_y = -1, first_bad_rx = -1, first_bad_ry = -1;
    long first_bad_tick = -1;
    FILE *dbg_spr_f = nullptr;
    if (dumpframe >= 0) {
        dbg_spr_f = fopen("sim/out/dbg_rtl_spr.bin", "wb");
        if (!dbg_spr_f) fprintf(stderr, "cannot open sim/out/dbg_rtl_spr.bin for write\n");
    }
    // dbg_rtl_spr.bin must be indexed by the RTL's own RAW dbg_hpos/dbg_vpos
    // (sprite_engine.v's sprbits/plb are explicitly 0-latency vs raw
    // hpos/vpos, see its header) -- NOT by this testbench's (x,y), which only
    // advances on the mixer-delayed top->ce_pix and is therefore a constant
    // RASTER_LAG ticks ahead of dbg_hpos/dbg_vpos (see the raster-alignment
    // comment above). Sampling on top->ce_pix and indexing by (x,y), as this
    // used to do, silently wrote each pixel's real-time sprite data under the
    // WRONG raster address (off by RASTER_LAG in the 640-wide raw domain,
    // which straddles the 512/640 visible/blanking split unevenly and so
    // does not reduce to a simple in-visible-window shift) -- an instrument
    // bug, not evidence of a sprite_engine defect. Fixed by sampling on every
    // RAW hpos/vpos change instead, indexed by that same raw position
    // (which is already 0..511/0..223 for the visible region, per
    // video_timing.v's HBSTART=512/VBSTART=224 -- no translation needed).
    int prev_dbg_hpos = -1, prev_dbg_vpos = -1;

    FILE *turbodump_f = nullptr;
    if (turbodump_frame >= 0) {
        turbodump_f = fopen("sim/out/turbo_dump.csv", "w");
        if (turbodump_f) fprintf(turbodump_f, "hpos,vpos,babit,bacol,road,pen,fbpla,fbcol,opa,opb,opc,ipa,ipb,ipc\n");
    }
    int prev_td_hpos = -1, prev_td_vpos = -1;

    // Downsample audio_l by the same /832 ratio audio_top.sv's sample_ce
    // divider uses (clk_sys / 832 = 48 kHz) -- sample_ce itself isn't exposed
    // at this port level, and change-detection would silently collapse any
    // sustained-silence or sustained-level stretch to a single sample,
    // desyncing the WAV's timeline. A free-running counter is exact instead.
    std::vector<int16_t> audio_samples;
    int audio_div = 0;

    while (frame < frames && tick_count < max_ticks) {
        // Coin1 (IN1 bit 7) pulsed frames 90-99; Start1 (IN1 bit 3) pulsed
        // frames 150-159 -- matches tools/mame/dump_frames.lua's schedule
        // exactly, so sim and MAME reference frames are directly comparable
        // by frame index now that both CPUs run at real-hardware speed.
        // --midreset N: simulates pressing the OSD "Reset" (or "Reset and
        // close OSD") mid-session, as opposed to only ever resetting once at
        // power-on the way every other test in this harness does. If
        // --midresetdsw1 is also given, turbo_dsw1 changes at the same
        // moment, simulating "change a DIP, then reset" -- the exact
        // real-hardware sequence reported as not working.
        if (midreset_frame >= 0) {
            if (frame == midreset_frame) top->reset = 1;
            if (frame == midreset_frame && midreset_dsw1 >= 0) top->turbo_dsw1 = (vluint8_t)midreset_dsw1;
            if (frame == midreset_frame + 10) top->reset = 0;
        }

        bool coin_active  = (frame >= coin_frame  && frame < coin_frame  + 10);
        bool start_active = (frame >= start_frame && frame < start_frame + 10);
        unsigned char in1v = 0xFF;
        if (coin_active)  in1v &= ~(1 << 7);
        if (start_active) in1v &= ~(1 << 3);
        top->in1 = in1v;

        // Turbo has its own coin/start/pedal/gear port (turbo_in0, sel_in0_t
        // in segavco.v) entirely separate from Buck's in1 -- the coin/start
        // pulses above land on the wrong port for --turbo runs, so drive
        // turbo_in0 here instead. Bit layout (docs/reference/turbo.cpp:653-661,
        // turbo_base_state::pedal_r): bits0-1 = pedal gray code (0x03 =
        // released), bit2 = gear (active high, 0 = low gear), bit3 = start1
        // (active low), bit4 = service, bit5 = service1, bit6 = coin2, bit7 =
        // coin1 (both active low). --accelframe N holds the pedal at gray
        // code 00 (~full throttle, pedal_r(0x80)) from frame N onward, so the
        // road/mixer taps reflect real driving state, not just the idle/
        // attract-demo condition.
        if (turbo_mode) {
            unsigned char t0 = 0xFB; // idle: 11 (pedal), gear 0, start/coin inactive
            if (coin_active)  t0 &= ~(1 << 7);
            if (start_active) t0 &= ~(1 << 3);
            if (accelframe_arg >= 0 && frame >= accelframe_arg) t0 &= ~0x03; // pedal_r=00, near-full throttle
            top->turbo_in0 = t0;
        }

        tick(top);
        tick_count++;

        if (!wav_path.empty()) {
            if (audio_div == 0) audio_samples.push_back((int16_t)top->audio_l);
            audio_div = (audio_div + 1) % 832;
        }

        {
            int rhp = (int)top->dbg_hpos, rvp = (int)top->dbg_vpos;
            if ((rhp != prev_dbg_hpos || rvp != prev_dbg_vpos) &&
                dbg_spr_f && frame == dumpframe &&
                rhp < ACTIVE_W && rvp < ACTIVE_H) {
                unsigned char rec[5];
                vluint32_t sb = top->dbg_sprbits;
                rec[0] = (unsigned char)(sb & 0xFF);
                rec[1] = (unsigned char)((sb >> 8) & 0xFF);
                rec[2] = (unsigned char)((sb >> 16) & 0xFF);
                rec[3] = (unsigned char)((sb >> 24) & 0xFF);
                rec[4] = (unsigned char)(top->dbg_plb & 0xFF);
                long idx = ((long)rvp * ACTIVE_W + rhp) * 5;
                fseek(dbg_spr_f, idx, SEEK_SET);
                fwrite(rec, 1, 5, dbg_spr_f);
            }
            prev_dbg_hpos = rhp;
            prev_dbg_vpos = rvp;

            if (turbodump_f && frame == turbodump_frame &&
                (rhp != prev_td_hpos || rvp != prev_td_vpos) &&
                rhp < ACTIVE_W && rvp < ACTIVE_H) {
                fprintf(turbodump_f, "%d,%d,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u,%u\n",
                        rhp, rvp,
                        (unsigned)top->dbg_babit, (unsigned)top->dbg_bacol,
                        (unsigned)top->dbg_road, (unsigned)top->dbg_pen,
                        (unsigned)top->dbg_fbpla, (unsigned)top->dbg_fbcol,
                        (unsigned)top->dbg_opa, (unsigned)top->dbg_opb, (unsigned)top->dbg_opc,
                        (unsigned)top->dbg_ipa, (unsigned)top->dbg_ipb, (unsigned)top->dbg_ipc);
            }
            prev_td_hpos = rhp;
            prev_td_vpos = rvp;
        }

        if (top->ce_pix) {
            // Raster alignment check (see note above): hpos/vpos is the tb's
            // own (x,y) delayed by a constant RASTER_LAG (4) ce_pix ticks.
            // This is NOT corrected in the framebuffer indexing below: which
            // pixel the video output actually belongs to depends on the
            // mixer pipeline depth, and that pipeline currently free-runs on
            // `clk` rather than `ce_pix` (see docs/PLAN.md), so "fixing" the
            // indexing here would just be guessing. What matters is that the
            // lag stays CONSTANT -- any deviation means a real phase glitch.
            {
                int rx = (int)top->dbg_hpos, ry = (int)top->dbg_vpos;
                int hidx = (int)(align_checked % RASTER_LAG);
                if (align_checked >= RASTER_SKIP) {
                    int exp_x = hist_x[hidx];
                    int exp_y = hist_y[hidx];
                    if (rx != exp_x || ry != exp_y) {
                        if (align_bad == 0) {
                            first_bad_x = exp_x; first_bad_y = exp_y;
                            first_bad_rx = rx;   first_bad_ry = ry;
                            first_bad_tick = tick_count;
                        }
                        align_bad++;
                    }
                }
                hist_x[hidx] = x;
                hist_y[hidx] = y;
                align_checked++;
            }

            if (x < ACTIVE_W && y < ACTIVE_H) {
                int idx = (y * ACTIVE_W + x) * 3;
                fb[idx + 0] = top->video_r;
                fb[idx + 1] = top->video_g;
                fb[idx + 2] = top->video_b;
            }
            x++;
            if (x == HTOTAL) {
                x = 0;
                y++;
                if (y == VTOTAL) {
                    y = 0;
                    if (!noppm) {
                        char path[512];
                        snprintf(path, sizeof(path), "%s%03d.ppm", out_prefix.c_str(), frame);
                        FILE *pf = fopen(path, "wb");
                        if (pf) {
                            fprintf(pf, "P6\n%d %d\n255\n", ACTIVE_W, ACTIVE_H);
                            fwrite(fb.data(), 1, fb.size(), pf);
                            fclose(pf);
                            printf("wrote %s\n", path);
                        } else {
                            fprintf(stderr, "cannot write %s\n", path);
                        }
                    }
                    frame++;

                    // HUD trace: same fields, same order, same formatting as
                    // tools/mame/hud_trace.lua, so the two traces diff
                    // directly. VRAM addresses are tilemap-relative
                    // (0xc000 + row*32 + col).
                    if (hudf) {
                        auto rd = [&](int off) -> unsigned {
                            top->dbg_vram_addr = (vluint32_t)off;
                            top->eval();
                            return (unsigned)top->dbg_vram_data;
                        };
                        unsigned sect = rd(2 * 32 + 30);
                        unsigned rdno = rd(1 * 32 + 30);
                        unsigned sum = 0;
                        for (int a = 0; a < 2048; a++)
                            sum = (sum + rd(a) * (unsigned)(((0xc000 + a) & 0xff) | 1)) & 0xffffff;
                        char bar[80], timer[80];
                        for (int c = 0; c < 32; c++)
                            snprintf(bar + c * 2, 3, "%02x", rd(25 * 32 + c));
                        // TIME LEFT gauge: row 1, cols 1..23.
                        for (int c = 0; c < 23; c++)
                            snprintf(timer + c * 2, 3, "%02x", rd(1 * 32 + 1 + c));
                        fprintf(hudf, "f=%d sect=%02x rd=%02x sum=%06x bar=%s timer=%s\n",
                                frame, sect, rdno, sum, bar, timer);
                        fflush(hudf);
                    }

                    if (vramlo >= 0 && frame >= vramlo && frame <= vramhi) {
                        std::vector<unsigned char> vr(2048);
                        for (int a = 0; a < 2048; a++) {
                            top->dbg_vram_addr = (vluint32_t)a;
                            top->eval();
                            vr[a] = (unsigned char)top->dbg_vram_data;
                        }
                        char vpath[512];
                        snprintf(vpath, sizeof(vpath), "sim/out/rtl_vram_%04d.bin", frame);
                        FILE *vf = fopen(vpath, "wb");
                        if (vf) { fwrite(vr.data(), 1, vr.size(), vf); fclose(vf); }
                    }

                    if (dumpworkram && frame >= 1 && frame <= workramframes) {
                        std::vector<unsigned char> wr(2048);
                        for (int a = 0; a < 2048; a++) {
                            top->dbg_workram_addr = (vluint32_t)a;
                            top->eval();
                            wr[a] = (unsigned char)top->dbg_workram_data;
                        }
                        char wpath[512];
                        snprintf(wpath, sizeof(wpath), "sim/out/rtl_workram_%03d.bin", frame);
                        FILE *wf = fopen(wpath, "wb");
                        if (wf) {
                            fwrite(wr.data(), 1, wr.size(), wf);
                            fclose(wf);
                        }
                    }

                    if (dumpmainram && frame >= 1 && frame <= workramframes) {
                        std::vector<unsigned char> mr(2048);
                        for (int a = 0; a < 2048; a++) {
                            top->dbg_mainram_addr = (vluint32_t)a;
                            top->eval();
                            mr[a] = (unsigned char)top->dbg_mainram_data;
                        }
                        char mpath[512];
                        snprintf(mpath, sizeof(mpath), "sim/out/rtl_mainram_%03d.bin", frame);
                        FILE *mf = fopen(mpath, "wb");
                        if (mf) {
                            fwrite(mr.data(), 1, mr.size(), mf);
                            fclose(mf);
                        }
                    }

                    if (dumpbitmap && frame >= 420 && frame <= 459) {
                        std::vector<unsigned char> bm(57344);
                        for (int a = 0; a < 57344; a++) {
                            top->dbg_bitmap_addr = (vluint32_t)a;
                            top->eval();
                            bm[a] = top->dbg_bitmap_bit ? 1 : 0;
                        }
                        char bpath[512];
                        snprintf(bpath, sizeof(bpath), "sim/out/rtl_bitmap_%03d.bin", frame);
                        FILE *bf = fopen(bpath, "wb");
                        if (bf) {
                            fwrite(bm.data(), 1, bm.size(), bf);
                            fclose(bf);
                        }
                    }
                }
            }
        }
    }

    if (frame < frames) fprintf(stderr, "WARNING: only produced %d/%d frames before tick cap\n", frame, frames);

    if (turbo_mode) printf("TURBO COLLISION ACCUMULATOR at end of run: %u\n", (unsigned)top->dbg_collision);
    if (turbo_mode) printf("TURBO i8279 DSW1 reads: count=%u last_rl=0x%02x wr_count=%u sel_count=%u\n",
                            (unsigned)top->dbg_i8279_rd_count, (unsigned)top->dbg_i8279_last_rl,
                            (unsigned)top->dbg_i8279_wr_count, (unsigned)top->dbg_i8279_sel_count);
    if (turbo_mode) printf("TURBO PPI3 DSW2 reads: count=%u last_inb=0x%02x\n",
                            (unsigned)top->dbg_ppi3_rd_count, (unsigned)top->dbg_ppi3_last_inb);
    if (turbo_mode) printf("TURBO collision diag: sprbits_nz=%u addr_nz=%u addr_max=%u coll_max=%u clear_count=%u first_hit_frame=%u\n",
                            (unsigned)top->dbg_coll_sprbits_nz_count, (unsigned)top->dbg_coll_addr_nz_count,
                            (unsigned)top->dbg_coll_addr_max, (unsigned)top->dbg_coll_max,
                            (unsigned)top->dbg_coll_clear_count, (unsigned)top->dbg_coll_first_hit_frame);

    printf("RASTER ALIGNMENT: %ld/%ld ce_pix ticks deviating from the expected\n"
           "  constant %d-tick RTL-lags-tb raster relationship\n",
           align_bad, align_checked, RASTER_LAG);
    if (align_bad) {
        printf("  first deviation at tick %ld: expected RTL=(%d,%d) got RTL=(%d,%d)\n",
               first_bad_tick, first_bad_x, first_bad_y, first_bad_rx, first_bad_ry);
        printf("  => the raster phase is NOT constant; investigate before trusting\n"
               "     any pixel-level comparison from this run.\n");
    }

    if (dbg_spr_f) {
        fclose(dbg_spr_f);
        printf("wrote sim/out/dbg_rtl_spr.bin (frame %d)\n", dumpframe);
    }
    if (turbodump_f) {
        fclose(turbodump_f);
        printf("wrote sim/out/turbo_dump.csv (frame %d)\n", turbodump_frame);
    }

    if (hudf) fclose(hudf);

    if (!wav_path.empty()) {
        write_wav(wav_path, audio_samples);
        printf("wrote %s (%zu samples, %.2fs)\n", wav_path.c_str(), audio_samples.size(),
               audio_samples.size() / 48000.0);
    }

    top->final();
    delete top;
    return 0;
}
