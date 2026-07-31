// HIT channel, sheet 2. See docs/audio-rtl-design.md, "Phase 3" family for
// the derivation pattern this module follows (same shape as exp_chan.sv);
// this module must not contradict that file.
//
//   /HIT -> IC13 sec.1 74123 (tw=99.4ms) -- Q -----------------------+
//                                                                     v
//   hit envelope (Q-bar of IC13 sec.1, discharge/recharge through C48) ->
//     control voltage (5+Vc)/2 -> MC3340 VCA gain LUT (direct, no invert)
//
//   noise_b -> 2-pole lowpass f0=3215Hz, Q=2.0, gain=2.5 (IC20 sec.1) ->
//              atten 0.232558 -> x VCA gain -> gain -6.8 -->
//   IC24 -> C13 -> HIT DIS0-2 3x4066 gain/lowpass select network ->
//   IC28 inverting stage -> HIT MIX
//
// The 74123's timing resistor is drawn on sheet 2 with no designator and no
// value. Taken as 47K -- INFERRED, not traced, but on strong evidence: this
// board sets every one-shot's width with its CAPACITOR and holds the resistor
// at 47K throughout. ALARM0-2 (R2/R3/R14, 6.8uF), ALARM3 (R15, 10uF), FIRE
// (R7, 1uF), EXP crack (R16, 4.7uF), EXP rumble (R17, 22uF) and REBOUND
// (R47, 1uF) are eight for eight at 47K across a 22:1 spread of capacitors --
// and R47 is the OTHER SECTION OF THIS VERY PACKAGE. At 47K/4.7uF, HIT is
// identical to EXP's crack in both R and C.
//
// Two dead ends, so nobody re-walks them: it is NOT R92 (4.7 ohm 1/2 W, a
// Zobel resistor on the LA4460 outputs; the assembly drawing shows the bank
// beside IC13 as R90 1M, R91 470, MA150, R93 4.7K, R94 4.7K, R95 2.7K, with
// no R92 present), and NOT R97 (by IC21/C51/C52, in EXP's rumble filter).
//
// If a BOM ever contradicts this, only WIDTH_CYCLES below changes -- the
// envelope shape and every level here are set by C48/R91/R90/R96.
module hit_chan (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic                hit_n,        // /HIT, active low, falling edge triggers
    input  logic         [2:0] hit_dis,       // HIT DIS0..2, active high, from IC2 4175B
    input  logic signed [15:0] noise_b,       // 4096 LSB = 1V
    output logic signed [15:0] hit_mix        // 4096 LSB = 1V
);

    // ---------------------------------------------------------------
    // Fixed-point conventions, identical to exp_chan.sv / fire_chan.sv:
    //   envelope / filter state: signed [31:0], SCALE = 4096*256 =
    //   1,048,576 LSB/V (same units for both the envelope cap and the
    //   V2 control-voltage LUT index, so no conversion is needed).
    //   fs = clk_sys/832 = 39,935,064/832 = 47,998.875 Hz.
    // ---------------------------------------------------------------
    // SCALE = 1,048,576 LSB/V; folded directly into the localparam
    // constants below (VLOW_SCALED, VHIGH_SCALED, V2_MIN/MAX_SCALED)
    // rather than kept as its own signal, same as exp_chan.sv.
    // (fs = 47,998.875 Hz. Not declared as a `real` localparam -- every
    // constant derived from it is precomputed, because Quartus rejects
    // real-valued elaboration arithmetic for synthesis.)

    // ---------------------------------------------------------------
    // Stage 1: IC13 sec.1 74123 one-shot.
    //   tw = 0.45 * Rtiming(47K, ASSUMED -- see header) * C42(4.7uF) = 99.4ms
    //     WIDTH_CYCLES = 0.0994 * 39,935,064 = 3,969,745.36 -> 3,969,745
    // ---------------------------------------------------------------
    logic q_hit;

    ttl_74123 #(.WIDTH_CYCLES(3969745)) u_74123 (
        .clk    (clk),
        .rst_n  (rst_n),
        .a_n    (hit_n),
        .q      (q_hit)
    );

    // ---------------------------------------------------------------
    // Stage 2: envelope on C48 0.68uF. D3's cathode faces the 74123
    // (same orientation as EXP's D6/D7, opposite to FIRE's D8): the cap
    // sits charged toward 5V while idle (Q-bar idles high, diode
    // blocks), the pulse pulls Q-bar low and the diode conducts,
    // *discharging* the cap toward ~0.8V; it recovers toward 5V once
    // the pulse ends. Modelled the same way as exp_chan's envelopes: a
    // one-pole toward one of two targets, gated by the one-shot's Q
    // (active while gated = discharging).
    //
    // Reset value: the idle steady-state is the cap fully charged
    // (5.0V, i.e. maximally attenuated / silent) -- reset must NOT be
    // 0V, same fix as alarm_chan.sv / exp_chan.sv.
    //
    // discharge (R91 470, tau=0.3196ms): A_DISCHARGE_Q16 = 61400
    //   realised tau 0.319587ms (-0.0040%)
    // recharge (R90+R96 2M, tau=1.36s): pole far too close to unity for
    //   Q0.16 -- same trap as exp_chan's recharge poles -- so Q0.24:
    //   A_RECHARGE_Q24 = 16776959, realised tau 1.36004s (+0.0031%)
    // ---------------------------------------------------------------
    localparam signed [31:0] VLOW_SCALED  = 32'sd838861;   // 0.8V * SCALE
    localparam signed [31:0] VHIGH_SCALED = 32'sd5242880;  // 5.0V * SCALE

    localparam signed [31:0] A_DISCHARGE_Q16 = 32'sd61400;
    localparam signed [31:0] B_DISCHARGE_Q16 = 32'sd4136;   // 65536 - A

    localparam signed [63:0] A_RECHARGE_Q24 = 64'sd16776959;
    localparam signed [63:0] B_RECHARGE_Q24 = 64'sd257;     // 16777216 - A

    logic signed [31:0] env_hit, env_hit_next;

    wire signed [63:0] hit_dis_sum = 64'(A_DISCHARGE_Q16) * 64'(env_hit)
                                    + 64'(B_DISCHARGE_Q16) * 64'(VLOW_SCALED);
    wire signed [63:0] hit_rec_sum = A_RECHARGE_Q24 * 64'(env_hit)
                                    + B_RECHARGE_Q24 * 64'(VHIGH_SCALED);
    assign env_hit_next = q_hit ? hit_dis_sum[47:16] : hit_rec_sum[55:24];

    // Control voltage = (5.0 + Vcap) / 2 -- R90 and R96 are equal, fed
    // directly (no inversion) into the VCA LUT below, same as exp_chan.
    wire signed [31:0] v2_hit_scaled = (VHIGH_SCALED + env_hit) >>> 1;

    // ---------------------------------------------------------------
    // Stage 3: MC3340 VCA gain LUT -- identical table, indexing and
    // interpolation as exp_chan.sv's VCA_GAIN_LUT (65 points, V2 =
    // 2.0..6.0V step 0.0625V), copied verbatim.
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

    wire signed [31:0] vca_gain_hit = vca_lut_lookup(v2_hit_scaled);

    // ---------------------------------------------------------------
    // Stage 4: IC20 sec.1 Sallen-Key 2-pole lowpass on noise_b.
    // R84=R88=15K, C49=C50=0.0033uF, gain K = 1 + R85/R86 = 2.5.
    // f0 = 3215Hz, Q = 2.0. RBJ biquad, direct form I, s32 state,
    // filter SCALE units, coefficients precomputed the same way as
    // exp_chan.sv's (Quartus rejects $sin/$cos for synthesis, so no
    // elaboration-time trig here).
    //
    // Regenerate at fs = 47998.875 with:
    //   w0 = 2*pi*f0/fs; alpha = sin(w0)/(2*Q); a0 = 1+alpha
    //   b0 = b2 = G*(1-cos(w0))/2/a0, b1 = G*(1-cos(w0))/a0
    //   a1 = -2*cos(w0)/a0, a2 = (1-alpha)/a0
    //   then multiply by 2^24 and round.
    // ---------------------------------------------------------------
    localparam signed [31:0] HIT_B0_Q24 =  32'sd1660616;   // +0.098980428
    localparam signed [31:0] HIT_B1_Q24 =  32'sd3321232;   // +0.197960855
    localparam signed [31:0] HIT_B2_Q24 =  32'sd1660616;   // +0.098980428
    localparam signed [31:0] HIT_A1_Q24 = -32'sd27787755;  // -1.656279257
    localparam signed [31:0] HIT_A2_Q24 =  32'sd13667524;  // +0.814647941

    // noise_b, scaled from the audio SCALE (4096 LSB/V) to the filter
    // SCALE (4096*256 LSB/V), same convention as exp_chan's noise_scaled.
    wire signed [31:0] noise_scaled = {{16{noise_b[15]}}, noise_b} <<< 8;

    logic signed [31:0] hit_x1, hit_x2, hit_y1, hit_y2;

    wire signed [63:0] hit_acc =
          64'(HIT_B0_Q24) * 64'(noise_scaled)
        + 64'(HIT_B1_Q24) * 64'(hit_x1)
        + 64'(HIT_B2_Q24) * 64'(hit_x2)
        - 64'(HIT_A1_Q24) * 64'(hit_y1)
        - 64'(HIT_A2_Q24) * 64'(hit_y2);
    wire signed [31:0] hit_y_next = hit_acc[55:24];

    // ---------------------------------------------------------------
    // Stage 5: input attenuator R81 10K / (R80 33K + R81 10K) = 0.232558,
    // then x VCA gain. Order: biquad output -> atten -> VCA multiply.
    // ---------------------------------------------------------------
    localparam signed [31:0] ATTEN_Q16 = 32'sd15241;   // 0.232558 * 65536

    wire signed [63:0] hit_atten_prod = 64'(ATTEN_Q16) * 64'(hit_y_next);
    wire signed [31:0] hit_atten      = hit_atten_prod[47:16];

    wire signed [63:0] hit_vca_prod = 64'(hit_atten) * 64'(vca_gain_hit);
    wire signed [31:0] hit_vca      = hit_vca_prod[47:16];

    // ---------------------------------------------------------------
    // Stage 6: HIT DIS0-2 network. IC24's output feeds C13 into three
    // 4066 sections gated by hit_dis[0..2], each in series with a
    // different resistor (R25 100K / R26 22K / R27 10K) into a common
    // node. That node is NOT a virtual ground: R28 100K (to +12V, an AC
    // ground) and R135 100K (to IC28's virtual ground) put 50K across
    // it, and C9 0.01uF shunts it -- so the DIS selection sets BOTH a
    // low-frequency gain and a one-pole lowpass corner at once.
    // Implemented as a combinational 8-entry lookup on hit_dis giving
    // (gain Q0.16, pole a Q0.24), then a one-pole lowpass
    //   y += (1-a) * (gain*x - y)
    // in filter scale.
    // ---------------------------------------------------------------
    logic signed [31:0] dis_gain_q16;
    logic signed [31:0] dis_a_q24;

    always_comb begin
        case (hit_dis)
            3'b000: begin dis_gain_q16 = 32'sd0;     dis_a_q24 = 32'sd0;        end // no switch closed, muted
            3'b001: begin dis_gain_q16 = 32'sd21845; dis_a_q24 = 32'sd15760713; end // DIS0 only,  477.5 Hz
            3'b010: begin dis_gain_q16 = 32'sd45511; dis_a_q24 = 32'sd14638499; end // DIS1 only,  1041.7 Hz
            3'b011: begin dis_gain_q16 = 32'sd48165; dis_a_q24 = 32'sd14336678; end // DIS0+1,     1200.9 Hz
            3'b100: begin dis_gain_q16 = 32'sd54613; dis_a_q24 = 32'sd13066032; end // DIS2 only,  1909.9 Hz
            3'b101: begin dis_gain_q16 = 32'sd55454; dis_a_q24 = 32'sd12796633; end // DIS0+2,     2069.0 Hz
            3'b110: begin dis_gain_q16 = 32'sd57614; dis_a_q24 = 32'sd11885471; end // DIS1+2,     2633.3 Hz
            3'b111: begin dis_gain_q16 = 32'sd58066; dis_a_q24 = 32'sd11640413; end // all three,  2792.4 Hz
        endcase
    end

    logic signed [31:0] dis_y, dis_y_next;

    wire signed [63:0] dis_gain_prod = 64'(dis_gain_q16) * 64'(hit_vca);
    wire signed [31:0] dis_gain_x    = dis_gain_prod[47:16];

    wire signed [31:0] dis_one_minus_a = 32'sd16777216 - dis_a_q24; // Q0.24
    wire signed [63:0] dis_lp_prod     = 64'(dis_one_minus_a) * 64'(dis_gain_x - dis_y);
    assign dis_y_next = dis_y + dis_lp_prod[55:24];

    // ---------------------------------------------------------------
    // Stage 7: IC28 inverting stage, R134 680K feedback over R135 100K
    // -> gain -6.8. Then convert filter scale -> audio scale (>>>8)
    // and clamp to the LM324 rails.
    // ---------------------------------------------------------------
    localparam signed [31:0] OUT_GAIN_Q16 = -32'sd445645;   // -6.8 * 65536

    wire signed [63:0] hit_out_prod = 64'(OUT_GAIN_Q16) * 64'(dis_y_next);
    wire signed [31:0] hit_out      = hit_out_prod[47:16];

    wire signed [31:0] mix_full = hit_out >>> 8; // filter scale -> audio scale (4096 LSB/V)

    // IC28 OUTPUT RAILS -- a real clipping mechanism, not a format guard.
    //
    // IC28 is an LM324 on the board's 12V single supply with its + input
    // at the 6V mid-rail, so its output cannot leave 0 .. ~10.5V. Referred
    // to the 6V rail that is roughly -6.0V / +4.5V, and it is ASYMMETRIC:
    // the LM324 sinks nearly to ground but stops about 1.5V short of Vcc.
    //
    // Both figures are datasheet-backed (docs/reference/LM324.pdf p11):
    //   LM324 V_OH = VCC - 1.5V at RL = 2K, 25C -> 10.5V -> +4.50V
    //   LM324 V_OL = 5mV typ / 20mV max         ->  0.0V -> -6.00V
    localparam signed [31:0] RAIL_HI = 32'sd18432;   // +4.50 V * 4096
    localparam signed [31:0] RAIL_LO = -32'sd24576;  // -6.00 V * 4096

    wire signed [15:0] mix_sat =
        (mix_full > RAIL_HI) ? RAIL_HI[15:0] :
        (mix_full < RAIL_LO) ? RAIL_LO[15:0] :
        mix_full[15:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            env_hit <= VHIGH_SCALED; // idle = cap fully charged = 5V = silent
            hit_x1  <= 32'sd0;
            hit_x2  <= 32'sd0;
            hit_y1  <= 32'sd0;
            hit_y2  <= 32'sd0;
            dis_y   <= 32'sd0;
            hit_mix <= 16'sd0;
        end else if (sample_ce) begin
            env_hit <= env_hit_next;

            hit_x1  <= noise_scaled;
            hit_x2  <= hit_x1;
            hit_y1  <= hit_y_next;
            hit_y2  <= hit_y1;

            dis_y   <= dis_y_next;

            hit_mix <= mix_sat;
        end
    end

endmodule
