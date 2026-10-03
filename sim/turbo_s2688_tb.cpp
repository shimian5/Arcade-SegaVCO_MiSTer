#include "Vturbo_s2688_noise.h"
#include "verilated.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr uint32_t AUDIO_INTERVAL_CLOCKS = 832;
constexpr uint64_t TICKS_Q32 = 8948058253ULL;
constexpr int64_t RECIPROCAL_Q32 = 2061535984LL;
constexpr int64_t Q32_ONE = 4294967296LL;
constexpr int SOURCE_HALF = 19456;

struct RefSample {
    int16_t noise = 0;
    int16_t physical = 0;
    uint8_t ticks = 0;
    uint32_t phase = 0;
    uint32_t state = 0;
};

uint32_t lfsr_step(uint32_t state) {
    const uint32_t feedback = ((state >> 16) ^ (state >> 13)) & 1u;
    return (((state & 0xffffu) << 1) & 0x1ffffu) | feedback;
}

RefSample reference_step(uint32_t state, uint32_t phase) {
    RefSample r;
    const uint64_t total = static_cast<uint64_t>(phase) + TICKS_Q32;
    r.ticks = static_cast<uint8_t>(total >> 32);
    r.phase = static_cast<uint32_t>(total);
    r.physical = ((state >> 16) & 1u) ? SOURCE_HALF : -SOURCE_HALF;

    int64_t area = ((state >> 16) & 1u)
        ? Q32_ONE - static_cast<int64_t>(phase)
        : -(Q32_ONE - static_cast<int64_t>(phase));
    uint32_t work = state;
    for (uint8_t i = 1; i <= 3; ++i) {
        if (i <= r.ticks) {
            work = lfsr_step(work);
            const int64_t dwell = (i < r.ticks) ? Q32_ONE : r.phase;
            area += ((work >> 16) & 1u) ? dwell : -dwell;
        }
    }
    r.state = work;
    const int64_t average = static_cast<int64_t>(
        (static_cast<__int128>(area) * RECIPROCAL_Q32) >> 48);
    int64_t effective = static_cast<int64_t>(
        (static_cast<__int128>(average) * SOURCE_HALF) >> 16);
    effective = std::clamp<int64_t>(effective, -SOURCE_HALF, SOURCE_HALF);
    r.noise = static_cast<int16_t>(effective);
    return r;
}

void clock(Vturbo_s2688_noise &dut, bool sample_ce) {
    dut.sample_ce = sample_ce;
    dut.clk = 1;
    dut.eval();
    dut.clk = 0;
    dut.eval();
}

void reset(Vturbo_s2688_noise &dut) {
    dut.clk = 0;
    dut.rst_n = 0;
    dut.sample_ce = 0;
    dut.eval();
    for (int i = 0; i < 6; ++i) clock(dut, false);
    dut.rst_n = 1;
}

uint16_t max_scheduler_cycles = 0;

RefSample sample(Vturbo_s2688_noise &dut, uint32_t &state, uint32_t &phase) {
    const RefSample expected = reference_step(state, phase);
    for (uint32_t i = 0; i < AUDIO_INTERVAL_CLOCKS - 1; ++i)
        clock(dut, false);
    clock(dut, true);
    if (dut.dbg_scheduler_cycles_last >= AUDIO_INTERVAL_CLOCKS)
        throw std::runtime_error("S2688 scheduler missed 832-clock deadline");
    max_scheduler_cycles = std::max<uint16_t>(
        max_scheduler_cycles, dut.dbg_scheduler_cycles_last);
    if (static_cast<int16_t>(dut.noise_raw) != expected.noise ||
        static_cast<int16_t>(dut.noise_physical) != expected.physical ||
        static_cast<uint8_t>(dut.source_ticks_last) != expected.ticks ||
        static_cast<uint32_t>(dut.source_phase_q32) != expected.phase) {
        std::cerr << "mismatch exp noise=" << expected.noise << " got=" << static_cast<int16_t>(dut.noise_raw) << " exp physical=" << expected.physical << " got=" << static_cast<int16_t>(dut.noise_physical) << " exp ticks=" << static_cast<unsigned>(expected.ticks) << " got=" << static_cast<unsigned>(dut.source_ticks_last) << " exp phase=" << expected.phase << " got=" << static_cast<uint32_t>(dut.source_phase_q32) << " sched=" << dut.dbg_scheduler_cycles_last << "\n";
        throw std::runtime_error("S2688 scheduled/reference mismatch");
    }
    state = expected.state;
    phase = expected.phase;
    return expected;
}

uint64_t fnv1a(uint64_t hash, uint64_t value) {
    for (int i = 0; i < 8; ++i) {
        hash ^= (value >> (i * 8)) & 0xffu;
        hash *= 1099511628211ULL;
    }
    return hash;
}

std::vector<RefSample> run(Vturbo_s2688_noise &dut, size_t count) {
    std::vector<RefSample> result;
    result.reserve(count);
    uint32_t state = 0x0B5E7;
    uint32_t phase = 0;
    reset(dut);
    for (size_t i = 0; i < count; ++i)
        result.push_back(sample(dut, state, phase));
    return result;
}
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vturbo_s2688_noise dut;
    const size_t count = argc > 1 ? static_cast<size_t>(std::stoul(argv[1])) : 12000;
    const auto first = run(dut, count);
    const auto replay = run(dut, count);
    if (first.size() != replay.size())
        throw std::runtime_error("S2688 reset/replay size mismatch");
    for (size_t i = 0; i < first.size(); ++i) {
        if (first[i].noise != replay[i].noise ||
            first[i].physical != replay[i].physical ||
            first[i].ticks != replay[i].ticks ||
            first[i].phase != replay[i].phase ||
            first[i].state != replay[i].state)
            throw std::runtime_error("S2688 reset/replay mismatch");
    }

    uint64_t hash = 1469598103934665603ULL;
    uint8_t min_ticks = 3, max_ticks = 0;
    for (const auto &s : first) {
        min_ticks = std::min(min_ticks, s.ticks);
        max_ticks = std::max(max_ticks, s.ticks);
        hash = fnv1a(hash, static_cast<uint16_t>(s.noise));
        hash = fnv1a(hash, static_cast<uint16_t>(s.physical));
        hash = fnv1a(hash, s.ticks);
        hash = fnv1a(hash, s.phase);
        if (std::abs(static_cast<int>(s.noise)) > SOURCE_HALF)
            throw std::runtime_error("S2688 source wrap/clamp failure");
    }
    if (min_ticks != 2 || max_ticks != 3)
        throw std::runtime_error("S2688 dwell count did not exercise 2/3 tick intervals");

    std::cout << "turbo_s2688: PASS samples=" << count
              << " hash=0x" << std::hex << hash << std::dec
              << " max_scheduler_clocks=" << max_scheduler_cycles
              << " interval=" << AUDIO_INTERVAL_CLOCKS << "\n";
    return 0;
}