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
    Verilated::commandArgs(argc, argv);

    std::string rom_path = "sim/buckrogn.rom";
    std::string out_prefix = "sim/out/frame";
    // 180 frames gives the CPU enough simulated time to run past its
    // init/POST sequence, draw the attract screen, respond to a coin-in +
    // start1 pulse (see below), and get partway into actual gameplay
    // (see docs/PLAN.md phase 1c notes).
    int frames = 180;

    for (int i = 1; i < argc; i++) {
        std::string a = argv[i];
        if (a == "--rom" && i + 1 < argc) rom_path = argv[++i];
        else if (a == "--frames" && i + 1 < argc) frames = atoi(argv[++i]);
        else if (a == "--out" && i + 1 < argc) out_prefix = argv[++i];
    }

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

    while (frame < frames && tick_count < max_ticks) {
        // Coin1 (IN1 bit 7) pulsed frames 30-39; Start1 (IN1 bit 3) pulsed
        // frames 60-69 -- enough separation for the main CPU's coin/credit
        // handling and the sub-CPU handshake to settle between the two.
        bool coin_active  = (frame >= 30 && frame < 40);
        bool start_active = (frame >= 60 && frame < 70);
        unsigned char in1v = 0xFF;
        if (coin_active)  in1v &= ~(1 << 7);
        if (start_active) in1v &= ~(1 << 3);
        top->in1 = in1v;

        tick(top);
        tick_count++;
        if (top->ce_pix) {
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

    top->final();
    delete top;
    return 0;
}
