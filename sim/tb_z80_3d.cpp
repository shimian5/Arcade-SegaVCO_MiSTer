// Verilator testbench for rtl/z80_3d.v (phase 1a/1b/1c).
//
// Loads a flat ROM blob (built by sim/build_rom.py, same layout rom_download.v
// expects) via the ioctl_download port, free-runs the core, and dumps one PPM
// per frame for the 512x224 active area -- for diffing against
// `mame buckrogn -snapshot` (see docs/PLAN.md "Verilator frame diff").
//
// Phase 1c: drives IN0/IN1/DSW1/DSW2 directly (z80_3d.v's top-level ports,
// not through the HPS/OSD machinery Arcade-Z80-3D.sv uses on real hardware)
// and pulses coin-in then start1 partway through the run, to exercise the
// sub CPU/bitmap/mixer path far enough to reach actual gameplay instead of
// just the attract loop.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include "verilated.h"
#include "Vz80_3d.h"

static const int HTOTAL = 640, VTOTAL = 264;
static const int ACTIVE_W = 512, ACTIVE_H = 224;

static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static void tick(Vz80_3d *top)
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
    // in raster order -- see rtl/z80_3d.v's VERILATOR_SIM dbg_* ports and
    // rtl/video/sprite_engine.v's matching dbg_rtl_levels.txt dump. Frame
    // numbering here (tb's own `frame` counter, below) is driven by the same
    // hpos/vpos wraps sprite_engine.v's dbg_cur_frame counts, so the two are
    // directly comparable by index.
    int dumpframe = -1;
    // Now that cpu_z80.v drives TV80 with a real cen (see rtl/cpu_z80.v),
    // both CPUs run at the correct core_clk/8 rate in sim, same as real
    // hardware -- so frame counts here are directly comparable to real
    // time/MAME frame counts. 410 frames gives the same post-start1 runway
    // as tools/mame/dump_frames.lua's reference capture at frame 400 (see
    // docs/PLAN.md phase 1c notes).
    int frames = 410;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--rom" && i + 1 < argc) rom_path = argv[++i];
        else if (a == "--frames" && i + 1 < argc) frames = atoi(argv[++i]);
        else if (a == "--out" && i + 1 < argc) out_prefix = argv[++i];
        else if (a == "--dumpframe" && i + 1 < argc) dumpframe = atoi(argv[++i]);
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

    Vz80_3d *top = new Vz80_3d;

    // Reset. IN0/IN1 idle-high (active low, no buttons pressed); DSW1 = 0
    // (default coinage), DSW2 = 0x80 (Upright, MAME's real default).
    top->reset = 1;
    top->ioctl_download = 0;
    top->ioctl_wr = 0;
    top->ioctl_addr = 0;
    top->ioctl_dout = 0;
    top->in0 = 0xFF;
    top->in1 = 0xFF;
    top->dsw1 = 0x00;
    top->dsw2 = 0x80;
    for (int i = 0; i < 32; i++) tick(top);

    // Load ROM blob
    top->ioctl_download = 1;
    for (long i = 0; i < rom_size; i++) {
        top->ioctl_addr = (vluint32_t)i;
        top->ioctl_dout = rom[i];
        top->ioctl_wr = 1;
        tick(top);
    }
    top->ioctl_wr = 0;
    top->ioctl_download = 0;
    top->reset = 0;
    printf("loaded %ld bytes from %s\n", rom_size, rom_path.c_str());

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
    // MEASURED (not assumed) relationship: `top->ce_pix` is z80_3d.v's
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
    // depth to an 8-clk/2-pixel one (see z80_3d.v's SPR_TO_MIX_DELAY
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
    static const int RASTER_LAG = 5;
    static const int RASTER_SKIP = 16; // past the startup transient, comfortably
    int hist_x[RASTER_LAG] = {0}, hist_y[RASTER_LAG] = {0};
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

    while (frame < frames && tick_count < max_ticks) {
        // Coin1 (IN1 bit 7) pulsed frames 90-99; Start1 (IN1 bit 3) pulsed
        // frames 150-159 -- matches tools/mame/dump_frames.lua's schedule
        // exactly, so sim and MAME reference frames are directly comparable
        // by frame index now that both CPUs run at real-hardware speed.
        bool coin_active  = (frame >= 90 && frame < 100);
        bool start_active = (frame >= 150 && frame < 160);
        unsigned char in1v = 0xFF;
        if (coin_active)  in1v &= ~(1 << 7);
        if (start_active) in1v &= ~(1 << 3);
        top->in1 = in1v;

        tick(top);
        tick_count++;

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
                    frame++;
                }
            }
        }
    }

    if (frame < frames) fprintf(stderr, "WARNING: only produced %d/%d frames before tick cap\n", frame, frames);

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

    top->final();
    delete top;
    return 0;
}
