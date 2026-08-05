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
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;  

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// Sound board 834-5122, modelled discretely in rtl/audio. AUDIO_S = 1
// because the mixer works in signed volts about the board's 6 V mid-rail.
// AUDIO_MIX = 0: the cabinet is mono, so there is nothing for the
// framework to blend.
assign AUDIO_S = 1;
assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;
assign AUDIO_MIX = 0;

assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"SegaVCO;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	// Every option below is listed so that the FIRST entry (status bit(s) =
	// 0, which is what MiSTer boots with) is the FACTORY DIP setting, i.e.
	// DSW1 = 0xC0 and DSW2 = 0x92 -- the PORT_DIPNAME defaults in
	// buckrog's INPUT_PORTS_START (docs/reference/turbo.cpp). Where the
	// factory setting is a 1 bit, the bit is INVERTED in the dsw1/dsw2
	// assembly below rather than by reordering the labels, so each label
	// keeps meaning what it says. Do not reorder these lists without
	// flipping the matching inversion.
	"P1,Dip Switches;",
	"P1-,DSW1;",
	"P1O[27:25],Coin A,1C_1C,1C_2C,1C_3C,1C_6C,2C_1C,3C_1C,4C_1C,5C_1C;",
	"P1O[30:28],Coin B,1C_1C,1C_2C,1C_3C,1C_6C,2C_1C,3C_1C,4C_1C,5C_1C;",
	"P1O[31],DSW1 SW1:7 (Unknown),Off,On;",
	"P1O[32],DSW1 SW1:8 (Unknown),Off,On;",
	"P1-,DSW2;",
	"P1O[33],Collisions,On,Off (Cheat);",
	"P1O[34],Accel By,Button,Pedal;",
	"P1O[35],Best 5 Scores,On,Off;",
	"P1O[36],Score Display,Off,On;",
	"P1O[37],Difficulty,Normal,Hard;",
	"P1O[39:38],Lives,3,4,5,6;",
	"P1O[40],Cabinet,Upright,Cockpit;",
	"-;",
	// Only the buttons the game actually has -- no placeholder entries. Turbo
	// (phase 3) adds its own inputs; those get declared when that core arrives
	// rather than being reserved here as dead names. Start/Coin are the last
	// two by convention, and P2 takes its own controller's copies of the SAME
	// bit positions (joystick_1[7]/[8]), so P2 start and P2 coin never land on
	// P1's pad. Names must match <buttons names="..."> in mra/*.mra.
	"J1,Fire,Accel Fast,Accel Slow,Start,Coin;",
	"-;",
	"T[0],Reset;",
	"R[0],Reset and close OSD;",
	"v,0;", // [optional] config version 0-99.
	        // If CONF_STR options are changed in incompatible way, then change version number too,
			  // so all options will get default values on first start.
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;

wire [31:0] joystick_0, joystick_1;

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

	.forced_scandoubler(forced_scandoubler),

	.joystick_0(joystick_0),
	.joystick_1(joystick_1),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),

	.buttons(buttons),
	.status(status),
	// bit1 = mod_turbo, reserved for Turbo's own DIP page(s) (Step 7 of
	// docs/WORKPLAN_TURBO_GRAPHICS.md) to hide Buck Rogers' P1 DIP page
	// and vice versa; no CONF_STR entry references it yet since Turbo has
	// no menu items of its own in this step. bit0 unchanged.
	.status_menumask({mod_turbo, status[5]}),

	.ps2_key(ps2_key)
);

