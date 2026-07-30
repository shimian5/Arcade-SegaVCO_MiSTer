// Z80 CPU wrapper: TV80 (plain Verilog), used for both real synthesis and
// sim (Verilator). T80 (VHDL) has been removed -- it was never
// simulated or cross-checked against MAME even once (see
// docs/INVESTIGATION_title_logo_garbling.md's T80-vs-TV80 caveat), and the
// hardware/MAME star-region divergence this replacement was made to close
// out was consistent with exactly that untested path. A single CPU core
// means sim results are now real evidence about what the hardware runs.
//
// tv80s.v's wrapper ties its internal `cen` permanently to 1 (confirmed
// against the tv80 repo's own tb_top.v, which drives tv80s from a single
// free-running clock with no gating at all) -- it has no usable
// clock-enable input. Instantiating it directly would run the CPU at the
// full core clock rate, undivided, i.e. ~8x faster relative to video than
// intended (core_clk vs. core_clk/8). Fixed by instantiating tv80_core
// directly instead of tv80s and driving its `cen` port from this module's
// own `cen` input -- tv80_core's FSM genuinely gates its state updates on
// `cen` internally (`ClkEn = cen && ~BusAck`, tv80_core.v). The
// bus-signal-decode logic below is copied verbatim from tv80s.v (mreq_n/
// rd_n/wr_n/iorq_n derived from mcycle/tstate/intcycle_n/iorq/write/
// no_read); it runs unconditionally every `clk` edge, but since those
// inputs only change on `cen` pulses (gated inside tv80_core), the decode
// naturally holds steady between enables and needs no gating of its own.
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

    // tv80s.v with a real `cen` wired in, in place of its hardcoded
    // `assign cen = 1`. See header comment above.
    reg        mreq_n_r, iorq_n_r, rd_n_r, wr_n_r;
    wire       intcycle_n_w, no_read_w, write_w, iorq_w;
    reg [7:0]  di_reg;
    reg        ts3_d;
    wire [6:0] mcycle_w, tstate_w;

    assign mreq_n = mreq_n_r;
    assign iorq_n = iorq_n_r;
    assign rd_n   = rd_n_r;
    assign wr_n   = wr_n_r;

    tv80_core #(.Mode(0), .IOWait(1)) i_tv80_core
    (
        .cen        (cen),
        .m1_n       (m1_n),
        .iorq       (iorq_w),
        .no_read    (no_read_w),
        .write      (write_w),
        .rfsh_n     (rfsh_n),
        .halt_n     (halt_n),
        .wait_n     (wait_n),
        .int_n      (int_n),
        .nmi_n      (nmi_n),
        .reset_n    (reset_n),
        .busrq_n    (busrq_n),
        .busak_n    (busak_n),
        .clk        (clk),
        .IntE       (),
        .stop       (),
        .A          (a),
        .dinst      (di),
        .di         (di_reg),
        .dout       (dout),
        .mc         (mcycle_w),
        .ts         (tstate_w),
        .intcycle_n (intcycle_n_w)
    );

    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            rd_n_r   <= 1'b1;
            wr_n_r   <= 1'b1;
            iorq_n_r <= 1'b1;
            mreq_n_r <= 1'b1;
            di_reg   <= 8'h00;
            ts3_d    <= 1'b0;
        end else begin
            rd_n_r   <= 1'b1;
            wr_n_r   <= 1'b1;
            iorq_n_r <= 1'b1;
            mreq_n_r <= 1'b1;
            if (mcycle_w[0]) begin
                if (tstate_w[1] || (tstate_w[2] && wait_n == 1'b0)) begin
                    rd_n_r   <= ~intcycle_n_w;
                    mreq_n_r <= ~intcycle_n_w;
                    iorq_n_r <= intcycle_n_w;
                end
            end else begin
                if ((tstate_w[1] || (tstate_w[2] && wait_n == 1'b0)) && no_read_w == 1'b0 && write_w == 1'b0) begin
                    rd_n_r   <= 1'b0;
                    iorq_n_r <= ~iorq_w;
                    mreq_n_r <= iorq_w;
                end
                if ((tstate_w[1] || (tstate_w[2] && wait_n == 1'b0)) && write_w == 1'b1) begin
                    wr_n_r   <= 1'b0;
                    iorq_n_r <= ~iorq_w;
                    mreq_n_r <= iorq_w;
                end
            end
            // EXPERIMENT (root-cause confirmation, see investigation notes):
            // sample di only on the FIRST core clock of T3, which is what
            // the ungated tv80s does (there T3 is one clock). Under `cen`
            // T3 lasts 8 core clocks and this ran on all of them, so
            // last-write-wins latched di long after iorq_n_r had been
            // driven back high -- i.e. after z80_3d.v's
            // `~sub_iorq_n ? ppi0_pa : memory` mux reverted to memory.
            if (tstate_w[2] && !ts3_d && wait_n == 1'b1 && !write_w && !no_read_w)
                di_reg <= di;
            ts3_d <= tstate_w[2];
        end
    end

endmodule
