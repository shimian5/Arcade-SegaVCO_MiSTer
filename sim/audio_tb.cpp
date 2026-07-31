// Verilator testbench for audio_top discrete-audio simulation.
// Not a product; an instrument for scenario-driven WAV capture.
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>
#include "verilated.h"
#include "Vaudio_top.h"

static const double CLK_HZ = 39935064.0;
static const uint64_t CLK_PERIOD_PS = (uint64_t)(1.0e12 / CLK_HZ + 0.5);

// bit positions
static const int ALARM0_PA_BIT = 6;
static const int ALARM1_PA_BIT = 7;
static const int ALARM2_PB_BIT = 0;
static const int ALARM3_PB_BIT = 1;
static const int FIRE_PB_BIT   = 2;
static const int EXP_PB_BIT    = 3;

struct Harness {
    Vaudio_top *dut;
    vluint64_t time_ps = 0;
    uint8_t pa = 0xFF;
    uint8_t pb = 0xFF;
    std::vector<int16_t> samples;
    // per-channel peaks, to separate an internally-saturating channel from
    // master-stage clipping
    int pk_alarm = 0, pk_fire = 0, pk_exp = 0;

    Harness() {
        dut = new Vaudio_top;
        dut->rst_n = 0;
        dut->ppi1_pa = pa;
        dut->ppi1_pb = pb;
        dut->clk = 0;
    }

    ~Harness() {
        dut->final();
        delete dut;
    }

    void apply_ports() {
        dut->ppi1_pa = pa;
        dut->ppi1_pb = pb;
    }

    // advance one half clock period
    // When false, cycles still run but nothing is recorded. Used to let the
    // power-on thump decay before a scenario starts: the board has been
    // powered for seconds before the game makes a sound, so capturing that
    // transient underneath every burst would be the unrealistic choice.
    bool capture = true;

    void half_tick() {
        dut->clk = !dut->clk;
        dut->eval();
        if (dut->clk && dut->sample_ce && capture) {
            samples.push_back((int16_t)dut->audio_l);
            auto absmax = [](int &acc, int16_t v) {
                int a = v < 0 ? -(int)v : (int)v;
                if (a > acc) acc = a;
            };
            absmax(pk_alarm, (int16_t)dut->dbg_alarm_mix);
            absmax(pk_fire,  (int16_t)dut->dbg_fire_mix);
            absmax(pk_exp,   (int16_t)dut->dbg_exp_mix);
        }
        time_ps += CLK_PERIOD_PS / 2;
    }

    void tick() {
        half_tick();
        half_tick();
    }

    // run for given number of milliseconds, applying current pa/pb each cycle
    void run_ms(double ms) {
        double target_ps = time_ps + ms * 1.0e9;
        while ((double)time_ps < target_ps) {
            apply_ports();
            tick();
        }
    }

    void reset(int cycles = 100) {
        dut->rst_n = 0;
        apply_ports();
        for (int i = 0; i < cycles; i++) tick();
        dut->rst_n = 1;
    }

    // Run without recording, so the caller's timeline still starts at t=0.
    // 600 ms is 11.5 of the ALARM high-pass's 52.17 ms tau, which is enough
    // for the power-on thump to decay back to bit-exact zero and so preserve
    // phase-1 acceptance criterion 5. (300 ms left a 22 LSB residual.)
    void settle(double ms = 600.0) {
        capture = false;
        run_ms(ms);
        capture = true;
    }

    void pulse_alarm(int which, double low_ms = 1.0) {
        switch (which) {
            case 0: pa &= ~(1 << ALARM0_PA_BIT); break;
            case 1: pa &= ~(1 << ALARM1_PA_BIT); break;
            case 2: pb &= ~(1 << ALARM2_PB_BIT); break;
            case 3: pb &= ~(1 << ALARM3_PB_BIT); break;
        }
        run_ms(low_ms);
        switch (which) {
            case 0: pa |= (1 << ALARM0_PA_BIT); break;
            case 1: pa |= (1 << ALARM1_PA_BIT); break;
            case 2: pb |= (1 << ALARM2_PB_BIT); break;
            case 3: pb |= (1 << ALARM3_PB_BIT); break;
        }
    }

    // /FIRE is port B bit 2 (docs/hardware-audio.md connector pinout).
    void pulse_fire(double low_ms = 1.0) {
        pb &= ~(1 << FIRE_PB_BIT);
        run_ms(low_ms);
        pb |= (1 << FIRE_PB_BIT);
    }

    // /EXP is port B bit 3.
    void pulse_exp(double low_ms = 1.0) {
        pb &= ~(1 << EXP_PB_BIT);
        run_ms(low_ms);
        pb |= (1 << EXP_PB_BIT);
    }

