// HIT channel, sheet 2 (same shape as exp_chan.sv).
//
//   /HIT -> IC13 sec.1 74123 (tw=99.4ms) -- Q -----------------------+
//                                                                     v
//   hit envelope (Q-bar of IC13 sec.1, discharge/recharge through C48) ->
//     control voltage (5+Vc)/2 -> MC3340 VCA gain LUT (direct, no invert)
//
//   noise_b -> 2-pole lowpass f0=3215Hz, Q=2.0, gain=2.5 (IC20 sec.1) ->
//              atten 0.232558 -> x VCA gain -> gain -6.8 -->
//   IC24 -> C13 -> HIT DIS0-2 3x4066 gain/lowpass select network ->
//   IC28 inverting stage -> HIT MIX
//
// The 74123 timing resistor has no designator or value on sheet 2. It is taken
// as 47K by inference: every other one-shot on this board (ALARM0-2 R2/R3/R14,
// ALARM3 R15, FIRE R7, EXP R16/R17, REBOUND R47 -- the other section of this
// same package) uses 47K and sets its width with the capacitor. It is not R92
// (4.7 ohm Zobel resistor on the LA4460 outputs) nor R97 (EXP rumble filter).
// Only WIDTH_CYCLES depends on this; the envelope shape and levels are set by
// C48/R91/R90/R96.
module hit_chan (
	input  logic               clk,
	input  logic               rst_n,
	input  logic               sample_ce,
	input  logic                hit_n,        // /HIT, active low, falling edge triggers
	input  logic         [2:0] hit_dis,       // HIT DIS0..2, active high, from IC2 4175B
	input  logic signed [15:0] noise_b,       // 4096 LSB = 1V
	output logic signed [15:0] hit_mix,       // 4096 LSB = 1V

	// Dedicated shared-multiplier client. The complete sample snapshot is
	// evaluated after upstream noise settles, then committed at sample_ce.
	output logic                mul_req_valid,
	input  logic                mul_req_ready,
	output logic signed [63:0]  mul_req_a,
	output logic signed [63:0]  mul_req_b,
	output logic          [6:0] mul_req_a_width,
	output logic          [6:0] mul_req_b_width,
	output logic          [7:0] mul_req_tag,
	input  logic                mul_rsp_valid,
	input  logic signed [127:0] mul_rsp_product,
	input  logic          [7:0] mul_rsp_tag
);

	// ---------------------------------------------------------------
	// Fixed-point conventions (as exp_chan.sv / fire_chan.sv):
	//   envelope / filter state: signed [26:0], SCALE = 4096*256 = 1,048,576
	//   LSB/V (shared by the envelope cap and the V2 control-voltage LUT index).
	//   fs = clk_sys/832 = 39,935,064/832 = 47,998.875 Hz.
	//
	// Every operand feeding a multiply is 27 bits: Cyclone V DSP blocks are
	// natively 27x27, while a 32-bit operand needs two blocks and defeats
	// packing the output register. Q24 coefficients top out at 33,237,369
	// (EXP's RUMBLE_A1_Q24, 26 bits signed); filter states (rails -6.00/+4.50 V
	// * 1,048,576 LSB/V < 2^23) need ~24 bits. VCA gain values (max 292,739)
	// use a narrower signed [20:0]. All fs-derived constants are precomputed
	// because Quartus rejects real-valued elaboration arithmetic.
	// ---------------------------------------------------------------

	// ---------------------------------------------------------------
	// Stage 1: IC13 sec.1 74123 one-shot.
	//   tw = 0.45 * Rtiming(47K, inferred -- see header) * C42(4.7uF) = 99.4ms
	//     WIDTH_CYCLES = 0.0994 * 39,935,064 = 3,969,745.36 -> 3,969,745
	// ---------------------------------------------------------------
	logic q_hit;

	ttl_74123 #(.WIDTH_CYCLES(3969745)) u_74123 (
		.clk    (clk),
		.rst_n  (rst_n),
		.a_n    (hit_n),
		.q      (q_hit)
	);

	// ---------------------------------------------------------------
	// Stage 2: envelope on C48 0.68uF. D3's cathode faces the 74123 (as EXP's
	// D6/D7, opposite to FIRE's D8): the cap sits charged toward 5V while idle
	// (Q-bar high, diode blocks); the pulse pulls Q-bar low and the diode
	// conducts, discharging the cap toward ~0.8V; it recovers toward 5V once
	// the pulse ends. Modelled as in exp_chan: a one-pole toward one of two
	// targets, gated by the one-shot's Q (gated = discharging). Reset is the
	// idle state (cap at 5V, silent), not 0V.
	//
	// discharge (R91 470, tau=0.3196ms): A_DISCHARGE_Q16 = 61400
	//   realised tau 0.319587ms (-0.0040%)
	// recharge (R90+R96 2M, tau=1.36s): too close to unity for Q0.16, so Q0.24:
	//   A_RECHARGE_Q24 = 16776959, realised tau 1.36004s (+0.0031%)
	// ---------------------------------------------------------------
	localparam signed [26:0] VLOW_SCALED  = 27'sd838861;   // 0.8V * SCALE
	localparam signed [26:0] VHIGH_SCALED = 27'sd5242880;  // 5.0V * SCALE

	localparam signed [26:0] A_DISCHARGE_Q16 = 27'sd61400;
	localparam signed [26:0] B_DISCHARGE_Q16 = 27'sd4136;   // 65536 - A

	localparam signed [26:0] A_RECHARGE_Q24 = 27'sd16776959;
	localparam signed [26:0] B_RECHARGE_Q24 = 27'sd257;     // 16777216 - A

	logic signed [26:0] env_hit;

	// ---------------------------------------------------------------
	// Stage 3: MC3340 VCA gain LUT, identical to exp_chan.sv (65 points,
	// V2 = 2.0..6.0V step 0.0625V).
	// ---------------------------------------------------------------
	localparam int LUT_SIZE = 65;
	localparam logic [31:0] VCA_GAIN_LUT [0:LUT_SIZE-1] = '{
		32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739,
		32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739,
		32'd292739, 32'd292739, 32'd253501, 32'd176901, 32'd123447, 32'd86145,  32'd60115,  32'd41950,
		32'd29274,  32'd21952,  32'd16462,  32'd12345,  32'd9257,   32'd6942,   32'd5206,   32'd3904,
		32'd2927,   32'd2195,   32'd1646,   32'd1234,   32'd926,    32'd694,    32'd521,    32'd390,
		32'd293,    32'd220,    32'd165,    32'd123,    32'd93,     32'd69,     32'd52,     32'd39,
		32'd29,     32'd25,     32'd22,     32'd19,     32'd16,     32'd14,     32'd12,     32'd11,
		32'd9,      32'd9,      32'd9,      32'd9,      32'd9,      32'd9,      32'd9,      32'd9,
		32'd9
	};

	localparam signed [26:0] V2_MIN_SCALED = 27'sd2097152;      // 2.0V * SCALE
	localparam signed [26:0] V2_MAX_SCALED = 27'sd6291455;      // 6.0V * SCALE - 1

	// Gain values top out at 292,739 (19 bits unsigned); signed [20:0] holds
	// them.
	function automatic logic signed [20:0] vca_lut_lookup(input logic signed [26:0] v2_in);
		logic signed [26:0] v2_clamped;
		logic        [26:0] v2_off;
		logic        [6:0]  lut_idx;
		logic        [15:0] lut_frac;
		logic        [31:0] gain_lo, gain_hi;
		logic signed [63:0] gain_interp_prod;
		begin
			v2_clamped = (v2_in < V2_MIN_SCALED) ? V2_MIN_SCALED :
						 (v2_in > V2_MAX_SCALED) ? V2_MAX_SCALED :
						 v2_in;
			v2_off   = v2_clamped - V2_MIN_SCALED;
			lut_idx  = v2_off[22:16];
			lut_frac = v2_off[15:0];
			gain_lo  = VCA_GAIN_LUT[lut_idx];
			gain_hi  = VCA_GAIN_LUT[lut_idx + 7'd1];
			gain_interp_prod = ($signed({1'b0, gain_hi}) - $signed({1'b0, gain_lo})) * $signed({1'b0, lut_frac});
			vca_lut_lookup = 21'($signed({1'b0, gain_lo}) + gain_interp_prod[47:16]);
		end
	endfunction


	// Transaction chain: each product is exact at its Q point; the added
	// latency stays within the 832-clock sample window.
	localparam signed [26:0] HIT_B0_Q24 = 27'sd1660616;
	localparam signed [26:0] HIT_B1_Q24 = 27'sd3321232;
	localparam signed [26:0] HIT_B2_Q24 = 27'sd1660616;
	localparam signed [26:0] HIT_A1_Q24 = -27'sd27787755;
	localparam signed [26:0] HIT_A2_Q24 = 27'sd13667524;
	localparam signed [26:0] ATTEN_Q16 = 27'sd15241;
	localparam signed [26:0] OUT_GAIN_Q16 = -27'sd445645;
	localparam signed [31:0] RAIL_HI = 32'sd18432;
	localparam signed [31:0] RAIL_LO = -32'sd24576;
	localparam logic [7:0] TAG_HIT_BASE = 8'hC0;

	wire signed [31:0] hit_noise_ext = {{16{noise_b[15]}}, noise_b};
	wire signed [26:0] hit_noise_scaled = 27'(hit_noise_ext <<< 8);

	function automatic logic [58:0] hit_vca_params(input logic signed [26:0] v2_in);
		logic signed [26:0] v2_clamped;
		logic [26:0] v2_off;
		logic [6:0] lut_idx;
		logic [15:0] lut_frac;
		logic [31:0] gain_lo, gain_hi;
		logic signed [20:0] gain_base, gain_delta;
		begin
			v2_clamped = (v2_in < V2_MIN_SCALED) ? V2_MIN_SCALED :
						 (v2_in > V2_MAX_SCALED) ? V2_MAX_SCALED : v2_in;
			v2_off = v2_clamped - V2_MIN_SCALED;
			lut_idx = v2_off[22:16];
			lut_frac = v2_off[15:0];
			gain_lo = VCA_GAIN_LUT[lut_idx]; gain_hi = VCA_GAIN_LUT[lut_idx + 7'd1];
			gain_base = 21'($signed({1'b0, gain_lo}));
			gain_delta = 21'($signed({1'b0, gain_hi}) - $signed({1'b0, gain_lo}));
			hit_vca_params = {gain_base, gain_delta, 1'b0, lut_frac};
		end
	endfunction

	logic signed [26:0] hit_x1, hit_x2, hit_y1, hit_y2, dis_y;
	logic [3:0] op_index;
	logic waiting_response, next_valid;
	logic [6:0] settle_count;
	logic [9:0] sample_age;
	logic late_dis_pending;
	logic signed [53:0] b0_w, b1_w, b2_w, a1_w;
	logic signed [26:0] hit_y_work, atten_work, vca_work, dis_y_work;
	logic signed [53:0] env_dis_a, env_rec_a;
	logic signed [26:0] env_dis_work, env_rec_work;
	logic signed [15:0] hit_sample;
	logic signed [20:0] gain_base_work, gain_delta_work;
	logic signed [16:0] gain_frac_work;

	wire signed [26:0] hit_v2_scaled = (VHIGH_SCALED + env_hit) >>> 1;
	wire [58:0] hit_vca_p = hit_vca_params(hit_v2_scaled);
	wire signed [53:0] rsp_q54 = 54'(mul_rsp_product);
	wire signed [26:0] rsp_q16 = 27'(mul_rsp_product >>> 16);
	wire signed [26:0] rsp_q24 = 27'(mul_rsp_product >>> 24);

	function automatic logic signed [26:0] dis_gain(input logic [2:0] sel);
		case (sel)
			3'b000: dis_gain = 27'sd0;
			3'b001: dis_gain = 27'sd21845;
			3'b010: dis_gain = 27'sd45511;
			3'b011: dis_gain = 27'sd48165;
			3'b100: dis_gain = 27'sd54613;
			3'b101: dis_gain = 27'sd55454;
			3'b110: dis_gain = 27'sd57614;
			default: dis_gain = 27'sd58066;
		endcase
	endfunction
	function automatic logic signed [26:0] dis_one_minus_a(input logic [2:0] sel);
		case (sel)
			3'b000: dis_one_minus_a = 27'sd16777216;
			3'b001: dis_one_minus_a = 27'sd1016503;
			3'b010: dis_one_minus_a = 27'sd2138717;
			3'b011: dis_one_minus_a = 27'sd2440538;
			3'b100: dis_one_minus_a = 27'sd3711184;
			3'b101: dis_one_minus_a = 27'sd3980583;
			3'b110: dis_one_minus_a = 27'sd4891745;
			default: dis_one_minus_a = 27'sd5136803;
		endcase
	endfunction

	task automatic issue_multiply(input logic signed [63:0] a, input logic signed [63:0] b,
								  input logic [6:0] aw, input logic [6:0] bw, input logic [7:0] tag);
		begin
			mul_req_a <= a; mul_req_b <= b; mul_req_a_width <= aw; mul_req_b_width <= bw;
			mul_req_tag <= tag; mul_req_valid <= 1'b1;
		end
	endtask

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			env_hit <= VHIGH_SCALED; hit_x1 <= '0; hit_x2 <= '0; hit_y1 <= '0; hit_y2 <= '0; dis_y <= '0;
			op_index <= '0; waiting_response <= 1'b0; next_valid <= 1'b0; settle_count <= '0;
			sample_age <= '0; late_dis_pending <= 1'b0;
			hit_mix <= '0; hit_sample <= '0; b0_w <= '0; b1_w <= '0; b2_w <= '0; a1_w <= '0;
			hit_y_work <= '0; atten_work <= '0; vca_work <= '0; dis_y_work <= '0;
			env_dis_a <= '0; env_rec_a <= '0; env_dis_work <= '0; env_rec_work <= '0;
			gain_base_work <= '0; gain_delta_work <= '0; gain_frac_work <= '0;
			mul_req_valid <= 1'b0; mul_req_a <= '0; mul_req_b <= '0; mul_req_a_width <= 7'd1; mul_req_b_width <= 7'd1; mul_req_tag <= '0;
		end else begin
			hit_mix <= hit_sample;
			if (mul_req_valid && mul_req_ready) begin mul_req_valid <= 1'b0; waiting_response <= 1'b1; end
			if (sample_ce) begin
				settle_count <= 7'd64;
				sample_age <= '0;
				if (next_valid) begin
					env_hit <= q_hit ? env_dis_work : env_rec_work;
					hit_x1 <= hit_noise_scaled; hit_x2 <= hit_x1; hit_y1 <= hit_y_work; hit_y2 <= hit_y1; dis_y <= dis_y_work;
					next_valid <= 1'b0;
				end
			end else begin
				sample_age <= sample_age + 1'b1;
				if (settle_count != 0) settle_count <= settle_count - 1'b1;
			end
			if (!mul_req_valid && !waiting_response && settle_count == 7'd1) begin
				op_index <= 4'd0;
				gain_base_work <= hit_vca_p[58:38]; gain_delta_work <= hit_vca_p[37:17]; gain_frac_work <= hit_vca_p[16:0];
				issue_multiply(64'(HIT_B0_Q24), 64'(hit_noise_scaled), 7'd27, 7'd27, TAG_HIT_BASE);
			end
			if (mul_rsp_valid && waiting_response) begin
				waiting_response <= 1'b0;
				case (op_index)
					4'd0: begin b0_w <= rsp_q54; op_index <= 4'd1; issue_multiply(64'(HIT_B1_Q24),64'(hit_x1),7'd27,7'd27,TAG_HIT_BASE+8'd1); end
					4'd1: begin b1_w <= rsp_q54; op_index <= 4'd2; issue_multiply(64'(HIT_B2_Q24),64'(hit_x2),7'd27,7'd27,TAG_HIT_BASE+8'd2); end
					4'd2: begin b2_w <= rsp_q54; op_index <= 4'd3; issue_multiply(64'(HIT_A1_Q24),64'(hit_y1),7'd27,7'd27,TAG_HIT_BASE+8'd3); end
					4'd3: begin a1_w <= rsp_q54; op_index <= 4'd4; issue_multiply(64'(HIT_A2_Q24),64'(hit_y2),7'd27,7'd27,TAG_HIT_BASE+8'd4); end
					4'd4: begin hit_y_work <= 27'((b0_w+b1_w+b2_w-a1_w-rsp_q54)>>>24); op_index <= 4'd5; issue_multiply(64'(ATTEN_Q16),64'((b0_w+b1_w+b2_w-a1_w-rsp_q54)>>>24),7'd27,7'd27,TAG_HIT_BASE+8'd5); end
					4'd5: begin atten_work <= rsp_q16; op_index <= 4'd6; issue_multiply(64'(gain_delta_work),64'(gain_frac_work),7'd21,7'd17,TAG_HIT_BASE+8'd6); end
					4'd6: begin op_index <= 4'd7; issue_multiply(64'(atten_work),64'(gain_base_work + 21'(mul_rsp_product >>> 16)),7'd27,7'd21,TAG_HIT_BASE+8'd7); end
					4'd7: begin vca_work <= rsp_q16; op_index <= 4'd8; issue_multiply(64'(A_DISCHARGE_Q16),64'(env_hit),7'd27,7'd27,TAG_HIT_BASE+8'd8); end
					4'd8: begin env_dis_a <= rsp_q54; op_index <= 4'd9; issue_multiply(64'(B_DISCHARGE_Q16),64'(VLOW_SCALED),7'd27,7'd27,TAG_HIT_BASE+8'd9); end
					4'd9: begin env_dis_work <= 27'((env_dis_a+rsp_q54)>>>16); op_index <= 4'd10; issue_multiply(64'(A_RECHARGE_Q24),64'(env_hit),7'd27,7'd27,TAG_HIT_BASE+8'd10); end
					4'd10: begin env_rec_a <= rsp_q54; op_index <= 4'd11; issue_multiply(64'(B_RECHARGE_Q24),64'(VHIGH_SCALED),7'd27,7'd27,TAG_HIT_BASE+8'd11); end
					4'd11: begin env_rec_work <= 27'((env_rec_a+rsp_q54)>>>24); late_dis_pending <= 1'b1; end
					4'd12: begin op_index <= 4'd13; issue_multiply(64'(dis_one_minus_a(hit_dis)),64'(rsp_q16-dis_y),7'd27,7'd27,TAG_HIT_BASE+8'd13); end
					4'd13: begin dis_y_work <= dis_y + rsp_q24; op_index <= 4'd14; issue_multiply(64'(OUT_GAIN_Q16),64'(dis_y + rsp_q24),7'd27,7'd27,TAG_HIT_BASE+8'd14); end
					default: begin hit_sample <= ((rsp_q16 >>> 8) > RAIL_HI) ? RAIL_HI[15:0] : ((rsp_q16 >>> 8) < RAIL_LO) ? RAIL_LO[15:0] : 16'(rsp_q16 >>> 8); next_valid <= 1'b1; end
				endcase
			end
				// IC2 can be strobed late in the audio period, so this dependent
				// DIS tail is issued near the end of the window rather than
				// snapshotting hit_dis early.
			if (late_dis_pending && !mul_req_valid && !waiting_response && sample_age == 10'd780) begin
				late_dis_pending <= 1'b0;
				op_index <= 4'd12;
				issue_multiply(64'(dis_gain(hit_dis)),64'(vca_work),7'd27,7'd27,TAG_HIT_BASE+8'd12);
			end
		end
	end

`ifdef VERILATOR_SIM
	always_ff @(posedge clk) begin
		if (rst_n && mul_rsp_valid && waiting_response && (mul_rsp_tag != TAG_HIT_BASE + op_index)) $error("HIT shared-multiply tag mismatch");
		if (rst_n && sample_ce && (mul_req_valid || waiting_response)) $error("HIT shared multiply missed sample deadline");
	end
`endif

endmodule
