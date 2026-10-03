#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>

#include "verilated.h"
#include "Vturbo_mixer.h"

namespace {

using Inputs = std::array<int16_t, 10>;
constexpr int kSourceCount = 10;
constexpr int kInstalledMLegs = 12;
constexpr int64_t kQ16Scale = 65536;

int derive_m_q16_from_loaded_bus(int fitted_legs) {
    const double source_conductance = fitted_legs / 100000.0;
    const double bus_conductance = 1.0 / 22000.0;
    const double coefficient =
        (100000.0 / 22000.0) * (1.0 / 100000.0) /
        (source_conductance + bus_conductance);
    return static_cast<int>(std::lround(coefficient * kQ16Scale));
}

int64_t floor_q16(int64_t value) {
    // The RTL's signed >>>16 is floor division for negative products. Use
    // an explicit mathematical floor here so the expected result is an
    // independent C++ calculation, not a copy of the RTL shift expression.
    if (value >= 0) return value / kQ16Scale;
    return -((-value + kQ16Scale - 1) / kQ16Scale);
}

int16_t saturate16(int64_t value) {
    if (value > 32767) return 32767;
    if (value < -32768) return -32768;
    return static_cast<int16_t>(value);
}

int16_t expected_m(const Inputs &inputs, int q16) {
    int64_t source_sum = 0;
    for (int16_t value : inputs) source_sum += value;
    const int64_t loaded_sum = floor_q16(source_sum * q16);
    return saturate16(-loaded_sum);
}

struct MixerDriver {
    Vturbo_mixer dut;

    MixerDriver() {
        dut.clk = 0;
        dut.rst_n = 0;
        dut.sample_ce = 1;
        dut.mute = 0;
        set_inputs(Inputs{});
        dut.eval();
        dut.clk = 1;
        dut.eval();
        dut.clk = 0;
        dut.rst_n = 1;
    }

    void set_inputs(const Inputs &inputs) {
        dut.alarm_tap = inputs[0];
        dut.skid_tap = inputs[1];
        dut.crash_s_tap = inputs[2];
        dut.crash_l_tap = inputs[3];
        dut.ambulance_tap = inputs[4];
        dut.othercars_f_tap = inputs[5];
        dut.othercars_l_tap = inputs[6];
        dut.othercars_r_tap = inputs[7];
        dut.othercars_w_tap = inputs[8];
        dut.playercar_m = inputs[9];
    }

    int16_t sample(const Inputs &inputs) {
        set_inputs(inputs);
        dut.clk = 0;
        dut.eval();
        dut.clk = 1;
        dut.eval();
        return static_cast<int16_t>(dut.mixer2_m_out);
    }
};

} // namespace

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int failures = 0;
    int cases = 0;

    auto check = [&](bool pass, const char *label) {
        ++cases;
        std::printf("check %-42s %s\n", label, pass ? "PASS" : "FAIL");
        if (!pass) ++failures;
    };

    const int q16 = derive_m_q16_from_loaded_bus(kInstalledMLegs);
    check(q16 == 18004, "loaded equation rounds to Q16=18004");
    for (int active = 0; active <= kSourceCount; ++active) {
        char label[80];
        std::snprintf(label, sizeof(label),
                      "denominator uses 12 legs with %d active RTL inputs", active);
        check(derive_m_q16_from_loaded_bus(kInstalledMLegs) == q16, label);
    }

    MixerDriver mixer;
    auto run_case = [&](const char *label, const Inputs &inputs) {
        const int16_t actual = mixer.sample(inputs);
        const int16_t expected = expected_m(inputs, q16);
        std::printf("case %-30s expected=%d actual=%d\n", label,
                    static_cast<int>(expected), static_cast<int>(actual));
        check(actual == expected, label);
    };

    run_case("zero input", Inputs{});

    for (int source = 0; source < kSourceCount; ++source) {
        Inputs positive{};
        Inputs negative{};
        positive[source] = 10000;
        negative[source] = -10000;
        char positive_label[80];
        char negative_label[80];
        std::snprintf(positive_label, sizeof(positive_label),
                      "source %d positive one-at-a-time", source);
        std::snprintf(negative_label, sizeof(negative_label),
                      "source %d negative one-at-a-time", source);
        run_case(positive_label, positive);
        run_case(negative_label, negative);
    }

    run_case("positive rounding/truncation", Inputs{4, 0, 0, 0, 0, 0, 0, 0, 0, 0});
    run_case("negative rounding/truncation", Inputs{-4, 0, 0, 0, 0, 0, 0, 0, 0, 0});
    run_case("signed mixed combination A", Inputs{12000, -7000, 3000, -2000, 500, -900, 1300, -1100, 800, -600});
    run_case("signed mixed combination B", Inputs{-32768, 32767, -16000, 16000, -8000, 8000, -4000, 4000, -2000, 2000});
    run_case("maximum positive expected sum", Inputs{32767, 32767, 32767, 32767, 32767,
                                                     32767, 32767, 32767, 32767, 32767});
    run_case("maximum negative expected sum", Inputs{-32768, -32768, -32768, -32768, -32768,
                                                     -32768, -32768, -32768, -32768, -32768});

    const int16_t max_actual = mixer.sample(Inputs{32767, 32767, 32767, 32767, 32767,
                                                    32767, 32767, 32767, 32767, 32767});
    const int16_t min_actual = mixer.sample(Inputs{-32768, -32768, -32768, -32768, -32768,
                                                    -32768, -32768, -32768, -32768, -32768});
    check(max_actual == -32768, "positive overload saturates negative rail");
    check(min_actual == 32767, "negative overload saturates positive rail");
    check(max_actual != 32767 && min_actual != -32768, "saturation has no signed wrap");

    std::printf("turbo_mixer unit: q16=%d fitted_legs=%d active_rtl_inputs=%d cases=%d failures=%d\n",
                q16, kInstalledMLegs, kSourceCount, cases, failures);
    return failures == 0 ? 0 : 1;
}
