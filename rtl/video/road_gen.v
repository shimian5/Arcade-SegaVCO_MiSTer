// Turbo road generator (docs/WORKPLAN_TURBO_GRAPHICS.md Step 3): five
// ROM-driven edge comparisons per native pixel that replace Buck Rogers'
// starfield/bgcolor background. Ported line-for-line from
// turbo_state::screen_update (docs/reference/turbo_v.cpp:364-453, schematic
// pages 141-144 per that file's own page-number comments).
//
// House memory idiom: five independent inferred-array ROM banks (matching
// the 8-bank sprite-ROM idiom in sprite_engine.v -- parallel banks, not a
// sequencer, so there is no per-pixel arbitration), addressed and read every
// cycle, registered dout -- never a combinational mux over a ROM (see
// rtl/video/fg_tilemap.v:8-11). PR-1114/1115/1117 (the small colour/babit
// PROMs this module also needs) are owned here too, forwarded from
// segavco.v's proms_we/proms_wraddr the same way PR-1196/pr-5199 are
// forwarded into sprite_engine.
//
// Pipeline / latency (clk cycles from a stable {y,xx,opa,opb,opc,ipa,ipb,
// ipc,fbcol0} input to babit/bacol/road output):
//   cycle 0: combinational address generation (va/carry/sel/coch/offsets)
//   cycle 1: bank0-4 dout registers, bacol_lo/hi dout registers land
//   cycle 2: area[4:0] computed from bank dout + xx (delayed to match);
//            babit's address (area) is issued this cycle
//   cycle 3: babit (pr1115 dout) lands; bacol delayed to match; road latch
//            updates from this cycle's babit
// Total latency = 3 clk. xx_native/y_native are held stable for the whole
// native-pixel dwell (many clk cycles -- see segavco.v's xx_native comment),
// so this recomputes the same result harmlessly every clk until the next
// native pixel; only the pipeline-delayed sample at the point of use matters.
// mixer_turbo.v (Step 5) owns delay-matching babit/bacol/road against the
// sprite and foreground paths, mirroring segavco.v's SPR_TO_MIX_DELAY/
// COORD_DELAY convention.
module road_gen
(
    input  wire        clk,

    // ROM download: 32KB road slot, split into 5 banks by addr[14:12]
    // (0x0000/0x1000/0x2000/0x3000 = 4KB each, 0x4000 = 2KB). Shares the
    // "road" download slot with Buck Rogers' bgcolorrom in segavco.v --
    // road_we itself is not mod_turbo-gated (matches road_we/bgcolorrom_we's
    // existing convention: bgcolorrom_we range-gates on the low 8KB instead)
    // so gate the actual bank writes on mod_turbo here.
    input  wire         road_we,
    input  wire [14:0]  road_addr,
    input  wire [7:0]   road_wdata,

    // PROM download: PR-1114/1115/1117 forwarded from the shared proms_we/
    // proms_wraddr window (docs/WORKPLAN_TURBO_GRAPHICS.md Step 2's PROM
    // table: 0x000/0x020/0x060, 32B each). Not mod_turbo-gated for the same
    // reason road_we isn't above: Buck Rogers' PROMs at these same offsets
    // (pr-5194/xshift, unused here) live in separate arrays elsewhere, so
    // there is no aliasing to guard against.
    input  wire         proms_we,
    input  wire [12:0]  proms_addr,
    input  wire [7:0]   proms_wdata,

    // Per-native-pixel inputs. opa/opb/opc are PPI0 port A/B/C; ipa/ipb/ipc
    // are PPI1 port A/B/C (docs/reference/turbo_v.cpp's m_opa/m_opb/m_opc/
    // m_ipa/m_ipb/m_ipc, set directly from those PPIs' out_p*_callback).
    // fbcol0 is PPI3 port C bit4 (fbcol & 1) -- PPI3 doesn't exist until
    // Step 7, so segavco.v currently ties this to 0.
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
    // 5 road ROM banks (docs/WORKPLAN_TURBO_GRAPHICS.md Step 3 layout).
    // road_addr spans the full 32KB shared road/bgcolor download slot.
    // road_we is the raw, ungated download strobe -- Buck Rogers' bgcolor
    // ROM (bgcolorrom in segavco.v) occupies the SAME address range but is a
    // SEPARATE array, so both this module's banks and bgcolorrom simply get
    // written in parallel during any download; only the game selected by
    // mod_turbo ever reads its own array back out, exactly like the
    // combined palette/xscale LUT pattern from Step 1. No local mod_turbo
    // gating is needed here.
    // ------------------------------------------------------------------
    reg [7:0] bank0[0:4095], bank1[0:4095], bank2[0:4095], bank3[0:4095];
    reg [7:0] bank4[0:2047];

    wire        bank_sel4  = (road_addr[14:12] == 3'd4);
    wire [11:0] bank_off   = road_addr[11:0];
    wire [10:0] bank4_off  = road_addr[10:0];

    always @(posedge clk) begin
        if (road_we) case (road_addr[14:12])
            3'd0: bank0[bank_off] <= road_wdata;
            3'd1: bank1[bank_off] <= road_wdata;
            3'd2: bank2[bank_off] <= road_wdata;
            3'd3: bank3[bank_off] <= road_wdata;
            3'd4: bank4[bank4_off] <= road_wdata;
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

    wire pr1114_we = proms_we && (proms_addr < 13'h020);
    wire pr1115_we = proms_we && (proms_addr >= 13'h020) && (proms_addr < 13'h040);
    wire pr1117_we = proms_we && (proms_addr >= 13'h060) && (proms_addr < 13'h100);

    always @(posedge clk) begin
        if (pr1114_we) pr1114[proms_addr[4:0]] <= proms_wdata;
        if (pr1115_we) pr1115[proms_addr[4:0]] <= proms_wdata;
        if (pr1117_we) pr1117[proms_addr[4:0]] <= proms_wdata;
    end

    // ------------------------------------------------------------------
    // Stage 0 (comb): va/carry/sel/coch and the four/five ROM addresses.
    // turbo_v.cpp:370-441.
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
    // Stage 1 (registered): ROM dout for all 5 banks + bacol lo/hi, plus
    // xx/coch/fbcol_addr delayed one cycle to stay aligned with the dout
    // they'll be combined with next stage.
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
    // turbo_v.cpp:414-440 -- "(rom_byte + xx) >> 8" is a "left/right of this
    // edge" carry test; AREA5 is a bitmap-stripe test instead (no +xx).
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
    // Stage 3 (registered): babit = pr1115[area]; bacol delay-matched;
    // road latch. turbo_v.cpp:442-448 -- SLIPAR/ACCIAR are babit bits 4/5;
    // road latches permanently high (per scanline) once ACCIAR (bit 5) is
    // seen, and is never cleared except at the next scanline's first pixel.
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
