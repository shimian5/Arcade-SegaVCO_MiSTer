// EXP channel (crack + rumble), sheet 2. See docs/audio-rtl-design.md,
// "Phase 3 -- EXP (sheet 2)" for the full derivation; this module must not
// contradict that file. Two independent VCA legs summed at the end:
//
//   /EXP -> IC8 sec.A 74123 (tw=99.4ms) -----------------------------+
//              Q (pin13) falling edge --------------------------+   |
//                                                                v   v
//                                                    IC8 sec.B 74123 (tw=465.3ms)
//
//   crack envelope (Q-bar of sec.A, discharge/recharge through C88) ->
//     control voltage (5+Vc)/2 -> MC3340 VCA gain LUT (direct, no invert)
//   rumble envelope (Q-bar of sec.B, discharge/recharge through C89) ->
//     control voltage (5+Vc)/2 -> MC3340 VCA gain LUT (direct, no invert)
//
//   noise_b -> 2-pole highpass f0=1205Hz (crack shape) -> atten 0.2481 ->
//              x crack VCA gain -> gain -2.136 --\
//   noise_b -> 2-pole lowpass  f0=272Hz  (rumble shape) -> atten 0.2481 ->
//              x rumble VCA gain -> gain -4.700 --+--> EXP MIX
// The crack filter's Q is baked into the precomputed coefficients below at
// 0.70711 (Butterworth). It was a module parameter until Quartus refused the
// $sin/$cos that turned it into coefficients; retuning it now means
// regenerating those constants, per the recipe at the coefficient block.
module exp_chan (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic                exp_n,          // /EXP, active low, falling edge triggers
    input  logic signed [15:0] noise_b,
    output logic signed [15:0] exp_mix,        // 4096 LSB = 1V

    // Dedicated shared-multiplier client. EXP's 26 sample-rate products are
    // scheduled serially between sample_ce pulses; it has one request in flight.
    output logic                mul_req_valid,
    input  logic                mul_req_ready,
    output logic signed [63:0]  mul_req_a,
    output logic signed [63:0]  mul_req_b,
    output logic          [6:0] mul_req_a_width,
    output logic          [6:0] mul_req_b_width,
    output logic          [7:0] mul_req_tag,
    input  logic                mul_rsp_valid,
    input  logic signed [127:0] mul_rsp_product,
    input  logic          [7:0] mul_rsp_tag
);

    // ---------------------------------------------------------------
    // Fixed-point conventions, identical to fire_chan.sv / alarm_chan.sv:
    //   envelope / filter state: signed [26:0] (27-bit), SCALE = 4096*256 =
    //   1,048,576 LSB/V (same units for both the envelope caps and the
    //   V2 control-voltage LUT index, so no conversion is needed between
    //   them -- see fire_chan.sv's v2_scaled for precedent).
    //   fs = clk_sys/832 = 39,935,064/832 = 47,998.875 Hz.
    //
    // WIDTH CHOICE -- see docs/audio-rtl-design.md "DSP block budget": every
    // coefficient/state operand that feeds a multiply here is 27 bits, not
    // 32. Cyclone V DSP blocks natively do 27x27; a 32-bit operand needs 2
    // DSP blocks (or gets decomposed into 18x18 sub-multiplies) AND defeats
    // packing the multiplier's output register into the DSP, forcing a
    // soft-logic adder tree afterward. Derived bounds: this file's own
    // RUMBLE_A1_Q24 (33,237,369) is the worst-case Q24 coefficient across
    // both HIT and EXP and needs 26 bits signed; filter states at this
    // design's voltage scale need ~24 bits signed (rails -6.00/+4.50 V *
    // 1,048,576 LSB/V < 2^23). Both fit in 27 bits with margin, which is
    // also the DSP's native operand width. VCA gain values (from
    // VCA_GAIN_LUT, max 292,739) get their own narrower signed [20:0].
    // ---------------------------------------------------------------
    // SCALE = 1,048,576 LSB/V; folded directly into the localparam
    // constants below (VLOW_SCALED, VHIGH_SCALED, V2_MIN/MAX_SCALED)
    // rather than kept as its own signal, same as fire_chan.sv.
    // (fs = 47,998.875 Hz. Not declared as a `real` localparam -- every
    // constant derived from it is precomputed, because Quartus rejects
    // real-valued elaboration arithmetic for synthesis.)

    // ---------------------------------------------------------------
    // Stage 1: IC8 sec.A/sec.B 74123 one-shots, cascaded: B's a_n is
    // wired directly to A's q, so B triggers on A's *falling* edge (the
    // end of the crack), per docs/audio-rtl-design.md point 2.
    //   tw_A = 0.45 * R16(47K) * C7(4.7uF)  = 99.4ms
    //     WIDTH_CYCLES_A = 0.0994 * 39,935,064 = 3,969,545.36 -> 3,969,545
    //   tw_B = 0.45 * R17(47K) * C8(22uF)   = 465.3ms
    //     WIDTH_CYCLES_B = 0.4653 * 39,935,064 = 18,581,785.28 -> 18,581,785
    // ---------------------------------------------------------------
    logic q_a, q_b;

    ttl_74123 #(.WIDTH_CYCLES(3969545)) u_74123_crack (
        .clk    (clk),
        .rst_n  (rst_n),
        .a_n    (exp_n),
        .q      (q_a)
    );

    ttl_74123 #(.WIDTH_CYCLES(18581785)) u_74123_rumble (
        .clk    (clk),
        .rst_n  (rst_n),
        .a_n    (q_a),      // falling edge of A's Q triggers B
        .q      (q_b)
    );

    // ---------------------------------------------------------------
    // Stage 2: envelopes. Per docs point 3, both are taken from Q-bar
    // with the diode pointed opposite to FIRE's D8: idle the cap sits
    // charged toward 5V (Q-bar idles high, diode blocks); the pulse
    // pulls Q-bar low, the diode conducts and the cap *discharges*
    // toward ~0.8V; then it recovers toward 5V once the pulse ends.
    // Modelled the same way as fire_chan's envelope: a one-pole toward
    // one of two targets, gated by the one-shot's Q (active while
    // gated = discharging).
    //
    // Reset value: the idle steady-state is the cap fully charged
    // (5.0V, i.e. maximally attenuated / silent), matching the "reset
    // to idle, not to a false transient" fix already made in
    // alarm_chan.sv -- reset must NOT be 0V.
    //
    // crack (C88 1uF): discharge R11 10K, tau=10ms; recharge R10+R9
    //   940K, tau=0.94s
    // rumble (C89 2.2uF): discharge R151 470, tau=1.03ms; recharge
    //   R150+R149 2M, tau=4.4s
    //
    // Fast (discharge) poles are nowhere near unity -> Q0.16 is fine.
    // Slow (recharge) poles are the identical trap flagged in
    // fire_chan.sv / the ALARM high-pass: 0.94s and 4.4s are far too
    // close to 1 for Q0.16 to resolve, so both use Q0.24.
    //
    //   a_discharge_crack  = exp(-1/(fs*0.01))    = 0.99791879 -> Q0.16 = 65400
    //   a_discharge_rumble = exp(-1/(fs*0.00103)) = 0.97997630 -> Q0.16 = 64224
    //
    //   a_recharge_crack  = exp(-1/(fs*0.94)) = 0.999977824
    //     nearest Q0.24 code: 16777216-372 = 16776844
    //     realised tau = 1 / (fs * -ln(16776844/16777216)) = 0.939624s (-0.040%)
    //   a_recharge_rumble = exp(-1/(fs*4.4)) = 0.9999952913
    //     nearest Q0.24 code: 16777216-79 = 16777137
    //     realised tau = 1 / (fs * -ln(16777137/16777216)) = 4.42480s (+0.564%)
    //   (both within the 1% tolerance the spec asks for; the adjacent
    //   codes, -371/-80, land at +0.229%/-0.696%, i.e. worse, confirming
    //   these are the nearest representable codes.)
    // ---------------------------------------------------------------
    localparam signed [26:0] VLOW_SCALED  = 27'sd838861;   // 0.8V * SCALE
    localparam signed [26:0] VHIGH_SCALED = 27'sd5242880;  // 5.0V * SCALE

    localparam signed [26:0] A_CRACK_DISCHARGE_Q16  = 27'sd65400;
    localparam signed [26:0] B_CRACK_DISCHARGE_Q16  = 27'sd136;   // 65536 - A
    localparam signed [26:0] A_RUMBLE_DISCHARGE_Q16 = 27'sd64224;
    localparam signed [26:0] B_RUMBLE_DISCHARGE_Q16 = 27'sd1312;  // 65536 - A

    localparam signed [26:0] A_CRACK_RECHARGE_Q24  = 27'sd16776844;
    localparam signed [26:0] B_CRACK_RECHARGE_Q24  = 27'sd372;      // 16777216 - A
    localparam signed [26:0] A_RUMBLE_RECHARGE_Q24 = 27'sd16777137;
    localparam signed [26:0] B_RUMBLE_RECHARGE_Q24 = 27'sd79;       // 16777216 - A

    logic signed [26:0] env_crack;
    logic signed [26:0] env_rumble;

    // Control voltage = (5.0 + Vcap) / 2, fed directly (no inversion) into
    // the VCA LUT below.
    wire signed [26:0] v2_crack_scaled  = (VHIGH_SCALED + env_crack)  >>> 1;
    wire signed [26:0] v2_rumble_scaled = (VHIGH_SCALED + env_rumble) >>> 1;

    // ---------------------------------------------------------------
    // Stage 3: MC3340 VCA gain LUT -- identical table, indexing and
    // interpolation as fire_chan.sv's VCA_GAIN_LUT (65 points, V2 =
    // 2.0..6.0V step 0.0625V, Q0.16-by-fractional-bit-count values
    // held in 32-bit words). Reused verbatim per the design doc
    // ("Reuse the exact same LUT approach and constants as fire_chan").
    // ---------------------------------------------------------------
    localparam int LUT_SIZE = 65;
    localparam logic [31:0] VCA_GAIN_LUT [0:LUT_SIZE-1] = '{
        32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739,
        32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739,
        32'd292739, 32'd292739, 32'd253501, 32'd176901, 32'd123447, 32'd86145,  32'd60115,  32'd41950,
        32'd29274,  32'd21952,  32'd16462,  32'd12345,  32'd9257,   32'd6942,   32'd5206,   32'd3904,
        32'd2927,   32'd2195,   32'd1646,   32'd1234,   32'd926,    32'd694,    32'd521,    32'd390,
        32'd293,    32'd220,    32'd165,    32'd123,    32'd93,     32'd69,     32'd52,     32'd39,
        32'd29,     32'd25,     32'd22,     32'd19,     32'd16,     32'd14,     32'd12,     32'd11,
        32'd9,      32'd9,      32'd9,      32'd9,      32'd9,      32'd9,      32'd9,      32'd9,
        32'd9
    };

    localparam signed [26:0] V2_MIN_SCALED = 27'sd2097152;      // 2.0V * SCALE
    localparam signed [26:0] V2_MAX_SCALED = 27'sd6291455;      // 6.0V * SCALE - 1

    // Gain values top out at 292,739 (19 bits unsigned) -- signed [20:0]
    // holds them with margin; this multiply was already small enough not
    // to be a DSP-budget driver, but the return path is narrowed too so it
    // doesn't force a wide operand on whatever multiplies it downstream.
    // Return {gain_lo, gain_hi-gain_lo, frac}.  The interpolation multiply is
    // deliberately scheduled through the shared lane below rather than hidden
    // inside this lookup function.
    function automatic logic [58:0] vca_lut_params(input logic signed [26:0] v2_in);
        logic signed [26:0] v2_clamped;
        logic        [26:0] v2_off;
        logic        [6:0]  lut_idx;
        logic        [15:0] lut_frac;
        logic        [31:0] gain_lo, gain_hi;
        logic signed [20:0] gain_base, gain_delta;
        begin
            v2_clamped = (v2_in < V2_MIN_SCALED) ? V2_MIN_SCALED :
                         (v2_in > V2_MAX_SCALED) ? V2_MAX_SCALED :
                         v2_in;
            v2_off   = v2_clamped - V2_MIN_SCALED;
            lut_idx  = v2_off[22:16];
            lut_frac = v2_off[15:0];
            gain_lo  = VCA_GAIN_LUT[lut_idx];
            gain_hi  = VCA_GAIN_LUT[lut_idx + 7'd1];
            gain_base  = 21'($signed({1'b0, gain_lo}));
            gain_delta = 21'($signed({1'b0, gain_hi}) - $signed({1'b0, gain_lo}));
            vca_lut_params = {gain_base, gain_delta, 1'b0, lut_frac};
        end
    endfunction

    // ---------------------------------------------------------------
    // Stage 4: shaping filters on noise_b, standard RBJ 2-pole biquads
    // (direct form I, s32 state, filter SCALE units), coefficients
    // computed at elaboration time from f0/Q/fs and stored as Q0.24
    // (16,777,216 LSB) -- the same precision upgrade fire_chan needed
    // for its slow pole applies here since a2 for the 272Hz lowpass is
    // also not far below unity. Computed real coefficients are
    // converted to Q0.24 integers below; the resulting constants are
    // listed alongside for the record.
    //
    // Crack: 2-pole highpass, f0=1205Hz, Q=CRACK_Q_Q16 (default 0.70711,
    // Butterworth -- spec flags Q as uncertain, kept parameterised).
    //   w0 = 2*pi*1205/47998.875 = 0.1577378 rad
    //   cos(w0) = 0.987586, sin(w0) = 0.157085
    //   alpha = sin(w0)/(2*Q)
    //   (default Q=0.70711 -> alpha = 0.111102)
    //   a0 = 1+alpha, b0=b2=(1+cos)/(2*a0), b1=-(1+cos)/a0
    //   a1 = -2*cos/a0, a2 = (1-alpha)/a0
    //   (default numeric values: b0=b2=0.894415, b1=-1.788830,
    //    a1=-1.777653, a2=0.800002)
    //
    // Rumble: 2-pole lowpass, f0=272Hz, Q=2.0 (fixed, unambiguous per
    // spec), passband gain 2.5.
    //   w0 = 2*pi*272/47998.875 = 0.0356047 rad
    //   cos(w0) = 0.999366, sin(w0) = 0.035597
    //   alpha = sin(w0)/(2*2.0) = 0.008899
    //   a0 = 1+alpha, b0=b2 = 2.5*(1-cos)/(2*a0), b1 = 2.5*(1-cos)/a0
    //   a1 = -2*cos/a0, a2 = (1-alpha)/a0
    //   (numeric values: b0=b2=0.000785, b1=0.001570,
    //    a1=-1.981145, a2=0.982365)
    // ---------------------------------------------------------------
    // Coefficients are PRECOMPUTED, not derived here. Quartus rejects $sin
    // and $cos outright ("system function is not supported for synthesis",
    // error 10174), and `real` localparams are not portable across synthesis
    // tools either, so the whole elaboration-time derivation had to go.
    //
    // Regenerate with, at fs = 47998.875:
    //   w0 = 2*pi*f0/fs;  alpha = sin(w0)/(2*Q);  a0 = 1 + alpha
    //   HP: b0 = b2 = (1+cos)/2/a0,  b1 = -(1+cos)/a0
    //   LP: b0 = b2 = G*(1-cos)/2/a0, b1 = G*(1-cos)/a0
    //   both: a1 = -2*cos/a0,  a2 = (1-alpha)/a0
    //   then multiply by 2^24 and round.
    //
    // NOTE: CRACK_Q_Q16 is consequently NO LONGER WIRED to anything -- the
    // crack coefficients below are baked at Q = 0.70710678. The spec flags
    // the crack filter's true Q as uncertain, so if it needs changing, the
    // constants must be regenerated by the formula above rather than by
    // editing the parameter. The parameter is retained only to document the
    // Q the constants were built at.
    localparam signed [26:0] CRACK_B0_Q24 =  27'sd15006246; // +0.894441964
    localparam signed [26:0] CRACK_B1_Q24 = -27'sd30012492; // -1.788883929
    localparam signed [26:0] CRACK_B2_Q24 =  27'sd15006246; // +0.894441964
    localparam signed [26:0] CRACK_A1_Q24 = -27'sd29825028; // -1.777710217
    localparam signed [26:0] CRACK_A2_Q24 =  27'sd13422740; // +0.800057641

    localparam signed [26:0] RUMBLE_B0_Q24 =  27'sd13175;      // +0.000785275
    localparam signed [26:0] RUMBLE_B1_Q24 =  27'sd26349;      // +0.001570550
    localparam signed [26:0] RUMBLE_B2_Q24 =  27'sd13175;      // +0.000785275
    localparam signed [26:0] RUMBLE_A1_Q24 = -27'sd33237369;   // -1.981101551
    localparam signed [26:0] RUMBLE_A2_Q24 =  27'sd16481232;   // +0.982357991

    // noise_b, scaled from the audio SCALE (4096 LSB/V) to the filter
    // SCALE (4096*256 LSB/V), same convention as fire_chan's noise_scaled.
    // Sign-extend and shift in a full-width wire FIRST (per fire_chan.sv's
    // header note: a bare multiply/shift isn't context-widened by a narrow
    // assignment target), then cast down to 27 bits -- the shifted value
    // only ever needs ~24 bits, so the cast is a safe truncation, not a
    // silent overflow.
    wire signed [31:0] noise_ext    = {{16{noise_b[15]}}, noise_b};
    wire signed [26:0] noise_scaled = 27'(noise_ext <<< 8);

    logic signed [26:0] crack_x1, crack_x2, crack_y1, crack_y2;
    logic signed [26:0] rumble_x1, rumble_x2, rumble_y1, rumble_y2;

    // ---------------------------------------------------------------
    // Input attenuator 0.2481 on both VCA inputs, x VCA gain, output gains
    // -2.136 (crack) / -4.700 (rumble), sum, saturate.
    // ---------------------------------------------------------------
    localparam signed [26:0] ATTEN_Q16          = 27'sd16261;   // 0.2481 * 65536
    localparam signed [26:0] OUT_GAIN_CRACK_Q16  = -27'sd140004; // -2.136 * 65536
    localparam signed [26:0] OUT_GAIN_RUMBLE_Q16 = -27'sd308019; // -4.700 * 65536

    // IC25 OUTPUT RAILS -- a real clipping mechanism, not a format guard.
    //
    // IC25 is an LM324 on the board's 12 V single supply with its + input at
    // the 6 V mid-rail, so its output cannot leave 0 .. ~10.5 V. Referred to
    // the 6 V rail that is roughly -6.0 V / +4.5 V, and it is ASYMMETRIC:
    // the LM324 sinks nearly to ground but stops about 1.5 V short of Vcc.
    //
    // This matters. A full-gain explosion through the -4.700 rumble weight
    // drives well past +4.5 V, so the real board clips here too -- that
    // clipping is part of what an explosion on this hardware sounds like.
    // Saturating at the format limit of +/-8.000 V instead (which no LM324 on
    // a 12 V rail can reach) both misses the distortion and lets the channel
    // run ~5 dB hotter than the circuit permits.
    //
    // Both figures are datasheet-backed (docs/reference/LM324.pdf p11,
    // docs/reference/MB3614.pdf p2):
    //   LM324  V_OH = VCC - 1.5 V at RL = 2K, 25 C -> 10.5 V -> +4.50 V
    //   LM324  V_OL = 5 mV typ / 20 mV max         ->  0.0 V -> -6.00 V
    //   MB3614 V_OH typ = 28 V at VCC = 30 V, i.e. VCC - 2.0 V -> +4.00 V
    // The V_OH spec is quoted at RL = 2K while the loads here are 100K-470K,
    // an order of magnitude lighter, so +4.50 V is conservative.
    //
    // Residual uncertainty is 0.5 V on the POSITIVE rail only: the IC roster
    // in docs/hardware-audio.md lists IC17/IC20-IC22/IC25/IC26/IC29 as
    // "LM324 / MB3614" without saying which socket holds which, and the two
    // parts differ by exactly that. Taking the LM324 figure.
    localparam signed [31:0] RAIL_HI = 32'sd18432;   // +4.50 V * 4096
    localparam signed [31:0] RAIL_LO = -32'sd24576;  // -6.00 V * 4096

    // The previous free-running pipeline instantiated 24 DSP multiplies.  This
    // sequencer evaluates the equivalent snapshot over 26 requests: ten
    // biquad terms, two attenuators, two LUT interpolations, two VCA gains,
    // two output gains, and both envelope branches. Work starts after upstream
    // noise has settled and commits at the following sample_ce.
    localparam logic [7:0] TAG_EXP_BASE = 8'hE0;
    logic [4:0] op_index;
    logic waiting_response, next_valid;
    logic [6:0] settle_count;
    logic signed [53:0] crack_b0_w, crack_b1_w, crack_b2_w, crack_a1_w;
    logic signed [53:0] rumble_b0_w, rumble_b1_w, rumble_b2_w, rumble_a1_w;
    logic signed [26:0] crack_y_work, rumble_y_work;
    logic signed [26:0] crack_atten_work, rumble_atten_work;
    logic signed [20:0] gain_base_crack, gain_delta_crack, gain_base_rumble, gain_delta_rumble;
    logic signed [16:0] gain_frac_crack, gain_frac_rumble;
    logic signed [20:0] gain_crack_work, gain_rumble_work;
    logic signed [26:0] crack_vca_work, rumble_vca_work, crack_out_work;
    logic signed [53:0] env_crack_dis_a, env_crack_rec_a, env_rumble_dis_a, env_rumble_rec_a;
    logic signed [26:0] env_crack_dis_work, env_crack_rec_work;
    logic signed [26:0] env_rumble_dis_work, env_rumble_rec_work;
    logic signed [15:0] exp_sample;

    wire [58:0] vca_params_crack  = vca_lut_params(v2_crack_scaled);
    wire [58:0] vca_params_rumble = vca_lut_params(v2_rumble_scaled);
    wire signed [53:0] rsp_q54 = 54'(mul_rsp_product);
    wire signed [26:0] rsp_q16 = 27'(mul_rsp_product >>> 16);
    wire signed [20:0] rsp_gain_q16 = 21'(mul_rsp_product >>> 16);
    wire signed [26:0] rsp_mix_full = (crack_out_work + rsp_q16) >>> 8;
    wire signed [15:0] rsp_mix_sat =
        (rsp_mix_full > RAIL_HI) ? RAIL_HI[15:0] :
        (rsp_mix_full < RAIL_LO) ? RAIL_LO[15:0] : rsp_mix_full[15:0];

    task automatic issue_multiply(
        input logic signed [63:0] a, input logic signed [63:0] b,
        input logic [6:0] aw, input logic [6:0] bw, input logic [7:0] tag
    );
        begin
            mul_req_a <= a; mul_req_b <= b;
            mul_req_a_width <= aw; mul_req_b_width <= bw;
            mul_req_tag <= tag; mul_req_valid <= 1'b1;
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            env_crack <= VHIGH_SCALED; env_rumble <= VHIGH_SCALED;
            crack_x1 <= '0; crack_x2 <= '0; crack_y1 <= '0; crack_y2 <= '0;
            rumble_x1 <= '0; rumble_x2 <= '0; rumble_y1 <= '0; rumble_y2 <= '0;
            op_index <= '0; waiting_response <= 1'b0; next_valid <= 1'b0;
            settle_count <= '0; exp_mix <= '0; exp_sample <= '0;
            crack_b0_w <= '0; crack_b1_w <= '0; crack_b2_w <= '0; crack_a1_w <= '0;
            rumble_b0_w <= '0; rumble_b1_w <= '0; rumble_b2_w <= '0; rumble_a1_w <= '0;
            crack_y_work <= '0; rumble_y_work <= '0;
            crack_atten_work <= '0; rumble_atten_work <= '0;
            gain_base_crack <= '0; gain_delta_crack <= '0; gain_frac_crack <= '0;
            gain_base_rumble <= '0; gain_delta_rumble <= '0; gain_frac_rumble <= '0;
            gain_crack_work <= '0; gain_rumble_work <= '0;
            crack_vca_work <= '0; rumble_vca_work <= '0; crack_out_work <= '0;
            env_crack_dis_a <= '0; env_crack_rec_a <= '0;
            env_rumble_dis_a <= '0; env_rumble_rec_a <= '0;
            env_crack_dis_work <= '0; env_crack_rec_work <= '0;
            env_rumble_dis_work <= '0; env_rumble_rec_work <= '0;
            mul_req_valid <= 1'b0; mul_req_a <= '0; mul_req_b <= '0;
            mul_req_a_width <= 7'd1; mul_req_b_width <= 7'd1; mul_req_tag <= '0;
        end else begin
            exp_mix <= exp_sample;
            if (mul_req_valid && mul_req_ready) begin
                mul_req_valid <= 1'b0;
                waiting_response <= 1'b1;
            end
            if (sample_ce) begin
                settle_count <= 7'd64;
                if (next_valid) begin
                    env_crack <= q_a ? env_crack_dis_work : env_crack_rec_work;
                    env_rumble <= q_b ? env_rumble_dis_work : env_rumble_rec_work;
                    crack_x1 <= noise_scaled; crack_x2 <= crack_x1;
                    crack_y1 <= crack_y_work; crack_y2 <= crack_y1;
                    rumble_x1 <= noise_scaled; rumble_x2 <= rumble_x1;
                    rumble_y1 <= rumble_y_work; rumble_y2 <= rumble_y1;
                    next_valid <= 1'b0;
                end
            end else if (settle_count != 0) begin
                settle_count <= settle_count - 1'b1;
            end
            if (!mul_req_valid && !waiting_response && settle_count == 7'd1) begin
                op_index <= 5'd0;
                gain_base_crack <= vca_params_crack[58:38];
                gain_delta_crack <= vca_params_crack[37:17];
                gain_frac_crack <= vca_params_crack[16:0];
                gain_base_rumble <= vca_params_rumble[58:38];
                gain_delta_rumble <= vca_params_rumble[37:17];
                gain_frac_rumble <= vca_params_rumble[16:0];
                issue_multiply(64'(CRACK_B0_Q24), 64'(noise_scaled), 7'd27, 7'd27, TAG_EXP_BASE);
            end
            if (mul_rsp_valid && waiting_response) begin
                waiting_response <= 1'b0;
                case (op_index)
                    5'd0: begin crack_b0_w <= rsp_q54; op_index <= 5'd1; issue_multiply(64'(CRACK_B1_Q24),64'(crack_x1),7'd27,7'd27,TAG_EXP_BASE+8'd1); end
                    5'd1: begin crack_b1_w <= rsp_q54; op_index <= 5'd2; issue_multiply(64'(CRACK_B2_Q24),64'(crack_x2),7'd27,7'd27,TAG_EXP_BASE+8'd2); end
                    5'd2: begin crack_b2_w <= rsp_q54; op_index <= 5'd3; issue_multiply(64'(CRACK_A1_Q24),64'(crack_y1),7'd27,7'd27,TAG_EXP_BASE+8'd3); end
                    5'd3: begin crack_a1_w <= rsp_q54; op_index <= 5'd4; issue_multiply(64'(CRACK_A2_Q24),64'(crack_y2),7'd27,7'd27,TAG_EXP_BASE+8'd4); end
                    5'd4: begin crack_y_work <= 27'((crack_b0_w+crack_b1_w+crack_b2_w-crack_a1_w-rsp_q54)>>>24); op_index <= 5'd5; issue_multiply(64'(RUMBLE_B0_Q24),64'(noise_scaled),7'd27,7'd27,TAG_EXP_BASE+8'd5); end
                    5'd5: begin rumble_b0_w <= rsp_q54; op_index <= 5'd6; issue_multiply(64'(RUMBLE_B1_Q24),64'(rumble_x1),7'd27,7'd27,TAG_EXP_BASE+8'd6); end
                    5'd6: begin rumble_b1_w <= rsp_q54; op_index <= 5'd7; issue_multiply(64'(RUMBLE_B2_Q24),64'(rumble_x2),7'd27,7'd27,TAG_EXP_BASE+8'd7); end
                    5'd7: begin rumble_b2_w <= rsp_q54; op_index <= 5'd8; issue_multiply(64'(RUMBLE_A1_Q24),64'(rumble_y1),7'd27,7'd27,TAG_EXP_BASE+8'd8); end
                    5'd8: begin rumble_a1_w <= rsp_q54; op_index <= 5'd9; issue_multiply(64'(RUMBLE_A2_Q24),64'(rumble_y2),7'd27,7'd27,TAG_EXP_BASE+8'd9); end
                    5'd9: begin rumble_y_work <= 27'((rumble_b0_w+rumble_b1_w+rumble_b2_w-rumble_a1_w-rsp_q54)>>>24); op_index <= 5'd10; issue_multiply(64'(ATTEN_Q16),64'(crack_y_work),7'd27,7'd27,TAG_EXP_BASE+8'd10); end
                    5'd10: begin crack_atten_work <= rsp_q16; op_index <= 5'd11; issue_multiply(64'(ATTEN_Q16),64'(rumble_y_work),7'd27,7'd27,TAG_EXP_BASE+8'd11); end
                    5'd11: begin rumble_atten_work <= rsp_q16; op_index <= 5'd12; issue_multiply(64'(gain_delta_crack),64'(gain_frac_crack),7'd21,7'd17,TAG_EXP_BASE+8'd12); end
                    5'd12: begin gain_crack_work <= gain_base_crack + rsp_gain_q16; op_index <= 5'd13; issue_multiply(64'(gain_delta_rumble),64'(gain_frac_rumble),7'd21,7'd17,TAG_EXP_BASE+8'd13); end
                    5'd13: begin gain_rumble_work <= gain_base_rumble + rsp_gain_q16; op_index <= 5'd14; issue_multiply(64'(crack_atten_work),64'(gain_crack_work),7'd27,7'd21,TAG_EXP_BASE+8'd14); end
                    5'd14: begin crack_vca_work <= rsp_q16; op_index <= 5'd15; issue_multiply(64'(rumble_atten_work),64'(gain_rumble_work),7'd27,7'd21,TAG_EXP_BASE+8'd15); end
                    5'd15: begin rumble_vca_work <= rsp_q16; op_index <= 5'd16; issue_multiply(64'(OUT_GAIN_CRACK_Q16),64'(crack_vca_work),7'd27,7'd27,TAG_EXP_BASE+8'd16); end
                    5'd16: begin crack_out_work <= rsp_q16; op_index <= 5'd17; issue_multiply(64'(OUT_GAIN_RUMBLE_Q16),64'(rumble_vca_work),7'd27,7'd27,TAG_EXP_BASE+8'd17); end
                    5'd17: begin exp_sample <= rsp_mix_sat; op_index <= 5'd18; issue_multiply(64'(A_CRACK_DISCHARGE_Q16),64'(env_crack),7'd27,7'd27,TAG_EXP_BASE+8'd18); end
                    5'd18: begin env_crack_dis_a <= rsp_q54; op_index <= 5'd19; issue_multiply(64'(B_CRACK_DISCHARGE_Q16),64'(VLOW_SCALED),7'd27,7'd27,TAG_EXP_BASE+8'd19); end
                    5'd19: begin env_crack_dis_work <= 27'((env_crack_dis_a+rsp_q54)>>>16); op_index <= 5'd20; issue_multiply(64'(A_CRACK_RECHARGE_Q24),64'(env_crack),7'd27,7'd27,TAG_EXP_BASE+8'd20); end
                    5'd20: begin env_crack_rec_a <= rsp_q54; op_index <= 5'd21; issue_multiply(64'(B_CRACK_RECHARGE_Q24),64'(VHIGH_SCALED),7'd27,7'd27,TAG_EXP_BASE+8'd21); end
                    5'd21: begin env_crack_rec_work <= 27'((env_crack_rec_a+rsp_q54)>>>24); op_index <= 5'd22; issue_multiply(64'(A_RUMBLE_DISCHARGE_Q16),64'(env_rumble),7'd27,7'd27,TAG_EXP_BASE+8'd22); end
                    5'd22: begin env_rumble_dis_a <= rsp_q54; op_index <= 5'd23; issue_multiply(64'(B_RUMBLE_DISCHARGE_Q16),64'(VLOW_SCALED),7'd27,7'd27,TAG_EXP_BASE+8'd23); end
                    5'd23: begin env_rumble_dis_work <= 27'((env_rumble_dis_a+rsp_q54)>>>16); op_index <= 5'd24; issue_multiply(64'(A_RUMBLE_RECHARGE_Q24),64'(env_rumble),7'd27,7'd27,TAG_EXP_BASE+8'd24); end
                    5'd24: begin env_rumble_rec_a <= rsp_q54; op_index <= 5'd25; issue_multiply(64'(B_RUMBLE_RECHARGE_Q24),64'(VHIGH_SCALED),7'd27,7'd27,TAG_EXP_BASE+8'd25); end
                    default: begin env_rumble_rec_work <= 27'((env_rumble_rec_a+rsp_q54)>>>24); next_valid <= 1'b1; end
                endcase
            end
        end
    end

`ifdef VERILATOR_SIM
    always_ff @(posedge clk) begin
        if (rst_n && mul_rsp_valid && waiting_response &&
            (mul_rsp_tag != (TAG_EXP_BASE + op_index)))
            $error("EXP shared-multiply tag mismatch");
        if (rst_n && sample_ce && (mul_req_valid || waiting_response))
            $error("EXP shared multiply missed sample deadline");
    end
`endif

endmodule
