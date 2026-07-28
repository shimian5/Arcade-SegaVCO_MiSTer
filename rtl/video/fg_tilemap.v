// Buck Rogers foreground tilemap (see docs/PLAN.md "Foreground tilemap").
//
// 32x32 grid of 8x8 tiles, 2bpp planar, code = raw VRAM byte, color = code>>2.
// Buck Rogers' column fetch is remapped through PR-5194 (an X-shift PROM):
//   col = pr5194[((xx>>3)-1) & 0x1f]
// Output "foreraw" is MAME's `color*4 + pixel`, an 8-bit raw pen consumed by
// the mixer (not built yet -- phase 1c).
//
// NOTE (phase 1a simplification): VRAM/tile-ROM/PROM reads below are modeled
// as combinational array reads rather than registered BRAM ports. That is
// fine for Verilator simulation and for getting attract-mode text on screen,
// but is not synthesizable as single-cycle BRAM on real hardware -- pipeline
// this (mirroring sprite_engine's per-pixel fetch approach) before phase 1b
// frame-diff verification against MAME on real timing.
module fg_tilemap
(
    input  wire        clk,

    // CPU port -- video RAM, c000-c7ff (2KB span; only the low 1KB, the
    // 32x32 grid, is ever addressed by the tilemap fetch below)
    input  wire         cpu_we,
    input  wire [10:0]  cpu_addr,
    input  wire [7:0]   cpu_wdata,
    output wire [7:0]   cpu_rdata,

    // ROM download ports
    input  wire         tile_we,
    input  wire [11:0]  tile_addr,
    input  wire [7:0]   tile_wdata,
    input  wire         xshift_we,
    input  wire [4:0]   xshift_addr,
    input  wire [7:0]   xshift_wdata,

    // video side, native (pre-2x) coordinates
    input  wire [7:0]   xx,   // 0..255
    input  wire [7:0]   y,    // 0..255 (0..223 visible)
    output wire [7:0]   foreraw
);

    reg [7:0] vram[0:2047];       // 2KB (c000-c7ff)
    reg [7:0] tile_rom[0:4095];   // 4KB: plane0 @ 0x000, plane1 @ 0x800, each code*8+py
    reg [7:0] xshift_rom[0:31];   // pr-5194

    always @(posedge clk) begin
        if (cpu_we)    vram[cpu_addr]        <= cpu_wdata;
        if (tile_we)   tile_rom[tile_addr]   <= tile_wdata;
        if (xshift_we) xshift_rom[xshift_addr] <= xshift_wdata;
    end
    assign cpu_rdata = vram[cpu_addr];

    wire [4:0]  col_raw = xx[7:3] - 5'd1;         // (xx>>3)-1, wraps mod 32
    wire [4:0]  col     = xshift_rom[col_raw][4:0];
    wire [4:0]  row     = y[7:3];
    wire [9:0]  vaddr   = {row, col};             // row*32 + col
    wire [7:0]  code    = vram[vaddr];
    wire [2:0]  py      = y[2:0];
    wire [2:0]  px      = xx[2:0];
    wire [10:0] rom_row = {code, py};             // code*8 + py
    wire [7:0]  plane0  = tile_rom[rom_row];
    wire [7:0]  plane1  = tile_rom[{1'b1, rom_row}];
    wire        bit0    = plane0[3'd7 - px];
    wire        bit1    = plane1[3'd7 - px];
    wire [5:0]  color   = code[7:2];

    assign foreraw = {color, bit1, bit0};

endmodule
