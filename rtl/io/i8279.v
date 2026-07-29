// Minimal Intel 8279 keyboard/display controller. See docs/PLAN.md "Support
// chips": only two functions of the real chip are ever used by these games,
// DSW1 read via the RL sensor-return lines and 7-segment digit output via
// scanlines_w/digit_w. Digit output is cosmetic (drives the operator-visible
// digit displays, not gameplay) and is left unimplemented here; DSW1 read is
// required for playability (it's the only path to DSW1 on this board) and is
// implemented directly: any read of the data register returns the RL lines
// (DSW1), which is a faithful simplification of "issue a read-FIFO/sensor-RAM
// command, then read the data register" since this core has only one sensor
// source and no real keyboard matrix to scan.
//
// Register map: addr==0 -> data register, addr==1 -> command/status register.
// Read is registered (synchronous), matching the idiom used throughout.
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
        // Command/data writes (digit/scanline output, FIFO mode select) are
        // not modeled -- cosmetic only, see header.
    end

endmodule
