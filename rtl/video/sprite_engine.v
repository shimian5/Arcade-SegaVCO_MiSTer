// Z80-3D sprite engine (see docs/PLAN.md "The sprite engine").
//
// 16 sprite-RAM entries x 8 bytes, folded onto 8 hardware "levels" via
// level = sprnum & 7 (sprites 8-15 overwrite whatever sprites 0-7 set up for
// the same level -- this is a real hardware trick, not a bug: processing
// order 0..15 means the second half wins if both fire the same scanline).
// Each level has a private 32KB sprite-ROM bank (8 independent BRAMs, one
// fetch per level per output pixel -- see docs/PLAN.md "Findings that
// changed the plan": max X-scale step is well under 1.0 pixel/pixel, so a
// single "if" (not a "while") per level per pixel is enough, no arbitration
// needed).
//
// Game-specific constants are parameters, not hardcoded, per docs/PLAN.md's
// sequencing note: "the sprite engine's game-specific bits (plb_end table,
// X-scale constants, offset pre-shift, sprite-position RAM addressing) are
// parameterized so it can be slotted in later [for Turbo/Subroc-3D] without
// reopening the engine." This instance is wired up for Buck Rogers only;
// Turbo's sprite-position addressing (sprpos[xx] | sprpos[xx+0x100]<<8,
// vs. Buck Rogers' sprpos[xx*2] | sprpos[xx*2+1]<<8) and its different
// self-termination test (bitmask compare, not a plb_end table) are NOT
// implemented here -- that's phase 3 work.
//
// PR-5195 ("sprite state machine" per its ROM comment in turbo.cpp) has no
// consumer anywhere in MAME's buckrog_state emulation: on real hardware it
// drives the physical carry-ALU/sequencer chip, but turbo_v.cpp's
// prepare_sprites() replicates that chip's behavior directly as boolean
// logic instead of a table lookup (same as this module does below). It is
// still downloaded as part of the "proms" ROM blob (offset 0x0020, already
// covered by rom_download.v's proms_we/proms_addr) but intentionally has no
// dedicated reader here -- this is not an oversight.
//
// PIPELINE / TIMING:
//  - prepare_sprites runs as a state machine on the raw core clock during
//    HBLANK, computing level state for the scanline about to start. Budget:
//    HBLANK is 128 ce_pix ticks = 512 core-clk cycles (video_timing.v:
//    HTOTAL-HBSTART = 640-512); this FSM takes at most 16 sprites x 15
//    states = 240 cycles, well inside budget. Because nothing reads the
//    level/VE state until active video resumes (well after HBLANK ends),
//    this is effectively single-buffered -- no separate pending/active
//    register sets are needed.
//  - get_sprite_bits (the per-pixel path) is real-time: it must step
//    exactly once per actual output pixel (ce_pix), since the X-scale
//    accumulator's cadence IS the timing reference. Its output (sprbits/
//    plb) is combinational from already-registered per-level state, so it
//    is valid on the SAME clk cycle as the ce_pix tick that advanced it --
//    zero added latency relative to hpos/vpos. The caller (z80_3d.v) is
//    responsible for delay-matching sprbits/plb against the fg-tilemap path
//    (which has real fetch latency) with its own shift register before
//    mixing, exactly like it already does for hblank/vblank/hsync/vsync/
//    ce_pix.
//  - Sprite-position RAM is read one native pixel ahead of when its data is
//    needed (see pos_prefetch_addr below) specifically so that 1-cycle BRAM
//    read latency doesn't show up as extra pipeline delay at the real-time
//    per-pixel consumption point.
//
// All memory reads are registered (synchronous) -- sprite RAM, sprite-
// position RAM, the Y-scale PROM and the 8 sprite-ROM banks all use the
// "address every cycle, registered dout" idiom already established in
// fg_tilemap.v, so Quartus infers M10K/BRAM instead of a giant combinational
// mux (critical here: the 8 sprite-ROM banks alone are 256KB).
module sprite_engine
#(
    parameter [31:0] XSCALE_THRESHOLD = 32'h00800000,   // Buck Rogers: 0x800000; Turbo: 0x1000000
    parameter        OFFSET_PRESHIFT  = 1,               // Buck Rogers pre-shifts offset<<1; Turbo does not
    parameter        ROM_ADDR_BITS    = 15,               // 32KB/level (Buck Rogers); Turbo uses 14 (16KB/level)
    parameter        Y_INVERT         = 0,               // Turbo inverts sprite Y bytes (^0xff); Buck Rogers does not
    // plb_end[16], 2 bits/entry {END,PLB}, packed entry15..entry0 MSB..LSB.
    // Default = Buck Rogers' table {0,1,1,1, 1,1,1,1, 1,1,1,1, 1,1,1,2}.
    parameter [31:0] PLB_END          = {2'd2,2'd1,2'd1,2'd1, 2'd1,2'd1,2'd1,2'd1,
                                          2'd1,2'd1,2'd1,2'd1, 2'd1,2'd1,2'd1,2'd0},
    parameter        VTOTAL           = 264,
    parameter        XSCALE_HEX_FILE  = "roms/xscale_buckrog.hex"
)
(
    input  wire        clk,
    input  wire        reset,

    // CPU port: sprite RAM, e400-e7ff (16 entries x 8B = 128B; full 1KB
    // mapped span kept, matching the CPU-address-width convention used
    // elsewhere in this core -- see z80_3d.v).
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

    // ROM download: PR-5196, Y-scale PROM, 512B
    input  wire         yscale_we,
    input  wire [8:0]   yscale_addr,
    input  wire [7:0]   yscale_wdata,

    // Video timing (undelayed / real-time)
    input  wire         ce_pix,
    input  wire         hblank,
    input  wire [9:0]   hpos,
    input  wire [8:0]   vpos,

    input  wire [2:0]   obch,        // PPI1 port C bits 0-2 (tied 0 until PPI1 is wired up)

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
    // Sprite-position RAM: split into lo/hi byte banks (CPU addr bit0
    // selects bank) so the engine can read both bytes of a 16-bit
    // horizontal-enable word in the same cycle from two independent
    // 2-port BRAMs, instead of needing a 3rd port on one array.
    // ------------------------------------------------------------------
    reg [7:0] sprpos_lo[0:511];
    reg [7:0] sprpos_hi[0:511];

    wire        cpu_sprpos_we_lo = cpu_sprpos_we && !cpu_sprpos_addr[0];
    wire        cpu_sprpos_we_hi = cpu_sprpos_we &&  cpu_sprpos_addr[0];
    wire [8:0]  cpu_sprpos_idx   = cpu_sprpos_addr[9:1];
    reg  [7:0]  cpu_sprpos_rdata_lo, cpu_sprpos_rdata_hi;
    always @(posedge clk) begin
        if (cpu_sprpos_we_lo) sprpos_lo[cpu_sprpos_idx] <= cpu_sprpos_wdata;
        if (cpu_sprpos_we_hi) sprpos_hi[cpu_sprpos_idx] <= cpu_sprpos_wdata;
        cpu_sprpos_rdata_lo <= sprpos_lo[cpu_sprpos_idx];
        cpu_sprpos_rdata_hi <= sprpos_hi[cpu_sprpos_idx];
    end
    always @(posedge clk) cpu_sprpos_rdata <= cpu_sprpos_addr[0] ? cpu_sprpos_rdata_hi : cpu_sprpos_rdata_lo;

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
    // 8 sprite-ROM banks, 32KB each (level = sproms_addr[17:15])
    // ------------------------------------------------------------------
    reg [7:0] sprom0[0:32767], sprom1[0:32767], sprom2[0:32767], sprom3[0:32767];
    reg [7:0] sprom4[0:32767], sprom5[0:32767], sprom6[0:32767], sprom7[0:32767];
    wire [14:0] sproms_off = sproms_addr[14:0];
    always @(posedge clk) begin
        if (sproms_we) case (sproms_addr[17:15])
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

    // Per-level registered read ports (one per bank, unrolled -- a `case`
    // can't select between separate `always` blocks, only between
    // statements inside one).
    wire [ROM_ADDR_BITS-1:0] rom_raddr [0:7];
    reg  [7:0]                rom_dout [0:7];
    always @(posedge clk) rom_dout[0] <= sprom0[rom_raddr[0]];
    always @(posedge clk) rom_dout[1] <= sprom1[rom_raddr[1]];
    always @(posedge clk) rom_dout[2] <= sprom2[rom_raddr[2]];
    always @(posedge clk) rom_dout[3] <= sprom3[rom_raddr[3]];
    always @(posedge clk) rom_dout[4] <= sprom4[rom_raddr[4]];
    always @(posedge clk) rom_dout[5] <= sprom5[rom_raddr[5]];
    always @(posedge clk) rom_dout[6] <= sprom6[rom_raddr[6]];
    always @(posedge clk) rom_dout[7] <= sprom7[rom_raddr[7]];

    // ------------------------------------------------------------------
    // Y-scale PROM (PR-5196), 512B
    // ------------------------------------------------------------------
    reg [7:0] yscale_rom[0:511];
    always @(posedge clk) if (yscale_we) yscale_rom[yscale_addr] <= yscale_wdata;
    reg [8:0] yscale_raddr;
    reg [7:0] yscale_dout;
    always @(posedge clk) yscale_dout <= yscale_rom[yscale_raddr];

    // ------------------------------------------------------------------
    // X-scale LUT: 256 x 32-bit Q8.24, generated by tools/gen_tables.py.
    // Loaded directly via $readmemh, same as palette_buckrog.hex in
    // z80_3d.v.
    // ------------------------------------------------------------------
    reg [31:0] xscale_lut[0:255];
    initial $readmemh(XSCALE_HEX_FILE, xscale_lut);
    reg [7:0]  xscale_raddr;
    reg [31:0] xscale_dout;
    always @(posedge clk) xscale_dout <= xscale_lut[xscale_raddr];

    // ------------------------------------------------------------------
    // Per-level runtime state (8 levels)
    // ------------------------------------------------------------------
    localparam OFFSET_WIDTH = 16 + OFFSET_PRESHIFT;

    reg [OFFSET_WIDTH-1:0] offset_reg [0:7];
    reg [31:0]             step_reg   [0:7];
    reg [31:0]             frac_reg   [0:7];
    reg [31:0]             latched_reg[0:7];
    reg [7:0]  plb_bit_reg;     // 1 bit per level
    reg [15:0] ve_reg;          // 1 bit per sprnum (0-15)
    reg [7:0]  lst_active;      // 1 bit per level, persists across pixels

    reg fire_pending[0:7];
    reg nibble_sel_pending[0:7];

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

    // Two-stage carry ALU (docs/PLAN.md "Per-scanline prepare_sprites state
    // machine", step 1). Combinational from the just-captured Y bytes.
    wire [7:0] y_lo_eff = Y_INVERT ? ~y_lo_reg : y_lo_reg;
    wire [7:0] y_hi_eff = Y_INVERT ? ~y_hi_reg : y_hi_reg;
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

        case (st)
            ST_IDLE: begin
                if (hblank_rise) begin
                    idx        <= 4'd0;
                    y_target   <= y_target_next;
                    lst_active <= 8'h00;
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
                // Issue now (using the combinational ALU sum, not yet
                // registered) so yscale_dout lands exactly in ST_COMMIT.
                yscale_raddr <= {yscale_raw_reg[3], alu_sum1[7:0]};
                st <= ST_YSCALE_WAIT;
            end
            ST_YSCALE_WAIT: begin
                st <= ST_COMMIT;
            end
            ST_COMMIT: begin
                if (ve_bit_reg) begin
                    offset_reg[idx[2:0]]  <= OFFSET_PRESHIFT ? {new_offset, 1'b0} : new_offset;
                    step_reg[idx[2:0]]    <= xscale_dout;
                    frac_reg[idx[2:0]]    <= 32'd0;
                    latched_reg[idx[2:0]] <= 32'd0;
                    plb_bit_reg[idx[2:0]] <= 1'b0;
                    ve_reg[idx]           <= 1'b1;

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
    // (docs/PLAN.md / turbo_v.cpp:17)
    function [31:0] sprite_expand_f;
        input [3:0] n;
        begin
            sprite_expand_f = {7'b0, n[3], 7'b0, n[2], 7'b0, n[1], 7'b0, n[0]};
        end
    endfunction

    wire [31:0] latched_masked [0:7];
    wire [7:0]  clear_lvl_vec;

    genvar lvl;
    generate
        for (lvl = 0; lvl < 8; lvl = lvl + 1) begin : levels
            assign rom_raddr[lvl] = offset_reg[lvl][ROM_ADDR_BITS:1];

            wire        live     = lst_eff[lvl];
            wire [32:0] frac_sum = {1'b0, frac_reg[lvl]} + {1'b0, step_reg[lvl]};
            wire        fire     = live && (frac_sum >= {1'b0, XSCALE_THRESHOLD});

            wire [3:0] pixdata   = nibble_sel_pending[lvl] ? rom_dout[lvl][7:4] : rom_dout[lvl][3:0];
            wire [1:0] plb_end_v = PLB_END[pixdata*2 +: 2];
            assign clear_lvl_vec[lvl] = fire_pending[lvl] && plb_end_v[1];

            always @(posedge clk) begin
                if (active_pix) begin
                    if (live) begin
                        frac_reg[lvl] <= fire ? (frac_sum[31:0] - XSCALE_THRESHOLD) : frac_sum[31:0];
                        if (fire) begin
                            offset_reg[lvl]         <= offset_reg[lvl] +
                                                        (offset_reg[lvl][OFFSET_WIDTH-1] ?
                                                         {OFFSET_WIDTH{1'b1}} :
                                                         {{(OFFSET_WIDTH-1){1'b0}}, 1'b1});
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

            assign latched_masked[lvl] = lst_eff[lvl] ? latched_reg[lvl] : 32'd0;
        end
    endgenerate

    // lst_active update: OR in newly-enabled levels (he_or_mask, at ix0),
    // AND out levels whose fetch this cycle signalled END (clear_lvl_vec).
    always @(posedge clk) if (active_pix) lst_active <= lst_eff & ~clear_lvl_vec;

    assign sprbits = latched_masked[0] | latched_masked[1] | latched_masked[2] | latched_masked[3] |
                      latched_masked[4] | latched_masked[5] | latched_masked[6] | latched_masked[7];
    assign plb     = lst_eff & plb_bit_reg;

endmodule
