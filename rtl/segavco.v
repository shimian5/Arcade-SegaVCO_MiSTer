// System top: main CPU, sub CPU, memory decode and video/mixer pipeline for
// the Sega Buck Rogers / Turbo boards (one RBF, selected by mod_turbo).
//
// All memory reads are registered so Quartus infers block RAM. No Z80 wait
// states are needed: cpu_a/sub_a stay stable for the whole T-state (ce_z80
// pulses once every 8 clks), far longer than the 1-clk read latency. The video
// path's registered reads form a fixed-depth pipeline; VIDEO_PIPE_LATENCY
// delay-matches hblank/vblank/hsync/vsync/ce_pix to the pixel data.
module segavco
(
	input  wire        clk,             // core clock, ~39.936 MHz nominal
	input  wire        reset,

	// Game strap from the MRA mod byte (ioctl_index 1): 0 = Buck Rogers, 1 = Turbo.
	// Selects between the games' data in LUTs loaded by $readmemh (palette_rom
	// here, xscale_lut in sprite_engine.v), the PROM layout and the CPU memory map.
	input  wire         mod_turbo,

	input  wire         ioctl_download,
	input  wire         ioctl_wr,
	input  wire [24:0]  ioctl_addr,
	input  wire [7:0]   ioctl_dout,
	// Qualifies ROM-blob writes against non-blob MRA transfers (index 1, the mod
	// byte) sharing the ioctl bus; see rom_download.v.
	input  wire [15:0]  ioctl_index,

	// IN0/IN1/DSW1/DSW2: player controls, coin/start/service and DIP switches
	// (bit layout per the buckrog input ports). All active-low (idle = 1).
	input  wire [7:0]   in0,
	input  wire [7:0]   in1,
	input  wire [7:0]   dsw1,
	input  wire [7:0]   dsw2,

	// Turbo-only I/O: its own IN0 layout, three DIP banks (DSW3's low nibble is
	// collision, forced 0 by the top level) and the free-running dial position
	// (steering_input.sv). Ignored when !mod_turbo.
	input  wire [7:0]   turbo_in0,
	input  wire [7:0]   turbo_dsw1,
	input  wire [7:0]   turbo_dsw2,
	input  wire [7:0]   turbo_dsw3,
	input  wire [7:0]   turbo_dial,

	output wire         hblank,
	output wire         vblank,
	output wire         hsync,
	output wire         vsync,
	output wire         ce_pix,
	output wire [7:0]   video_r,
	output wire [7:0]   video_g,
	output wire [7:0]   video_b,

	// Sound board 834-5122 (discrete/analog on real hardware), modelled in rtl/audio.
	output wire signed [15:0] audio_l,
	output wire signed [15:0] audio_r

`ifdef VERILATOR_SIM
	// Sim debug: real-time, zero-latency sprite_engine outputs for per-pixel dumps.
	, output wire [31:0] dbg_sprbits
	, output wire [7:0]  dbg_plb
	, output wire [9:0]  dbg_hpos
	, output wire [8:0]  dbg_vpos
	// Sim debug: raw Turbo road_gen/mixer_turbo outputs and the PPI0/1/3 inputs
	// driving them (real-time, not delay-matched).
	, output wire [7:0]  dbg_babit
	, output wire [15:0] dbg_bacol
	, output wire        dbg_road
	, output wire [7:0]  dbg_pen
	, output wire [3:0]  dbg_fbpla
	, output wire [2:0]  dbg_fbcol
	, output wire [7:0]  dbg_opa
	, output wire [7:0]  dbg_opb
	, output wire [7:0]  dbg_opc
	, output wire [7:0]  dbg_ipa
	, output wire [7:0]  dbg_ipb
	, output wire [7:0]  dbg_ipc
	, output wire [3:0]  dbg_collision
	, output wire [15:0] dbg_i8279_rd_count
	, output wire [7:0]  dbg_i8279_last_rl
	, output wire [15:0] dbg_i8279_wr_count
	, output wire [15:0] dbg_i8279_sel_count
	, output wire [15:0] dbg_ppi3_rd_count
	, output wire [7:0]  dbg_ppi3_last_inb
	, output wire [31:0] dbg_coll_sprbits_nz_count
	, output wire [31:0] dbg_coll_addr_nz_count
	, output wire [4:0]  dbg_coll_addr_max
	, output wire [3:0]  dbg_coll_max
	, output wire [15:0] dbg_coll_clear_count
	, output wire [15:0] dbg_coll_first_hit_frame
	// Sim debug: combinational read of the sub-CPU-written star bitmap (address y*256+x).
	, input  wire [15:0] dbg_bitmap_addr
	, output wire        dbg_bitmap_bit
	// Sim debug: combinational read of sub CPU work RAM (e000-e7ff).
	, input  wire [10:0] dbg_workram_addr
	, output wire [7:0]  dbg_workram_data
	// Sim debug: fg tilemap VRAM (c000-c7ff) read port; the HUD is plain ASCII tile codes.
	, input  wire [10:0] dbg_vram_addr
	, output wire [7:0]  dbg_vram_data
	// Sim debug: main CPU work RAM (f800-ffff) read port.
	, input  wire [10:0] dbg_mainram_addr
	, output wire [7:0]  dbg_mainram_data
	// Sim debug: CN1 ACC0-5 and BSEL0-1 as audio_top decodes them. Unused in real builds.
	, output wire [5:0]  dbg_cn1_acc
	, output wire [1:0]  dbg_cn1_bsel
	// Sim debug: Turbo audio taps forwarded from audio_top (OSEL and the signal
	// path after the channel, mixer and STK439 stage).
	, output wire        dbg_cn1_osel0
	, output wire [1:0]  dbg_cn1_osel12
	, output wire signed [15:0] dbg_turbo_othercars_f
	, output wire signed [15:0] dbg_turbo_othercars_w
	, output wire signed [15:0] dbg_turbo_mixer_f
	, output wire signed [15:0] dbg_turbo_mixer_w
	, output wire signed [15:0] dbg_turbo_out_l
	, output wire signed [15:0] dbg_turbo_out_r
	, output wire signed [63:0] dbg_turbo_amp_f_raw
	, output wire signed [63:0] dbg_turbo_amp_w_raw
	, output wire               dbg_turbo_amp_f_clip
	, output wire               dbg_turbo_amp_w_clip
`endif
);

	// ------------------------------------------------------------------
	// Clock enables
	// ------------------------------------------------------------------
	// Z80 CE: core_clk / 8 = 4.992 MHz, shared by both CPUs (both run from MASTER_CLOCK/4).
	reg [2:0] z80_div;
	wire      ce_z80 = (z80_div == 3'd0);
	always @(posedge clk) begin
		if (reset) z80_div <= 0;
		else       z80_div <= z80_div + 3'd1;
	end

	// ------------------------------------------------------------------
	// Video timing (already at 2x horizontal)
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
		.ioctl_index    (ioctl_index),
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

	// Buck Rogers' bgcolor ROM (8KB) shares the "road" download slot with Turbo's
	// road generator. Registered read.
	//
	// The slot spans 32KB but only the first 8KB is real ROM; the rest is 0xFF
	// filler. Gate the write on the low 8KB so the filler cannot alias back onto
	// the same entries and overwrite the real bytes.
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

	// VBLANK IRQ, cleared by the int-ack (M1 & IORQ) cycle. No interrupt controller
	// is modeled, so the bus floats to FF during int-ack, which IM0 (RST 38) and
	// IM1 CPUs handle identically. The sub CPU has no VBLANK IRQ; its /INT comes
	// from PPI0 port C bit 7 (sub_int_n).
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

	// Turbo has no sub CPU: hold it in reset under mod_turbo so it does not
	// free-run its all-0xFF ROM (an RST 38 loop) while its /INT (sub_int_n, from
	// ppi0_pc[7]) follows Turbo's opc[7] road-invert bit.
	cpu_z80 u_subcpu
	(
		.clk     (clk),
		.cen     (ce_z80),
		.reset_n (~(reset || mod_turbo)),
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

	// Trailing-edge, one-clock write strobe, as for the main CPU (see the memory
	// decode comment). sub_io_read stays a level: reads have no capture edge.
	wire sub_write_lvl = ~sub_mreq_n && ~sub_wr_n;
	reg  sub_write_d;
	always @(posedge clk) sub_write_d <= sub_write_lvl;
	wire sub_write   = sub_write_d && !sub_write_lvl;
	wire sub_io_read = ~sub_iorq_n && ~sub_rd_n;

	// sub_prg_map: 0000-1fff ROM (read), 0000-dfff write -> bitmap_w, e000-e7ff
	// work RAM (mirror 1800 covers e000-ffff with an 11-bit RAM).
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

	// Bitmap RAM (star layer): 256x224x1bit, addressed by sub_a directly
	// (addr == y*256+x for the 0000-dfff write window).
	wire sub_bitmap_we = sub_write && (sub_a < 16'hE000);
	reg bitmap_ram[0:57343];
	always @(posedge clk) if (sub_bitmap_we) bitmap_ram[sub_a] <= sub_do[0];

	// Sub CPU data-in mux: its entire I/O space reads the command latch
	// (ppi0_pa, written by the main CPU); memory space reads ROM or
	// mirrored work RAM.
	assign sub_di = (~sub_iorq_n) ? ppi0_pa :
					 (sub_a < 16'h2000) ? sub_rom_dout : sub_workram_dout;

	// ------------------------------------------------------------------
	// Main<->sub protocol: not software, but the 8255's group-A mode-2 output
	// handshake inside u_ppi0 (control word 0xC0 written once at boot):
	//   1. Main writes PPI0 port A (the command latch, ppi0_pa) and the 8255
	//      drives PC7 (/OBF) low. PC7 goes straight to the sub CPU's /INT
	//      (834-5120 sheet 5: IC90 pin 10 -> IC50 pin 16), so the write is the
	//      interrupt.
	//   2. The sub CPU's /IORQ goes straight back to PC6 (/ACK) (IC90 pin 11 <-
	//      IC50 pin 20). It pulses on the interrupt-acknowledge cycle and again
	//      on the ISR's IN; the first pulse raises /OBF, releasing /INT.
	//   3. Main polls port C bit 7 to see the command was consumed.
	// MAME clears the handshake a machine cycle later through its own scheduling;
	// that is an emulator artifact and is not reproduced.
	// ------------------------------------------------------------------
	wire sub_int_n = ppi0_pc[7];   // = /OBF, driven by u_ppi0 in mode 2

	// ------------------------------------------------------------------
	// Memory decode (main_prg_map)
	// ------------------------------------------------------------------
	// WRITE STROBES ARE TRAILING-EDGE, ONE CORE CLOCK WIDE.
	//
	// cpu_z80.v registers mreq_n/wr_n every clk, ungated by `cen`, while the data
	// bus changes on the `cen` edge. The raw ~mreq_n & ~wr_n window is 8 clks wide
	// but only its last clk carries the byte being written; the first 7 still hold
	// the previous bus value. Latching on every clk ends up right for RAMs (last
	// write wins), but combinationally used values (e.g. PPI0 port C driving fchg
	// and /INT) would see a 7-clk garbage excursion.
	//
	// A strobe from the trailing edge (wr_n just risen, cpu_a/cpu_do still hold
	// the write's address and data) latches the right byte exactly once. Do not
	// qualify with ce_z80: that pulse lands mid-window, where the data is stale.
	wire cpu_write_lvl = ~cpu_mreq_n && ~cpu_wr_n;
	reg  cpu_write_d;
	always @(posedge clk) cpu_write_d <= cpu_write_lvl;
	wire cpu_write = cpu_write_d && !cpu_write_lvl;

	// Buck Rogers decode.
	wire sel_rom_buck     = (cpu_a < 16'h8000);
	wire sel_vram_buck    = (cpu_a >= 16'hC000) && (cpu_a < 16'hC800);
	wire sel_ppi0_buck    = (cpu_a >= 16'hC800) && (cpu_a < 16'hD000);
	wire sel_ppi1_buck    = (cpu_a >= 16'hD000) && (cpu_a < 16'hD800);
	wire sel_i8279_buck   = (cpu_a >= 16'hD800) && (cpu_a < 16'hE000);
	wire sel_sprpos_buck  = (cpu_a >= 16'hE000) && (cpu_a < 16'hE400);
	wire sel_sprram_buck  = (cpu_a >= 16'hE400) && (cpu_a < 16'hE800);
	wire sel_io2_buck     = (cpu_a >= 16'hE800) && (cpu_a < 16'hF000); // IN0/IN1/DSW
	wire sel_workram_buck = (cpu_a >= 16'hF800);

	// Turbo decode (turbo_state::prg_map). Mirrored ranges decode only the top
	// address bits the real chip-select sees, e.g. "a000-a0ff mirror 0700" is
	// cpu_a[15:11] alone: a000-a7ff with bits[10:8] don't-care.
	wire sel_rom_turbo            = (cpu_a < 16'h6000);
	wire sel_sprram_turbo         = (cpu_a[15:11] == 5'b10100); // a000-a7ff
	wire sel_outlatch_turbo       = (cpu_a[15:11] == 5'b10101); // a800-afff
	wire sel_sprpos_turbo         = (cpu_a[15:11] == 5'b10110); // b000-b7ff
	wire sel_analog_reset_turbo   = (cpu_a[15:11] == 5'b10111); // b800-bfff
	wire sel_vram_turbo           = (cpu_a[15:11] == 5'b11100); // e000-e7ff
	wire sel_collision_clear_turbo= (cpu_a[15:11] == 5'b11101); // e800-efff
	wire sel_workram_turbo        = (cpu_a[15:11] == 5'b11110); // f000-f7ff
	wire sel_ppi0_turbo            = (cpu_a[15:8] == 8'hf8);
	wire sel_ppi1_turbo            = (cpu_a[15:8] == 8'hf9);
	wire sel_ppi2_turbo            = (cpu_a[15:8] == 8'hfa);
	wire sel_ppi3_turbo            = (cpu_a[15:8] == 8'hfb);
	wire sel_i8279_turbo           = (cpu_a[15:8] == 8'hfc);
	wire sel_in0_turbo             = (cpu_a[15:8] == 8'hfd);
	wire sel_collision_dsw3_turbo  = (cpu_a[15:8] == 8'hfe);

	// Combined selects: vram, ppi0/1, i8279, sprram, sprpos and work_ram are shared
	// between games, so each switches which decode drives it. Turbo-only resources
	// (outlatch/analog_reset/collision_clear/ppi2/ppi3/in0/collision_dsw3) are
	// gated on mod_turbo directly.
	wire sel_rom     = mod_turbo ? sel_rom_turbo     : sel_rom_buck;
	wire sel_vram    = mod_turbo ? sel_vram_turbo    : sel_vram_buck;
	wire sel_ppi0    = mod_turbo ? sel_ppi0_turbo    : sel_ppi0_buck;
	wire sel_ppi1    = mod_turbo ? sel_ppi1_turbo    : sel_ppi1_buck;
	wire sel_i8279   = mod_turbo ? sel_i8279_turbo   : sel_i8279_buck;
	wire sel_sprpos  = mod_turbo ? sel_sprpos_turbo  : sel_sprpos_buck;
	wire sel_sprram  = mod_turbo ? sel_sprram_turbo  : sel_sprram_buck;
	wire sel_io2     = !mod_turbo && sel_io2_buck; // IN0/IN1/DSW, Buck only
	wire sel_workram = mod_turbo ? sel_workram_turbo : sel_workram_buck;

	wire sel_ppi2           = mod_turbo && sel_ppi2_turbo;
	wire sel_ppi3           = mod_turbo && sel_ppi3_turbo;
	wire sel_outlatch       = mod_turbo && sel_outlatch_turbo;
	wire sel_analog_reset   = mod_turbo && sel_analog_reset_turbo;
	wire sel_collision_clear= mod_turbo && sel_collision_clear_turbo;
	wire sel_in0_t          = mod_turbo && sel_in0_turbo;
	wire sel_collision_dsw3 = mod_turbo && sel_collision_dsw3_turbo;

	// Turbo sprite RAM address fold (turbo_state::spriteram_r/w): the 8-bit
	// sub-address within the a000-a0ff/mirror window folds onto 128 physical
	// bytes. Done here so sprite_engine.v just takes a 10-bit address.
	wire [6:0] sprram_fold_turbo = (cpu_a[7:0] & 8'h07) | ((cpu_a[7:0] & 8'hf0) >> 1);
	wire [9:0] sprram_addr_final = mod_turbo ? {3'b0, sprram_fold_turbo} : cpu_a[9:0];

	wire [7:0] vram_rdata;
	fg_tilemap u_fg
	(
		.clk          (clk),
		.mod_turbo    (mod_turbo),
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
`ifdef VERILATOR_SIM
		, .dbg_vram_addr (dbg_vram_addr)
		, .dbg_vram_data (dbg_vram_data)
`endif
	);

	// pr-5196 (Buck Y-scale, 512B @ proms offset 0x100), pr-1119 (Turbo Y-scale,
	// 512B @ proms offset 0x200) and pr-5199 (Buck sprite color table, 1024B @
	// proms offset 0x700) forwarded from the shared PROMS blob. Full-width
	// subtraction before slicing (see rom_download.v).
	//
	// Y-scale goes through two always-active windows rather than one selected by
	// mod_turbo: mod_turbo (ioctl_index 1) arrives after the whole proms blob, so
	// it is not valid during download. sprite_engine.v keeps two Y-scale arrays
	// and muxes their output by mod_turbo instead, which only matters in play.
	wire        buck_yscale_we_fwd  = proms_we && (proms_wraddr >= 13'h100) && (proms_wraddr < 13'h300);
	wire [12:0] buck_yscale_off     = proms_wraddr - 13'h100;
	wire        turbo_yscale_we_fwd = proms_we && (proms_wraddr >= 13'h200) && (proms_wraddr < 13'h400);
	wire [12:0] turbo_yscale_off    = proms_wraddr - 13'h200;

	wire        sprcolor_we_fwd = proms_we && (proms_wraddr >= 13'h700) && (proms_wraddr < 13'hB00);
	wire [12:0] sprcolor_off    = proms_wraddr - 13'h700;

	reg [7:0] sprcolor_table[0:1023]; // pr-5199
	always @(posedge clk) if (sprcolor_we_fwd) sprcolor_table[sprcolor_off[9:0]] <= rom_dout;

	// ------------------------------------------------------------------
	// Turbo PROM sub-window routing. Turbo's proms blob has a different layout
	// from Buck's (see turbo_v.cpp and the MRA) but uses the same shared
	// proms_we/proms_wraddr slot as Buck's PROMs above.
	//
	// mixer_turbo.v owns PR-1118/1121/1122/1123 and road_gen.v owns PR-1114/1115/
	// 1117. PR-1116 (collision detect) is held here. PR-1279 (sound) is not loaded.
	// ------------------------------------------------------------------
	reg [7:0] turbo_pr1116[0:31];   // collision detect
	reg [7:0] turbo_pr1120[0:511];  // no consumer in MAME -- loaded, not wired

	// Not gated on mod_turbo: the strap byte (ioctl_index 1) arrives after the ROM
	// blob, so mod_turbo reads 0 for the whole PROM download. Buck's own PROM
	// writes (0x000-0x020, 0x100-0x300, 0x500-0x700, 0x700-0xB00) do not overlap
	// this window, so there is no aliasing risk.
	wire        turbo_pr1116_we = proms_we && (proms_wraddr >= 13'h040) && (proms_wraddr < 13'h060);
	wire        turbo_pr1120_we = proms_we && (proms_wraddr >= 13'h400) && (proms_wraddr < 13'h600);

	wire [12:0] turbo_pr1120_off = proms_wraddr - 13'h400;

	always @(posedge clk) begin
		if (turbo_pr1116_we) turbo_pr1116[proms_wraddr[4:0]]   <= rom_dout;
		if (turbo_pr1120_we) turbo_pr1120[turbo_pr1120_off[8:0]]  <= rom_dout;
	end

	// road_gen.v: five ROM-driven edge comparisons per pixel that replace Buck's
	// starfield/bgcolor background. Owns PR-1114/1115/1117 (forwarded from the
	// proms window above) and its own 5 road ROM banks (shared "road" slot, gated
	// by mod_turbo like bgcolorrom_we). PPI0/PPI1 are shared hardware: Turbo's
	// opa/opb/opc/ipa/ipb/ipc are the same ppi0/ppi1 pa/pb/pc wires, interpreted
	// differently by its software. fbcol0 = PPI3 port C bit 4 (turbo_fbcol[0]).
	wire [7:0]  turbo_babit;
	wire [15:0] turbo_bacol;
	wire        turbo_road;
	road_gen u_road
	(
		.clk        (clk),

		.road_we    (road_we),
		.road_addr  (road_wraddr),
		.road_wdata (rom_dout),

		.proms_we   (proms_we),
		.proms_addr (proms_wraddr),
		.proms_wdata(rom_dout),

		.y          (y_native),
		.xx         (xx_native),
		.opa        (ppi0_pa),
		.opb        (ppi0_pb),
		.opc        (ppi0_pc),
		.ipa        (ppi1_pa),
		.ipb        (ppi1_pb),
		.ipc        (ppi1_pc),
		.fbcol0     (turbo_fbcol[0]),

		.babit      (turbo_babit),
		.bacol      (turbo_bacol),
		.road       (turbo_road)
	);

	wire [7:0]  sprram_rdata, sprpos_rdata;
	wire [31:0] sprbits;
	wire [7:0]  spr_plb;
`ifdef VERILATOR_SIM
	assign dbg_sprbits = sprbits;
	assign dbg_plb      = spr_plb;
	assign dbg_hpos      = hpos;
	assign dbg_vpos      = vpos;
	assign dbg_babit = turbo_babit;
	assign dbg_bacol = turbo_bacol;
	assign dbg_road  = turbo_road;
	assign dbg_pen   = turbo_pen;
	assign dbg_fbpla = turbo_fbpla;
	assign dbg_fbcol = turbo_fbcol;
	assign dbg_opa = ppi0_pa;
	assign dbg_opb = ppi0_pb;
	assign dbg_opc = ppi0_pc;
	assign dbg_ipa = ppi1_pa;
	assign dbg_ipb = ppi1_pb;
	assign dbg_ipc = ppi1_pc;
	assign dbg_collision = turbo_collision_acc;
	assign dbg_bitmap_bit = bitmap_ram[dbg_bitmap_addr];
	assign dbg_workram_data  = sub_workram[dbg_workram_addr];
	assign dbg_mainram_data  = work_ram[dbg_mainram_addr];
`endif
	sprite_engine u_sprites
	(
		.clk              (clk),
		.reset            (reset),

		.mod_turbo        (mod_turbo),
		.road_in          (turbo_road),

		.cpu_sprram_we    (sel_sprram && cpu_write),
		.cpu_sprram_addr  (sprram_addr_final),
		.cpu_sprram_wdata (cpu_do),
		.cpu_sprram_rdata (sprram_rdata),

		.cpu_sprpos_we    (sel_sprpos && cpu_write),
		.cpu_sprpos_addr  (cpu_a[9:0]),
		.cpu_sprpos_wdata (cpu_do),
		.cpu_sprpos_rdata (sprpos_rdata),

		.sproms_we        (sprites_we),
		.sproms_addr      (sprites_wraddr),
		.sproms_wdata     (rom_dout),

		.buck_yscale_we   (buck_yscale_we_fwd),
		.buck_yscale_addr (buck_yscale_off[8:0]),
		.buck_yscale_wdata(rom_dout),
		.turbo_yscale_we   (turbo_yscale_we_fwd),
		.turbo_yscale_addr (turbo_yscale_off[8:0]),
		.turbo_yscale_wdata(rom_dout),

		.ce_pix           (ce_pix_int),
		.hblank           (hblank_raw),
		.hpos             (hpos),
		.vpos             (vpos),

		.obch             (obch), // PPI1 port C bits 0-2

		.sprbits          (sprbits),
		.plb              (spr_plb)
	);

	// ------------------------------------------------------------------
	// i8255 PPI0 (c800-c803, mirror 07fc) and PPI1 (d000-d003, mirror 07fc). Both
	// are programmed all-output on the real board, so the input ports are tied off.
	// ------------------------------------------------------------------
	wire [7:0] ppi0_dout, ppi0_pa, ppi0_pb, ppi0_pc;
	wire       ppi0_pc_wr;
	i8255 u_ppi0
	(
		.clk   (clk), .reset (reset),
		.cs    (sel_ppi0), .we (cpu_write), .addr (cpu_a[1:0]),
		.din   (cpu_do), .dout (ppi0_dout),
		.in_a  (8'hFF), .in_b (8'hFF), .in_c (8'hFF),
		// PC6 (/ACK) is the sub CPU's /IORQ, ungated, so it also fires on the
		// interrupt-acknowledge cycle (see "Main<->sub protocol").
		.ack_n (sub_iorq_n),
		.pa    (ppi0_pa), .pb (ppi0_pb), .pc (ppi0_pc),
		.pa_wr (), .pb_wr (), .pc_wr (ppi0_pc_wr)
	);

	// PPI1: port C = OBCH0-2, coin meters (bits 4/5), start lamp (bit 6); kept as
	// internal wires (no top-level port for meters/lamp). Ports A/B are the
	// sound-generator interface.
	wire [7:0] ppi1_dout, ppi1_pa, ppi1_pb, ppi1_pc;
	i8255 u_ppi1
	(
		.clk   (clk), .reset (reset),
		.cs    (sel_ppi1), .we (cpu_write), .addr (cpu_a[1:0]),
		.din   (cpu_do), .dout (ppi1_dout),
		.in_a  (8'hFF), .in_b (8'hFF), .in_c (8'hFF),
		.ack_n (1'b1),                 // PPI1 is mode 0 only
		.pa    (ppi1_pa), .pb (ppi1_pb), .pc (ppi1_pc),
		.pa_wr (), .pb_wr (), .pc_wr ()
	);
	// The sound board hangs off PPI1 ports A and B over a 20-pin flat cable.
	// PPI1 is shared hardware: for Turbo it carries ipa/ipb (road_gen's
	// AREA-select inputs), not Buck's trigger lines, so audio_top is muted under
	// Turbo. Idle values hold every active-low trigger high and every active-high
	// level (ship_on/game_on) low, so no spurious edge fires.
	wire [7:0] audio_ppi1_pa = mod_turbo ? 8'hFF : ppi1_pa;
	wire [7:0] audio_ppi1_pb = mod_turbo ? 8'h3F : ppi1_pb;
	audio_top u_audio
	(
		.clk     (clk),
		.rst_n   (~reset),
		.ppi1_pa (audio_ppi1_pa),
		.ppi1_pb (audio_ppi1_pb),
		// Turbo sound-board CN1 bundle (PPI2, u_ppi2). For Buck Rogers ppi2_pa/pb/pc
		// idle at the PPI reset value (8'hFF), so it cannot affect Buck's audio.
		.ppi2_pa (ppi2_pa),
		.ppi2_pb (ppi2_pb),
		.ppi2_pc (ppi2_pc),
		// IC40's D address input: sound-board DIP bit, mapped to the "Sound System"
		// MRA option.
		.turbo_dsw3_7 (turbo_dsw3[7]),
		// Selects which game's mix reaches audio_l/audio_r.
		.mod_turbo (mod_turbo),
		.audio_l (audio_l),
		.audio_r (audio_r),
		.sample_ce (),
		.dbg_cn1_acc  (dbg_cn1_acc),
		.dbg_cn1_bsel (dbg_cn1_bsel)
`ifdef VERILATOR_SIM
		, .dbg_cn1_osel0          (dbg_cn1_osel0)
		, .dbg_cn1_osel12         (dbg_cn1_osel12)
		, .dbg_turbo_othercars_f  (dbg_turbo_othercars_f)
		, .dbg_turbo_othercars_w  (dbg_turbo_othercars_w)
		, .dbg_turbo_mixer_f      (dbg_turbo_mixer_f)
		, .dbg_turbo_mixer_w      (dbg_turbo_mixer_w)
		, .dbg_turbo_out_l        (dbg_turbo_out_l)
		, .dbg_turbo_out_r        (dbg_turbo_out_r)
		, .dbg_turbo_amp_f_raw    (dbg_turbo_amp_f_raw)
		, .dbg_turbo_amp_w_raw    (dbg_turbo_amp_w_raw)
		, .dbg_turbo_amp_f_clip   (dbg_turbo_amp_f_clip)
		, .dbg_turbo_amp_w_clip   (dbg_turbo_amp_w_clip)
`endif
	);

	wire [2:0] obch          = ppi1_pc[2:0];
	wire       coin_meter1   = ppi1_pc[4];
	wire       coin_meter2   = ppi1_pc[5];
	wire       start_lamp    = ppi1_pc[6];

	// Video registers from PPI0: fchg = port C bits 0-2 (only bits 0-1 feed the
	// pr5198 address, see color_addr), mov = port B bits 0-5 (only bits 0-4 feed
	// the bgcolor address).
	wire [1:0] fchg = ppi0_pc[1:0];
	wire [5:0] mov  = ppi0_pb[5:0];

	// ------------------------------------------------------------------
	// i8279 (d800-d801, mirror 07fe); only DSW1 via RL is implemented (see
	// rtl/io/i8279.v).
	// ------------------------------------------------------------------
	wire [7:0] i8279_dout;
	i8279 u_i8279
	(
		.clk  (clk), .reset (reset),
		.cs   (sel_i8279), .we (cpu_write), .addr (cpu_a[0]),
		.din  (cpu_do), .dout (i8279_dout),
		.rl   (mod_turbo ? turbo_dsw1 : dsw1)
	);

	// Sim debug: count CPU reads of the i8279 data register (DSW1/RL path) and
	// latch the last rl value seen.
	reg [15:0] dbg_i8279_rd_count_r;
	reg [7:0]  dbg_i8279_last_rl_r;
	wire       i8279_rd_now = sel_i8279 && ~cpu_a[0] && ~cpu_rd_n && ~cpu_mreq_n;
	reg        i8279_rd_now_d;
	always @(posedge clk) begin
		i8279_rd_now_d <= i8279_rd_now;
		if (reset) begin
			dbg_i8279_rd_count_r <= 16'h0;
			dbg_i8279_last_rl_r  <= 8'h0;
		end else if (i8279_rd_now && !i8279_rd_now_d) begin
			dbg_i8279_rd_count_r <= dbg_i8279_rd_count_r + 16'h1;
			dbg_i8279_last_rl_r  <= mod_turbo ? turbo_dsw1 : dsw1;
		end
	end
	assign dbg_i8279_rd_count = dbg_i8279_rd_count_r;
	assign dbg_i8279_last_rl  = dbg_i8279_last_rl_r;

	reg [15:0] dbg_i8279_wr_count_r;
	reg [15:0] dbg_i8279_sel_count_r;
	reg        sel_i8279_d;
	always @(posedge clk) begin
		sel_i8279_d <= sel_i8279;
		if (reset) begin
			dbg_i8279_wr_count_r  <= 16'h0;
			dbg_i8279_sel_count_r <= 16'h0;
		end else begin
			if (sel_i8279 && cpu_write) dbg_i8279_wr_count_r <= dbg_i8279_wr_count_r + 16'h1;
			if (sel_i8279 && !sel_i8279_d) dbg_i8279_sel_count_r <= dbg_i8279_sel_count_r + 16'h1;
		end
	end
	assign dbg_i8279_wr_count  = dbg_i8279_wr_count_r;
	assign dbg_i8279_sel_count = dbg_i8279_sel_count_r;

	// ------------------------------------------------------------------
	// Turbo-only I/O.
	// ------------------------------------------------------------------

	// PPI2 (fa00-fa03, mirror 00fc): sound generator interface (sound_a_w/b_w/c_w,
	// the CN1 bundle to the sound board).
	wire [7:0] ppi2_dout, ppi2_pa, ppi2_pb, ppi2_pc;
	i8255 u_ppi2
	(
		.clk   (clk), .reset (reset),
		.cs    (sel_ppi2), .we (cpu_write), .addr (cpu_a[1:0]),
		.din   (cpu_do), .dout (ppi2_dout),
		.in_a  (8'hFF), .in_b (8'hFF), .in_c (8'hFF),
		.ack_n (1'b1),
		.pa    (ppi2_pa), .pb (ppi2_pb), .pc (ppi2_pc),
		.pa_wr (), .pb_wr (), .pc_wr ()
	);

	// PPI3 (fb00-fb03, mirror 00fc): port A = steering dial delta (analog_r),
	// port B = DSW2, port C write = fbpla/fbcol (inputs of road_gen.v and
	// mixer_turbo.v).
	reg [7:0] turbo_last_analog;
	always @(posedge clk) begin
		if (reset) turbo_last_analog <= 8'h0;
		else if (sel_analog_reset && cpu_write) turbo_last_analog <= turbo_dial;
	end
	wire [7:0] turbo_analog_delta = turbo_dial - turbo_last_analog;

	wire [7:0] ppi3_dout, ppi3_pa, ppi3_pb;
	wire       ppi3_pc_wr;
	wire [7:0] ppi3_pc;
	i8255 u_ppi3
	(
		.clk   (clk), .reset (reset),
		.cs    (sel_ppi3), .we (cpu_write), .addr (cpu_a[1:0]),
		.din   (cpu_do), .dout (ppi3_dout),
		.in_a  (turbo_analog_delta), .in_b (turbo_dsw2), .in_c (8'hFF),
		.ack_n (1'b1),
		.pa    (ppi3_pa), .pb (ppi3_pb), .pc (ppi3_pc),
		.pa_wr (), .pb_wr (), .pc_wr (ppi3_pc_wr)
	);
	// Sim debug: count CPU reads of PPI3 port B (DSW2) and latch the last
	// turbo_dsw2 value seen.
	reg [15:0] dbg_ppi3_rd_count_r;
	reg [7:0]  dbg_ppi3_last_inb_r;
	wire       ppi3_rd_now = sel_ppi3 && (cpu_a[1:0] == 2'd1) && ~cpu_rd_n && ~cpu_mreq_n;
	reg        ppi3_rd_now_d;
	always @(posedge clk) begin
		ppi3_rd_now_d <= ppi3_rd_now;
		if (reset) begin
			dbg_ppi3_rd_count_r <= 16'h0;
			dbg_ppi3_last_inb_r <= 8'h0;
		end else if (ppi3_rd_now && !ppi3_rd_now_d) begin
			dbg_ppi3_rd_count_r <= dbg_ppi3_rd_count_r + 16'h1;
			dbg_ppi3_last_inb_r <= turbo_dsw2;
		end
	end
	assign dbg_ppi3_rd_count = dbg_ppi3_rd_count_r;
	assign dbg_ppi3_last_inb = dbg_ppi3_last_inb_r;

	reg [3:0] turbo_fbpla;
	reg [2:0] turbo_fbcol;
	always @(posedge clk) begin
		if (reset) begin
			turbo_fbpla <= 4'h0;
			turbo_fbcol <= 3'h0;
		end else if (ppi3_pc_wr) begin
			turbo_fbpla <= ppi3_pc[3:0];
			turbo_fbcol <= ppi3_pc[6:4];
		end
	end

	// LS259 outlatch (a800-a807, mirror 07f8): bit0/1 coin meters, bit3 start
	// lamp. No top-level port exists for them.
	reg [7:0] turbo_outlatch;
	always @(posedge clk) begin
		if (reset) turbo_outlatch <= 8'h0;
		else if (sel_outlatch && cpu_write) turbo_outlatch[cpu_a[2:0]] <= cpu_do[0];
	end
	wire turbo_coin_meter1 = turbo_outlatch[0];
	wire turbo_coin_meter2 = turbo_outlatch[1];
	wire turbo_start_lamp  = turbo_outlatch[3];

	// Collision detection: turbo_collision_acc is the PR-1116-driven per-pixel
	// accumulator, declared below with the mixer_turbo instantiation.
	wire [3:0] turbo_collision = turbo_collision_acc;

	// Read back by the CPU ($fd00/IN0, $fe00/DSW3+collision). Reset to idle
	// values (IN0 idle-high per its active-low convention, DSW3+collision
	// uncollided) so a mid-session reset leaves no stale bytes.
	reg [7:0] turbo_in0_reg;
	always @(posedge clk) begin
		if (reset) turbo_in0_reg <= 8'hFF;
		else if (sel_in0_t) turbo_in0_reg <= turbo_in0;
	end

	reg [7:0] turbo_collision_dsw3_reg;
	always @(posedge clk) begin
		if (reset) turbo_collision_dsw3_reg <= 8'h00;
		else if (sel_collision_dsw3) turbo_collision_dsw3_reg <= {turbo_dsw3[7:4], turbo_collision};
	end

	// Sim debug: highest turbo_collision value reached and clear-pulse count.
	reg [3:0]  dbg_coll_max_r;
	reg [15:0] dbg_coll_clear_count_r;
	reg        coll_clear_now_d;
	wire       coll_clear_now = sel_collision_clear && cpu_write;
	always @(posedge clk) begin
		coll_clear_now_d <= coll_clear_now;
		if (reset) begin
			dbg_coll_max_r         <= 4'h0;
			dbg_coll_clear_count_r <= 16'h0;
		end else begin
			if (turbo_collision_acc > dbg_coll_max_r) dbg_coll_max_r <= turbo_collision_acc;
			if (coll_clear_now && !coll_clear_now_d) dbg_coll_clear_count_r <= dbg_coll_clear_count_r + 16'h1;
		end
	end
	assign dbg_coll_max         = dbg_coll_max_r;
	assign dbg_coll_clear_count = dbg_coll_clear_count_r;

	// Sim debug: latch the frame number of the first nonzero PROM collision hit.
	reg [15:0] dbg_coll_first_hit_frame_r;
	reg        dbg_coll_first_hit_seen_r;
	reg [15:0] dbg_vblank_count_r;
	always @(posedge clk) begin
		if (reset) begin
			dbg_coll_first_hit_frame_r <= 16'hFFFF;
			dbg_coll_first_hit_seen_r  <= 1'b0;
			dbg_vblank_count_r         <= 16'h0;
		end else begin
			if (vblank_rise) dbg_vblank_count_r <= dbg_vblank_count_r + 16'h1;
			if (!dbg_coll_first_hit_seen_r && !hblank_pipe[7] && !vblank_pipe[7] &&
				turbo_pr1116[turbo_coll_addr][3:0] != 4'h0) begin
				dbg_coll_first_hit_seen_r  <= 1'b1;
				dbg_coll_first_hit_frame_r <= dbg_vblank_count_r;
			end
		end
	end
	assign dbg_coll_first_hit_frame = dbg_coll_first_hit_frame_r;

	// ------------------------------------------------------------------
	// IN0/IN1/DSW reads (e800-e803, mirror 07fc); e802/e803 are DSW bitswaps
	// (buckrog_state::port_2_r/port_3_r).
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
					 sel_ppi0   ? ppi0_dout      :
					 sel_ppi1   ? ppi1_dout      :
					 sel_i8279  ? i8279_dout     :
					 sel_sprram ? sprram_rdata   :
					 sel_sprpos ? sprpos_rdata   :
					 sel_io2    ? io2_reg        :
					 sel_workram? work_ram_dout  :
					 sel_ppi2   ? ppi2_dout      :
					 sel_ppi3   ? ppi3_dout      :
					 sel_in0_t  ? turbo_in0_reg  :
					 sel_collision_dsw3 ? turbo_collision_dsw3_reg :
								  8'hFF;

	// ------------------------------------------------------------------
	// Video: native (pre-2x) coordinates for the fg tilemap / bitmap /
	// bgcolor fetches
	// ------------------------------------------------------------------
	wire [7:0] xx_native = hpos[9:1];
	wire [7:0] y_native  = vpos[7:0];
	wire [7:0] foreraw;

	// ------------------------------------------------------------------
	// Mixer priority chain (see mixer_buckrog.v):
	//   fg tier 1 -> sprite -> fg tier 2 -> star (bitmap) -> bgcolor
	// ------------------------------------------------------------------
	wire [8:0] color_addr = ({7'b0, foreraw[1:0]}) |
							({1'b0, foreraw & 8'hF8} >> 1) |
							({fchg, 7'b0});
	reg [7:0] forebits_reg;
	always @(posedge clk) forebits_reg <= color_table[color_addr];

	// sprbits/plb are real-time (0 latency vs. hpos/vpos). forebits_reg lands 5 clk
	// deep (fg_tilemap's 4 + color_table's 1), which is 1.25 output pixels
	// (ce_pix = clk/4). Every input to the final palbits mux must land on the same
	// whole number of pixels, or a stale layer is combined with a fresh one for
	// 1 clk in 4, garbling multi-colour sprites. Delay by 7 clk so this path
	// (7 + sprcolor_table's 1 = 8 clk = 2 pixels) matches the fg path re-timed to
	// 8 below.
	localparam SPR_TO_MIX_DELAY = 7;
	reg [39:0] spr_pipe [0:SPR_TO_MIX_DELAY-1];
	integer si;
	always @(posedge clk) begin
		spr_pipe[0] <= {sprbits, spr_plb};
		for (si = 1; si < SPR_TO_MIX_DELAY; si = si + 1) spr_pipe[si] <= spr_pipe[si-1];
	end
	wire [31:0] sprbits_d7 = spr_pipe[SPR_TO_MIX_DELAY-1][39:8];
	wire [7:0]  plb_d7     = spr_pipe[SPR_TO_MIX_DELAY-1][7:0];

	// LS148 priority encoder: index of the lowest-numbered set bit in plb (0-7),
	// or 4'hf if plb==0 (MAME: countl_zero(bitswap<8>(plb,0,1,2,3,4,5,6,7)) with
	// the mux==8 clamp folded in).
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

	wire [3:0]  mux             = find_lsb(plb_d7);
	wire [31:0] sprbits_shifted = sprbits_d7 >> mux[2:0];
	wire [3:0]  cd              = {sprbits_shifted[24], sprbits_shifted[16], sprbits_shifted[8], sprbits_shifted[0]};

	reg [7:0] sprcolor_dout;
	always @(posedge clk) sprcolor_dout <= sprcolor_table[{obch, mux[2:0], cd}];

	// One more register stage on the fg-tier-1 path so both operands of the final
	// select land at +8 clk (sprcolor_dout's cycle). forebits_reg is 5 deep, so
	// forebits_reg2..4 add the remaining 3 hops.
	reg [7:0] forebits_reg2, forebits_reg3, forebits_reg4;
	reg [3:0] mux_reg;
	always @(posedge clk) begin
		forebits_reg2 <= forebits_reg;
		forebits_reg3 <= forebits_reg2;
		forebits_reg4 <= forebits_reg3;
		mux_reg       <= mux;
	end

	// Star (bitmap RAM) / bgcolor branches are addressed from xx_native/y_native
	// directly, not from foreraw, so they need their own delay chain to land on
	// stage 8 with everything else: COORD_DELAY (7 regs) + the bitmap_ram/
	// bgcolorrom read (1 reg) = 8 hops = 2 whole output pixels. VIDEO_PIPE_LATENCY
	// is thus 9 (8 + palette_rom's 1).
	localparam COORD_DELAY = 7;
	reg [15:0] coord_pipe [0:COORD_DELAY-1];
	integer ci;
	always @(posedge clk) begin
		coord_pipe[0] <= {y_native, xx_native};
		for (ci = 1; ci < COORD_DELAY; ci = ci + 1) coord_pipe[ci] <= coord_pipe[ci-1];
	end
	wire [7:0] y_d7  = coord_pipe[COORD_DELAY-1][15:8];
	wire [7:0] xx_d7 = coord_pipe[COORD_DELAY-1][7:0];

	reg star_bit;
	always @(posedge clk) star_bit <= bitmap_ram[{y_d7, xx_d7}];

	reg [7:0] bgcolor_reg;
	always @(posedge clk) bgcolor_reg <= bgcolorrom[{mov[4:0], y_d7}];

	function [7:0] repack;
		input [7:0] f;
		repack = ((f & 8'h3c) << 2) | ((f & 8'h06) << 1) | (f & 8'h01);
	endfunction

	// repack_bg's shifts overflow 8 bits on purpose: MAME's palbits is a plain
	// int, and this is how the bgcolor branch reaches the upper 3/4 of the
	// 1024-entry (10-bit) palette. Keep the full 10-bit width end to end.
	function [9:0] repack_bg;
		input [7:0] p;
		repack_bg = ({2'b00, p} & 10'h0c0) | (({2'b00, p} & 10'h030) << 4) | (({2'b00, p} & 10'h00f) << 2);
	endfunction

	wire [9:0] palbits_buck = (!forebits_reg4[7]) ? palbits_fg :             // fg tier 1
						  (!mux_reg[3])       ? {2'b00, sprcolor_dout} : // sprite
						  (!forebits_reg4[6]) ? palbits_fg :             // fg tier 2
						  star_bit             ? 10'h0ff :                // bitmap/star
												  repack_bg(bgcolor_reg);  // bgcolor
	wire [9:0] palbits_fg = {2'b00, repack(forebits_reg4)};

	// mixer_turbo.v: bit-serial 16:1 mux, separate from Buck's priority chain.
	// sprbits is the same real-time wire Buck's path taps; foreraw/babit/bacol
	// come from fg_tilemap/road_gen, fbpla/fbcol from PPI3 port C.
	wire [7:0] turbo_pen;
	wire [31:0] turbo_coll_sprbits_d8;
	wire [7:0]  turbo_coll_babit_d8;
	mixer_turbo u_mixer_turbo
	(
		.clk         (clk),
		.proms_we    (proms_we),
		.proms_addr  (proms_wraddr),
		.proms_wdata (rom_dout),
		.sprbits     (sprbits),
		.foreraw     (foreraw),
		.babit       (turbo_babit),
		.bacol       (turbo_bacol),
		.fbpla       (turbo_fbpla),
		.fbcol       (turbo_fbcol),
		.pen         (turbo_pen),
		.coll_sprbits_d8 (turbo_coll_sprbits_d8),
		.coll_babit_d8   (turbo_coll_babit_d8)
	);

	// Collision detect. IC20 (PR-1116, TBP18S030 32x8 PROM; P-ROM board sheet
	// 2/10) has address inputs PLB0-2 (A0-A2) and SLIPAR/ACCIAR (A3-A4), i.e.
	// sprbits[26:24] and babit[4]/babit[5], matching turbo_v.cpp's
	// ((sprbits>>24)&7) | ((babit&0x30)>>1). Its output feeds a 74LS376 latch
	// (IC19) whose set/clear sequencing was not traced; the model OR-accumulates
	// every visible pixel, is read at fe00 low nibble and cleared by any write to
	// e800-efff. Uses mixer_turbo's cycle-8 sprbits_d8/babit_d8 taps, gated by
	// hblank_pipe[7]/vblank_pipe[7] (tapped 8 stages in to match) so blanking
	// garbage never registers; the schematic likewise gates the AREA5/ROAD latch
	// (IC30) with "TV BLANK".
	wire [4:0] turbo_coll_addr = {turbo_coll_babit_d8[5:4], turbo_coll_sprbits_d8[26:24]};
	reg  [3:0] turbo_collision_acc;
	always @(posedge clk) begin
		if (reset)
			turbo_collision_acc <= 4'h0;
		else if (sel_collision_clear && cpu_write)
			turbo_collision_acc <= 4'h0;
		else if (!hblank_pipe[7] && !vblank_pipe[7])
			turbo_collision_acc <= turbo_collision_acc | turbo_pr1116[turbo_coll_addr][3:0];
	end

	// Sim debug: count active-video cycles with sprbits[26:24] nonzero vs. cycles
	// where the PROM lookup reports a hit.
	reg [31:0] dbg_coll_sprbits_nz_count_r;
	reg [31:0] dbg_coll_addr_nz_count_r;
	reg [4:0]  dbg_coll_addr_max_r;
	always @(posedge clk) begin
		if (reset) begin
			dbg_coll_sprbits_nz_count_r <= 32'h0;
			dbg_coll_addr_nz_count_r    <= 32'h0;
			dbg_coll_addr_max_r         <= 5'h0;
		end else if (!hblank_pipe[7] && !vblank_pipe[7]) begin
			if (turbo_coll_sprbits_d8[26:24] != 3'h0) dbg_coll_sprbits_nz_count_r <= dbg_coll_sprbits_nz_count_r + 32'h1;
			if (turbo_pr1116[turbo_coll_addr][3:0] != 4'h0) dbg_coll_addr_nz_count_r <= dbg_coll_addr_nz_count_r + 32'h1;
			if (turbo_coll_addr > dbg_coll_addr_max_r) dbg_coll_addr_max_r <= turbo_coll_addr;
		end
	end
	assign dbg_coll_sprbits_nz_count = dbg_coll_sprbits_nz_count_r;
	assign dbg_coll_addr_nz_count    = dbg_coll_addr_nz_count_r;
	assign dbg_coll_addr_max         = dbg_coll_addr_max_r;

	wire [9:0] palbits = mod_turbo ? {2'b00, turbo_pen} : palbits_buck;

	// Combined palette: $readmemh cannot depend on mod_turbo, so both games' tables
	// load into one 2048-entry BRAM indexed by mod_turbo as MSB: Buck at 0-1023
	// (10-bit palbits), Turbo at 1024-1279 (8-bit pen, zero-extended by the two
	// 0 bits below).
	reg [23:0] palette_rom[0:2047];
	initial $readmemh("rtl/tables/palette_combined.hex", palette_rom);

	reg [23:0] rgb_reg;
	always @(posedge clk) rgb_reg <= palette_rom[{mod_turbo, palbits}];

	assign video_r = (hblank | vblank) ? 8'h0 : rgb_reg[23:16];
	assign video_g = (hblank | vblank) ? 8'h0 : rgb_reg[15:8];
	assign video_b = (hblank | vblank) ? 8'h0 : rgb_reg[7:0];

	// ------------------------------------------------------------------
	// Sync-bundle delay line: realigns hblank/vblank/hsync/vsync/ce_pix with the
	// pixel pipeline. Buck: 8 clk (2 pixels, see SPR_TO_MIX_DELAY/COORD_DELAY) +
	// palette_rom's 1 = 9. Turbo: mixer_turbo.v's 11-clk latency (3-deep
	// PR-1122 -> PR-1123 -> PR-1121 ROM-read chain) + 1 = 12. The shift registers
	// are sized for the larger and mod_turbo selects the tap, rather than
	// duplicating the delay line.
	// ------------------------------------------------------------------
	localparam VIDEO_PIPE_LATENCY_BUCK  = 9;
	localparam VIDEO_PIPE_LATENCY_TURBO = 12;
	localparam VIDEO_PIPE_LATENCY_MAX   = 12;

	wire [3:0] video_pipe_tap = (mod_turbo ? VIDEO_PIPE_LATENCY_TURBO : VIDEO_PIPE_LATENCY_BUCK) - 4'd1;

	reg [VIDEO_PIPE_LATENCY_MAX-1:0] hblank_pipe, vblank_pipe, hsync_pipe, vsync_pipe, ce_pix_pipe;
	always @(posedge clk) begin
		hblank_pipe <= {hblank_pipe[VIDEO_PIPE_LATENCY_MAX-2:0], hblank_raw};
		vblank_pipe <= {vblank_pipe[VIDEO_PIPE_LATENCY_MAX-2:0], vblank_raw};
		hsync_pipe  <= {hsync_pipe [VIDEO_PIPE_LATENCY_MAX-2:0], hsync_raw};
		vsync_pipe  <= {vsync_pipe [VIDEO_PIPE_LATENCY_MAX-2:0], vsync_raw};
		ce_pix_pipe <= {ce_pix_pipe[VIDEO_PIPE_LATENCY_MAX-2:0], ce_pix_int};
	end
	assign hblank = hblank_pipe[video_pipe_tap];
	assign vblank = vblank_pipe[video_pipe_tap];
	assign hsync  = hsync_pipe [video_pipe_tap];
	assign vsync  = vsync_pipe [video_pipe_tap];
	assign ce_pix = ce_pix_pipe[video_pipe_tap];


endmodule
