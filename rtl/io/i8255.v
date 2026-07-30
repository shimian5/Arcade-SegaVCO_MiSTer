// Generic Intel 8255 PPI: mode 0 (plain latched I/O) plus the group-A
// mode-2 output handshake. See docs/PLAN.md "Support chips".
//
// Register map (2-bit address, matches the CPU's low address bits at the
// chip's base offset): 0=port A, 1=port B, 2=port C, 3=control word.
//
// Mode-0 direction is configurable per the control word, split the same way
// real 8255 hardware splits it: port A and port C-upper share "group A"'s
// direction bit, port B and port C-lower share "group B"'s. Turbo's PPIs
// only ever use mode 0 as all-output.
//
// MODE 2 (group A, strobed bidirectional) is required by Buck Rogers' PPI0:
// it is the entire main-CPU -> sub-CPU command channel. The game writes
// control word 0xC0 once at boot (D6=1 selects mode 2 regardless of D5),
// after which port C upper stops being data and becomes handshake pins:
//
//   PC7 = /OBF  output -- driven LOW by the chip on the trailing edge of a
//                         port A write, driven HIGH again by /ACK.
//   PC6 = /ACK  input  -- a low pulse marks the peripheral as having taken
//                         the byte, and (on real silicon) gates port A onto
//                         the peripheral-side bus.
//   PC5 = IBF, PC4 = /STB, PC3 = INTR -- the input half of mode 2, unused
//                         and physically unconnected on this board.
//
// On the Buck Rogers CPU board (834-5120 sheet 5) IC90's PC7 runs straight
// to the sub Z80's /INT and PC6 comes straight from its /IOREQ, with no
// gating in between, and PC5/PC4/PC3 are left open -- so the command write
// *is* the interrupt, and the sub CPU's own /IORQ (interrupt-acknowledge
// cycle first, then the ISR's IN) clears it. There is no software
// /INT-clear step anywhere. See docs/INVESTIGATION_starfield_2x_speed.md.
//
// Only the output half of mode 2 is modelled; nothing in this project
// drives the peripheral-to-CPU (/STB / IBF) direction.
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

    // Group-A mode-2 /ACK input (PC6). Active low; ignored unless the
    // control word selected mode 2. Tie high when unused.
    input  wire         ack_n,

    // output latches (last value written while programmed as output;
    // per real 8255 behavior, still readable back even if reprogrammed).
    // `pc` is the port C PIN vector, so in mode 2 pc[7] is /OBF rather than
    // a data bit -- consumers wiring pc[7] to a peripheral /INT get the
    // handshake automatically.
    output reg   [7:0]  pa,
    output reg   [7:0]  pb,
    output wire  [7:0]  pc,

    // one-cycle strobes, pulsed the cycle a port is written while
    // configured as output -- lets the caller react to specific writes
    // (e.g. Buck Rogers' PPI0 port C sub-CPU handshake) without polling
    output reg          pa_wr,
    output reg          pb_wr,
    output reg          pc_wr
);

    // direction bits: 1 = input, 0 = output (matches 8255 control-word polarity)
    reg dir_a, dir_b, dir_c_hi, dir_c_lo;

    // group A mode 2 (control word D6), and its /OBF flip-flop
    reg mode2_a;
    reg obf_n;

    // port C data latch; `pc` below is the pin vector derived from it
    reg [7:0] pc_lat;

    // In mode 2 the upper port C bits are handshake pins, not the data
    // latch. PC5/PC4/PC3 (IBF, /STB, INTR) are unconnected on the Buck
    // Rogers board and nothing reads them; they carry their idle levels.
    assign pc = mode2_a ? {obf_n, ack_n, 1'b0, 1'b1, 1'b0, pc_lat[2:0]}
                        : pc_lat;

    // edge detectors: /ACK falling, and the trailing edge of a port A write
    // (a real 8255 clears /OBF on the trailing edge of /WR)
    reg ack_n_d;
    reg pa_cs_d;
    wire pa_cs = cs && we && (addr == 2'd0);

    always @(posedge clk) begin
        pa_wr <= 1'b0;
        pb_wr <= 1'b0;
        pc_wr <= 1'b0;

        ack_n_d <= ack_n;
        pa_cs_d <= pa_cs;

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
            mode2_a  <= 1'b0;
            obf_n    <= 1'b1;
            pa       <= 8'hFF;
            pb       <= 8'hFF;
            pc_lat   <= 8'hFF;
        end else begin
            // ---------------------------------------------------------
            // Group-A mode-2 output handshake. Independent of any CPU
            // access: /ACK can arrive at any time.
            // ---------------------------------------------------------
            if (mode2_a) begin
                if (ack_n_d && !ack_n)      obf_n <= 1'b1;  // taken
                else if (pa_cs_d && !pa_cs) obf_n <= 1'b0;  // byte pending
            end

        if (cs && we) begin
            case (addr)
                2'd0: begin pa <= din; pa_wr <= 1'b1; end
                2'd1: begin pb <= din; pb_wr <= 1'b1; end
                2'd2: begin
                    // In mode 2 only the group-B half of port C is data;
                    // bits 7-3 are group-A handshake pins and a data write
                    // must not disturb them. (Buck Rogers relies on this:
                    // it writes 0xA0/0xA1/0xA2 to set FCHG0-2 in PC2-0,
                    // and those bytes have bit 7 = 1, which under a mode-0
                    // model would wrongly deassert the sub CPU's /INT.)
                    if (mode2_a) pc_lat[2:0] <= din[2:0];
                    else         pc_lat      <= din;
                    pc_wr <= 1'b1;
                end
                2'd3: begin
                    if (din[7]) begin
                        // mode-set control word. D6 selects group A mode 2
                        // (mode 2 is chosen by D6 alone, D5 is don't-care);
                        // D6=0 leaves group A in mode 0 here -- mode 1 is
                        // not modelled and no game in this core uses it.
                        // A mode-set command also initialises the
                        // handshake flags, so /OBF starts inactive.
                        mode2_a  <= din[6];
                        obf_n    <= 1'b1;
                        dir_a    <= din[4];
                        dir_c_hi <= din[3];
                        dir_b    <= din[1];
                        dir_c_lo <= din[0];
                    end else begin
                        // BSR (bit set/reset) mode: D3-D1 select one of
                        // port C's 8 output bits, D0 sets(1)/clears(0) it.
                        // This is the standard real-8255 way to toggle a
                        // single control line without a read-modify-write
                        // of the whole port. In mode 2, BSR on bits 7-3
                        // addresses the INTE flip-flops rather than the
                        // pins, so it must not drive the handshake nets.
                        if (!(mode2_a && din[3:1] >= 3'd3))
                            pc_lat[din[3:1]] <= din[0];
                        pc_wr <= 1'b1;
                    end
                end
            endcase
        end
        end

        // registered read
        if (cs) begin
            case (addr)
                2'd0: dout <= dir_a ? in_a : pa;
                2'd1: dout <= dir_b ? in_b : pb;
                // Port C readback returns the pin vector, so in mode 2 the
                // main CPU sees /OBF on bit 7 -- which is exactly what Buck
                // Rogers' command loop polls.
                2'd2: dout <= mode2_a ? pc :
                              {dir_c_hi ? in_c[7:4] : pc_lat[7:4],
                               dir_c_lo ? in_c[3:0] : pc_lat[3:0]};
                2'd3: dout <= 8'hFF;
            endcase
        end
    end

endmodule
