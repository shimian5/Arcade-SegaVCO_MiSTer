// Z80-3D system top: main CPU, sub CPU, memory decode, video pipeline.
//
// PHASE 1c SCOPE (see docs/PLAN.md): sub CPU + bitmap/starfield + bgcolor +
// full mixer priority chain, on top of phase 1a (main CPU/video RAM/fg
// tilemap) and phase 1b (sprite engine). This is the full `buckrogn`
// memory map and mixer -- boots, coin-up, playable.
//
// MEMORY READS ARE ALL REGISTERED (synchronous), including both CPUs'
// program ROM/work RAM ports, so Quartus infers real M10K block RAM instead
// of large combinational muxes. This needs no Z80 wait-state handling:
// cpu_a/sub_a are held stable for the CPU's whole T-state (many core-clk
// cycles, since ce_z80 only pulses once every 8), far longer than the
// 1-cycle read latency. The video path's registered reads (fg_tilemap,
// sprite_engine, and the local color-table/sprcolor-table/bitmap-ram/
// bgcolor-ROM/palette lookups below) form a fixed-depth pipeline instead;
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

    // IN0/IN1/DSW1/DSW2, real player controls + coin/start/service + DIP
    // switches. See docs/PLAN.md phase 1 CPU/memory table and the buckrog
    // INPUT_PORTS_START block in docs/reference/turbo.cpp for bit layout.
    // All active-low (idle = 1), matching MAME's ACTIVE_LOW convention.
    input  wire [7:0]   in0,
    input  wire [7:0]   in1,
    input  wire [7:0]   dsw1,
    input  wire [7:0]   dsw2,

    output wire         hblank,
    output wire         vblank,
    output wire         hsync,
    output wire         vsync,
    output wire         ce_pix,
    output wire [7:0]   video_r,
    output wire [7:0]   video_g,
    output wire [7:0]   video_b

