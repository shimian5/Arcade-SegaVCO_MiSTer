// Turbo mixer (schematic sheet 144): a bit-serial 16:1 multiplexer, not an
// ordinal priority chain -- the layer ordering is data (the contents of
// PR-1122/PR-1123), not structure. Follows MAME's turbo_state::screen_update.
//
// PR-1118/1121/1122/1123 are inferred arrays, read every cycle into registered
// outputs.
//
// LATENCY: the three inputs arrive at different fixed latencies behind the
// live native pixel (cycle 0):
//   sprbits     : cycle 0 (real-time)
//   babit/bacol : cycle 3 (road_gen.v pipeline)
//   foreraw     : cycle 4 (fg_tilemap.v FG_TILEMAP_LATENCY)
// All must land on the same cycle before being combined, otherwise one
// layer's stale sample is mixed with another's fresh one for part of each
// native pixel (this garbles multi-colour sprites). Cycle 8 (two output
// pixels, ce_pix = clk/4) is the common landing point, as in the Buck Rogers
// mixer in segavco.v: forebits' intrinsic latency (5) must round up to a
// multiple of 4 to keep sprbits' per-output-pixel phase correct.
//   sprbits     delayed 8 (0 -> 8)
//   babit/bacol delayed 5 (3 -> 8)
//   foreraw     delayed 4 (4 -> 8); forebits = pr1118[foreraw] read at cycle 4
//               (dout cycle 5), then delayed 3 more (5 -> 8)
// From cycle 8 the sequential ROM chain is priority = pr1122[...] (dout cycle
// 9), mx = pr1123[...] (cycle 10), pen = pr1121[...] (cycle 11). red/grn/blu
// are built at cycle 8 and carried to cycle 10 in plain hold registers (the
// pipeline taps have moved on by then).
// Total latency, live native pixel -> pen: 11 clk.
module mixer_turbo
(
	input  wire        clk,

	// PROM download: PR-1118 (256B @ proms offset 0x100), PR-1121 (512B @
	// 0x600), PR-1122 (1024B @ 0x800), PR-1123 (1024B @ 0xC00).
	input  wire         proms_we,
	input  wire [12:0]  proms_addr,
	input  wire [7:0]   proms_wdata,

	// Real-time (0-latency vs. hpos/vpos)
	input  wire [31:0]  sprbits,
	// fg_tilemap.v output, FG_TILEMAP_LATENCY (4) behind live xx/y
	input  wire [7:0]   foreraw,
	// road_gen.v outputs, 3 clk behind live xx/y/opa/opb/opc/ipa/ipb/ipc
	input  wire [7:0]   babit,
	input  wire [15:0]  bacol,
	// PPI3 port C: fbpla = data&0x0f, fbcol = (data>>4)&7
	input  wire [3:0]   fbpla,
	input  wire [2:0]   fbcol,

	output reg  [7:0]   pen,

	// Collision detect: pr1116[((sprbits>>24)&7) | ((babit&0x30)>>1)] is
	// accumulated by segavco.v every visible pixel. The already delay-matched
	// cycle-8 taps are exported so the sprbits/babit alignment is not
	// duplicated elsewhere.
	output wire [31:0]  coll_sprbits_d8,
	output wire [7:0]   coll_babit_d8
);

	// ------------------------------------------------------------------
	// PR-1118/1121/1122/1123
	// ------------------------------------------------------------------
	reg [7:0] pr1118[0:255];
	reg [7:0] pr1121[0:511];
	reg [7:0] pr1122[0:1023];
	reg [7:0] pr1123[0:1023];

	wire pr1118_we = proms_we && (proms_addr >= 13'h100) && (proms_addr < 13'h200);
	wire pr1121_we = proms_we && (proms_addr >= 13'h600) && (proms_addr < 13'h800);
	wire pr1122_we = proms_we && (proms_addr >= 13'h800) && (proms_addr < 13'hC00);
	wire pr1123_we = proms_we && (proms_addr >= 13'hC00) && (proms_addr < 13'h1000);

	wire [12:0] pr1118_off = proms_addr - 13'h100;
	wire [12:0] pr1121_off = proms_addr - 13'h600;
	wire [12:0] pr1122_off = proms_addr - 13'h800;
	wire [12:0] pr1123_off = proms_addr - 13'hC00;

	always @(posedge clk) begin
		if (pr1118_we) pr1118[pr1118_off[7:0]]  <= proms_wdata;
		if (pr1121_we) pr1121[pr1121_off[8:0]]  <= proms_wdata;
		if (pr1122_we) pr1122[pr1122_off[9:0]]  <= proms_wdata;
		if (pr1123_we) pr1123[pr1123_off[9:0]]  <= proms_wdata;
	end

	// ------------------------------------------------------------------
	// Stage: land sprbits/babit/bacol/foreraw+forebits all at cycle 8.
	// ------------------------------------------------------------------
	reg [31:0] sprbits_pipe [0:7];
	integer si;
	always @(posedge clk) begin
		sprbits_pipe[0] <= sprbits;
		for (si = 1; si < 8; si = si + 1) sprbits_pipe[si] <= sprbits_pipe[si-1];
	end
	wire [31:0] sprbits_d8 = sprbits_pipe[7];

	reg [23:0] road_pipe [0:4]; // {babit, bacol}, 5 stages (3 -> 8)
	integer ri;
	always @(posedge clk) begin
		road_pipe[0] <= {babit, bacol};
		for (ri = 1; ri < 5; ri = ri + 1) road_pipe[ri] <= road_pipe[ri-1];
	end
	wire [7:0]  babit_d8 = road_pipe[4][23:16];
	wire [15:0] bacol_d8 = road_pipe[4][15:0];

	assign coll_sprbits_d8 = sprbits_d8;
	assign coll_babit_d8   = babit_d8;

	reg [7:0] foreraw_pipe [0:3]; // 4 stages (4 -> 8)
	integer fi;
	always @(posedge clk) begin
		foreraw_pipe[0] <= foreraw;
		for (fi = 1; fi < 4; fi = fi + 1) foreraw_pipe[fi] <= foreraw_pipe[fi-1];
	end
	wire [7:0] foreraw_d8 = foreraw_pipe[3];

	// fbpla/fbcol (PPI3 port C) are cycle-0 real-time signals like sprbits, so
	// they are delayed by 8 to stay aligned with the other cycle-8 inputs.
	reg [3:0] fbpla_pipe [0:7];
	reg [2:0] fbcol_pipe [0:7];
	integer pi;
	always @(posedge clk) begin
		fbpla_pipe[0] <= fbpla;
		fbcol_pipe[0] <= fbcol;
		for (pi = 1; pi < 8; pi = pi + 1) begin
			fbpla_pipe[pi] <= fbpla_pipe[pi-1];
			fbcol_pipe[pi] <= fbcol_pipe[pi-1];
		end
	end
	wire [3:0] fbpla_d8 = fbpla_pipe[7];
	wire [2:0] fbcol_d8 = fbcol_pipe[7];

	// forebits = pr1118[foreraw]: address at foreraw's own cycle-4 arrival,
	// dout lands cycle 5, then 3 more stages (5 -> 8).
	reg [7:0] forebits_reg;
	always @(posedge clk) forebits_reg <= pr1118[foreraw];
	reg [7:0] forebits_pipe [0:2];
	integer bi;
	always @(posedge clk) begin
		forebits_pipe[0] <= forebits_reg;
		for (bi = 1; bi < 3; bi = bi + 1) forebits_pipe[bi] <= forebits_pipe[bi-1];
	end
	wire [7:0] forebits_d8 = forebits_pipe[2];

	// ------------------------------------------------------------------
	// Cycle 8: red/grn/blu and PR-1122 address.
	// ------------------------------------------------------------------
	// 16 bits wide: the three 74LS150s (IC38/39/40, P-ROM Board sheet 2/10)
	// are 16:1 selectors with D15 grounded (0) and D14 pulled high (1). Bit 15
	// must exist explicitly: the road surface pen is reached only via mx=15,
	// and an out-of-range select would be x in 4-state synthesis.
	wire [15:0] red8 = {1'b0, 1'b1, bacol_d8[4:0],  forebits_d8[0], sprbits_d8[7:0]};
	wire [15:0] grn8 = {1'b0, 1'b1, bacol_d8[9:5],  forebits_d8[1], sprbits_d8[15:8]};
	wire [15:0] blu8 = {1'b0, 1'b1, bacol_d8[14:10],forebits_d8[2], sprbits_d8[23:16]};

	wire [9:0] priority_addr8 = {fbpla_d8[2:0], sprbits_d8[31:25]};

	// mx_addr's other fields (PLB0/PLBE/PLBF/BABIT1-3/PLA3), captured at
	// cycle 8 so they are still valid at cycle 9 when priority is combined
	// with them.
	reg [6:0] mx_bits_reg; // {fbpla_d8[3], babit_d8[2:0], forebits_d8[3], foreraw_d8[7], sprbits_d8[24]}
	always @(posedge clk)
		mx_bits_reg <= {fbpla_d8[3], babit_d8[2:0], forebits_d8[3], foreraw_d8[7], sprbits_d8[24]};

	// red/grn/blu (and fbcol) are held to cycle 10, when mx is known, as the
	// same sample that was valid at cycle 8.
	reg [15:0] red_h1, grn_h1, blu_h1;   // cycle 8 -> 9
	reg [2:0]  fbcol_h1;
	always @(posedge clk) begin
		red_h1 <= red8;
		grn_h1 <= grn8;
		blu_h1 <= blu8;
		fbcol_h1 <= fbcol_d8;
	end
	reg [15:0] red_h2, grn_h2, blu_h2;   // cycle 9 -> 10
	reg [2:0]  fbcol_h2;
	always @(posedge clk) begin
		red_h2 <= red_h1;
		grn_h2 <= grn_h1;
		blu_h2 <= blu_h1;
		fbcol_h2 <= fbcol_h1;
	end

	// ------------------------------------------------------------------
	// Cycle 9: priority (registered ROM dout, addressed at cycle 8) and
	// mx's address.
	// ------------------------------------------------------------------
	reg [7:0] priority_reg;
	always @(posedge clk) priority_reg <= pr1122[priority_addr8];

	// mx address: bits[2:0]=priority&7, bit3=PLB0(sprbits[24]),
	// bit4=PLBE(foreraw[7]), bit5=PLBF(forebits[3]), bits[8:6]=BABIT1-3
	// (babit[2:0]), bit9=PLA3(fbpla[3]); mx_bits_reg already packs bits 9:3.
	wire [9:0] mx_addr9 = {mx_bits_reg, priority_reg[2:0]};

	// ------------------------------------------------------------------
	// Cycle 10: mx (registered ROM dout, addressed at cycle 9) and the
	// final pen address.
	// ------------------------------------------------------------------
	reg [7:0] mx_reg;
	always @(posedge clk) mx_reg <= pr1123[mx_addr9];

	wire [3:0] mx4 = mx_reg[3:0];
	wire [8:0] pen_addr10 = {fbcol_h2[2:1], ~blu_h2[mx4], ~grn_h2[mx4], ~red_h2[mx4], mx4};

	// ------------------------------------------------------------------
	// Cycle 11: pen (registered ROM dout, addressed at cycle 10).
	// ------------------------------------------------------------------
	always @(posedge clk) pen <= pr1121[pen_addr10];

endmodule
