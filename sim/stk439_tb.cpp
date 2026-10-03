// Direct STK439 unit bench. sample_ce is asserted on every clocked sample.
// The physical constants are recomputed here from the component values; the
// bench does not copy AVC_Q16 or the RTL pole constant as its derivation.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <vector>
#include "verilated.h"
#include "Vstk439_tb.h"

static constexpr double CLK_HZ = 39935064.0;
static constexpr double FS_HZ = CLK_HZ / 832.0;
static constexpr double PI = 3.14159265358979323846;
static int failures = 0;

static void check(bool ok, const char *name) {
    std::printf("check %-42s %s\n", name, ok ? "PASS" : "FAIL");
    if (!ok) ++failures;
}

struct Sample {
    int16_t upper = 0, lower = 0, unity = 0;
    int64_t upper_raw = 0, lower_raw = 0, unity_raw = 0;
    bool upper_clip = false, lower_clip = false, unity_clip = false;
};

struct Harness {
    Vstk439_tb dut;

    Sample tick(int16_t input) {
        dut.mix_in = input;
        dut.clk = 0;
        dut.eval();
        dut.clk = 1;
        dut.eval();
        Sample s;
        s.upper = static_cast<int16_t>(dut.upper_out);
        s.lower = static_cast<int16_t>(dut.lower_out);
        s.unity = static_cast<int16_t>(dut.unity_out);
        s.upper_raw = static_cast<int64_t>(dut.upper_raw);
        s.lower_raw = static_cast<int64_t>(dut.lower_raw);
        s.unity_raw = static_cast<int64_t>(dut.unity_raw);
        s.upper_clip = dut.upper_clip != 0;
        s.lower_clip = dut.lower_clip != 0;
        s.unity_clip = dut.unity_clip != 0;
        dut.clk = 0;
        dut.eval();
        return s;
    }

    void reset() {
        dut.clk = 0;
        dut.rst_n = 0;
        dut.sample_ce = 1;
        dut.mix_in = 0;
        for (int i = 0; i < 4; ++i) (void)tick(0);
        dut.rst_n = 1;
        (void)tick(0);
    }
};

struct SineResult { double gain = 0.0; double phase = 0.0; };

static SineResult measure_sine(Harness &h, double hz, double amplitude,
                               double warm_seconds, double capture_cycles,
                               bool unity) {
    h.reset();
    const int warm = static_cast<int>(std::llround(warm_seconds * FS_HZ));
    const int capture = static_cast<int>(std::llround(capture_cycles * FS_HZ / hz));
    std::vector<Sample> outputs;
    outputs.reserve(static_cast<size_t>(warm + capture + 2));
    const int total = warm + capture + 2;
    for (int i = 0; i < total; ++i) {
        const int16_t x = static_cast<int16_t>(std::llround(
            amplitude * std::sin(2.0 * PI * hz * static_cast<double>(i) / FS_HZ)));
        outputs.push_back(h.tick(x));
    }
    long double sin_sum = 0.0L, cos_sum = 0.0L;
    const int first = warm + 1;
    const int last = first + capture;
    for (int i = first; i < last; ++i) {
        // audio_out is registered from the preceding input sample.
        const int input_index = i - 1;
        const double theta = 2.0 * PI * hz * static_cast<double>(input_index) / FS_HZ;
        const double y = unity ? static_cast<double>(outputs[i].unity)
                               : static_cast<double>(outputs[i].upper);
        sin_sum += y * std::sin(theta);
        cos_sum += y * std::cos(theta);
    }
    const long double scale = 2.0L / static_cast<long double>(capture);
    const double sin_component = static_cast<double>(scale * sin_sum);
    const double cos_component = static_cast<double>(scale * cos_sum);
    return {std::sqrt(sin_component * sin_component +
                      cos_component * cos_component) / amplitude,
            std::atan2(cos_component, sin_component)};
}

static bool identical_wave(Harness &h) {
    h.reset();
    const int16_t sequence[] = {0, 1, -1, 32767, -32768, 1234, -2345, 0, 0};
    for (int16_t x : sequence) {
        const Sample s = h.tick(x);
        if (s.upper != s.lower || s.upper_raw != s.lower_raw ||
            s.upper_clip != s.lower_clip)
            return false;
    }
    return true;
}

static void impulse_and_dc_rejection(Harness &h) {
    h.reset();
    int impulse_peak = 0, impulse_tail = 0;
    for (int i = 0; i < 30000; ++i) {
        const int a = std::abs(static_cast<int>(h.tick(i == 0 ? 1000 : 0).upper));
        impulse_peak = std::max(impulse_peak, a);
        if (i >= 29000) impulse_tail = std::max(impulse_tail, a);
    }
    h.reset();
    int step_peak = 0, dc_tail = 0;
    for (int i = 0; i < 30000; ++i) {
        const int a = std::abs(static_cast<int>(h.tick(1000).upper));
        step_peak = std::max(step_peak, a);
        if (i >= 29000) dc_tail = std::max(dc_tail, a);
    }
    std::printf("stk439_dc: impulse_peak=%d impulse_tail=%d step_peak=%d dc_tail=%d\n",
                impulse_peak, impulse_tail, step_peak, dc_tail);
    check(impulse_peak > 100 && impulse_tail * 20 < impulse_peak + 20,
          "stk439.impulse_rejection");
    check(step_peak > 100 && dc_tail * 20 < step_peak + 20,
          "stk439.step_dc_rejection");
}

