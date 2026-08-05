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
// Turbo mode (docs/WORKPLAN_TURBO_GRAPHICS.md Step 4): the runtime mod_turbo
// strap selects between Buck Rogers and Turbo's sprite-engine differences --
// XSCALE_THRESHOLD, the offset register's effective width/wraparound, ROM
// bank size, Y-byte inversion, sprite-position RAM addressing, and the
// self-termination test -- all switched at runtime rather than at
// elaboration, since both games are resident in the same bitstream (Step 1).
// Physical register/array widths stay fixed at Buck Rogers' (larger) sizes;
// Turbo's narrower logical values are computed in their own native width
// then zero-extended, which correctly reproduces MAME's masked/uint16_t
// arithmetic (e.g. Turbo's ROM address is `(offs>>1)&0x3fff`, a real 14-bit
// mask, not merely "the low 14 bits of whatever the 15-bit calculation gave"
// -- those differ whenever the 15-bit calculation's bit 14 would have
// carried into/out of a wider add).
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
//    zero added latency relative to hpos/vpos. The caller (segavco.v) is
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
    // plb_end[16], 2 bits/entry {END,PLB}, packed entry15..entry0 MSB..LSB.
    // Buck Rogers only -- Turbo's self-termination test is a direct bitmask
    // compare on pixdata, computed structurally below (see mod_turbo use
    // in the per-level generate block).
    parameter [31:0] PLB_END          = {2'd2,2'd1,2'd1,2'd1, 2'd1,2'd1,2'd1,2'd1,
                                          2'd1,2'd1,2'd1,2'd1, 2'd1,2'd1,2'd1,2'd0},
    parameter        VTOTAL           = 264,
    parameter        VDISP            = 224,               // visible scanlines, y=0..VDISP-1 (matches MAME cliprect.min_y/max_y)
    parameter        XSCALE_HEX_FILE  = "roms/xscale_combined.hex"
)
(
    input  wire        clk,
    input  wire        reset,

    // One-RBF game strap (docs/WORKPLAN_TURBO_GRAPHICS.md Step 1): selects
    // buckrog (0) vs turbo (1) within xscale_lut, which holds both games'
    // tables since $readmemh can't be conditional on a runtime strap.
    input  wire        mod_turbo,

    // CPU port: sprite RAM, e400-e7ff (16 entries x 8B = 128B; full 1KB
    // mapped span kept, matching the CPU-address-width convention used
    // elsewhere in this core -- see segavco.v).
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

    // Turbo only (docs/WORKPLAN_TURBO_GRAPHICS.md Step 3/5): road_gen's
    // "road" latch (turbo_v.cpp:302-303 -- "if we haven't left the road yet,
    // sprites 3-7 are disabled"). Fed straight from road_gen's registered
    // output with no further delay-matching: it only ever transitions once
    // per scanline (0->1), and road_gen's own ~3clk settle time is small
    // relative to a native pixel's 8clk dwell, so the only imprecision this
    // can introduce is a few-native-pixel window right at that one
    // transition point each scanline -- not validated against a golden
    // model, see the work log. Ignored when !mod_turbo.
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
    // 8 sprite-ROM banks, sized for Buck Rogers' larger 32KB/level (arrays
    // are fixed at elaboration; Turbo's 16KB/level data simply occupies the
    // low half of each array, addressed with the top bit forced 0).
    // level = sproms_addr[17:15] (Buck, 32KB/level) or sproms_addr[16:14]
    // (Turbo, 16KB/level). Turbo's actual ROM data only spans the low 128KB
    // of the shared 256KB download slot (docs/WORKPLAN_TURBO_GRAPHICS.md
    // Step 1's REGIONS table pads the rest with 0xFF filler to match Buck's
    // fixed region size) -- since Turbo's level/offset decode only looks at
    // addr[16:0], addresses at 0x20000+ (addr[17]=1) would alias directly
    // onto 0x00000-0x1FFFF and silently overwrite real chip data with that
    // trailing filler if not excluded, so sproms_we_eff gates them out.
    // ------------------------------------------------------------------
    reg [7:0] sprom0[0:32767], sprom1[0:32767], sprom2[0:32767], sprom3[0:32767];
    reg [7:0] sprom4[0:32767], sprom5[0:32767], sprom6[0:32767], sprom7[0:32767];
    wire [2:0]  sproms_level    = mod_turbo ? sproms_addr[16:14] : sproms_addr[17:15];
    wire [14:0] sproms_off      = mod_turbo ? {1'b0, sproms_addr[13:0]} : sproms_addr[14:0];
    wire        sproms_in_range = mod_turbo ? !sproms_addr[17] : 1'b1;
    wire        sproms_we_eff   = sproms_we && sproms_in_range;
    always @(posedge clk) begin
        if (sproms_we_eff) case (sproms_level)
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
    // statements inside one). Sized for Buck's 15-bit address; Turbo's
    // fetch_addr_reg (below) zero-extends its 14-bit address into this same
    // width.
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
    // Y-scale PROM (PR-5196), 512B
    // ------------------------------------------------------------------
    reg [7:0] yscale_rom[0:511];
    always @(posedge clk) if (yscale_we) yscale_rom[yscale_addr] <= yscale_wdata;
    reg [8:0] yscale_raddr;
    reg [7:0] yscale_dout;
    always @(posedge clk) yscale_dout <= yscale_rom[yscale_raddr];

    // ------------------------------------------------------------------
    // X-scale LUT: combined buckrog/turbo, 512 x 32-bit Q8.24, generated by
    // tools/gen_tables.py (docs/WORKPLAN_TURBO_GRAPHICS.md Step 1). $readmemh
    // can't be conditional on mod_turbo, so both games' 256-entry tables are
    // loaded into one BRAM and selected by indexing on mod_turbo as the MSB
    // -- buckrog at 0-255, turbo at 256-511. Same pattern as palette_rom in
    // segavco.v.
    // ------------------------------------------------------------------
    reg [31:0] xscale_lut[0:511];
    initial $readmemh(XSCALE_HEX_FILE, xscale_lut);
    reg [7:0]  xscale_raddr;
    reg [31:0] xscale_dout;
    always @(posedge clk) xscale_dout <= xscale_lut[{mod_turbo, xscale_raddr}];

    // ------------------------------------------------------------------
    // Per-level runtime state (8 levels)
    // ------------------------------------------------------------------
    // Physical width fixed at Buck Rogers' 17 bits (16-bit offset + its
    // preshift-by-1 extra precision bit); Turbo's logical 16-bit offset
    // zero-extends into the same register (bit 16 always 0 for Turbo), see
    // commit_offset/offset_next below for the width-aware wraparound this
    // requires.
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

    // offset_reg/step_reg/frac_reg/latched_reg/plb_bit_reg are each written
    // from exactly ONE place: the per-level always block in the generate
    // loop below (get_sprite_bits' real-time path). The prepare_sprites FSM
    // does NOT write them directly -- Quartus can't prove a runtime-indexed
    // write (offset_reg[idx[2:0]] from the FSM) and a genvar-indexed write
    // (offset_reg[lvl] from the generate block) are mutually exclusive, and
    // flags it as multiple constant drivers even though they never
    // actually race (FSM only commits during HBLANK; the per-pixel path
    // only runs during active video). Instead the FSM raises a one-cycle
    // broadcast pulse (commit_pulse/commit_level/commit_offset/
    // commit_step) that the target level's own always block consumes.
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

    // Gate on the FULL 9-bit vpos (not the truncated y_target_next) so the
    // FSM runs exactly once per visible scanline, y_target_next = 0..VDISP-1,
    // matching MAME's `for (y = cliprect.min_y; y <= cliprect.max_y; y++)`
    // (turbo_v.cpp screen_update). True at vpos = VTOTAL-1 (wrap, prepares
    // y=0) and at vpos = 0..VDISP-2 (prepares y=vpos+1..VDISP-1); false for
    // every VBLANK line (vpos = VDISP-1..VTOTAL-2), so no spurious
    // prepare_sprites passes -- and no offset/step writeback -- ever happen
    // during blanking. y_target itself stays 8 bits and its arithmetic is
    // untouched; only WHEN the FSM is allowed to launch changes.
    wire run_prepare_sprites = (vpos == VTOTAL-1) || (vpos < VDISP-1);

    // Two-stage carry ALU (docs/PLAN.md "Per-scanline prepare_sprites state
    // machine", step 1). Combinational from the just-captured Y bytes.
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
                    commit_pulse  <= 1'b1;
                    commit_level  <= idx[2:0];
                    // Buck Rogers pre-shifts (offset<<1, 17-bit value);
                    // Turbo does not (16-bit value, zero-extended into the
                    // same 17-bit register -- bit 16 stays 0).
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
    // (docs/PLAN.md / turbo_v.cpp:17)
    function [31:0] sprite_expand_f;
        input [3:0] n;
        begin
            sprite_expand_f = {7'b0, n[3], 7'b0, n[2], 7'b0, n[1], 7'b0, n[0]};
        end
    endfunction

    wire [31:0] latched_masked [0:7];
    wire [7:0]  clear_lvl_vec;

    // X-scale fire threshold: Buck Rogers 0x800000, Turbo 0x1000000
    // (docs/reference/turbo_v.cpp's per-game sprite_xscale scaling target).
    wire [31:0] xscale_threshold = mod_turbo ? 32'h01000000 : 32'h00800000;

    // ROM address from a 17-bit offset register: Buck Rogers uses the full
    // offs[15:1] (15 bits, natural wraparound); Turbo masks to offs[14:1]
    // (14 bits, matching MAME's explicit "(offs>>1)&0x3fff") -- computed in
    // Turbo's own 16-bit-wide slice first so its wraparound is confined to
    // 16 bits before zero-extending into this module's unified 17-bit
    // offset register width, then zero-extended again into the unified
    // 15-bit ROM address bus.
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
            // rom_raddr must be driven from a REGISTER captured at fire time
            // (fetch_addr_reg), not combinationally off the live offset_reg.
            // offset_reg[lvl] advances to its POST-increment value at the
            // very same edge as the fire that's supposed to fetch the
            // PRE-increment byte -- if rom_raddr tracked offset_reg live, it
            // would follow that same-edge increment and re-address the ROM
            // to the NEXT offset starting the very next clock, well before
            // fire_pending consumes the result a full active_pix period
            // later. That consumption would then see the *next* generation's
            // byte instead of the one this fire actually meant to fetch --
            // not an occasional race, but the steady-state behaviour any
            // time two fires are more than 1 clock apart (i.e. always,
            // since a period is 4 clocks and X-scale never fires that
          // fast). Net effect: every level's displayed sprite data runs a
            // fixed, whole-generation ahead of MAME's reference timing --
            // confirmed empirically as a constant 2-native-pixel-early
            // reveal via an exhaustive shift search against
            // sim/golden_buckrog.py (session 6 continuation, see
            // docs/INVESTIGATION_title_logo_garbling.md). Freezing the
            // fetch address at fire time (like sprite-position RAM's own
            // pos_prefetch_addr latch) keeps rom_raddr -- and hence
            // rom_dout -- stable for the entire period until the NEXT fire,
            // so consumption always sees the byte this fire actually meant.
            reg [14:0] fetch_addr_reg;
            assign rom_raddr[lvl] = fetch_addr_reg;

            // Turbo: levels 3-7 read as dead until road_in goes high this
            // scanline (turbo_v.cpp:302-303); levels 0-2 and Buck Rogers
            // (any level) are never masked. Gates both the fetch/advance
            // path (live, here) and the output path (latched_masked, below)
            // -- matching MAME's local `sprlive` copy, which masks both the
            // per-pixel sprdata accumulation and the fetch/advance loop, but
            // never the persistent lst register's own accumulation
            // (lst_active's update below is intentionally NOT road-gated).
            wire        road_gate = !mod_turbo || (lvl < 3) || road_in;
            wire        live      = lst_eff[lvl] && road_gate;
            wire [32:0] frac_sum = {1'b0, frac_reg[lvl]} + {1'b0, step_reg[lvl]};
            wire        fire     = live && (frac_sum >= {1'b0, xscale_threshold});

            wire [3:0] pixdata   = nibble_sel_pending[lvl] ? rom_dout[lvl][7:4] : rom_dout[lvl][3:0];
            wire [1:0] plb_end_v = PLB_END[pixdata*2 +: 2];
            // Buck Rogers: plb_end table lookup. Turbo: direct bitmask test,
            // no table (turbo_v.cpp:327 -- "if bit 3 is 0 and bit 2 is 1,
            // the enable flip/flop is reset", i.e. (pixdata & 0x0c) == 0x04).
            // Turbo's PLB bit needs no separate handling here: sprite_expand
            // already puts pixdata bit 3 at bit 24 of the 32-bit word (D24 =
            // PLB0 before the <<lvl below), so it rides along inside sprbits
            // automatically -- Turbo's mixer (a later step) reads PLB from
            // sprbits directly instead of this module's plb output.
            wire        turbo_end = (pixdata[3:2] == 2'b01);
            wire        lvl_end   = mod_turbo ? turbo_end : plb_end_v[1];
            assign clear_lvl_vec[lvl] = fire_pending[lvl] && lvl_end;

            // Sole driver of offset_reg[lvl]/step_reg[lvl]/frac_reg[lvl]/
            // latched_reg[lvl]/plb_bit_reg[lvl] -- both the prepare_sprites
            // commit (broadcast in, see commit_pulse above) and the
            // real-time per-pixel advance are handled in this one process
            // so Quartus sees a single driver per register.
            wire commit_now = commit_pulse && (commit_level == lvl[2:0]);

            // offset_next: the post-increment offset a fire this cycle commits
            // to offset_reg[lvl], for the FOLLOWING fire to fetch from.
            // THIS fire's own fetch uses the current (pre-increment)
            // offset_reg[lvl] -- captured into fetch_addr_reg/
            // nibble_sel_pending below -- matching sim/golden_buckrog.py's
            // `get_sprite_bits` (turbo_v.cpp), which fetches with `offs =
            // st["offset"]` and only increments afterward.
            // Buck Rogers decrements when offset bit 16 (0x10000) is set,
            // wrapping the full 17-bit register (turbo_v.cpp-equivalent
            // buckrog logic uses a wider offset than Turbo's real uint16_t).
            // Turbo decrements when offset bit 15 (0x8000) is set
            // (turbo_v.cpp:334, "if bit 15 is set, we decrement instead"),
            // wrapping only its native 16 bits -- computed in a 16-bit slice
            // first so a decrement from 0 wraps to 0xFFFF, not into bit 16
            // of the unified register, then zero-extended to match.
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

            // Gate the OUTPUT on lst_active (registered), not lst_eff (which
            // is lst_active | he_or_mask, and he_or_mask is combinationally
            // nonzero for exactly the ix0 clock of the column boundary
            // itself -- i.e. lst_eff answers "true a level's enable window
            // opens" one whole active_pix period BEFORE lst_active latches
            // that fact). golden_buckrog.py's model has no such distinction
            // (`lst |= he` and its consumption are the same software step),
            // so gating sprbits/plb on lst_eff shows freshly-activated
            // levels' data one period earlier than MAME's reference timing
            // -- empirically confirmed as a constant, exact 2-native-pixel
            // early reveal for every fire once a level is live (sim session
            // 6 continuation, docs/INVESTIGATION_title_logo_garbling.md).
            // `live` (the fire-gating condition, above) intentionally keeps
            // using lst_eff -- fire cadence was independently confirmed
            // bit-exact against golden with that in place, so only the
            // display path needed correcting.
            assign latched_masked[lvl] = (lst_active[lvl] && road_gate) ? latched_reg[lvl] : 32'd0;
        end
    endgenerate

    // lst_active update: cleared once per scanline at HBLANK start (matches
    // prepare_sprites' "lst=0"), then OR in newly-enabled levels
    // (he_or_mask, at ix0) and AND out levels whose fetch this cycle
    // signalled END (clear_lvl_vec). Single process/driver, same reasoning
    // as commit_now above.
    always @(posedge clk) begin
        if (hblank_rise)       lst_active <= 8'h00;
        else if (active_pix)   lst_active <= lst_eff & ~clear_lvl_vec;
    end

    assign sprbits = latched_masked[0] | latched_masked[1] | latched_masked[2] | latched_masked[3] |
                      latched_masked[4] | latched_masked[5] | latched_masked[6] | latched_masked[7];
    assign plb     = lst_active & plb_bit_reg;

    // ------------------------------------------------------------------
    // VERILATOR_SIM debug instrumentation (see prompt for phase0-1a sprite
    // debug harness). Snapshots the engine's INPUTS (sprram/sprpos/obch) at
    // the start and end of one chosen frame -- selected via +dumpframe=N --
    // so a golden Python re-implementation of MAME's prepare_sprites/
    // get_sprite_bits can be driven from the exact same inputs the RTL saw,
    // instead of comparing screenshots at possibly-different game states.
    // Also logs step_reg/offset_reg/ve per level per scanline for that same
    // frame, which is the highest-value diagnostic (isolates the FSM logic
    // from the per-pixel ROM-fetch logic).
    //
    // "Start of frame N" and "end of frame N" are the SAME hardware event
    // (the true, unambiguous frame wrap) observed on two successive
    // occurrences: occurrence #N is the start of frame N (sprram/sprpos not
    // yet touched by frame N's FSM passes), occurrence #(N+1) is the end of
    // frame N (== start of frame N+1, captured before frame N+1's FSM runs).
    //
    // NOTE: this boundary is deliberately detected as `hblank_rise &&
    // (vpos == VTOTAL-1)` -- the full 9-bit vpos -- and NOT as
    // `y_target_next == 0` (which is what the FSM's y_target register uses,
    // see ST_IDLE above). `y_target_next` is derived from the truncated
    // `vpos[7:0] + 1` (`y_target` must stay 8 bits to match MAME's
    // `prepare_sprites(uint8_t y)` ALU semantics), so in isolation it also
    // reads 0 at vpos==255, one frame-boundary "early".
    //
    // That truncation used to be a live bug: the FSM's ST_IDLE trigger was
    // bare `hblank_rise`, so it launched a prepare_sprites pass on every one
    // of the 264 scanlines, including all of VBLANK. Combined with the
    // vpos==255 truncation, the FSM spuriously re-processed y_target=0..7 a
    // SECOND time during vpos=256..263 (vblank, never displayed, but fully
    // live as far as the FSM's sprnum-vs-y ALU and offset/step commit logic
    // were concerned) before finally reaching the real vpos==263 wrap; any
    // sprite whose Y range satisfied the ALU compare during those lines got
    // its level's offset_reg/step_reg spuriously re-committed with the wrong
    // y. This is now FIXED: ST_IDLE only launches when
    // `run_prepare_sprites` (full 9-bit vpos) is true, which is exactly
    // vpos==VTOTAL-1 (wrap, prepares y=0) or vpos<VDISP-1 (prepares
    // y=vpos+1..VDISP-1) -- i.e. the FSM now runs exactly once per visible
    // scanline y=0..VDISP-1 and never during VBLANK, matching MAME's
    // `for (y = cliprect.min_y; y <= cliprect.max_y; y++)`. `y_target`
    // itself and its ALU were not touched.
    //
    // This debug snapshot boundary still deliberately keys off the full
    // 9-bit vpos rather than the FSM's own y_target_next, on principle: it
    // should stay correct independent of whatever the FSM's internal
    // wrap-detection logic does, so it remains a trustworthy instrument even
    // if a future change to the FSM regresses that logic again.
    `ifdef VERILATOR_SIM
        integer dbg_dumpframe;
        initial if (!$value$plusargs("dumpframe=%d", dbg_dumpframe)) dbg_dumpframe = -1;

        // Frame index we are currently inside, in the SAME numbering the C++
        // testbench uses, so `--dumpframe N` selects the same frame on both
        // sides. Starts at 0 (not -1): measured with the ENGINE_BOUNDARY /
        // TB_BOUNDARY probes, this counter's increment and the testbench's
        // fire on the identical tick, and at that instant the testbench moves
        // from its frame 0 to its frame 1 -- so incrementing from -1 made
        // engine frame N mean testbench frame N+1. That off-by-one silently
        // made the RAM snapshots and the image/pixel dumps describe DIFFERENT
        // frames, which is what produced the co-sim's "RTL drew a logo, the
        // golden model drew nothing" result.
        integer dbg_cur_frame = 0;
        integer dbg_lvl_fh    = 0;    // open only while dbg_cur_frame == dbg_dumpframe
        integer dbg_wr_fh     = 0;    // open only while dbg_cur_frame == dbg_dumpframe; logs CPU writes
        integer dbg_li;

        always @(posedge clk) begin
            if (dbg_dumpframe >= 0 && hblank_rise && (vpos == VTOTAL-1)) begin
                // occurrence check for END-of-frame first (uses PRE-increment dbg_cur_frame)
                if (dbg_cur_frame == dbg_dumpframe) begin
                    $writememh("sim/out/dbg_sprram_end.hex",     sprram,     0, 127);
                    $writememh("sim/out/dbg_sprpos_lo_end.hex",  sprpos_lo,  0, 255);
                    $writememh("sim/out/dbg_sprpos_hi_end.hex",  sprpos_hi,  0, 255);
                    begin : dbg_obch_end_blk
                        integer fh_oe;
                        fh_oe = $fopen("sim/out/dbg_obch_end.hex", "w");
                        $fwrite(fh_oe, "%02x\n", obch);
                        $fclose(fh_oe);
                    end
                    if (dbg_lvl_fh != 0) begin
                        $fclose(dbg_lvl_fh);
                        dbg_lvl_fh = 0;
                    end
                    if (dbg_wr_fh != 0) begin
                        $fclose(dbg_wr_fh);
                        dbg_wr_fh = 0;
                    end
                end

                dbg_cur_frame = dbg_cur_frame + 1;

                if (dbg_cur_frame == dbg_dumpframe) begin
                    $writememh("sim/out/dbg_sprram.hex",     sprram,     0, 127);
                    $writememh("sim/out/dbg_sprpos_lo.hex",  sprpos_lo,  0, 255);
                    $writememh("sim/out/dbg_sprpos_hi.hex",  sprpos_hi,  0, 255);
                    begin : dbg_obch_blk
                        integer fh_os;
                        fh_os = $fopen("sim/out/dbg_obch.hex", "w");
                        $fwrite(fh_os, "%02x\n", obch);
                        $fclose(fh_os);
                    end
                    dbg_lvl_fh = $fopen("sim/out/dbg_rtl_levels.txt", "w");
                    dbg_wr_fh  = $fopen("sim/out/dbg_rtl_writes.txt", "w");
                end
            end

            // Per-scanline level snapshot, taken at HBLANK end (i.e. right
            // after the FSM above has committed every level for the
            // scanline about to start, y_target) -- before get_sprite_bits'
            // real-time path has advanced anything for this scanline.
            if (dbg_lvl_fh != 0 && hblank_fall) begin
                for (dbg_li = 0; dbg_li < 8; dbg_li = dbg_li + 1) begin
                    $fwrite(dbg_lvl_fh, "y=%0d lvl=%0d step=%08x offset=%05x ve=%0d\n",
                            y_target, dbg_li, step_reg[dbg_li], offset_reg[dbg_li],
                            {ve_reg[dbg_li+8], ve_reg[dbg_li]});
                end
            end

            // Open thread #1 (docs/INVESTIGATION_title_logo_garbling.md):
            // log every CPU write to sprite RAM / sprite-position RAM during
            // the dumped frame, tagged with (vpos, hpos), in write order.
            // This is the "WHEN does the CPU write sprite RAM" measurement --
            // purely observational, no engine logic touched.
            if (dbg_wr_fh != 0) begin
                if (cpu_sprram_we)
                    $fwrite(dbg_wr_fh, "SPRRAM vpos=%0d hpos=%0d addr=%03x data=%02x\n",
                            vpos, hpos, cpu_sprram_addr, cpu_sprram_wdata);
                if (cpu_sprpos_we)
                    $fwrite(dbg_wr_fh, "SPRPOS vpos=%0d hpos=%0d addr=%03x data=%02x\n",
                            vpos, hpos, cpu_sprpos_addr, cpu_sprpos_wdata);
            end
        end

        wire hblank_fall = !hblank && hblank_d;
    `endif

endmodule
