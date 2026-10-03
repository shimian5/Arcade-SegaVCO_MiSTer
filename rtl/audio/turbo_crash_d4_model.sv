// Turbo D-4/11 CRASH.L analogue model: the IC10 shaping networks (main: pins 8-10, tail: pins
// 12-14), the two MB4391 (MC3340) VCA sections of IC29 and the IC33 summer.
//
// The shaping filters are third-order. Their coefficients are frozen offline (not computed
// in RTL) as a real-pole plus complex-pole cascade:
//
//   H(z) = K (1-z^-1)^2 /
//          ((1-p z^-1)(1-a z^-1+b z^-2))
//
// It needs four Q30 coefficient multipliers per branch and keeps the unrailed cascade
// states visible for the unit bench. Only the physical IC10 outputs, VCA outputs and
// the IC33 output are rail limited.
//
// Q12 is centred audio voltage (4096 counts/V); Q20 is control voltage; Q16 is the
// MC3340 gain table; coefficients are Q30. All multiplies go through one shared lane
// in sequence (see the scheduler below), so one sample takes many clk_sys cycles.
module turbo_crash_d4_model #(
	// Production assumption: MB4391 effective input loading is 10K. This is an
	// assumption, not a schematic- or datasheet-derived impedance. Zero is the
	// high-Z/unity coupling limit; 20K/50K/100K are sensitivity cases.
	parameter int IC29_ZIN_OHMS = 10000
) (
	input  logic clk,
	input  logic rst_n,
	input  logic sample_ce,
	input  logic source_ready,
	input  logic signed [15:0] source_in,
	input  logic signed [63:0] main_control_q20,
	input  logic signed [63:0] tail_control_q20,
	output logic signed [15:0] ic29_main_input,
	output logic signed [15:0] ic29_tail_input,
	output logic signed [31:0] main_pin8_raw,
	output logic signed [31:0] tail_pin14_raw,
	output logic signed [15:0] main_pin8_rail,
	output logic signed [15:0] tail_pin14_rail,
	output logic signed [63:0] main_vca_raw,
	output logic signed [63:0] tail_vca_raw,
	output logic signed [15:0] main_vca_rail,
	output logic signed [15:0] tail_vca_rail,
	output logic signed [63:0] ic33_raw,
	output logic signed [15:0] ic33_rail,
	output logic [31:0] main_pin_clip_count,
	output logic [31:0] tail_pin_clip_count,
	output logic [31:0] main_vca_clip_count,
	output logic [31:0] tail_vca_clip_count,
	output logic [31:0] ic33_clip_count,
	output logic signed [31:0] dbg_main_hp_state,
	output logic signed [31:0] dbg_main_y_state,
	output logic signed [31:0] dbg_tail_hp_state,
	output logic signed [31:0] dbg_tail_y_state,
	output logic [15:0] dbg_scheduler_cycles_last,
	output logic [15:0] dbg_scheduler_cycles_max,
	output logic signed [15:0] dbg_source_txn
);

	localparam logic signed [63:0] RAIL_Q12 = 64'sd18432;
	localparam logic signed [63:0] Q30_ONE = 64'sd1073741824;
	localparam logic signed [63:0] IC33_MAIN_GAIN_Q20 = 64'sd4753545;
	localparam logic signed [63:0] IC33_TAIL_GAIN_Q20 = 64'sd7130317;

	// Offline-frozen Q30 coefficients, fs = 47,998.875 Hz.
	localparam logic signed [31:0] MAIN_K_Q30 = -32'sd470355346;
	localparam logic signed [31:0] MAIN_P_Q30 =  32'sd1073099179;
	localparam logic signed [31:0] MAIN_A_Q30 =  32'sd2114745692;
	localparam logic signed [31:0] MAIN_B_Q30 =  32'sd1053233859;
	localparam logic signed [31:0] TAIL_K_Q30 = -32'sd101011723;
	localparam logic signed [31:0] TAIL_P_Q30 =  32'sd1073375645;
	localparam logic signed [31:0] TAIL_A_Q30 =  32'sd2142199170;
	localparam logic signed [31:0] TAIL_B_Q30 =  32'sd1068779969;

	// Coupling high-pass coefficients, frozen offline. A finite case represents
	// alpha*(1-z^-1)/(1-A z^-1) with C = 1uF and Rseries = 33K: alpha = Rin/(33K+Rin),
	// and the coupling pole uses C = 1uF with (33K+Rin) total resistance.
	localparam logic signed [31:0] COUPLE_ALPHA_10K_Q30 = 32'sd249707401;
	localparam logic signed [31:0] COUPLE_A_10K_Q30     = 32'sd1073221714;
	localparam logic signed [31:0] COUPLE_ALPHA_20K_Q30 = 32'sd405185594;
	localparam logic signed [31:0] COUPLE_A_20K_Q30     = 32'sd1073319829;
	localparam logic signed [31:0] COUPLE_ALPHA_50K_Q30 = 32'sd646832424;
	localparam logic signed [31:0] COUPLE_A_50K_Q30     = 32'sd1073472338;
	localparam logic signed [31:0] COUPLE_ALPHA_100K_Q30 = 32'sd807324680;
	localparam logic signed [31:0] COUPLE_A_100K_Q30     = 32'sd1073573641;

	logic signed [31:0] source_state;
	logic signed [31:0] main_hp_state, main_y_state, main_y2_state;
	logic signed [31:0] tail_hp_state, tail_y_state, tail_y2_state;
	logic signed [63:0] main_couple_lp, tail_couple_lp;

	logic signed [31:0] couple_alpha_q30, couple_a_q30;
	logic signed [31:0] couple_one_minus_a_q30;
	always_comb begin
		couple_alpha_q30 = 32'sh40000000;
		couple_a_q30 = 32'sd0;
		case (IC29_ZIN_OHMS)
			10000: begin couple_alpha_q30 = COUPLE_ALPHA_10K_Q30; couple_a_q30 = COUPLE_A_10K_Q30; end
			20000: begin couple_alpha_q30 = COUPLE_ALPHA_20K_Q30; couple_a_q30 = COUPLE_A_20K_Q30; end
			50000: begin couple_alpha_q30 = COUPLE_ALPHA_50K_Q30; couple_a_q30 = COUPLE_A_50K_Q30; end
			100000: begin couple_alpha_q30 = COUPLE_ALPHA_100K_Q30; couple_a_q30 = COUPLE_A_100K_Q30; end
			default: begin end
		endcase
		couple_one_minus_a_q30 = Q30_ONE - couple_a_q30;
	end

	// MC3340 gain LUT (65 points, V2 = 2.0..6.0 V in 0.0625 V steps).
	localparam logic [31:0] VCA_GAIN_LUT [0:64] = '{
		32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739,
		32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739,
		32'd292739, 32'd292739, 32'd253501, 32'd176901, 32'd123447, 32'd86145, 32'd60115, 32'd41950,
		32'd29274, 32'd21952, 32'd16462, 32'd12345, 32'd9257, 32'd6942, 32'd5206, 32'd3904,
		32'd2927, 32'd2195, 32'd1646, 32'd1234, 32'd926, 32'd694, 32'd521, 32'd390,
		32'd293, 32'd220, 32'd165, 32'd123, 32'd93, 32'd69, 32'd52, 32'd39,
		32'd29, 32'd25, 32'd22, 32'd19, 32'd16, 32'd14, 32'd12, 32'd11,
		32'd9, 32'd9, 32'd9, 32'd9, 32'd9, 32'd9, 32'd9, 32'd9,
		32'd9
	};

	function automatic logic signed [63:0] sign_extend_width(
		input logic [63:0] value,
		input integer width
	);
		integer i;
		begin
			sign_extend_width = '0;
			for (i = 0; i < 64; i = i + 1)
				sign_extend_width[i] = (i < width) ? value[i] : value[width - 1];
		end
	endfunction

	function automatic logic signed [63:0] shifted_lane_product(
		input logic signed [127:0] product,
		input logic [6:0] shift
	);
		logic signed [127:0] shifted;
		begin
			shifted = product >>> shift;
			shifted_lane_product = shifted[63:0];
		end
	endfunction

	function automatic logic signed_ext_ok(
		input logic signed [63:0] value,
		input logic [6:0] width
	);
		integer i;
		begin
			signed_ext_ok = (width >= 1) && (width <= 64);
			if (signed_ext_ok)
				for (i = 0; i < 64; i = i + 1)
					if ((i >= width) && (value[i] != value[width - 1]))
						signed_ext_ok = 1'b0;
		end
	endfunction

	function automatic logic signed [47:0] rail_q12(input logic signed [63:0] value);
		begin
			if (value > RAIL_Q12)
				rail_q12 = 48'sd18432;
			else if (value < -RAIL_Q12)
				rail_q12 = -48'sd18432;
			else
				rail_q12 = value[47:0];
		end
	endfunction

	function automatic logic signed [15:0] pcm16(input logic signed [63:0] value);
		begin
			if (value > 64'sd32767)
				pcm16 = 16'sd32767;
			else if (value < -64'sd32768)
				pcm16 = 16'sh8000;
			else
				pcm16 = value[15:0];
		end
	endfunction

	logic signed [20:0] main_gain_q16, tail_gain_q16;

	typedef enum logic [1:0] {D_IDLE, D_REQ, D_WAIT, D_READY} d_state_t;
	typedef enum logic [5:0] {
		D_OP_MAIN_HP_P, D_OP_TAIL_HP_P, D_OP_MAIN_A_Y, D_OP_MAIN_B_Y2,
		D_OP_TAIL_A_Y, D_OP_TAIL_B_Y2, D_OP_MAIN_K, D_OP_TAIL_K,
		D_OP_MAIN_LP_A, D_OP_MAIN_LP_ONE, D_OP_TAIL_LP_A, D_OP_TAIL_LP_ONE,
		D_OP_MAIN_ALPHA, D_OP_TAIL_ALPHA, D_OP_MAIN_GAIN, D_OP_TAIL_GAIN,
		D_OP_MAIN_VCA, D_OP_TAIL_VCA, D_OP_MAIN_IC33, D_OP_TAIL_IC33
	} d_op_t;

	d_state_t d_state;
	d_op_t d_op;
	logic d_result_ready;
	logic d_txn_latched;
	logic [15:0] d_cycle_counter;
	logic signed [15:0] d_source_txn;
	logic signed [63:0] d_main_control_txn, d_tail_control_txn;
	logic signed [31:0] d_source_state_txn;
	logic signed [31:0] d_main_hp_state_txn, d_main_y_state_txn, d_main_y2_state_txn;
	logic signed [31:0] d_tail_hp_state_txn, d_tail_y_state_txn, d_tail_y2_state_txn;
	logic signed [63:0] d_main_couple_lp_txn, d_tail_couple_lp_txn;
	logic signed [20:0] d_main_gain_txn, d_tail_gain_txn;
	logic signed [63:0] d_main_hp_mul, d_tail_hp_mul;
	logic signed [63:0] d_main_a_mul, d_main_b_mul, d_tail_a_mul, d_tail_b_mul;
	logic signed [63:0] d_main_k_mul, d_tail_k_mul;
	logic signed [63:0] d_main_lp_a_mul, d_main_lp_one_mul;
	logic signed [63:0] d_tail_lp_a_mul, d_tail_lp_one_mul;
	logic signed [63:0] d_main_alpha_mul, d_tail_alpha_mul;
	logic signed [63:0] d_main_gain_mul, d_tail_gain_mul;
	logic signed [63:0] d_main_vca_mul, d_tail_vca_mul;
	logic signed [63:0] d_main_ic33_mul, d_tail_ic33_mul;

	logic signed [63:0] source_wide;
	logic signed [63:0] main_hp_next_wide, tail_hp_next_wide;
	logic signed [31:0] main_hp_next, tail_hp_next;
	logic signed [63:0] main_y_next_wide, tail_y_next_wide;
	logic signed [31:0] main_y_next, tail_y_next;
	logic signed [31:0] main_y2_next, tail_y2_next;
	logic signed [63:0] main_pin8_raw_wide, tail_pin14_raw_wide;
	logic signed [47:0] main_pin8_rail_wide, tail_pin14_rail_wide;
	logic signed [63:0] main_couple_diff, tail_couple_diff;
	logic signed [63:0] main_couple_lp_next, tail_couple_lp_next;
	logic signed [63:0] main_ic29_input_wide, tail_ic29_input_wide;
	logic signed [63:0] main_vca_raw_wide, tail_vca_raw_wide;
	logic signed [47:0] main_vca_rail_wide, tail_vca_rail_wide;
	logic signed [63:0] ic33_main_wide, ic33_tail_wide, ic33_raw_wide;
	logic signed [47:0] ic33_rail_wide;
	logic signed [20:0] main_gain_next, tail_gain_next;
	logic signed [63:0] main_gain_clamped, tail_gain_clamped;
	logic signed [63:0] main_gain_offset, tail_gain_offset;
	logic [6:0] main_gain_index, tail_gain_index;
	logic signed [32:0] main_gain_low, main_gain_high;
	logic signed [32:0] tail_gain_low, tail_gain_high;
	logic signed [19:0] main_gain_delta, tail_gain_delta;
	logic signed [16:0] main_gain_fraction, tail_gain_fraction;

	always_comb begin
		main_gain_clamped = (d_main_control_txn < 64'sd2097152) ? 64'sd2097152 :
							(d_main_control_txn > 64'sd6291456) ? 64'sd6291456 : d_main_control_txn;
		tail_gain_clamped = (d_tail_control_txn < 64'sd2097152) ? 64'sd2097152 :
							(d_tail_control_txn > 64'sd6291456) ? 64'sd6291456 : d_tail_control_txn;
		main_gain_offset = main_gain_clamped - 64'sd2097152;
		tail_gain_offset = tail_gain_clamped - 64'sd2097152;
		main_gain_index = main_gain_offset[22:16];
		tail_gain_index = tail_gain_offset[22:16];
		if (main_gain_index >= 7'd64) main_gain_index = 7'd63;
		if (tail_gain_index >= 7'd64) tail_gain_index = 7'd63;
		main_gain_fraction = $signed({1'b0, main_gain_offset[15:0]});
		tail_gain_fraction = $signed({1'b0, tail_gain_offset[15:0]});
		main_gain_low = $signed({1'b0, VCA_GAIN_LUT[main_gain_index]});
		main_gain_high = $signed({1'b0, VCA_GAIN_LUT[main_gain_index + 1'b1]});
		tail_gain_low = $signed({1'b0, VCA_GAIN_LUT[tail_gain_index]});
		tail_gain_high = $signed({1'b0, VCA_GAIN_LUT[tail_gain_index + 1'b1]});
		main_gain_delta = main_gain_high - main_gain_low;
		tail_gain_delta = tail_gain_high - tail_gain_low;
	end

	always_comb begin
		source_wide = sign_extend_width({48'd0, d_source_txn}, 16);
		main_hp_next_wide = source_wide - d_source_state_txn + d_main_hp_mul;
		tail_hp_next_wide = source_wide - d_source_state_txn + d_tail_hp_mul;
		main_hp_next = main_hp_next_wide[31:0];
		tail_hp_next = tail_hp_next_wide[31:0];
		main_y_next_wide = main_hp_next_wide - d_main_hp_state_txn + d_main_a_mul - d_main_b_mul;
		tail_y_next_wide = tail_hp_next_wide - d_tail_hp_state_txn + d_tail_a_mul - d_tail_b_mul;
		main_y_next = main_y_next_wide[31:0];
		tail_y_next = tail_y_next_wide[31:0];
		main_y2_next = d_main_y_state_txn;
		tail_y2_next = d_tail_y_state_txn;
		main_pin8_raw_wide = d_main_k_mul;
		tail_pin14_raw_wide = d_tail_k_mul;
		main_pin8_rail_wide = rail_q12(main_pin8_raw_wide);
		tail_pin14_rail_wide = rail_q12(tail_pin14_raw_wide);
		main_couple_lp_next = d_main_lp_a_mul + d_main_lp_one_mul;
		tail_couple_lp_next = d_tail_lp_a_mul + d_tail_lp_one_mul;
		main_couple_diff = main_pin8_rail_wide - main_couple_lp_next;
		tail_couple_diff = tail_pin14_rail_wide - tail_couple_lp_next;
		if (IC29_ZIN_OHMS == 0) begin
			main_couple_lp_next = 64'sd0;
			tail_couple_lp_next = 64'sd0;
			main_ic29_input_wide = main_pin8_rail_wide;
			tail_ic29_input_wide = tail_pin14_rail_wide;
		end else begin
			main_ic29_input_wide = d_main_alpha_mul;
			tail_ic29_input_wide = d_tail_alpha_mul;
		end
		main_gain_next = 21'($signed(main_gain_low) + $signed(d_main_gain_mul));
		tail_gain_next = 21'($signed(tail_gain_low) + $signed(d_tail_gain_mul));
		main_vca_raw_wide = d_main_vca_mul;
		tail_vca_raw_wide = d_tail_vca_mul;
		main_vca_rail_wide = rail_q12(main_vca_raw_wide);
		tail_vca_rail_wide = rail_q12(tail_vca_raw_wide);
		ic33_main_wide = d_main_ic33_mul;
		ic33_tail_wide = d_tail_ic33_mul;
		ic33_raw_wide = -(ic33_main_wide + ic33_tail_wide);
		ic33_rail_wide = rail_q12(ic33_raw_wide);
	end

	logic d_lane_req_valid, d_lane_req_ready;
	logic signed [63:0] d_lane_req_a, d_lane_req_b;
	logic [6:0] d_lane_req_a_width, d_lane_req_b_width;
	logic [7:0] d_lane_req_tag;
	logic d_lane_rsp_valid;
	logic signed [127:0] d_lane_rsp_product;
	logic [7:0] d_lane_rsp_tag;

	always_comb begin
		d_lane_req_a = 64'sd0; d_lane_req_b = 64'sd0;
		d_lane_req_a_width = 7'd1; d_lane_req_b_width = 7'd1;
		d_lane_req_tag = d_op;
		case (d_op)
			D_OP_MAIN_HP_P: begin d_lane_req_a = sign_extend_width(MAIN_P_Q30, 32); d_lane_req_b = sign_extend_width(d_main_hp_state_txn, 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_TAIL_HP_P: begin d_lane_req_a = sign_extend_width(TAIL_P_Q30, 32); d_lane_req_b = sign_extend_width(d_tail_hp_state_txn, 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_MAIN_A_Y: begin d_lane_req_a = sign_extend_width(MAIN_A_Q30, 32); d_lane_req_b = sign_extend_width(d_main_y_state_txn, 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_MAIN_B_Y2: begin d_lane_req_a = sign_extend_width(MAIN_B_Q30, 32); d_lane_req_b = sign_extend_width(d_main_y2_state_txn, 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_TAIL_A_Y: begin d_lane_req_a = sign_extend_width(TAIL_A_Q30, 32); d_lane_req_b = sign_extend_width(d_tail_y_state_txn, 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_TAIL_B_Y2: begin d_lane_req_a = sign_extend_width(TAIL_B_Q30, 32); d_lane_req_b = sign_extend_width(d_tail_y2_state_txn, 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_MAIN_K: begin d_lane_req_a = sign_extend_width(MAIN_K_Q30, 32); d_lane_req_b = sign_extend_width(main_y_next, 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_TAIL_K: begin d_lane_req_a = sign_extend_width(TAIL_K_Q30, 32); d_lane_req_b = sign_extend_width(tail_y_next, 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_MAIN_LP_A: begin d_lane_req_a = sign_extend_width(couple_a_q30, 32); d_lane_req_b = sign_extend_width(d_main_couple_lp_txn[31:0], 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_MAIN_LP_ONE: begin d_lane_req_a = sign_extend_width(couple_one_minus_a_q30, 32); d_lane_req_b = sign_extend_width(main_pin8_rail_wide[31:0], 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_TAIL_LP_A: begin d_lane_req_a = sign_extend_width(couple_a_q30, 32); d_lane_req_b = sign_extend_width(d_tail_couple_lp_txn[31:0], 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_TAIL_LP_ONE: begin d_lane_req_a = sign_extend_width(couple_one_minus_a_q30, 32); d_lane_req_b = sign_extend_width(tail_pin14_rail_wide[31:0], 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_MAIN_ALPHA: begin d_lane_req_a = sign_extend_width(couple_alpha_q30, 32); d_lane_req_b = sign_extend_width(main_couple_diff[31:0], 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_TAIL_ALPHA: begin d_lane_req_a = sign_extend_width(couple_alpha_q30, 32); d_lane_req_b = sign_extend_width(tail_couple_diff[31:0], 32); d_lane_req_a_width = 7'd32; d_lane_req_b_width = 7'd32; end
			D_OP_MAIN_GAIN: begin d_lane_req_a = sign_extend_width(main_gain_delta, 20); d_lane_req_b = sign_extend_width(main_gain_fraction, 17); d_lane_req_a_width = 7'd20; d_lane_req_b_width = 7'd17; end
			D_OP_TAIL_GAIN: begin d_lane_req_a = sign_extend_width(tail_gain_delta, 20); d_lane_req_b = sign_extend_width(tail_gain_fraction, 17); d_lane_req_a_width = 7'd20; d_lane_req_b_width = 7'd17; end
			D_OP_MAIN_VCA: begin d_lane_req_a = sign_extend_width(main_ic29_input_wide, 16); d_lane_req_b = sign_extend_width(d_main_gain_txn, 20); d_lane_req_a_width = 7'd16; d_lane_req_b_width = 7'd20; end
			D_OP_TAIL_VCA: begin d_lane_req_a = sign_extend_width(tail_ic29_input_wide, 16); d_lane_req_b = sign_extend_width(d_tail_gain_txn, 20); d_lane_req_a_width = 7'd16; d_lane_req_b_width = 7'd20; end
			D_OP_MAIN_IC33: begin d_lane_req_a = sign_extend_width(main_vca_rail_wide, 16); d_lane_req_b = sign_extend_width(IC33_MAIN_GAIN_Q20, 24); d_lane_req_a_width = 7'd16; d_lane_req_b_width = 7'd24; end
			D_OP_TAIL_IC33: begin d_lane_req_a = sign_extend_width(tail_vca_rail_wide, 16); d_lane_req_b = sign_extend_width(IC33_TAIL_GAIN_Q20, 24); d_lane_req_a_width = 7'd16; d_lane_req_b_width = 7'd24; end
			default: begin end
		endcase
	end

	assign d_lane_req_valid = (d_state == D_REQ);

	shared_mul_lane u_d4_shared_mul_lane (
		.clk(clk), .rst_n(rst_n),
		.req_valid(d_lane_req_valid), .req_ready(d_lane_req_ready),
		.req_a(d_lane_req_a), .req_b(d_lane_req_b),
		.req_a_width(d_lane_req_a_width), .req_b_width(d_lane_req_b_width),
		.req_tag(d_lane_req_tag),
		.rsp_valid(d_lane_rsp_valid), .rsp_product(d_lane_rsp_product),
		.rsp_tag(d_lane_rsp_tag)
	);

	assign dbg_main_hp_state = main_hp_state;
	assign dbg_main_y_state = main_y_state;
	assign dbg_tail_hp_state = tail_hp_state;
	assign dbg_tail_y_state = tail_y_state;
	assign dbg_source_txn = d_source_txn;

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			d_state <= D_IDLE; d_op <= D_OP_MAIN_HP_P; d_result_ready <= 1'b0;
			d_txn_latched <= 1'b0;
			d_cycle_counter <= 16'd0;
			dbg_scheduler_cycles_last <= 16'd0; dbg_scheduler_cycles_max <= 16'd0;
			d_source_txn <= '0; d_main_control_txn <= '0; d_tail_control_txn <= '0;
			d_source_state_txn <= '0;
			d_main_hp_state_txn <= '0; d_main_y_state_txn <= '0; d_main_y2_state_txn <= '0;
			d_tail_hp_state_txn <= '0; d_tail_y_state_txn <= '0; d_tail_y2_state_txn <= '0;
			d_main_couple_lp_txn <= '0; d_tail_couple_lp_txn <= '0;
			d_main_gain_txn <= 21'sd9; d_tail_gain_txn <= 21'sd9;
			d_main_hp_mul <= '0; d_tail_hp_mul <= '0; d_main_a_mul <= '0; d_main_b_mul <= '0;
			d_tail_a_mul <= '0; d_tail_b_mul <= '0; d_main_k_mul <= '0; d_tail_k_mul <= '0;
			d_main_lp_a_mul <= '0; d_main_lp_one_mul <= '0; d_tail_lp_a_mul <= '0; d_tail_lp_one_mul <= '0;
			d_main_alpha_mul <= '0; d_tail_alpha_mul <= '0; d_main_gain_mul <= '0; d_tail_gain_mul <= '0;
			d_main_vca_mul <= '0; d_tail_vca_mul <= '0; d_main_ic33_mul <= '0; d_tail_ic33_mul <= '0;
			source_state <= '0; main_hp_state <= '0; main_y_state <= '0; main_y2_state <= '0;
			tail_hp_state <= '0; tail_y_state <= '0; tail_y2_state <= '0;
			main_couple_lp <= '0; tail_couple_lp <= '0;
			main_gain_q16 <= 21'sd9; tail_gain_q16 <= 21'sd9;
			ic29_main_input <= '0; ic29_tail_input <= '0; main_pin8_raw <= '0; tail_pin14_raw <= '0;
			main_pin8_rail <= '0; tail_pin14_rail <= '0; main_vca_raw <= '0; tail_vca_raw <= '0;
			main_vca_rail <= '0; tail_vca_rail <= '0; ic33_raw <= '0; ic33_rail <= '0;
			main_pin_clip_count <= '0; tail_pin_clip_count <= '0; main_vca_clip_count <= '0;
			tail_vca_clip_count <= '0; ic33_clip_count <= '0;
		end else begin
			if (d_state != D_IDLE && d_state != D_READY)
				d_cycle_counter <= d_cycle_counter + 1'b1;
			if (d_state == D_READY) begin
				if (sample_ce) begin
					source_state <= d_source_txn;
					main_hp_state <= main_hp_next; main_y_state <= main_y_next; main_y2_state <= main_y2_next;
					tail_hp_state <= tail_hp_next; tail_y_state <= tail_y_next; tail_y2_state <= tail_y2_next;
					main_couple_lp <= main_couple_lp_next; tail_couple_lp <= tail_couple_lp_next;
					main_gain_q16 <= main_gain_next; tail_gain_q16 <= tail_gain_next;
					ic29_main_input <= pcm16(main_ic29_input_wide); ic29_tail_input <= pcm16(tail_ic29_input_wide);
					main_pin8_raw <= main_pin8_raw_wide[31:0]; tail_pin14_raw <= tail_pin14_raw_wide[31:0];
					main_pin8_rail <= pcm16(main_pin8_rail_wide); tail_pin14_rail <= pcm16(tail_pin14_rail_wide);
					main_vca_raw <= main_vca_raw_wide; tail_vca_raw <= tail_vca_raw_wide;
					main_vca_rail <= pcm16(main_vca_rail_wide); tail_vca_rail <= pcm16(tail_vca_rail_wide);
					ic33_raw <= ic33_raw_wide; ic33_rail <= pcm16(ic33_rail_wide);
					if ((main_pin8_raw_wide > RAIL_Q12) || (main_pin8_raw_wide < -RAIL_Q12)) main_pin_clip_count <= main_pin_clip_count + 1'b1;
					if ((tail_pin14_raw_wide > RAIL_Q12) || (tail_pin14_raw_wide < -RAIL_Q12)) tail_pin_clip_count <= tail_pin_clip_count + 1'b1;
					if ((main_vca_raw_wide > RAIL_Q12) || (main_vca_raw_wide < -RAIL_Q12)) main_vca_clip_count <= main_vca_clip_count + 1'b1;
					if ((tail_vca_raw_wide > RAIL_Q12) || (tail_vca_raw_wide < -RAIL_Q12)) tail_vca_clip_count <= tail_vca_clip_count + 1'b1;
					if ((ic33_raw_wide > RAIL_Q12) || (ic33_raw_wide < -RAIL_Q12)) ic33_clip_count <= ic33_clip_count + 1'b1;
					d_result_ready <= 1'b0; d_txn_latched <= 1'b0; d_state <= D_IDLE;
				end
			end else if (d_state == D_IDLE) begin
	// Controls and filter state are captured on the first idle clock so they cannot move
	// across a trigger/envelope transition while the registered preamp source (which may
	// arrive a few clocks later) is awaited.
				if (!d_txn_latched) begin
					d_main_control_txn <= main_control_q20; d_tail_control_txn <= tail_control_q20;
					d_source_state_txn <= source_state;
					d_main_hp_state_txn <= main_hp_state; d_main_y_state_txn <= main_y_state; d_main_y2_state_txn <= main_y2_state;
					d_tail_hp_state_txn <= tail_hp_state; d_tail_y_state_txn <= tail_y_state; d_tail_y2_state_txn <= tail_y2_state;
					d_main_couple_lp_txn <= main_couple_lp; d_tail_couple_lp_txn <= tail_couple_lp;
					d_main_gain_txn <= main_gain_q16; d_tail_gain_txn <= tail_gain_q16;
					d_txn_latched <= 1'b1;
				end
				if (source_ready) begin
					d_source_txn <= source_in;
					d_op <= D_OP_MAIN_HP_P; d_cycle_counter <= 16'd0; d_state <= D_REQ;
				end
			end else if (d_state == D_REQ) begin
				if (d_lane_req_ready) d_state <= D_WAIT;
			end else if (d_state == D_WAIT) begin
				if (d_lane_rsp_valid) begin
					case (d_op)
						D_OP_MAIN_HP_P: d_main_hp_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_TAIL_HP_P: d_tail_hp_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_MAIN_A_Y: d_main_a_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_MAIN_B_Y2: d_main_b_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_TAIL_A_Y: d_tail_a_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_TAIL_B_Y2: d_tail_b_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_MAIN_K: d_main_k_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_TAIL_K: d_tail_k_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_MAIN_LP_A: d_main_lp_a_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_MAIN_LP_ONE: d_main_lp_one_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_TAIL_LP_A: d_tail_lp_a_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_TAIL_LP_ONE: d_tail_lp_one_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_MAIN_ALPHA: d_main_alpha_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_TAIL_ALPHA: d_tail_alpha_mul <= shifted_lane_product(d_lane_rsp_product, 30);
						D_OP_MAIN_GAIN: d_main_gain_mul <= shifted_lane_product(d_lane_rsp_product, 16);
						D_OP_TAIL_GAIN: d_tail_gain_mul <= shifted_lane_product(d_lane_rsp_product, 16);
						D_OP_MAIN_VCA: d_main_vca_mul <= shifted_lane_product(d_lane_rsp_product, 16);
						D_OP_TAIL_VCA: d_tail_vca_mul <= shifted_lane_product(d_lane_rsp_product, 16);
						D_OP_MAIN_IC33: d_main_ic33_mul <= shifted_lane_product(d_lane_rsp_product, 20);
						D_OP_TAIL_IC33: d_tail_ic33_mul <= shifted_lane_product(d_lane_rsp_product, 20);
						default: begin end
					endcase
					if (d_op == D_OP_TAIL_IC33) begin
						d_result_ready <= 1'b1; dbg_scheduler_cycles_last <= d_cycle_counter + 1'b1;
						if ((d_cycle_counter + 1'b1) > dbg_scheduler_cycles_max) dbg_scheduler_cycles_max <= d_cycle_counter + 1'b1;
						d_state <= D_READY;
					end else begin
						d_op <= d_op_t'(d_op + 1'b1); d_state <= D_REQ;
					end
				end
			end
		end
	end

	always_ff @(posedge clk) begin
		if (rst_n) begin
			assert (!(d_lane_rsp_valid && (d_state != D_WAIT))) else $error("D-4 response with no pending request");
			if (d_lane_rsp_valid) assert (d_lane_rsp_tag == d_op) else $error("D-4 response tag/order mismatch");
			if (d_lane_req_valid && d_lane_req_ready) begin
				assert (signed_ext_ok(d_lane_req_a, d_lane_req_a_width)) else $error("D-4 A sign extension");
				assert (signed_ext_ok(d_lane_req_b, d_lane_req_b_width)) else $error("D-4 B sign extension");
			end
			if (sample_ce) assert (d_state == D_READY && d_result_ready) else $error("D-4 not complete at sample_ce");
			if (d_state == D_READY) assert (d_result_ready) else $error("D-4 READY without result");
		end else begin
			assert (d_state == D_IDLE && !d_result_ready) else $error("D-4 reset did not return idle");
		end
	end
endmodule
