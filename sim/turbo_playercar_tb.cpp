// Player-car channel behavioral bench (free-running rework). Unlike the
// prior placeholder's bit-exact-vs-C++-model bench, this channel's
// arithmetic now runs through a serialized shared_mul_lane sequencer, so
// this bench checks behavior/invariants (non-degenerate output, correct
// BSEL routing/mute, deterministic replay, no assertion failures) rather
// than re-deriving the sequencer's exact fixed-point arithmetic in C++.
#include <Vturbo_playercar_chan.h>
#include <Vturbo_playercar_chan___024root.h>
#include <verilated.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

static constexpr int AUDIO_INTERVAL_CLOCKS = 832;

static void fail(const char *what) {
    std::printf("FAIL %s\n", what);
    std::exit(1);
}

static void tick(Vturbo_playercar_chan &dut, bool ce) {
    dut.sample_ce = ce;
    dut.clk = 1; dut.eval();
    dut.clk = 0; dut.eval();
}

static void reset(Vturbo_playercar_chan &dut) {
    dut.clk = 0; dut.rst_n = 0; dut.sample_ce = 0; dut.acc = 0; dut.bsel = 3;
    dut.eval();
    for (int i = 0; i < 8; ++i) tick(dut, false);
    dut.rst_n = 1;
}

struct Sample {
    int16_t qf, qw, f1, w1, f, w, m, slf;
    int16_t dcf, dcw; // AC-coupled combined F/W -- the real mixer feed
    int32_t g0, g1, g2; // retained as zeroed legacy debug fields
    int16_t source_raw, source_shaped; // public IC6 source taps
};

static Sample sample(Vturbo_playercar_chan &dut, int acc, int bsel) {
    dut.acc = acc; dut.bsel = bsel;
    for (int i = 0; i < AUDIO_INTERVAL_CLOCKS - 1; ++i) tick(dut, false);
    tick(dut, true);
    return {
        static_cast<int16_t>(dut.mycarq_f_mix), static_cast<int16_t>(dut.mycarq_w_mix),
        static_cast<int16_t>(dut.mycar1_f_mix), static_cast<int16_t>(dut.mycar1_w_mix),
        static_cast<int16_t>(dut.mycar_f_mix),  static_cast<int16_t>(dut.mycar_w_mix),
        static_cast<int16_t>(dut.mycar_m_mix),  static_cast<int16_t>(dut.slf_mix),
        static_cast<int16_t>(dut.dcblock_f_mix), static_cast<int16_t>(dut.dcblock_w_mix),
        0, 0, 0,
        static_cast<int16_t>(dut.dbg_source_raw),
        static_cast<int16_t>(dut.dbg_source_shaped)
    };
}

// Minimal mono 16-bit PCM WAV writer -- render-only helper, not part of the
// pass/fail bench logic below. Keeps this the one canonical player-car
// testbench+renderer per the mandate instead of a second standalone file.
static void write_wav(const char *path, const std::vector<int16_t> &samples, uint32_t fs) {
    FILE *f = std::fopen(path, "wb");
    if (!f) { std::printf("WAV WRITE FAILED %s\n", path); return; }
    uint32_t data_bytes = (uint32_t)samples.size() * 2;
    uint32_t byte_rate = fs * 2;
    uint16_t block_align = 2, bits = 16, channels = 1, fmt = 1;
    uint32_t rib = 36 + data_bytes;
    std::fwrite("RIFF", 1, 4, f); std::fwrite(&rib, 4, 1, f);
    std::fwrite("WAVE", 1, 4, f); std::fwrite("fmt ", 1, 4, f);
    uint32_t fmt_len = 16; std::fwrite(&fmt_len, 4, 1, f);
    std::fwrite(&fmt, 2, 1, f); std::fwrite(&channels, 2, 1, f);
    std::fwrite(&fs, 4, 1, f); std::fwrite(&byte_rate, 4, 1, f);
    std::fwrite(&block_align, 2, 1, f); std::fwrite(&bits, 2, 1, f);
    std::fwrite("data", 1, 4, f); std::fwrite(&data_bytes, 4, 1, f);
    std::fwrite(samples.data(), 2, samples.size(), f);
    std::fclose(f);
}

