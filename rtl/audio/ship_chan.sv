// SHIP channel -- the engine drone, sheet 1. Every constant below is derived in
// docs/audio-rtl-design.md, "Phase 6"; this module must not contradict that file.
//
// SHIP is unlike every other channel on this board: it uses NO noise at all and
// is entirely self-oscillating. Three identical relaxation oscillators (Tr2,
// Tr4, Tr5) do all the work.
//
//   IC14 555 --C12 ramp--> IC17 sec.A follower = Vramp, 4..8 V at 6.95 Hz
//     |
//     +-------------------------------------------> Tr5 VCO  142.8 -> 71.4 Hz
//     |
//     +-> IC17 sec.B, R50/R51 10K, + at 6V, x(-1) -> Tr2 VCO  205.5 -> 411.1 Hz
//
//   ACC0-3 4066 ladder -> R22/C11 -> IC22 sec.A --> Tr4 VCO      0 -> 3236 Hz
//
//   AUDIO:   Tr2 integrator -> C65 -> R118 220K -+
//            Tr5 integrator -> C59 -> R120 220K -+-> IC26 sec.C, R119 30K fb
//                                                   gain -0.136364 -> IC24 pin 5
//   CONTROL: Tr4 integrator -> C56 -> R102 100K -> IC22 sec.C, R103 51K fb,
//                                                   + at 2.977444 V -> IC24 pin 6
//
//   IC24 MB4391 out -> C10 -> IC10 4066 (SHIP ON) -> R124 100K
//     -> IC28, R125 220K fb, + at 6 V = -2.200 -> C70 -> SHIP MIX
//
// The 555 is a ~7 Hz LFO, NOT the sound source, and it sweeps Tr2 and Tr5 in
// OPPOSITE directions because only Tr2 goes through the inverter. Tr4 is not
// audio at all: it is the VCA's control voltage, and it is the only thing ACC
// touches. Throttle changes the chop RATE, not the level.
//
// Scales here differ from the other channels on purpose -- see the design doc's
// "RTL realisation" note:
//   555 cap / VCO state / Vs/2 : 2^24 LSB/V   (fine enough for a per-clk step)
//   dc_block internal          : 2^32 LSB/V
//   audio tail and V2          : 2^20 LSB/V   (the house scale, so the MC3340
//                                              LUT ports over verbatim)
module ship_chan (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic               ship_on,   // ppi1_pb[6], ACTIVE HIGH level
    input  logic         [3:0] acc,       // ACC0-3, latched by IC6 in audio_top
    output logic signed [15:0] ship_mix   // 4096 LSB = 1V
);

    // ---------------------------------------------------------------
    // Stage 1: IC14 555 astable, modelled by its C12 timing-cap voltage.
    //
    // Its output pin 3 is NOT CONNECTED -- IC17 sec.A (pins 2/3/1) is a unity
    // follower sitting on the C12 node -- so SHIP needs the ramp's SHAPE, not
    // just its period, and a fixed-cycle square would be wrong. Same treatment
    // rebound_chan.sv gives IC15B.
    //
    // D1's ANODE is at DIS and its cathode at TH/TR, so D1 is in the CHARGE
    // path, shorting out R23; on discharge it is reverse-biased and the cap
    // drains through R23 alone. That also means the charge target is
    // 12 - 0.6 = 11.4 V, not 12 V:
    //
    //   charge    R24 6.8K,  tau = 6.800 ms,  target 11.4 V
    //             t_high = 6.8m * ln(7.4/3.4) = 5.288 ms
    //   discharge R23 200K,  tau = 200.0 ms,  target 0 V
    //             t_low  = 200m * ln(8/4)     = 138.629 ms
    //   period 143.918 ms -> 6.9484 Hz, duty 3.675 %
    //
    // The extreme asymmetry is the point: a fast rise and a slow fall is what
    // makes the engine a lumpy putt rather than a hum.
    // ---------------------------------------------------------------
    // Declared at 32 bits, not 64: both fit in ~25 bits, and a DSP-block
    // multiplier is sized off the operand width Verilog presents to `*`.
    // See docs/audio-rtl-design.md, "DSP block budget".
    localparam signed [31:0] A_555_CH_Q24  = 32'sd16725893;  // tau 6.800 ms  (+0.0006%)
    localparam signed [31:0] B_555_CH_Q24  = 32'sd51323;
    localparam signed [31:0] A_555_DIS_Q24 = 32'sd16775468;  // tau 199.95 ms (-0.024%)

    localparam signed [39:0] V_CHG_TARGET = 40'sd191260262;  // 11.4 V * 2^24
    localparam signed [39:0] TH_HI_555    = 40'sd134217728;  //  8.0 V * 2^24
    localparam signed [39:0] TH_LO_555    = 40'sd67108864;   //  4.0 V * 2^24
    localparam signed [39:0] V_TWELVE     = 40'sd201326592;  // 12.0 V * 2^24

    logic signed [39:0] v_c12;
    logic               c12_charging;

    wire signed [63:0] c12_chg_sum = A_555_CH_Q24 * v_c12
                                   + B_555_CH_Q24 * V_CHG_TARGET
                                   + 64'sd8388608;
    wire signed [63:0] c12_dis_sum = A_555_DIS_Q24 * v_c12 + 64'sd8388608;

    wire signed [39:0] v_c12_next = c12_charging ? 40'(c12_chg_sum >>> 24)
                                                 : 40'(c12_dis_sum >>> 24);

    wire c12_charging_next = c12_charging ? !(v_c12 >= TH_HI_555)
                                          :  (v_c12 <= TH_LO_555);

    // ---------------------------------------------------------------
    // Stage 2: the ACC0-3 level ladder.
    //
    // The four IC9 4066 inputs are tied to +12 V -- "MY SHIP" is the name of
    // the block on the sheet, not a signal. Each enabled section puts its
    // resistor from 12 V onto a common node loaded by R22 10 K to ground and
    // smoothed by C11 33 uF, so this is a PARALLEL-CONDUCTANCE ladder, not a
    // binary DAC:
    //     ACC0 R20 82K   ACC1 R21 30K   ACC2 R18 16K   ACC3 R19 2K
    //
    // ACC3's 2 K swamps the other three: every code from 1000 up is within 3%
    // of the top step. And C11/R22 makes every change GLIDE over 47-330 ms
    // rather than step, faster at high throttle because the selected
    // resistance is lower. Full derivation and the whole 16-row table are in
    // the design doc.
    //
    // UNLIKE every other one-pole update in this design (one multiply, one
    // constant term), this leaky integrator has TWO live multiplies summed in
    // the same step -- acc_a*v_acc AND acc_b*acc_target, both operands
    // register-fed, neither foldable to a constant. Timed as a single
    // combinational cycle (as first written) that pair puts a Cyclone V build
    // ~140 ns over the 25 ns clk_sys budget -- see the timing-closure note at
    // the top of this file. Split across three clk_sys cycles instead of one:
    // one multiply per cycle is the same budget every other channel's
    // one-pole filters already run at, and 3 extra clk_sys ticks is nothing
    // against the 832-tick sample period.
    // ---------------------------------------------------------------
    localparam logic signed [39:0] ACC_V_LUT [0:15] = '{
        40'sd0,         40'sd21883325,  40'sd50331648,  40'sd62984856,
        40'sd77433305,  40'sd86082051,  40'sd98521524,  40'sd104548201,
        40'sd167772160, 40'sd168440575, 40'sd169538183, 40'sd170138719,
        40'sd170937672, 40'sd171486953, 40'sd172393429, 40'sd172891776
    };

    localparam logic signed [31:0] ACC_A_LUT [0:15] = '{
        32'sd16776157, 32'sd16776028, 32'sd16775804, 32'sd16775675,
        32'sd16775495, 32'sd16775366, 32'sd16775142, 32'sd16775013,
        32'sd16770862, 32'sd16770733, 32'sd16770509, 32'sd16770380,
        32'sd16770200, 32'sd16770071, 32'sd16769847, 32'sd16769718
    };

    logic signed [39:0] v_acc;

    wire signed [39:0] acc_target = ACC_V_LUT[acc];
    wire signed [31:0] acc_a      = ACC_A_LUT[acc];
    wire signed [31:0] acc_b      = 32'sd16777216 - acc_a;

    // Glide pipeline, one multiply per clk_sys cycle:
    //   cyc 0 (every clk): form the two products
    //   cyc 1: add them
    //   cyc 2: shift down to Q24 -- this is v_acc_next, latched into v_acc at
    //          the NEXT sample_ce (which is guaranteed at least 829 clk_sys
    //          cycles away, since sample_ce itself only just fired to get here)
    logic signed [63:0] acc_prod_a, acc_prod_b;
    logic signed [63:0] acc_sum_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_prod_a <= '0;
            acc_prod_b <= '0;
            acc_sum_r  <= '0;
        end else begin
            acc_prod_a <= acc_a * v_acc;
            acc_prod_b <= acc_b * acc_target + 64'sd8388608;
            acc_sum_r  <= acc_prod_a + acc_prod_b;
        end
    end

    wire signed [39:0] v_acc_next = 40'(acc_sum_r >>> 24);

    // ---------------------------------------------------------------
    // Stage 3: the three VCOs. Each takes Vs/2 because that is where its
    // 51K/51K divider (to TRUE GROUND, not to the 6 V rail) puts the
    // integrator's virtual node.
    //
    //   Tr5: Vs = Vramp            Tr2: Vs = 12 - Vramp (IC17 sec.B, x(-1))
    //   Tr4: Vs = V_ACC
    //
    // K_UP/K_DN are volts of integrator output per clk_sys per volt of Vs/2:
    //   K_UP = (1/R_c - 1/R_in) / (C * f_clk)
    //   K_DN =  (1/R_in)        / (C * f_clk)
    // ---------------------------------------------------------------
    wire signed [39:0] vs_half_tr5 = v_c12 >>> 1;
    wire signed [39:0] vs_half_tr2 = (V_TWELVE - v_c12) >>> 1;
    wire signed [39:0] vs_half_tr4 = v_acc >>> 1;

    logic signed [39:0] vint_tr2, vint_tr4, vint_tr5;
    logic               vint_tr2_ce, vint_tr4_ce, vint_tr5_ce;

    // R59 150K / C22 0.01uF / R58 68K
    relax_vco #(.K_UP_Q40(22133960), .K_DN_Q40(18354991)) u_tr2 (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .vs_half(vs_half_tr2), .vint_avg(vint_tr2), .vint_avg_ce(vint_tr2_ce)
    );

    // R112 100K / C64 0.0022uF / R114 51K
    relax_vco #(.K_UP_Q40(120239916), .K_DN_Q40(125147668)) u_tr4 (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .vs_half(vs_half_tr4), .vint_avg(vint_tr4), .vint_avg_ce(vint_tr4_ce)
    );

    // R116 150K / C66 0.033uF / R111 56K
    relax_vco #(.K_UP_Q40(9336413), .K_DN_Q40(5562119)) u_tr5 (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .vs_half(vs_half_tr5), .vint_avg(vint_tr5), .vint_avg_ce(vint_tr5_ce)
    );

    // ---------------------------------------------------------------
    // Stage 4: coupling caps. All three triangles have a mean of exactly
    // 5.746689 V -- the midpoint of two thresholds that do not move with
    // frequency -- so these are exact DC removers in steady state and reset
    // with no transient at all.
    //
    // They are still real one-pole high-passes rather than a constant
    // subtraction for one reason: at ACC = 0000 Tr4 STOPS (Vs = 0 makes both
    // slew rates zero) and freezes wherever it stood. The real C56 bleeds that
    // arbitrary offset away over 0.22 s, leaving V2 at 2.977 V and the VCA
    // wide open. A subtraction would leave the offset there forever.
    // ---------------------------------------------------------------
    localparam signed [39:0] TRI_MEAN = 40'sd96413438;  // 5.746689 V * 2^24

    logic signed [31:0] ac_tr2, ac_tr4, ac_tr5;   // 2^20 LSB/V

    // C65 2.2uF / R118 220K, tau = 0.484 s
    //
    // sample_ce here is u_tr2's vint_avg_ce, NOT the system sample_ce: this
    // dc_block's x_in (vint_tr2) only becomes valid a few clk_sys cycles
    // after the real sample_ce fires, so it must capture on the same
    // delayed pulse relax_vco.sv used to publish that value.
    dc_block #(.A_Q24(16776494)) u_dc_tr2 (
        .clk(clk), .rst_n(rst_n), .sample_ce(vint_tr2_ce),
        .x_in(vint_tr2), .x_reset(TRI_MEAN), .y_out(ac_tr2)
    );

    // C56 2.2uF / R102 100K, tau = 0.220 s
    dc_block #(.A_Q24(16775627)) u_dc_tr4 (
        .clk(clk), .rst_n(rst_n), .sample_ce(vint_tr4_ce),
        .x_in(vint_tr4), .x_reset(TRI_MEAN), .y_out(ac_tr4)
    );

    // C59 2.2uF / R120 220K, tau = 0.484 s
    dc_block #(.A_Q24(16776494)) u_dc_tr5 (
        .clk(clk), .rst_n(rst_n), .sample_ce(vint_tr5_ce),
        .x_in(vint_tr5), .x_reset(TRI_MEAN), .y_out(ac_tr5)
    );

    // ---------------------------------------------------------------
    // Stages 5-8: audio sum -> VCA control leg -> MB4391 lookup -> VCA
    // multiply -> SHIP ON gate -> IC28 output gain -> rail clip.
    //
    // TIMING-CLOSURE NOTE. As first written this whole tail (five serial
    // 64-bit multiplies: IC26's gain, IC22 sec.C's control gain, the MB4391
    // LUT's interpolation, the VCA multiply itself, and IC28's output gain)
    // was pure combinational logic between one sample_ce edge and the next,
    // registered only once at the very end. A real Quartus build of this
    // exact RTL came back with clk_sys (39.935 MHz, 25.04 ns period) missing
    // setup by -142 ns on its worst path and -17.6 us of total negative slack
    // -- Fmax on that domain restricted to 5.98 MHz. Verilator cannot show
    // this: it evaluates a combinational cloud to its final value regardless
    // of depth, so every scenario WAV and the full-game sim both sound
    // correct while a real board latches whatever the flip-flops caught
    // mid-settle -- which is what "solid static" is. SHIP has by far the
    // longest chain of any channel (three VCOs feeding a 5-multiply serial
    // tail vs. one or two multiplies elsewhere), which is why it was the
    // worst-hit rather than merely mistuned.
    //
    // Fix: spread the tail over multiple clk_sys cycles, one multiply (or
    // one cheap add/mux) per register-to-register hop, exactly the budget
    // every other channel's one-pole filters already keep to. There are 832
    // clk_sys cycles per audio sample and this pipeline is 5 deep, so the
    // extra latency is inaudible and every intermediate register can simply
    // free-run on `clk` -- the upstream values it is reading are already
    // stable for hundreds of cycles either side of any one sample boundary.
    // ---------------------------------------------------------------

    // IC26 sec.C, the audio summing amp -- R118/R120 both 220 K into an R119
    // 30 K feedback with + at the 6 V rail: both oscillators get the same
    // -30/220 = -0.136364. Peak when they align is +/-3.546 V * 0.136364 =
    // +/-0.4836 V. There is NO input attenuator ahead of the VCA here -- SHIP
    // is the only channel without one.
    localparam signed [31:0] IC26_GAIN_Q24 = -32'sd2287697;   // -30/220

    // IC22 sec.C, the VCA control leg. Inverting, R102 100 K in, R103 51 K
    // feedback, + at 12 * 33/(100+33) = 2.977444 V from R106/R104 with C57
    // 33 uF decoupling -- the same reference FIRE uses.
    //   V2 = 2.977444 - 0.51 * Vtr4_ac,   Vtr4_ac = +/-1.773179 V
    //      -> V2 sweeps 2.0731 .. 3.8818 V
    // Against the MC3340 curve that is fully open (+13 dB) below 3.1 V and
    // about 35 dB down at 3.88 V, open for 56.8% of the voltage swing -- a
    // deep asymmetric CHOP at Tr4's frequency, a ring modulator in all but
    // name. Its rate tracks throttle; its depth does not move at all.
    localparam signed [31:0] CTRL_GAIN_Q24 = -32'sd8556380;  // -51/100
    localparam signed [31:0] VREF_SCALED   =  32'sd3122076;  // 2.977444 V * 2^20

    // Pipe stage 0 (every clk): form the audio sum, the two multiplies feeding
    // it and V2 are independent so they share a stage.
    logic signed [31:0] p0_tri_sum;
    logic signed [63:0] p0_vca_in_prod, p0_v2_prod;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            p0_tri_sum     <= '0;
            p0_vca_in_prod <= '0;
            p0_v2_prod     <= '0;
        end else begin
            p0_tri_sum     <= ac_tr2 + ac_tr5;
            p0_vca_in_prod <= IC26_GAIN_Q24 * (ac_tr2 + ac_tr5) + 64'sd8388608;
            p0_v2_prod     <= CTRL_GAIN_Q24 * ac_tr4 + 64'sd8388608;
        end
    end

    // Pipe stage 1: shift both products down to their working scales.
    logic signed [31:0] p1_vca_in, p1_v2;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            p1_vca_in <= '0;
            p1_v2     <= VREF_SCALED;
        end else begin
            p1_vca_in <= 32'(p0_vca_in_prod >>> 24);
            p1_v2     <= VREF_SCALED + 32'(p0_v2_prod >>> 24);
        end
    end

    // ---------------------------------------------------------------
    // IC24 MB4391 (= two MC3340s). Identical table, indexing and
    // interpolation as hit_chan.sv / rebound_chan.sv -- 65 points, V2 =
    // 2.0..6.0 V step 0.0625 V, gain in Q0.16 -- copied verbatim. C68 680 pF
    // on RO is negligible at audio rates and modelled as a wire.
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

    localparam signed [31:0] V2_MIN_SCALED = 32'sd2097152;      // 2.0V * 2^20
    localparam signed [31:0] V2_MAX_SCALED = 32'sd6291455;      // 6.0V * 2^20 - 1

    // NOTE: a Verilog bit-select like `signal[47:16]` is ALWAYS UNSIGNED, even
    // when `signal` itself is declared signed -- caught by instrumenting
    // fire_chan.sv's identical VCA path and comparing against a hand trace,
    // not visible from the RTL alone (see fire_chan.sv's header note on this
    // function). Here `gain_interp_prod[47:16]` below is safe only because it
    // feeds straight into a signed addition/assignment with no intervening
    // `>>>` or width cast of its own -- if a future edit inserts one, route
    // the bit-select through its own signed-declared wire first.
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
            gain_interp_prod = ($signed({1'b0, gain_hi}) - $signed({1'b0, gain_lo})) * $signed({1'b0, lut_frac});
            vca_lut_lookup = 32'($signed({1'b0, gain_lo}) + gain_interp_prod[47:16]);
        end
    endfunction

    // Pipe stage 2: the LUT read + interpolation multiply (one multiply,
    // inside the function), carrying vca_in forward alongside it.
    logic signed [31:0] p2_vca_in, p2_vca_gain;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            p2_vca_in   <= '0;
            p2_vca_gain <= '0;
        end else begin
            p2_vca_in   <= p1_vca_in;
            p2_vca_gain <= vca_lut_lookup(p1_v2);
        end
    end

    // Pipe stage 3: the VCA multiply itself.
    //
    // NOTE: a bare multiply feeding straight into `>>>` with no other wide
    // operand in the same expression is NOT context-widened by the eventual
    // narrow assignment target the way a direct `wire signed[63:0] x = a*b;`
    // is -- this was a real bug caught in rebound_chan.sv/fire_chan.sv (see
    // their header notes) that silently truncated the product before the
    // shift. The `+ 64'sd32768` rounding term below is what keeps this line
    // safe: it is a 64-bit operand in the SAME expression as the multiply, so
    // it forces the whole sum (multiply included) to be evaluated at 64 bits
    // before the `>>>` and the final `32'(...)` cast narrow it. Don't drop
    // that term, or split the multiply out into its own line, without first
    // re-declaring it through an explicitly-wide wire.
    logic signed [31:0] p3_vca_out;

    always_ff @(posedge clk) begin
        if (!rst_n) p3_vca_out <= '0;
        else        p3_vca_out <= 32'((p2_vca_in * p2_vca_gain + 64'sd32768) >>> 16);
    end

    // ---------------------------------------------------------------
    // IC10 4066 gate and IC28 output amp.
    //
    // SHIP ON is an active-high LEVEL, not an edge, and the 4066 is a hard
    // gate with no ramp -- so the real board clicks when it switches. C10 and
    // C70 would soften that; they are not modelled, consistently with every
    // other channel's coupling caps. With the switch open the node is held at
    // the 6 V rail through R124 into IC28's virtual ground, i.e. AC zero.
    // ---------------------------------------------------------------
    localparam signed [31:0] OUT_GAIN_Q16 = -32'sd144179;   // -R125/R124 = -2.200

    wire signed [31:0] p3_gated = ship_on ? p3_vca_out : 32'sd0;

    // Pipe stage 4: IC28's output-gain multiply.
    logic signed [31:0] p4_out_20;

    always_ff @(posedge clk) begin
        if (!rst_n) p4_out_20 <= '0;
        else        p4_out_20 <= 32'((OUT_GAIN_Q16 * p3_gated + 64'sd32768) >>> 16);
    end

    // 2^20 -> 4096 LSB/V, rounded (cheap -- shares stage 4's register hop)
    wire signed [31:0] mix_full = (p4_out_20 + 32'sd128) >>> 8;

    // IC28 OUTPUT RAILS -- a real clipping mechanism, not a format guard. See
    // docs/audio-rtl-design.md, "Op-amp output rails". Predicted SHIP peak is
    // 0.4836 * 4.4668 * 2.200 = 4.752 V, so SHIP just touches RAIL_HI when the
    // two oscillators align and sits under it the rest of the time.
    localparam signed [31:0] RAIL_HI = 32'sd18432;   // +4.50 V * 4096
    localparam signed [31:0] RAIL_LO = -32'sd24576;  // -6.00 V * 4096

    wire signed [15:0] mix_sat =
        (mix_full > RAIL_HI) ? RAIL_HI[15:0] :
        (mix_full < RAIL_LO) ? RAIL_LO[15:0] :
        mix_full[15:0];

    // ship_mix free-runs on `clk` like the rest of this pipeline rather than
    // waiting for sample_ce: by the time it is next read (at the following
    // sample_ce, at least 826 clk_sys cycles after this one) the ~6-cycle
    // pipeline above has long since settled to the steady-state value for the
    // CURRENT sample. Gating it on sample_ce would only recreate a version of
    // the exact timing hazard this rework removes -- collapsing five
    // multiplies' worth of settling time into the single cycle sample_ce is
    // asserted on.
    always_ff @(posedge clk) begin
        if (!rst_n) ship_mix <= 16'sd0;
        else        ship_mix <= mix_sat;
    end

    // v_c12 / c12_charging / v_acc remain sample_ce-gated: they are the
    // recursive one-pole states themselves (see the pipelines above that feed
    // v_acc_next), and must only advance once per audio sample.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            v_c12        <= 40'sd0;
            c12_charging <= 1'b1;
            v_acc        <= 40'sd0;
        end else if (sample_ce) begin
            v_c12        <= v_c12_next;
            c12_charging <= c12_charging_next;
            v_acc        <= v_acc_next;
        end
    end

endmodule
