//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {SDRAM_DQ, SDRAM_A, SDRAM_BA, SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nWE, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nCS} = 'Z;
// DDRAM/FB_* are driven by screen_rotate below.
assign FB_FORCE_BLANK = 0;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Sound board 834-5122, modelled discretely in rtl/audio. AUDIO_S = 1
// because the output is signed (centred on the board's 6 V mid-rail).
// AUDIO_MIX = 0: the cabinet is mono, so there is nothing to blend.
assign AUDIO_S = 1;
assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

// "Original" (ar==0) swaps to 3:4 when Turbo's rotated picture is being sent
// to the HDMI framebuffer (~no_rotate, as used by screen_rotate below);
// otherwise the portrait image would be stretched into 4:3.
// "Full Screen"/[ARC1]/[ARC2] (ar!=0) are explicit user overrides.
assign VIDEO_ARX = (!ar) ? (no_rotate ? 12'd4 : 12'd3) : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? (no_rotate ? 12'd3 : 12'd4) : 12'd0;

`include "build_id.v"
// Status bit map (one option per bit; add new options in free bits only):
//   [0]       Reset (T[0]/R[0], reserved by the framework)
//   [6]       Rotate HDMI (Turbo)
//   [7]       Gear Overlay (Turbo)
//   [10]      D-Pad Steering (Turbo)
//   [122:121] Aspect ratio
localparam CONF_STR = {
	"SegaVCO;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	// Turbo's native raster is portrait (ROT270); Buck Rogers is ROT0. This
	// option only affects the HDMI framebuffer-scaler path (screen_rotate
	// below writes a rotated copy to DDRAM); VGA is always the raw picture.
	// H0 hides these two Turbo-only entries when Buck Rogers is loaded
	// (status_menumask[0] = ~mod_turbo).
	"H0O[6],Rotate HDMI (Turbo),Auto,Off;",
	"H0O[7],Gear Overlay (Turbo),Off,On;",
	"H0O[10],D-Pad Steering (Turbo),Velocity,Position;",
	"-;",
	// DIP switch values are not declared here: per MiSTer arcade convention
	// they live in each game's MRA <switches>/<dip> elements and arrive over
	// ioctl_index==254 as up to 8 raw bytes (sw[0..7] below), so the OSD
	// saves them per game. The "DIP;" entry is the placeholder that makes
	// the OSD show the MRA-sourced DIP page at this position.
	"DIP;",
	"-;",
	// T[0]/R[0] both use status bit 0. They must come before J1: J1 is a
	// non-OSD directive (joystick button names) and belongs after all real
	// menu entries.
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	// Start/Coin use the shared bit positions (joystick_0/1[7]/[8]) in both
	// games; P2 reads the same positions from its own controller. Turbo's
	// Gear Shift/Pedal are appended so Buck's bit positions are undisturbed.
	// Names must match <buttons names="..."> in the MRA files.
	"J1,Fire,Accel Fast,Accel Slow,Start,Coin,Gear Shift,Pedal;",
	"jn,A,B,X,Start,Select,Y,R;",
	"v,0;", // [optional] config version 0-99.
	        // If CONF_STR options are changed in incompatible way, then change version number too,
	        // so all options will get default values on first start.
	"V,v",`BUILD_DATE
};

wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire [31:0] joystick_0, joystick_1;
wire [15:0] joystick_l_analog_0;
wire  [8:0] spinner_0;

