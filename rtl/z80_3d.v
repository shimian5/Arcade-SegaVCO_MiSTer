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
    video_timing vtiming
    (
        .clk         (clk),
        .ce_pix      (ce_pix_int),
        .reset       (reset),
        .hpos        (hpos),
        .vpos        (vpos),
        .hblank      (hblank),
        .vblank      (vblank),
        .hsync       (hsync),
        .vsync       (vsync),
        .vblank_rise (vblank_rise)
    );

    // core_clk / 4 = 9.984 MHz pixel CE
    reg [1:0] pix_div;
    wire ce_pix_int = (pix_div == 2'd0);
    always @(posedge clk) begin
        if (reset) pix_div <= 0;
        else       pix_div <= pix_div + 2'd1;
    end
    assign ce_pix = ce_pix_int;

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
    // Main program ROM (32KB, 0000-7fff)
    // ------------------------------------------------------------------
    reg [7:0] maincpu_rom[0:32767];
    always @(posedge clk) if (maincpu_we) maincpu_rom[maincpu_wraddr] <= rom_dout;

    // ------------------------------------------------------------------
    // Work RAM (f800-ffff, 2KB)
    // ------------------------------------------------------------------
    reg [7:0] work_ram[0:2047];

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

    // ------------------------------------------------------------------
    // Memory decode (main_prg_map, docs/PLAN.md phase 1)
    // ------------------------------------------------------------------
    wire cpu_mem_valid = ~cpu_mreq_n && ~cpu_rd_n || ~cpu_mreq_n && ~cpu_wr_n;
    wire cpu_write     = ~cpu_mreq_n && ~cpu_wr_n;

    wire sel_rom     = (cpu_a < 16'h8000);
    wire sel_vram    = (cpu_a >= 16'hC000) && (cpu_a < 16'hC800);
    wire sel_workram = (cpu_a >= 16'hF800);
    // Everything else (PPI0/PPI1/i8279/sprite RAM/sprite-pos RAM/IN0/IN1/DSW)
    // is stubbed: reads return FF, writes are dropped.

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

    always @(posedge clk) begin
        if (sel_workram && cpu_write) work_ram[cpu_a[10:0]] <= cpu_do;
    end

    assign cpu_di = sel_rom     ? maincpu_rom[cpu_a[14:0]] :
                     sel_vram   ? vram_rdata               :
                     sel_workram? work_ram[cpu_a[10:0]]    :
                                  8'hFF;

    // ------------------------------------------------------------------
    // Video: native (pre-2x) coordinates for the fg tilemap fetch
    // ------------------------------------------------------------------
    wire [7:0] xx_native = hpos[9:1];
    wire [7:0] y_native  = vpos[7:0];
    wire [7:0] foreraw;

    // ------------------------------------------------------------------
    // Phase-1a mixer stub: fg tier-1 path only (docs/PLAN.md mixer_buckrog.v)
    // fchg (PPI0 port C bits 0-2) is tied to 0 until PPI0 is wired up.
    // ------------------------------------------------------------------
    wire [1:0] fchg = 2'b00;
    wire [8:0] color_addr = ({7'b0, foreraw[1:0]}) |
                            ({1'b0, foreraw & 8'hF8} >> 1) |
                            ({fchg, 7'b0});
    wire [7:0] forebits = color_table[color_addr];
    wire [7:0] palbits  = ((forebits & 8'h3c) << 2) | ((forebits & 8'h06) << 1) | (forebits & 8'h01);

    reg [23:0] palette_rom[0:1023];
    initial $readmemh("roms/palette_buckrog.hex", palette_rom);

    wire [23:0] rgb = (hblank || vblank) ? 24'h0 : palette_rom[{2'b00, palbits}];
    assign video_r = rgb[23:16];
    assign video_g = rgb[15:8];
    assign video_b = rgb[7:0];

endmodule
