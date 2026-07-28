// Z80 CPU wrapper: T80 (VHDL) for real synthesis, TV80 (plain Verilog) for
// simulation with the open-source Verilator tool, which cannot compile VHDL.
//
// KNOWN PHASE 1a SIMPLIFICATION: TV80's tv80s.v wrapper ties its internal
// `cen` permanently to 1 (confirmed against the tv80 repo's own tb_top.v,
// which drives tv80s from a single free-running clock with no gating at
// all) -- it has no usable clock-enable input. So under VERILATOR_SIM this
// wrapper just runs tv80s at the full core clock rate, undivided. That means
// in simulation the CPU currently executes ~8x faster relative to video
// than real hardware (core_clk vs. core_clk/8) -- fine for confirming
// attract-mode VRAM writes happen at all, but wrong for phase 1b/1c's
// cycle-accurate MAME frame-diffing. Fix before then, either by driving
// tv80_core (not tv80s) directly with a real per-T-state `cen` pulse train
// (tv80_core does expose a cen port), or by giving the CPU its own
// free-running clock domain instead of a clk_sys-derived enable.
//
// T80s (real synthesis target) is unaffected: it takes a genuine
// clock-enable on CEN and needs no such workaround.
module cpu_z80
(
    input  wire        clk,       // core clock (39.936 MHz)
    input  wire        cen,       // Z80 clock enable (4.992 MHz strobe on clk) -- T80s only, see above
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

    tv80s cpu
    (
        .reset_n (reset_n),
        .clk     (clk),
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
