// Z80 CPU wrapper: T80 (VHDL) for real synthesis, TV80 (Verilog) for
// Verilator simulation, since Verilator cannot compile VHDL.
//
// TV80 has no CEN pin (tv80s.v ties its internal `cen` to 1 permanently), so
// under VERILATOR_SIM this wrapper derives its own divided clock and drives
// tv80s.clk directly instead. Real hardware doesn't need that: T80s takes a
// genuine clock-enable on CEN, which is the correct MiSTer-style approach and
// is what actually gets synthesized.
module cpu_z80
(
    input  wire        clk,       // core clock (39.936 MHz)
    input  wire        cen,       // Z80 clock enable (4.992 MHz strobe on clk)
    input  wire        reset_n,
    input  wire        wait_n,
    input  wire        int_n,
    input  wire        nmi_n,
    input  wire        busrq_n,
    output wire        m1_n,
    output wire        mreq_n,
    output wire        iorq_n,
    output wire        rd_n,
    output wire        wr_n,
    output wire        rfsh_n,
    output wire        halt_n,
    output wire        busak_n,
    output wire [15:0] a,
    input  wire [7:0]  di,
    output wire [7:0]  dout
);

`ifdef VERILATOR_SIM

    reg clk_z80;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) clk_z80 <= 1'b0;
        else if (cen) clk_z80 <= ~clk_z80;
    end

    tv80s cpu
    (
        .reset_n (reset_n),
        .clk     (clk_z80),
        .wait_n  (wait_n),
        .int_n   (int_n),
        .nmi_n   (nmi_n),
        .busrq_n (busrq_n),
        .m1_n    (m1_n),
        .mreq_n  (mreq_n),
        .iorq_n  (iorq_n),
        .rd_n    (rd_n),
        .wr_n    (wr_n),
        .rfsh_n  (rfsh_n),
        .halt_n  (halt_n),
        .busak_n (busak_n),
        .A       (a),
        .di      (di),
        .dout    (dout)
    );

`else

    T80s cpu
    (
        .RESET_n (reset_n),
        .CLK     (clk),
        .CEN     (cen),
        .WAIT_n  (wait_n),
        .INT_n   (int_n),
        .NMI_n   (nmi_n),
        .BUSRQ_n (busrq_n),
        .M1_n    (m1_n),
        .MREQ_n  (mreq_n),
        .IORQ_n  (iorq_n),
        .RD_n    (rd_n),
        .WR_n    (wr_n),
        .RFSH_n  (rfsh_n),
        .HALT_n  (halt_n),
        .BUSAK_n (busak_n),
        .A       (a),
        .DI      (di),
        .DO      (dout)
    );

`endif

endmodule