    void pulse_alarms_together(std::vector<int> which, double low_ms = 1.0) {
        for (int w : which) {
            switch (w) {
                case 0: pa &= ~(1 << ALARM0_PA_BIT); break;
                case 1: pa &= ~(1 << ALARM1_PA_BIT); break;
                case 2: pb &= ~(1 << ALARM2_PB_BIT); break;
                case 3: pb &= ~(1 << ALARM3_PB_BIT); break;
            }
        }
        run_ms(low_ms);
        for (int w : which) {
            switch (w) {
                case 0: pa |= (1 << ALARM0_PA_BIT); break;
                case 1: pa |= (1 << ALARM1_PA_BIT); break;
                case 2: pb |= (1 << ALARM2_PB_BIT); break;
                case 3: pb |= (1 << ALARM3_PB_BIT); break;
            }
        }
    }
};

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

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    if (argc < 2) {
        fprintf(stderr, "usage: %s <scenario 0-10>\n", argv[0]);
        return 1;
    }
    int scen = atoi(argv[1]);

    Harness h;
    h.reset(100);
    // Scenario 11 is the power-on thump itself, so it must NOT settle first.
    if (scen != 11) h.settle();

    switch (scen) {
        case 0:
            h.run_ms(10);
            h.pulse_alarm(0);
            h.run_ms(400 - 10);
            break;
        case 1:
            h.run_ms(10);
            h.pulse_alarm(1);
            h.run_ms(400 - 10);
            break;
        case 2:
            h.run_ms(10);
            h.pulse_alarm(2);
            h.run_ms(400 - 10);
            break;
        case 3:
            h.run_ms(10);
            h.pulse_alarm(3);
            h.run_ms(500 - 10);
            break;
        case 4:
            h.run_ms(10);
            h.pulse_alarm(0);
            h.run_ms(80 - 11);
            h.pulse_alarm(0);
            h.run_ms(500 - 81);
            break;
        case 5:
            h.run_ms(10);
            h.pulse_alarms_together({0, 2});
            h.run_ms(400 - 10);
            break;
        // ---- FIRE (phase 2) ----
        case 6:
            // one laser shot. 1.5 s of capture: the C3/R4 envelope has a
            // 1.02 s tau, so the tail is long and the whole decay must be
            // visible to check it against fire.wav's ~0.95 s.
            h.run_ms(10);
            h.pulse_fire();
            h.run_ms(1500 - 10);
            break;
        case 7:
            // rapid repeat fire, roughly the cadence the game uses. The
            // 74123 is retriggerable, so shots should re-open the VCA
            // rather than queueing.
            h.run_ms(10);
            for (int i = 0; i < 6; i++) {
                h.pulse_fire();
                h.run_ms(150 - 1);
            }
            h.run_ms(800);
            break;
        case 8:
            // FIRE under a sustained ALARM0, which is what the game
            // actually produces: the alarms are held continuously
            // retriggered while the player keeps shooting. Exercises the
            // passive mix node with two live channels.
            h.run_ms(10);
            for (int i = 0; i < 10; i++) {
                h.pulse_alarm(0);
                if (i % 3 == 0) h.pulse_fire();
                h.run_ms(60 - 1);
            }
            h.run_ms(600);
            break;
        // ---- EXP (phase 3) ----
        case 9:
            // one explosion. 5 s of capture: the rumble's C89 recovers
            // through 2M with tau = 4.4 s, so the tail is very long and
            // truncating it would hide the shape.
            h.run_ms(10);
            h.pulse_exp();
            h.run_ms(5000 - 10);
            break;
        case 10:
            // explosion with the laser still firing over it, and an alarm
            // running underneath -- three live channels on the passive mix
            // node, which is where clipping would first show up.
            h.run_ms(10);
            h.pulse_exp();
            for (int i = 0; i < 8; i++) {
                if (i % 2 == 0) h.pulse_fire();
                h.pulse_alarm(0);
                h.run_ms(80 - 2);
            }
            h.run_ms(2500);
            break;
        // ---- power-on ----
        case 11:
            // The power-on thump, captured from the instant reset releases.
            // C88 starts uncharged, so the ALARM high-pass begins at
            // -1845 LSB and decays over its 52.17 ms tau -- a +0.90 V pulse
            // at ALARM MIX after the x(-2) stage. No trigger is asserted;
            // everything here is the analog tail settling.
            h.run_ms(400);
            break;
        default:
            fprintf(stderr, "unknown scenario %d\n", scen);
            return 1;
    }

    char path[256];
    snprintf(path, sizeof(path), "out/audio/scen%d.wav", scen);
    write_wav(path, h.samples);

    int16_t peak = 0;
    uint64_t nonzero = 0;
    for (int16_t s : h.samples) {
        int16_t a = s < 0 ? (int16_t)(-s) : s;
        if (a > peak) peak = a;
        if (s != 0) nonzero++;
    }

    // channel peaks in volts: 4096 LSB = 1 V. The board is a 12 V single
    // supply biased at 6 V, so anything much past +/-5.5 V at a channel's
    // MIX node is not physically reachable on hardware.
    printf("scenario=%2d samples=%6zu peak=%5d nonzero=%6llu | "
           "alarm=%5d (%.2fV) fire=%5d (%.2fV) exp=%5d (%.2fV)\n",
           scen, h.samples.size(), (int)peak, (unsigned long long)nonzero,
           h.pk_alarm, h.pk_alarm / 4096.0,
           h.pk_fire,  h.pk_fire  / 4096.0,
           h.pk_exp,   h.pk_exp   / 4096.0);

    return 0;
}
