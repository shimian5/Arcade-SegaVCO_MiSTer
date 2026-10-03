// Foreground tilemap (Buck Rogers and Turbo).
//
// 32x32 grid of 8x8 tiles, 2bpp planar, code = raw VRAM byte, color = code>>2.
// Buck Rogers' column fetch is remapped through PR-5194 (an X-shift PROM):
//   col = pr5194[((xx>>3)-1) & 0x1f]
// Output "foreraw" is MAME's `color*4 + pixel`, an 8-bit raw pen for the mixer.
//
// PIPELINE: VRAM/tile-ROM/PROM reads are registered (one clk each) so Quartus
// infers block RAM instead of a large combinational mux, giving foreraw a
// fixed 4-clk latency behind xx/y. Each stage needs a different field of the
// native (xx,y) pair, and the live xx/y can change between stages at a native
// pixel boundary, which would fetch the leftmost pixel from the neighbouring
// tile column. So xx/y are captured once at stage 1 and delayed through a
// chain so every stage consumes the same sample. segavco.v delay-matches the
// sync/blank bundle by the same total depth (FG_TILEMAP_LATENCY plus the
// colour-table and palette lookups).
module fg_tilemap
(
	input  wire        clk,

	// Game strap: Turbo's column fetch has no PR-5194 X-shift remap. It is a
	// plain 8-native-pixel shift with the tilemap forced blank outside
	// [8, 0x108) (MAME turbo_v.cpp: `foreraw = (xx<8||xx>=0x108) ? 0 :
	// fore[xx-8]`). Everything downstream of "col" is common to both games.
	input  wire        mod_turbo,

	// CPU port -- video RAM, c000-c7ff (2KB span; only the low 1KB, the
	// 32x32 grid, is addressed by the tilemap fetch)
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

	// video side, native (pre-2x) coordinates
	input  wire [7:0]   xx,   // 0..255
	input  wire [7:0]   y,    // 0..255 (0..223 visible)
	output wire [7:0]   foreraw
`ifdef VERILATOR_SIM
	// Simulation-only combinational read port on the tilemap VRAM, for
	// comparing the HUD cell-for-cell against MAME.
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

	// Coordinate delay chain: re-time each field by the number of stages it
	// lags behind stage 1 so all stages use the same (xx,y) sample.
	reg [7:0] xx_d1, xx_d2, xx_d3;
	reg [7:0] y_d1, y_d2;
	always @(posedge clk) begin
		xx_d1 <= xx;    xx_d2 <= xx_d1;    xx_d3 <= xx_d2;
		y_d1  <= y;     y_d2  <= y_d1;
	end

	// Stage 1: X-shift PROM lookup -> tile column (Buck Rogers), or a plain
	// shift-by-8 (Turbo). Both are registered so latency is game-independent;
	// segavco.v's delay-matching constants are not runtime-switched.
	wire [4:0] col_raw       = xx[7:3] - 5'd1;          // (xx>>3)-1, wraps mod 32
	wire [4:0] turbo_col_raw = (xx - 8'd8) >> 3;         // (xx-8)>>3, wraps mod 32 via 8-bit truncation
	reg  [7:0] xshift_dout;
	reg  [4:0] turbo_col_reg;
	always @(posedge clk) begin
		xshift_dout   <= xshift_rom[col_raw];
		turbo_col_reg <= turbo_col_raw;
	end

	// Stage 2: VRAM lookup -> tile code (y delayed 1 to match stage 1)
	wire [4:0] col   = mod_turbo ? turbo_col_reg : xshift_dout[4:0];
	wire [9:0] vaddr = {y_d1[7:3], col};          // row*32 + col
	reg  [7:0] vram_dout;
	always @(posedge clk) vram_dout <= vram[vaddr];

	// Stage 3: tile ROM lookup (both planes) -> pixel planes + latched code
	// (y delayed 2)
	wire [10:0] rom_row = {vram_dout, y_d2[2:0]}; // code*8 + py
	reg  [7:0]  plane0_dout, plane1_dout, code_dout;
	always @(posedge clk) begin
		plane0_dout <= tile_rom[rom_row];
		plane1_dout <= tile_rom[{1'b1, rom_row}];
		code_dout   <= vram_dout;
	end

	// Stage 4: bit-select + pack (color*4 + pixel); xx delayed 3
	wire       bit0  = plane0_dout[3'd7 - xx_d3[2:0]];
	wire       bit1  = plane1_dout[3'd7 - xx_d3[2:0]];
	wire [5:0] color = code_dout[7:2];

	// Turbo's blanking window (MAME turbo_v.cpp). The ">=264" arm can never
	// fire since xx is 8 bits; it is kept to mirror the MAME source.
	wire turbo_blank = (xx_d3 < 8'd8) || ({1'b0, xx_d3} >= 9'd264);

	reg  [7:0] foreraw_reg;
	always @(posedge clk)
		foreraw_reg <= (mod_turbo && turbo_blank) ? 8'h00 : {color, bit1, bit0};
	assign foreraw = foreraw_reg;

endmodule
