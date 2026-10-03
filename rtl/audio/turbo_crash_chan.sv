// Turbo CRASH audio (sheet D-4/11): CRASH.S and CRASH.L from the shared S2688 noise (IC8, D-3/11).
//
// Schematic signal paths (IC2 and IC10 are quad op-amps; pin numbers select the section):
//   noise -> C23/R44 -> IC2 pins 1-3 inverting stage (R45/R44 = 51K/150K, gain -0.34)
//   CRASH.S: C11/R47 -> IC2 pins 5-7 second-order low-pass (R46, R47, C12) -> R272 33K
//            -> IC36 (4391/2 VCA) -> VR4. IC36's control is the R8/R9/C2 node buffered
//            by IC2 pins 8-10; IC54 (74123) drives that node through D2/R10.
//   CRASH.L: main = C27/R96/R97 + IC10 pins 8-10 (R98, C29, C36) -> R222 33K -> IC29 upper VCA
//            (control: R91/R92/C24 node buffered by IC2 pins 12-14, driven by IC55's first half)
//            tail = C28/R95/R94 + IC10 pins 12-14 (R93, C25, C26) -> R221 33K -> IC29 lower VCA
//            (control: IC55's second half, triggered when the first ends, charging C43 into
//            IC10 pins 5-7 and 1-3)
//            both VCA outputs -> R223/R224 -> IC33 summer (R226 680K) -> VR3.
//
// Modelled here: the IC2 pins 1-3 stage, the CRASH.S noise path and its envelope, and the
// CRASH.L control envelopes. The CRASH.S filter is a one-pole approximation of the
// second-order IC2 pins 5-7 stage (not derived from the schematic). CRASH.L filtering, VCAs
// and the IC33 sum live in turbo_crash_d4_model.sv; IC10 pin 8 and pin 14 are physical
// output taps from that model, and no intermediate mathematical state is rail limited here.
//
// The source amplitude is the S2688 assumption documented in turbo_s2688_noise.sv. The
// +/-4.5 V centred limit is an assumed symmetric op-amp output limit (the sheet shows a
// single 0/12 V supply, so real limits are asymmetric). IC29_ZIN_OHMS = 10K is the effective
// MB4391 input loading behind the 33K series resistors: an assumption, not schematic- or
// datasheet-derived. Zero is the high-Z/unity coupling limit; 20K/50K/100K are sensitivity cases.
module turbo_crash_chan #(
	parameter int IC29_ZIN_OHMS = 10000
) (
	input  logic clk,
	input  logic rst_n,
	input  logic crash_s_n,
	input  logic crash_l_n,
	input  logic sample_ce,
	input  logic signed [15:0] noise_in,
	output logic signed [15:0] turbo_crash_s_mix,
	output logic signed [15:0] turbo_crash_l_mix,
	output logic dbg_q_crash_s,
	output logic dbg_q_crash_l_main,
	output logic dbg_q_crash_l_tail,
	output logic signed [15:0] dbg_preamp_out,
	output logic signed [15:0] dbg_main_shaped_noise,
	output logic signed [15:0] dbg_tail_shaped_noise,
	output logic signed [31:0] dbg_main_shaped_raw,
	output logic signed [31:0] dbg_tail_shaped_raw,
	output logic signed [15:0] dbg_main_control,
	output logic signed [15:0] dbg_tail_c43,
	output logic signed [15:0] dbg_tail_control,
	output logic signed [15:0] dbg_main_vca_out,
	output logic signed [15:0] dbg_tail_vca_out,
	output logic signed [15:0] dbg_ic33_sum,
	output logic [31:0] dbg_preamp_clip_count,
	output logic [31:0] dbg_main_clip_count,
	output logic [31:0] dbg_tail_clip_count,
	output logic [31:0] dbg_main_vca_clip_count,
	output logic [31:0] dbg_tail_vca_clip_count,
	output logic [31:0] dbg_ic33_clip_count,
	output logic signed [63:0] dbg_preamp_lp_state,
	output logic signed [63:0] dbg_preamp_lp_next,
	output logic signed [63:0] dbg_preamp_raw_q12,
	output logic signed [15:0] dbg_d4_source_sample,
	output logic [15:0] dbg_preamp_scheduler_cycles_last,
	output logic [15:0] dbg_preamp_scheduler_cycles_max
);

	localparam logic signed [63:0] Q20_ONE = 64'sd1048576;
	localparam logic signed [63:0] RAIL_Q12 = 64'sd18432;
	localparam logic signed [63:0] V5_SCALED_Q20 = 64'sd5242880;
	localparam logic signed [63:0] V6_SCALED_Q20 = 64'sd6291456;
	localparam logic signed [63:0] VREF_TAIL_Q20 = 64'sd4055649;
	localparam logic signed [63:0] PRE_HP_A_Q20 = 64'sd1048430;
	localparam logic signed [63:0] PRE_GAIN_Q20 = -64'sd356516;
	// Exact accepted LP coefficient: Q20_ONE - PRE_HP_A_Q20 = 146; 9 bits suffice.
	localparam logic signed [8:0] PRE_HP_DELTA_Q20 = 9'sd146;
	localparam logic signed [63:0] VLOW_SCALED_S = 64'sd838861;
	localparam logic signed [63:0] VHIGH_SCALED_S = 64'sd5242880;

	function automatic logic signed [47:0] sat_rail_q12(input logic signed [63:0] value);
		begin
			if (value > RAIL_Q12)
				sat_rail_q12 = 48'sd18432;
			else if (value < -RAIL_Q12)
				sat_rail_q12 = -48'sd18432;
			else
				sat_rail_q12 = value[47:0];
		end
	endfunction

	function automatic logic signed [15:0] sat_pcm16(input logic signed [63:0] value);
		begin
			if (value > 64'sd32767)
				sat_pcm16 = 16'sd32767;
			else if (value < -64'sd32768)
				sat_pcm16 = 16'sh8000;
			else
				sat_pcm16 = value[15:0];
		end
	endfunction

	function automatic logic signed [63:0] preamp_shift_q20(
		input logic signed [127:0] product
	);
		logic signed [127:0] shifted;
		begin
			shifted = product >>> 20;
			preamp_shift_q20 = shifted[63:0];
		end
	endfunction

	function automatic logic preamp_signed_ext_ok(
		input logic signed [63:0] value,
		input logic [6:0] width
	);
		integer i;
		begin
			preamp_signed_ext_ok = (width >= 1) && (width <= 64);
			if (preamp_signed_ext_ok)
				for (i = 0; i < 64; i = i + 1)
					if ((i >= width) && (value[i] != value[width - 1]))
						preamp_signed_ext_ok = 1'b0;
		end
	endfunction

	// MC3340 gain LUT (65 points, V2 = 2.0..6.0 V in 0.0625 V steps, linear interpolation).
	function automatic logic signed [20:0] crash_vca_gain(input logic signed [63:0] v2_q20);
		localparam int LUT_SIZE = 65;
		localparam logic [31:0] VCA_GAIN_LUT [0:LUT_SIZE-1] = '{
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
		logic signed [63:0] clamped, offset;
		logic [6:0] index;
		logic signed [16:0] fraction;
		logic signed [32:0] low, high, delta;
		logic signed [50:0] interpolation;
		begin
			clamped = (v2_q20 < 64'sd2097152) ? 64'sd2097152 :
					  (v2_q20 > V6_SCALED_Q20) ? V6_SCALED_Q20 : v2_q20;
			offset = clamped - 64'sd2097152;
			index = offset[22:16];
			if (index >= 7'd64)
				index = 7'd63;
			fraction = $signed({1'b0, offset[15:0]});
			low = $signed({1'b0, VCA_GAIN_LUT[index]});
			high = $signed({1'b0, VCA_GAIN_LUT[index + 1'b1]});
			delta = high - low;
			interpolation = delta * fraction;
			crash_vca_gain = 21'($signed(low) + $signed(interpolation >>> 16));
		end
	endfunction

	logic q_crash_s, q_crash_l_main, q_crash_l_tail;
	ttl_74123 #(.WIDTH_CYCLES(2044675)) u_74123_crash_s (
		.clk(clk), .rst_n(rst_n), .a_n(crash_s_n), .q(q_crash_s));
	ttl_74123 #(.WIDTH_CYCLES(2911266)) u_74123_crash_l_main (
		.clk(clk), .rst_n(rst_n), .a_n(crash_l_n), .q(q_crash_l_main));
	ttl_74123 #(.WIDTH_CYCLES(2911266)) u_74123_crash_l_tail (
		.clk(clk), .rst_n(rst_n), .a_n(q_crash_l_main), .q(q_crash_l_tail));

	assign dbg_q_crash_s = q_crash_s;
	assign dbg_q_crash_l_main = q_crash_l_main;
	assign dbg_q_crash_l_tail = q_crash_l_tail;

	// CRASH.S: one-pole noise filter into the VCA, with a (5+Vcap)/2 control divider.
	logic signed [17:0] crash_s_noise_filter;
	logic signed [63:0] env_s;
	logic signed [20:0] gain_s_q16;
	wire signed [17:0] crash_s_noise_diff =
		{{2{noise_in[15]}}, noise_in} - crash_s_noise_filter;
	wire signed [63:0] env_s_dis_next =
		(64'sd62701 * env_s + 64'sd2835 * VLOW_SCALED_S) >>> 16;
	wire signed [63:0] env_s_rec_next =
		(64'sd16776844 * env_s + 64'sd372 * VHIGH_SCALED_S) >>> 24;
	wire signed [63:0] env_s_next = q_crash_s ? env_s_dis_next : env_s_rec_next;
	wire signed [63:0] v2_s_scaled = (VHIGH_SCALED_S + env_s) >>> 1;
	wire signed [63:0] crash_s_product_q12 =
		($signed({{46{crash_s_noise_filter[17]}}, crash_s_noise_filter}) *
		 $signed({{43{gain_s_q16[20]}}, gain_s_q16})) >>> 16;
	wire signed [47:0] crash_s_sat_q12 = sat_rail_q12(-(crash_s_product_q12 >>> 2));

	// Shared IC2 section 2/3/1 common preamp. The two products (low-pass update and gain)
	// are scheduled through a private multiplier lane so the S2688 register-to-register
	// path never reaches D-4 within one clk_sys period.
	logic signed [63:0] preamp_lp_q12;
	wire signed [63:0] noise_q12 = {{48{noise_in[15]}}, noise_in};

	typedef enum logic {P_OP_LP, P_OP_RAW} preamp_op_t;
	typedef enum logic [1:0] {P_IDLE, P_REQ, P_WAIT, P_READY} preamp_state_t;
	preamp_op_t preamp_op;
	preamp_state_t preamp_state;
	logic preamp_reset_seen;
	logic [15:0] preamp_cycle_counter;
	logic signed [63:0] preamp_noise_txn, preamp_lp_txn;
	logic signed [63:0] preamp_lp_next_txn;
	logic signed [63:0] preamp_lp_next_reg, preamp_raw_q12_reg;
	logic signed [15:0] preamp_pcm_reg;

	wire signed [63:0] preamp_diff_lp_wide = preamp_noise_txn - preamp_lp_txn;
	wire signed [63:0] preamp_diff_raw_wide = preamp_noise_txn - preamp_lp_next_txn;
	wire signed [16:0] preamp_diff_lp = preamp_diff_lp_wide[16:0];
	wire signed [16:0] preamp_diff_raw = preamp_diff_raw_wide[16:0];

	logic preamp_lane_req_valid, preamp_lane_req_ready;
	logic signed [63:0] preamp_lane_req_a, preamp_lane_req_b;
	logic [6:0] preamp_lane_req_a_width, preamp_lane_req_b_width;
	logic [7:0] preamp_lane_req_tag;
	logic preamp_lane_rsp_valid;
	logic signed [127:0] preamp_lane_rsp_product;
	logic [7:0] preamp_lane_rsp_tag;

	always_comb begin
		preamp_lane_req_a = 64'sd0;
		preamp_lane_req_b = 64'sd0;
		preamp_lane_req_a_width = 7'd17;
		preamp_lane_req_b_width = (preamp_op == P_OP_LP) ? 7'd9 : 7'd20;
		preamp_lane_req_tag = {7'd0, preamp_op};
		if (preamp_op == P_OP_LP) begin
			preamp_lane_req_a = {{47{preamp_diff_lp[16]}}, preamp_diff_lp};
			preamp_lane_req_b = {{55{PRE_HP_DELTA_Q20[8]}}, PRE_HP_DELTA_Q20};
		end else begin
			preamp_lane_req_a = {{47{preamp_diff_raw[16]}}, preamp_diff_raw};
			preamp_lane_req_b = {{44{PRE_GAIN_Q20[19]}}, PRE_GAIN_Q20[19:0]};
		end
	end

	assign preamp_lane_req_valid = (preamp_state == P_REQ);
	wire signed [63:0] preamp_rsp_q12 =
		preamp_shift_q20(preamp_lane_rsp_product);
	wire preamp_ready = (preamp_state == P_READY);

	shared_mul_lane u_preamp_shared_mul_lane (
		.clk(clk),
		.rst_n(rst_n),
		.req_valid(preamp_lane_req_valid),
		.req_ready(preamp_lane_req_ready),
		.req_a(preamp_lane_req_a),
		.req_b(preamp_lane_req_b),
		.req_a_width(preamp_lane_req_a_width),
		.req_b_width(preamp_lane_req_b_width),
		.req_tag(preamp_lane_req_tag),
		.rsp_valid(preamp_lane_rsp_valid),
		.rsp_product(preamp_lane_rsp_product),
		.rsp_tag(preamp_lane_rsp_tag)
	);

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			preamp_state <= P_IDLE;
			preamp_op <= P_OP_LP;
			preamp_reset_seen <= 1'b1;
			preamp_cycle_counter <= 16'd0;
			preamp_noise_txn <= '0;
			preamp_lp_txn <= '0;
			preamp_lp_next_txn <= '0;
			preamp_lp_next_reg <= '0;
			preamp_raw_q12_reg <= '0;
			preamp_pcm_reg <= '0;
			dbg_preamp_scheduler_cycles_last <= 16'd0;
			dbg_preamp_scheduler_cycles_max <= 16'd0;
		end else begin
			if (preamp_reset_seen)
				preamp_reset_seen <= 1'b0;
			if (preamp_state != P_IDLE && preamp_state != P_READY)
				preamp_cycle_counter <= preamp_cycle_counter + 1'b1;
			case (preamp_state)
				P_IDLE: begin
					if (!sample_ce) begin
						preamp_noise_txn <= noise_q12;
						preamp_lp_txn <= preamp_lp_q12;
						preamp_op <= P_OP_LP;
						preamp_cycle_counter <= 16'd0;
						preamp_state <= P_REQ;
					end
				end
				P_REQ: begin
					if (preamp_lane_req_ready)
						preamp_state <= P_WAIT;
				end
				P_WAIT: begin
					if (preamp_lane_rsp_valid) begin
						if (preamp_op == P_OP_LP) begin
							preamp_lp_next_txn <= preamp_lp_txn + preamp_rsp_q12;
							preamp_op <= P_OP_RAW;
							preamp_state <= P_REQ;
						end else begin
							preamp_lp_next_reg <= preamp_lp_next_txn;
							preamp_raw_q12_reg <= preamp_rsp_q12;
							preamp_pcm_reg <= sat_pcm16(sat_rail_q12(preamp_rsp_q12));
							dbg_preamp_scheduler_cycles_last <= preamp_cycle_counter + 1'b1;
							if ((preamp_cycle_counter + 1'b1) >
								dbg_preamp_scheduler_cycles_max)
								dbg_preamp_scheduler_cycles_max <=
									preamp_cycle_counter + 1'b1;
							preamp_state <= P_READY;
						end
					end
				end
				P_READY: begin
					if (sample_ce)
						preamp_state <= P_IDLE;
				end
				default: preamp_state <= P_IDLE;
			endcase
		end
	end

	always_ff @(posedge clk) begin
		if (rst_n) begin
			assert (!(preamp_lane_rsp_valid && (preamp_state != P_WAIT))) else
				$error("preamp response with no pending request");
			if (preamp_lane_rsp_valid)
				assert (preamp_lane_rsp_tag == {7'd0, preamp_op}) else
					$error("preamp response tag/order mismatch");
			assert (!(preamp_state == P_WAIT && preamp_lane_req_valid)) else
				$error("preamp request overwritten while waiting");
			if (preamp_lane_req_valid && preamp_lane_req_ready) begin
				assert (preamp_signed_ext_ok(preamp_lane_req_a, 7'd17)) else
					$error("preamp A sign extension");
				assert (preamp_signed_ext_ok(preamp_lane_req_b,
											 preamp_lane_req_b_width)) else
					$error("preamp B sign extension");
			end
			if (preamp_state == P_REQ || preamp_state == P_WAIT) begin
				assert (preamp_noise_txn >= -64'sd19456 &&
						preamp_noise_txn <= 64'sd19456) else
					$error("preamp source outside S2688 meaningful range");
				assert (preamp_lp_txn >= -64'sd19456 &&
						preamp_lp_txn <= 64'sd19456) else
					$error("preamp LP state outside meaningful range");
				assert (preamp_diff_lp_wide >= -64'sd65536 &&
						preamp_diff_lp_wide <= 64'sd65535) else
					$error("preamp LP difference does not fit 17 bits");
				assert (preamp_diff_raw_wide >= -64'sd65536 &&
						preamp_diff_raw_wide <= 64'sd65535) else
					$error("preamp raw difference does not fit 17 bits");
			end
			if (sample_ce)
				assert (preamp_state == P_READY) else
					$error("preamp scheduler incomplete at sample_ce");
			if (preamp_reset_seen)
				assert (preamp_state == P_IDLE) else
					$error("preamp reset did not return to idle");
		end
	end

	// IC2 section 13/12/14 upper CO envelope proxy: CRASH.L main control path.
	logic signed [63:0] env_l;
	wire signed [63:0] env_l_dis_next =
		(64'sd64918 * env_l + 64'sd618 * VLOW_SCALED_S) >>> 16;
	wire signed [63:0] env_l_rec_next =
		(64'sd16777047 * env_l + 64'sd169 * VHIGH_SCALED_S) >>> 24;
	wire signed [63:0] env_l_next = q_crash_l_main ? env_l_dis_next : env_l_rec_next;
	wire signed [63:0] main_control_q20 = (V5_SCALED_Q20 + env_l) >>> 1;

	// IC10 section 2/3/1 lower CO path. VREF_TAIL is the unloaded divider value
	// 12V*3.9K/(8.2K+3.9K); the ideal lower relation is VC_lower = 2*3.8677686V - VC43.
	logic signed [63:0] tail_c43_q20;
	wire signed [63:0] tail_c43_charge_next = tail_c43_q20 +
		((V5_SCALED_Q20 - tail_c43_q20) * (Q20_ONE - 64'sd1038886) >>> 20);
	wire signed [63:0] tail_c43_decay_next = tail_c43_q20 -
		((tail_c43_q20 * (Q20_ONE - 64'sd1048573)) >>> 20);
	wire signed [63:0] tail_c43_next =
		q_crash_l_tail ? tail_c43_charge_next : tail_c43_decay_next;
	wire signed [63:0] tail_control_raw_q20 =
		(VREF_TAIL_Q20 <<< 1) - tail_c43_q20;
	wire signed [63:0] tail_control_q20 =
		(tail_control_raw_q20 < 64'sd0) ? 64'sd0 :
		(tail_control_raw_q20 > V6_SCALED_Q20) ? V6_SCALED_Q20 :
		tail_control_raw_q20;

	logic signed [20:0] gain_s_next;
	wire signed [31:0] child_main_pin8_raw, child_tail_pin14_raw;
	wire signed [15:0] child_main_pin8_rail, child_tail_pin14_rail;
	wire signed [15:0] child_main_vca_rail, child_tail_vca_rail;
	wire signed [63:0] child_main_vca_raw, child_tail_vca_raw;
	wire signed [63:0] child_ic33_raw;
	wire signed [15:0] child_ic33_rail;
	wire signed [15:0] child_d4_source;
	wire [31:0] child_main_pin_clip_count, child_tail_pin_clip_count;
	wire [31:0] child_main_vca_clip_count, child_tail_vca_clip_count;
	wire [31:0] child_ic33_clip_count;
	wire signed [15:0] child_main_input, child_tail_input;

	turbo_crash_d4_model #(.IC29_ZIN_OHMS(IC29_ZIN_OHMS)) u_d4 (
		.clk(clk),
		.rst_n(rst_n),
		.sample_ce(sample_ce),
		.source_ready(preamp_ready),
		.source_in(preamp_pcm_reg),
		.main_control_q20(main_control_q20),
		.tail_control_q20(tail_control_q20),
		.ic29_main_input(child_main_input),
		.ic29_tail_input(child_tail_input),
		.main_pin8_raw(child_main_pin8_raw),
		.tail_pin14_raw(child_tail_pin14_raw),
		.main_pin8_rail(child_main_pin8_rail),
		.tail_pin14_rail(child_tail_pin14_rail),
		.main_vca_raw(child_main_vca_raw),
		.tail_vca_raw(child_tail_vca_raw),
		.main_vca_rail(child_main_vca_rail),
		.tail_vca_rail(child_tail_vca_rail),
		.ic33_raw(child_ic33_raw),
		.ic33_rail(child_ic33_rail),
		.main_pin_clip_count(child_main_pin_clip_count),
		.tail_pin_clip_count(child_tail_pin_clip_count),
		.main_vca_clip_count(child_main_vca_clip_count),
		.tail_vca_clip_count(child_tail_vca_clip_count),
		.ic33_clip_count(child_ic33_clip_count),
		.dbg_main_hp_state(),
		.dbg_main_y_state(),
		.dbg_tail_hp_state(),
		.dbg_tail_y_state(),
		.dbg_scheduler_cycles_last(),
		.dbg_scheduler_cycles_max(),
		.dbg_source_txn(child_d4_source)
	);

	assign turbo_crash_s_mix = sat_pcm16(crash_s_sat_q12);
	assign turbo_crash_l_mix = child_ic33_rail;
	assign dbg_preamp_out = preamp_pcm_reg;
	assign dbg_preamp_lp_state = preamp_lp_q12;
	assign dbg_preamp_lp_next = preamp_lp_next_reg;
	assign dbg_preamp_raw_q12 = preamp_raw_q12_reg;
	assign dbg_d4_source_sample = child_d4_source;
	assign dbg_main_shaped_noise = child_main_pin8_rail;
	assign dbg_tail_shaped_noise = child_tail_pin14_rail;
	assign dbg_main_shaped_raw = child_main_pin8_raw;
	assign dbg_tail_shaped_raw = child_tail_pin14_raw;
	assign dbg_main_control = sat_pcm16(main_control_q20 >>> 8);
	assign dbg_tail_c43 = sat_pcm16(tail_c43_q20 >>> 8);
	assign dbg_tail_control = sat_pcm16(tail_control_q20 >>> 8);
	assign dbg_main_vca_out = child_main_vca_rail;
	assign dbg_tail_vca_out = child_tail_vca_rail;
	assign dbg_ic33_sum = child_ic33_rail;
	assign dbg_preamp_clip_count = preamp_clip_count;
	assign dbg_main_clip_count = child_main_pin_clip_count;
	assign dbg_tail_clip_count = child_tail_pin_clip_count;
	assign dbg_main_vca_clip_count = child_main_vca_clip_count;
	assign dbg_tail_vca_clip_count = child_tail_vca_clip_count;
	assign dbg_ic33_clip_count = child_ic33_clip_count;

	logic [31:0] preamp_clip_count;
	always_ff @(posedge clk) begin
		if (!rst_n) begin
			crash_s_noise_filter <= '0;
			env_s <= VHIGH_SCALED_S;
			gain_s_q16 <= 21'sd9;
			preamp_lp_q12 <= '0;
			env_l <= VHIGH_SCALED_S;
			tail_c43_q20 <= '0;
			preamp_clip_count <= '0;
		end else if (sample_ce) begin
			crash_s_noise_filter <= crash_s_noise_filter + (crash_s_noise_diff >>> 2);
			env_s <= env_s_next;
			gain_s_q16 <= crash_vca_gain(v2_s_scaled);
			preamp_lp_q12 <= preamp_lp_next_reg;
			env_l <= env_l_next;
			tail_c43_q20 <= tail_c43_next;
			if ((preamp_raw_q12_reg > RAIL_Q12) || (preamp_raw_q12_reg < -RAIL_Q12))
				preamp_clip_count <= preamp_clip_count + 1'b1;
		end
	end
endmodule