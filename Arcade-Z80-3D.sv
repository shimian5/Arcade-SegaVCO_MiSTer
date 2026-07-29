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

assign AUDIO_S = 0;
assign AUDIO_L = 0;
assign AUDIO_R = 0;
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
	"Z80-3D;;",
	"-;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"-;",
	"P1,Dip Switches;",
	"P1O[27:25],Coin A,1C_1C,1C_2C,1C_3C,1C_6C,2C_1C,3C_1C,4C_1C,5C_1C;",
	"P1O[30:28],Coin B,1C_1C,1C_2C,1C_3C,1C_6C,2C_1C,3C_1C,4C_1C,5C_1C;",
	"P1O[31],DSW1 SW1:7 (Unknown),On,Off;",
	"P1O[32],DSW1 SW1:8 (Unknown),On,Off;",
	"P1O[33],Collisions,On,Off (Cheat);",
	"P1O[34],Accel By,Pedal,Button;",
	"P1O[35],Best 5 Scores,On,Off;",
	"P1O[36],Score Display,Off,On;",
	"P1O[37],Difficulty,Hard,Normal;",
	"P1O[39:38],Lives,3,4,5,6;",
	"P1O[40],Cabinet,Cockpit,Upright;",
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

	.buttons(buttons),
	.status(status),
	.status_menumask({status[5]}),

	.ps2_key(ps2_key)
);

// IN0/IN1/DSW1/DSW2 -- docs/PLAN.md phase 1 CPU/memory table, buckrog
// INPUT_PORTS_START in docs/reference/turbo.cpp. Joystick bit convention:
// [0]=Right [1]=Left [2]=Down [3]=Up [4]=Fire1 [5]=Fire2 [6]=Fire3
// [8]=Start1 [9]=Start2 [10]=Coin1 [11]=Coin2 [12]=Service1 (the
// start/coin/service extension bits used by other MiSTer arcade cores in
// this style, e.g. the Donkey Kong core T80 was vendored from). All
// active-low (idle = 1), matching MAME's ACTIVE_LOW convention -- pedal
// (accel-by-pedal DSW mode) is not wired yet, only the button-accel bits.
wire [7:0] in0 = {~joystick_0[3], ~joystick_0[2], ~joystick_0[6], ~joystick_0[5], ~joystick_1[8], 3'b111};
wire [7:0] in1 = {~joystick_0[10], ~joystick_0[11], ~joystick_0[12], 1'b1, ~joystick_0[8], ~joystick_0[4], ~joystick_0[1], ~joystick_0[0]};

wire [7:0] dsw1 = {status[32], status[31], status[30:28], status[27:25]};
wire [7:0] dsw2 = {status[40], status[39:38], status[37], status[36], status[35], status[34], status[33]};

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
wire reset = RESET | status[0] | buttons[1];

wire HBlank;
wire HSync;
wire VBlank;
wire VSync;
wire ce_pix;
wire [7:0] video_r, video_g, video_b;

z80_3d z80_3d
(
	.clk(clk_sys),
	.reset(reset),

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
	.video_b(video_b)
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
