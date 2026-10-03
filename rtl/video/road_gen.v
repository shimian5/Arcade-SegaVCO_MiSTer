// Turbo road generator (schematic sheets 141-144): five ROM-driven edge
// comparisons per native pixel that replace Buck Rogers' starfield/bgcolor
// background. Follows MAME's turbo_state::screen_update.
//
// The five ROM banks are independent inferred arrays, read every cycle into
// registered outputs (no combinational mux over a ROM). PR-1114/1115/1117 (the
// small colour/babit PROMs) are owned here, forwarded from the shared PROM
// download window.
//
// Pipeline (clk cycles from stable {y,xx,opa..ipc,fbcol0} to babit/bacol/road):
//   cycle 0: combinational address generation
//   cycle 1: bank0-4 and bacol_lo/hi dout registers
//   cycle 2: area[4:0] from bank dout + xx; babit address issued
//   cycle 3: babit lands; bacol delayed to match; road latch updates
// Total latency = 3 clk. xx/y are held for the whole native-pixel dwell, so
// the result is recomputed harmlessly every clk; only the delayed sample at
// the point of use matters. mixer_turbo.v delay-matches babit/bacol/road
// against the sprite and foreground paths.
module road_gen
(
	input  wire        clk,

	// ROM download: 32KB road slot, split into 5 banks by addr[14:12]
	// (0x0000/0x1000/0x2000/0x3000 = 4KB each, 0x4000 = 2KB). The slot is
	// shared with Buck Rogers' bgcolorrom in segavco.v and road_we is not
	// game-gated; both games' arrays are simply written in parallel and only
	// the selected game reads its own back.
	input  wire         road_we,
	input  wire [14:0]  road_addr,
	input  wire [7:0]   road_wdata,

	// PROM download: PR-1114/1115/1117 at window offsets 0x000/0x020/0x060,
	// 32B each. Not game-gated (Buck Rogers' PROMs live in separate arrays).
	input  wire         proms_we,
	input  wire [12:0]  proms_addr,
	input  wire [7:0]   proms_wdata,

	// Per-native-pixel inputs. opa/opb/opc are PPI0 port A/B/C; ipa/ipb/ipc
	// are PPI1 port A/B/C. fbcol0 is PPI3 port C bit 4 (fbcol & 1).
	input  wire [7:0]   y,
	input  wire [7:0]   xx,
	input  wire [7:0]   opa,
	input  wire [7:0]   opb,
	input  wire [7:0]   opc,
	input  wire [7:0]   ipa,
	input  wire [7:0]   ipb,
	input  wire [7:0]   ipc,
	input  wire         fbcol0,

	output reg  [7:0]   babit,
	output reg  [15:0]  bacol,
	output reg           road
);

	// ------------------------------------------------------------------
	// 5 road ROM banks
	// ------------------------------------------------------------------
	reg [7:0] bank0[0:4095], bank1[0:4095], bank2[0:4095], bank3[0:4095];
	reg [7:0] bank4[0:2047];

	wire [11:0] bank_off  = road_addr[11:0];
	wire [10:0] bank4_off = road_addr[10:0];

	// bank4 (AREA5, epr-1243) holds only 2KB, but the 0x4000-0x4FFF window is
	// 4KB. The MRA pads the download slot with 0xFF past 0x4800, which would
	// alias back onto bank4 0x000-0x7FF and overwrite the real data, so
	// range-gate the write (same as sproms_in_range in sprite_engine.v).
	wire bank4_in_range = (road_addr < 15'h4800);

	always @(posedge clk) begin
		if (road_we) case (road_addr[14:12])
			3'd0: bank0[bank_off] <= road_wdata;
			3'd1: bank1[bank_off] <= road_wdata;
			3'd2: bank2[bank_off] <= road_wdata;
			3'd3: bank3[bank_off] <= road_wdata;
			3'd4: if (bank4_in_range) bank4[bank4_off] <= road_wdata;
			default: ;
		endcase
	end

	// ------------------------------------------------------------------
	// PR-1114 (bacol low byte), PR-1115 (babit), PR-1117 (bacol high byte):
	// 32B each, @ proms offset 0x000/0x020/0x060.
	// ------------------------------------------------------------------
	reg [7:0] pr1114[0:31];
	reg [7:0] pr1115[0:31];
	reg [7:0] pr1117[0:31];

	// pr1117_we must end at the chip's own end (0x080), not at PR-1118's start
	// (0x100): the 0x080-0x0FF gap is 0xFF MRA filler, and since proms_addr[4:0]
	// wraps every 32 bytes it would overwrite pr1117 with 0xFF.
	wire pr1114_we = proms_we && (proms_addr < 13'h020);
	wire pr1115_we = proms_we && (proms_addr >= 13'h020) && (proms_addr < 13'h040);
	wire pr1117_we = proms_we && (proms_addr >= 13'h060) && (proms_addr < 13'h080);

	always @(posedge clk) begin
		if (pr1114_we) pr1114[proms_addr[4:0]] <= proms_wdata;
		if (pr1115_we) pr1115[proms_addr[4:0]] <= proms_wdata;
		if (pr1117_we) pr1117[proms_addr[4:0]] <= proms_wdata;
	end

	// ------------------------------------------------------------------
	// Stage 0 (comb): va/carry/sel/coch and the ROM addresses.
	// ------------------------------------------------------------------
	wire [7:0] va_sum  = y + opa;
	wire [7:0] va      = opc[7] ? va_sum : ~va_sum;

	wire [8:0] xb_sum  = {1'b0, xx} + {1'b0, opb};
	wire       carry   = xb_sum[8];

	wire [7:0] sel  = carry ? ipb : ipa;
	wire [3:0] coch = carry ? ipc[7:4] : ipc[3:0];

	wire [11:0] offs01 = {sel[3:0], va};
	wire [11:0] offs23 = {sel[7:4], va};
	wire [10:0] offs4  = {opc[5:0], xx[7:3]};

	wire [4:0] bacol_addr = {fbcol0, coch};

	// ------------------------------------------------------------------
	// Stage 1 (registered): ROM dout for all 5 banks + bacol lo/hi, with xx
	// delayed one cycle to stay aligned with the dout.
	// ------------------------------------------------------------------
	reg [7:0] bank0_dout, bank1_dout, bank2_dout, bank3_dout, bank4_dout;
	reg [7:0] bacol_lo_dout, bacol_hi_dout;
	always @(posedge clk) begin
		bank0_dout <= bank0[offs01];
		bank1_dout <= bank1[offs01];
		bank2_dout <= bank2[offs23];
		bank3_dout <= bank3[offs23];
		bank4_dout <= bank4[offs4];
		bacol_lo_dout <= pr1114[bacol_addr];
		bacol_hi_dout <= pr1117[bacol_addr];
	end

	reg [7:0] xx_d1;
	always @(posedge clk) xx_d1 <= xx;

	// ------------------------------------------------------------------
	// Stage 2 (comb from stage-1 registers): area[4:0].
	// "(rom_byte + xx) >> 8" is a left/right-of-edge carry test; AREA5 is a
	// bitmap-stripe test instead (no +xx).
	// ------------------------------------------------------------------
	wire [8:0] area0_sum = {1'b0, bank0_dout} + {1'b0, xx_d1};
	wire [8:0] area1_sum = {1'b0, bank1_dout} + {1'b0, xx_d1};
	wire [8:0] area2_sum = {1'b0, bank2_dout} + {1'b0, xx_d1};
	wire [8:0] area3_sum = {1'b0, bank3_dout} + {1'b0, xx_d1};
	wire area4_bit = ((bank4_dout << xx_d1[2:0]) & 8'h80) != 8'h00;

	wire [4:0] area = {area4_bit, area3_sum[8], area2_sum[8], area1_sum[8], area0_sum[8]};

	reg [4:0] area_reg;
	reg [7:0] bacol_lo_d2, bacol_hi_d2;
	always @(posedge clk) begin
		area_reg    <= area;
		bacol_lo_d2 <= bacol_lo_dout;
		bacol_hi_d2 <= bacol_hi_dout;
	end

	// ------------------------------------------------------------------
	// Stage 3 (registered): babit = pr1115[area]; bacol delay-matched; road
	// latch. SLIPAR/ACCIAR are babit bits 4/5; road latches high once ACCIAR
	// (bit 5) is seen and clears only at the next scanline.
	// ------------------------------------------------------------------
	reg [7:0] y_d3;
	reg       new_line;
	always @(posedge clk) begin
		y_d3     <= y;
		new_line <= (y != y_d3);
	end

	wire [7:0] babit_next = pr1115[area_reg];

	always @(posedge clk) begin
		babit <= babit_next;
		bacol <= {bacol_hi_d2, bacol_lo_d2};
		if (new_line)
			road <= 1'b0;
		else if (babit_next[5])
			road <= 1'b1;
	end

endmodule
