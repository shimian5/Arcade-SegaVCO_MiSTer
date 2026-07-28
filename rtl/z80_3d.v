// Z80-3D system top: main CPU, memory decode, video RAM / fg tilemap.
//
// PHASE 1a SCOPE (see docs/PLAN.md): main CPU + video RAM + fg tilemap, just
// far enough that Buck Rogers' (buckrogn) attract-mode text renders. Not yet
// implemented (stubbed): sub CPU, sprite engine, PPI0/PPI1/i8279 real
// behavior, bgcolor/bitmap layers, full mixer priority chain. Stubbed reads
// return 8'hFF (idle bus / inactive switches), which is enough for the main
// CPU to run through its init + attract-mode text draw without hanging, as
// long as it doesn't block on a sub-CPU handshake before drawing text.
//
// The fg-only "tier 1" mixer path is implemented directly here (see
// mixer_buckrog.v in docs/PLAN.md) since the full mixer belongs to phase 1c;
// forebits/palette addressing follow the plan's formulas verbatim, with
// fchg (PPI0 port C bits 0-2) tied to 0 until PPI0 is wired up.
//
// MEMORY READS ARE ALL REGISTERED (synchronous), including the CPU's program
// ROM/work RAM ports, so Quartus infers real M10K block RAM instead of large
// combinational muxes. This needs no Z80 wait-state handling: cpu_a is held
// stable for the CPU's whole T-state (many core-clk cycles, since ce_z80
// only pulses once every 8), which is far longer than the 1-cycle read
// latency -- the registered output settles long before the CPU's next CEN
// sample point. The video path's registered reads (fg_tilemap + the local
// color-table/palette lookups below) form a fixed-depth pipeline instead;
// see VIDEO_PIPE_LATENCY, which delay-matches hblank/vblank/hsync/vsync/
// ce_pix so the sync bundle output stays aligned with the pixel data it
// describes.
module z80_3d
(
    input  wire        clk,             // core clock, ~39.936 MHz nominal
    input  wire        reset,

    input  wire         ioctl_download,
    input  wire         ioctl_wr,
    input  wire [24:0]  ioctl_addr,
    input  wire [7:0]   ioctl_dout,

    output wire         hblank,
    output wire         vblank,
    output wire         hsync,
    output wire         vsync,
    output wire         ce_pix,
    output wire [7:0]   video_r,
    output wire [7:0]   video_g,
    output wire [7:0]   video_b
);

    // ------------------------------------------------------------------
    // Clock enables
    // ------------------------------------------------------------------
    // Z80 CE: core_clk / 8 = 4.992 MHz
    reg [2:0] z80_div;
    wire      ce_z80 = (z80_div == 3'd0);
    always @(posedge clk) begin
        if (reset) z80_div <= 0;
        else       z80_div <= z80_div + 3'd1;
    end

    // ------------------------------------------------------------------
    // Video timing (already at 2x horizontal, per docs/PLAN.md)
    // ------------------------------------------------------------------
    wire [9:0] hpos;
    wire [8:0] vpos;
    wire       hblank_raw, vblank_raw, hsync_raw, vsync_raw;
    video_timing vtiming
    (
        .clk         (clk),
        .ce_pix      (ce_pix_int),
        .reset       (reset),
        .hpos        (hpos),
        .vpos        (vpos),
        .hblank      (hblank_raw),
        .vblank      (vblank_raw),
        .hsync       (hsync_raw),
        .vsync       (vsync_raw),
        .vblank_rise (vblank_rise)
    );

    // core_clk / 4 = 9.984 MHz pixel CE
    reg [1:0] pix_div;
    wire ce_pix_int = (pix_div == 2'd0);
    always @(posedge clk) begin
        if (reset) pix_div <= 0;
        else       pix_div <= pix_div + 2'd1;
    end

    wire vblank_rise;

    // ------------------------------------------------------------------
    // ROM download decode
    // ------------------------------------------------------------------
    wire        maincpu_we;
    wire [14:0] maincpu_wraddr;
    wire        fgtiles_we;
    wire [11:0] fgtiles_wraddr;
    wire        proms_we;
    wire [12:0] proms_wraddr;
    wire        subcpu_we, road_we, sprites_we;
    wire [12:0] subcpu_wraddr;
    wire [14:0] road_wraddr;
    wire [17:0] sprites_wraddr;
    wire [7:0]  rom_dout;

    rom_download u_download
    (
        .clk            (clk),
        .ioctl_download (ioctl_download),
        .ioctl_wr       (ioctl_wr),
        .ioctl_addr     (ioctl_addr),
        .ioctl_dout     (ioctl_dout),
        .maincpu_we     (maincpu_we),
        .maincpu_addr   (maincpu_wraddr),
        .subcpu_we      (subcpu_we),
        .subcpu_addr    (subcpu_wraddr),
        .fgtiles_we     (fgtiles_we),
        .fgtiles_addr   (fgtiles_wraddr),
        .proms_we       (proms_we),
        .proms_addr     (proms_wraddr),
        .road_we        (road_we),
        .road_addr      (road_wraddr),
        .sprites_we     (sprites_we),
        .sprites_addr   (sprites_wraddr),
        .dout           (rom_dout)
    );

    // pr-5194 (X-shift, 32B @ proms offset 0x000) forwarded into fg_tilemap
    wire        xshift_we   = proms_we && (proms_wraddr < 13'h0020);
    wire [4:0]  xshift_addr = proms_wraddr[4:0];

    // pr-5198 (char color table, 512B @ proms offset 0x500), kept local
    reg [7:0] color_table[0:511];
    wire proms_is_colortab = proms_we && (proms_wraddr >= 13'h500) && (proms_wraddr < 13'h700);
    always @(posedge clk) begin
        if (proms_is_colortab) color_table[proms_wraddr - 13'h500] <= rom_dout;
    end

    // ------------------------------------------------------------------
    // Main program ROM (32KB, 0000-7fff) -- registered read
    // ------------------------------------------------------------------
    reg [7:0] maincpu_rom[0:32767];
    reg [7:0] maincpu_dout;
    always @(posedge clk) begin
        if (maincpu_we) maincpu_rom[maincpu_wraddr] <= rom_dout;
        maincpu_dout <= maincpu_rom[cpu_a[14:0]];
    end

    // ------------------------------------------------------------------
    // Work RAM (f800-ffff, 2KB) -- registered read
    // ------------------------------------------------------------------
    reg [7:0] work_ram[0:2047];
    reg [7:0] work_ram_dout;
    always @(posedge clk) begin
        if (sel_workram && cpu_write) work_ram[cpu_a[10:0]] <= cpu_do;
        work_ram_dout <= work_ram[cpu_a[10:0]];
    end

    // ------------------------------------------------------------------
    // CPU
    // ------------------------------------------------------------------
    wire [15:0] cpu_a;
    wire [7:0]  cpu_di;
    wire [7:0]  cpu_do;
    wire        cpu_wr_n, cpu_rd_n, cpu_mreq_n, cpu_m1_n, cpu_iorq_n;
    wire        int_n;

    cpu_z80 u_cpu
    (
        .clk     (clk),
        .cen     (ce_z80),
        .reset_n (~reset),
        .wait_n  (1'b1),
        .int_n   (int_n),
        .nmi_n   (1'b1),
        .busrq_n (1'b1),
        .m1_n    (cpu_m1_n),
        .mreq_n  (cpu_mreq_n),
        .iorq_n  (cpu_iorq_n),
        .rd_n    (cpu_rd_n),
        .wr_n    (cpu_wr_n),
        .rfsh_n  (),
        .halt_n  (),
        .busak_n (),
        .a       (cpu_a),
        .di      (cpu_di),
        .dout    (cpu_do)
    );

    // VBLANK IRQ, cleared by the int-ack (M1 & IORQ) cycle. No interrupt
    // controller is modeled, so the data bus during int-ack floats to FF,
    // which both IM0 (executes as RST 38) and IM1 CPUs handle the same way.
    reg irq_pending;
    wire int_ack = ~cpu_m1_n && ~cpu_iorq_n;
    always @(posedge clk) begin
        if (reset) irq_pending <= 0;
        else begin
            if (vblank_rise) irq_pending <= 1'b1;
            else if (int_ack) irq_pending <= 1'b0;
        end
    end
    assign int_n = ~irq_pending;

`ifdef SIM_DEBUG_TRACE
    integer trace_count = 0;
    always @(posedge clk) begin
        if (!reset && trace_count < 400) begin
            $display("[%0t] a=%04x m1_n=%b mreq_n=%b rd_n=%b wr_n=%b di=%02x do=%02x cen=%b",
                      $time, cpu_a, cpu_m1_n, cpu_mreq_n, cpu_rd_n, cpu_wr_n, cpu_di, cpu_do, ce_z80);
            trace_count = trace_count + 1;
        end
        if (sel_vram && cpu_write) $display("[%0t] VRAM write addr=%04x data=%02x", $time, cpu_a, cpu_do);
    end
`endif

    // ------------------------------------------------------------------
    // Memory decode (main_prg_map, docs/PLAN.md phase 1)
    // ------------------------------------------------------------------
    wire cpu_write = ~cpu_mreq_n && ~cpu_wr_n;

    wire sel_rom     = (cpu_a < 16'h8000);
    wire sel_vram    = (cpu_a >= 16'hC000) && (cpu_a < 16'hC800);
    wire sel_sprpos  = (cpu_a >= 16'hE000) && (cpu_a < 16'hE400);
    wire sel_sprram  = (cpu_a >= 16'hE400) && (cpu_a < 16'hE800);
    wire sel_workram = (cpu_a >= 16'hF800);
    // Everything else (PPI0/PPI1/i8279/IN0/IN1/DSW) is stubbed: reads
    // return FF, writes are dropped.

    wire [7:0] vram_rdata;
    fg_tilemap u_fg
    (
        .clk          (clk),
        .cpu_we       (sel_vram && cpu_write),
        .cpu_addr     (cpu_a[10:0]),
        .cpu_wdata    (cpu_do),
        .cpu_rdata    (vram_rdata),
        .tile_we      (fgtiles_we),
        .tile_addr    (fgtiles_wraddr),
        .tile_wdata   (rom_dout),
        .xshift_we    (xshift_we),
        .xshift_addr  (xshift_addr),
        .xshift_wdata (rom_dout),
        .xx           (xx_native),
        .y            (y_native),
        .foreraw      (foreraw)
    );

    // pr-5196 (Y-scale, 512B @ proms offset 0x100) and pr-5199 (sprite
    // color table, 1024B @ proms offset 0x700) forwarded from the shared
    // PROMS blob, same pattern as xshift_we/color_table above. Full-width
    // subtraction before slicing (not truncation) -- see rom_download.v's
    // header comment on why that matters for non-zero-based windows.
    wire        yscale_we_fwd = proms_we && (proms_wraddr >= 13'h100) && (proms_wraddr < 13'h300);
    wire [12:0] yscale_off    = proms_wraddr - 13'h100;

    wire        sprcolor_we_fwd = proms_we && (proms_wraddr >= 13'h700) && (proms_wraddr < 13'hB00);
    wire [12:0] sprcolor_off    = proms_wraddr - 13'h700;

    reg [7:0] sprcolor_table[0:1023]; // pr-5199
    always @(posedge clk) if (sprcolor_we_fwd) sprcolor_table[sprcolor_off[9:0]] <= rom_dout;

    wire [7:0]  sprram_rdata, sprpos_rdata;
    wire [31:0] sprbits;
    wire [7:0]  spr_plb;
    sprite_engine u_sprites
    (
        .clk              (clk),
        .reset            (reset),

        .cpu_sprram_we    (sel_sprram && cpu_write),
        .cpu_sprram_addr  (cpu_a[9:0]),
        .cpu_sprram_wdata (cpu_do),
        .cpu_sprram_rdata (sprram_rdata),

        .cpu_sprpos_we    (sel_sprpos && cpu_write),
        .cpu_sprpos_addr  (cpu_a[9:0]),
        .cpu_sprpos_wdata (cpu_do),
        .cpu_sprpos_rdata (sprpos_rdata),

        .sproms_we        (sprites_we),
        .sproms_addr      (sprites_wraddr),
        .sproms_wdata     (rom_dout),

        .yscale_we        (yscale_we_fwd),
        .yscale_addr      (yscale_off[8:0]),
        .yscale_wdata     (rom_dout),

        .ce_pix           (ce_pix_int),
        .hblank           (hblank_raw),
        .hpos             (hpos),
        .vpos             (vpos),

        .obch             (3'b000), // PPI1 port C bits 0-2, not wired yet (phase 1c)

        .sprbits          (sprbits),
        .plb              (spr_plb)
    );

    assign cpu_di = sel_rom     ? maincpu_dout  :
                     sel_vram   ? vram_rdata    :
                     sel_sprram ? sprram_rdata  :
                     sel_sprpos ? sprpos_rdata  :
                     sel_workram? work_ram_dout :
                                  8'hFF;

    // ------------------------------------------------------------------
    // Video: native (pre-2x) coordinates for the fg tilemap fetch
    // ------------------------------------------------------------------
    wire [7:0] xx_native = hpos[9:1];
    wire [7:0] y_native  = vpos[7:0];
    wire [7:0] foreraw;

    // ------------------------------------------------------------------
    // Phase-1b mixer: fg tier-1 + sprite branch (docs/PLAN.md
    // mixer_buckrog.v). fchg/obch (PPI0/PPI1 port C) are tied to 0 until
    // the PPIs are wired up (phase 1c). fg-tier-2/star/bgcolor branches
    // aren't implemented yet (phase 1c: sub CPU + bitmap + bgcolor) --
    // they fall back to the fg-tier-1 repack, same as the phase-1a stub
    // did unconditionally.
    // ------------------------------------------------------------------
    wire [1:0] fchg = 2'b00;
    wire [8:0] color_addr = ({7'b0, foreraw[1:0]}) |
                            ({1'b0, foreraw & 8'hF8} >> 1) |
                            ({fchg, 7'b0});
    reg [7:0] forebits_reg;
    always @(posedge clk) forebits_reg <= color_table[color_addr];

    // sprbits/plb are real-time (0-latency vs. hpos/vpos, see
    // sprite_engine.v's header) -- delay by 5 clk to land on the same
    // pipeline stage as forebits_reg (fg_tilemap's 4 + this module's
    // color_table stage = 5).
    localparam SPR_TO_MIX_DELAY = 5;
    reg [39:0] spr_pipe [0:SPR_TO_MIX_DELAY-1];
    integer si;
    always @(posedge clk) begin
        spr_pipe[0] <= {sprbits, spr_plb};
        for (si = 1; si < SPR_TO_MIX_DELAY; si = si + 1) spr_pipe[si] <= spr_pipe[si-1];
    end
    wire [31:0] sprbits_d5 = spr_pipe[SPR_TO_MIX_DELAY-1][39:8];
    wire [7:0]  plb_d5     = spr_pipe[SPR_TO_MIX_DELAY-1][7:0];

    // LS148 priority encoder: index of the lowest-numbered set bit in plb
    // (0-7), or 4'hf if plb==0 -- equivalent to MAME's
    // countl_zero(bitswap<8>(plb,0,1,2,3,4,5,6,7)) with the mux==8 clamp
    // folded in.
    function [3:0] find_lsb;
        input [7:0] p;
        begin
            casez (p)
                8'b???????1: find_lsb = 4'd0;
                8'b??????10: find_lsb = 4'd1;
                8'b?????100: find_lsb = 4'd2;
                8'b????1000: find_lsb = 4'd3;
                8'b???10000: find_lsb = 4'd4;
                8'b??100000: find_lsb = 4'd5;
                8'b?1000000: find_lsb = 4'd6;
                8'b10000000: find_lsb = 4'd7;
                default:     find_lsb = 4'hf;
            endcase
        end
    endfunction

    wire [3:0]  mux             = find_lsb(plb_d5);
    wire [31:0] sprbits_shifted = sprbits_d5 >> mux[2:0];
    wire [3:0]  cd              = {sprbits_shifted[24], sprbits_shifted[16], sprbits_shifted[8], sprbits_shifted[0]};
    wire [2:0]  obch            = 3'b000; // PPI1 port C bits 0-2, not wired yet (phase 1c)

    reg [7:0] sprcolor_dout;
    always @(posedge clk) sprcolor_dout <= sprcolor_table[{obch, mux[2:0], cd}];

    // One more register stage on the fg-tier-1 path + mux so both operands
    // of the final select land on sprcolor_dout's cycle (+6: the +5 above,
    // plus this module's own sprcolor_table read).
    reg [7:0] forebits_reg2;
    reg [3:0] mux_reg;
    always @(posedge clk) begin
        forebits_reg2 <= forebits_reg;
        mux_reg       <= mux;
    end

    function [7:0] repack;
        input [7:0] f;
        repack = ((f & 8'h3c) << 2) | ((f & 8'h06) << 1) | (f & 8'h01);
    endfunction

    wire [7:0] palbits_fg1 = repack(forebits_reg2);
    wire [7:0] palbits = (!forebits_reg2[7]) ? palbits_fg1 :          // fg tier 1
                          (!mux_reg[3])       ? sprcolor_dout :       // sprite
                                                 palbits_fg1;          // stand-in for fg-tier2/star/bgcolor (phase 1c)

    reg [23:0] palette_rom[0:1023];
    initial $readmemh("roms/palette_buckrog.hex", palette_rom);

    reg [23:0] rgb_reg;
    always @(posedge clk) rgb_reg <= palette_rom[{2'b00, palbits}];

    assign video_r = (hblank | vblank) ? 8'h0 : rgb_reg[23:16];
    assign video_g = (hblank | vblank) ? 8'h0 : rgb_reg[15:8];
    assign video_b = (hblank | vblank) ? 8'h0 : rgb_reg[7:0];

    // ------------------------------------------------------------------
    // Sync-bundle delay line: realigns hblank/vblank/hsync/vsync/ce_pix with
    // the pipeline latency above (fg_tilemap's 4 + color_table's 1 +
    // sprcolor_table's 1 + palette_rom's 1 = 7), so the sync signals output
    // alongside rgb_reg describe the same original hpos/vpos that produced
    // it.
    // ------------------------------------------------------------------
    localparam VIDEO_PIPE_LATENCY = 7;

    reg [VIDEO_PIPE_LATENCY-1:0] hblank_pipe, vblank_pipe, hsync_pipe, vsync_pipe, ce_pix_pipe;
    always @(posedge clk) begin
        hblank_pipe <= {hblank_pipe[VIDEO_PIPE_LATENCY-2:0], hblank_raw};
        vblank_pipe <= {vblank_pipe[VIDEO_PIPE_LATENCY-2:0], vblank_raw};
        hsync_pipe  <= {hsync_pipe [VIDEO_PIPE_LATENCY-2:0], hsync_raw};
        vsync_pipe  <= {vsync_pipe [VIDEO_PIPE_LATENCY-2:0], vsync_raw};
        ce_pix_pipe <= {ce_pix_pipe[VIDEO_PIPE_LATENCY-2:0], ce_pix_int};
    end
    assign hblank = hblank_pipe[VIDEO_PIPE_LATENCY-1];
    assign vblank = vblank_pipe[VIDEO_PIPE_LATENCY-1];
    assign hsync  = hsync_pipe [VIDEO_PIPE_LATENCY-1];
    assign vsync  = vsync_pipe [VIDEO_PIPE_LATENCY-1];
    assign ce_pix = ce_pix_pipe[VIDEO_PIPE_LATENCY-1];

endmodule
