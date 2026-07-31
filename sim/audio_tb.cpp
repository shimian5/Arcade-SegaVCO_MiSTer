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
static const int HIT_PB_BIT    = 4;
static const int HITCLK_PA_BIT = 4;   // rising edge strobes IC2 (HIT DIS)
static const int REBOUND_PB_BIT= 5;
static const int SHIPON_PB_BIT = 6;   // active-HIGH level, not an edge
static const int ACCCLK_PA_BIT = 5;   // rising edge strobes IC6 (ACC0-3)
static const int GAMEON_PB_BIT = 7;   // active-HIGH level: 7417 O.C. -> LA4460 pin 6 (DC mute)

struct Harness {
    Vaudio_top *dut;
    vluint64_t time_ps = 0;
    uint8_t pa = 0xFF;
    // pb[6] = SHIP ON is active HIGH, so it must idle LOW or every scenario
    // would have the engine running underneath it.
    // pb[7] = GAME ON is also active HIGH but idles HIGH: it is the board's
    // global enable, and the game asserts it once at boot and leaves it there.
    // Idling it low would mute every scenario.
    uint8_t pb = 0xFF & ~(1 << 6);
    std::vector<int16_t> samples;
    // DC-mute tracking: how many captured samples were muted, and the sample
    // index at which the mute first released (-1 = never released).
    uint64_t muted_samples = 0;
    long mute_release_idx = -1;
    bool was_muted = false;
    // per-channel peaks, to separate an internally-saturating channel from
    // master-stage clipping
    int pk_alarm = 0, pk_fire = 0, pk_exp = 0, pk_hit = 0, pk_reb = 0, pk_ship = 0;

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
            // Record the mute state alongside the sample. A "release" is the
            // first unmuted sample that follows a muted one, so a scenario that
            // starts already unmuted reports -1 rather than a spurious 0.
            bool m = dut->dbg_dc_mute != 0;
            if (m) { muted_samples++; was_muted = true; }
            else if (was_muted && mute_release_idx < 0)
                mute_release_idx = (long)samples.size();
            samples.push_back((int16_t)dut->audio_l);
            auto absmax = [](int &acc, int16_t v) {
                int a = v < 0 ? -(int)v : (int)v;
                if (a > acc) acc = a;
            };
            absmax(pk_alarm, (int16_t)dut->dbg_alarm_mix);
            absmax(pk_fire,  (int16_t)dut->dbg_fire_mix);
            absmax(pk_exp,   (int16_t)dut->dbg_exp_mix);
            absmax(pk_hit,   (int16_t)dut->dbg_hit_mix);
            absmax(pk_reb,   (int16_t)dut->dbg_rebound_mix);
            absmax(pk_ship,  (int16_t)dut->dbg_ship_mix);
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
    // The binding constraint is no longer the ALARM high-pass's 52.17 ms tau
    // (600 ms covered that comfortably): it is the LA4460's DC mute. IC26
    // holds pin 6 low through the 470K/4.7uF power-on delay, so nothing at all
    // reaches the output for the first 1.5312 s. Settling for less than that
    // would make every scenario record silence for its opening samples.
    // 1700 ms clears the release with ~170 ms of margin, by which point the
    // thump the mute was covering is long gone.
    void settle(double ms = 1700.0) {
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

    // /HIT is port B bit 4.
    void pulse_hit(double low_ms = 1.0) {
        pb &= ~(1 << HIT_PB_BIT);
        run_ms(low_ms);
        pb |= (1 << HIT_PB_BIT);
    }

    // /REBOUND is port B bit 5.
    void pulse_rebound(double low_ms = 1.0) {
        pb &= ~(1 << REBOUND_PB_BIT);
        run_ms(low_ms);
        pb |= (1 << REBOUND_PB_BIT);
    }

    // HIT DIS0-2: drive the shared nibble on port A bits 0-2, then strobe
    // IC2 with a rising edge on port A bit 4, exactly as the CPU does.
    void set_hit_dis(int dis) {
        pa &= ~(1 << HITCLK_PA_BIT);
        run_ms(0.05);
        pa = (uint8_t)((pa & ~0x07) | (dis & 0x07));
        run_ms(0.05);
        pa |= (1 << HITCLK_PA_BIT);
        run_ms(0.05);
    }

    // SHIP ON is a level: assert and leave it.
    void ship_on(bool on) {
        if (on) pb |= (1 << SHIPON_PB_BIT);
        else    pb &= ~(1 << SHIPON_PB_BIT);
        apply_ports();
    }

    // GAME ON is a level too: the CPU's global sound enable, which drives the
    // LA4460's DC mute pin through a 7417 open-collector buffer. Low = muted.
    void game_on(bool on) {
        if (on) pb |= (1 << GAMEON_PB_BIT);
        else    pb &= ~(1 << GAMEON_PB_BIT);
        apply_ports();
    }

    // ACC0-3: drive the shared nibble on port A bits 0-3, then strobe IC6
    // with a rising edge on port A bit 5. Unlike IC2 this latch uses all four
    // bits.
    void set_acc(int a) {
        pa &= ~(1 << ACCCLK_PA_BIT);
        run_ms(0.05);
        pa = (uint8_t)((pa & ~0x0F) | (a & 0x0F));
        run_ms(0.05);
        pa |= (1 << ACCCLK_PA_BIT);
        run_ms(0.05);
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
        fprintf(stderr, "usage: %s <scenario 0-22>\n", argv[0]);
        return 1;
    }
    int scen = atoi(argv[1]);

    Harness h;
    h.reset(100);
    // Scenarios 11 (the power-on thump) and 21 (the power-on mute that covers
    // it) are both about t = 0 itself, so they must NOT settle first.
    if (scen != 11 && scen != 21) h.settle();

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
        // ---- HIT (phase 4) ----
        case 12:
            // one hit at the closest/brightest setting (all three DIS bits).
            // 2.5 s: C48 recharges through 2 M with tau = 1.36 s, so the
            // VCA tail is long.
            h.set_hit_dis(7);
            h.run_ms(10);
            h.pulse_hit();
            h.run_ms(2500 - 10);
            break;
        case 13:
            // the DIS sweep: same hit at each of the seven non-muted
            // settings. This is the acceptance test for the distance cue --
            // level AND brightness should both fall as DIS decreases.
            for (int d = 7; d >= 1; d--) {
                h.set_hit_dis(d);
                h.pulse_hit();
                h.run_ms(400);
            }
            break;
        case 14:
            // hits under a sustained ALARM0, the gameplay combination.
            // HIT has the hottest path into the mixer (R136 5.1 K), so this
            // is where clipping would show up first.
            h.set_hit_dis(7);
            h.run_ms(10);
            for (int i = 0; i < 8; i++) {
                h.pulse_alarm(0);
                if (i % 2 == 0) h.pulse_hit();
                h.run_ms(80 - 2);
            }
            h.run_ms(1500);
            break;
        // ---- REBOUND (phase 5) ----
        case 15:
            // one rebound. 3.5 s: C43 recharges through 800 K with
            // tau = 1.76 s, and the 555 rate sweeps 24.6 -> 6.2 Hz and then
            // stops as the control voltage reaches Vcc, so the whole decay
            // must be visible.
            h.run_ms(10);
            h.pulse_rebound();
            h.run_ms(3500 - 10);
            break;
        case 16:
            // repeated rebounds -- the 74123 is retriggerable, so each should
            // restart the sweep from the top rather than queueing.
            h.run_ms(10);
            for (int i = 0; i < 4; i++) {
                h.pulse_rebound();
                h.run_ms(700 - 1);
            }
            h.run_ms(2000);
            break;
        // ---- SHIP (phase 6) ----
        case 17:
            // Engine at a mid throttle, held. 2 s -- long enough for 14 cycles
            // of the 6.95 Hz 555 LFO, so the counter-motion of Tr2 (205->411 Hz)
            // against Tr5 (143->71 Hz) is unmistakable, and long enough for the
            // C11 glide (203 ms at this setting) to have finished.
            h.set_acc(4);
            h.ship_on(true);
            h.run_ms(2000);
            break;
        case 18:
            // The throttle sweep, and SHIP's acceptance test. Tr4's chop rate
            // should climb monotonically 410 -> 3236 Hz across these settings
            // while the LEVEL stays put: ACC moves spectrum, not amplitude.
            // 400 ms a step is over twice the worst-case C11 glide.
            h.ship_on(true);
            for (int a = 1; a <= 15; a += 2) {
                h.set_acc(a);
                h.run_ms(400);
            }
            break;
        case 19:
            // ACC = 0000, the one code that STOPS Tr4 (Vs = 0 -> both slew
            // rates zero). C56 then bleeds the frozen offset away over 0.22 s
            // and the VCA parks wide open, so this is the unmodulated drone --
            // and the loudest the channel gets. Then step to full throttle to
            // watch the 55 ms glide, then gate the engine off and on.
            h.set_acc(0);
            h.ship_on(true);
            h.run_ms(1200);
            h.set_acc(15);
            h.run_ms(800);
            h.ship_on(false);
            h.run_ms(200);
            h.ship_on(true);
            h.run_ms(800);
            break;
        case 20:
            // The real gameplay pile-up: engine held under alarms, with a
            // laser and a hit over the top. SHIP is the only CONTINUOUS
            // channel, so this -- not scenario 14 -- is what MASTER_VOL has to
            // be calibrated against.
            h.set_acc(8);
            h.ship_on(true);
            h.set_hit_dis(7);
            h.run_ms(10);
            for (int i = 0; i < 10; i++) {
                h.pulse_alarm(0);
                if (i % 3 == 0) h.pulse_fire();
                if (i % 5 == 0) h.pulse_hit();
                h.run_ms(60 - 1);
            }
            h.run_ms(1200);
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
        // ---- global mute (LA4460 pin 6) ----
        case 21:
            // The power-on mute, captured from the instant reset releases, so
            // it must NOT settle. IC26 watches a 470K/4.7uF network and holds
            // the DC mute pin low for the first 1.5312 s -- which is exactly
            // what covers the power-on thump scenario 11 records. The engine is
            // started at t = 0 and held so there is something loud underneath:
            // the acceptance test is bit-exact zero out until the release at
            // sample 73494 (61,147,057 clk_sys / 832), and the engine already
            // running at full tilt the moment it lifts.
            h.set_acc(6);
            h.ship_on(true);
            h.run_ms(2500);
            break;
        case 22:
            // GAME ON toggling. The CPU's own mute, same pin as the power-on
            // delay. The point is that muting is an OUTPUT-stage attenuation,
            // not a reset: the channels keep running behind it. So an alarm and
            // a hit are fired WHILE muted, and when GAME ON comes back the hit
            // must reappear part-way through its 1.36 s tail rather than
            // starting over -- and the engine must be at whatever phase it
            // reached, not re-glided from idle.
            h.set_acc(6);
            h.ship_on(true);
            h.set_hit_dis(7);
            h.run_ms(400);
            h.game_on(false);
            h.run_ms(50);
            h.pulse_alarm(0);
            h.pulse_hit();
            h.run_ms(400 - 52);
            h.game_on(true);
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
    long first_nonzero = -1;
    for (size_t i = 0; i < h.samples.size(); i++) {
        int16_t s = h.samples[i];
        int16_t a = s < 0 ? (int16_t)(-s) : s;
        if (a > peak) peak = a;
        if (s != 0) { nonzero++; if (first_nonzero < 0) first_nonzero = (long)i; }
    }
    // For the mute scenarios this is the acceptance check: first_nonzero must
    // not precede the mute release.
    printf("scenario=%2d first_nonzero=%ld\n", scen, first_nonzero);

    // channel peaks in volts: 4096 LSB = 1 V. The board is a 12 V single
    // supply biased at 6 V, so anything much past +/-5.5 V at a channel's
    // MIX node is not physically reachable on hardware.
    printf("scenario=%2d samples=%6zu peak=%5d nonzero=%6llu | "
           "alarm=%5d (%.2fV) fire=%5d (%.2fV) exp=%5d (%.2fV) hit=%5d (%.2fV) reb=%5d (%.2fV) ship=%5d (%.2fV) | "
           "muted=%6llu release=%7ld\n",
           scen, h.samples.size(), (int)peak, (unsigned long long)nonzero,
           h.pk_alarm, h.pk_alarm / 4096.0,
           h.pk_fire,  h.pk_fire  / 4096.0,
           h.pk_exp,   h.pk_exp   / 4096.0,
           h.pk_hit,   h.pk_hit   / 4096.0,
           h.pk_reb,   h.pk_reb   / 4096.0,
           h.pk_ship,  h.pk_ship  / 4096.0,
           (unsigned long long)h.muted_samples, h.mute_release_idx);

    return 0;
}