static std::vector<Sample> run_sequence() {
    Vturbo_playercar_chan dut;
    std::vector<Sample> samples;
    reset(dut);
    auto phase = [&](int acc, int bsel, int count) {
        for (int i = 0; i < count; ++i)
            samples.push_back(sample(dut, acc, bsel));
    };
    // Settle each BSEL/ACC combination past the ~50ms ladder tau (2400
    // samples at fs~48kHz) and the slower BCONT2 release tau (0.44s,
    // ~21000 samples) -- give each phase enough samples to both ramp the
    // gate and observe several oscillator cycles.
    phase(0, 3, 3000);
    phase(0, 0, 4000);
    phase(27, 1, 4000);
    phase(63, 2, 4000);
    phase(27, 2, 2000);
    phase(0, 1, 4000);
    phase(63, 0, 4000);
    // BCONT2's release tau is 0.44s (real traced value); reaching a
    // genuinely inaudible level needs ~5 tau after gate2 last drops (at
    // sample 17000, see boundaries below), not the ~0.5s a short idle
    // phase gives -- that only lets a single tau of decay happen, which
    // still leaves an audible residual. 220000 gives ~4.2s (~9.6 tau) of
    // idle settle time.
    phase(27, 3, 220000);
    dut.final();
    return samples;
}

static bool same_samples(const std::vector<Sample> &a, const std::vector<Sample> &b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); ++i) {
        const Sample &x = a[i], &y = b[i];
        if (x.qf != y.qf || x.qw != y.qw || x.f1 != y.f1 || x.w1 != y.w1 ||
            x.f != y.f || x.w != y.w || x.m != y.m || x.slf != y.slf ||
            x.source_raw != y.source_raw || x.source_shaped != y.source_shaped)
            return false;
    }
    return true;
}

