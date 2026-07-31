// One-pole coupling-cap high-pass (a "DC block"), used three times by SHIP for
// C65/R118, C59/R120 and C56/R102. See docs/audio-rtl-design.md, "The DC blocks
// are exact, and that is worth stating".
//
//   y[n] = a * (y[n-1] + x[n] - x[n-1])
//
// Input arrives at the oscillator scale (2^24 LSB/V) and is carried internally
// at 2^32 LSB/V; the output is reduced to the house analog-tail scale
// (2^20 = 4096*256 LSB/V) that the MC3340 LUT and the rest of the channel use.
//
// The wide internal scale is the leaky-integrator STALL fix recorded under
// "Numeric formats", not coefficient precision: a leaky integrator stops
// moving once its per-step decrement falls under the rounding threshold, at
// |y| = 0.5/(1-a) STATE LSB, and only widening the state moves that. At
// a = 0.999957 the stall is 11614 LSB, which at 2^32 LSB/V is 2.7 uV -- three
// orders under one output LSB. Every shift here rounds to nearest, so a
// negative state is not biased away from zero on each step.
module dc_block #(
    parameter longint A_Q24 = 0   // exp(-1/(fs*tau)) in Q0.24
) (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic signed [39:0] x_in,     // 2^24 LSB/V
    input  logic signed [39:0] x_reset,  // steady-state input at reset, 2^24 LSB/V
    output logic signed [31:0] y_out     // 2^20 LSB/V
);

    logic signed [47:0] x_d, y_state;

    wire signed [47:0] x_scaled = 48'(x_in) <<< 8;   // 2^24 -> 2^32 LSB/V

    // |x| <= 7.52 V * 2^32 = 3.2e10 (35 bits), |y| <= 1.78 V * 2^32 = 7.6e9,
    // so |hp_sum| < 2^37 and hp_prod < 2^61.
    wire signed [63:0] hp_sum  = 64'(y_state) + 64'(x_scaled) - 64'(x_d);
    wire signed [63:0] hp_prod = 64'(A_Q24) * hp_sum + 64'sd8388608;
    wire signed [47:0] y_next  = 48'(hp_prod >>> 24);

    // 2^32 -> 2^20 LSB/V, rounded
    assign y_out = 32'((y_next + 48'sd2048) >>> 12);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Cap already charged to the source's steady-state DC -- the board
            // has been powered for seconds before the game makes a sound, and
            // all three SHIP sources sit at a constant mean. Resetting x_d to
            // zero instead would inject a full-scale step and ring for the
            // whole 0.48 s tau.
            x_d     <= 48'(x_reset) <<< 8;
            y_state <= '0;
        end else if (sample_ce) begin
            x_d     <= x_scaled;
            y_state <= y_next;
        end
    end

endmodule
