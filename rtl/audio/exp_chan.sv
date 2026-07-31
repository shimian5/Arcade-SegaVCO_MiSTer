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
module exp_chan #(
    parameter int CRACK_Q_Q16 = 46341   // Q0.16; default 0.70711 (Butterworth).
                                         // Spec flags this Q as uncertain -- kept
                                         // a real parameter, not baked into the
                                         // coefficients, so it can be retuned.
)(
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic                exp_n,          // /EXP, active low, falling edge triggers
    input  logic signed [15:0] noise_b,
    output logic signed [15:0] exp_mix         // 4096 LSB = 1V
);

    // ---------------------------------------------------------------
    // Fixed-point conventions, identical to fire_chan.sv / alarm_chan.sv:
    //   envelope / filter state: signed [31:0], SCALE = 4096*256 =
    //   1,048,576 LSB/V (same units for both the envelope caps and the
    //   V2 control-voltage LUT index, so no conversion is needed between
    //   them -- see fire_chan.sv's v2_scaled for precedent).
    //   fs = clk_sys/832 = 39,935,064/832 = 47,998.875 Hz.
    // ---------------------------------------------------------------
    // SCALE = 1,048,576 LSB/V; folded directly into the localparam
    // constants below (VLOW_SCALED, VHIGH_SCALED, V2_MIN/MAX_SCALED)
    // rather than kept as its own signal, same as fire_chan.sv.
    localparam real FS = 47998.875;
    localparam real PI = 3.14159265358979323846;

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
    localparam signed [31:0] VLOW_SCALED  = 32'sd838861;   // 0.8V * SCALE
    localparam signed [31:0] VHIGH_SCALED = 32'sd5242880;  // 5.0V * SCALE

    localparam signed [31:0] A_CRACK_DISCHARGE_Q16  = 32'sd65400;
    localparam signed [31:0] B_CRACK_DISCHARGE_Q16  = 32'sd136;   // 65536 - A
    localparam signed [31:0] A_RUMBLE_DISCHARGE_Q16 = 32'sd64224;
    localparam signed [31:0] B_RUMBLE_DISCHARGE_Q16 = 32'sd1312;  // 65536 - A

    localparam signed [63:0] A_CRACK_RECHARGE_Q24  = 64'sd16776844;
    localparam signed [63:0] B_CRACK_RECHARGE_Q24  = 64'sd372;      // 16777216 - A
    localparam signed [63:0] A_RUMBLE_RECHARGE_Q24 = 64'sd16777137;
    localparam signed [63:0] B_RUMBLE_RECHARGE_Q24 = 64'sd79;       // 16777216 - A

    logic signed [31:0] env_crack, env_crack_next;
    logic signed [31:0] env_rumble, env_rumble_next;

    wire signed [63:0] crack_dis_sum = 64'(A_CRACK_DISCHARGE_Q16) * 64'(env_crack)
                                      + 64'(B_CRACK_DISCHARGE_Q16) * 64'(VLOW_SCALED);
    wire signed [63:0] crack_rec_sum = A_CRACK_RECHARGE_Q24 * 64'(env_crack)
                                      + B_CRACK_RECHARGE_Q24 * 64'(VHIGH_SCALED);
    assign env_crack_next = q_a ? crack_dis_sum[47:16] : crack_rec_sum[55:24];

    wire signed [63:0] rumble_dis_sum = 64'(A_RUMBLE_DISCHARGE_Q16) * 64'(env_rumble)
                                       + 64'(B_RUMBLE_DISCHARGE_Q16) * 64'(VLOW_SCALED);
    wire signed [63:0] rumble_rec_sum = A_RUMBLE_RECHARGE_Q24 * 64'(env_rumble)
                                       + B_RUMBLE_RECHARGE_Q24 * 64'(VHIGH_SCALED);
    assign env_rumble_next = q_b ? rumble_dis_sum[47:16] : rumble_rec_sum[55:24];

    // Control voltage = (5.0 + Vcap) / 2, fed directly (no inversion) into
    // the VCA LUT below.
    wire signed [31:0] v2_crack_scaled  = (VHIGH_SCALED + env_crack)  >>> 1;
    wire signed [31:0] v2_rumble_scaled = (VHIGH_SCALED + env_rumble) >>> 1;

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

    localparam signed [31:0] V2_MIN_SCALED = 32'sd2097152;      // 2.0V * SCALE
    localparam signed [31:0] V2_MAX_SCALED = 32'sd6291455;      // 6.0V * SCALE - 1

    function automatic logic signed [31:0] vca_lut_lookup(input logic signed [31:0] v2_in);
        logic signed [31:0] v2_clamped;
        logic        [31:0] v2_off;
        logic        [6:0]  lut_idx;
        logic        [15:0] lut_frac;
        logic        [31:0] gain_lo, gain_hi;
        logic signed [63:0] gain_interp_prod;
        begin
            v2_clamped = (v2_in < V2_MIN_SCALED) ? V2_MIN_SCALED :
                         (v2_in > V2_MAX_SCALED) ? V2_MAX_SCALED :
                         v2_in;
            v2_off   = v2_clamped - V2_MIN_SCALED;
            lut_idx  = v2_off[22:16];
            lut_frac = v2_off[15:0];
            gain_lo  = VCA_GAIN_LUT[lut_idx];
            gain_hi  = VCA_GAIN_LUT[lut_idx + 7'd1];
            gain_interp_prod = 64'($signed({1'b0, gain_hi}) - $signed({1'b0, gain_lo})) * 64'($signed({16'd0, lut_frac}));
            vca_lut_lookup = 32'($signed({1'b0, gain_lo}) + gain_interp_prod[47:16]);
        end
    endfunction

    wire signed [31:0] vca_gain_crack  = vca_lut_lookup(v2_crack_scaled);
    wire signed [31:0] vca_gain_rumble = vca_lut_lookup(v2_rumble_scaled);

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
    localparam real CRACK_F0 = 1205.0;
    localparam real CRACK_W0 = 2.0 * PI * CRACK_F0 / FS;
    localparam real CRACK_COSW0 = $cos(CRACK_W0);
    localparam real CRACK_SINW0 = $sin(CRACK_W0);
    localparam real CRACK_Q     = real'(CRACK_Q_Q16) / 65536.0;
    localparam real CRACK_ALPHA = CRACK_SINW0 / (2.0 * CRACK_Q);
    localparam real CRACK_A0R   = 1.0 + CRACK_ALPHA;
    localparam real CRACK_B0R   = (1.0 + CRACK_COSW0) / 2.0 / CRACK_A0R;
    localparam real CRACK_B1R   = -(1.0 + CRACK_COSW0) / CRACK_A0R;
    localparam real CRACK_A1R   = (-2.0 * CRACK_COSW0) / CRACK_A0R;
    localparam real CRACK_A2R   = (1.0 - CRACK_ALPHA) / CRACK_A0R;

    localparam real RUMBLE_F0   = 272.0;
    localparam real RUMBLE_Q    = 2.0;
    localparam real RUMBLE_GAIN = 2.5;
    localparam real RUMBLE_W0   = 2.0 * PI * RUMBLE_F0 / FS;
    localparam real RUMBLE_COSW0 = $cos(RUMBLE_W0);
    localparam real RUMBLE_SINW0 = $sin(RUMBLE_W0);
    localparam real RUMBLE_ALPHA = RUMBLE_SINW0 / (2.0 * RUMBLE_Q);
    localparam real RUMBLE_A0R   = 1.0 + RUMBLE_ALPHA;
    localparam real RUMBLE_B0R   = RUMBLE_GAIN * (1.0 - RUMBLE_COSW0) / 2.0 / RUMBLE_A0R;
    localparam real RUMBLE_B1R   = RUMBLE_GAIN * (1.0 - RUMBLE_COSW0) / RUMBLE_A0R;
    localparam real RUMBLE_A1R   = (-2.0 * RUMBLE_COSW0) / RUMBLE_A0R;
    localparam real RUMBLE_A2R   = (1.0 - RUMBLE_ALPHA) / RUMBLE_A0R;

    function automatic logic signed [31:0] to_q24(input real x);
        to_q24 = 32'($rtoi(x * 16777216.0 + (x >= 0.0 ? 0.5 : -0.5)));
    endfunction

    localparam signed [31:0] CRACK_B0_Q24 = to_q24(CRACK_B0R);
    localparam signed [31:0] CRACK_B1_Q24 = to_q24(CRACK_B1R);
    localparam signed [31:0] CRACK_B2_Q24 = CRACK_B0_Q24;
    localparam signed [31:0] CRACK_A1_Q24 = to_q24(CRACK_A1R);
    localparam signed [31:0] CRACK_A2_Q24 = to_q24(CRACK_A2R);

    localparam signed [31:0] RUMBLE_B0_Q24 = to_q24(RUMBLE_B0R);
    localparam signed [31:0] RUMBLE_B1_Q24 = to_q24(RUMBLE_B1R);
    localparam signed [31:0] RUMBLE_B2_Q24 = RUMBLE_B0_Q24;
    localparam signed [31:0] RUMBLE_A1_Q24 = to_q24(RUMBLE_A1R);
    localparam signed [31:0] RUMBLE_A2_Q24 = to_q24(RUMBLE_A2R);

    // noise_b, scaled from the audio SCALE (4096 LSB/V) to the filter
    // SCALE (4096*256 LSB/V), same convention as fire_chan's noise_scaled.
    wire signed [31:0] noise_scaled = {{16{noise_b[15]}}, noise_b} <<< 8;

    logic signed [31:0] crack_x1, crack_x2, crack_y1, crack_y2;
    logic signed [31:0] rumble_x1, rumble_x2, rumble_y1, rumble_y2;

    wire signed [63:0] crack_acc =
          64'(CRACK_B0_Q24) * 64'(noise_scaled)
        + 64'(CRACK_B1_Q24) * 64'(crack_x1)
        + 64'(CRACK_B2_Q24) * 64'(crack_x2)
        - 64'(CRACK_A1_Q24) * 64'(crack_y1)
        - 64'(CRACK_A2_Q24) * 64'(crack_y2);
    wire signed [31:0] crack_y_next = crack_acc[55:24];

    wire signed [63:0] rumble_acc =
          64'(RUMBLE_B0_Q24) * 64'(noise_scaled)
        + 64'(RUMBLE_B1_Q24) * 64'(rumble_x1)
        + 64'(RUMBLE_B2_Q24) * 64'(rumble_x2)
        - 64'(RUMBLE_A1_Q24) * 64'(rumble_y1)
        - 64'(RUMBLE_A2_Q24) * 64'(rumble_y2);
    wire signed [31:0] rumble_y_next = rumble_acc[55:24];

    // ---------------------------------------------------------------
    // Stage 5: input attenuator 0.2481 on both VCA inputs, x VCA gain,
    // output gains -2.136 (crack) / -4.700 (rumble), sum, saturate.
    // ---------------------------------------------------------------
    localparam signed [31:0] ATTEN_Q16          = 32'sd16261;   // 0.2481 * 65536
    localparam signed [31:0] OUT_GAIN_CRACK_Q16  = -32'sd140004; // -2.136 * 65536
    localparam signed [31:0] OUT_GAIN_RUMBLE_Q16 = -32'sd308019; // -4.700 * 65536

    wire signed [63:0] crack_atten_prod  = 64'(ATTEN_Q16) * 64'(crack_y_next);
    wire signed [31:0] crack_atten       = crack_atten_prod[47:16];
    wire signed [63:0] rumble_atten_prod = 64'(ATTEN_Q16) * 64'(rumble_y_next);
    wire signed [31:0] rumble_atten      = rumble_atten_prod[47:16];

    wire signed [63:0] crack_vca_prod  = 64'(crack_atten)  * 64'(vca_gain_crack);
    wire signed [31:0] crack_vca       = crack_vca_prod[47:16];
    wire signed [63:0] rumble_vca_prod = 64'(rumble_atten) * 64'(vca_gain_rumble);
    wire signed [31:0] rumble_vca      = rumble_vca_prod[47:16];

    wire signed [63:0] crack_out_prod  = 64'(OUT_GAIN_CRACK_Q16)  * 64'(crack_vca);
    wire signed [31:0] crack_out       = crack_out_prod[47:16];
    wire signed [63:0] rumble_out_prod = 64'(OUT_GAIN_RUMBLE_Q16) * 64'(rumble_vca);
    wire signed [31:0] rumble_out      = rumble_out_prod[47:16];

    wire signed [31:0] sum_full = crack_out + rumble_out;
    wire signed [31:0] mix_full = sum_full >>> 8; // filter scale -> audio scale (4096 LSB/V)

    wire signed [15:0] mix_sat =
        (mix_full > 32'sd32767)  ? 16'sd32767  :
        (mix_full < -32'sd32768) ? -16'sd32768 :
        mix_full[15:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            env_crack  <= VHIGH_SCALED; // idle = cap fully charged = 5V = silent
            env_rumble <= VHIGH_SCALED;
            crack_x1   <= 32'sd0;
            crack_x2   <= 32'sd0;
            crack_y1   <= 32'sd0;
            crack_y2   <= 32'sd0;
            rumble_x1  <= 32'sd0;
            rumble_x2  <= 32'sd0;
            rumble_y1  <= 32'sd0;
            rumble_y2  <= 32'sd0;
            exp_mix    <= 16'sd0;
        end else if (sample_ce) begin
            env_crack  <= env_crack_next;
            env_rumble <= env_rumble_next;

            crack_x1   <= noise_scaled;
            crack_x2   <= crack_x1;
            crack_y1   <= crack_y_next;
            crack_y2   <= crack_y1;

            rumble_x1  <= noise_scaled;
            rumble_x2  <= rumble_x1;
            rumble_y1  <= rumble_y_next;
            rumble_y2  <= rumble_y1;

            exp_mix    <= mix_sat;
        end
    end

endmodule
