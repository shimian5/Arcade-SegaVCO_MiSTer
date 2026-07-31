// REBOUND channel, sheet 2. See docs/audio-rtl-design.md for the derivation
// pattern this module follows (same shape as hit_chan.sv / exp_chan.sv);
// this module must not contradict that file.
//
//   /REBOUND -> IC13 sec.2 74123 (tw=21.15ms) -- Q --------------------+
//                                                                       v
//   rebound envelope (Q-bar of IC13 sec.2, discharge/recharge through C43) ->
//     control node V = 0.5875*Vc + 2.0625  (UNEQUAL divider, unlike EXP/HIT)
//     -> drives BOTH the 555 control voltage AND the VCA control (direct)
//
//   ctrl -> IC15B 555 astable, modelled via its C31 timing-cap voltage
//     (pin 3 unconnected; IC12 sec.2 follows the cap node directly) ->
//     bounce-rate oscillator, 24.6Hz -> 6.2Hz -> stops as ctrl -> 5V
//   C31 voltage -> Tr3 gate (R37/R36 base divider, piecewise-linear
//     conduction like fire_chan's Tr1) -> gates noise_a into node M
//
//   noise_a -> C41/R39 -> node M (C51/C40 midpoint, IC12's feedback net) ->
//     band-pass f0=320.3Hz, Q=1.129, peak gain 2.55 (IC12) ->
//     atten 0.751880 (R82/R83, INVERSE of EXP/HIT's ratio) ->
//     x VCA gain (ctrl node, direct) -> gain -3.30 (IC22) -> REBOUND MIX
//
// Tr3's collector shunts the SAME node (M) that noise_a is injected into,
// so physically the gate also detunes the band-pass (a resistive term at M
// moves both f0 and Q as Tr3 conducts). We model Tr3 as an input gate only,
// at fixed f0/Q -- the same simplification fire_chan.sv makes for its Tr1 --
// and say so here rather than let it go unstated.
module rebound_chan (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic                rebound_n,    // /REBOUND, active low, falling edge triggers
    input  logic signed [15:0] noise_a,       // 4096 LSB = 1V
    output logic signed [15:0] rebound_mix    // 4096 LSB = 1V
);

    // ---------------------------------------------------------------
    // Fixed-point conventions, identical to hit_chan.sv / exp_chan.sv:
    //   envelope / filter state: signed [31:0], SCALE = 4096*256 =
    //   1,048,576 LSB/V (same units for both the envelope cap and the
    //   V2 control-voltage LUT index, so no conversion is needed).
    //   fs = clk_sys/832 = 39,935,064/832 = 47,998.875 Hz.
    // ---------------------------------------------------------------
    // SCALE = 1,048,576 LSB/V; folded directly into the localparam
    // constants below (VLOW_SCALED, VHIGH_SCALED, V2_MIN/MAX_SCALED)
    // rather than kept as its own signal, same as hit_chan.sv.
    // (fs = 47,998.875 Hz. Not declared as a `real` localparam -- every
    // constant derived from it is precomputed, because Quartus rejects
    // real-valued elaboration arithmetic for synthesis.)

    // ---------------------------------------------------------------
    // Stage 1: IC13 sec.2 74123 one-shot.
    //   tw = R47(47K) * C44(1uF) shape -> 21.15ms (verified, given)
    //     WIDTH_CYCLES = 0.02115 * 39,935,064 = 844,626.60 -> 844,627
    // ---------------------------------------------------------------
    logic q_reb;

    ttl_74123 #(.WIDTH_CYCLES(844627)) u_74123 (
        .clk    (clk),
        .rst_n  (rst_n),
        .a_n    (rebound_n),
        .q      (q_reb)
    );

    // ---------------------------------------------------------------
    // Stage 2: envelope on C43 2.2uF from Q-bar (pin 12). D2's cathode
    // faces IC13, same orientation as HIT's D3: the cap sits charged
    // toward 5V while idle (Q-bar idles high, diode blocks), the pulse
    // pulls Q-bar low and the diode conducts, *discharging* the cap
    // toward ~0.8V; it recovers toward 5V once the pulse ends. Modelled
    // exactly like hit_chan's envelope: a one-pole toward one of two
    // targets, gated by the one-shot's Q (active while gated =
    // discharging).
    //
    // Reset value: the idle steady-state is the cap fully charged
    // (5.0V, i.e. maximally attenuated / silent) -- reset must NOT be
    // 0V, same fix as hit_chan.sv / exp_chan.sv.
    //
    // discharge (R44 470, tau=1.0342ms): A_DISCHARGE_Q16 = 64229
    // recharge (R43+R42 800K, tau=1.7564s): pole far too close to unity
    //   for Q0.16 -- same trap as exp_chan's recharge poles -- so
    //   Q0.24: A_RECHARGE_Q24 = 16777017
    // ---------------------------------------------------------------
    localparam signed [31:0] VLOW_SCALED  = 32'sd838861;   // 0.8V * SCALE
    localparam signed [31:0] VHIGH_SCALED = 32'sd5242880;  // 5.0V * SCALE

    localparam signed [31:0] A_DISCHARGE_Q16 = 32'sd64229;
    localparam signed [31:0] B_DISCHARGE_Q16 = 32'sd1307;   // 65536 - A

    localparam signed [63:0] A_RECHARGE_Q24 = 64'sd16777017;
    localparam signed [63:0] B_RECHARGE_Q24 = 64'sd199;     // 16777216 - A

    logic signed [31:0] env_reb, env_reb_next;

    wire signed [63:0] reb_dis_sum = 64'(A_DISCHARGE_Q16) * 64'(env_reb)
                                    + 64'(B_DISCHARGE_Q16) * 64'(VLOW_SCALED);
    wire signed [63:0] reb_rec_sum = A_RECHARGE_Q24 * 64'(env_reb)
                                    + B_RECHARGE_Q24 * 64'(VHIGH_SCALED);
    assign env_reb_next = q_reb ? reb_dis_sum[47:16] : reb_rec_sum[55:24];

    // ---------------------------------------------------------------
    // Stage 3: control node. UNLIKE EXP and HIT the divider is UNEQUAL
    // (R43 330K / R42 470K), so this is NOT the (5+Vc)/2 midpoint those
    // channels use -- it is a shifted, shallower ramp:
    //   V = 0.5875*Vc + 2.0625, spanning 2.5325V (open) -> 5.0V (muted)
    // This ONE node drives both the 555 control voltage (Stage 4) and
    // the VCA control (Stage 7) directly.
    // ---------------------------------------------------------------
    localparam signed [31:0] CTRL_SLOPE_Q24 = 32'sd9856614;   // 0.5875
    localparam signed [31:0] CTRL_OFFS      = 32'sd2162688;   // 2.0625V * SCALE

    wire signed [63:0] ctrl_prod = 64'(env_reb) * 64'(CTRL_SLOPE_Q24);
    wire signed [31:0] ctrl      = (ctrl_prod[55:24]) + CTRL_OFFS;

    // ---------------------------------------------------------------
    // Stage 4: IC15B 555 astable. Its output pin 3 is NOT CONNECTED;
    // IC12 sec.2 is a unity follower on the C31 timing-capacitor node,
    // so we model the CAPACITOR VOLTAGE itself and use it as the
    // signal, not a square wave. Ra = R65 10K, Rb = R64 33K, C31 = 1uF.
    //
    //   charging  (tau = (Ra+Rb)*C = 43ms, realised 42.999ms):
    //     v_c31 += (1-a_ch) * (VCC_SCALED - v_c31)
    //   discharging (tau = Rb*C = 33ms, realised 32.999ms):
    //     v_c31 += (1-a_dis) * (0 - v_c31)
    //   comparator: charging while v_c31 < ctrl and !(v_c31 <= ctrl/2)
    //     stops at v_c31 >= ctrl; resumes at v_c31 <= ctrl/2 (555's
    //     standard 1/3-2/3 thresholds, here referred to ctrl not Vcc
    //     since ctrl IS the 555's control-voltage pin).
    //
    // As ctrl rises toward 5V the charge phase can no longer reach it
    // (v_c31's ceiling is VCC_SCALED = 5.0V, the same as ctrl's ceiling),
    // so the oscillator simply STOPS -- that is the real behaviour and
    // needs no special case here. The sweep is 24.6Hz -> 6.2Hz -> stop,
    // i.e. a BOUNCE RATE, not a pitch.
    // ---------------------------------------------------------------
    localparam signed [31:0] VCC_SCALED = 32'sd5242880;  // 5.0V * SCALE

    localparam signed [63:0] A_CHARGE_Q24    = 64'sd16769089;
    localparam signed [63:0] B_CHARGE_Q24    = 64'sd8127;    // 16777216 - A
    localparam signed [63:0] A_DISCHARGE555_Q24 = 64'sd16766627;
    localparam signed [63:0] B_DISCHARGE555_Q24 = 64'sd10589; // 16777216 - A

    logic signed [31:0] v_c31, v_c31_next;
    logic                charging, charging_next;

    wire signed [63:0] v_c31_chg_sum = A_CHARGE_Q24 * 64'(v_c31)
                                      + B_CHARGE_Q24 * 64'(VCC_SCALED);
    wire signed [63:0] v_c31_dis_sum = A_DISCHARGE555_Q24 * 64'(v_c31);

    always_comb begin
        if (charging) begin
            v_c31_next = v_c31_chg_sum[55:24];
        end else begin
            v_c31_next = v_c31_dis_sum[55:24];
        end

        charging_next = charging;
        if (charging && (v_c31 >= ctrl)) begin
            charging_next = 1'b0;
        end else if (!charging && (v_c31 <= (ctrl >>> 1))) begin
            charging_next = 1'b1;
        end
    end

    // ---------------------------------------------------------------
    // Stage 5: Tr3 gate. Base fed through R37 12K / R36 4.7K = 0.281437,
    // emitter grounded. Piecewise-linear conduction like fire_chan's
    // Tr1 (off below Vbe 0.60, saturated at 0.75), driven off the C31
    // node voltage.
    //   GATE_OFF_THRESH: ramp giving Vbe = 0.60 -> 2.13193V
    //   GATE_SAT_THRESH: ramp giving Vbe = 0.75 -> 2.66491V
    //   frac = ((v_c31 - OFF) * GATE_SLOPE) >>> 20, Q0.16, clamped 0..65535
    //   factor: v_c31 <= OFF -> open (0dB), v_c31 >= SAT -> saturated
    //     (-36.6dB), between -> linear interpolation
    // ---------------------------------------------------------------
    localparam signed [31:0] GATE_OFF_THRESH = 32'sd2235480;
    localparam signed [31:0] GATE_SAT_THRESH = 32'sd2794349;
    localparam signed [31:0] GATE_SLOPE      = 32'sd122961;
    localparam signed [31:0] GATE_OPEN_Q16   = 32'sd65536;
    localparam signed [31:0] GATE_SAT_Q16    = 32'sd969;
    localparam signed [31:0] GATE_SPAN_Q16   = 32'sd64567;   // OPEN - SAT

    logic signed [31:0] gate_factor;

    always_comb begin
        if (v_c31 <= GATE_OFF_THRESH) begin
            gate_factor = GATE_OPEN_Q16;
        end else if (v_c31 >= GATE_SAT_THRESH) begin
            gate_factor = GATE_SAT_Q16;
        end else begin
            logic signed [63:0] frac_prod;
            logic signed [31:0] frac_raw, frac_clamped;
            logic signed [63:0] span_prod;
            frac_prod    = (64'(v_c31) - 64'(GATE_OFF_THRESH)) * 64'(GATE_SLOPE);
            frac_raw     = frac_prod[51:20];
            frac_clamped = (frac_raw < 32'sd0)     ? 32'sd0     :
                            (frac_raw > 32'sd65535) ? 32'sd65535 :
                            frac_raw;
            span_prod    = 64'(GATE_SPAN_Q16) * 64'(frac_clamped);
            gate_factor  = GATE_OPEN_Q16 - span_prod[47:16];
        end
    end

    // ---------------------------------------------------------------
    // Stage 6: band-pass on noise_a. NOISE.A -> C41 4.7uF -> R39 10K
    // injects at node M, the midpoint of C51/C40 (0.022uF each) in
    // series across R38 51K, IC12's feedback. Tr3 + R40 shunt that SAME
    // node (see the header note on the gate/detune simplification).
    // Solving the network gives a BAND-PASS (this is NOT fire_chan's
    // switchable lowpass -- FIRE injects at the inverting input
    // instead):
    //   Vo/Vin = -s*C51*R38 / [1 + s*R39*(C51+C40) + s^2*R39*R38*C40*C51]
    //   f0 = 320.3Hz, Q = 1.129, peak gain 2.55
    // RBJ biquad, direct form I, s32 state, filter SCALE units,
    // coefficients precomputed the same way as exp_chan.sv's (Quartus
    // rejects $sin/$cos for synthesis, so no elaboration-time trig
    // here). Verified: |H(f0)| = 2.55000, with exact nulls at DC and
    // Nyquist.
    //
    // Regenerate at fs = 47998.875 with:
    //   w0 = 2*pi*f0/fs; alpha = sin(w0)/(2*Q); a0 = 1+alpha
    //   b0 = G*alpha/a0, b1 = 0, b2 = -G*alpha/a0
    //   a1 = -2*cos(w0)/a0, a2 = (1-alpha)/a0
    //   then multiply by 2^24 and round.
    // ---------------------------------------------------------------
    localparam signed [31:0] REB_B0_Q24 =  32'sd779658;    // +0.046471256
    localparam signed [31:0] REB_B1_Q24 =  32'sd0;
    localparam signed [31:0] REB_B2_Q24 = -32'sd779658;    // -0.046471256
    localparam signed [31:0] REB_A1_Q24 = -32'sd32913976;  // -1.961825845
    localparam signed [31:0] REB_A2_Q24 =  32'sd16165719;  // +0.963551956

    // noise_a, scaled from the audio SCALE (4096 LSB/V) to the filter
    // SCALE (4096*256 LSB/V), same convention as exp_chan's noise_scaled.
    wire signed [31:0] noise_scaled = {{16{noise_a[15]}}, noise_a} <<< 8;

    wire signed [63:0] gate_prod = 64'(gate_factor) * 64'(noise_scaled);
    wire signed [31:0] gated_in  = gate_prod[47:16];

    logic signed [31:0] reb_x1, reb_x2, reb_y1, reb_y2;

    wire signed [63:0] reb_acc =
          64'(REB_B0_Q24) * 64'(gated_in)
        + 64'(REB_B1_Q24) * 64'(reb_x1)
        + 64'(REB_B2_Q24) * 64'(reb_x2)
        - 64'(REB_A1_Q24) * 64'(reb_y1)
        - 64'(REB_A2_Q24) * 64'(reb_y2);
    wire signed [31:0] reb_y_next = reb_acc[55:24];

    // ---------------------------------------------------------------
    // Stage 7: MC3340 VCA gain LUT -- identical table, indexing and
    // interpolation as hit_chan.sv's VCA_GAIN_LUT (65 points, V2 =
    // 2.0..6.0V step 0.0625V), copied verbatim. Its input is the
    // Stage-3 ctrl node directly (no inversion).
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

    wire signed [31:0] vca_gain_reb = vca_lut_lookup(ctrl);

    // ---------------------------------------------------------------
    // Stage 8: output. IC12 out -> C45 -> R82 3.3K / R83 10K divider ->
    // C24 -> IC18 VCA; IC18 out -> C20 -> R62 100K -> IC22 (R128 330K
    // fb, + at 6V). Order: biquad out -> OUT_DIV -> VCA gain ->
    // OUT_GAIN -> (>>>8) to audio scale -> rails.
    // ---------------------------------------------------------------
    localparam signed [31:0] OUT_DIV_Q16  =  32'sd49275;    // R83/(R82+R83) = 0.751880 --
                                                              // note this is the INVERSE of
                                                              // EXP/HIT's 0.248/0.233
    localparam signed [31:0] OUT_GAIN_Q16 = -32'sd216269;   // -R128/R62 = -3.30

    wire signed [63:0] reb_div_prod = 64'(OUT_DIV_Q16) * 64'(reb_y_next);
    wire signed [31:0] reb_div      = reb_div_prod[47:16];

    wire signed [63:0] reb_vca_prod = 64'(reb_div) * 64'(vca_gain_reb);
    wire signed [31:0] reb_vca      = reb_vca_prod[47:16];

    wire signed [63:0] reb_out_prod = 64'(OUT_GAIN_Q16) * 64'(reb_vca);
    wire signed [31:0] reb_out      = reb_out_prod[47:16];

    wire signed [31:0] mix_full = reb_out >>> 8; // filter scale -> audio scale (4096 LSB/V)

    // IC22 OUTPUT RAILS -- a real clipping mechanism, not a format guard.
    //
    // IC22 is an LM324 on the board's 12V single supply with its + input
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
            env_reb      <= VHIGH_SCALED; // idle = cap fully charged = 5V = silent
            v_c31        <= 32'sd0;
            charging     <= 1'b1;
            reb_x1       <= 32'sd0;
            reb_x2       <= 32'sd0;
            reb_y1       <= 32'sd0;
            reb_y2       <= 32'sd0;
            rebound_mix  <= 16'sd0;
        end else if (sample_ce) begin
            env_reb  <= env_reb_next;

            v_c31    <= v_c31_next;
            charging <= charging_next;

            reb_x1   <= gated_in;
            reb_x2   <= reb_x1;
            reb_y1   <= reb_y_next;
            reb_y2   <= reb_y1;

            rebound_mix <= mix_sat;
        end
    end

endmodule
