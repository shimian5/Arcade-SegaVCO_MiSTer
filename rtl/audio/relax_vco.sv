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
    // Volts of vint per clk_sys per volt of vs_half, in Q0.40. Declared at
    // 32 bits, not 64: every instantiated value is documented below (Stage
    // "Slew steps") to fit in 27 bits, and a DSP-block multiplier is sized
    // off the OPERAND width Verilog actually presents to `*`, not off the
    // magnitude of the constant -- casting a 27-bit value up to 64 bits
    // before multiplying forces Quartus to build a needlessly wide
    // multiplier. See docs/audio-rtl-design.md, "DSP block budget".
    parameter signed [31:0] K_UP_Q40 = 0,
    parameter signed [31:0] K_DN_Q40 = 0
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic signed [39:0] vs_half,   // Vs/2, 2^24 LSB/V
    output logic signed [39:0] vint_avg,  // box-average of vint over the last
                                          // 832 clks, 2^24 LSB/V, stable from
                                          // vint_avg_ce until the NEXT sample_ce
    output logic               vint_avg_ce  // pulses once, a few clk_sys cycles
                                             // after sample_ce, when vint_avg
                                             // first reflects the just-completed
                                             // window -- see "Decimator" below
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
    // Declared at 27 bits, not 32: the value itself fits in 23 bits, and
    // now that the divide is a registered multiply (see below) rather than
    // combinational logic, Quartus DSP-infers it -- a 27-bit operand packs
    // into a single native Cyclone V 27x27 DSP multiplier where 32 bits
    // would force two. See docs/audio-rtl-design.md, "DSP block budget".
    localparam signed [26:0] RECIP832_Q32 = 27'sd5162220;

    // ---------------------------------------------------------------
    // Slew steps, latched once per audio sample.
    //   step = (vs_half * K_Q40) >> 40
    // vs_half <= 5.16 V * 2^24 = 8.7e7 (27 bits); K_UP_Q40 <= 1.2e8 (27 bits);
    // product <= 2^54, comfortably inside 64 -- but the MULTIPLIER ITSELF
    // only needs to be sized for the two 27-bit-ish operands below, so they
    // are multiplied at their natural declared widths (40 and 32 bits) and
    // the 64-bit result register captures the full product with no loss.
    // ---------------------------------------------------------------
    wire signed [63:0] up_prod = vs_half * K_UP_Q40;
    wire signed [63:0] dn_prod = vs_half * K_DN_Q40;

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
    //
    // TIMING-CLOSURE NOTE. As first written, vint_avg was a bare `assign`
    // straight off this divide -- combinationally correct, but only VALID
    // for the single clk_sys cycle sample_ce itself fires on, since acc is
    // reset to a fresh single sample the very next cycle. That is too
    // fragile a window to build a register pipeline on (a stage recomputing
    // every clk would be overwritten by the next cycle's garbage partial
    // sum), and it was also one live 56x32 multiply chained straight into
    // dc_block.sv's own multiply and then ship_chan.sv's stage-0 gain
    // multiply -- three serial multiplies settling in one clk_sys hop, the
    // worst offender found by a real Quartus build (`acc[40] ->
    // p0_vca_in_prod[55]`, -10.787 ns slack). Fixed the same way
    // alarm_chan.sv fixes its own leaky-integrator read: latch the
    // COMPLETED sum into `acc_latched` on sample_ce (stable for the whole
    // ~832-cycle window, exactly like alarm_chan.sv's acc_latched), then
    // let the divide-and-shift pipeline free-run off that stable source --
    // recomputing every clk just reproduces the same settled answer until
    // the next sample_ce, no valid-window tracking needed past this point.
    // `vint_avg_ce` tells dc_block.sv exactly when that settled answer first
    // appears (2 clk_sys cycles after sample_ce), so it can capture the
    // FRESH value promptly -- not a full audio-sample late, which for an
    // oscillating source like Tr2/Tr4/Tr5 (down to ~15 samples/cycle) would
    // be a real, audible phase error, unlike alarm_chan.sv's near-DC input.
    //
    // DSP-BUDGET NOTE. acc was originally declared at 56 bits, well past
    // its true ~38-bit range (see above), because as a bare combinational
    // divide it cost no DSP block either way. Registering the divide (this
    // pass) makes Quartus DSP-infer it, and a Cyclone V 27x27 multiplier
    // packs an operand in ceil(width/27) chunks -- 56 bits needs 3, so the
    // acc*RECIP832_Q32 multiply alone cost 3x as many DSP blocks as it
    // needed and blew the 112-block budget (found on a real Quartus build:
    // 121/112, Fitter Failed) even after RECIP832_Q32 was narrowed to 27
    // bits, because the WIDER of the two operands is what sets the chunk
    // count. Narrowed to 40 bits (2 chunks, matching vint/vs_half's own
    // width) to fix it -- see docs/audio-rtl-design.md, "DSP block budget".
    // ---------------------------------------------------------------
    logic signed [39:0] acc;
    logic signed [39:0] acc_latched;
    logic signed [63:0] avg_prod_r;
    logic signed [39:0] vint_avg_r;
    logic               ce_d1, ce_d2, ce_d3;

    localparam signed [63:0] AVG_PROD_RESET = 40'sd0 * RECIP832_Q32 + 64'sd2147483648;
    localparam signed [39:0] VINT_AVG_RESET = 40'(AVG_PROD_RESET >>> 32);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Start at the triangle's own mean with the transistor off. Any
            // start point converges within half a cycle; this one puts no step
            // into the downstream DC blocks, whose x_d resets to the same
            // value.
            vint        <= TH_MEAN;
            sq          <= 1'b0;
            acc         <= '0;
            acc_latched <= '0;
            avg_prod_r  <= AVG_PROD_RESET;
            vint_avg_r  <= VINT_AVG_RESET;
            step_up     <= '0;
            step_dn     <= '0;
            ce_d1       <= 1'b0;
            ce_d2       <= 1'b0;
            ce_d3       <= 1'b0;
        end else begin
            if (sample_ce) begin
                step_up     <= 40'(up_prod >>> 40);
                step_dn     <= 40'(dn_prod >>> 40);
                acc         <= vint;
                acc_latched <= acc;
            end else begin
                acc     <= acc + vint;
            end

            avg_prod_r <= acc_latched * RECIP832_Q32 + 64'sd2147483648;
            vint_avg_r <= 40'(avg_prod_r >>> 32);

            ce_d1 <= sample_ce;
            ce_d2 <= ce_d1;
            ce_d3 <= ce_d2;

            vint <= sq ? (vint + step_up) : (vint - step_dn);

            if (sq && (vint >= TH_HI))
                sq <= 1'b0;
            else if (!sq && (vint <= TH_LO))
                sq <= 1'b1;
        end
    end

    assign vint_avg    = vint_avg_r;
    assign vint_avg_ce = ce_d3;

endmodule
