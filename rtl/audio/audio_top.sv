// Discrete audio top level for both games.
//
// Buck Rogers (sound board 834-5122): six discrete channels driven from PPI1
// (port A/B carry the triggers, the shared data nibble and the two latch
// strobes), summed by audio_mixer and amplified by the LA4460 model.
// GAME ON (ppi1_pb[7]) drives IC5, a 7417 open-collector buffer, onto the
// LA4460's DC-mute pin 6 (see mute_ctl.sv).
//
// Turbo (sound board 834-0123): channels driven from the CN1 bundle (PPI2),
// summed by turbo_mixer and amplified by two STK439 models (stk439.sv).
// The dbg_* outputs are taps for the Verilator bench; they synthesise away
// when left unconnected.
module audio_top (
	input  logic               clk,
	input  logic               rst_n,
	input  logic         [7:0] ppi1_pa,
	input  logic         [7:0] ppi1_pb,
	// Turbo sound-board CN1 bundle, from the third 8255 (PPI2/IC123/CSFA)
	// on the CPU board: raw port bytes in, named per the schematic below.
	// Buck Rogers ties these to their PPI2 idle levels (0xFF/0x00/0x00)
	// via segavco.v.
	input  logic         [7:0] ppi2_pa,
	input  logic         [7:0] ppi2_pb,
	input  logic         [7:0] ppi2_pc,
	// Turbo sound-board local DIP SW.1 bit 4 ("Sound System": Cockpit/
	// Upright), IC40's D address input (D-11/11), from segavco.v's
	// turbo_dsw3[7].
	input  logic                turbo_dsw3_7,
	// Selects which game's mix drives audio_l/audio_r. Several Turbo channels
	// (Other Cars, Player Car) free-run rather than being trigger-gated, so
	// they must be muxed out explicitly during a Buck Rogers session.
	input  logic                mod_turbo,
	output logic signed [15:0] audio_l,
	output logic signed [15:0] audio_r,
	output logic               sample_ce,
	// Per-channel taps, ahead of the mixer, to tell a channel saturating
	// internally from the master stage clipping.
	output logic signed [15:0] dbg_alarm_mix,
	output logic signed [15:0] dbg_fire_mix,
	output logic signed [15:0] dbg_exp_mix,
	output logic signed [15:0] dbg_hit_mix,
	output logic signed [15:0] dbg_rebound_mix,
	output logic signed [15:0] dbg_ship_mix,
	// Mute state.
	output logic               dbg_dc_mute,
	// Turbo ALARM channel, see turbo_alarm_chan.sv.
	output logic signed [15:0] dbg_turbo_alarm_mix,
	output logic                dbg_turbo_alarm_node,
	// Turbo CRASH channel, see turbo_crash_chan.sv.
	output logic signed [15:0] dbg_turbo_s2688_noise,
	output logic signed [15:0] dbg_turbo_s2688_physical,
	output logic          [2:0] dbg_turbo_s2688_ticks,
	output logic         [31:0] dbg_turbo_s2688_phase,
	output logic signed [15:0] dbg_turbo_crash_noise_in,
	output logic signed [15:0] dbg_turbo_skid_noise_in,
	output logic signed [15:0] dbg_turbo_crash_s_mix,
	output logic signed [15:0] dbg_turbo_crash_l_mix,
	output logic                dbg_turbo_crash_q_s,
	output logic                dbg_turbo_crash_q_l_main,
	output logic                dbg_turbo_crash_q_l_tail,
	output logic signed [15:0] dbg_turbo_crash_preamp,
	output logic signed [15:0] dbg_turbo_crash_main_shaped,
	output logic signed [15:0] dbg_turbo_crash_tail_shaped,
	output logic signed [31:0] dbg_turbo_crash_main_shaped_raw,
	output logic signed [31:0] dbg_turbo_crash_tail_shaped_raw,
	output logic signed [15:0] dbg_turbo_crash_main_control,
	output logic signed [15:0] dbg_turbo_crash_tail_c43,
	output logic signed [15:0] dbg_turbo_crash_tail_control,
	output logic signed [15:0] dbg_turbo_crash_main_vca,
	output logic signed [15:0] dbg_turbo_crash_tail_vca,
	output logic signed [15:0] dbg_turbo_crash_ic33_sum,
	output logic [31:0] dbg_turbo_crash_preamp_clip_count,
	output logic [31:0] dbg_turbo_crash_main_clip_count,
	output logic [31:0] dbg_turbo_crash_tail_clip_count,
	output logic [31:0] dbg_turbo_crash_main_vca_clip_count,
	output logic [31:0] dbg_turbo_crash_tail_vca_clip_count,
	output logic [31:0] dbg_turbo_crash_ic33_clip_count,
	// Turbo SKID channel, see turbo_skid_chan.sv.
	output logic signed [15:0] dbg_turbo_skid_mix,
	output logic                dbg_turbo_skid_q_slip,
	output logic                dbg_turbo_skid_gate,
	// Turbo AMBULANCE channel, see turbo_ambulance_chan.sv.
	output logic signed [15:0] dbg_turbo_ambulance_mix,
	output logic                dbg_turbo_ambulance_warble,
	// Turbo OTHER CARS + OTHER CAR OSC channel, see turbo_othercars_chan.sv.
	output logic signed [15:0] dbg_turbo_othercars_f,
	output logic signed [15:0] dbg_turbo_othercars_l,
	output logic signed [15:0] dbg_turbo_othercars_r,
	output logic signed [15:0] dbg_turbo_othercars_w,
	output logic signed [15:0] dbg_turbo_othercars_osc_a,
	output logic signed [15:0] dbg_turbo_othercars_osc_b,
	output logic signed [15:0] dbg_turbo_othercars_osc_c,
	output logic         [16:0] dbg_turbo_othercars_gain_f_q16,
	output logic         [16:0] dbg_turbo_othercars_gain_l_q16,
	output logic signed [15:0] dbg_turbo_othercars_tone_sum,
	// Turbo PLAYER CAR channel (D-8/11 + D-9/11), see turbo_playercar_chan.sv.
	output logic signed [15:0] dbg_turbo_playercar_f_mix,
	output logic signed [15:0] dbg_turbo_playercar_w_mix,
	output logic signed [15:0] dbg_turbo_playercar_m_mix,
	// Not available in this implementation; tied 0.
	output logic signed [15:0] dbg_turbo_playercar_gated,
	output logic signed [15:0] dbg_turbo_playercar_raw,
	output logic signed [15:0] dbg_turbo_playercar_shaped,
	// AC-coupled combined F/W (all 3 BSEL families), modelling the board's
	// output coupling caps. These feed the mixer below.
	output logic signed [15:0] dbg_turbo_playercar_dcblock_f,
	output logic signed [15:0] dbg_turbo_playercar_dcblock_w,
	// Turbo Mixer I + Mixer II (D-11/11 + D-7/11): the five logical bus sums
	// and the final F->L / W->R outputs (CN2-to-amp mapping, see below).
	// Computed unconditionally; only reaches audio_l/audio_r when mod_turbo.
	output logic signed [15:0] dbg_turbo_mixer_m,
	output logic signed [15:0] dbg_turbo_mixer_f,
	output logic signed [15:0] dbg_turbo_mixer_w,
	output logic signed [15:0] dbg_turbo_mixer_r,
	output logic signed [15:0] dbg_turbo_mixer_l,
	output logic signed [15:0] dbg_turbo_out_l,
	output logic signed [15:0] dbg_turbo_out_r,
	// Registered raw STK439 codes and per-sample clip telemetry, ahead of the
	// mono downmix; separate for Upper/F and Lower/W.
	output logic signed [63:0] dbg_turbo_amp_f_raw,
	output logic signed [63:0] dbg_turbo_amp_w_raw,
	output logic               dbg_turbo_amp_f_clip,
	output logic               dbg_turbo_amp_w_clip,
	output logic        [31:0] dbg_turbo_amp_f_clip_count,
	output logic        [31:0] dbg_turbo_amp_w_clip_count,
	// CN1 bundle, decoded and named per the schematic (bit map below).
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
	// signal names (active-low stays active-low in the name). `OSEL0` is
	// active-HIGH despite the bar printed over it on the CN1 sheet: D-5/11,
	// which uses the signal, shows no inverter and treats it like OSEL1/OSEL2.
	// Port A = {CRASH.L, /SLIP, OSEL0, TRIG4..TRIG1, /CRASH.S} (MSB..LSB),
	// port B = {/SPIN, /AMBU, ACC5..ACC0},
	// port C = {SPEED3..0, BSEL1, BSEL0, OSEL2, OSEL1}.
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

`ifdef VERILATOR_SIM
	logic [7:0] dbg_pa_prev, dbg_pb_prev, dbg_pc_prev;
	always_ff @(posedge clk) begin
		if (!rst_n) begin
			dbg_pa_prev <= 8'hFF; dbg_pb_prev <= 8'hFF; dbg_pc_prev <= 8'hFF;
		end else begin
			if (ppi2_pa !== dbg_pa_prev || ppi2_pb !== dbg_pb_prev || ppi2_pc !== dbg_pc_prev) begin
				$display("CN1 CHANGE t=%0t pa=%02h pb=%02h pc=%02h acc=%0d osel0=%0d osel12=%0d bsel=%0d",
						  $time, ppi2_pa, ppi2_pb, ppi2_pc, cn1_acc, cn1_osel0, cn1_osel12, cn1_bsel);
				dbg_pa_prev <= ppi2_pa; dbg_pb_prev <= ppi2_pb; dbg_pc_prev <= ppi2_pc;
			end
		end
	end
`endif

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
	// Turbo ALARM channel (D-2/11), driven from the CN1 bundle.
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
	// Turbo S2688 noise source (IC8, D-3/11 + D-4/11). The board has one
	// source shared by SKID and both CRASH paths; see turbo_s2688_noise.sv.
	// ---------------------------------------------------------------
	wire signed [15:0] turbo_s2688_noise;
	wire signed [15:0] turbo_s2688_physical;
	wire        [2:0]  turbo_s2688_ticks;
	wire       [31:0]  turbo_s2688_phase;
	turbo_s2688_noise u_turbo_s2688_noise (
		.clk             (clk),
		.rst_n           (rst_n),
		.sample_ce       (sample_ce),
		.noise_raw       (turbo_s2688_noise),
		.noise_physical  (turbo_s2688_physical),
		.source_ticks_last (turbo_s2688_ticks),
		.source_phase_q32  (turbo_s2688_phase)
	);
	assign dbg_turbo_s2688_noise = turbo_s2688_noise;
	assign dbg_turbo_s2688_physical = turbo_s2688_physical;
	assign dbg_turbo_s2688_ticks = turbo_s2688_ticks;
	assign dbg_turbo_s2688_phase = turbo_s2688_phase;
	// Both consumers see the same net; the source is shared, so the
	// channels must not get independently resampled or re-seeded sequences.
	assign dbg_turbo_crash_noise_in = turbo_s2688_noise;
	assign dbg_turbo_skid_noise_in = turbo_s2688_noise;
	// ---------------------------------------------------------------
	// Turbo CRASH channel (D-4/11).
	// ---------------------------------------------------------------
	turbo_crash_chan u_turbo_crash (
		.clk                (clk),
		.rst_n              (rst_n),
		.crash_s_n          (cn1_crash_s_n),
		.crash_l_n          (cn1_crash_l_n),
		.sample_ce          (sample_ce),
		.noise_in           (turbo_s2688_noise),
		.turbo_crash_s_mix  (dbg_turbo_crash_s_mix),
		.turbo_crash_l_mix  (dbg_turbo_crash_l_mix),
		.dbg_q_crash_s      (dbg_turbo_crash_q_s),
		.dbg_q_crash_l_main (dbg_turbo_crash_q_l_main),
		.dbg_q_crash_l_tail (dbg_turbo_crash_q_l_tail),
		.dbg_preamp_out     (dbg_turbo_crash_preamp),
		.dbg_main_shaped_noise (dbg_turbo_crash_main_shaped),
		.dbg_tail_shaped_noise (dbg_turbo_crash_tail_shaped),
		.dbg_main_shaped_raw (dbg_turbo_crash_main_shaped_raw),
		.dbg_tail_shaped_raw (dbg_turbo_crash_tail_shaped_raw),
		.dbg_main_control   (dbg_turbo_crash_main_control),
		.dbg_tail_c43       (dbg_turbo_crash_tail_c43),
		.dbg_tail_control   (dbg_turbo_crash_tail_control),
		.dbg_main_vca_out   (dbg_turbo_crash_main_vca),
		.dbg_tail_vca_out   (dbg_turbo_crash_tail_vca),
		.dbg_ic33_sum       (dbg_turbo_crash_ic33_sum),
		.dbg_preamp_clip_count (dbg_turbo_crash_preamp_clip_count),
		.dbg_main_clip_count (dbg_turbo_crash_main_clip_count),
		.dbg_tail_clip_count (dbg_turbo_crash_tail_clip_count),
		.dbg_main_vca_clip_count (dbg_turbo_crash_main_vca_clip_count),
		.dbg_tail_vca_clip_count (dbg_turbo_crash_tail_vca_clip_count),
		.dbg_ic33_clip_count (dbg_turbo_crash_ic33_clip_count)
	);

	// ---------------------------------------------------------------
	// Turbo SKID channel (D-3/11).
	// ---------------------------------------------------------------
	turbo_skid_chan u_turbo_skid (
		.clk             (clk),
		.rst_n           (rst_n),
		.slip_n          (cn1_slip_n),
		.spin_n          (cn1_spin_n),
		.sample_ce       (sample_ce),
		.noise_in        (turbo_s2688_noise),
		.turbo_skid_mix  (dbg_turbo_skid_mix),
		.dbg_q_slip      (dbg_turbo_skid_q_slip),
		.dbg_gate        (dbg_turbo_skid_gate)
	);

	// ---------------------------------------------------------------
	// Turbo AMBULANCE channel (D-10/11).
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
	// Turbo OTHER CARS + OTHER CAR OSC channel (D-5/11 + D-6/11).
	// ---------------------------------------------------------------
	turbo_othercars_chan u_turbo_othercars (
		.clk                  (clk),
		.rst_n                (rst_n),
		.osel0                (cn1_osel0),
		.osel1                (cn1_osel12[0]),
		.osel2                (cn1_osel12[1]),
		.dsw3_7               (turbo_dsw3_7),
		.sample_ce            (sample_ce),
		.othercars_f          (dbg_turbo_othercars_f),
		.othercars_l          (dbg_turbo_othercars_l),
		.othercars_r          (dbg_turbo_othercars_r),
		.othercars_w          (dbg_turbo_othercars_w),
		.dbg_osc_a            (dbg_turbo_othercars_osc_a),
		.dbg_osc_b            (dbg_turbo_othercars_osc_b),
		.dbg_osc_c            (dbg_turbo_othercars_osc_c),
		.dbg_gain_f_q16       (dbg_turbo_othercars_gain_f_q16),
		.dbg_gain_l_q16       (dbg_turbo_othercars_gain_l_q16),
		.dbg_tone_sum         (dbg_turbo_othercars_tone_sum)
	);

	// ---------------------------------------------------------------
	// Turbo PLAYER CAR channel (D-8/11 + D-9/11): BCONT0/1/2 (one VCA path
	// per BSEL state) plus SLF. See turbo_playercar_chan.sv.
	// ---------------------------------------------------------------
	logic signed [15:0] playercar_mycarq_f, playercar_mycarq_w;
	logic signed [15:0] playercar_mycar1_f, playercar_mycar1_w;
	logic signed [15:0] playercar_slf;
	logic                playercar_mycar_off_n;

	turbo_playercar_chan u_turbo_playercar (
		.clk           (clk),
		.rst_n         (rst_n),
		.sample_ce     (sample_ce),
		.acc           (cn1_acc),
		.bsel          (cn1_bsel),
		.mycar_f_mix   (dbg_turbo_playercar_f_mix),
		.mycar_w_mix   (dbg_turbo_playercar_w_mix),
		.mycar_m_mix   (dbg_turbo_playercar_m_mix),
		.mycarq_f_mix  (playercar_mycarq_f),
		.mycarq_w_mix  (playercar_mycarq_w),
		.mycar1_f_mix  (playercar_mycar1_f),
		.mycar1_w_mix  (playercar_mycar1_w),
		.slf_mix       (playercar_slf),
		.dcblock_f_mix (dbg_turbo_playercar_dcblock_f),
		.dcblock_w_mix (dbg_turbo_playercar_dcblock_w),
		.mycar_off_n   (playercar_mycar_off_n),
		.dbg_source_raw    (dbg_turbo_playercar_raw),
		.dbg_source_shaped (dbg_turbo_playercar_shaped),
		.dbg_acc       (),
		.dbg_bsel      ()
	);
	assign dbg_turbo_playercar_gated = 16'sd0;

	// F/M-family pre-sum of the three player-car families. BSEL selects one
	// family's BCONT gate at a time, so at most one term is non-zero in
	// steady state; the 18-bit intermediate is saturated to 16 bits before
	// the mixer's own per-bus multiply.
	function automatic logic signed [15:0] sat16_add3(
		input logic signed [15:0] a, input logic signed [15:0] b, input logic signed [15:0] c
	);
		logic signed [17:0] sum;
		begin
			sum = {{2{a[15]}}, a} + {{2{b[15]}}, b} + {{2{c[15]}}, c};
			if (sum > 18'sd32767) sat16_add3 = 16'sd32767;
			else if (sum < -18'sd32768) sat16_add3 = 16'sh8000;
			else sat16_add3 = sum[15:0];
		end
	endfunction

	// F/W use the channel's AC-coupled combined output (dcblock_f/w_mix);
	// the raw per-family taps still carry the analogue bias point.
	wire signed [15:0] playercar_f_sum = dbg_turbo_playercar_dcblock_f;
	wire signed [15:0] playercar_w_sum = dbg_turbo_playercar_dcblock_w;
	// The channel produces no separate M value per family, so M reuses each
	// family's F tap (same simplification as in turbo_playercar_chan.sv).
	wire signed [15:0] playercar_m_sum = sat16_add3(
		playercar_mycarq_f, playercar_mycar1_f, dbg_turbo_playercar_m_mix);

	// ---------------------------------------------------------------
	// Turbo MUTE (D-11/11's own local power-on delay, IC42). Not a CN1/PPI
	// signal, and not the same circuit as Buck's mute_ctl.sv.
	// ---------------------------------------------------------------
	logic turbo_mute;

	turbo_mute_ctl u_turbo_mute (
		.clk    (clk),
		.rst_n  (rst_n),
		.mute   (turbo_mute)
	);

	// ---------------------------------------------------------------
	// Effect-trimmer defaults. The board has trimmers on Crash.S (VR4),
	// Crash.L (VR3), Skid (VR1), Ambulance (VR5) and Alarm (VR2); Other Cars
	// and Player Car are untrimmed. Wiper positions in a cabinet are
	// unknowable, so these are fixed listening-balance values, kept in one
	// block so the whole balance can be retuned in one place:
	//
	//   Crash.S   (VR4) 1.00   keeps the crash above the Other Cars bed on the F bus
	//   Crash.L   (VR3) 0.75   the "big" crash
	//   Skid      (VR1) 0.40   frequent cue, should not dominate
	//   Ambulance (VR5) 0.05   recurring background event, kept quiet
	//   Alarm     (VR2) 16/21  see below
	// ---------------------------------------------------------------
	// Q16 trims must represent +1.0 (65536), which does not fit a signed
	// 17-bit value, so the trim bus is 18 bits wide.
	localparam signed [17:0] TRIM_CRASH_S_Q16   = 18'sd65536;  // 1.00 * 65536
	localparam signed [17:0] TRIM_CRASH_L_Q16   = 18'sd49152;  // 0.75 * 65536
	localparam signed [17:0] TRIM_SKID_Q16      = 18'sd26214;  // 0.40 * 65536
	localparam signed [17:0] TRIM_AMBULANCE_Q16 = 18'sd3277;   // 0.05 * 65536

	// VR2 (Alarm). IC33-B's feedback is R225 (1K) in series with VR2 (20K
	// rheostat); turbo_alarm_chan.sv applies the maximum -(1K+20K)/22K and
	// this factor is the wiper position against that maximum,
	// (1K + VR2) / 21K, spanning 0.0476 (wiper 0) .. 1.0 (wiper max).
	// Default = wiper at 3/4 travel: (1K + 15K)/21K = 16/21 = 0.761905
	// (net IC33-B gain 16K/22K = 0.727x), so the countdown cuts through the
	// Other Cars bed.
	localparam signed [17:0] TRIM_ALARM_Q16     = 18'sd49933;  // 0.761905 * 65536

	function automatic logic signed [15:0] apply_trim(input logic signed [15:0] tap, input logic signed [17:0] trim_q16);
		logic signed [33:0] prod;
		begin
			prod = $signed(tap) * $signed(trim_q16);
			apply_trim = prod[31:16];
		end
	endfunction

	// Registered so that turbo_mixer.sv's own combinational per-bus multiply
	// is not chained behind this one within a single clk_sys edge (timing).
	// The extra sample_ce of latency (~20.8us) is inaudible.
	logic signed [15:0] crash_s_trimmed, crash_l_trimmed, skid_trimmed, ambulance_trimmed;
	logic signed [15:0] alarm_trimmed;

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			crash_s_trimmed   <= 16'sd0;
			crash_l_trimmed   <= 16'sd0;
			skid_trimmed      <= 16'sd0;
			ambulance_trimmed <= 16'sd0;
			alarm_trimmed     <= 16'sd0;
		end else if (sample_ce) begin
			crash_s_trimmed   <= apply_trim(dbg_turbo_crash_s_mix, TRIM_CRASH_S_Q16);
			crash_l_trimmed   <= apply_trim(dbg_turbo_crash_l_mix, TRIM_CRASH_L_Q16);
			skid_trimmed      <= apply_trim(dbg_turbo_skid_mix, TRIM_SKID_Q16);
			ambulance_trimmed <= apply_trim(dbg_turbo_ambulance_mix, TRIM_AMBULANCE_Q16);
			alarm_trimmed     <= apply_trim(dbg_turbo_alarm_mix, TRIM_ALARM_Q16);
		end
	end

	// ---------------------------------------------------------------
	// Turbo Mixer I + Mixer II (D-11/11 + D-7/11).
	// ---------------------------------------------------------------
	turbo_mixer u_turbo_mixer (
		.clk            (clk),
		.rst_n          (rst_n),
		.sample_ce      (sample_ce),
		.mute           (turbo_mute),
		.alarm_tap      (alarm_trimmed),
		.skid_tap       (skid_trimmed),
		.crash_s_tap    (crash_s_trimmed),
		.crash_l_tap    (crash_l_trimmed),
		.ambulance_tap  (ambulance_trimmed),
		.othercars_f_tap (dbg_turbo_othercars_f),
		.othercars_l_tap (dbg_turbo_othercars_l),
		.othercars_r_tap (dbg_turbo_othercars_r),
		.othercars_w_tap (dbg_turbo_othercars_w),
		.playercar_f    (playercar_f_sum),
		.playercar_w    (playercar_w_sum),
		.playercar_m    (playercar_m_sum),
		.slf_w_tap      (playercar_slf),
		.mixer2_m_out   (dbg_turbo_mixer_m),
		.mixer1_f_out   (dbg_turbo_mixer_f),
		.mixer1_w_out   (dbg_turbo_mixer_w),
		.mixer1_r_out   (dbg_turbo_mixer_r),
		.mixer1_l_out   (dbg_turbo_mixer_l)
	);

	// ---------------------------------------------------------------
	// CN2-pin-to-amp-channel mapping, from the cabinet wiring and power amp
	// schematics (734-0048 Upright, 734-0049 Cockpit). On the Upright
	// (2-speaker) cabinet only CN2 pin 1 (F.OUT) and pin 3 (W.OUT) are
	// wired: F->Upper, W->Lower. R.OUT/L.OUT are unconnected on the Upright
	// and M.OUT on both cabinet variants. With two output channels this
	// target implements the Upright pairing; R/L remain turbo_mixer outputs
	// but are not routed.
	//
	// Power amp stage: F/W leave the sound board (834-0123) and land on the
	// separate power-amp board (834-0121), a Sanyo STK-439 per channel
	// behind a front-panel volume pot, modelled in stk439.sv. All gain and
	// clipping happen there, and each bus is already saturated by
	// turbo_mixer, so there is no global output shift (GLOBAL_OUT_SHIFT = 0).
	// ---------------------------------------------------------------
	localparam int GLOBAL_OUT_SHIFT = 0;

	logic signed [15:0] turbo_amp_f_out, turbo_amp_w_out;

	// Timing-only pipeline stage between the wide mixer1_f/w_out sums and the
	// STK439 inputs: without it the mixer register fans straight into
	// stk439's hp_sum ripple-carry chain and setup slack becomes marginal.
	// F and W get the same extra sample_ce of latency so they stay aligned.
	// M is not registered: it only reaches a debug output.
	logic signed [15:0] mixer_f_pipe, mixer_w_pipe;
	always_ff @(posedge clk) begin
		if (!rst_n) begin
			mixer_f_pipe <= 16'sd0;
			mixer_w_pipe <= 16'sd0;
		end else if (sample_ce) begin
			mixer_f_pipe <= dbg_turbo_mixer_f;
			mixer_w_pipe <= dbg_turbo_mixer_w;
		end
	end

	stk439 u_stk439_upper (
		.clk       (clk),
		.rst_n     (rst_n),
		.sample_ce (sample_ce),
		.mix_in    (mixer_f_pipe >>> GLOBAL_OUT_SHIFT),
		.audio_out (turbo_amp_f_out),
		.raw_out   (dbg_turbo_amp_f_raw),
		.clip      (dbg_turbo_amp_f_clip),
		.clip_count(dbg_turbo_amp_f_clip_count)
	);

	stk439 u_stk439_lower (
		.clk       (clk),
		.rst_n     (rst_n),
		.sample_ce (sample_ce),
		.mix_in    (mixer_w_pipe >>> GLOBAL_OUT_SHIFT),
		.audio_out (turbo_amp_w_out),
		.raw_out   (dbg_turbo_amp_w_raw),
		.clip      (dbg_turbo_amp_w_clip),
		.clip_count(dbg_turbo_amp_w_clip_count)
	);

	// ---------------------------------------------------------------
	// Mono downmix. The cabinet has two amplifiers (F: two 12 cm speakers in
	// series, W: one 30 cm woofer) in one box, and a listener hears their
	// acoustic sum, so both MiSTer channels get the sum of the two STK439
	// outputs. It is taken after each stk439 because the amps clip
	// independently.
	//
	// The law is x0.7071 (-3 dB), not an average: the channel-to-bus map is
	// nearly disjoint (CRASH.L is W-only; Alarm/Skid/Crash.S are F-only), so
	// the buses rarely peak together and halving would cost ~6 dB on every
	// single-bus event. Shifts only, no DSP: 1/2+1/8+1/16+1/64+1/256 =
	// 0.70703. The sum saturates in case both buses do peak together.
	// ---------------------------------------------------------------
	wire signed [18:0] turbo_amp_sum = $signed({{3{turbo_amp_f_out[15]}}, turbo_amp_f_out})
									 + $signed({{3{turbo_amp_w_out[15]}}, turbo_amp_w_out});
	wire signed [18:0] turbo_amp_mono_full = (turbo_amp_sum >>> 1) + (turbo_amp_sum >>> 3) + (turbo_amp_sum >>> 4)
										   + (turbo_amp_sum >>> 6) + (turbo_amp_sum >>> 8);
	wire signed [15:0] turbo_amp_mono =
		(turbo_amp_mono_full > 19'sd32767)  ? 16'sd32767 :
		(turbo_amp_mono_full < -19'sd32768) ? 16'sh8000  :
		turbo_amp_mono_full[15:0];

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			dbg_turbo_out_l <= 16'sd0;
			dbg_turbo_out_r <= 16'sd0;
		end else if (sample_ce) begin
			dbg_turbo_out_l <= turbo_amp_mono;
			dbg_turbo_out_r <= turbo_amp_mono;
		end
	end

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
	// HIT DIS0-2 is latched on-board by IC2, a 4175B quad D flip-flop, from
	// the shared 4-bit data nibble on port A bits 0-3, strobed by the RISING
	// edge of port A bit 4. (IC6 latches ACC0-3 from the same nibble on
	// bit 5, for SHIP.) IC2 ignores D3, so only bits 2:0 are captured.
	// ---------------------------------------------------------------
	wire hit_n = ppi1_pb[4];

	logic [2:0] hit_dis;
	logic       hit_dis_clk_d;

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			hit_dis       <= 3'd0;
			// Reset the strobe history to the CURRENT level, not a constant:
			// the port idles HIGH (8255 reset -> inputs, RA pull-ups), so a
			// hardcoded 0 would create a rising edge on the first clock out
			// of reset and latch whatever is on the nibble.
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
			acc_clk_d <= ppi1_pa[5];   // reset to the current level, as for hit_dis_clk_d
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
	// Output stage. IC28's output leaves the mixer through C69 / R45 / VR1 /
	// C83 into IC27, an LA4460 BTL power amp with a fixed 51 dB of gain; its
	// DC-mute pin 6 is wire-ORed between GAME ON (via the IC5 7417) and a
	// power-on RC comparator.
	//
	//   mute_ctl  ->  the pin 6 control node (mute_ctl.sv)
	//   la4460    ->  C69/C83 high-passes, the amp's own 47 Hz and 9 kHz
	//                 corners, the VR1 divider, 51 dB, and the 8.6 V clip
	//
	// VR1's setting lives in la4460.sv (the k = 0.100 term of OUT_GAIN_Q16);
	// there is deliberately no second volume constant here.
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

	// Two physical 27x27 DSP lanes serve all six clients. Each channel has at
	// most one request in flight; tagged responses return only to that client.
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
			// Explicit game select; see the mod_turbo port comment.
			audio_l <= mod_turbo ? dbg_turbo_out_l : amp_out;
			audio_r <= mod_turbo ? dbg_turbo_out_r : amp_out;
		end
	end

endmodule
