// Discrete audio top level. Phase 1: ALARM channel only, SHIP/HIT/FIRE/
// EXP/REBOUND tied to zero (see docs/audio-rtl-design.md, "why the mixer
// is built whole"). PPI1 port A/B carry the four /ALARMn lines.
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
    output logic signed [15:0] dbg_exp_mix
);

    parameter int MASTER_VOL = 256;

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

    assign dbg_alarm_mix = alarm_mix;
    assign dbg_fire_mix  = fire_mix;
    assign dbg_exp_mix   = exp_mix;

    logic signed [15:0] mix_out;

    audio_mixer u_mixer (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_ce   (sample_ce),
        .ship_mix    (16'sd0),
        .hit_mix     (16'sd0),
        .fire_mix    (fire_mix),
        .exp_mix     (exp_mix),
        .rebound_mix (16'sd0),
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
