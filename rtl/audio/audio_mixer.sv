// IC28 passive summing node + inverting gain stage. R138 sits in series
// into the op-amp, so the six channel resistors meet at a node that is
// NOT a virtual ground -- every channel's effective gain depends on the
// source impedance of all five others. That is why this mixer is built
// for all six channels even though only ALARM is driven in phase 1: the
// other five inputs are tied to 0 by the caller, which correctly models
// a silent channel's low-impedance 0V output. See docs/audio-rtl-design.md
// for the resistor network and the derivation of the two coefficients
// below (SHIP/FIRE/EXP/REBOUND/ALARM share one gain via 10K resistors,
// HIT has its own via a 5.1K resistor).
module audio_mixer (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic signed [15:0] ship_mix,
    input  logic signed [15:0] hit_mix,
    input  logic signed [15:0] fire_mix,
    input  logic signed [15:0] exp_mix,
    input  logic signed [15:0] rebound_mix,
    input  logic signed [15:0] alarm_mix,
    output logic signed [15:0] mix_out
);

    localparam signed [31:0] GAIN_10K = -32'sd4674;
    localparam signed [31:0] GAIN_5K1 = -32'sd9166;

    wire signed [31:0] sum_10k = $signed({{16{ship_mix[15]}}, ship_mix})
                                + $signed({{16{fire_mix[15]}}, fire_mix})
                                + $signed({{16{exp_mix[15]}}, exp_mix})
                                + $signed({{16{rebound_mix[15]}}, rebound_mix})
                                + $signed({{16{alarm_mix[15]}}, alarm_mix});

    wire signed [31:0] hit_ext = $signed({{16{hit_mix[15]}}, hit_mix});

    wire signed [63:0] prod = sum_10k * GAIN_10K + hit_ext * GAIN_5K1;

    wire signed [31:0] acc_shifted = prod[47:16];

    wire signed [15:0] mix_sat =
        (acc_shifted > 32'sd32767)  ? 16'sd32767  :
        (acc_shifted < -32'sd32768) ? -16'sd32768 :
        acc_shifted[15:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            mix_out <= 16'sd0;
        end else if (sample_ce) begin
            mix_out <= mix_sat;
        end
    end

endmodule