int main() {
    std::vector<Sample> first = run_sequence();

    if (std::getenv("TURBO_PLAYERCAR_DEBUG_DUMP")) {
        size_t lo = 11000, hi = 11080;
        if (const char *s = std::getenv("TURBO_PLAYERCAR_DEBUG_LO")) lo = std::atoll(s);
        hi = lo + 80;
        for (size_t i = lo; i < first.size() && i < hi; ++i)
            std::printf("i=%zu f=%d w=%d qf=%d f1=%d m=%d dcf=%d dcw=%d "
                        "legacy_gains=%d/%d/%d source_raw=%d source_shaped=%d\n",
                        i, first[i].f, first[i].w, first[i].qf, first[i].f1,
                        first[i].m, first[i].dcf, first[i].dcw,
                        first[i].g0, first[i].g1, first[i].g2,
                        first[i].source_raw, first[i].source_shaped);
    }

    // The former direct bench debug branch depended on internal signals from
    // the retired relax_vco/IC3 sidecar carrier.  The release carrier is the
    // public IC6 D7/D13 source; scenario 29/33 provide its detailed captures.
    // Keep the old opt-in code below in the file for historical reference, but
    // do not compile it against the v2 topology.
#if 0
    if (std::getenv("TURBO_PLAYERCAR_DEBUG_VCO")) {
        Vturbo_playercar_chan dut;
        reset(dut);
        long long lo = 0, hi_ = 0;
        if (const char *s = std::getenv("TURBO_PLAYERCAR_DEBUG_LO")) lo = std::atoll(s);
        // run to a specific sample index at fixed acc/bsel from env
        int acc = std::getenv("TURBO_PLAYERCAR_DEBUG_ACC") ? std::atoi(std::getenv("TURBO_PLAYERCAR_DEBUG_ACC")) : 0;
        int bsel = std::getenv("TURBO_PLAYERCAR_DEBUG_BSEL") ? std::atoi(std::getenv("TURBO_PLAYERCAR_DEBUG_BSEL")) : 1;
        long long n = std::getenv("TURBO_PLAYERCAR_DEBUG_N") ? std::atoll(std::getenv("TURBO_PLAYERCAR_DEBUG_N")) : 60;
        std::vector<std::pair<int,int>> seq_acc_bsel;
        bool use_seq = std::getenv("TURBO_PLAYERCAR_DEBUG_SEQ") != nullptr;
        if (use_seq) {
            auto add = [&](int a, int b, int count) {
                for (int i = 0; i < count; ++i) seq_acc_bsel.push_back({a, b});
            };
            add(0, 3, 3000);
            add(0, 0, 4000);
            add(27, 1, 4000);
            add(63, 2, 4000);
            add(27, 2, 2000);
            add(0, 1, 4000);
            add(63, 0, 4000);
            int mute_samples = std::getenv("TURBO_PLAYERCAR_DEBUG_MUTE_SAMPLES") ?
                std::atoi(std::getenv("TURBO_PLAYERCAR_DEBUG_MUTE_SAMPLES")) : 25000;
            add(27, 3, mute_samples);
            n = (long long)seq_acc_bsel.size();
        } else {
            dut.acc = acc; dut.bsel = bsel;
        }
        long long max_abs_tone = 0;
        long long clip_count = 0, total = 0;
        long long max_gain0 = 0, max_gain1 = 0, max_gain2 = 0;
        for (long long i = 0; i < n; ++i) {
            if (use_seq) { dut.acc = seq_acc_bsel[i].first; dut.bsel = seq_acc_bsel[i].second; }
            for (int c = 0; c < AUDIO_INTERVAL_CLOCKS - 1; ++c) {
                tick(dut, false);
                {
                    long long g0 = (long long)dut.rootp->turbo_playercar_chan__DOT__gain0_q16;
                    long long g1 = (long long)dut.rootp->turbo_playercar_chan__DOT__gain1_q16;
                    long long g2 = (long long)dut.rootp->turbo_playercar_chan__DOT__gain2_q16;
                    if (g0 > max_gain0) max_gain0 = g0;
                    if (g1 > max_gain1) max_gain1 = g1;
                    if (g2 > max_gain2) max_gain2 = g2;
                }
                if (i == 15000) {
                    static bool prev_rsp = false;
                    bool rsp = dut.rootp->turbo_playercar_chan__DOT__pc_lane_rsp_valid;
                    if (rsp) {
                        std::printf("MULOP i=%lld c=%d op=%d state=%d mag_a=%llu negate=%d "
                                    "rsp_product=%lld step_smoothed=%lld step_smoothed_next=%lld\n",
                                    i, c,
                                    (int)dut.rootp->turbo_playercar_chan__DOT__pc_op,
                                    (int)dut.rootp->turbo_playercar_chan__DOT__pc_seq_state,
                                    (unsigned long long)dut.rootp->turbo_playercar_chan__DOT__u_playercar_shared_mul_lane__DOT__mag_a,
                                    (int)dut.rootp->turbo_playercar_chan__DOT__u_playercar_shared_mul_lane__DOT__negate_result,
                                    (long long)dut.rootp->turbo_playercar_chan__DOT__pc_lane_rsp_product[0] |
                                    ((long long)dut.rootp->turbo_playercar_chan__DOT__pc_lane_rsp_product[1] << 32),
                                    (long long)dut.rootp->turbo_playercar_chan__DOT__step_smoothed,
                                    (long long)dut.rootp->turbo_playercar_chan__DOT__step_smoothed_next);
                    }
                }
                long long shadow = (long long)dut.rootp->turbo_playercar_chan__DOT__pc_vint_shadow;
                long long lh3 = (long long)dut.rootp->turbo_playercar_chan__DOT__pc_vint_lh3;
                long long step_up_sh = (long long)dut.rootp->turbo_playercar_chan__DOT__pc_step_up_shadow;
                long long step_dn_sh = (long long)dut.rootp->turbo_playercar_chan__DOT__pc_step_dn_shadow;
                long long maxstep = step_up_sh > step_dn_sh ? step_up_sh : step_dn_sh;
                long long dev = lh3 - shadow;
                int tone = (int16_t)dut.rootp->turbo_playercar_chan__DOT__pc_tone;
                total++;
                if (tone == 32767 || tone == -32768) {
                    clip_count++;
                    static long long clog = 0;
                    if (clog++ < 20) {
                        int16_t psp = (int16_t)dut.rootp->turbo_playercar_chan__DOT__player_source_pipe;
                        std::printf("CLIP i=%lld c=%d shadow=%lld lh3=%lld player_source_pipe=%d tone=%d acc=%d bsel=%d "
                                    "step_smoothed=%lld step_up_sh=%lld step_dn_sh=%lld\n",
                                    i, c, shadow, lh3, (int)psp, tone, (int)dut.acc, (int)dut.bsel,
                                    (long long)dut.rootp->turbo_playercar_chan__DOT__step_smoothed,
                                    step_up_sh, step_dn_sh);
                    }
                }
                if (llabs(tone) > llabs(max_abs_tone)) max_abs_tone = tone;
                // Flag whenever the 3-step lookahead deviates from the
                // shadow by more than 3x the current max per-step size --
                // should never happen if the invariant "lh3 == shadow + <=3
                // steps" holds.
                long long TH_HI = 126162442, TH_LO = 66664434;
                long long slack = 3 * maxstep + 10;
                if (shadow > TH_HI + slack || shadow < TH_LO - slack) {
                    static long long count = 0;
                    if (count++ < 40)
                        std::printf("OOB i=%lld c=%d shadow=%lld sq_sh=%d step_up_sh=%lld "
                                    "step_dn_sh=%lld step_smoothed=%lld acc=%d bsel=%d\n",
                                    i, c, shadow,
                                    (int)dut.rootp->turbo_playercar_chan__DOT__pc_sq_shadow,
                                    step_up_sh, step_dn_sh,
                                    (long long)dut.rootp->turbo_playercar_chan__DOT__step_smoothed,
                                    (int)dut.acc, (int)dut.bsel);
                }
                if (llabs(dev) > 3 * maxstep + 10) {
                    std::printf("DEVIATION i=%lld c=%d shadow=%lld lh1=%lld lh2=%lld lh3=%lld "
                                "sq_sh=%d sq1=%d sq2=%d sq3=%d step_up_sh=%lld step_dn_sh=%lld "
                                "vco.vint=%lld vco.sq=%d pc_tone=%d\n",
                                i, c, shadow,
                                (long long)dut.rootp->turbo_playercar_chan__DOT__pc_vint_lh1,
                                (long long)dut.rootp->turbo_playercar_chan__DOT__pc_vint_lh2,
                                lh3,
                                (int)dut.rootp->turbo_playercar_chan__DOT__pc_sq_shadow,
                                (int)dut.rootp->turbo_playercar_chan__DOT__pc_sq_lh1,
                                (int)dut.rootp->turbo_playercar_chan__DOT__pc_sq_lh2,
                                (int)dut.rootp->turbo_playercar_chan__DOT__pc_sq_lh3,
                                step_up_sh, step_dn_sh,
                                (long long)dut.rootp->turbo_playercar_chan__DOT__vint,
                                (int)dut.rootp->turbo_playercar_chan__DOT__u_vco__DOT__sq,
                                (int16_t)dut.rootp->turbo_playercar_chan__DOT__pc_tone);
                }
            }
            tick(dut, true);
            if (std::getenv("TURBO_PLAYERCAR_DEBUG_D8") &&
                (i < 120 || (i % 100) == 0 ||
                 std::getenv("TURBO_PLAYERCAR_DEBUG_D8_ALL"))) {
                std::printf("D8 i=%lld acc=%d bsel=%d raw=%d tone=%d n_bout=%d mycar_cont=%d "
                            "c7=%d c154=%d aout_v=%d n5bout_v=%d n_c17_v=%d "
                            "bout_v=%d loop_v=%d ic5b=%d\n",
                            i, (int)dut.acc, (int)dut.bsel,
                            (int16_t)dut.rootp->turbo_playercar_chan__DOT__pc_tone_raw,
                            (int16_t)dut.rootp->turbo_playercar_chan__DOT__pc_tone,
                            (int16_t)dut.rootp->turbo_playercar_chan__DOT__pc_n_bout_ac,
                            (int16_t)dut.rootp->turbo_playercar_chan__DOT__pc_mycar_cont_ac,
                            (int)dut.rootp->turbo_playercar_chan__DOT__u_d8_transient__DOT__c7_q12,
                            (int)dut.rootp->turbo_playercar_chan__DOT__u_d8_transient__DOT__c154_q12,
                            (int)dut.rootp->turbo_playercar_chan__DOT__u_d8_transient__DOT__aout_v,
                            (int)dut.rootp->turbo_playercar_chan__DOT__u_d8_transient__DOT__n5bout_v,
                            (int)dut.rootp->turbo_playercar_chan__DOT__u_d8_transient__DOT__n_c17_v,
                            (int)dut.rootp->turbo_playercar_chan__DOT__u_d8_transient__DOT__bout_v,
                            (int)dut.rootp->turbo_playercar_chan__DOT__u_d8_transient__DOT__n_loop_v,
                            (int)dut.rootp->turbo_playercar_chan__DOT__u_d8_transient__DOT__ic5b_hi);
            }
            long long ss = (long long)dut.rootp->turbo_playercar_chan__DOT__step_smoothed;
            static long long prev_ss = 0;
            static long long first_blowup = -1;
            if (first_blowup < 0 && (ss > 100000 || ss < -100000)) {
                first_blowup = i;
                std::printf("BLOWUP first at sample i=%lld acc=%d bsel=%d step_smoothed=%lld prev=%lld\n",
                            i, (int)dut.acc, (int)dut.bsel, ss, prev_ss);
            }
            prev_ss = ss;
        }
        std::printf("SUMMARY total=%lld clip_count=%lld max_abs_tone=%lld "
                    "max_gain0=%lld max_gain1=%lld max_gain2=%lld "
                    "final_gain0=%lld final_gain1=%lld final_gain2=%lld\n",
                    total, clip_count, max_abs_tone, max_gain0, max_gain1, max_gain2,
                    (long long)dut.rootp->turbo_playercar_chan__DOT__gain0_q16,
                    (long long)dut.rootp->turbo_playercar_chan__DOT__gain1_q16,
                    (long long)dut.rootp->turbo_playercar_chan__DOT__gain2_q16);
        std::printf("FINAL_TAPS f=%d w=%d mycar_f=%d mycar_w=%d tone=%d "
                    "xprev=%d yprev=%d qnext=%d fw_next=%d\n",
                    (int16_t)dut.rootp->turbo_playercar_chan__DOT__dcblock_f_mix,
                    (int16_t)dut.rootp->turbo_playercar_chan__DOT__dcblock_w_mix,
                    (int16_t)dut.rootp->turbo_playercar_chan__DOT__mycar_f_mix,
                    (int16_t)dut.rootp->turbo_playercar_chan__DOT__mycar_w_mix,
                    (int16_t)dut.rootp->turbo_playercar_chan__DOT__pc_tone,
                    (int16_t)dut.rootp->turbo_playercar_chan__DOT__dcblock_f_xprev,
                    (int16_t)dut.rootp->turbo_playercar_chan__DOT__dcblock_f_yprev,
                    (int16_t)dut.rootp->turbo_playercar_chan__DOT__mycarq_f_next,
                    (int16_t)dut.rootp->turbo_playercar_chan__DOT__mycar_fw_next);
        dut.final();
        return 0;
    }
#endif

    if (const char *out_dir = std::getenv("TURBO_PLAYERCAR_WAV_DIR")) {
        std::vector<int16_t> f, w;
        f.reserve(first.size()); w.reserve(first.size());
        for (const Sample &s : first) { f.push_back(s.dcf); w.push_back(s.dcw); }
        char path[512];
        std::snprintf(path, sizeof(path), "%s/turbo_playercar_dcblock_f.wav", out_dir);
        write_wav(path, f, 47999);
        std::snprintf(path, sizeof(path), "%s/turbo_playercar_dcblock_w.wav", out_dir);
        write_wav(path, w, 47999);
    }

    std::vector<Sample> second = run_sequence();
    if (!same_samples(first, second)) fail("nondeterministic replay");

    // Index ranges (see phase() calls above): [0,60)=BSEL3 idle,
    // [60,140)=BSEL0 acc0, [140,220)=BSEL1 acc27, [220,300)=BSEL2 acc63,
    // [300,340)=BSEL2 acc27, [340,420)=BSEL1 acc0, [420,500)=BSEL0 acc63,
    // [500,560)=BSEL3 acc27.
    auto pp = [&](size_t lo, size_t hi, auto field) {
        int16_t mn = 32767, mx = -32768;
        for (size_t i = lo; i < hi; ++i) {
            int16_t v = field(first[i]);
            if (v < mn) mn = v;
            if (v > mx) mx = v;
        }
        return static_cast<int32_t>(mx) - static_cast<int32_t>(mn);
    };

    // Last portion of each settled phase: enough cycles past the ladder/
    // BCONT time constants for the gate to have reached steady state.
    // Phase boundaries: [0,3000)=BSEL3, [3000,7000)=BSEL0 acc0,
    // [7000,11000)=BSEL1 acc27, [11000,15000)=BSEL2 acc63,
    // [15000,17000)=BSEL2 acc27, [17000,21000)=BSEL1 acc0,
    // [21000,25000)=BSEL0 acc63, [25000,245000)=BSEL3 acc27.
    size_t bsel0_lo = 3000 + 3000, bsel0_hi = 7000;
    size_t bsel1_lo = 7000 + 3000, bsel1_hi = 11000;
    size_t bsel2_lo = 11000 + 3000, bsel2_hi = 15000;
    size_t bsel3_lo = 245000 - 3000, bsel3_hi = 245000;

    if (pp(bsel0_lo, bsel0_hi, [](const Sample &s) { return s.qf; }) < 10)
        fail("BSEL0 MYCARQ.F not audible");
    if (pp(bsel1_lo, bsel1_hi, [](const Sample &s) { return s.f1; }) < 10)
        fail("BSEL1 MYCAR1.F not audible");
    if (pp(bsel1_lo, bsel1_hi, [](const Sample &s) { return s.w1; }) < 10)
        fail("BSEL1 MYCAR1.W not audible");
    // The D9 trace has distinct IC24-A (F/FM) and IC24-B/C (W) branches.
    // They share MY CAR CONT but the C155/R196 W-side pole must not collapse
    // back to the F waveform.  Require a settled, nontrivial difference;
    // this is a topology invariant, not a cabinet-timbre target.
    size_t bsel1_different = 0;
    for (size_t i = bsel1_lo; i < bsel1_hi; ++i) {
        if (std::abs(static_cast<int>(first[i].f1) -
                    static_cast<int>(first[i].w1)) > 4)
            ++bsel1_different;
    }
    if (bsel1_different < (bsel1_hi - bsel1_lo) / 4)
        fail("BSEL1 F/W paths collapsed");
    if (pp(bsel2_lo, bsel2_hi, [](const Sample &s) { return s.f; }) < 10)
        fail("BSEL2 MYCAR.F not audible");

    // BSEL==3 should mute all three families (mycar_off_n low).
    if (pp(bsel3_lo, bsel3_hi, [](const Sample &s) { return s.qf; }) > 4)
        fail("BSEL3 MYCARQ.F not muted");
    if (pp(bsel3_lo, bsel3_hi, [](const Sample &s) { return s.f1; }) > 4)
        fail("BSEL3 MYCAR1.F not muted");
    if (pp(bsel3_lo, bsel3_hi, [](const Sample &s) { return s.f; }) > 4)
        fail("BSEL3 MYCAR.F not muted");

    // Cross-check mycar_off_n directly.
    {
        Vturbo_playercar_chan dut;
        reset(dut);
        dut.acc = 10; dut.bsel = 3;
        for (int i = 0; i < AUDIO_INTERVAL_CLOCKS; ++i) tick(dut, i == AUDIO_INTERVAL_CLOCKS - 1);
        if (dut.mycar_off_n != 0) fail("mycar_off_n not asserted at BSEL==3");
        dut.bsel = 2;
        for (int i = 0; i < AUDIO_INTERVAL_CLOCKS; ++i) tick(dut, i == AUDIO_INTERVAL_CLOCKS - 1);
        if (dut.mycar_off_n != 1) fail("mycar_off_n asserted at BSEL==2");
        dut.final();
    }

    std::printf("PASS turbo_playercar\n");
    return 0;
}
