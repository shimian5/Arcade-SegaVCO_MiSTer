// Focused fixed-point D8 transient trace bench.
//
// This drives the corrected turbo_playercar_d8_transient boundary directly,
// so the Python implicit reference can be compared without the upstream
// relax_vco or the shared player-car sequencer hiding a node mismatch.
#include <Vturbo_playercar_d8_transient.h>
#include <verilated.h>
#include <cstdint>
#include <cstdio>

static void tick(Vturbo_playercar_d8_transient &dut, bool sample_ce) {
    dut.sample_ce = sample_ce;
    dut.clk = 1; dut.eval();
    dut.clk = 0; dut.eval();
}

int main() {
    Vturbo_playercar_d8_transient dut;
    dut.clk = 0;
    dut.rst_n = 0;
    dut.sample_ce = 0;
    dut.source_in = 0;
    dut.eval();
    for (int i = 0; i < 8; ++i) tick(dut, false);
    dut.rst_n = 1;

    // The first 687 samples are a negative N_SRC departure and the rest a
    // positive departure.  This is the same bounded transition used by the
    // existing reference comparison, expressed in Q12 volts.
    for (int i = 0; i < 1200; ++i) {
        dut.source_in = (i < 687) ? -7262 : 7262;
        tick(dut, true);
        std::printf("D8 i=%d raw=%d n_bout=%d mycar_cont=%d\n",
                    i, (int)dut.source_in,
                    (int)dut.n_bout_v_q12,
                    (int)dut.mycar_cont_v_q12);
    }
    dut.final();
    return 0;
}
