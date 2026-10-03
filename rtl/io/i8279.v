// Minimal Intel 8279 keyboard/display controller. Only two functions are used
// by these games: DSW1 read via the RL sensor-return lines, and 7-segment
// digit output. Digit output is cosmetic and not implemented. Any read of the
// data register returns the RL lines (DSW1), a simplification of "issue a
// sensor-RAM read command, then read data" since there is a single sensor
// source and no keyboard matrix.
//
// Register map: addr==0 -> data register, addr==1 -> command/status register.
// Read is registered (synchronous).
module i8279
(
	input  wire        clk,
	input  wire        reset,

	input  wire         cs,
	input  wire         we,
	input  wire         addr,     // 0 = data, 1 = command/status
	input  wire  [7:0]  din,
	output reg   [7:0]  dout,

	input  wire  [7:0]  rl        // DSW1, wired to the RL sensor-return lines
);

	always @(posedge clk) begin
		if (reset) begin
			dout <= 8'h00;
		end else if (cs) begin
			dout <= addr ? 8'h00 : rl;
		end
		// Command/data writes (digit output, FIFO mode) are not modeled.
	end

endmodule
