// Turbo mixer (docs/WORKPLAN_TURBO_GRAPHICS.md Step 5): a bit-serial 16:1
// multiplexer, NOT an ordinal priority chain -- the layer ordering is data
// (PR-1122/PR-1123's contents), not structure. Ported line-for-line from
// turbo_state::screen_update (docs/reference/turbo_v.cpp:459-520, schematic
// page 144 per that file's page-number comments).
//
// House idiom: PR-1118/1121/1122/1123 loaded as inferred arrays, addressed
// and read every cycle, registered dout -- see rtl/video/fg_tilemap.v:8-11.
//
// LATENCY BUDGET (the highest-risk part of this step, per the plan). Three
// inputs arrive at this module already at different fixed latencies behind
// the live native pixel (xx_native/y_native in segavco.v, "cycle 0"):
//   sprbits   : cycle 0 (real-time, sprite_engine.v's own header)
//   babit/bacol: cycle 3 (road_gen.v's own 3-clk pipeline)
//   foreraw   : cycle 4 (fg_tilemap.v's FG_TILEMAP_LATENCY)
// All three must land on the SAME absolute cycle before being combined, or
// the mixer combines one layer's stale sample with another's fresh one for
// part of every native pixel's dwell -- see segavco.v's SPR_TO_MIX_DELAY
// comment for why that specifically garbles multi-colour sprites. Buck
// Rogers' own mixer (segavco.v) picks cycle 8 (2 whole output pixels,
// ce_pix = clk/4) as the common landing point, because forebits' own
// intrinsic latency (5) must round UP to a multiple of 4 for sprbits'
// per-output-pixel (not per-native-pixel) variability to stay correctly
// phased; this module reuses that identical convention:
//   sprbits    delayed  8 (0 -> 8)
//   babit/bacol delayed 5 (3 -> 8)
//   foreraw    delayed  4 (4 -> 8), forebits = pr1118[foreraw] computed at
//              foreraw's cycle-4 arrival (1-clk ROM read -> cycle 5), then
//              delayed 3 more (5 -> 8)
// From cycle 8 the REAL (not padding) sequential ROM-read dependency chain
// runs: priority = pr1122[...] (cycle 8 addr -> cycle 9 dout), mx =
// pr1123[...] (cycle 9 addr -> cycle 10 dout), pen = pr1121[...] (cycle 10
// addr -> cycle 11 dout). red/grn/blu (built once, combinationally, at
// cycle 8 from the values that just landed there) are NOT re-read from the
// cycle-8 pipeline taps at cycle 10 -- those taps have already moved on to
// newer samples by then, since they're continuously shifting delay lines,
// not hold registers. They are instead captured ONCE into plain 2-deep hold
// registers (red_h1/2, grn_h1/2, blu_h1/2) that carry that exact cycle-8
// sample forward to cycle 10 unchanged, mirroring fg_tilemap's own
// "capture once, thread through" discipline for xx/y (see its header).
// TOTAL LATENCY, live native pixel -> pen: 11 clk.
//
// NOT VALIDATED: no golden model exists for Turbo yet (see the work log),
// so this bit-accurate port of the C reference has not been checked against
// any independent reference output. Treat as unproven.
module mixer_turbo
(
    input  wire        clk,

    // PROM download: PR-1118 (256B @ proms offset 0x100), PR-1121 (512B @
    // 0x600), PR-1122 (1024B @ 0x800), PR-1123 (1024B @ 0xC00). Forwarded
    // from the shared proms_we/proms_wraddr window, same pattern as
    // road_gen.v's PR-1114/1115/1117 -- not mod_turbo-gated here for the
    // same reason (no aliasing risk from Buck's PROMs at these offsets).
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
    // PPI3 port C (Step 7): fbpla = data&0x0f, fbcol = (data>>4)&7. PPI3
    // doesn't exist yet, so segavco.v ties both to 0 for now.
    input  wire [3:0]   fbpla,
    input  wire [2:0]   fbcol,

    output reg  [7:0]   pen
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

    reg [7:0] foreraw_pipe [0:3]; // 4 stages (4 -> 8)
    integer fi;
    always @(posedge clk) begin
        foreraw_pipe[0] <= foreraw;
        for (fi = 1; fi < 4; fi = fi + 1) foreraw_pipe[fi] <= foreraw_pipe[fi-1];
    end
    wire [7:0] foreraw_d8 = foreraw_pipe[3];

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
    // Cycle 8: red/grn/blu (turbo_v.cpp:494-510) and PR-1122 address.
    // ------------------------------------------------------------------
    wire [14:0] red8 = {1'b1, bacol_d8[4:0],  forebits_d8[0], sprbits_d8[7:0]};
    wire [14:0] grn8 = {1'b1, bacol_d8[9:5],  forebits_d8[1], sprbits_d8[15:8]};
    wire [14:0] blu8 = {1'b1, bacol_d8[14:10],forebits_d8[2], sprbits_d8[23:16]};

    wire [9:0] priority_addr8 = {fbpla[2:0], sprbits_d8[31:25]};

    // mx_addr's other fields (PLB0/PLBE/PLBF/BABIT1-3/PLA3), captured at
    // cycle 8 so they're still valid at cycle 9 when priority (a plain
    // register, not a further-shifting tap) is combined with them --
    // fbpla is a placeholder constant (Step 7) so it needs no capture of
    // its own.
    reg [5:0] mx_bits_reg; // {babit_d8[2:0], forebits_d8[3], foreraw_d8[7], sprbits_d8[24]}
    always @(posedge clk)
        mx_bits_reg <= {babit_d8[2:0], forebits_d8[3], foreraw_d8[7], sprbits_d8[24]};

    // red/grn/blu themselves must also survive to cycle 10 (when mx is
    // finally known) as plain captured values, not live pipeline taps.
    reg [14:0] red_h1, grn_h1, blu_h1;   // cycle 8 -> 9
    always @(posedge clk) begin
        red_h1 <= red8;
        grn_h1 <= grn8;
        blu_h1 <= blu8;
    end
    reg [14:0] red_h2, grn_h2, blu_h2;   // cycle 9 -> 10
    always @(posedge clk) begin
        red_h2 <= red_h1;
        grn_h2 <= grn_h1;
        blu_h2 <= blu_h1;
    end

    // ------------------------------------------------------------------
    // Cycle 9: priority (registered ROM dout, addressed at cycle 8) and
    // mx's address.
    // ------------------------------------------------------------------
    reg [7:0] priority_reg;
    always @(posedge clk) priority_reg <= pr1122[priority_addr8];

    // turbo_v.cpp:484-489: bits[2:0]=priority&7, bit3=PLB0(sprbits[24]),
    // bit4=PLBE(foreraw[7]), bit5=PLBF(forebits[3]), bits[8:6]=BABIT1-3
    // (babit[2:0]), bit9=PLA3(fbpla[3]). mx_bits_reg packs
    // {babit_d8[2:0], forebits_d8[3], foreraw_d8[7], sprbits_d8[24]}
    // (bits 5:0), so it slots in directly below.
    wire [9:0] mx_addr9 = {fbpla[3], mx_bits_reg, priority_reg[2:0]};

    // ------------------------------------------------------------------
    // Cycle 10: mx (registered ROM dout, addressed at cycle 9) and the
    // final pen address (turbo_v.cpp:513-517).
    // ------------------------------------------------------------------
    reg [7:0] mx_reg;
    always @(posedge clk) mx_reg <= pr1123[mx_addr9];

    wire [3:0] mx4 = mx_reg[3:0];
    wire [8:0] pen_addr10 = {fbcol[2:1], ~blu_h2[mx4], ~grn_h2[mx4], ~red_h2[mx4], mx4};

    // ------------------------------------------------------------------
    // Cycle 11: pen (registered ROM dout, addressed at cycle 10).
    // ------------------------------------------------------------------
    always @(posedge clk) pen <= pr1121[pen_addr10];

endmodule
