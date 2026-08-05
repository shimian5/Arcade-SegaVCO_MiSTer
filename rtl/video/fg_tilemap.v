// Buck Rogers foreground tilemap (see docs/PLAN.md "Foreground tilemap").
//
// 32x32 grid of 8x8 tiles, 2bpp planar, code = raw VRAM byte, color = code>>2.
// Buck Rogers' column fetch is remapped through PR-5194 (an X-shift PROM):
//   col = pr5194[((xx>>3)-1) & 0x1f]
// Output "foreraw" is MAME's `color*4 + pixel`, an 8-bit raw pen consumed by
// the mixer (not built yet -- phase 1c).
//
// PIPELINE: VRAM/tile-ROM/PROM reads are registered (synchronous, one clk of
// latency each) so Quartus infers real M10K block RAM instead of a giant
// combinational mux. That gives foreraw a fixed 4-clk latency behind xx/y.
// xx/y are only fed by the 2x-scale video pipeline, which holds each native
// (xx,y) pair stable for 8 clk cycles (2 output pixels x 4 clk/pixel) --
// comfortably longer than this 4-stage fetch, BUT each stage below samples a
// different field of the *live* xx/y a clock apart (col from xx[7:3] at t,
// row from y[7:3] at t+1, row-within-tile from y[2:0] at t+2, pixel-within-
// tile from xx[2:0] at t+3). For 3 of every 8 clk phases -- i.e. at every
// native-pixel boundary -- those fields disagree by one native pixel, which
// renders the leftmost pixel of the wrong (neighbouring) tile column. To
// avoid that, xx/y are captured once at stage 1 and threaded through a delay
// chain so every stage consumes the SAME (xx,y) sample. segavco.v
// delay-matches hblank/vblank/hsync/vsync/ce_pix by the same total pipeline
// depth (this module's 4, plus its own color-table and palette lookups) so
// the sync bundle stays aligned with the pixel data it describes. See
// FG_TILEMAP_LATENCY below.
module fg_tilemap
(
    input  wire        clk,

    // One-RBF game strap (docs/WORKPLAN_TURBO_GRAPHICS.md Step 5): Turbo's
    // column fetch has no PR-5194 X-shift remap -- it's a plain 8-native-
    // pixel shift with the whole tilemap forced blank outside
    // [8, 0x108) -- turbo_v.cpp:459 (`foreraw = (xx<8||xx>=0x108) ? 0 :
    // fore[xx-8]`). Everything downstream of "col" (VRAM/tile-ROM lookup,
    // bit-select+pack) is unchanged between games.
    input  wire        mod_turbo,

    // CPU port -- video RAM, c000-c7ff (2KB span; only the low 1KB, the
    // 32x32 grid, is ever addressed by the tilemap fetch below)
    input  wire         cpu_we,
    input  wire [10:0]  cpu_addr,
    input  wire [7:0]   cpu_wdata,
    output reg  [7:0]   cpu_rdata,

    // ROM download ports
    input  wire         tile_we,
    input  wire [11:0]  tile_addr,
    input  wire [7:0]   tile_wdata,
    input  wire         xshift_we,
    input  wire [4:0]   xshift_addr,
    input  wire [7:0]   xshift_wdata,

    // video side, native (pre-2x) coordinates. Held stable for >=4 clk by
    // the caller (see latency note above).
    input  wire [7:0]   xx,   // 0..255
    input  wire [7:0]   y,    // 0..255 (0..223 visible)
    output wire [7:0]   foreraw
`ifdef VERILATOR_SIM
    // SECT-2 investigation: combinational read port on the fg tilemap VRAM,
    // so the HUD (RD:/SECT: digits at rows 1-2, the lives icons on row 25)
    // can be sampled once per frame and compared cell-for-cell against
    // MAME's maincpu-space read of 0xc000-0xc7ff. Value comparison, not a
    // counter -- see docs/PLAN.md on degenerate instruments.
    , input  wire [10:0] dbg_vram_addr
    , output wire [7:0]  dbg_vram_data
`endif
);

    localparam FG_TILEMAP_LATENCY = 4;

    reg [7:0] vram[0:2047];       // 2KB (c000-c7ff)
    reg [7:0] tile_rom[0:4095];   // 4KB: plane0 @ 0x000, plane1 @ 0x800, each code*8+py
    reg [7:0] xshift_rom[0:31];   // pr-5194

