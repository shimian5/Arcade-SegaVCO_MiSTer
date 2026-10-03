// Sprite engine for the Sega 3D-era boards (Buck Rogers and Turbo).
//
// 16 sprite-RAM entries x 8 bytes, folded onto 8 hardware "levels" via
// level = sprnum & 7. Sprites are processed in order 0..15, so sprites 8-15
// overwrite what sprites 0-7 set up for the same level (real hardware
// behaviour). Each level has a private 32KB sprite-ROM bank (8 independent
// BRAMs). The maximum X-scale step is well under one pixel per pixel, so one
// fetch per level per output pixel is enough and no arbitration is needed.
//
// The runtime mod_turbo strap selects the Turbo differences: XSCALE_THRESHOLD,
// offset register width/wraparound, ROM bank size, Y-byte inversion,
// sprite-position RAM addressing and the self-termination test. Both games sit
// in the same bitstream, so these are switched at runtime. Register widths stay
// at Buck Rogers' (larger) sizes; Turbo's narrower values are computed in their
// native width and then zero-extended, which reproduces MAME's masked/uint16_t
// arithmetic (e.g. Turbo's ROM address is a true 14-bit mask, `(offs>>1)&0x3fff`).
//
// PR-5195 (the sprite state machine PROM) is intentionally not read: MAME's
// prepare_sprites() models that sequencer chip directly as boolean logic, as
// this module does. It is still downloaded with the "proms" blob.
//
// PIPELINE / TIMING:
//  - prepare_sprites runs as a state machine on the core clock during HBLANK,
//    computing level state for the scanline about to start. HBLANK is 128
//    ce_pix ticks = 512 clk (HTOTAL-HBSTART in video_timing.v); the FSM needs
//    at most 16 sprites x 15 states = 240 clk. Nothing reads level state until
//    active video resumes, so no double buffering is needed.
//  - get_sprite_bits (the per-pixel path) steps exactly once per ce_pix, as the
//    X-scale accumulator cadence is the timing reference. sprbits/plb are
//    combinational from registered per-level state, so they are valid on the
//    same clk as the ce_pix that advanced them (zero latency vs. hpos/vpos).
//    The caller delay-matches them against the fg-tilemap path.
//  - Sprite-position RAM is read one native pixel ahead (pos_prefetch_addr) so
//    the 1-clk BRAM latency does not add pipeline delay at the point of use.
//
// All memory reads are registered ("address every cycle, registered dout") so
// Quartus infers block RAM; the 8 sprite-ROM banks alone are 256KB.
module sprite_engine
#(
	// plb_end[16], 2 bits/entry {END,PLB}, packed entry15..entry0 MSB..LSB.
	// Buck Rogers only; Turbo's end test is a bitmask compare on pixdata.
	parameter [31:0] PLB_END          = {2'd2,2'd1,2'd1,2'd1, 2'd1,2'd1,2'd1,2'd1,
										  2'd1,2'd1,2'd1,2'd1, 2'd1,2'd1,2'd1,2'd0},
	parameter        VTOTAL           = 264,
	parameter        VDISP            = 224,               // visible scanlines, y=0..VDISP-1 (matches MAME cliprect.min_y/max_y)
	parameter        XSCALE_HEX_FILE  = "rtl/tables/xscale_combined.hex"
)
(
	input  wire        clk,
	input  wire        reset,

	// Game strap: selects buckrog (0) vs turbo (1) within xscale_lut and the
	// sprite engine's per-game behaviour.
	input  wire        mod_turbo,

	// CPU port: sprite RAM, e400-e7ff (16 entries x 8B = 128B; the full 1KB
	// span is mapped)
	input  wire         cpu_sprram_we,
	input  wire [9:0]   cpu_sprram_addr,
	input  wire [7:0]   cpu_sprram_wdata,
	output reg  [7:0]   cpu_sprram_rdata,

	// CPU port: sprite-position RAM, e000-e3ff (only bytes 0-511 are ever
	// read by the engine: sprpos[xx*2] | sprpos[xx*2+1]<<8, xx 0..255).
	input  wire         cpu_sprpos_we,
	input  wire [9:0]   cpu_sprpos_addr,
	input  wire [7:0]   cpu_sprpos_wdata,
	output reg  [7:0]   cpu_sprpos_rdata,

	// ROM download: 8 x 32KB sprite ROM banks (level = addr[17:15])
	input  wire         sproms_we,
	input  wire [17:0]  sproms_addr,
	input  wire [7:0]   sproms_wdata,

	// ROM download: PR-5196 (Buck Y-scale) / PR-1119 (Turbo Y-scale), 512B each,
	// in separate arrays. mod_turbo is not yet valid during download, so it can
	// only select which array's output is read, not which one is written.
	input  wire         buck_yscale_we,
	input  wire [8:0]   buck_yscale_addr,
	input  wire [7:0]   buck_yscale_wdata,
	input  wire         turbo_yscale_we,
	input  wire [8:0]   turbo_yscale_addr,
	input  wire [7:0]   turbo_yscale_wdata,

	// Video timing (undelayed / real-time)
	input  wire         ce_pix,
	input  wire         hblank,
	input  wire [9:0]   hpos,
	input  wire [8:0]   vpos,

	input  wire [2:0]   obch,        // PPI1 port C bits 0-2

	// Turbo only: road_gen's "road" latch (sprites 3-7 are disabled until the
	// car has left the road). It transitions once per scanline (0->1) and
	// road_gen settles in ~3 clk against an 8 clk native pixel, so no
	// delay-matching is done; at worst the transition is a few native pixels
	// off. Ignored when !mod_turbo.
	input  wire         road_in,

	// Real-time per-pixel output, zero added latency vs. hpos/vpos -- caller
	// delay-matches against the fg-tilemap path itself.
	output wire [31:0]  sprbits,     // CDA0-7=D0-7, CDB0-7=D8-15, CDC0-7=D16-23, CDD0-7=D24-31
	output wire [7:0]   plb          // PLB0-7
);

	// ------------------------------------------------------------------
	// Sprite RAM: true dual-port (CPU r/w + engine r/w)
	// ------------------------------------------------------------------
	reg [7:0] sprram[0:1023];

	always @(posedge clk) begin
		if (cpu_sprram_we) sprram[cpu_sprram_addr] <= cpu_sprram_wdata;
		cpu_sprram_rdata <= sprram[cpu_sprram_addr];
	end

	reg        eng_sprram_we;
	reg [9:0]  eng_sprram_addr;
	reg [7:0]  eng_sprram_wdata;
	reg [7:0]  eng_sprram_rdata;
	always @(posedge clk) begin
		if (eng_sprram_we) sprram[eng_sprram_addr] <= eng_sprram_wdata;
		eng_sprram_rdata <= sprram[eng_sprram_addr];
	end

	// ------------------------------------------------------------------
	// Sprite-position RAM: split into lo/hi byte banks so the engine can
	// read both bytes of a 16-bit horizontal-enable word in the same cycle
	// from two independent 2-port BRAMs, instead of needing a 3rd port on
	// one array. The engine-side read (below, pos_prefetch_addr) is
	// identical for both games -- xx directly indexes each bank regardless
	// of how the CPU laid the two bytes out -- so only the CPU-side
	// bank-select bit and index change with mod_turbo:
	//   Buck Rogers: sprpos[xx*2] | sprpos[xx*2+1]<<8 (interleaved pairs,
	//     bank select = addr[0], index = addr[9:1])
	//   Turbo:       sprpos[xx] | sprpos[xx+0x100]<<8 (two flat 256B
	//     blocks, bank select = addr[8], index = addr[7:0])
	// ------------------------------------------------------------------
	reg [7:0] sprpos_lo[0:511];
	reg [7:0] sprpos_hi[0:511];

	wire        cpu_sprpos_bank  = mod_turbo ? cpu_sprpos_addr[8] : cpu_sprpos_addr[0];
	wire        cpu_sprpos_we_lo = cpu_sprpos_we && !cpu_sprpos_bank;
	wire        cpu_sprpos_we_hi = cpu_sprpos_we &&  cpu_sprpos_bank;
	wire [8:0]  cpu_sprpos_idx   = mod_turbo ? {1'b0, cpu_sprpos_addr[7:0]} : cpu_sprpos_addr[9:1];
	reg  [7:0]  cpu_sprpos_rdata_lo, cpu_sprpos_rdata_hi;
	always @(posedge clk) begin
		if (cpu_sprpos_we_lo) sprpos_lo[cpu_sprpos_idx] <= cpu_sprpos_wdata;
		if (cpu_sprpos_we_hi) sprpos_hi[cpu_sprpos_idx] <= cpu_sprpos_wdata;
		cpu_sprpos_rdata_lo <= sprpos_lo[cpu_sprpos_idx];
		cpu_sprpos_rdata_hi <= sprpos_hi[cpu_sprpos_idx];
	end
	always @(posedge clk) cpu_sprpos_rdata <= cpu_sprpos_bank ? cpu_sprpos_rdata_hi : cpu_sprpos_rdata_lo;

	// Engine read port, prefetched one native pixel ahead: address issued
	// while displaying column xx-1 targets column xx, so the registered
	// dout is already valid by the time column xx's first (ix=0) pixel
	// needs it -- zero extra latency at the point of use. HTOTAL/2=320
	// matches video_timing.v's HTOTAL=640 (2x-horizontal domain).
	wire [8:0] xx_now = hpos[9:1];
	wire [8:0] pos_prefetch_addr = (xx_now == 9'd319) ? 9'd0 : (xx_now + 9'd1);
	reg  [7:0] he_lo_dout, he_hi_dout;
	always @(posedge clk) if (ce_pix) begin
		he_lo_dout <= sprpos_lo[pos_prefetch_addr];
		he_hi_dout <= sprpos_hi[pos_prefetch_addr];
	end

	// ------------------------------------------------------------------
	// 8 sprite-ROM banks, sized for Buck Rogers' native 32KB/level.
	//
	// The write-time decode (level=addr[17:15], offset=addr[14:0]) is the same
	// for both games and must not depend on mod_turbo: mod_turbo is latched
	// from a separate ioctl_index=1 transfer that the MiSTer loader sends only
	// after this ROM blob has streamed in, so it is not valid during sprite-ROM
	// download. The MRA pads each of Turbo's 8 levels to a full 32KB slot (16KB
	// real data + 16KB 0xFF filler) so that Turbo's data lands in the low half
	// of each bank, where the (mod_turbo-gated) read side expects it.
	// ------------------------------------------------------------------
	reg [7:0] sprom0[0:32767], sprom1[0:32767], sprom2[0:32767], sprom3[0:32767];
	reg [7:0] sprom4[0:32767], sprom5[0:32767], sprom6[0:32767], sprom7[0:32767];
	wire [2:0]  sproms_level = sproms_addr[17:15];
	wire [14:0] sproms_off   = sproms_addr[14:0];
	always @(posedge clk) begin
		if (sproms_we) case (sproms_level)
			3'd0: sprom0[sproms_off] <= sproms_wdata;
			3'd1: sprom1[sproms_off] <= sproms_wdata;
			3'd2: sprom2[sproms_off] <= sproms_wdata;
			3'd3: sprom3[sproms_off] <= sproms_wdata;
			3'd4: sprom4[sproms_off] <= sproms_wdata;
			3'd5: sprom5[sproms_off] <= sproms_wdata;
			3'd6: sprom6[sproms_off] <= sproms_wdata;
			3'd7: sprom7[sproms_off] <= sproms_wdata;
		endcase
	end

	// Per-level registered read ports, unrolled (a `case` cannot select between
	// separate `always` blocks). Sized for Buck's 15-bit address; Turbo's 14-bit
	// address is zero-extended into the same width.
	wire [14:0] rom_raddr [0:7];
	reg  [7:0]  rom_dout [0:7];
	always @(posedge clk) rom_dout[0] <= sprom0[rom_raddr[0]];
	always @(posedge clk) rom_dout[1] <= sprom1[rom_raddr[1]];
	always @(posedge clk) rom_dout[2] <= sprom2[rom_raddr[2]];
	always @(posedge clk) rom_dout[3] <= sprom3[rom_raddr[3]];
	always @(posedge clk) rom_dout[4] <= sprom4[rom_raddr[4]];
	always @(posedge clk) rom_dout[5] <= sprom5[rom_raddr[5]];
	always @(posedge clk) rom_dout[6] <= sprom6[rom_raddr[6]];
	always @(posedge clk) rom_dout[7] <= sprom7[rom_raddr[7]];

	// ------------------------------------------------------------------
	// Y-scale PROM: PR-5196 (Buck) / PR-1119 (Turbo), 512B each, separate
	// arrays, output muxed by mod_turbo.
	// ------------------------------------------------------------------
	reg [7:0] buck_yscale_rom[0:511];
	reg [7:0] turbo_yscale_rom[0:511];
	always @(posedge clk) begin
		if (buck_yscale_we)  buck_yscale_rom[buck_yscale_addr]   <= buck_yscale_wdata;
		if (turbo_yscale_we) turbo_yscale_rom[turbo_yscale_addr] <= turbo_yscale_wdata;
	end
	reg [8:0] yscale_raddr;
	reg [7:0] yscale_dout;
	always @(posedge clk)
		yscale_dout <= mod_turbo ? turbo_yscale_rom[yscale_raddr] : buck_yscale_rom[yscale_raddr];

	// ------------------------------------------------------------------
	// X-scale LUT: both games' 256-entry Q8.24 tables (tools/gen_tables.py) in
	// one BRAM, since $readmemh cannot depend on mod_turbo. mod_turbo is the
	// index MSB: buckrog at 0-255, turbo at 256-511.
	// ------------------------------------------------------------------
	reg [31:0] xscale_lut[0:511];
	initial $readmemh(XSCALE_HEX_FILE, xscale_lut);
	reg [7:0]  xscale_raddr;
	reg [31:0] xscale_dout;
	always @(posedge clk) xscale_dout <= xscale_lut[{mod_turbo, xscale_raddr}];

	// ------------------------------------------------------------------
	// Per-level runtime state (8 levels)
	// ------------------------------------------------------------------
	// Physical width is Buck Rogers' 17 bits (16-bit offset plus the pre-shift
	// bit); Turbo's 16-bit offset zero-extends into it (bit 16 always 0).
	localparam OFFSET_WIDTH = 17;

	reg [OFFSET_WIDTH-1:0] offset_reg [0:7];
	reg [31:0]             step_reg   [0:7];
	reg [31:0]             frac_reg   [0:7];
	reg [31:0]             latched_reg[0:7];
	reg [7:0]  plb_bit_reg;     // 1 bit per level
	reg [15:0] ve_reg;          // 1 bit per sprnum (0-15)
	reg [7:0]  lst_active;      // 1 bit per level, persists across pixels

	reg fire_pending[0:7];
	reg nibble_sel_pending[0:7];

	// Each per-level register is written from one place only, the per-level
	// always block in the generate loop below. The prepare_sprites FSM cannot
	// write them directly: Quartus cannot prove a runtime-indexed write and a
	// genvar-indexed write exclusive and reports multiple drivers. Instead the
	// FSM raises a one-cycle broadcast pulse (commit_*) that the target level's
	// own always block consumes.
	reg                     commit_pulse;
	reg [2:0]               commit_level;
	reg [OFFSET_WIDTH-1:0]  commit_offset;
	reg [31:0]              commit_step;

	// ------------------------------------------------------------------
	// prepare_sprites: per-scanline FSM, runs on the raw core clock
	// during HBLANK (see module header for budget analysis).
	//
	// Timing convention: a memory address issued (nonblocking-assigned)
	// while in state X is stable for the registered-read memory during
	// state X+1, so its data is captured/usable starting state X+2.
	// ------------------------------------------------------------------
	localparam ST_IDLE          = 4'd0;
	localparam ST_ISSUE_Y0      = 4'd1;
	localparam ST_ISSUE_Y1      = 4'd2;
	localparam ST_ISSUE_XS      = 4'd3;
	localparam ST_ISSUE_YS      = 4'd4;
	localparam ST_ISSUE_RBLO    = 4'd5;
	localparam ST_ISSUE_RBHI    = 4'd6;
	localparam ST_ISSUE_OFLO    = 4'd7;
	localparam ST_ISSUE_OFHI    = 4'd8;
	localparam ST_CAPTURE_LAST  = 4'd9;
	localparam ST_YSCALE_ADDR   = 4'd10;
	localparam ST_YSCALE_WAIT   = 4'd11;
	localparam ST_COMMIT        = 4'd12;
	localparam ST_COMMIT2       = 4'd13;
	localparam ST_NEXT          = 4'd14;

	reg [3:0] st;
	reg [3:0] idx;                 // sprnum, 0..15
	reg [7:0] y_target;            // scanline about to start (vpos+1, wrapped)

	reg [7:0] y_lo_reg, y_hi_reg, yscale_raw_reg;
	reg [7:0] rb_lo_reg, rb_hi_reg, off_lo_reg, off_hi_reg;
	reg       ve_bit_reg;

	reg hblank_d;
	always @(posedge clk) hblank_d <= hblank;
	wire hblank_rise = hblank && !hblank_d;

	wire [7:0] y_target_next = (vpos == VTOTAL-1) ? 8'd0 : (vpos[7:0] + 8'd1);

	// Gate on the full 9-bit vpos so the FSM runs exactly once per visible
	// scanline (y_target_next = 0..VDISP-1), as MAME's per-line loop does: at
	// vpos = VTOTAL-1 (wrap, prepares y=0) and vpos = 0..VDISP-2. No pass runs
	// during VBLANK.
	wire run_prepare_sprites = (vpos == VTOTAL-1) || (vpos < VDISP-1);

	// Two-stage carry ALU on the just-captured Y bytes (combinational).
	wire [7:0] y_lo_eff = mod_turbo ? ~y_lo_reg : y_lo_reg;
	wire [7:0] y_hi_eff = mod_turbo ? ~y_hi_reg : y_hi_reg;
	wire [8:0] alu_sum1 = {1'b0, y_target} + {1'b0, y_lo_eff};
	wire       alu_clo  = alu_sum1[8];
	wire [16:0] alu_sum2 = {8'b0, alu_sum1} + {1'b0, y_target, 8'b0} + {1'b0, y_hi_eff, 8'b0};
	wire       alu_chi  = alu_sum2[16];
	wire       alu_ve   = alu_clo & ~alu_chi;

	wire       writeback = ~((yscale_dout >> yscale_raw_reg[2:0]) & 1'b1);
	wire [15:0] existing_offset = {off_hi_reg, off_lo_reg};
	wire [15:0] rowbytes        = {rb_hi_reg, rb_lo_reg};
	wire [15:0] new_offset      = writeback ? (existing_offset + rowbytes) : existing_offset;

	always @(posedge clk) begin
		eng_sprram_we <= 1'b0;
		commit_pulse  <= 1'b0;

		case (st)
			ST_IDLE: begin
				if (hblank_rise && run_prepare_sprites) begin
					idx        <= 4'd0;
					y_target   <= y_target_next;
					st         <= ST_ISSUE_Y0;
				end
			end
			ST_ISSUE_Y0: begin
				eng_sprram_addr <= {idx, 3'd0};
				st <= ST_ISSUE_Y1;
			end
			ST_ISSUE_Y1: begin
				eng_sprram_addr <= {idx, 3'd1};
				st <= ST_ISSUE_XS;
			end
			ST_ISSUE_XS: begin
				y_lo_reg        <= eng_sprram_rdata;
				eng_sprram_addr <= {idx, 3'd2};
				st <= ST_ISSUE_YS;
			end
			ST_ISSUE_YS: begin
				y_hi_reg        <= eng_sprram_rdata;
				eng_sprram_addr <= {idx, 3'd3};
				st <= ST_ISSUE_RBLO;
			end
			ST_ISSUE_RBLO: begin
				xscale_raddr    <= eng_sprram_rdata ^ 8'hFF;  // byte2 = X-scale, inverted
				eng_sprram_addr <= {idx, 3'd4};
				st <= ST_ISSUE_RBHI;
			end
			ST_ISSUE_RBHI: begin
				yscale_raw_reg  <= eng_sprram_rdata;          // byte3 = Y-scale, NOT inverted
				eng_sprram_addr <= {idx, 3'd5};
				st <= ST_ISSUE_OFLO;
			end
			ST_ISSUE_OFLO: begin
				rb_lo_reg       <= eng_sprram_rdata;
				eng_sprram_addr <= {idx, 3'd6};
				st <= ST_ISSUE_OFHI;
			end
			ST_ISSUE_OFHI: begin
				rb_hi_reg       <= eng_sprram_rdata;
				eng_sprram_addr <= {idx, 3'd7};
				st <= ST_CAPTURE_LAST;
			end
			ST_CAPTURE_LAST: begin
				off_lo_reg <= eng_sprram_rdata;
				st <= ST_YSCALE_ADDR;
			end
			ST_YSCALE_ADDR: begin
				off_hi_reg   <= eng_sprram_rdata;
				ve_bit_reg   <= alu_ve;
					// Issue from the combinational ALU sum so yscale_dout
					// lands in ST_COMMIT.
				yscale_raddr <= {yscale_raw_reg[3], alu_sum1[7:0]};
				st <= ST_YSCALE_WAIT;
			end
			ST_YSCALE_WAIT: begin
				st <= ST_COMMIT;
			end
			ST_COMMIT: begin
				if (ve_bit_reg) begin
					commit_pulse  <= 1'b1;
					commit_level  <= idx[2:0];
						// Buck Rogers pre-shifts the offset (17-bit value);
						// Turbo does not (16-bit value, bit 16 stays 0).
					commit_offset <= mod_turbo ? {1'b0, new_offset} : {new_offset, 1'b0};
					commit_step   <= xscale_dout;
					ve_reg[idx]   <= 1'b1;

					eng_sprram_we    <= 1'b1;
					eng_sprram_addr  <= {idx, 3'd6};
					eng_sprram_wdata <= new_offset[7:0];
				end else begin
					ve_reg[idx] <= 1'b0;
				end
				st <= ST_COMMIT2;
			end
			ST_COMMIT2: begin
				if (ve_bit_reg) begin
					eng_sprram_we    <= 1'b1;
					eng_sprram_addr  <= {idx, 3'd7};
					eng_sprram_wdata <= new_offset[15:8];
				end
				st <= ST_NEXT;
			end
			ST_NEXT: begin
				if (idx == 4'd15) begin
					st <= ST_IDLE;
				end else begin
					idx <= idx + 4'd1;
					st  <= ST_ISSUE_Y0;
				end
			end
			default: st <= ST_IDLE;
		endcase
	end

	// ------------------------------------------------------------------
	// get_sprite_bits: real-time per-pixel path, 8 levels in parallel.
	// ------------------------------------------------------------------
	wire [15:0] he_word    = {he_hi_dout, he_lo_dout};
	wire [15:0] he_masked  = he_word & ve_reg;
	wire        active_pix = ce_pix && !hblank;
	wire        ix0        = active_pix && !hpos[0];
	wire [7:0]  he_or_mask = ix0 ? (he_masked[7:0] | he_masked[15:8]) : 8'h00;
	wire [7:0]  lst_eff    = lst_active | he_or_mask;

	// sprite_expand[16]: bit n of the nibble -> bit 8n of the 32-bit word
	function [31:0] sprite_expand_f;
		input [3:0] n;
		begin
			sprite_expand_f = {7'b0, n[3], 7'b0, n[2], 7'b0, n[1], 7'b0, n[0]};
		end
	endfunction

	wire [31:0] latched_masked [0:7];
	wire [7:0]  clear_lvl_vec;

	// X-scale fire threshold: Buck Rogers 0x800000, Turbo 0x1000000
	wire [31:0] xscale_threshold = mod_turbo ? 32'h01000000 : 32'h00800000;

	// ROM address from the 17-bit offset register: Buck Rogers uses offs[15:1];
	// Turbo masks to offs[14:1] (MAME's `(offs>>1)&0x3fff`), taken from the
	// 16-bit slice so wraparound is confined to 16 bits.
	function [14:0] rom_addr_from_offs;
		input        turbo;
		input [16:0] offs;
		begin
			rom_addr_from_offs = turbo ? {1'b0, offs[14:1]} : offs[15:1];
		end
	endfunction

	genvar lvl;
	generate
		for (lvl = 0; lvl < 8; lvl = lvl + 1) begin : levels
			// rom_raddr comes from a register captured at fire time
			// (fetch_addr_reg), not combinationally from offset_reg. offset_reg
			// takes its post-increment value on the same edge as the fire that
			// should fetch the pre-increment byte; tracking it live would
			// re-address the ROM before fire_pending consumes the result one
			// active_pix period later and return the next byte instead.
			reg [14:0] fetch_addr_reg;
			assign rom_raddr[lvl] = fetch_addr_reg;

			// Turbo: levels 3-7 are dead until road_in goes high this scanline;
			// levels 0-2 and all Buck Rogers levels are never masked. Gates the
			// fetch/advance path and the output path (latched_masked) like
			// MAME's local `sprlive`, but not lst_active's own accumulation.
			wire        road_gate = !mod_turbo || (lvl < 3) || road_in;
			wire        live      = lst_eff[lvl] && road_gate;
			wire [32:0] frac_sum = {1'b0, frac_reg[lvl]} + {1'b0, step_reg[lvl]};
			wire        fire     = live && (frac_sum >= {1'b0, xscale_threshold});

			wire [3:0] pixdata   = nibble_sel_pending[lvl] ? rom_dout[lvl][7:4] : rom_dout[lvl][3:0];
			wire [1:0] plb_end_v = PLB_END[pixdata*2 +: 2];
				// Buck Rogers: plb_end table lookup. Turbo: bitmask test, the
				// enable flip/flop is reset when (pixdata & 0x0c) == 0x04. Turbo's
				// PLB bit rides inside sprbits (pixdata bit 3 lands at bit 24), and
				// its mixer reads it from there rather than from plb.
			wire        turbo_end = (pixdata[3:2] == 2'b01);
			wire        lvl_end   = mod_turbo ? turbo_end : plb_end_v[1];
			assign clear_lvl_vec[lvl] = fire_pending[lvl] && lvl_end;

				// Sole driver of this level's offset/step/frac/latched/plb
				// registers: handles both the prepare_sprites commit (broadcast
				// via commit_pulse) and the per-pixel advance.
			wire commit_now = commit_pulse && (commit_level == lvl[2:0]);

				// offset_next: the post-increment offset a fire commits for the
				// FOLLOWING fire; this fire fetches with the current offset.
				// Buck Rogers decrements when offset bit 16 is set, wrapping the
				// 17-bit register. Turbo decrements when bit 15 is set, wrapping
				// at 16 bits (computed in a 16-bit slice so 0 wraps to 0xFFFF,
				// not into bit 16).
			wire [16:0] offset_next_buck =
				offset_reg[lvl] + (offset_reg[lvl][16] ? 17'h1FFFF : 17'h00001);
			wire [15:0] offset_next_turbo16 =
				offset_reg[lvl][15:0] + (offset_reg[lvl][15] ? 16'hFFFF : 16'h0001);
			wire [OFFSET_WIDTH-1:0] offset_next =
				mod_turbo ? {1'b0, offset_next_turbo16} : offset_next_buck;

			always @(posedge clk) begin
				if (commit_now) begin
					offset_reg[lvl]  <= commit_offset;
					fetch_addr_reg   <= rom_addr_from_offs(mod_turbo, commit_offset);
					step_reg[lvl]    <= commit_step;
					frac_reg[lvl]    <= 32'd0;
					latched_reg[lvl] <= 32'd0;
					plb_bit_reg[lvl] <= 1'b0;
					fire_pending[lvl] <= 1'b0;
				end else if (active_pix) begin
					if (live) begin
						frac_reg[lvl] <= fire ? (frac_sum[31:0] - xscale_threshold) : frac_sum[31:0];
						if (fire) begin
							offset_reg[lvl]         <= offset_next;
							fetch_addr_reg          <= rom_addr_from_offs(mod_turbo, offset_reg[lvl]);
							nibble_sel_pending[lvl] <= ~offset_reg[lvl][0];
							fire_pending[lvl]       <= 1'b1;
						end else begin
							fire_pending[lvl] <= 1'b0;
						end
					end else begin
						fire_pending[lvl] <= 1'b0;
					end

					if (fire_pending[lvl]) begin
						latched_reg[lvl] <= sprite_expand_f(pixdata) << lvl;
						plb_bit_reg[lvl] <= plb_end_v[0];
					end
				end
			end

			// Gate the output on lst_active (registered), not lst_eff:
			// lst_eff = lst_active | he_or_mask opens one active_pix period
			// before lst_active latches, which would reveal sprite data two
			// native pixels early. `live` (fire gating) keeps using lst_eff.
			assign latched_masked[lvl] = (lst_active[lvl] && road_gate) ? latched_reg[lvl] : 32'd0;
		end
	endgenerate

	// lst_active: cleared once per scanline at HBLANK start, then OR in
	// newly-enabled levels (he_or_mask at ix0) and AND out levels whose fetch
	// signalled END (clear_lvl_vec).
	always @(posedge clk) begin
		if (hblank_rise)       lst_active <= 8'h00;
		else if (active_pix)   lst_active <= lst_eff & ~clear_lvl_vec;
	end

	assign sprbits = latched_masked[0] | latched_masked[1] | latched_masked[2] | latched_masked[3] |
					  latched_masked[4] | latched_masked[5] | latched_masked[6] | latched_masked[7];
	assign plb     = lst_active & plb_bit_reg;

endmodule
