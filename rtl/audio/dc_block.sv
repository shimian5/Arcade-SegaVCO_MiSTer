// One-pole coupling-cap high-pass (a "DC block"), used three times by SHIP for
// C65/R118, C59/R120 and C56/R102. See docs/audio-rtl-design.md, "The DC blocks
// are exact, and that is worth stating".
//
//   y[n] = a * (y[n-1] + x[n] - x[n-1])
//
// Input arrives at the oscillator scale (2^24 LSB/V) and is carried internally
// at 2^32 LSB/V; the output is reduced to the house analog-tail scale
// (2^20 = 4096*256 LSB/V) that the MC3340 LUT and the rest of the channel use.
//
// The wide internal scale is the leaky-integrator STALL fix recorded under
// "Numeric formats", not coefficient precision: a leaky integrator stops
// moving once its per-step decrement falls under the rounding threshold, at
// |y| = 0.5/(1-a) STATE LSB, and only widening the state moves that. At
// a = 0.999957 the stall is 11614 LSB, which at 2^32 LSB/V is 2.7 uV -- three
// orders under one output LSB. Every shift here rounds to nearest, so a
// negative state is not biased away from zero on each step.
module dc_block #(
    // exp(-1/(fs*tau)) in Q0.24. Declared at 27 bits, not 32: every
    // instantiated value fits in ~25 bits, and now that hp_prod is a
    // registered multiply (this file's own timing-closure pass) rather than
    // combinational logic, Quartus DSP-infers it -- a 27-bit operand packs
    // into a single native Cyclone V 27x27 DSP multiplier where 32 bits
    // would force two. See docs/audio-rtl-design.md, "DSP block budget".
    parameter signed [26:0] A_Q24 = 0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,  // pulses once x_in has settled to its
                                            // value for the current audio sample
                                            // -- the caller wires in relax_vco.sv's
                                            // vint_avg_ce here, not the raw system
                                            // sample_ce
    input  logic signed [39:0] x_in,     // 2^24 LSB/V
    input  logic signed [39:0] x_reset,  // steady-state input at reset, 2^24 LSB/V
    output logic signed [31:0] y_out     // 2^20 LSB/V
);

    logic signed [47:0] x_d, y_state;

    // ---------------------------------------------------------------
    // TIMING-CLOSURE NOTE. As first written, x_scaled -> hp_sum -> hp_prod
    // -> y_next -> y_out was one combinational expression per sample. SHIP's
    // three instances of this module each feed straight into another live
    // multiply in ship_chan.sv's stage 0 (and, upstream, x_in itself comes
    // out of another live multiply in relax_vco.sv) -- three serial
    // multiplies settling in a single clk_sys hop, the worst timing path a
    // real Quartus build found on this design (`relax_vco:u_tr2|acc[40] ->
    // p0_vca_in_prod[55]`, -10.787 ns slack). Fixed by splitting the one
    // multiply here into its own register-to-register hop, free-running on
    // clk. Two things had to be gotten right together, both caught only by
    // the full-game regression, not by inspection:
    //
    // 1. `sample_ce` must be a PROMPT pulse (relax_vco.sv's `vint_avg_ce`,
    //    firing a handful of clk_sys cycles after the real sample_ce), not
    //    a full audio-sample-late one. Tr2/Tr4/Tr5 are oscillators down to
    //    ~15 samples/cycle, not a slowly-varying control signal like
    //    alarm_chan.sv's; a full-sample lag in `x_d`'s capture is a real,
    //    audible phase error there, unlike alarm_chan.sv's negligible one.
    //
    // 2. `y_out` must be read off `y_state` -- a register that changes ONLY
    //    at `sample_ce` and holds for the whole window -- not off the
    //    continuously free-running hp_sum/hp_prod/y_next chain. That chain
    //    keeps recomputing every clk using whatever `x_d`/`y_state` CURRENTLY
    //    hold, so the cycle right after a capture it sees `x_scaled_pA` and
    //    `x_d` momentarily EQUAL (both just set to this window's x[n]) and
    //    computes hp_sum = 0, i.e. `y <= a*y_state` -- a pure decay step. If
    //    `y_out` were wired to that chain's output it would keep re-applying
    //    that decay on every one of the ~825 remaining clk_sys cycles in the
    //    window instead of holding y_state steady, a real (not cosmetic)
    //    ~3.5% amplitude error on SHIP's peak. The free-running chain is
    //    still useful -- it's what PRODUCES the next candidate state -- it's
    //    just not what the output tap reads.
    //
    // |x| <= 7.52 V * 2^32 = 3.2e10 (35 bits), |y| <= 1.78 V * 2^32 = 7.6e9,
    // so |hp_sum| < 2^37 and hp_prod < 2^61. hp_sum is declared at 40 bits
    // (not 64) so the hp_prod multiply below is sized for its true 37-bit
    // range rather than a needlessly wide one.
    // ---------------------------------------------------------------
    // x_reset is a runtime port (the caller's TRI_MEAN/etc.), not an
    // elaboration-time constant, so its reset-derived term is a wire, not a
    // localparam -- unlike every other reset constant below, which only
    // depend on this module's own parameter A_Q24.
    wire signed [47:0] X_SCALED_RESET = 48'(x_reset) <<< 8;
    // y_state resets to 0 and x_scaled/x_d both reset to the same value, so
    // hp_sum's reset is exactly 0 regardless of A_Q24 -- consistent with
    // this file's "no transient at reset" comment below.
    localparam signed [39:0] HP_SUM_RESET  = 40'sd0;
    localparam signed [63:0] HP_PROD_RESET = A_Q24 * HP_SUM_RESET + 64'sd8388608;
    localparam signed [47:0] Y_NEXT_RESET  = 48'(HP_PROD_RESET >>> 24);
    // y_out is read off y_state (reset to 0), not y_next_pD -- Y_NEXT_RESET
    // happens to also be 0 here, but derive Y_OUT_RESET from y_state's own
    // reset value (0) directly so the two can never silently drift apart.
    localparam signed [31:0] Y_OUT_RESET   = 32'((48'sd0 + 48'sd2048) >>> 12);

    logic signed [47:0] x_scaled_pA;
    logic signed [39:0] hp_sum_pB;
    logic signed [63:0] hp_prod_pC;
    logic signed [47:0] y_next_pD;
    logic signed [31:0] y_out_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            x_scaled_pA <= X_SCALED_RESET;
            hp_sum_pB   <= HP_SUM_RESET;
            hp_prod_pC  <= HP_PROD_RESET;
            y_next_pD   <= Y_NEXT_RESET;
        end else begin
            x_scaled_pA <= 48'(x_in) <<< 8;
            hp_sum_pB   <= 40'(y_state) + 40'(x_scaled_pA) - 40'(x_d);
            hp_prod_pC  <= A_Q24 * hp_sum_pB + 64'sd8388608;
            y_next_pD   <= 48'(hp_prod_pC >>> 24);
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Cap already charged to the source's steady-state DC -- the board
            // has been powered for seconds before the game makes a sound, and
            // all three SHIP sources sit at a constant mean. Resetting x_d to
            // zero instead would inject a full-scale step and ring for the
            // whole 0.48 s tau.
            x_d     <= X_SCALED_RESET;
            y_state <= '0;
        end else if (sample_ce) begin
            x_d     <= x_scaled_pA;
            y_state <= y_next_pD;
        end
    end

    // y_out is a plain register hop off the STABLE y_state (only changes at
    // sample_ce, held the rest of the window) -- not off y_next_pD, which
    // keeps evolving every clk between captures (see note above). One more
    // free-running clk of latency, negligible against the ~825-cycle margin.
    always_ff @(posedge clk) begin
        if (!rst_n) y_out_r <= Y_OUT_RESET;
        else        y_out_r <= 32'((48'(y_state) + 48'sd2048) >>> 12);
    end

    assign y_out = y_out_r;

endmodule
