// One of SHIP's three relaxation oscillators (Tr2, Tr4, Tr5 on sheet 1).
// Written as a general part, parameterised by its two slew constants, because
// the board draws the identical circuit three times and only the integrator's
// R_in / C / R_c differ. See docs/audio-rtl-design.md, "Tr4 and Tr5"; this
// module must not contradict that file.
//
//        Vs ---R_in--->|- \                      integrator: C is the ONLY
//                      |    >--+--- vint         feedback element
//        Vs --+--51K---|+ /    |
//             |        |       |
//            51K       +---C---+
//             |
//            GND               summing node also pulled down by R_c -> collector
//
//        vint ---------|- \                      Schmitt
//                      |    >--+--- sq
//        6V ---51K--+--|+ /    |
//                   |          |
//                   +---100K---+
//
//        sq --10K--|>|-- base (2.2K to gnd), emitter grounded, collector -> R_c
//
// The "+" divider goes to TRUE GROUND, so the virtual node sits at Vs/2 and
// the frequency is exactly proportional to Vs. Slew rates:
//
//   transistor off:  dvint/dt = -(Vs/2) / (R_in * C)
//   transistor on:   dvint/dt = +(Vs/2) * (1/R_c - 1/R_in) / C
//
// R_c < R_in in all three instances, so the "on" term always wins and the
// oscillator always runs (except at Vs = 0, where both rates are zero and it
// correctly freezes -- that is ACC = 0000 for Tr4).
//
// WHY THIS RUNS AT clk_sys AND NOT AT sample_ce
// ---------------------------------------------
// Tr4 reaches 3.2 kHz, 15 audio samples per cycle. Quantising the threshold
// crossings to the 48 kHz grid would jitter the period by up to 7% and alias.
// So the integrator is a full-rate accumulator -- which is EXACT here, the ramp
// being linear rather than exponential -- and the output is box-averaged over
// the 832 clk_sys cycles of each audio sample, the same 1st-order CIC decimator
// alarm_chan.sv uses. Crossings then land within one clk_sys (25 ns) of truth.
//
// The two step sizes depend only on Vs, which moves at 7 Hz, so they are
// recomputed once per audio sample and merely added 832 times.
module relax_vco #(
    // Volts of vint per clk_sys per volt of vs_half, in Q0.40.
    parameter longint K_UP_Q40 = 0,
    parameter longint K_DN_Q40 = 0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic signed [39:0] vs_half,   // Vs/2, 2^24 LSB/V
    output logic signed [39:0] vint_avg   // box-average of vint over the last
                                          // 832 clks, 2^24 LSB/V, valid on
                                          // the sample_ce cycle
);

    // Schmitt thresholds, shared by all three instances and independent of
    // frequency (the mean is what the DC blocks downstream rely on):
    //   Vth = (6/51K + Vsq/100K) / (1/51K + 1/100K)
    //   Vsq = V_OH 10.5 V -> 7.519868 V ;  Vsq = V_OL 0 V -> 3.973510 V
    // V_OH is the one soft number in SHIP -- an MB3614 (10.0 V) would raise
    // every SHIP frequency by a uniform 5.0%.
    localparam signed [39:0] TH_HI   = 40'sd126162442;  // 7.519868 V * 2^24
    localparam signed [39:0] TH_LO   = 40'sd66664434;   // 3.973510 V * 2^24
    localparam signed [39:0] TH_MEAN = 40'sd96413438;   // 5.746689 V * 2^24

    // 1/832 in Q0.32, for the decimator. 5162220/2^32 = 1/832.0000455.
    localparam signed [63:0] RECIP832_Q32 = 64'sd5162220;

    // ---------------------------------------------------------------
    // Slew steps, latched once per audio sample.
    //   step = (vs_half * K_Q40) >> 40
    // vs_half <= 5.16 V * 2^24 = 8.7e7 (27 bits); K_UP_Q40 <= 1.2e8 (27 bits);
    // product <= 2^54, comfortably inside 64.
    // ---------------------------------------------------------------
    wire signed [63:0] up_prod = 64'(vs_half) * 64'(K_UP_Q40);
    wire signed [63:0] dn_prod = 64'(vs_half) * 64'(K_DN_Q40);

    logic signed [39:0] step_up, step_dn;

    // ---------------------------------------------------------------
    // Integrator + Schmitt, at full clk_sys.
    //
    // `sq` is the Schmitt's output: high = transistor saturated = vint rising.
    // The comparison uses the registered vint, so a crossing is acted on one
    // clk_sys later. That is the 25 ns quantisation noted above and is the
    // only error in the oscillator.
    // ---------------------------------------------------------------
    logic signed [39:0] vint;
    logic               sq;

    // ---------------------------------------------------------------
    // Decimator. acc holds the running sum of vint over the current sample
    // window; on sample_ce it is both consumed and restarted, exactly as
    // alarm_chan.sv does with its node bit.
    //   |vint| <= 7.52 V * 2^24 = 1.26e8, times 832 = 1.05e11 (37 bits).
    //   acc * RECIP832_Q32 <= 2^60.
    // ---------------------------------------------------------------
    logic signed [55:0] acc;

    wire signed [63:0] avg_prod = 64'(acc) * RECIP832_Q32 + 64'sd2147483648;
    assign vint_avg = 40'(avg_prod >>> 32);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Start at the triangle's own mean with the transistor off. Any
            // start point converges within half a cycle; this one puts no step
            // into the downstream DC blocks, whose x_d resets to the same
            // value.
            vint    <= TH_MEAN;
            sq      <= 1'b0;
            acc     <= '0;
            step_up <= '0;
            step_dn <= '0;
        end else begin
            if (sample_ce) begin
                step_up <= 40'(up_prod >>> 40);
                step_dn <= 40'(dn_prod >>> 40);
                acc     <= 56'(vint);
            end else begin
                acc     <= acc + 56'(vint);
            end

            vint <= sq ? (vint + step_up) : (vint - step_dn);

            if (sq && (vint >= TH_HI))
                sq <= 1'b0;
            else if (!sq && (vint <= TH_LO))
                sq <= 1'b1;
        end
    end

endmodule