wire        ioctl_download;
wire        ioctl_wr;
wire [24:0] ioctl_addr;
wire [7:0]  ioctl_dout;
wire [15:0] ioctl_index;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),


	.joystick_0(joystick_0),
	.joystick_1(joystick_1),
	.joystick_l_analog_0(joystick_l_analog_0),
	.spinner_0(spinner_0),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),

	.buttons(buttons),
	.status(status),
	.status_menumask({15'h0, ~mod_turbo}), // H0: hide Turbo-only rotate/steering entries on Buck Rogers

	.ps2_key(ps2_key)
);

// Game strap: ioctl_index 1 is the mod byte the MRA emits after the ROM
// regions (00 = Buck Rogers, 01 = Turbo). One RBF serves both games,
// selected at ROM-load time.
reg [7:0] mod_game;
always @(posedge clk_sys) if (ioctl_wr && ioctl_index == 16'd1) mod_game <= ioctl_dout;
wire mod_turbo = mod_game[0];

// DIP switches, MRA-sourced: each game's <switches> block streams up to 8
// raw bytes over ioctl_index==254, addressed by ioctl_addr[2:0]. sw[0] =
// DSW1, sw[1] = DSW2, sw[2] = DSW3, matching the physical DIP banks, so the
// dsw bytes below are used verbatim (no inversion or reordering).
reg [7:0] sw[0:7];
always @(posedge clk_sys) if (ioctl_wr && ioctl_index == 16'd254) sw[ioctl_addr[2:0]] <= ioctl_dout;

// Buck Rogers IN0/IN1. Joystick bit convention: [0]=Right [1]=Left [2]=Down
// [3]=Up are MiSTer's standard D-pad bits; the named buttons start at [4] in
// "J1,..." order: [4]=Fire, [5]=Accel Fast, [6]=Accel Slow, [7]=Start,
// [8]=Coin. All inputs are active-low (idle = 1).
//
// P2's start and coin come from joystick_1 at the same bit positions as P1's.
//
// SERVICE1 (IN1 bit 5) and TEST (IN1 bit 4) (sheet 4: I15=SERVICE, I14=TEST)
// are tied inactive; no button is mapped to them.
//
// in0[5:4] are ACC.LO/ACC.HI (sheet 4: two opto-isolated lines on the
// control connector). The same two wires serve both accel modes; SW2:2
// selects how the game reads them: fast/slow buttons in Button mode (wired
// here) or a 2-bit Gray code from the pedal's opto pair in Pedal mode. No
// analog pedal is wired, so Pedal mode leaves the throttle dead.
wire [7:0] in0 = {~joystick_0[3], ~joystick_0[2], ~joystick_0[6], ~joystick_0[5], ~joystick_1[7], 3'b111};
// in1[1:0]: the game's IN1 bit 0 is LEFT and bit 1 is RIGHT, the opposite
// of the MiSTer convention above ([0]=Right, [1]=Left), so they are crossed
// here.
wire [7:0] in1 = {~joystick_0[8], ~joystick_1[8], 1'b1, 1'b1, ~joystick_0[7], ~joystick_0[4], ~joystick_0[0], ~joystick_0[1]};

// Buck Rogers DSW1/DSW2: raw MRA bytes (see sw[] above); the 4-bit bitswaps
// of the port 2/3 reads live in rtl/segavco.v.
wire [7:0] dsw1 = sw[0];
wire [7:0] dsw2 = sw[1];

// ------------------------------------------------------------------
// Turbo IN0/DSW1/DSW2/DSW3 and controls.
// IN0: bits[1:0] = pedal (inverted 2-bit Gray code), bit2 = gear shift
// (active-high, toggle), bit3 = start1 (active-low), bit4 = service mode,
// bit5 = service1, bit6 = coin2, bit7 = coin1.
// Start/Coin reuse Buck's bit positions (joystick_0[7]/[8]).
// ------------------------------------------------------------------
wire pedal_btn = joystick_0[10];
wire [7:0] pedal_raw = pedal_btn ? 8'hFF : 8'h00;
wire [7:0] pedal_gray = (pedal_raw >> 6) ^ (pedal_raw >> 7) ^ 8'h03;

// The gear shift is a lever that stays in the last gear selected, so the
// reported bit toggles on each press (rising edge).
reg gear_toggle;
reg gear_btn_d;
always @(posedge clk_sys) begin
	gear_btn_d <= joystick_0[9];
	if (joystick_0[9] && !gear_btn_d) gear_toggle <= ~gear_toggle;
end

// bit6 (coin2) is P2's coin button, as in Buck's in1[6].
wire [7:0] turbo_in0 = {~joystick_0[8], ~joystick_1[8], 1'b1, 1'b1,
                         ~joystick_0[7], gear_toggle, pedal_gray[1:0]};

// Turbo DSW1/DSW2/DSW3: raw MRA bytes (see sw[] above).
wire [7:0] turbo_dsw1 = sw[0];
wire [7:0] turbo_dsw2 = sw[1];
wire [7:0] turbo_dsw3 = sw[2];

// Steering: the game reads a DELTA (dial - last_analog), not an absolute
// position. The delta (last_analog snapshot, reset by writes to b800-bfff)
// is computed in segavco.v with the PPI3 port A read; steering_input only
// produces the free-running dial position.
reg vblank_d;
always @(posedge clk_sys) vblank_d <= VBlank;
wire ce_frame = VBlank & ~vblank_d;

// Steering feel. The real wheel drives an x1 quadrature encoder (LS191
// counter) through ~5:1 gearing and a ~40-slot disk, so one hardware count
// is roughly 45 degrees of wheel rotation. The velocity ramp (RAMP_STEP=3,
// VEL_MAX=6, applied after a >>>1) ramps up over two held frames to a
// ceiling of 3 counts/frame, so taps stay small but a long hold can still
// turn the wheel fully. POS_MAX=48 gives the spring-return position mode the
// same 3 count/frame ceiling (the real wheel has no spring; that mode is a
// convenience). ANALOG_SHIFT=4 sets the analog stick's dead zone (~12.5%)
// and its full-deflection ceiling (127>>>4 = 7 counts/frame) independently
// of the d-pad SHIFT.
wire [7:0] turbo_dial;
steering_input #(
	.RAMP_STEP(9'sd3), .VEL_MAX(9'sd6), .POS_MAX(9'sd48), .SHIFT(4), .ANALOG_SHIFT(4)
) u_steering
(
	.clk_sys(clk_sys), .reset(reset), .ce_frame(ce_frame),
	.dpad_pos_mode(status[10]), // OSD "D-Pad Steering": 0 = velocity ramp (default), 1 = position w/ spring-return
	.analog_x(joystick_l_analog_0[7:0]),
	.dpad_left(joystick_0[1]), .dpad_right(joystick_0[0]),
	.spinner(spinner_0),
	.wheel_pos(turbo_dial)
);

///////////////////////   CLOCKS   ///////////////////////////////

// 39.936 MHz core clock = 2x the board's 19.968 MHz master XTAL. That is not
// exactly representable from the 50 MHz reference, so rtl/pll/pll_0002.v
// uses the nearest legal PLL setting, 39,935,064 Hz (~23 ppm low, within
// crystal tolerance).
wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

// pll_locked is intentionally not part of reset.
// ioctl_download must be: the HPS streams the ROM image into the CPUs'
// program memory over many thousands of cycles, and without reset held for
// that whole window the Z80s would free-run on partially written memory and
// never restart cleanly. The testbench holds reset across the download for
// the same reason.
wire reset = RESET | status[0] | buttons[1] | ioctl_download;

wire HBlank;
wire HSync;
wire VBlank;
wire VSync;
wire ce_pix;
wire [7:0] video_r, video_g, video_b;

// Sound board output from the discrete model in rtl/audio.
wire signed [15:0] core_audio_l, core_audio_r;
wire signed [15:0] audio_l, audio_r;

segavco segavco
(
	.clk(clk_sys),
	.reset(reset),

	.mod_turbo(mod_turbo),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),

	.in0(in0),
	.in1(in1),
	.dsw1(dsw1),
	.dsw2(dsw2),

	.turbo_in0(turbo_in0),
	.turbo_dsw1(turbo_dsw1),
	.turbo_dsw2(turbo_dsw2),
	.turbo_dsw3(turbo_dsw3),
	.turbo_dial(turbo_dial),

	.hblank(HBlank),
	.vblank(VBlank),
	.hsync(HSync),
	.vsync(VSync),
	.ce_pix(ce_pix),

	.video_r(video_r),
	.video_g(video_g),
	.video_b(video_b),
	.audio_l(core_audio_l),
	.audio_r(core_audio_r)
);

// Turbo's F+W mono sum (the cabinet's single speaker output) is done in rtl/audio/audio_top.sv.
assign audio_l = core_audio_l;
assign audio_r = core_audio_r;

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL = ce_pix;

assign VGA_DE = ~(HBlank | VBlank);
assign VGA_HS = HSync;
assign VGA_VS = VSync;
// Gear overlay (Turbo, OSD option): a small "L"/"H" box beside the TIME
// readout showing the lever position the game is reading (gear_toggle,
// IN0 bit 2: 1 = high gear). Not on the original board; like MAME's lever
// artwork it is only a display aid, off by default.
// gx/gy count active pixels/lines of the native 512x224 raster. The raster is
// shown rotated 90 deg CCW, so a glyph column runs along +gy and a glyph row
// runs along -gx.
localparam [8:0] GEAR_X0 = 9'd452;
localparam [7:0] GEAR_Y0 = 8'd160;

reg [9:0] gx;
reg [8:0] gy;
reg       gear_hb_d;
always @(posedge CLK_VIDEO) if (ce_pix) begin
	gear_hb_d <= HBlank;
	gx <= HBlank ? 10'd0 : gx + 1'd1;
	if (VBlank)                      gy <= 9'd0;
	else if (HBlank && !gear_hb_d)   gy <= gy + 1'd1;
end

wire [9:0] gear_dx = gx - {1'b0, GEAR_X0};
wire [8:0] gear_dy = gy - {1'b0, GEAR_Y0};
wire       gear_box = (gear_dx < 10'd8) && (gear_dy < 9'd8);
wire [2:0] gear_row = 3'd7 - gear_dx[2:0];
wire [2:0] gear_col = gear_dy[2:0];

// 8x8 glyphs, bit 7 = leftmost column of the upright letter.
function [7:0] gear_glyph_row(input high, input [2:0] row);
	case (row)
		3'd3:    gear_glyph_row = high ? 8'h7E : 8'h60;   // H crossbar / L stem
		3'd6:    gear_glyph_row = high ? 8'h66 : 8'h7E;   // L foot
		3'd7:    gear_glyph_row = 8'h00;
		default: gear_glyph_row = high ? 8'h66 : 8'h60;
	endcase
endfunction

wire gear_on     = status[7] & mod_turbo;
wire [7:0] gear_bits = gear_glyph_row(gear_toggle, gear_row);
wire gear_pixel  = gear_bits[3'd7 - gear_col];
wire gear_active = gear_on & gear_box;
wire [7:0] gear_c = gear_pixel ? 8'hFF : 8'h00;

assign VGA_R  = gear_active ? gear_c : video_r;
assign VGA_G  = gear_active ? gear_c : video_g;
assign VGA_B  = gear_active ? gear_c : video_b;

// Turbo's native raster is portrait (ROT270); Buck Rogers is ROT0 and never
// rotates. Writes a rotated copy of the final VGA_* picture into the DDRAM
// framebuffer for the HDMI scaler path; VGA_* itself stays unrotated.
wire no_rotate = ~mod_turbo | status[6];
screen_rotate screen_rotate
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),

	.VGA_R(VGA_R),
	.VGA_G(VGA_G),
	.VGA_B(VGA_B),
	.VGA_HS(VGA_HS),
	.VGA_VS(VGA_VS),
	.VGA_DE(VGA_DE),

	.rotate_ccw(1'b1),
	.no_rotate(no_rotate),
	.flip(1'b0),
	.video_rotated(),

	.FB_EN(FB_EN),
	.FB_FORMAT(FB_FORMAT),
	.FB_WIDTH(FB_WIDTH),
	.FB_HEIGHT(FB_HEIGHT),
	.FB_BASE(FB_BASE),
	.FB_STRIDE(FB_STRIDE),
	.FB_VBL(FB_VBL),
	.FB_LL(FB_LL),

	.DDRAM_CLK(DDRAM_CLK),
	.DDRAM_BUSY(DDRAM_BUSY),
	.DDRAM_BURSTCNT(DDRAM_BURSTCNT),
	.DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DIN(DDRAM_DIN),
	.DDRAM_BE(DDRAM_BE),
	.DDRAM_WE(DDRAM_WE),
	.DDRAM_RD(DDRAM_RD)
);

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1;
assign LED_USER    = act_cnt[26]  ? act_cnt[25:18]  > act_cnt[7:0]  : act_cnt[25:18]  <= act_cnt[7:0];

endmodule
