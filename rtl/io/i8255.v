// Generic Intel 8255 PPI, mode 0 only (both games in this core only ever
// use mode 0 -- plain latched I/O, no strobed/bidirectional modes). See
// docs/PLAN.md "Support chips".
//
// Register map (2-bit address, matches the CPU's low address bits at the
// chip's base offset): 0=port A, 1=port B, 2=port C, 3=control word.
//
// Mode-0 direction is configurable per the control word, split the same way
// real 8255 hardware splits it: port A and port C-upper share "group A"'s
// direction bit, port B and port C-lower share "group B"'s. Buck Rogers only
// ever programs both PPIs as all-output (no in_* callback registered in the
// MAME driver), but this module supports mixed direction for fidelity/reuse
// (e.g. Turbo's PPI3, phase 3).
//
// Read is registered (synchronous), one clk of latency -- matches the
// registered-read idiom used everywhere else in this core. The CPU holds its
// address for a full T-state (many clk cycles), so this is transparent.
module i8255
(
    input  wire        clk,
    input  wire        reset,

    input  wire         cs,
    input  wire         we,
    input  wire  [1:0]  addr,
    input  wire  [7:0]  din,
    output reg   [7:0]  dout,

    // external pin values, sampled when the corresponding group is
    // programmed as input
    input  wire  [7:0]  in_a,
    input  wire  [7:0]  in_b,
    input  wire  [7:0]  in_c,

    // output latches (last value written while programmed as output;
    // per real 8255 behavior, still readable back even if reprogrammed)
    output reg   [7:0]  pa,
    output reg   [7:0]  pb,
    output reg   [7:0]  pc,

    // one-cycle strobes, pulsed the cycle a port is written while
    // configured as output -- lets the caller react to specific writes
    // (e.g. Buck Rogers' PPI0 port C sub-CPU handshake) without polling
    output reg          pa_wr,
    output reg          pb_wr,
    output reg          pc_wr
);

    // direction bits: 1 = input, 0 = output (matches 8255 control-word polarity)
    reg dir_a, dir_b, dir_c_hi, dir_c_lo;

    always @(posedge clk) begin
        pa_wr <= 1'b0;
        pb_wr <= 1'b0;
        pc_wr <= 1'b0;

        if (reset) begin
            // Real 8255 hardware resets its control word to 0x9B (all
            // ports input mode) -- nothing drives the output pins until
            // firmware explicitly configures and writes them, so the
            // physical net sits at its idle (pulled-up) level. This
            // module models that "nothing driven yet" state as the output
            // latches idling high (0xFF, this project's standard idle-bus
            // convention) rather than 0x00: callers that tap a port's
            // output latch directly for a control line (e.g. z80_3d.v's
            // sub_int_n from PPI0 port C bit 7) need that idle level to be
            // "not asserted", not "asserted" -- getting this backwards
            // means a consumer CPU sees its interrupt line asserted from
            // the instant of reset, before the driving CPU ever touches
            // this chip.
            dir_a    <= 1'b0;
            dir_b    <= 1'b0;
            dir_c_hi <= 1'b0;
            dir_c_lo <= 1'b0;
            pa       <= 8'hFF;
            pb       <= 8'hFF;
            pc       <= 8'hFF;
        end else if (cs && we) begin
            case (addr)
                2'd0: begin pa <= din; pa_wr <= 1'b1; end
                2'd1: begin pb <= din; pb_wr <= 1'b1; end
                2'd2: begin pc <= din; pc_wr <= 1'b1; end
                2'd3: begin
                    if (din[7]) begin
                        // mode-set control word; only group A/B direction
                        // bits matter here (mode field is assumed 00 = mode 0)
                        dir_a    <= din[4];
                        dir_c_hi <= din[3];
                        dir_b    <= din[1];
                        dir_c_lo <= din[0];
                    end else begin
                        // BSR (bit set/reset) mode: D3-D1 select one of
                        // port C's 8 output bits, D0 sets(1)/clears(0) it.
                        // This is the standard real-8255 way to toggle a
                        // single control line (e.g. Buck Rogers' sub-CPU
                        // /INT on PC7) without a read-modify-write of the
                        // whole port -- required for correctness, not
                        // optional: see docs/PLAN.md phase 1c notes.
                        pc[din[3:1]] <= din[0];
                        pc_wr        <= 1'b1;
                    end
                end
            endcase
        end

        // registered read
        if (cs) begin
            case (addr)
                2'd0: dout <= dir_a ? in_a : pa;
                2'd1: dout <= dir_b ? in_b : pb;
                2'd2: dout <= {dir_c_hi ? in_c[7:4] : pc[7:4],
                                dir_c_lo ? in_c[3:0] : pc[3:0]};
                2'd3: dout <= 8'hFF;
            endcase
        end
    end

endmodule