static void no_wrap_and_clip(Harness &h, double normalized_gain) {
    h.reset();
    bool no_wrap = true;
    int max_out = 0, min_out = 0, positive_clips = 0, negative_clips = 0;
    for (int i = 0; i < 12000; ++i) {
        const int magnitude = 16000;
        const Sample s = h.tick(static_cast<int16_t>((i & 1) ? -magnitude : magnitude));
        max_out = std::max(max_out, static_cast<int>(s.upper));
        min_out = std::min(min_out, static_cast<int>(s.upper));
        if (s.upper == 32767) ++positive_clips;
        if (s.upper == -32768) ++negative_clips;
        const int64_t raw_abs = s.upper_raw < 0 ? -s.upper_raw : s.upper_raw;
        if (raw_abs >= (1LL << 40)) no_wrap = false;
        if (s.upper == 32767 && s.upper_raw < 32767) no_wrap = false;
        if (s.upper == -32768 && s.upper_raw > -32768) no_wrap = false;
    }
    const bool both_clip = positive_clips > 100 && negative_clips > 100 &&
                           max_out == 32767 && min_out == -32768;
    std::printf("stk439_clip: threshold_input=%.3f max=%d min=%d pos=%d neg=%d\n",
                32767.0 / normalized_gain, max_out, min_out,
                positive_clips, negative_clips);
    check(both_clip, "stk439.symmetric_clip_boundaries");
    check(no_wrap, "stk439.no_intermediate_wrap");

    h.reset();
    bool below_clip = true;
    for (int i = 0; i < 3000; ++i) {
        const Sample s = h.tick(static_cast<int16_t>((i & 1) ? -10000 : 10000));
        if (i > 100 && (s.upper_clip || s.upper == 32767 || s.upper == -32768))
            below_clip = false;
    }
    check(below_clip, "stk439.below_15w_reference");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Harness h;
    const double vclip = std::sqrt(2.0 * 15.0 * 8.0);
    const double c = 32767.0 / (vclip * 4096.0);
    const double av = 1.0 + 390000.0 / 12000.0;
    const double avc = av * c;
    const long avc_q16 = std::lround(avc * 65536.0);
    const double k = 9438.0 / 65536.0;
    const double rth = 25000.0 * k * (1.0 - k);
    const double rseen = 220000.0 + 1000.0 + rth;
    const double fc = 1.0 / (2.0 * PI * 0.47e-6 * rseen);
    const long hp_q24 = std::lround(std::exp(-2.0 * PI * fc / FS_HZ) * 16777216.0);
    const double unity_fc = 1.0 / (2.0 * PI * 0.47e-6 * 221000.0);
    const long unity_hp_q24 =
        std::lround(std::exp(-2.0 * PI * unity_fc / FS_HZ) * 16777216.0);
    const double normalized_gain = k * avc;

    std::printf("stk439_derived: Av=%.9f Av_dB=%.6f Vclip=%.9f c=%.10f "
                "Avc=%.10f AVC_Q16=%ld k=%.10f normalized=%.10f\n",
                av, 20.0 * std::log10(av), vclip, c, avc, avc_q16,
                k, normalized_gain);
    std::printf("stk439_pole: Rth=%.9f Rseen=%.9f fc=%.9f A_HP_Q24=%ld "
                "unity_fc=%.9f unity_A_HP_Q24=%ld fs=%.9f\n",
                rth, rseen, fc, hp_q24, unity_fc, unity_hp_q24, FS_HZ);

    check(std::fabs(av - 33.5) < 1.0e-12, "stk439.exact_gain_equation");
    check(std::fabs(20.0 * std::log10(av) - 30.501) < 0.002,
          "stk439.gain_db");
    check(std::fabs(vclip - 15.4919333848) < 1.0e-9,
          "stk439.15w_8ohm_reference");
    check(avc_q16 == 1133694, "stk439.independent_AVC_Q16");
    check(hp_q24 == 16773898 && unity_hp_q24 == 16773851,
          "stk439.independent_k_pole");
    check(std::fabs(rth - 3081.8216270) < 0.01 &&
          std::fabs(rseen - 224081.8216270) < 0.01,
          "stk439.thevenin_resistance");
    check(std::fabs(fc - 1.5111780868) < 1.0e-6,
          "stk439.coupling_pole");
    check(identical_wave(h), "stk439.upper_lower_identical");
    impulse_and_dc_rejection(h);

    const SineResult final_1k = measure_sine(h, 1000.0, 1000.0, 0.05, 8.0, false);
    const SineResult unity_1k = measure_sine(h, 1000.0, 1000.0, 0.05, 8.0, true);
    const SineResult final_low = measure_sine(h, 0.5, 1000.0, 2.0, 4.0, false);
    const double final_low_expected = normalized_gain *
        (0.5 / std::sqrt(0.5 * 0.5 + fc * fc));
    const double final_low_phase = std::atan2(fc, 0.5);
    std::printf("stk439_sine: final_1k_gain=%.9f unity_1k_gain=%.9f "
                "low_gain=%.9f expected=%.9f low_phase=%.9f expected_phase=%.9f\n",
                final_1k.gain, unity_1k.gain, final_low.gain,
                final_low_expected, final_low.phase, final_low_phase);
    check(std::fabs(unity_1k.gain - avc) / avc < 0.005,
          "stk439.unity_sine_gain");
    check(std::fabs(final_1k.gain - normalized_gain) / normalized_gain < 0.005,
          "stk439.pot_sine_gain");
    check(std::fabs(final_low.gain - final_low_expected) /
              final_low_expected < 0.03,
          "stk439.pot_sine_pole_gain");
    check(std::fabs(final_low.phase - final_low_phase) < 0.05,
          "stk439.pot_sine_phase");
    no_wrap_and_clip(h, normalized_gain);
    std::printf("stk439_summary: failures=%d\n", failures);
    return failures == 0 ? 0 : 1;
}
