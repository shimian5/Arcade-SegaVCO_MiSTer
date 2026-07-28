// Shared Z80-3D video timing generator.
//
// Runs entirely in the 2x-horizontal output pixel domain (see docs/PLAN.md,
// "Run the video pipeline at 2x horizontal"): HTOTAL 640 / HBSTART 512,
// VTOTAL 264 / VBSTART 224, ce_pix at core_clk/4 (9.984 MHz @ 39.936 MHz core).
//
// hpos/vpos are free-running counters (not blanked to 0 outside active area)
// so downstream modules can use them for ROM/RAM addressing during blanking
// (e.g. prepare_sprites during HBLANK).
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
    localparam HSSTART  = 528; // arbitrary sync placement within blanking, not yet traced from schematic
    localparam HSEND    = 592;
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