`ifdef VERILATOR_SIM
    assign dbg_vram_data = vram[dbg_vram_addr];
`endif

    always @(posedge clk) begin
        if (cpu_we)    vram[cpu_addr]          <= cpu_wdata;
        if (tile_we)   tile_rom[tile_addr]     <= tile_wdata;
        if (xshift_we) xshift_rom[xshift_addr] <= xshift_wdata;
        cpu_rdata <= vram[cpu_addr];
    end

    // Coordinate delay chain: every stage below must consume the SAME
    // (xx,y) sample that stage 1 used, not whatever xx/y is live on the
    // stage's own clock. Capture xx/y once here and re-time each field by
    // exactly the number of stages it lags behind stage 1.
    reg [7:0] xx_d1, xx_d2, xx_d3;
    reg [7:0] y_d1, y_d2;
    always @(posedge clk) begin
        xx_d1 <= xx;    xx_d2 <= xx_d1;    xx_d3 <= xx_d2;
        y_d1  <= y;     y_d2  <= y_d1;
    end

    // Stage 1: X-shift PROM lookup -> tile column (Buck Rogers), or a plain
    // shift-by-8 with no remap (Turbo). Both are registered here so col is
    // available at the same absolute pipeline stage regardless of mod_turbo
    // -- this module's total latency (FG_TILEMAP_LATENCY) must stay fixed
    // and game-independent, since segavco.v's delay-matching constants are
    // not (yet) runtime-switched.
    wire [4:0] col_raw       = xx[7:3] - 5'd1;          // (xx>>3)-1, wraps mod 32
    wire [4:0] turbo_col_raw = (xx - 8'd8) >> 3;         // (xx-8)>>3, wraps mod 32 via 8-bit truncation
    reg  [7:0] xshift_dout;
    reg  [4:0] turbo_col_reg;
    always @(posedge clk) begin
        xshift_dout   <= xshift_rom[col_raw];
        turbo_col_reg <= turbo_col_raw;
    end

    // Stage 2: VRAM lookup -> tile code (y delayed 1 to match stage 1's xx sample)
    wire [4:0] col   = mod_turbo ? turbo_col_reg : xshift_dout[4:0];
    wire [9:0] vaddr = {y_d1[7:3], col};          // row*32 + col
    reg  [7:0] vram_dout;
    always @(posedge clk) vram_dout <= vram[vaddr];

    // Stage 3: tile ROM lookup (both planes) -> pixel planes + latched code
    // (y delayed 2 to match stage 1's xx sample)
    wire [10:0] rom_row = {vram_dout, y_d2[2:0]}; // code*8 + py
    reg  [7:0]  plane0_dout, plane1_dout, code_dout;
    always @(posedge clk) begin
        plane0_dout <= tile_rom[rom_row];
        plane1_dout <= tile_rom[{1'b1, rom_row}];
        code_dout   <= vram_dout;
    end

    // Stage 4: bit-select + pack (color*4 + pixel)
    // (xx delayed 3 to match stage 1's xx sample)
    wire       bit0  = plane0_dout[3'd7 - xx_d3[2:0]];
    wire       bit1  = plane1_dout[3'd7 - xx_d3[2:0]];
    wire [5:0] color = code_dout[7:2];

    // Turbo's blanking window, evaluated on the same xx_d3 sample as the
    // pixel above (turbo_v.cpp:459). The ">=264" arm is structurally dead
    // for this core -- xx never exceeds 255 (8-bit, 256 native columns) --
    // but is kept for fidelity to the MAME source rather than silently
    // dropped.
    wire turbo_blank = (xx_d3 < 8'd8) || ({1'b0, xx_d3} >= 9'd264);

    reg  [7:0] foreraw_reg;
    always @(posedge clk)
        foreraw_reg <= (mod_turbo && turbo_blank) ? 8'h00 : {color, bit1, bit0};
    assign foreraw = foreraw_reg;

endmodule
