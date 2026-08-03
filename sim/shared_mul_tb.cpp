#include "Vshared_mul_lane.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <random>
#include <vector>

static void tick(Vshared_mul_lane &dut) {
    dut.clk = 0; dut.eval();
    dut.clk = 1; dut.eval();
}

static unsigned __int128 read_product(const Vshared_mul_lane &dut) {
    unsigned __int128 value = 0;
    value |= (unsigned __int128)dut.rsp_product[0];
    value |= (unsigned __int128)dut.rsp_product[1] << 32;
    value |= (unsigned __int128)dut.rsp_product[2] << 64;
    value |= (unsigned __int128)dut.rsp_product[3] << 96;
    return value;
}

static int64_t random_signed(std::mt19937_64 &rng, unsigned width) {
    uint64_t raw = rng();
    if (width < 64) {
        const uint64_t mask = (uint64_t{1} << width) - 1;
        raw &= mask;
        if (raw & (uint64_t{1} << (width - 1))) raw |= ~mask;
    }
    return static_cast<int64_t>(raw);
}

static bool run_case(Vshared_mul_lane &dut, int64_t a, int64_t b,
                     unsigned aw, unsigned bw, uint8_t tag) {
    while (!dut.req_ready) tick(dut);
    dut.req_a = static_cast<uint64_t>(a);
    dut.req_b = static_cast<uint64_t>(b);
    dut.req_a_width = aw;
    dut.req_b_width = bw;
    dut.req_tag = tag;
    dut.req_valid = 1;
    tick(dut);
    dut.req_valid = 0;

    unsigned cycles = 0;
    while (!dut.rsp_valid && cycles++ < 20) tick(dut);
    if (!dut.rsp_valid) {
        std::fprintf(stderr, "timeout: aw=%u bw=%u\n", aw, bw);
        return false;
    }

    const signed __int128 expected_s = (signed __int128)a * (signed __int128)b;
    const unsigned __int128 expected = (unsigned __int128)expected_s;
    const unsigned __int128 actual = read_product(dut);
    if (actual != expected || dut.rsp_tag != tag) {
        std::fprintf(stderr,
                     "mismatch: a=%lld b=%lld aw=%u bw=%u tag=%u/%u\n",
                     (long long)a, (long long)b, aw, bw, dut.rsp_tag, tag);
        return false;
    }
    tick(dut); // rsp_valid must be a pulse
    if (dut.rsp_valid) {
        std::fprintf(stderr, "rsp_valid did not clear\n");
        return false;
    }
    return true;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vshared_mul_lane dut;
    dut.clk = 0;
    dut.rst_n = 0;
    dut.req_valid = 0;
    for (int i = 0; i < 4; ++i) tick(dut);
    dut.rst_n = 1;
    tick(dut);

    struct Case { int64_t a, b; unsigned aw, bw; };
    const std::vector<Case> edges = {
        {0, 0, 1, 1}, {1, -1, 2, 2},
        {(int64_t)((uint64_t{1} << 26) - 1), -(int64_t)(uint64_t{1} << 26), 27, 27},
        {(int64_t)((uint64_t{1} << 53) - 1), -(int64_t)(uint64_t{1} << 53), 54, 54},
        {INT64_MAX, INT64_MIN, 64, 64}, {INT64_MIN, -1, 64, 2},
        {INT64_MIN, INT64_MIN, 64, 64}
    };

    uint8_t tag = 0;
    for (const auto &c : edges)
        if (!run_case(dut, c.a, c.b, c.aw, c.bw, tag++)) return 1;

    std::mt19937_64 rng(0x5345474156434fULL);
    const unsigned widths[] = {1, 8, 16, 27, 28, 40, 54, 55, 64};
    for (unsigned n = 0; n < 10000; ++n) {
        const unsigned aw = widths[rng() % (sizeof(widths) / sizeof(widths[0]))];
        const unsigned bw = widths[rng() % (sizeof(widths) / sizeof(widths[0]))];
        if (!run_case(dut, random_signed(rng, aw), random_signed(rng, bw),
                      aw, bw, tag++)) return 1;
    }

    std::printf("shared_mul_lane: PASS (10007 exact signed cases)\n");
    return 0;
}

