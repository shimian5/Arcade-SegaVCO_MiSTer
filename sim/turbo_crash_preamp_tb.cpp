#include "verilated.h"
#include "Vturbo_crash_chan.h"
#include <algorithm>
#include <array>
#include <cstdint>
#include <iostream>
#include <stdexcept>
#include <vector>

namespace {
constexpr uint32_t AUDIO_INTERVAL_CLOCKS = 832;
constexpr int64_t Q20_ONE = 1048576;
constexpr int64_t PRE_HP_A_Q20 = 1048430;
constexpr int64_t PRE_HP_DELTA_Q20 = Q20_ONE - PRE_HP_A_Q20;
constexpr int64_t PRE_GAIN_Q20 = -356516;
constexpr int64_t RAIL_Q12 = 18432;

struct Observation {
    int16_t pcm;
    int16_t d4_source;
    int64_t lp_state;
    int64_t lp_next;
    int64_t raw;
    uint16_t cycles;
    bool operator==(const Observation& o) const {
        return pcm == o.pcm && d4_source == o.d4_source &&
               lp_state == o.lp_state && lp_next == o.lp_next &&
               raw == o.raw && cycles == o.cycles;
    }
};

int64_t q64(uint64_t value) {
    return static_cast<int64_t>(value);
}

int64_t preamp_lp_next(int64_t noise, int64_t lp) {
    return lp + ((noise - lp) * PRE_HP_DELTA_Q20 >> 20);
}

int64_t preamp_raw(int64_t noise, int64_t lp_next) {
    return ((noise - lp_next) * PRE_GAIN_Q20) >> 20;
}

int16_t preamp_pcm(int64_t raw) {
    raw = std::clamp<int64_t>(raw, -RAIL_Q12, RAIL_Q12);
    return static_cast<int16_t>(raw);
}

void clock(Vturbo_crash_chan& d, bool ce) {
    d.sample_ce = ce;
    d.clk = 1;
    d.eval();
    d.clk = 0;
    d.eval();
}

void reset(Vturbo_crash_chan& d) {
    d.clk = 0;
    d.rst_n = 0;
    d.sample_ce = 0;
    d.crash_s_n = 1;
    d.crash_l_n = 1;
    d.noise_in = 0;
    d.eval();
    for (int i = 0; i < 8; ++i)
        clock(d, false);
    d.rst_n = 1;
}

bool run_once(Vturbo_crash_chan& d, const std::vector<int16_t>& input,
              std::vector<Observation>& observed, uint32_t& max_cycles) {
    reset(d);
    observed.clear();
    int64_t lp = 0;
    bool ok = true;
    for (int16_t noise : input) {
        const int64_t n = noise;
        const int64_t next = preamp_lp_next(n, lp);
        const int64_t raw = preamp_raw(n, next);
        const int16_t pcm = preamp_pcm(raw);
        d.noise_in = noise;
        for (uint32_t c = 0; c < 64; ++c)
            clock(d, false);
        Observation o{
            static_cast<int16_t>(d.dbg_preamp_out),
            static_cast<int16_t>(d.dbg_d4_source_sample),
            q64(d.dbg_preamp_lp_state),
            q64(d.dbg_preamp_lp_next),
            q64(d.dbg_preamp_raw_q12),
            static_cast<uint16_t>(d.dbg_preamp_scheduler_cycles_last)
        };
        observed.push_back(o);
        ok = ok && o.pcm == pcm && o.d4_source == pcm &&
             o.lp_state == lp && o.lp_next == next && o.raw == raw &&
             o.cycles < AUDIO_INTERVAL_CLOCKS;
        max_cycles = std::max<uint32_t>(max_cycles, o.cycles);
        for (uint32_t c = 64; c < AUDIO_INTERVAL_CLOCKS - 1; ++c)
            clock(d, false);
        clock(d, true);
        ok = ok && q64(d.dbg_preamp_lp_state) == next;
        lp = next;
    }
    return ok;
}

std::vector<int16_t> make_input() {
    std::vector<int16_t> v{
        0, 19456, -19456, 4096, -4096, 16384, -16384,
        19455, -19455, 1, -1, 8192, -8192
    };
    uint32_t s = 0x13579BDFu;
    for (int i = 0; i < 96; ++i) {
        s = s * 1664525u + 1013904223u;
        const int32_t x = static_cast<int32_t>(s & 0x7fffffffU) % 19457;
        v.push_back(static_cast<int16_t>((s & 0x80000000U) ? -x : x));
    }
    return v;
}
} // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vturbo_crash_chan d;
    const auto input = make_input();
    std::vector<Observation> first, replay;
    uint32_t max_cycles = 0;
    bool ok = run_once(d, input, first, max_cycles);

    reset(d);
    d.noise_in = 777;
    clock(d, false);
    clock(d, false);
    d.rst_n = 0;
    clock(d, false);
    d.rst_n = 1;
    ok = ok && run_once(d, input, replay, max_cycles);
    ok = ok && first == replay && first.size() == input.size();

    std::cout << "preamp_reference_samples=" << input.size()
              << " sample_for_sample=" << (ok ? "PASS" : "FAIL")
              << " reset_replay=" << ((first == replay) ? "PASS" : "FAIL")
              << " max_scheduler_clocks=" << max_cycles
              << " interval=" << AUDIO_INTERVAL_CLOCKS << "\n";
    if (max_cycles >= AUDIO_INTERVAL_CLOCKS)
        ok = false;
    return ok ? 0 : 1;
}