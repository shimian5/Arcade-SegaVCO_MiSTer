// Shared Z80-3D video timing generator.
//
// Runs entirely in the 2x-horizontal output pixel domain: HTOTAL 640 / HBSTART
// 512, VTOTAL 264 / VBSTART 224, ce_pix at core_clk/4 (9.984 MHz @ 39.936 MHz).
//
// hpos/vpos are free-running counters (not blanked outside the active area)
// so downstream modules can use them for ROM/RAM addressing during blanking
// (e.g. sprite preparation during HBLANK).
module video_timing
(
	input  wire       clk,
	input  wire       ce_pix,     // pixel clock enable, asserted every 4th clk
	input  wire       reset,

	output reg  [9:0] hpos,       // 0..639
	output reg  [8:0] vpos,       // 0..263
	output wire       hblank,
	output wire       vblank,
	output wire       hsync,
	output wire       vsync,
	output wire       vblank_rise // one ce_pix pulse at the start of VBLANK
);

	localparam HTOTAL   = 640;
	localparam HBSTART  = 512;
	// The original board's H SYNC (82S141 IC78 pin 9, pr-5197) is high for native
	// counts 264..303, i.e. 528..607 here (8.01 us), leaving only 3.2 us of back
	// porch; composite encoders such as the AD723 then fail to insert colour
	// burst. Keep the authentic leading edge and blanking but use an NTSC-width
	// pulse: 48 counts = 4.81 us, giving a 6.41 us back porch.
	localparam HSSTART  = 528;
	localparam HSEND    = 576;
	localparam VTOTAL   = 264;
	localparam VBSTART  = 224;
	localparam VSSTART  = 232;
	localparam VSEND    = 240;

	assign hblank = (hpos >= HBSTART);
	assign vblank = (vpos >= VBSTART);
	assign hsync  = (hpos >= HSSTART) && (hpos < HSEND);
	assign vsync  = (vpos >= VSSTART) && (vpos < VSEND);

	reg vblank_d;
	assign vblank_rise = ce_pix && vblank && !vblank_d;

	always @(posedge clk) begin
		if (reset) begin
			hpos     <= 0;
			vpos     <= 0;
			vblank_d <= 0;
		end else if (ce_pix) begin
			vblank_d <= vblank;
			if (hpos == HTOTAL-1) begin
				hpos <= 0;
				vpos <= (vpos == VTOTAL-1) ? 9'd0 : vpos + 9'd1;
			end else begin
				hpos <= hpos + 10'd1;
			end
		end
	end

endmodule
