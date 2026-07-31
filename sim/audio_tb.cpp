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

struct Harness {
    Vaudio_top *dut;
    vluint64_t time_ps = 0;
    uint8_t pa = 0xFF;
    uint8_t pb = 0xFF;
    std::vector<int16_t> samples;

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
    void half_tick() {
        dut->clk = !dut->clk;
        dut->eval();
        if (dut->clk && dut->sample_ce) {
            samples.push_back((int16_t)dut->audio_l);
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
        fprintf(stderr, "usage: %s <scenario 0-5>\n", argv[0]);
        return 1;
    }
    int scen = atoi(argv[1]);

    Harness h;
    h.reset(100);

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

    printf("scenario=%d samples=%zu peak=%d nonzero=%llu\n",
           scen, h.samples.size(), (int)peak, (unsigned long long)nonzero);

    return 0;
}
