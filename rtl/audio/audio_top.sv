// Discrete audio top level. All six channels are built. PPI1 port A/B carry
// every trigger, plus the shared data nibble and the two latch strobes.
// See docs/audio-rtl-design.md.
//
// GAME ON (ppi1_pb[7]) IS now implemented, and the path it gates is traced:
// it drives IC5, a 7417 open-collector buffer, whose output is the LA4460's
// DC-mute pin 6. See mute_ctl.sv. The output stage is the real amplifier
// (la4460.sv) rather than a scalar volume constant.
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
    output logic signed [15:0] dbg_ship_mix,
    // Mute state, for the bench. Synthesises away when unconnected.
    output logic               dbg_dc_mute
);

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
    logic                exp_mul_req_valid, exp_mul_req_ready;
    logic signed [63:0]  exp_mul_req_a, exp_mul_req_b;
    logic [6:0]          exp_mul_req_a_width, exp_mul_req_b_width;
    logic [7:0]          exp_mul_req_tag;
    logic                exp_mul_rsp_valid;
    logic signed [127:0] exp_mul_rsp_product;
    logic [7:0]          exp_mul_rsp_tag;

    // Lane 1 is dedicated to EXP for this migration step.  The same tagged
    // interface as lane 0 keeps the clients ready for a later arbiter.
    shared_mul_lane u_shared_mul1 (
        .clk         (clk),
        .rst_n       (rst_n),
        .req_valid   (exp_mul_req_valid),
        .req_ready   (exp_mul_req_ready),
        .req_a       (exp_mul_req_a),
        .req_b       (exp_mul_req_b),
        .req_a_width (exp_mul_req_a_width),
        .req_b_width (exp_mul_req_b_width),
        .req_tag     (exp_mul_req_tag),
        .rsp_valid   (exp_mul_rsp_valid),
        .rsp_product (exp_mul_rsp_product),
        .rsp_tag     (exp_mul_rsp_tag)
    );

    exp_chan u_exp (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_ce  (sample_ce),
        .exp_n      (exp_n),
        .noise_b    (noise_b),
        .exp_mix    (exp_mix),
        .mul_req_valid   (exp_mul_req_valid),
        .mul_req_ready   (exp_mul_req_ready),
        .mul_req_a       (exp_mul_req_a),
        .mul_req_b       (exp_mul_req_b),
        .mul_req_a_width (exp_mul_req_a_width),
        .mul_req_b_width (exp_mul_req_b_width),
        .mul_req_tag     (exp_mul_req_tag),
        .mul_rsp_valid   (exp_mul_rsp_valid),
        .mul_rsp_product (exp_mul_rsp_product),
        .mul_rsp_tag     (exp_mul_rsp_tag)
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
    // Output stage: the real thing. IC28's output leaves the mixer through
    // C69 / R45 / VR1 / C83 into IC27, an LA4460 BTL power amp with a fixed
    // 51 dB of gain; its DC-mute pin 6 is wire-ORed between GAME ON (via the
    // IC5 7417) and a power-on RC comparator. Both are modelled:
    //
    //   mute_ctl  ->  the pin 6 control node (mute_ctl.sv)
    //   la4460    ->  C69/C83 high-passes, the amp's own 47 Hz and 9 kHz
    //                 corners, the VR1 divider, 51 dB, and the 8.6 V clip
    //
    // What used to sit here was `MASTER_VOL`, a single scalar standing in for
    // the whole of that. It is gone: VR1's setting now lives inside la4460.sv
    // as the k = 0.100 term of OUT_GAIN_Q16, which is the only number that
    // moves when the pot is recalibrated. Do not reintroduce a second volume
    // constant at this level.
    // ---------------------------------------------------------------
    wire dc_mute;

    mute_ctl u_mute (
        .clk     (clk),
        .rst_n   (rst_n),
        .game_on (ppi1_pb[7]),   // GAME ON, active high
        .dc_mute (dc_mute)
    );

    assign dbg_dc_mute = dc_mute;

    logic signed [15:0] amp_out;

    logic                amp_mul_req_valid, amp_mul_req_ready;
    logic signed [63:0]  amp_mul_req_a, amp_mul_req_b;
    logic [6:0]          amp_mul_req_a_width, amp_mul_req_b_width;
    logic [7:0]          amp_mul_req_tag;
    logic                amp_mul_rsp_valid;
    logic signed [127:0] amp_mul_rsp_product;
    logic [7:0]          amp_mul_rsp_tag;

    shared_mul_lane u_shared_mul0 (
        .clk         (clk),
        .rst_n       (rst_n),
        .req_valid   (amp_mul_req_valid),
        .req_ready   (amp_mul_req_ready),
        .req_a       (amp_mul_req_a),
        .req_b       (amp_mul_req_b),
        .req_a_width (amp_mul_req_a_width),
        .req_b_width (amp_mul_req_b_width),
        .req_tag     (amp_mul_req_tag),
        .rsp_valid   (amp_mul_rsp_valid),
        .rsp_product (amp_mul_rsp_product),
        .rsp_tag     (amp_mul_rsp_tag)
    );

    la4460 u_amp (
        .clk       (clk),
        .rst_n     (rst_n),
        .sample_ce (sample_ce),
        .dc_mute   (dc_mute),
        .mix_in    (mix_out),
        .audio_out (amp_out),
        .mul_req_valid   (amp_mul_req_valid),
        .mul_req_ready   (amp_mul_req_ready),
        .mul_req_a       (amp_mul_req_a),
        .mul_req_b       (amp_mul_req_b),
        .mul_req_a_width (amp_mul_req_a_width),
        .mul_req_b_width (amp_mul_req_b_width),
        .mul_req_tag     (amp_mul_req_tag),
        .mul_rsp_valid   (amp_mul_rsp_valid),
        .mul_rsp_product (amp_mul_rsp_product),
        .mul_rsp_tag     (amp_mul_rsp_tag)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            audio_l <= 16'sd0;
            audio_r <= 16'sd0;
        end else begin
            audio_l <= amp_out;
            audio_r <= amp_out;
        end
    end

endmodule
