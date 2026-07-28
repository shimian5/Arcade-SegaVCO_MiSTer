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
// This is safe without any Z80-style wait-state handling because xx/y are
// only fed by the 2x-scale video pipeline, which holds each native (xx,y)
// pair stable for 8 clk cycles (2 output pixels x 4 clk/pixel) -- comfortably
// longer than this 4-stage fetch. z80_3d.v delay-matches hblank/vblank/hsync
// /vsync/ce_pix by the same total pipeline depth (this module's 4, plus its
// own color-table and palette lookups) so the sync bundle stays aligned with
// the pixel data it describes. See FG_TILEMAP_LATENCY below.
module fg_tilemap
(
    input  wire        clk,

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
);

    localparam FG_TILEMAP_LATENCY = 4;

    reg [7:0] vram[0:2047];       // 2KB (c000-c7ff)
    reg [7:0] tile_rom[0:4095];   // 4KB: plane0 @ 0x000, plane1 @ 0x800, each code*8+py
    reg [7:0] xshift_rom[0:31];   // pr-5194

    always @(posedge clk) begin
        if (cpu_we)    vram[cpu_addr]          <= cpu_wdata;
        if (tile_we)   tile_rom[tile_addr]     <= tile_wdata;
        if (xshift_we) xshift_rom[xshift_addr] <= xshift_wdata;
        cpu_rdata <= vram[cpu_addr];
    end

    // Stage 1: X-shift PROM lookup -> tile column
    wire [4:0] col_raw = xx[7:3] - 5'd1;          // (xx>>3)-1, wraps mod 32
    reg  [7:0] xshift_dout;
    always @(posedge clk) xshift_dout <= xshift_rom[col_raw];

    // Stage 2: VRAM lookup -> tile code
    wire [4:0] col   = xshift_dout[4:0];
    wire [9:0] vaddr = {y[7:3], col};             // row*32 + col
    reg  [7:0] vram_dout;
    always @(posedge clk) vram_dout <= vram[vaddr];

    // Stage 3: tile ROM lookup (both planes) -> pixel planes + latched code
    wire [10:0] rom_row = {vram_dout, y[2:0]};    // code*8 + py
    reg  [7:0]  plane0_dout, plane1_dout, code_dout;
    always @(posedge clk) begin
        plane0_dout <= tile_rom[rom_row];
        plane1_dout <= tile_rom[{1'b1, rom_row}];
        code_dout   <= vram_dout;
    end

    // Stage 4: bit-select + pack (color*4 + pixel)
    wire       bit0  = plane0_dout[3'd7 - xx[2:0]];
    wire       bit1  = plane1_dout[3'd7 - xx[2:0]];
    wire [5:0] color = code_dout[7:2];
    reg  [7:0] foreraw_reg;
    always @(posedge clk) foreraw_reg <= {color, bit1, bit0};
    assign foreraw = foreraw_reg;

endmodule
