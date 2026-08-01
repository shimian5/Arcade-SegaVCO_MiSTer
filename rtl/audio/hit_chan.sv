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
    //   envelope / filter state: signed [26:0] (27-bit), SCALE = 4096*256 =
    //   1,048,576 LSB/V (same units for both the envelope cap and the
    //   V2 control-voltage LUT index, so no conversion is needed).
    //   fs = clk_sys/832 = 39,935,064/832 = 47,998.875 Hz.
    //
    // WIDTH CHOICE -- see docs/audio-rtl-design.md "DSP block budget": every
    // coefficient/state operand that feeds a multiply here is 27 bits, not
    // 32. Cyclone V DSP blocks natively do 27x27; a 32-bit operand needs 2
    // DSP blocks (or gets decomposed into 18x18 sub-multiplies) AND defeats
    // packing the multiplier's output register into the DSP, forcing a
    // soft-logic adder tree afterward -- that soft adder tree is what blew
    // this file's timing budget under real Quartus synthesis. Derived
    // bounds: Q24 coefficients here top out at 33,237,369 in EXP's
    // RUMBLE_A1_Q24 (needs 26 bits signed); filter states at this design's
    // voltage scale need ~24 bits signed (rails -6.00/+4.50 V *
    // 1,048,576 LSB/V < 2^23). Both fit in 27 bits with margin, which is
    // also the DSP's native operand width -- so 27 is the target, not an
    // arbitrary round number. VCA gain values (from VCA_GAIN_LUT, max
    // 292,739) get their own narrower signed [20:0].
    // ---------------------------------------------------------------
    // SCALE = 1,048,576 LSB/V; folded directly into the localparam
    // constants below (VLOW_SCALED, VHIGH_SCALED, V2_MIN/MAX_SCALED)
    // rather than kept as its own signal, same as exp_chan.sv.
    // (fs = 47,998.875 Hz. Not declared as a `real` localparam -- every
    // constant derived from it is precomputed, because Quartus rejects
    // real-valued elaboration arithmetic for synthesis.)

    // ---------------------------------------------------------------
    // Stage 1: IC13 sec.1 74123 one-shot.
    //   tw = 0.45 * Rtiming(47K, INFERRED -- see header) * C42(4.7uF) = 99.4ms
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
    localparam signed [26:0] VLOW_SCALED  = 27'sd838861;   // 0.8V * SCALE
    localparam signed [26:0] VHIGH_SCALED = 27'sd5242880;  // 5.0V * SCALE

    localparam signed [26:0] A_DISCHARGE_Q16 = 27'sd61400;
    localparam signed [26:0] B_DISCHARGE_Q16 = 27'sd4136;   // 65536 - A

    localparam signed [26:0] A_RECHARGE_Q24 = 27'sd16776959;
    localparam signed [26:0] B_RECHARGE_Q24 = 27'sd257;     // 16777216 - A

    logic signed [26:0] env_hit, env_hit_next;

    // Products are 27x27 -> 54-bit (not 64): one coefficient operand times
    // one state operand, both narrowed to the DSP's native 27-bit width.
    wire signed [53:0] hit_dis_sum = A_DISCHARGE_Q16 * env_hit
                                    + B_DISCHARGE_Q16 * VLOW_SCALED;
    wire signed [53:0] hit_rec_sum = A_RECHARGE_Q24 * env_hit
                                    + B_RECHARGE_Q24 * VHIGH_SCALED;
    assign env_hit_next = q_hit ? 27'(hit_dis_sum >>> 16) : 27'(hit_rec_sum >>> 24);

    // Control voltage = (5.0 + Vcap) / 2 -- R90 and R96 are equal, fed
    // directly (no inversion) into the VCA LUT below, same as exp_chan.
    wire signed [26:0] v2_hit_scaled = (VHIGH_SCALED + env_hit) >>> 1;

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

    localparam signed [26:0] V2_MIN_SCALED = 27'sd2097152;      // 2.0V * SCALE
    localparam signed [26:0] V2_MAX_SCALED = 27'sd6291455;      // 6.0V * SCALE - 1

    // Gain values top out at 292,739 (19 bits unsigned) -- signed [20:0]
    // holds them with margin; this multiply was already small enough not
    // to be a DSP-budget driver, but the return path is narrowed too so it
    // doesn't force a wide operand on whatever multiplies it downstream.
    function automatic logic signed [20:0] vca_lut_lookup(input logic signed [26:0] v2_in);
        logic signed [26:0] v2_clamped;
        logic        [26:0] v2_off;
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
            gain_interp_prod = ($signed({1'b0, gain_hi}) - $signed({1'b0, gain_lo})) * $signed({1'b0, lut_frac});
            vca_lut_lookup = 21'($signed({1'b0, gain_lo}) + gain_interp_prod[47:16]);
        end
    endfunction

    // ---------------------------------------------------------------
    // Stages 4-7: 2-pole lowpass biquad -> input atten -> VCA multiply ->
    // HIT DIS network -> output gain -> rail clip.
    //
    // PIPELINED for the same reason ship_chan.sv/rebound_chan.sv/
    // fire_chan.sv were: as first written this whole tail was one
    // combinational cloud between sample_ce edges, and this file's biquad in
    // particular is the identical five-term mixed add/subtract MAC shape
    // that produced a genuine 98-node COMBINATIONAL LOOP in
    // rebound_chan.sv's biquad under real Quartus synthesis. A real Quartus
    // build of the RTL with SHIP/REBOUND/FIRE already pipelined confirmed
    // HIT as the new worst `clk_sys` setup path (`noise_mm5837:u_noise`
    // register straight through to `hit_mix`, -45 ns). See
    // docs/audio-rtl-design.md, "Real hardware sounded like static" and "DSP
    // block budget".
    //
    // Same discipline as the other three: one multiply per register-to-
    // register hop, free-running on `clk`. Every bit-select that feeds a
    // later multiply or shift is first routed through its own
    // signed-declared wire -- see fire_chan.sv's header note on why a bare
    // `signal[hi:lo]` is unsigned even when `signal` is signed, and
    // rebound_chan.sv's on why a bare multiply feeding straight into `>>>`
    // is not context-widened by a narrow assignment target. Both are real
    // bugs an earlier draft of this rework hit and had to find by
    // instrumentation; neither is a hypothetical here.
    // ---------------------------------------------------------------

    // IC20 sec.1 Sallen-Key 2-pole lowpass on noise_b. R84=R88=15K,
    // C49=C50=0.0033uF, gain K = 1 + R85/R86 = 2.5. f0 = 3215Hz, Q = 2.0.
    // RBJ biquad, direct form I, s32 state, filter SCALE units, coefficients
    // precomputed the same way as exp_chan.sv's (Quartus rejects $sin/$cos
    // for synthesis, so no elaboration-time trig here).
    //
    // Regenerate at fs = 47998.875 with:
    //   w0 = 2*pi*f0/fs; alpha = sin(w0)/(2*Q); a0 = 1+alpha
    //   b0 = b2 = G*(1-cos(w0))/2/a0, b1 = G*(1-cos(w0))/a0
    //   a1 = -2*cos(w0)/a0, a2 = (1-alpha)/a0
    //   then multiply by 2^24 and round.
    localparam signed [26:0] HIT_B0_Q24 =  27'sd1660616;   // +0.098980428
    localparam signed [26:0] HIT_B1_Q24 =  27'sd3321232;   // +0.197960855
    localparam signed [26:0] HIT_B2_Q24 =  27'sd1660616;   // +0.098980428
    localparam signed [26:0] HIT_A1_Q24 = -27'sd27787755;  // -1.656279257
    localparam signed [26:0] HIT_A2_Q24 =  27'sd13667524;  // +0.814647941

    // noise_b, scaled from the audio SCALE (4096 LSB/V) to the filter
    // SCALE (4096*256 LSB/V), same convention as exp_chan's noise_scaled.
    // Sign-extend and shift in a full-width wire FIRST (per this file's own
    // header note: a bare multiply/shift isn't context-widened by a narrow
    // assignment target), then cast down to 27 bits -- the shifted value
    // only ever needs ~24 bits, so the cast is a safe truncation, not a
    // silent overflow.
    wire signed [31:0] noise_ext     = {{16{noise_b[15]}}, noise_b};
    wire signed [26:0] noise_scaled  = 27'(noise_ext <<< 8);

    logic signed [26:0] hit_x1, hit_x2, hit_y1, hit_y2;
    logic signed [26:0] hit_y_next;

    // Pipe stage 0 (every clk): the biquad's five independent products
    // (unlike REBOUND, HIT's B1 term is genuinely nonzero -- a real 2-pole
    // lowpass, not a bandpass) and the VCA lookup share a stage; none
    // depends on another's result this cycle.
    logic signed [53:0] h0_prod_b0, h0_prod_b1, h0_prod_b2, h0_prod_a1, h0_prod_a2;
    logic signed [20:0] h0_vca_gain;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            h0_prod_b0 <= '0;
            h0_prod_b1 <= '0;
            h0_prod_b2 <= '0;
            h0_prod_a1 <= '0;
            h0_prod_a2 <= '0;
            h0_vca_gain <= '0;
        end else begin
            h0_prod_b0  <= HIT_B0_Q24 * noise_scaled;
            h0_prod_b1  <= HIT_B1_Q24 * hit_x1;
            h0_prod_b2  <= HIT_B2_Q24 * hit_x2;
            h0_prod_a1  <= HIT_A1_Q24 * hit_y1;
            h0_prod_a2  <= HIT_A2_Q24 * hit_y2;
            h0_vca_gain <= vca_lut_lookup(v2_hit_scaled);
        end
    end

    // Pipe stage 1: sum the five products (cheap add/sub) -> hit_y_next.
    logic signed [20:0] h1_vca_gain;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hit_y_next  <= '0;
            h1_vca_gain <= '0;
        end else begin
            hit_y_next  <= 27'((h0_prod_b0 + h0_prod_b1 + h0_prod_b2 - h0_prod_a1 - h0_prod_a2) >>> 24);
            h1_vca_gain <= h0_vca_gain;
        end
    end

    // ---------------------------------------------------------------
    // Input attenuator R81 10K / (R80 33K + R81 10K) = 0.232558, then x VCA
    // gain. Order: biquad output -> atten -> VCA multiply.
    // ---------------------------------------------------------------
    localparam signed [26:0] ATTEN_Q16 = 27'sd15241;   // 0.232558 * 65536

    // Pipe stage 2: the atten multiply.
    logic signed [53:0] h2_atten_prod;
    logic signed [20:0] h2_vca_gain;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            h2_atten_prod <= '0;
            h2_vca_gain   <= '0;
        end else begin
            h2_atten_prod <= ATTEN_Q16 * hit_y_next;
            h2_vca_gain   <= h1_vca_gain;
        end
    end

    // Pipe stage 3: the VCA multiply itself. 27x21 -> 48-bit product.
    wire signed [26:0] h2_atten = 27'(h2_atten_prod >>> 16);

    logic signed [47:0] h3_vca_prod;

    always_ff @(posedge clk) begin
        if (!rst_n) h3_vca_prod <= '0;
        else        h3_vca_prod <= h2_atten * h2_vca_gain;
    end

    // ---------------------------------------------------------------
    // HIT DIS0-2 network. IC24's output feeds C13 into three 4066 sections
    // gated by hit_dis[0..2], each in series with a different resistor
    // (R25 100K / R26 22K / R27 10K) into a common node. That node is NOT a
    // virtual ground: R28 100K (to +12V, an AC ground) and R135 100K (to
    // IC28's virtual ground) put 50K across it, and C9 0.01uF shunts it --
    // so the DIS selection sets BOTH a low-frequency gain and a one-pole
    // lowpass corner at once. Implemented as a combinational 8-entry lookup
    // on hit_dis giving (gain Q0.16, pole a Q0.24), then a one-pole lowpass
    //   y += (1-a) * (gain*x - y)
    // in filter scale.
    // ---------------------------------------------------------------
    logic signed [26:0] dis_gain_q16;
    logic signed [26:0] dis_a_q24;

    always_comb begin
        case (hit_dis)
            3'b000: begin dis_gain_q16 = 27'sd0;     dis_a_q24 = 27'sd0;        end // no switch closed, muted
            3'b001: begin dis_gain_q16 = 27'sd21845; dis_a_q24 = 27'sd15760713; end // DIS0 only,  477.5 Hz
            3'b010: begin dis_gain_q16 = 27'sd45511; dis_a_q24 = 27'sd14638499; end // DIS1 only,  1041.7 Hz
            3'b011: begin dis_gain_q16 = 27'sd48165; dis_a_q24 = 27'sd14336678; end // DIS0+1,     1200.9 Hz
            3'b100: begin dis_gain_q16 = 27'sd54613; dis_a_q24 = 27'sd13066032; end // DIS2 only,  1909.9 Hz
            3'b101: begin dis_gain_q16 = 27'sd55454; dis_a_q24 = 27'sd12796633; end // DIS0+2,     2069.0 Hz
            3'b110: begin dis_gain_q16 = 27'sd57614; dis_a_q24 = 27'sd11885471; end // DIS1+2,     2633.3 Hz
            3'b111: begin dis_gain_q16 = 27'sd58066; dis_a_q24 = 27'sd11640413; end // all three,  2792.4 Hz
        endcase
    end

    wire signed [26:0] dis_one_minus_a = 27'sd16777216 - dis_a_q24; // Q0.24

    logic signed [26:0] dis_y, dis_y_next;

    // Pipe stage 4: the DIS gain multiply. hit_dis is a slow CPU-latched
    // value (not per-sample), so reading it live at whichever pipeline
    // cycle needs it is fine -- same reasoning ship_chan.sv applies to
    // ship_on and rebound_chan.sv's gate stage applies to v_c31.
    wire signed [26:0] h3_vca = 27'(h3_vca_prod >>> 16);

    logic signed [53:0] h4_dis_gain_prod;

    always_ff @(posedge clk) begin
        if (!rst_n) h4_dis_gain_prod <= '0;
        else        h4_dis_gain_prod <= dis_gain_q16 * h3_vca;
    end

    // Pipe stage 5: the DIS lowpass's multiply (gain*x - y, times 1-a).
    // The subtraction is routed through its own signed-declared wire before
    // feeding the multiply, per this file's header note on bare multiplies
    // not being context-widened by a narrow assignment target.
    wire signed [26:0] h4_dis_gain_x = 27'(h4_dis_gain_prod >>> 16);
    wire signed [26:0] dis_gain_x_minus_y = 27'(h4_dis_gain_x - dis_y);

    logic signed [53:0] h5_dis_lp_prod;

    always_ff @(posedge clk) begin
        if (!rst_n) h5_dis_lp_prod <= '0;
        else        h5_dis_lp_prod <= dis_one_minus_a * dis_gain_x_minus_y;
    end

    // Pipe stage 6: resolve dis_y_next (cheap add).
    always_ff @(posedge clk) begin
        if (!rst_n) dis_y_next <= '0;
        else        dis_y_next <= dis_y + 27'(h5_dis_lp_prod >>> 24);
    end

    // ---------------------------------------------------------------
    // IC28 inverting stage, R134 680K feedback over R135 100K -> gain -6.8.
    // Then convert filter scale -> audio scale (>>>8) and clamp to the
    // LM324 rails.
    // ---------------------------------------------------------------
    localparam signed [26:0] OUT_GAIN_Q16 = -27'sd445645;   // -6.8 * 65536

    // Pipe stage 7: the output-gain multiply.
    logic signed [53:0] h7_out_prod;

    always_ff @(posedge clk) begin
        if (!rst_n) h7_out_prod <= '0;
        else        h7_out_prod <= OUT_GAIN_Q16 * dis_y_next;
    end

    wire signed [26:0] h7_out    = 27'(h7_out_prod >>> 16);
    wire signed [26:0] mix_full  = h7_out >>> 8; // filter scale -> audio scale (4096 LSB/V)

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

    // hit_mix free-runs on `clk`, same reasoning as the other three
    // pipelined channels: by the time it is next read (the following
    // sample_ce, at least ~824 clk_sys cycles after this one given the
    // 8-stage pipeline above) it has long since settled.
    always_ff @(posedge clk) begin
        if (!rst_n) hit_mix <= 16'sd0;
        else        hit_mix <= mix_sat;
    end

    // env_hit / hit_x1,x2,y1,y2 / dis_y remain sample_ce-gated: they are the
    // recursive one-pole/filter states themselves and must only advance
    // once per audio sample.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            env_hit <= VHIGH_SCALED; // idle = cap fully charged = 5V = silent
            hit_x1  <= 27'sd0;
            hit_x2  <= 27'sd0;
            hit_y1  <= 27'sd0;
            hit_y2  <= 27'sd0;
            dis_y   <= 27'sd0;
        end else if (sample_ce) begin
            env_hit <= env_hit_next;

            hit_x1  <= noise_scaled;
            hit_x2  <= hit_x1;
            hit_y1  <= hit_y_next;
            hit_y2  <= hit_y1;

            dis_y   <= dis_y_next;
        end
    end

endmodule