`ifdef VERILATOR_SIM
    // Phase0-1a sprite debug harness (see sprite_engine.v's VERILATOR_SIM
    // block): real-time, zero-latency sprite_engine outputs, exposed so
    // sim/tb_z80_3d.cpp can dump them per-pixel for the chosen frame without
    // needing to re-derive the mixer's delay-matched copies.
    , output wire [31:0] dbg_sprbits
    , output wire [7:0]  dbg_plb
    , output wire [9:0]  dbg_hpos
    , output wire [8:0]  dbg_vpos
`endif
);

    // ------------------------------------------------------------------
    // Clock enables
    // ------------------------------------------------------------------
    // Z80 CE: core_clk / 8 = 4.992 MHz, shared by both CPUs (real hardware
    // clocks the sub CPU from the same MASTER_CLOCK/4 as the main CPU --
    // see docs/reference/turbo.cpp Z80(config, m_subcpu, MASTER_CLOCK/4)).
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

    // Buck Rogers' bgcolor ROM (8KB) shares the "road" download slot with
    // Turbo's road generator (mutually exclusive alternatives, see
    // docs/PLAN.md "ROM loading"). Registered read, same pattern as
    // color_table/sprcolor_table.
    //
    // road_wraddr spans the FULL 32KB shared road/bgcolor download slot,
    // but Buck Rogers' real bgcolor ROM only fills the first 8KB of it --
    // the rest is 0xFF filler (sim/build_rom.py's blob-fill default;
    // real hardware simply has no ROM chip there). Gate the write on the
    // low 8KB, matching xshift_we/proms_is_colortab's range-gated
    // forwarding above: without this, the filler bytes alias back onto
    // the same 8192 entries via truncation and, arriving later in the
    // download stream, silently overwrite every real bgcolor byte with
    // 0xFF.
    wire        bgcolorrom_we = road_we && (road_wraddr < 15'h2000);
    reg [7:0] bgcolorrom[0:8191];
    always @(posedge clk) if (bgcolorrom_we) bgcolorrom[road_wraddr[12:0]] <= rom_dout;

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
    // Main CPU
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
    // Sub CPU has no VBLANK IRQ (docs/PLAN.md) -- see sub_int_n below,
    // which is driven directly from PPI0 port C bit 7 instead.
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
    // Sub CPU (Buck Rogers' second Z80 -- bitmap/starfield generator)
    // ------------------------------------------------------------------
    wire [15:0] sub_a;
    wire [7:0]  sub_di, sub_do;
    wire        sub_wr_n, sub_rd_n, sub_mreq_n, sub_m1_n, sub_iorq_n;

    cpu_z80 u_subcpu
    (
        .clk     (clk),
        .cen     (ce_z80),
        .reset_n (~reset),
        .wait_n  (1'b1),
        .int_n   (sub_int_n),
        .nmi_n   (1'b1),
        .busrq_n (1'b1),
        .m1_n    (sub_m1_n),
        .mreq_n  (sub_mreq_n),
        .iorq_n  (sub_iorq_n),
        .rd_n    (sub_rd_n),
        .wr_n    (sub_wr_n),
        .rfsh_n  (),
        .halt_n  (),
        .busak_n (),
        .a       (sub_a),
        .di      (sub_di),
        .dout    (sub_do)
    );

    wire sub_write   = ~sub_mreq_n && ~sub_wr_n;
    wire sub_io_read = ~sub_iorq_n && ~sub_rd_n;

    // sub_prg_map (docs/reference/turbo.cpp buckrog_state::sub_prg_map):
    // 0000-1fff ROM (read), 0000-dfff write -> bitmap_w, e000-e7ff mirrored
    // (mirror 1800 covers the full e000-ffff span with an 11-bit RAM) work
    // RAM.
    reg [7:0] subcpu_rom[0:8191];
    reg [7:0] sub_rom_dout;
    always @(posedge clk) begin
        if (subcpu_we) subcpu_rom[subcpu_wraddr] <= rom_dout;
        sub_rom_dout <= subcpu_rom[sub_a[12:0]];
    end

    wire sub_workram_sel = (sub_a >= 16'hE000);
    reg [7:0] sub_workram[0:2047];
    reg [7:0] sub_workram_dout;
    always @(posedge clk) begin
        if (sub_write && sub_workram_sel) sub_workram[sub_a[10:0]] <= sub_do;
        sub_workram_dout <= sub_workram[sub_a[10:0]];
    end

    // Bitmap RAM (star layer): 256x224x1bit = 57344 bits, addressed
    // directly by sub_a (y = addr>>8, x = addr&0xff => addr == y*256+x,
    // which is exactly sub_a for the 0000-dfff write window). See
    // docs/PLAN.md "Bitmap RAM / starfield layer".
    wire sub_bitmap_we = sub_write && (sub_a < 16'hE000);
    reg bitmap_ram[0:57343];
    always @(posedge clk) if (sub_bitmap_we) bitmap_ram[sub_a] <= sub_do[0];

    // Sub CPU data-in mux: its entire I/O space reads the command latch
    // (ppi0_pa, written by the main CPU); memory space reads ROM or
    // mirrored work RAM.
    assign sub_di = (~sub_iorq_n) ? ppi0_pa :
                     (sub_a < 16'h2000) ? sub_rom_dout : sub_workram_dout;

    // ------------------------------------------------------------------
    // Main<->sub protocol (docs/PLAN.md "Main<->sub protocol"). Trivially
    // a register (ppi0_pa, the command latch) plus two flags in RTL --
    // MAME's delayed_i8255_w/600Hz-quantum machinery is a pure emulator
    // scheduling artifact with no hardware analogue and is NOT reproduced
    // here.
    //   1. Main writes PPI0 port A -> 8-bit command register (= ppi0_pa).
    //   2. Main writes PPI0 port C bit 7 -> sub /INT directly (level, not
    //      edge-latched: real hardware ties /INT straight to the 8255's
    //      output pin).
    //   3. Sub executes any IN -> reads command, clears PPI0 PC6 (ACK,
    //      readable by main). Implemented as a dedicated ack_reg overriding
    //      bit 6 of the CPU-visible port-C readback (see "Support chips" in
    //      docs/PLAN.md: "PPI0 additionally needs port C bit 6 as a
    //      readable input driven by the sub-CPU ACK" -- the i8255 model
    //      itself is generic mode-0 with per-port direction, so the mixed
    //      per-bit override for just this one bit is handled here instead
    //      of inside i8255.v).
    // ------------------------------------------------------------------
    wire sub_int_n = ppi0_pc[7];

    reg ack_reg;
    wire ppi0_portc_write = sel_ppi0 && cpu_write && (cpu_a[1:0] == 2'd2);
    always @(posedge clk) begin
        if (reset) ack_reg <= 1'b1;
        else if (sub_io_read)        ack_reg <= 1'b0;
        else if (ppi0_portc_write)   ack_reg <= cpu_do[6];
    end

    // ------------------------------------------------------------------
    // Memory decode (main_prg_map, docs/PLAN.md phase 1)
    // ------------------------------------------------------------------
    wire cpu_write = ~cpu_mreq_n && ~cpu_wr_n;

    wire sel_rom     = (cpu_a < 16'h8000);
    wire sel_vram    = (cpu_a >= 16'hC000) && (cpu_a < 16'hC800);
    wire sel_ppi0    = (cpu_a >= 16'hC800) && (cpu_a < 16'hD000);
    wire sel_ppi1    = (cpu_a >= 16'hD000) && (cpu_a < 16'hD800);
    wire sel_i8279   = (cpu_a >= 16'hD800) && (cpu_a < 16'hE000);
    wire sel_sprpos  = (cpu_a >= 16'hE000) && (cpu_a < 16'hE400);
    wire sel_sprram  = (cpu_a >= 16'hE400) && (cpu_a < 16'hE800);
    wire sel_io2     = (cpu_a >= 16'hE800) && (cpu_a < 16'hF000); // IN0/IN1/DSW
    wire sel_workram = (cpu_a >= 16'hF800);

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
`ifdef VERILATOR_SIM
    assign dbg_sprbits = sprbits;
    assign dbg_plb      = spr_plb;
    assign dbg_hpos      = hpos;
    assign dbg_vpos      = vpos;
`endif
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

        .obch             (obch), // PPI1 port C bits 0-2

        .sprbits          (sprbits),
        .plb              (spr_plb)
    );

    // ------------------------------------------------------------------
    // i8255 PPI0 (c800-c803, mirror 07fc) and PPI1 (d000-d003, mirror
    // 07fc). Both are programmed all-output on real hardware (see
    // docs/reference/turbo.cpp buckrog_state's I8255 machine-config: only
    // out_p*_callback are registered, no in_p*_callback), so external
    // input ports are tied off.
    // ------------------------------------------------------------------
    wire [7:0] ppi0_dout, ppi0_pa, ppi0_pb, ppi0_pc;
    wire       ppi0_pc_wr;
    i8255 u_ppi0
    (
        .clk   (clk), .reset (reset),
        .cs    (sel_ppi0), .we (cpu_write), .addr (cpu_a[1:0]),
        .din   (cpu_do), .dout (ppi0_dout),
        .in_a  (8'hFF), .in_b (8'hFF), .in_c (8'hFF),
        .pa    (ppi0_pa), .pb (ppi0_pb), .pc (ppi0_pc),
        .pa_wr (), .pb_wr (), .pc_wr (ppi0_pc_wr)
    );

    // Port-C bit 6 readback is overridden with the sub-CPU ACK flag (see
    // "Main<->sub protocol" above); all other bits reflect the PPI's own
    // latched output register.
    wire [7:0] ppi0_dout_ovr = (cpu_a[1:0] == 2'd2) ?
                               {ppi0_dout[7], ack_reg, ppi0_dout[5:0]} : ppi0_dout;

    // PPI1: buckrog_state's out_pc_callback is ppi1c_w (docs/reference/
    // turbo.cpp lines 393-405) -- OBCH0-2, coin meters (bits 4/5), start
    // lamp (bit 6). Left as internal wires (no top-level MiSTer port for
    // coin meters/lamp exists yet in Arcade-Z80-3D.sv) -- TODO if/when one
    // is added. Port A/B are the sound-generator interface (phase 2, not
    // acted on here beyond decoding the writes).
    wire [7:0] ppi1_dout, ppi1_pa, ppi1_pb, ppi1_pc;
    i8255 u_ppi1
    (
        .clk   (clk), .reset (reset),
        .cs    (sel_ppi1), .we (cpu_write), .addr (cpu_a[1:0]),
        .din   (cpu_do), .dout (ppi1_dout),
        .in_a  (8'hFF), .in_b (8'hFF), .in_c (8'hFF),
        .pa    (ppi1_pa), .pb (ppi1_pb), .pc (ppi1_pc),
        .pa_wr (), .pb_wr (), .pc_wr ()
    );
    wire [2:0] obch          = ppi1_pc[2:0];
    wire       coin_meter1   = ppi1_pc[4];
    wire       coin_meter2   = ppi1_pc[5];
    wire       start_lamp    = ppi1_pc[6];

    // Video registers pulled from PPI0 (docs/PLAN.md "Video registers"):
    // fchg = port C bits 0-2 (only bits 0-1 feed the pr5198 address, per
    // turbo_v.cpp's mixer -- see color_addr below), mov = port B bits 0-5
    // (only bits 0-4 feed the bgcolor address).
    wire [1:0] fchg = ppi0_pc[1:0];
    wire [5:0] mov  = ppi0_pb[5:0];

    // ------------------------------------------------------------------
    // i8279 (d800-d801, mirror 07fe). Only DSW1-via-RL is required for
    // playability; digit/scanline output is cosmetic and unimplemented
    // (see rtl/io/i8279.v).
    // ------------------------------------------------------------------
    wire [7:0] i8279_dout;
    i8279 u_i8279
    (
        .clk  (clk), .reset (reset),
        .cs   (sel_i8279), .we (cpu_write), .addr (cpu_a[0]),
        .din  (cpu_do), .dout (i8279_dout),
        .rl   (dsw1)
    );

    // ------------------------------------------------------------------
    // IN0/IN1/DSW real reads (e800-e803, mirror 07fc). e802/e803 are DSW
    // bitswaps (docs/PLAN.md phase 1 CPU/memory table / buckrog_state::
    // port_2_r/port_3_r in docs/reference/turbo.cpp).
    // ------------------------------------------------------------------
    function [3:0] bitswap4;
        input [7:0] d;
        input [2:0] i3, i2, i1, i0;
        bitswap4 = {d[i3], d[i2], d[i1], d[i0]};
    endfunction

    wire [7:0] port2_bits = {bitswap4(dsw2, 6, 4, 3, 0), bitswap4(dsw1, 6, 4, 3, 0)};
    wire [7:0] port3_bits = {bitswap4(dsw2, 7, 5, 2, 1), bitswap4(dsw1, 7, 5, 2, 1)};

    reg [7:0] io2_reg;
    always @(posedge clk) begin
        case (cpu_a[1:0])
            2'd0: io2_reg <= in0;
            2'd1: io2_reg <= in1;
            2'd2: io2_reg <= port2_bits;
            2'd3: io2_reg <= port3_bits;
        endcase
    end

    assign cpu_di = sel_rom     ? maincpu_dout   :
                     sel_vram   ? vram_rdata     :
                     sel_ppi0   ? ppi0_dout_ovr  :
                     sel_ppi1   ? ppi1_dout      :
                     sel_i8279  ? i8279_dout     :
                     sel_sprram ? sprram_rdata   :
                     sel_sprpos ? sprpos_rdata   :
                     sel_io2    ? io2_reg        :
                     sel_workram? work_ram_dout  :
                                  8'hFF;

    // ------------------------------------------------------------------
    // Video: native (pre-2x) coordinates for the fg tilemap / bitmap /
    // bgcolor fetches
    // ------------------------------------------------------------------
    wire [7:0] xx_native = hpos[9:1];
    wire [7:0] y_native  = vpos[7:0];
    wire [7:0] foreraw;

    // ------------------------------------------------------------------
    // Full mixer priority chain (docs/PLAN.md "Mixer" / mixer_buckrog.v):
    //   fg tier 1 -> sprite -> fg tier 2 -> star (bitmap) -> bgcolor
    // fchg/mov/obch are now the real PPI-derived registers above.
    // ------------------------------------------------------------------
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

    // Star (bitmap RAM) / bgcolor branches: both are addressed from
    // xx_native/y_native directly (like fg_tilemap's stage-0 input), not
    // from foreraw, so they need their own delay chain to land on the same
    // pipeline stage (stage6, aligned with forebits_reg2/sprcolor_dout/
    // mux_reg above) as everything else feeding the final palbits mux.
    // COORD_DELAY (5 regs) + the bitmap_ram/bgcolorrom read itself (1 reg)
    // = 6 register hops from xx_native/y_native, matching forebits_reg2's
    // 6 hops (fg_tilemap's 4 + color_table's 1 + forebits_reg2's 1) and
    // sprcolor_dout/mux_reg's 6 hops (spr_pipe's 5 + 1) -- so this resolves
    // within the existing 7-stage total pipeline depth without needing to
    // bump VIDEO_PIPE_LATENCY.
    localparam COORD_DELAY = 5;
    reg [15:0] coord_pipe [0:COORD_DELAY-1];
    integer ci;
    always @(posedge clk) begin
        coord_pipe[0] <= {y_native, xx_native};
        for (ci = 1; ci < COORD_DELAY; ci = ci + 1) coord_pipe[ci] <= coord_pipe[ci-1];
    end
    wire [7:0] y_d5  = coord_pipe[COORD_DELAY-1][15:8];
    wire [7:0] xx_d5 = coord_pipe[COORD_DELAY-1][7:0];

    reg star_bit;
    always @(posedge clk) star_bit <= bitmap_ram[{y_d5, xx_d5}];

    reg [7:0] bgcolor_reg;
    always @(posedge clk) bgcolor_reg <= bgcolorrom[{mov[4:0], y_d5}];

    function [7:0] repack;
        input [7:0] f;
        repack = ((f & 8'h3c) << 2) | ((f & 8'h06) << 1) | (f & 8'h01);
    endfunction

    // NOTE: repack_bg's shifts genuinely overflow 8 bits -- in MAME's C++
    // (turbo_v.cpp) `palbits` is a plain `int`, and this is how the bgcolor
    // branch reaches the upper 3/4 of Buck Rogers' 1024-entry (10-bit)
    // palette; the other three branches (repack()/pr5199/0xff) all happen
    // to stay within the low 256 entries. Truncating palbits to 8 bits and
    // forcing the palette address's top 2 bits to 0 (an earlier version of
    // this code did exactly that) silently collapses every bgcolor pixel
    // onto the wrong palette bank -- keep the full 10-bit width end to end.
    function [9:0] repack_bg;
        input [7:0] p;
        repack_bg = ({2'b00, p} & 10'h0c0) | (({2'b00, p} & 10'h030) << 4) | (({2'b00, p} & 10'h00f) << 2);
    endfunction

    wire [9:0] palbits_fg = {2'b00, repack(forebits_reg2)};
    wire [9:0] palbits = (!forebits_reg2[7]) ? palbits_fg :             // fg tier 1
                          (!mux_reg[3])       ? {2'b00, sprcolor_dout} : // sprite
                          (!forebits_reg2[6]) ? palbits_fg :             // fg tier 2
                          star_bit             ? 10'h0ff :                // bitmap/star
                                                  repack_bg(bgcolor_reg);  // bgcolor

    reg [23:0] palette_rom[0:1023];
    initial $readmemh("roms/palette_buckrog.hex", palette_rom);

    reg [23:0] rgb_reg;
    always @(posedge clk) rgb_reg <= palette_rom[palbits];

    assign video_r = (hblank | vblank) ? 8'h0 : rgb_reg[23:16];
    assign video_g = (hblank | vblank) ? 8'h0 : rgb_reg[15:8];
    assign video_b = (hblank | vblank) ? 8'h0 : rgb_reg[7:0];

    // ------------------------------------------------------------------
    // Sync-bundle delay line: realigns hblank/vblank/hsync/vsync/ce_pix with
    // the pipeline latency above (fg_tilemap's 4 + color_table's 1 +
    // sprcolor_table's 1 + palette_rom's 1 = 7; the star/bgcolor branches
    // resolve within this same depth, see COORD_DELAY comment above), so
    // the sync signals output alongside rgb_reg describe the same original
    // hpos/vpos that produced it.
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

    // Phase 1c debug: per-frame summary counters -- vram/sprram/sprpos
    // writes, PPI/i8279 activity, sub-CPU liveness. Printed once per vblank.
    integer dbg_vram_wr = 0, dbg_sprram_wr = 0, dbg_sprpos_wr = 0;
    integer dbg_ppi0_wr = 0, dbg_ppi1_wr = 0, dbg_i8279_wr = 0;
    integer dbg_sub_fetch = 0, dbg_bitmap_wr = 0, dbg_frame = 0;
    integer dbg_tier1 = 0, dbg_sprite = 0, dbg_tier2 = 0, dbg_star = 0, dbg_bg = 0;
    integer dbg_plb_nz = 0;
    always @(posedge clk) begin
        if (spr_plb != 8'h00) begin
            if (dbg_plb_nz < 20) $display("[%0t] spr_plb=%02x sprbits=%08x hpos=%0d vpos=%0d", $time, spr_plb, sprbits, hpos, vpos);
            dbg_plb_nz = dbg_plb_nz + 1;
        end
    end
    always @(posedge clk) begin
        if (ce_pix_pipe[VIDEO_PIPE_LATENCY-1] && !vblank_pipe[VIDEO_PIPE_LATENCY-1] && !hblank_pipe[VIDEO_PIPE_LATENCY-1]) begin
            if (!forebits_reg2[7])      dbg_tier1  = dbg_tier1 + 1;
            else if (!mux_reg[3])       dbg_sprite = dbg_sprite + 1;
            else if (!forebits_reg2[6]) dbg_tier2  = dbg_tier2 + 1;
            else if (star_bit)          dbg_star   = dbg_star + 1;
            else                        dbg_bg     = dbg_bg + 1;
        end
        if (vblank_rise) begin
            $display("[%0t] MIX FRAME %0d: tier1=%0d sprite=%0d tier2=%0d star=%0d bg=%0d",
                      $time, dbg_frame, dbg_tier1, dbg_sprite, dbg_tier2, dbg_star, dbg_bg);
            dbg_tier1 = 0; dbg_sprite = 0; dbg_tier2 = 0; dbg_star = 0; dbg_bg = 0;
        end
    end
    always @(posedge clk) begin
        if (sel_vram   && cpu_write) dbg_vram_wr   = dbg_vram_wr + 1;
        if (sel_sprram && cpu_write) dbg_sprram_wr = dbg_sprram_wr + 1;
        if (sel_sprpos && cpu_write) dbg_sprpos_wr = dbg_sprpos_wr + 1;
        if (sel_ppi0   && cpu_write) dbg_ppi0_wr   = dbg_ppi0_wr + 1;
        if (sel_ppi1   && cpu_write) dbg_ppi1_wr   = dbg_ppi1_wr + 1;
        if (sel_i8279  && cpu_write) dbg_i8279_wr  = dbg_i8279_wr + 1;
        if (~sub_m1_n && ~sub_mreq_n) dbg_sub_fetch = dbg_sub_fetch + 1;
        if (sub_bitmap_we) dbg_bitmap_wr = dbg_bitmap_wr + 1;
        if (vblank_rise) begin
            $display("[%0t] FRAME %0d: vram_wr=%0d sprram_wr=%0d sprpos_wr=%0d ppi0_wr=%0d ppi1_wr=%0d i8279_wr=%0d sub_fetch=%0d bitmap_wr=%0d ppi0_pa=%02x ppi0_pb=%02x ppi0_pc=%02x ppi1_pc=%02x ack=%b sub_a=%04x sub_int_n=%b cpu_a=%04x",
                      $time, dbg_frame, dbg_vram_wr, dbg_sprram_wr, dbg_sprpos_wr, dbg_ppi0_wr, dbg_ppi1_wr, dbg_i8279_wr, dbg_sub_fetch, dbg_bitmap_wr,
                      ppi0_pa, ppi0_pb, ppi0_pc, ppi1_pc, ack_reg, sub_a, sub_int_n, cpu_a);
            dbg_frame = dbg_frame + 1;
            dbg_vram_wr = 0; dbg_sprram_wr = 0; dbg_sprpos_wr = 0;
            dbg_ppi0_wr = 0; dbg_ppi1_wr = 0; dbg_i8279_wr = 0;
            dbg_sub_fetch = 0; dbg_bitmap_wr = 0;
        end
    end
`endif

endmodule
