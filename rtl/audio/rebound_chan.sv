// REBOUND channel, sheet 2 (same shape as hit_chan.sv / exp_chan.sv).
//
//   /REBOUND -> IC13 sec.2 74123 (tw=21.15ms) -- Q --------------------+
//                                                                       v
//   rebound envelope (Q-bar of IC13 sec.2, discharge/recharge through C43) ->
//     control node V = 0.5875*Vc + 2.0625  (unequal divider, unlike EXP/HIT)
//     -> drives BOTH the 555 control voltage AND the VCA control (direct)
//
//   ctrl -> IC15B 555 astable, modelled via its C31 timing-cap voltage
//     (pin 3 unconnected; IC12 sec.2 follows the cap node directly) ->
//     bounce-rate oscillator, 24.6Hz -> 6.2Hz -> stops as ctrl -> 5V
//   C31 voltage -> Tr3 gate (R37/R36 base divider, piecewise-linear
//     conduction like fire_chan's Tr1) -> gates noise_a into node M
//
//   noise_a -> C41/R39 -> node M (C51/C40 midpoint, IC12's feedback net) ->
//     band-pass f0=320.3Hz, Q=1.129, peak gain 2.55 (IC12) ->
//     atten 0.751880 (R82/R83, inverse of EXP/HIT's ratio) ->
//     x VCA gain (ctrl node, direct) -> gain -3.30 (IC22) -> REBOUND MIX
//
// Tr3's collector shunts the same node (M) that noise_a is injected into, so
// physically the gate also detunes the band-pass (f0 and Q move as Tr3
// conducts). It is modelled as an input gate only, at fixed f0/Q, the same
// simplification fire_chan.sv makes for Tr1.
module rebound_chan (
	input  logic               clk,
	input  logic               rst_n,
	input  logic               sample_ce,
	input  logic                rebound_n,    // /REBOUND, active low, falling edge triggers
	input  logic signed [15:0] noise_a,       // 4096 LSB = 1V
	output logic signed [15:0] rebound_mix,   // 4096 LSB = 1V

	// Dedicated shared-multiplier client. Work is sequenced between sample
	// enables and commits as one snapshot on the following sample_ce.
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
	// Fixed-point conventions (as hit_chan.sv / exp_chan.sv):
	//   envelope / filter state: signed [31:0], SCALE = 4096*256 =
	//   1,048,576 LSB/V (shared by the envelope cap and the V2 control-voltage
	//   LUT index). fs = clk_sys/832 = 39,935,064/832 = 47,998.875 Hz.
	//   SCALE is folded into the localparam constants, and every fs-derived
	//   constant is precomputed (Quartus rejects real-valued elaboration
	//   arithmetic).
	// ---------------------------------------------------------------

	// ---------------------------------------------------------------
	// Stage 1: IC13 sec.2 74123 one-shot.
	//   tw = R47(47K) * C44(1uF) shape -> 21.15ms
	//     WIDTH_CYCLES = 0.02115 * 39,935,064 = 844,626.60 -> 844,627
	// ---------------------------------------------------------------
	logic q_reb;

	ttl_74123 #(.WIDTH_CYCLES(844627)) u_74123 (
		.clk    (clk),
		.rst_n  (rst_n),
		.a_n    (rebound_n),
		.q      (q_reb)
	);

	// ---------------------------------------------------------------
	// Stage 2: envelope on C43 2.2uF from Q-bar (pin 12). D2's cathode faces
	// IC13 (as HIT's D3): the cap sits charged toward 5V while idle (Q-bar
	// high, diode blocks), the pulse pulls Q-bar low and the diode conducts,
	// discharging the cap toward ~0.8V; it recovers toward 5V once the pulse
	// ends. Modelled as in hit_chan: a one-pole toward one of two targets,
	// gated by the one-shot's Q (gated = discharging). Reset is the idle state
	// (cap at 5V, silent), not 0V.
	//
	// discharge (R44 470, tau=1.0342ms): A_DISCHARGE_Q16 = 64229
	// recharge (R43+R42 800K, tau=1.7564s): too close to unity for Q0.16, so
	//   Q0.24: A_RECHARGE_Q24 = 16777017
	// ---------------------------------------------------------------
	localparam signed [31:0] VLOW_SCALED  = 32'sd838861;   // 0.8V * SCALE
	localparam signed [31:0] VHIGH_SCALED = 32'sd5242880;  // 5.0V * SCALE

	localparam signed [31:0] A_DISCHARGE_Q16 = 32'sd64229;
	localparam signed [31:0] B_DISCHARGE_Q16 = 32'sd1307;   // 65536 - A

	localparam signed [31:0] A_RECHARGE_Q24 = 32'sd16777017;
	localparam signed [31:0] B_RECHARGE_Q24 = 32'sd199;     // 16777216 - A

	// ---------------------------------------------------------------
	// MC3340 VCA gain LUT, identical to hit_chan.sv (65 points, V2 =
	// 2.0..6.0V step 0.0625V). Its input is the Stage-3 ctrl node directly (no
	// inversion), carried through the gate pipeline as g*_ctrl.
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

	localparam signed [31:0] V2_MIN_SCALED = 32'sd2097152;      // 2.0V * SCALE
	localparam signed [31:0] V2_MAX_SCALED = 32'sd6291455;      // 6.0V * SCALE - 1

	function automatic logic signed [31:0] vca_lut_lookup(input logic signed [31:0] v2_in);
		logic signed [31:0] v2_clamped;
		logic        [31:0] v2_off;
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
			vca_lut_lookup = 32'($signed({1'b0, gain_lo}) + gain_interp_prod[47:16]);
		end
	endfunction

	// ---------------------------------------------------------------

	// REBOUND keeps 32-bit control/filter arithmetic; the shared lane
	// decomposes these products internally, so no state or coefficient is
	// narrowed.
	localparam logic [7:0] TAG_REB_BASE = 8'hD0;
	localparam signed [31:0] CTRL_SLOPE_Q24 = 32'sd9856614;
	localparam signed [31:0] CTRL_OFFS = 32'sd2162688;
	localparam signed [31:0] VCC_SCALED = 32'sd5242880;
	localparam signed [31:0] A_CHARGE_Q24 = 32'sd16769089;
	localparam signed [31:0] B_CHARGE_Q24 = 32'sd8127;
	localparam signed [31:0] A_DISCHARGE555_Q24 = 32'sd16766627;
	localparam signed [31:0] GATE_OFF_THRESH = 32'sd2235480;
	localparam signed [31:0] GATE_SAT_THRESH = 32'sd2794349;
	localparam signed [31:0] GATE_SLOPE = 32'sd122961;
	localparam signed [31:0] GATE_OPEN_Q16 = 32'sd65536;
	localparam signed [31:0] GATE_SAT_Q16 = 32'sd969;
	localparam signed [31:0] GATE_SPAN_Q16 = 32'sd64567;
	localparam signed [31:0] REB_B0_Q24 = 32'sd779658;
	localparam signed [31:0] REB_B2_Q24 = -32'sd779658;
	localparam signed [31:0] REB_A1_Q24 = -32'sd32913976;
	localparam signed [31:0] REB_A2_Q24 = 32'sd16165719;
	localparam signed [31:0] OUT_DIV_Q16 = 32'sd49275;
	localparam signed [31:0] OUT_GAIN_Q16 = -32'sd216269;
	localparam signed [31:0] RAIL_HI = 32'sd18432;
	localparam signed [31:0] RAIL_LO = -32'sd24576;

	function automatic logic [79:0] reb_vca_params(input logic signed [31:0] v2_in);
		logic signed [31:0] v2_clamped;
		logic [31:0] v2_off;
		logic [6:0] lut_idx;
		logic [15:0] lut_frac;
		logic [31:0] gain_lo, gain_hi;
		logic signed [31:0] gain_base, gain_delta;
		begin
			v2_clamped = (v2_in < V2_MIN_SCALED) ? V2_MIN_SCALED :
						 (v2_in > V2_MAX_SCALED) ? V2_MAX_SCALED : v2_in;
			v2_off = v2_clamped - V2_MIN_SCALED;
			lut_idx = v2_off[22:16]; lut_frac = v2_off[15:0];
			gain_lo = VCA_GAIN_LUT[lut_idx]; gain_hi = VCA_GAIN_LUT[lut_idx + 7'd1];
			gain_base = 32'($signed({1'b0, gain_lo}));
			gain_delta = 32'($signed({1'b0, gain_hi}) - $signed({1'b0, gain_lo}));
			reb_vca_params = {gain_base, gain_delta, lut_frac};
		end
	endfunction

	logic signed [31:0] env_reb, v_c31, ctrl_work, v_c31_work;
	logic charging, charging_work;
	logic signed [31:0] reb_x1, reb_x2, reb_y1, reb_y2;
	logic [4:0] op_index;
	logic waiting_response, next_valid;
	logic [6:0] settle_count;
	logic signed [63:0] env_dis_a, env_rec_a, vchg_a, vchg_b, b0_w, b2_w, a1_w;
	logic signed [31:0] env_dis_work, env_rec_work, gated_work, reb_y_work;
	logic signed [31:0] gain_base_work, gain_work;
	logic signed [15:0] reb_sample;

	wire signed [31:0] reb_noise_scaled = {{16{noise_a[15]}}, noise_a} <<< 8;
	wire [79:0] reb_vca_p = reb_vca_params(ctrl_work);
	wire signed [63:0] rsp_q64 = 64'(mul_rsp_product);
	wire signed [31:0] rsp_q16 = 32'(mul_rsp_product >>> 16);
	wire signed [31:0] rsp_q20 = 32'(mul_rsp_product >>> 20);
	wire signed [31:0] rsp_q24 = 32'(mul_rsp_product >>> 24);

	task automatic issue_multiply(input logic signed [63:0] a, input logic signed [63:0] b,
								  input logic [6:0] aw, input logic [6:0] bw, input logic [7:0] tag);
		begin
			mul_req_a <= a; mul_req_b <= b; mul_req_a_width <= aw; mul_req_b_width <= bw;
			mul_req_tag <= tag; mul_req_valid <= 1'b1;
		end
	endtask

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			env_reb <= VHIGH_SCALED; v_c31 <= '0; charging <= 1'b1;
			reb_x1 <= '0; reb_x2 <= '0; reb_y1 <= '0; reb_y2 <= '0;
			op_index <= '0; waiting_response <= 1'b0; next_valid <= 1'b0; settle_count <= '0;
			ctrl_work <= '0; v_c31_work <= '0; charging_work <= 1'b1;
			env_dis_a <= '0; env_rec_a <= '0; vchg_a <= '0; vchg_b <= '0; b0_w <= '0; b2_w <= '0; a1_w <= '0;
			env_dis_work <= '0; env_rec_work <= '0; gated_work <= '0; reb_y_work <= '0;
			gain_base_work <= '0; gain_work <= '0;
			rebound_mix <= '0; reb_sample <= '0;
			mul_req_valid <= 1'b0; mul_req_a <= '0; mul_req_b <= '0; mul_req_a_width <= 7'd1; mul_req_b_width <= 7'd1; mul_req_tag <= '0;
		end else begin
			rebound_mix <= reb_sample;
			if (mul_req_valid && mul_req_ready) begin mul_req_valid <= 1'b0; waiting_response <= 1'b1; end
			if (sample_ce) begin
				settle_count <= 7'd64;
				if (next_valid) begin
					env_reb <= q_reb ? env_dis_work : env_rec_work;
					v_c31 <= v_c31_work; charging <= charging_work;
					reb_x1 <= gated_work; reb_x2 <= reb_x1; reb_y1 <= reb_y_work; reb_y2 <= reb_y1;
					next_valid <= 1'b0;
				end
			end else if (settle_count != 0) settle_count <= settle_count - 1'b1;
			if (!mul_req_valid && !waiting_response && settle_count == 7'd1) begin
				op_index <= 5'd0;
				issue_multiply(64'(A_DISCHARGE_Q16),64'(env_reb),7'd32,7'd32,TAG_REB_BASE);
			end
			if (mul_rsp_valid && waiting_response) begin
				waiting_response <= 1'b0;
				case (op_index)
					5'd0: begin env_dis_a <= rsp_q64; op_index <= 5'd1; issue_multiply(64'(B_DISCHARGE_Q16),64'(VLOW_SCALED),7'd32,7'd32,TAG_REB_BASE+8'd1); end
					5'd1: begin env_dis_work <= 32'((env_dis_a+rsp_q64)>>>16); op_index <= 5'd2; issue_multiply(64'(A_RECHARGE_Q24),64'(env_reb),7'd32,7'd32,TAG_REB_BASE+8'd2); end
					5'd2: begin env_rec_a <= rsp_q64; op_index <= 5'd3; issue_multiply(64'(B_RECHARGE_Q24),64'(VHIGH_SCALED),7'd32,7'd32,TAG_REB_BASE+8'd3); end
					5'd3: begin env_rec_work <= 32'((env_rec_a+rsp_q64)>>>24); op_index <= 5'd4; issue_multiply(64'(env_reb),64'(CTRL_SLOPE_Q24),7'd32,7'd32,TAG_REB_BASE+8'd4); end
					5'd4: begin ctrl_work <= rsp_q24 + CTRL_OFFS; op_index <= 5'd5; issue_multiply(64'(A_CHARGE_Q24),64'(v_c31),7'd32,7'd32,TAG_REB_BASE+8'd5); end
					5'd5: begin vchg_a <= rsp_q64; op_index <= 5'd6; issue_multiply(64'(B_CHARGE_Q24),64'(VCC_SCALED),7'd32,7'd32,TAG_REB_BASE+8'd6); end
					5'd6: begin vchg_b <= rsp_q64; op_index <= 5'd7; issue_multiply(64'(A_DISCHARGE555_Q24),64'(v_c31),7'd32,7'd32,TAG_REB_BASE+8'd7); end
					5'd7: begin
						v_c31_work <= charging ? 32'((vchg_a+vchg_b)>>>24) : rsp_q24;
						charging_work <= charging ? !(v_c31 >= ctrl_work) : (v_c31 <= (ctrl_work >>> 1));
						op_index <= 5'd8; issue_multiply(64'(v_c31-GATE_OFF_THRESH),64'(GATE_SLOPE),7'd32,7'd32,TAG_REB_BASE+8'd8);
					end
					5'd8: begin
						op_index <= 5'd9;
						issue_multiply(64'(GATE_SPAN_Q16),64'((rsp_q20 < 0) ? 0 : (rsp_q20 > 32'sd65535) ? 32'sd65535 : rsp_q20),7'd32,7'd32,TAG_REB_BASE+8'd9);
					end
					5'd9: begin
						op_index <= 5'd10;
						issue_multiply(64'((v_c31 <= GATE_OFF_THRESH) ? GATE_OPEN_Q16 : (v_c31 >= GATE_SAT_THRESH) ? GATE_SAT_Q16 : GATE_OPEN_Q16-rsp_q16),64'(reb_noise_scaled),7'd32,7'd32,TAG_REB_BASE+8'd10);
					end
					5'd10: begin gated_work <= rsp_q16; op_index <= 5'd11; issue_multiply(64'(REB_B0_Q24),64'(rsp_q16),7'd32,7'd32,TAG_REB_BASE+8'd11); end
					5'd11: begin b0_w <= rsp_q64; op_index <= 5'd12; issue_multiply(64'(REB_B2_Q24),64'(reb_x2),7'd32,7'd32,TAG_REB_BASE+8'd12); end
					5'd12: begin b2_w <= rsp_q64; op_index <= 5'd13; issue_multiply(64'(REB_A1_Q24),64'(reb_y1),7'd32,7'd32,TAG_REB_BASE+8'd13); end
					5'd13: begin a1_w <= rsp_q64; op_index <= 5'd14; issue_multiply(64'(REB_A2_Q24),64'(reb_y2),7'd32,7'd32,TAG_REB_BASE+8'd14); end
					5'd14: begin reb_y_work <= 32'((b0_w+b2_w-a1_w-rsp_q64)>>>24); op_index <= 5'd15; gain_base_work <= reb_vca_p[79:48]; issue_multiply(64'($signed(reb_vca_p[47:16])),64'(reb_vca_p[15:0]),7'd32,7'd16,TAG_REB_BASE+8'd15); end
					5'd15: begin gain_work <= gain_base_work + rsp_q16; op_index <= 5'd16; issue_multiply(64'(OUT_DIV_Q16),64'(reb_y_work),7'd32,7'd32,TAG_REB_BASE+8'd16); end
					5'd16: begin op_index <= 5'd17; issue_multiply(64'(rsp_q16),64'(gain_work),7'd32,7'd32,TAG_REB_BASE+8'd17); end
					5'd17: begin op_index <= 5'd18; issue_multiply(64'(OUT_GAIN_Q16),64'(rsp_q16),7'd32,7'd32,TAG_REB_BASE+8'd18); end
					default: begin reb_sample <= ((rsp_q16 >>> 8) > RAIL_HI) ? RAIL_HI[15:0] : ((rsp_q16 >>> 8) < RAIL_LO) ? RAIL_LO[15:0] : 16'(rsp_q16 >>> 8); next_valid <= 1'b1; end
				endcase
			end
		end
	end

`ifdef VERILATOR_SIM
	always_ff @(posedge clk) begin
		if (rst_n && mul_rsp_valid && waiting_response && (mul_rsp_tag != TAG_REB_BASE + op_index)) $error("REBOUND shared-multiply tag mismatch");
		if (rst_n && sample_ce && (mul_req_valid || waiting_response)) $error("REBOUND shared multiply missed sample deadline");
	end
`endif

endmodule
