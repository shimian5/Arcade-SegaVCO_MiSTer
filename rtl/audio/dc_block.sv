// SHIP coupling-cap state holder.  ship_chan owns the product scheduling and
// supplies the exact rounded Q32 next-state value when its tagged MAC reply
// arrives.  This keeps all three caps behind one client interface.
module dc_block (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               commit_valid,
    input  logic signed [39:0] x_in,       // delayed average used by hp sum, Q24
    input  logic signed [39:0] x_capture,  // same delayed sample, held to commit
    input  logic signed [39:0] x_reset,    // Q24
    input  logic signed [47:0] y_next,     // Q32
    output logic signed [39:0] hp_sum,     // Q32, sign extended/truncated
    output logic signed [31:0] y_out       // Q20
);
    logic signed [47:0] x_d, y_state;
    wire signed [47:0] x_scaled = 48'(x_in) <<< 8;
    wire signed [47:0] x_captured = 48'(x_capture) <<< 8;
    wire signed [47:0] hp_sum_w = y_state + x_scaled - x_d;

    // The documented range is below 37 bits; retaining the 40-bit request
    // operand preserves the previous multiplier result bit-for-bit.
    assign hp_sum = 40'(hp_sum_w);
    assign y_out  = 32'((y_state + 48'sd2048) >>> 12);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            x_d     <= 48'(x_reset) <<< 8;
            y_state <= '0;
        end else if (commit_valid) begin
            x_d     <= x_captured;
            y_state <= y_next;
        end
    end
endmodule
