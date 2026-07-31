// FIRE channel (laser), sheet 3. See docs/audio-rtl-design.md, "FIRE --
// laser" for the full derivation; this module must not contradict that
// file. Chain:
//   /FIRE -> IC4 74123 one-shot (tw=21.15ms) -> envelope (fast charge to
//   3.16V while gated, tau=1.02s decay) -> splits into:
//     control leg:  V2 = 5.475 - 0.839*Venv -> piecewise A(V2) -> VCA gain
//                   (LUT, linear interpolation)
//     filter leg:   Tr1 piecewise conduction -> blends IC12 between flat
//                   gain -4.7 (Tr1 saturated) and -4.7 with a 677 Hz
//                   one-pole low-pass (Tr1 off)
//   signal path: noise_a -> IC12 (filter leg) -> input atten 0.0991 ->
//                x VCA gain (control leg) -> output gain -2.2 -> FIRE MIX
module fire_chan (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic                fire_n,          // /FIRE, active low, falling edge triggers
    input  logic signed [15:0] noise_a,
    output logic signed [15:0] fire_mix         // 4096 LSB = 1V
);

    // ---------------------------------------------------------------
    // Filter-state fixed point: signed [31:0], 4096*256 = 1,048,576
    // LSB/V, same convention as alarm_chan's high-pass state. All Q0.16
    // coefficients below are computed at clk_sys = 39,935,064 Hz and
    // sample rate fs = clk_sys/832 = 47,998.875 Hz.
    // (SCALE = 4096*256 = 1,048,576 LSB/V; folded directly into the
    // localparam constants below rather than kept as its own signal.)

    // ---------------------------------------------------------------
    // Stage 1: IC4 sec.2 74123 one-shot.
    // tw = 0.45 * R7(47K) * C4(1uF) = 21.15 ms
    // WIDTH_CYCLES = 0.02115 * 39,935,064 = 844,626.6 -> 844,627
    // ---------------------------------------------------------------
    logic q_oneshot;

    ttl_74123 #(.WIDTH_CYCLES(844627)) u_74123_fire (
        .clk    (clk),
        .rst_n  (rst_n),
        .a_n    (fire_n),
        .q      (q_oneshot)
    );

    // ---------------------------------------------------------------
    // Stage 2: envelope. One-pole toward VPEAK=3.16V while gated (fast,
    // tau=1ms -- chosen only to be much faster than the 21.15ms gate, per
    // spec's "reaching it within the gate is correct"; the real charge
    // dynamics through D8/R6 are not otherwise documented). Decays with
    // tau=1.02s (R4 150K * C3 6.8uF) once the gate drops.
    //   a_charge = exp(-1/(fs*0.001))  = 0.97938 -> Q0.16 = 64185
    // env_next = a*env + (1-a)*target   (target = VPEAK while gated, 0 while decaying)
    //
    // The DECAY pole must be carried in Q0.24, not Q0.16. Its ideal value is
    // exp(-1/(fs*1.02)) = 0.99997957, and Q0.16 cannot express it: 65535/65536
    // yields tau = 1.365 s (+34%) and 65534/65536 yields 0.68 s (-33%), with
    // the target falling between two adjacent codes. Eight more fractional
    // bits put the realised tau at 1.0191 s, 0.09% low.
    //   a_decay = 0.99997957 -> Q0.24 = 16776873
    // (The charge path keeps Q0.16: its pole is nowhere near unity, so it has
    // no precision problem, and its tau is a free choice anyway.)
    // ---------------------------------------------------------------
    localparam signed [31:0] VPEAK_SCALED = 32'sd3313500; // 3.16V * SCALE
    localparam signed [31:0] A_CHARGE = 32'sd64185;
    localparam signed [31:0] B_CHARGE = 32'sd1351;  // 65536 - A_CHARGE
    localparam signed [63:0] A_DECAY  = 64'sd16776873; // Q0.24; target 0, so (1-a)*target drops out

    logic signed [31:0] env, env_next;

    wire signed [63:0] env_charge_sum = 64'(A_CHARGE) * 64'(env) + 64'(B_CHARGE) * 64'(VPEAK_SCALED);
    wire signed [63:0] env_decay_sum  = A_DECAY * 64'(env);
    assign env_next = q_oneshot ? env_charge_sum[47:16] : env_decay_sum[55:24];

    // ---------------------------------------------------------------
    // Stage 3: control leg. V2 = 5.475 - 0.839*Venv
    // V2_CONST_SCALED = 5.475 * SCALE = 5,740,954
    // COEF_0839 (Q0.16)   = 0.839 * 65536 = 54985
    // ---------------------------------------------------------------
    localparam signed [31:0] V2_CONST_SCALED = 32'sd5740954;
    localparam signed [31:0] COEF_0839       = 32'sd54985;

    wire signed [63:0] v2_prod = 64'(COEF_0839) * 64'(env);
    wire signed [31:0] v2_scaled = V2_CONST_SCALED - v2_prod[47:16];

    // Clamp into the LUT's covered range [2.0V, 6.0V) before indexing.
    localparam signed [31:0] V2_MIN_SCALED = 32'sd2097152;      // 2.0V * SCALE
    localparam signed [31:0] V2_MAX_SCALED = 32'sd6291455;      // 6.0V * SCALE - 1

    wire signed [31:0] v2_clamped =
        (v2_scaled < V2_MIN_SCALED) ? V2_MIN_SCALED :
        (v2_scaled > V2_MAX_SCALED) ? V2_MAX_SCALED :
        v2_scaled;

    // ---------------------------------------------------------------
    // MC3340 VCA gain LUT: 65 points across V2 = 2.0 .. 6.0V, step
    // 0.0625V. The step was chosen so that, in the SCALE=1,048,576
    // LSB/V fixed point above, 0.0625V * SCALE = 65536 exactly -- an
    // index and Q0.16 interpolation fraction fall straight out of the
    // low/high halves of (v2_clamped - V2_MIN_SCALED) with no divide.
    //
    // Each entry is gain = 10^((13-A(V2))/20) from the piecewise A(V2)
    // in docs/audio-rtl-design.md, stored as a 16-fractional-bit fixed
    // point value (i.e. Q0.16 by fractional-bit count) but held in a
    // 32-bit word rather than the classic unsigned-16 container: the
    // VCA's +13 dB peak gain is 4.4668x, which needs integer bits a
    // 16-bit unsigned Q0.16 doesn't have. The -77..-90 dB tail quantises
    // to a handful of LSBs (and eventually 0 at fs=47999Hz*Q0.16), which
    // is inaudible and is the accepted floor per the design doc.
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

    wire [31:0] v2_off   = v2_clamped - V2_MIN_SCALED;   // 0 .. LUT_SIZE-1 in units of 65536
    wire [6:0]  lut_idx  = v2_off[22:16];                // 0 .. 63 (indices for interpolation)
    wire [15:0] lut_frac = v2_off[15:0];                 // Q0.16 fraction between idx and idx+1

    wire [31:0] gain_lo = VCA_GAIN_LUT[lut_idx];
    wire [31:0] gain_hi = VCA_GAIN_LUT[lut_idx + 7'd1];

    wire signed [63:0] gain_interp_prod = 64'($signed({1'b0, gain_hi}) - $signed({1'b0, gain_lo})) * 64'($signed({16'd0, lut_frac}));
    wire signed [31:0] vca_gain = 32'($signed({1'b0, gain_lo}) + gain_interp_prod[47:16]);

    // ---------------------------------------------------------------
    // Stage 4: filter leg. Tr1 conduction, piecewise on Vbe = Venv*0.1803.
    //   gc = 0                     Vbe <= 0.60
    //      = gsat*(Vbe-0.60)/0.15  0.60 < Vbe < 0.75
    //      = gsat                  Vbe >= 0.75
    // Rather than compute the shunt resistance and re-derive a corner
    // frequency from it (a full network solve the spec explicitly says
    // to avoid), we interpolate the IC12 one-pole coefficient directly
    // between its two analytically-known endpoints: frac=0 (Tr1 off) ->
    // a=A677 (677 Hz low-pass); frac=1 (Tr1 saturated) -> a=0 (bypass,
    // i.e. the filter's target value passes straight through). Both
    // endpoints share the same -4.7 flat/DC gain, which is applied via
    // GAIN_IC12 on the filter's target rather than as a separate stage.
    // ---------------------------------------------------------------
    localparam signed [31:0] VBE_COEF            = 32'sd11816;   // 0.1803 Q0.16
    localparam signed [31:0] VBE_LOW_SCALED       = 32'sd629146; // 0.60V * SCALE
    localparam signed [31:0] VBE_RANGE_SCALED     = 32'sd157286; // 0.15V * SCALE
    localparam signed [31:0] A677                 = 32'sd59978;  // 677Hz one-pole, Q0.16
    localparam signed [31:0] GAIN_IC12            = -32'sd308019; // -4.7 * 65536

    wire signed [63:0] vbe_prod = 64'(VBE_COEF) * 64'(env);
    wire signed [31:0] vbe_scaled = vbe_prod[47:16];

    wire signed [63:0] frac_gc_num = 64'((vbe_scaled - VBE_LOW_SCALED)) * 64'sd65536;
    wire signed [31:0] frac_gc_raw = 32'(frac_gc_num / 64'(VBE_RANGE_SCALED));

    wire signed [31:0] frac_gc =
        (vbe_scaled <= VBE_LOW_SCALED) ? 32'sd0 :
        (vbe_scaled >= (VBE_LOW_SCALED + VBE_RANGE_SCALED)) ? 32'sd65536 :
        frac_gc_raw;

    wire signed [63:0] a_ic12_prod = 64'(A677) * (64'sd65536 - 64'(frac_gc));
    wire signed [31:0] a_ic12 = a_ic12_prod[47:16];
    wire signed [31:0] b_ic12 = 32'sd65536 - a_ic12;

    // filter target = noise_a (scaled up to the 32-bit filter scale) * GAIN_IC12
    wire signed [31:0] noise_scaled = {{16{noise_a[15]}}, noise_a} <<< 8;
    wire signed [63:0] ic12_target_prod = 64'(noise_scaled) * 64'(GAIN_IC12);
    wire signed [31:0] ic12_target = ic12_target_prod[47:16];

    logic signed [31:0] y_ic12, y_ic12_next;
    wire signed [63:0] ic12_sum = 64'(a_ic12) * 64'(y_ic12) + 64'(b_ic12) * 64'(ic12_target);
    assign y_ic12_next = ic12_sum[47:16];

    // ---------------------------------------------------------------
    // Stage 5: input attenuator (0.0991), x VCA gain, output stage
    // gain -2.2, saturate to s16.
    // ---------------------------------------------------------------
    localparam signed [31:0] ATTEN_Q16    = 32'sd6495;   // 0.0991 * 65536
    localparam signed [31:0] OUT_GAIN_Q16 = -32'sd144179; // -2.2 * 65536

    wire signed [63:0] atten_prod = 64'(ATTEN_Q16) * 64'(y_ic12);
    wire signed [31:0] x_atten    = atten_prod[47:16];

    wire signed [63:0] vca_prod = 64'(x_atten) * 64'(vca_gain);
    wire signed [31:0] x_vca    = vca_prod[47:16];

    wire signed [63:0] out_prod = 64'(OUT_GAIN_Q16) * 64'(x_vca);
    wire signed [31:0] x_out    = out_prod[47:16];

    wire signed [31:0] mix_full = x_out >>> 8; // filter scale -> audio scale (4096 LSB/V)

    wire signed [15:0] mix_sat =
        (mix_full > 32'sd32767)  ? 16'sd32767  :
        (mix_full < -32'sd32768) ? -16'sd32768 :
        mix_full[15:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            env       <= 32'sd0;
            y_ic12    <= 32'sd0;
            fire_mix  <= 16'sd0;
        end else if (sample_ce) begin
            env      <= env_next;
            y_ic12   <= y_ic12_next;
            fire_mix <= mix_sat;
        end
    end

endmodule