// Game strap: ioctl_index 1 is the mod byte MRA part gen_mra.py emits
// after every game's ROM regions (00 = Buck Rogers, 01 = Turbo). One RBF,
// selected at ROM-load time -- see docs/WORKPLAN_TURBO_GRAPHICS.md Step 1.
reg [7:0] mod_game;
always @(posedge clk_sys) if (ioctl_wr && ioctl_index == 16'd1) mod_game <= ioctl_dout;
wire mod_turbo = mod_game[0];

// IN0/IN1/DSW1/DSW2 -- docs/PLAN.md phase 1 CPU/memory table, buckrog
// INPUT_PORTS_START in docs/reference/turbo.cpp. Joystick bit convention:
// [0]=Right [1]=Left [2]=Down [3]=Up are MiSTer's standard D-pad bits; the
// named buttons then start at [4] in "J1,..." order, so [4]=Fire,
// [5]=Accel Fast, [6]=Accel Slow, [7]=Start, [8]=Coin. All active-low
// (idle = 1), matching MAME's ACTIVE_LOW convention.
//
// P2's start and coin are read from joystick_1 at the SAME bit positions as
// P1's, which is the MiSTer convention -- taking them from spare joystick_0
// bits instead would put P2's start and coin on P1's controller.
//
// SERVICE1 (IN1 bit 5) and the TEST/service-mode line (IN1 bit 4) are tied
// inactive on purpose: neither had any observable effect in play, and a
// mapped button that does nothing is worse than no button. They are real
// hardware inputs (schematic sheet 4: I15=SERVICE, I14=TEST) and can be
// wired later if a use for them turns up.
//
// in0[5:4] are ACC.LO/ACC.HI (schematic sheet 4, PDF p32: two discrete
// opto-isolated lines on the control connector). The same two wires serve
// both accel modes -- SW2:2 only selects how the GAME reads them: fast/slow
// buttons in Button mode (the factory setting, wired here), or an inverted
// 2-bit Gray code from the pedal's opto pair in Pedal mode. No analog pedal
// source is wired, so selecting Pedal in the OSD leaves the throttle dead.
wire [7:0] in0 = {~joystick_0[3], ~joystick_0[2], ~joystick_0[6], ~joystick_0[5], ~joystick_1[7], 3'b111};
// NOTE in1[1:0]: MAME's IN1 is bit 0x01 = JOYSTICK_LEFT, bit 0x02 =
// JOYSTICK_RIGHT (turbo.cpp INPUT_PORTS_START(buckrog)), which is the
// OPPOSITE order from the MiSTer joystick convention above ([0]=Right,
// [1]=Left). These two bits were previously wired straight through in
// index order, which transposed the steering axis -- the ship (and with
// it the starfield's lateral sweep) banked the wrong way for a given
// stick direction. Cross them explicitly; do not "simplify" this back to
// [1],[0] order.
wire [7:0] in1 = {~joystick_0[8], ~joystick_1[8], 1'b1, 1'b1, ~joystick_0[7], ~joystick_0[4], ~joystick_0[0], ~joystick_0[1]};

// DSW assembly. Bit positions are buckrog's DSW1/DSW2 as read through
// port_2_r/port_3_r (the 4-bit bitswaps live in rtl/segavco.v, not here).
//
// SW1:7, SW1:8, "Accel by", "Difficulty" and "Cabinet" are INVERTED: their
// factory setting is a 1 bit (DSW1 = 0xC0, DSW2 = 0x92 per
// docs/reference/turbo.cpp), and MiSTer boots every status bit at 0. Without
// the inversion the core came up as SW1:7/8=On, Accel by Pedal, Difficulty
// HARD and Cabinet Cockpit -- three of them non-factory, and the Hard
// default in particular made the game materially harder than the same ROM
// in MAME. See docs/INVESTIGATION_sect2_reachability.md.
wire [7:0] dsw1 = {~status[32], ~status[31], status[30:28], status[27:25]};
wire [7:0] dsw2 = {~status[40], status[39:38], ~status[37], status[36], status[35], ~status[34], status[33]};

///////////////////////   CLOCKS   ///////////////////////////////

// 39.936 MHz core clock = 2x the Z80-3D board's 19.968 MHz master XTAL, per
// docs/PLAN.md "Clocking". Not exactly representable from the 50 MHz
// reference (the board's XTAL isn't a round number either), so
// rtl/pll/pll_0002.v targets Quartus's nearest legal PLL setting instead:
// 39,935,064 Hz, ~23 ppm low. Tighter than the crystal tolerance on real
// hardware, so this is not a meaningful source of timing error.
wire clk_sys;
wire pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.locked(pll_locked)
);

// NOTE: pll_locked is intentionally NOT gating reset. It was wired in during
// the hardening pass but never validated on real hardware, and the very
// first on-hardware test came back showing exactly the symptom a
// permanently-unlocked PLL would produce (core stuck in reset forever: ROM
// download over HPS still works since it's independent of core reset, but
// the CPU never executes) -- see docs/PLAN.md. Isolating the variable here
// until that's confirmed one way or the other.
// ioctl_download MUST be part of reset: the HPS streams the ROM blob into
// the CPUs' program ROM/RAM arrays over many thousands of cycles, and
// without holding the core in reset for that whole window both Z80s
// free-run executing partially-written memory, then are never reset once
// the download completes -- they simply continue from whatever arbitrary
// state they reached. That produces nondeterministic, boot-to-boot-varying
// corruption on real hardware (garbage sub-CPU state => wrong starfield
// direction//placement) which is structurally INVISIBLE in simulation,
// because sim/tb_z80_3d.cpp holds reset asserted across the entire
// download and releases it afterwards. Keep this in sync with that
// testbench behavior.
//
// (Distinct from the pll_locked experiment noted in docs/PLAN.md, which was
// removed because a never-locking PLL would hold the core in reset forever.
// ioctl_download is self-clearing when the transfer ends, so it cannot
// wedge the core the same way.)
wire reset = RESET | status[0] | buttons[1] | ioctl_download;

wire HBlank;
wire HSync;
wire VBlank;
wire VSync;
wire ce_pix;
wire [7:0] video_r, video_g, video_b;

// Sound board output, straight from the discrete model in rtl/audio.
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

	.in0(in0),
	.in1(in1),
	.dsw1(dsw1),
	.dsw2(dsw2),

	.hblank(HBlank),
	.vblank(VBlank),
	.hsync(HSync),
	.vsync(VSync),
	.ce_pix(ce_pix),

	.video_r(video_r),
	.video_g(video_g),
	.video_b(video_b),
	.audio_l(audio_l),
	.audio_r(audio_r)
);

assign CLK_VIDEO = clk_sys;
assign CE_PIXEL = ce_pix;

assign VGA_DE = ~(HBlank | VBlank);
assign VGA_HS = HSync;
assign VGA_VS = VSync;
assign VGA_R  = video_r;
assign VGA_G  = video_g;
assign VGA_B  = video_b;

reg  [26:0] act_cnt;
always @(posedge clk_sys) act_cnt <= act_cnt + 1'd1; 
assign LED_USER    = act_cnt[26]  ? act_cnt[25:18]  > act_cnt[7:0]  : act_cnt[25:18]  <= act_cnt[7:0];

endmodule
