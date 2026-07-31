// Discrete audio top level. All six channels are built. PPI1 port A/B carry
// every trigger, plus the shared data nibble and the two latch strobes.
// See docs/audio-rtl-design.md.
//
// GAME ON global mute (ppi1_pb[7]) is deliberately NOT implemented in
// phase 1 -- its muting path (which stage of the analog chain it actually
// gates) has not been traced yet. Do not wire it up on a guess.
module audio_top (
    input  logic               clk,
    input  logic               rst_n,
    input  logic         [7:0] ppi1_pa,
    input  logic         [7:0] ppi1_pb,
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic               sample_ce,
    // Per-channel taps, ahead of the mixer. Purely for the Verilator bench:
    // they make it possible to tell a channel saturating internally from the
    // master stage clipping, which is otherwise indistinguishable at audio_l.
    // Leave unconnected in the core; they synthesise away.
    output logic signed [15:0] dbg_alarm_mix,
    output logic signed [15:0] dbg_fire_mix,
    output logic signed [15:0] dbg_exp_mix,
    output logic signed [15:0] dbg_hit_mix,
    output logic signed [15:0] dbg_rebound_mix,
    output logic signed [15:0] dbg_ship_mix
);

    // VR1 master volume -- a real 20 K panel pot, so this is authentic
    // hardware rather than a fudge, but its SETTING is the one number in the
    // whole design chosen by taste. Now settled, all six channels being built.
    //
    // The calibration case is scenario 20, the actual gameplay pile-up: the
    // engine held under alarms with a laser and hits over the top. SHIP is the
    // only CONTINUOUS channel, so it -- not scenario 14 -- sets the ceiling.
    // Measured mix_out peak there is 5417 LSB, so
    //
    //   256 (x16)  scenario 10 clipped                    (phase 2 value)
    //   128 (x8)   scenario 20 clips hard at 32767        (phase 5 value)
    //    96 (x6)   32502 -- under, but with 0.07 dB spare, which is nothing
    //    80 (x5)   27085 = -1.66 dBFS                     <- chosen
    //
    // Note what is deliberately NOT budgeted for: all six channels railed in
    // the same sample and the same direction sums to about 10011 at IC28 and
    // would clip at any setting above x3.3. EXP and REBOUND both pinned while
    // HIT is also pinned is not a state the game produces, and designing for
    // it would cost 4 dB of level across every normal sound.
    parameter int MASTER_VOL = 80;

    // ---------------------------------------------------------------
    // Sample-rate generator: clk_sys / 832 = 47,999.4 Hz
    // ---------------------------------------------------------------
    localparam int DIV_W = $clog2(832);
    logic [DIV_W-1:0] div_cnt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            div_cnt   <= '0;
            sample_ce <= 1'b0;
        end else begin
            if (div_cnt == DIV_W'(831)) begin
                div_cnt   <= '0;
                sample_ce <= 1'b1;
            end else begin
                div_cnt   <= div_cnt + 1'b1;
                sample_ce <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------------
    // PPI1 taps: bit3=/ALARM3 ... bit0=/ALARM0
    // ---------------------------------------------------------------
    wire [3:0] alarm_n = {ppi1_pb[1], ppi1_pb[0], ppi1_pa[7], ppi1_pa[6]};

    logic signed [15:0] alarm_mix;
    logic                alarm_node;

    alarm_chan u_alarm (
        .clk        (clk),
        .rst_n      (rst_n),
        .alarm_n    (alarm_n),
        .sample_ce  (sample_ce),
        .alarm_mix  (alarm_mix),
        .node       (alarm_node)
    );

    // ---------------------------------------------------------------
    // NOISE (MM5837) and FIRE (laser). /FIRE is ppi1_pb[2].
    // ---------------------------------------------------------------
    logic signed [15:0] noise_a, noise_b;

    noise_mm5837 u_noise (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_ce  (sample_ce),
        .noise_a    (noise_a),
        .noise_b    (noise_b)
    );

    wire fire_n = ppi1_pb[2];

    logic signed [15:0] fire_mix;

    fire_chan u_fire (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_ce  (sample_ce),
        .fire_n     (fire_n),
        .noise_a    (noise_a),
        .fire_mix   (fire_mix)
    );

    // ---------------------------------------------------------------
    // EXP (crack + rumble). /EXP is ppi1_pb[3].
    // ---------------------------------------------------------------
    wire exp_n = ppi1_pb[3];

    logic signed [15:0] exp_mix;

    exp_chan u_exp (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_ce  (sample_ce),
        .exp_n      (exp_n),
        .noise_b    (noise_b),
        .exp_mix    (exp_mix)
    );

    // ---------------------------------------------------------------
    // HIT. /HIT is ppi1_pb[4].
    //
    // HIT DIS0-2 is not a direct signal: it is latched on-board by IC2, a
    // 4175B quad D flip-flop, from the shared 4-bit data nibble on port A
    // bits 0-3, strobed by the RISING edge of port A bit 4. (IC6 latches
    // ACC0-3 from the same nibble on bit 5; SHIP will need that one.) IC2
    // ignores D3, so only bits 2:0 are captured. See the connector pinout
    // and CPU-side latch bits in docs/hardware-audio.md.
    // ---------------------------------------------------------------
    wire hit_n = ppi1_pb[4];

    logic [2:0] hit_dis;
    logic       hit_dis_clk_d;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hit_dis       <= 3'd0;
            // Reset the strobe history to the CURRENT level, never to a
            // constant. The port idles HIGH (8255 reset -> inputs, RA pull-ups),
            // so a hardcoded 0 would manufacture a rising edge on the first
            // clock out of reset and latch whatever happened to be on the
            // nibble. Exactly the ttl_74123 `a_n_d` bug written up under
            // "Phase 3 -- EXP" in docs/audio-rtl-design.md.
            hit_dis_clk_d <= ppi1_pa[4];
        end else begin
            hit_dis_clk_d <= ppi1_pa[4];
            if (!hit_dis_clk_d && ppi1_pa[4])   // rising edge strobes IC2
                hit_dis <= ppi1_pa[2:0];
        end
    end

    logic signed [15:0] hit_mix;

    hit_chan u_hit (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_ce  (sample_ce),
        .hit_n      (hit_n),
        .hit_dis    (hit_dis),
        .noise_b    (noise_b),
        .hit_mix    (hit_mix)
    );

    // ---------------------------------------------------------------
    // REBOUND. /REBOUND is ppi1_pb[5].
    // ---------------------------------------------------------------
    wire rebound_n = ppi1_pb[5];

    logic signed [15:0] rebound_mix;

    rebound_chan u_rebound (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_ce   (sample_ce),
        .rebound_n   (rebound_n),
        .noise_a     (noise_a),
        .rebound_mix (rebound_mix)
    );

    // ---------------------------------------------------------------
    // SHIP. SHIP ON is ppi1_pb[6] -- an active-high LEVEL, not an edge.
    //
    // ACC0-3 is latched on-board by IC6, a 4175B quad D flip-flop, from the
    // same shared port-A nibble HIT DIS uses, but strobed by the rising edge
    // of port A bit 5 rather than bit 4. Unlike IC2, IC6 uses all four bits.
    // ---------------------------------------------------------------
    wire ship_on = ppi1_pb[6];

    logic [3:0] acc;
    logic       acc_clk_d;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc       <= 4'd0;
            acc_clk_d <= ppi1_pa[5];   // see the note on hit_dis_clk_d above
        end else begin
            acc_clk_d <= ppi1_pa[5];
            if (!acc_clk_d && ppi1_pa[5])   // rising edge strobes IC6
                acc <= ppi1_pa[3:0];
        end
    end

    logic signed [15:0] ship_mix;

    ship_chan u_ship (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_ce  (sample_ce),
        .ship_on    (ship_on),
        .acc        (acc),
        .ship_mix   (ship_mix)
    );

    assign dbg_alarm_mix = alarm_mix;
    assign dbg_fire_mix  = fire_mix;
    assign dbg_exp_mix   = exp_mix;
    assign dbg_hit_mix   = hit_mix;
    assign dbg_rebound_mix = rebound_mix;
    assign dbg_ship_mix    = ship_mix;

    logic signed [15:0] mix_out;

    audio_mixer u_mixer (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_ce   (sample_ce),
        .ship_mix    (ship_mix),
        .hit_mix     (hit_mix),
        .fire_mix    (fire_mix),
        .exp_mix     (exp_mix),
        .rebound_mix (rebound_mix),
        .alarm_mix   (alarm_mix),
        .mix_out     (mix_out)
    );

    // ---------------------------------------------------------------
    // Output stage: VR1 master volume pot, MASTER_VOL is a placeholder
    // (see docs/audio-rtl-design.md, "Output stage")
    // ---------------------------------------------------------------
    wire signed [31:0] vol_prod = 32'(mix_out) * 32'(MASTER_VOL);
    wire signed [31:0] vol_shifted = vol_prod >>> 4;

    wire signed [15:0] vol_sat =
        (vol_shifted > 32'sd32767)  ? 16'sd32767  :
        (vol_shifted < -32'sd32768) ? -16'sd32768 :
        vol_shifted[15:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            audio_l <= 16'sd0;
            audio_r <= 16'sd0;
        end else begin
            audio_l <= vol_sat;
            audio_r <= vol_sat;
        end
    end

endmodule
