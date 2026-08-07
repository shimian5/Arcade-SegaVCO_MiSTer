// Discrete audio top level. All six channels are built. PPI1 port A/B carry
// every trigger, plus the shared data nibble and the two latch strobes.
// See docs/audio-rtl-design.md.
//
// GAME ON (ppi1_pb[7]) IS now implemented, and the path it gates is traced:
// it drives IC5, a 7417 open-collector buffer, whose output is the LA4460's
// DC-mute pin 6. See mute_ctl.sv. The output stage is the real amplifier
// (la4460.sv) rather than a scalar volume constant.
module audio_top (
    input  logic               clk,
    input  logic               rst_n,
    input  logic         [7:0] ppi1_pa,
    input  logic         [7:0] ppi1_pb,
    // Turbo sound-board CN1 bundle, from the third 8255 (PPI2/IC123/CSFA)
    // on the CPU board -- raw port bytes in, named per the schematic
    // internally (see below). Buck Rogers ties these to their PPI2 idle
    // levels (0xFF/0x00/0x00) via segavco.v; not yet consumed by any
    // channel (Phase 4 Step 4 -- plumbing only, no channel built yet).
    input  logic         [7:0] ppi2_pa,
    input  logic         [7:0] ppi2_pb,
    input  logic         [7:0] ppi2_pc,
    output logic signed [15:0] audio_l,
    output logic signed [15:0] audio_r,
    output logic               sample_ce,
    // Per-channel taps, ahead of the mixer. Purely for the Verilator bench:
    // they make it possible to tell a channel saturating internally from the
    // master stage clipping, which is otherwise indistinguishable at audio_l.
    // Leave unconnected in the core; they synthesise away.
    output logic signed [15:0] dbg_alarm_mix,
    output logic signed [15:0] dbg_fire_mix,
    output logic signed [15:0] dbg_exp_mix,
    output logic signed [15:0] dbg_hit_mix,
    output logic signed [15:0] dbg_rebound_mix,
    output logic signed [15:0] dbg_ship_mix,
    // Mute state, for the bench. Synthesises away when unconnected.
    output logic               dbg_dc_mute,
    // Turbo ALARM channel (Phase 4 Step 5), first Turbo channel built. Not
    // yet in the Buck mix or any Turbo mixer -- driven from the bench only.
    // See turbo_alarm_chan.sv.
    output logic signed [15:0] dbg_turbo_alarm_mix,
    output logic                dbg_turbo_alarm_node,
    // Turbo CRASH channel (Phase 4 Step 6). Same status as ALARM above --
    // driven from the bench only. See turbo_crash_chan.sv.
    output logic signed [15:0] dbg_turbo_crash_s_mix,
    output logic signed [15:0] dbg_turbo_crash_l_mix,
    output logic                dbg_turbo_crash_q_s,
    output logic                dbg_turbo_crash_q_l_main,
    output logic                dbg_turbo_crash_q_l_tail,
    // Turbo SKID channel (Phase 4 Step 7). Same status as ALARM/CRASH above.
    // See turbo_skid_chan.sv.
    output logic signed [15:0] dbg_turbo_skid_mix,
    output logic                dbg_turbo_skid_q_slip,
    output logic                dbg_turbo_skid_gate,
    // Turbo AMBULANCE channel (Phase 4 Step 8). Same status as ALARM/CRASH/
    // SKID above. See turbo_ambulance_chan.sv.
    output logic signed [15:0] dbg_turbo_ambulance_mix,
    output logic                dbg_turbo_ambulance_warble,
    // CN1 bundle, decoded and named per the schematic, for the Verilator
    // bench to confirm the game's PPI2 writes actually reach here (Phase 4
    // Step 4's gate). Not consumed by any channel yet. Synthesises away
    // when unconnected. Bit map: docs/hardware-turbo.md's CN1 pinout
    // (Phase 4 Step 2 ledger), cross-checked against turbo_a.cpp's
    // sound_a_w/sound_b_w/sound_c_w.
    output logic                dbg_cn1_crash_s_n,
    output logic         [3:0]  dbg_cn1_trig_n,   // [0]=TRIG1 .. [3]=TRIG4
    output logic                dbg_cn1_osel0,     // active-high; see note below
    output logic                dbg_cn1_slip_n,
    output logic                dbg_cn1_crash_l_n,
    output logic         [5:0]  dbg_cn1_acc,       // ACC0-5
    output logic                dbg_cn1_ambu_n,
    output logic                dbg_cn1_spin_n,
    output logic         [1:0]  dbg_cn1_osel12,    // [0]=OSEL1 [1]=OSEL2
    output logic         [1:0]  dbg_cn1_bsel,      // BSEL0-1
    output logic         [3:0]  dbg_cn1_speed      // SPEED0-3
);

    // ---------------------------------------------------------------
    // CN1 bundle: decode PPI2's three ports into the schematic's own
    // signal names. Active-low stays active-low in the name -- no
    // polarity normalisation here. `OSEL0` is active-HIGH despite the
    // CN1-sheet's printed bar over it: docs/hardware-turbo.md's Step 2
    // ledger, Item (c), resolves the bar as a drafting artifact (D-5/11,
    // the sheet that actually USES the signal, shows no inverter and
    // treats it identically to the unbarred OSEL1/OSEL2; turbo_a.cpp's
    // sound_a_w agrees, taking bit 5 direct with no inversion). Bit
    // positions: sound_a = {CRASH.L, /SLIP, OSEL0, TRIG4, TRIG3, TRIG2,
    // TRIG1, /CRASH.S} (MSB..LSB), sound_b = {/SPIN, /AMBU, ACC5..ACC0},
    // sound_c = {SPEED3..0, BSEL1, BSEL0, OSEL2, OSEL1}.
    // ---------------------------------------------------------------
    wire        cn1_crash_s_n = ppi2_pa[0];
    wire [3:0]  cn1_trig_n    = ppi2_pa[4:1];
    wire        cn1_osel0     = ppi2_pa[5];
    wire        cn1_slip_n    = ppi2_pa[6];
    wire        cn1_crash_l_n = ppi2_pa[7];

    wire [5:0]  cn1_acc       = ppi2_pb[5:0];
    wire        cn1_ambu_n    = ppi2_pb[6];
    wire        cn1_spin_n    = ppi2_pb[7];

    wire [1:0]  cn1_osel12    = ppi2_pc[1:0];
    wire [1:0]  cn1_bsel      = ppi2_pc[3:2];
    wire [3:0]  cn1_speed     = ppi2_pc[7:4];

    assign dbg_cn1_crash_s_n = cn1_crash_s_n;
    assign dbg_cn1_trig_n    = cn1_trig_n;
    assign dbg_cn1_osel0     = cn1_osel0;
    assign dbg_cn1_slip_n    = cn1_slip_n;
    assign dbg_cn1_crash_l_n = cn1_crash_l_n;
    assign dbg_cn1_acc       = cn1_acc;
    assign dbg_cn1_ambu_n    = cn1_ambu_n;
    assign dbg_cn1_spin_n    = cn1_spin_n;
    assign dbg_cn1_osel12    = cn1_osel12;
    assign dbg_cn1_bsel      = cn1_bsel;
    assign dbg_cn1_speed     = cn1_speed;

    // ---------------------------------------------------------------
    // Turbo ALARM channel (D-2/11), Phase 4 Step 5. Driven from the CN1
    // bundle above. Not summed into audio_l/audio_r and not wired into any
    // Turbo mixer yet (Mixer I/II are a later step, per
    // docs/WORKPLAN_TURBO_AUDIO.md's build order) -- exposed only as a
    // debug tap for the bench.
    // ---------------------------------------------------------------
    turbo_alarm_chan u_turbo_alarm (
        .clk              (clk),
        .rst_n            (rst_n),
        .trig_n           (cn1_trig_n),
        .sample_ce        (sample_ce),
        .turbo_alarm_mix  (dbg_turbo_alarm_mix),
        .node             (dbg_turbo_alarm_node)
    );

    // ---------------------------------------------------------------
    // Turbo CRASH channel (D-4/11), Phase 4 Step 6. Same status as ALARM
    // above -- driven from the CN1 bundle, exposed only as debug taps.
    // ---------------------------------------------------------------
    turbo_crash_chan u_turbo_crash (
        .clk                (clk),
        .rst_n              (rst_n),
        .crash_s_n          (cn1_crash_s_n),
        .crash_l_n          (cn1_crash_l_n),
        .sample_ce          (sample_ce),
        .turbo_crash_s_mix  (dbg_turbo_crash_s_mix),
        .turbo_crash_l_mix  (dbg_turbo_crash_l_mix),
        .dbg_q_crash_s      (dbg_turbo_crash_q_s),
        .dbg_q_crash_l_main (dbg_turbo_crash_q_l_main),
        .dbg_q_crash_l_tail (dbg_turbo_crash_q_l_tail)
    );

    // ---------------------------------------------------------------
    // Turbo SKID channel (D-3/11), Phase 4 Step 7. Same status as ALARM/
    // CRASH above -- driven from the CN1 bundle, exposed only as debug taps.
    // ---------------------------------------------------------------
    turbo_skid_chan u_turbo_skid (
        .clk             (clk),
        .rst_n           (rst_n),
        .slip_n          (cn1_slip_n),
        .spin_n          (cn1_spin_n),
        .sample_ce       (sample_ce),
        .turbo_skid_mix  (dbg_turbo_skid_mix),
        .dbg_q_slip      (dbg_turbo_skid_q_slip),
        .dbg_gate        (dbg_turbo_skid_gate)
    );

    // ---------------------------------------------------------------
    // Turbo AMBULANCE channel (D-10/11), Phase 4 Step 8. Same status as
    // ALARM/CRASH/SKID above -- driven from the CN1 bundle, exposed only as
    // debug taps.
    // ---------------------------------------------------------------
    turbo_ambulance_chan u_turbo_ambulance (
        .clk                  (clk),
        .rst_n                (rst_n),
        .ambu_n               (cn1_ambu_n),
        .sample_ce            (sample_ce),
        .turbo_ambulance_mix  (dbg_turbo_ambulance_mix),
        .dbg_warble           (dbg_turbo_ambulance_warble)
    );

    // ---------------------------------------------------------------
    // Sample-rate generator: clk_sys / 832 = 47,999.4 Hz
    // ---------------------------------------------------------------
    localparam int DIV_W = $clog2(832);
    logic [DIV_W-1:0] div_cnt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            div_cnt   <= '0;
            sample_ce <= 1'b0;
        end else begin
            if (div_cnt == DIV_W'(831)) begin
                div_cnt   <= '0;
                sample_ce <= 1'b1;
            end else begin
                div_cnt   <= div_cnt + 1'b1;
                sample_ce <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------------
    // PPI1 taps: bit3=/ALARM3 ... bit0=/ALARM0
    // ---------------------------------------------------------------
    wire [3:0] alarm_n = {ppi1_pb[1], ppi1_pb[0], ppi1_pa[7], ppi1_pa[6]};

    logic signed [15:0] alarm_mix;
    logic                alarm_node;

    alarm_chan u_alarm (
        .clk        (clk),
        .rst_n      (rst_n),
        .alarm_n    (alarm_n),
        .sample_ce  (sample_ce),
        .alarm_mix  (alarm_mix),
        .node       (alarm_node)
    );

    // ---------------------------------------------------------------
    // NOISE (MM5837) and FIRE (laser). /FIRE is ppi1_pb[2].
    // ---------------------------------------------------------------
    logic signed [15:0] noise_a, noise_b;

    noise_mm5837 u_noise (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_ce  (sample_ce),
        .noise_a    (noise_a),
        .noise_b    (noise_b)
    );

    wire fire_n = ppi1_pb[2];

    logic signed [15:0] fire_mix;
    logic                fire_mul_req_valid, fire_mul_req_ready;
    logic signed [63:0]  fire_mul_req_a, fire_mul_req_b;
    logic [6:0]          fire_mul_req_a_width, fire_mul_req_b_width;
    logic [7:0]          fire_mul_req_tag;
    logic                fire_mul_rsp_valid;
    logic signed [127:0] fire_mul_rsp_product;
    logic [7:0]          fire_mul_rsp_tag;

    fire_chan u_fire (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_ce  (sample_ce),
        .fire_n     (fire_n),
        .noise_a    (noise_a),
        .fire_mix   (fire_mix),
        .mul_req_valid   (fire_mul_req_valid),
        .mul_req_ready   (fire_mul_req_ready),
        .mul_req_a       (fire_mul_req_a),
        .mul_req_b       (fire_mul_req_b),
        .mul_req_a_width (fire_mul_req_a_width),
        .mul_req_b_width (fire_mul_req_b_width),
        .mul_req_tag     (fire_mul_req_tag),
        .mul_rsp_valid   (fire_mul_rsp_valid),
        .mul_rsp_product (fire_mul_rsp_product),
        .mul_rsp_tag     (fire_mul_rsp_tag)
    );

    // ---------------------------------------------------------------
    // EXP (crack + rumble). /EXP is ppi1_pb[3].
    // ---------------------------------------------------------------
    wire exp_n = ppi1_pb[3];

    logic signed [15:0] exp_mix;
    logic                exp_mul_req_valid, exp_mul_req_ready;
    logic signed [63:0]  exp_mul_req_a, exp_mul_req_b;
    logic [6:0]          exp_mul_req_a_width, exp_mul_req_b_width;
    logic [7:0]          exp_mul_req_tag;
    logic                exp_mul_rsp_valid;
    logic signed [127:0] exp_mul_rsp_product;
    logic [7:0]          exp_mul_rsp_tag;

    exp_chan u_exp (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_ce  (sample_ce),
        .exp_n      (exp_n),
        .noise_b    (noise_b),
        .exp_mix    (exp_mix),
        .mul_req_valid   (exp_mul_req_valid),
        .mul_req_ready   (exp_mul_req_ready),
        .mul_req_a       (exp_mul_req_a),
        .mul_req_b       (exp_mul_req_b),
        .mul_req_a_width (exp_mul_req_a_width),
        .mul_req_b_width (exp_mul_req_b_width),
        .mul_req_tag     (exp_mul_req_tag),
        .mul_rsp_valid   (exp_mul_rsp_valid),
        .mul_rsp_product (exp_mul_rsp_product),
        .mul_rsp_tag     (exp_mul_rsp_tag)
    );

    // ---------------------------------------------------------------
    // HIT. /HIT is ppi1_pb[4].
    //
    // HIT DIS0-2 is not a direct signal: it is latched on-board by IC2, a
    // 4175B quad D flip-flop, from the shared 4-bit data nibble on port A
    // bits 0-3, strobed by the RISING edge of port A bit 4. (IC6 latches
    // ACC0-3 from the same nibble on bit 5; SHIP will need that one.) IC2
    // ignores D3, so only bits 2:0 are captured. See the connector pinout
    // and CPU-side latch bits in docs/hardware-audio.md.
    // ---------------------------------------------------------------
    wire hit_n = ppi1_pb[4];

    logic [2:0] hit_dis;
    logic       hit_dis_clk_d;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            hit_dis       <= 3'd0;
            // Reset the strobe history to the CURRENT level, never to a
            // constant. The port idles HIGH (8255 reset -> inputs, RA pull-ups),
            // so a hardcoded 0 would manufacture a rising edge on the first
            // clock out of reset and latch whatever happened to be on the
            // nibble. Exactly the ttl_74123 `a_n_d` bug written up under
            // "Phase 3 -- EXP" in docs/audio-rtl-design.md.
            hit_dis_clk_d <= ppi1_pa[4];
        end else begin
            hit_dis_clk_d <= ppi1_pa[4];
            if (!hit_dis_clk_d && ppi1_pa[4])   // rising edge strobes IC2
                hit_dis <= ppi1_pa[2:0];
        end
    end

    logic signed [15:0] hit_mix;
    logic                hit_mul_req_valid, hit_mul_req_ready;
    logic signed [63:0]  hit_mul_req_a, hit_mul_req_b;
    logic [6:0]          hit_mul_req_a_width, hit_mul_req_b_width;
    logic [7:0]          hit_mul_req_tag;
    logic                hit_mul_rsp_valid;
    logic signed [127:0] hit_mul_rsp_product;
    logic [7:0]          hit_mul_rsp_tag;

    hit_chan u_hit (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_ce  (sample_ce),
        .hit_n      (hit_n),
        .hit_dis    (hit_dis),
        .noise_b    (noise_b),
        .hit_mix    (hit_mix),
        .mul_req_valid   (hit_mul_req_valid),
        .mul_req_ready   (hit_mul_req_ready),
        .mul_req_a       (hit_mul_req_a),
        .mul_req_b       (hit_mul_req_b),
        .mul_req_a_width (hit_mul_req_a_width),
        .mul_req_b_width (hit_mul_req_b_width),
        .mul_req_tag     (hit_mul_req_tag),
        .mul_rsp_valid   (hit_mul_rsp_valid),
        .mul_rsp_product (hit_mul_rsp_product),
        .mul_rsp_tag     (hit_mul_rsp_tag)
    );

    // ---------------------------------------------------------------
    // REBOUND. /REBOUND is ppi1_pb[5].
    // ---------------------------------------------------------------
    wire rebound_n = ppi1_pb[5];

    logic signed [15:0] rebound_mix;
    logic                rebound_mul_req_valid, rebound_mul_req_ready;
    logic signed [63:0]  rebound_mul_req_a, rebound_mul_req_b;
    logic [6:0]          rebound_mul_req_a_width, rebound_mul_req_b_width;
    logic [7:0]          rebound_mul_req_tag;
    logic                rebound_mul_rsp_valid;
    logic signed [127:0] rebound_mul_rsp_product;
    logic [7:0]          rebound_mul_rsp_tag;

    rebound_chan u_rebound (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_ce   (sample_ce),
        .rebound_n   (rebound_n),
        .noise_a     (noise_a),
        .rebound_mix (rebound_mix),
        .mul_req_valid   (rebound_mul_req_valid),
        .mul_req_ready   (rebound_mul_req_ready),
        .mul_req_a       (rebound_mul_req_a),
        .mul_req_b       (rebound_mul_req_b),
        .mul_req_a_width (rebound_mul_req_a_width),
        .mul_req_b_width (rebound_mul_req_b_width),
        .mul_req_tag     (rebound_mul_req_tag),
        .mul_rsp_valid   (rebound_mul_rsp_valid),
        .mul_rsp_product (rebound_mul_rsp_product),
        .mul_rsp_tag     (rebound_mul_rsp_tag)
    );

    // ---------------------------------------------------------------
    // SHIP. SHIP ON is ppi1_pb[6] -- an active-high LEVEL, not an edge.
    //
    // ACC0-3 is latched on-board by IC6, a 4175B quad D flip-flop, from the
    // same shared port-A nibble HIT DIS uses, but strobed by the rising edge
    // of port A bit 5 rather than bit 4. Unlike IC2, IC6 uses all four bits.
    // ---------------------------------------------------------------
    wire ship_on = ppi1_pb[6];

    logic [3:0] acc;
    logic       acc_clk_d;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc       <= 4'd0;
            acc_clk_d <= ppi1_pa[5];   // see the note on hit_dis_clk_d above
        end else begin
            acc_clk_d <= ppi1_pa[5];
            if (!acc_clk_d && ppi1_pa[5])   // rising edge strobes IC6
                acc <= ppi1_pa[3:0];
        end
    end

    logic signed [15:0] ship_mix;
    logic                ship_mul_req_valid, ship_mul_req_ready;
    logic signed [63:0]  ship_mul_req_a, ship_mul_req_b;
    logic [6:0]          ship_mul_req_a_width, ship_mul_req_b_width;
    logic [7:0]          ship_mul_req_tag;
    logic                ship_mul_rsp_valid;
    logic signed [127:0] ship_mul_rsp_product;
    logic [7:0]          ship_mul_rsp_tag;

    ship_chan u_ship (
        .clk        (clk),
        .rst_n      (rst_n),
        .sample_ce  (sample_ce),
        .ship_on    (ship_on),
        .acc        (acc),
        .ship_mix   (ship_mix),
        .mul_req_valid   (ship_mul_req_valid),
        .mul_req_ready   (ship_mul_req_ready),
        .mul_req_a       (ship_mul_req_a),
        .mul_req_b       (ship_mul_req_b),
        .mul_req_a_width (ship_mul_req_a_width),
        .mul_req_b_width (ship_mul_req_b_width),
        .mul_req_tag     (ship_mul_req_tag),
        .mul_rsp_valid   (ship_mul_rsp_valid),
        .mul_rsp_product (ship_mul_rsp_product),
        .mul_rsp_tag     (ship_mul_rsp_tag)
    );

    assign dbg_alarm_mix = alarm_mix;
    assign dbg_fire_mix  = fire_mix;
    assign dbg_exp_mix   = exp_mix;
    assign dbg_hit_mix   = hit_mix;
    assign dbg_rebound_mix = rebound_mix;
    assign dbg_ship_mix    = ship_mix;

    logic signed [15:0] mix_out;

    audio_mixer u_mixer (
        .clk         (clk),
        .rst_n       (rst_n),
        .sample_ce   (sample_ce),
        .ship_mix    (ship_mix),
        .hit_mix     (hit_mix),
        .fire_mix    (fire_mix),
        .exp_mix     (exp_mix),
        .rebound_mix (rebound_mix),
        .alarm_mix   (alarm_mix),
        .mix_out     (mix_out)
    );

    // ---------------------------------------------------------------
    // Output stage: the real thing. IC28's output leaves the mixer through
    // C69 / R45 / VR1 / C83 into IC27, an LA4460 BTL power amp with a fixed
    // 51 dB of gain; its DC-mute pin 6 is wire-ORed between GAME ON (via the
    // IC5 7417) and a power-on RC comparator. Both are modelled:
    //
    //   mute_ctl  ->  the pin 6 control node (mute_ctl.sv)
    //   la4460    ->  C69/C83 high-passes, the amp's own 47 Hz and 9 kHz
    //                 corners, the VR1 divider, 51 dB, and the 8.6 V clip
    //
    // What used to sit here was `MASTER_VOL`, a single scalar standing in for
    // the whole of that. It is gone: VR1's setting now lives inside la4460.sv
    // as the k = 0.100 term of OUT_GAIN_Q16, which is the only number that
    // moves when the pot is recalibrated. Do not reintroduce a second volume
    // constant at this level.
    // ---------------------------------------------------------------
    wire dc_mute;

    mute_ctl u_mute (
        .clk     (clk),
        .rst_n   (rst_n),
        .game_on (ppi1_pb[7]),   // GAME ON, active high
        .dc_mute (dc_mute)
    );

    assign dbg_dc_mute = dc_mute;

    logic signed [15:0] amp_out;

    logic                amp_mul_req_valid, amp_mul_req_ready;
    logic signed [63:0]  amp_mul_req_a, amp_mul_req_b;
    logic [6:0]          amp_mul_req_a_width, amp_mul_req_b_width;
    logic [7:0]          amp_mul_req_tag;
    logic                amp_mul_rsp_valid;
    logic signed [127:0] amp_mul_rsp_product;
    logic [7:0]          amp_mul_rsp_tag;

    // Two physical 27x27 DSP lanes are arbitrated across all six clients.
    // Each channel has at most one request in flight; tagged responses return
    // only to that client.
    shared_mul_pool u_shared_mul_pool (
        .clk(clk), .rst_n(rst_n),
        .la_req_valid(amp_mul_req_valid), .la_req_ready(amp_mul_req_ready),
        .la_req_a(amp_mul_req_a), .la_req_b(amp_mul_req_b),
        .la_req_a_width(amp_mul_req_a_width), .la_req_b_width(amp_mul_req_b_width), .la_req_tag(amp_mul_req_tag),
        .la_rsp_valid(amp_mul_rsp_valid), .la_rsp_product(amp_mul_rsp_product), .la_rsp_tag(amp_mul_rsp_tag),
        .exp_req_valid(exp_mul_req_valid), .exp_req_ready(exp_mul_req_ready),
        .exp_req_a(exp_mul_req_a), .exp_req_b(exp_mul_req_b),
        .exp_req_a_width(exp_mul_req_a_width), .exp_req_b_width(exp_mul_req_b_width), .exp_req_tag(exp_mul_req_tag),
        .exp_rsp_valid(exp_mul_rsp_valid), .exp_rsp_product(exp_mul_rsp_product), .exp_rsp_tag(exp_mul_rsp_tag),
        .fire_req_valid(fire_mul_req_valid), .fire_req_ready(fire_mul_req_ready),
        .fire_req_a(fire_mul_req_a), .fire_req_b(fire_mul_req_b),
        .fire_req_a_width(fire_mul_req_a_width), .fire_req_b_width(fire_mul_req_b_width), .fire_req_tag(fire_mul_req_tag),
        .fire_rsp_valid(fire_mul_rsp_valid), .fire_rsp_product(fire_mul_rsp_product), .fire_rsp_tag(fire_mul_rsp_tag),
        .ship_req_valid(ship_mul_req_valid), .ship_req_ready(ship_mul_req_ready),
        .ship_req_a(ship_mul_req_a), .ship_req_b(ship_mul_req_b),
        .ship_req_a_width(ship_mul_req_a_width), .ship_req_b_width(ship_mul_req_b_width), .ship_req_tag(ship_mul_req_tag),
        .ship_rsp_valid(ship_mul_rsp_valid), .ship_rsp_product(ship_mul_rsp_product), .ship_rsp_tag(ship_mul_rsp_tag),
        .rebound_req_valid(rebound_mul_req_valid), .rebound_req_ready(rebound_mul_req_ready),
        .rebound_req_a(rebound_mul_req_a), .rebound_req_b(rebound_mul_req_b),
        .rebound_req_a_width(rebound_mul_req_a_width), .rebound_req_b_width(rebound_mul_req_b_width), .rebound_req_tag(rebound_mul_req_tag),
        .rebound_rsp_valid(rebound_mul_rsp_valid), .rebound_rsp_product(rebound_mul_rsp_product), .rebound_rsp_tag(rebound_mul_rsp_tag),
        .hit_req_valid(hit_mul_req_valid), .hit_req_ready(hit_mul_req_ready),
        .hit_req_a(hit_mul_req_a), .hit_req_b(hit_mul_req_b),
        .hit_req_a_width(hit_mul_req_a_width), .hit_req_b_width(hit_mul_req_b_width), .hit_req_tag(hit_mul_req_tag),
        .hit_rsp_valid(hit_mul_rsp_valid), .hit_rsp_product(hit_mul_rsp_product), .hit_rsp_tag(hit_mul_rsp_tag)
    );

    la4460 u_amp (
        .clk       (clk),
        .rst_n     (rst_n),
        .sample_ce (sample_ce),
        .dc_mute   (dc_mute),
        .mix_in    (mix_out),
        .audio_out (amp_out),
        .mul_req_valid   (amp_mul_req_valid),
        .mul_req_ready   (amp_mul_req_ready),
        .mul_req_a       (amp_mul_req_a),
        .mul_req_b       (amp_mul_req_b),
        .mul_req_a_width (amp_mul_req_a_width),
        .mul_req_b_width (amp_mul_req_b_width),
        .mul_req_tag     (amp_mul_req_tag),
        .mul_rsp_valid   (amp_mul_rsp_valid),
        .mul_rsp_product (amp_mul_rsp_product),
        .mul_rsp_tag     (amp_mul_rsp_tag)
    );

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            audio_l <= 16'sd0;
            audio_r <= 16'sd0;
        end else begin
            audio_l <= amp_out;
            audio_r <= amp_out;
        end
    end

endmodule
