// FIRE channel (laser), sheet 3. Chain:
//   /FIRE -> IC4 74123 one-shot (tw=21.15ms) -> envelope (fast charge to
//   3.80V while gated, tau=1.02s decay) -> splits into:
//     control leg:  V2 = 5.475 - 0.839*Venv -> piecewise A(V2) -> VCA gain
//                   (LUT, linear interpolation)
//     filter leg:   Tr1 conduction -> IC12, a 2-pole filter whose resonant
//                   peak sweeps continuously with Tr1's conductance
//   signal path: noise_a -> IC12 (filter leg) -> input atten 0.0991 ->
//                x VCA gain (control leg) -> output gain -2.2 -> FIRE MIX
//
// IC12's feedback is not just R35 in parallel with C32+C33: the C32/C33
// midpoint is tapped and returned to ground through R31 (100 ohm) + Tr1's
// variable collector resistance (in parallel with R32 1.5K), a finite shunt
// impedance in every Tr1 state. A bridged-capacitor network with a
// finite-impedance midpoint tap is a true 2-pole network, not a one-pole
// low-pass with a shifting corner. Nodal analysis gives
//   H(s) = -(1/R33) * (2*C*s + 1/Z) / (C^2*s^2 + (2*C/R35)*s + 1/(R35*Z))
// where Z = R31 + (R32 || Tr1's Rce) is the shunt impedance at the midpoint.
// The resonant peak depends on Z: ~1.8 kHz with Tr1 off (Z=1.6K) up to
// ~7.3 kHz with Tr1 saturated (Z=148R), so the whistle sweeps down as the
// envelope decays and Tr1 desaturates.
module fire_chan (
	input  logic               clk,
	input  logic               rst_n,
	input  logic               sample_ce,
	input  logic                fire_n,          // /FIRE, active low, falling edge triggers
	input  logic signed [15:0] noise_a,
	output logic signed [15:0] fire_mix,        // 4096 LSB = 1V

	// Shared-multiplier client. FIRE submits one operation at a time; the
	// sequence completes well inside one 832-clock audio sample interval and
	// commits its recursive state on the next sample_ce.
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
	// Filter-state fixed point: 4096*256 = 1,048,576 LSB/V (SCALE, folded into
	// the localparam constants below). State widths vary per signal, narrowed
	// to 27 bits wherever DSP packing allows. All Q0.16 coefficients are
	// computed at fs = clk_sys/832 = 39,935,064/832 = 47,998.875 Hz.

	// ---------------------------------------------------------------
	// Stage 1: IC4 sec.2 74123 one-shot.
	// tw = 0.45 * R7(47K) * C4(1uF) = 21.15 ms
	// WIDTH_CYCLES = 0.02115 * 39,935,064 = 844,626.6 -> 844,627
	// ---------------------------------------------------------------
	logic q_oneshot;

	ttl_74123 #(.WIDTH_CYCLES(844627)) u_74123_fire (
		.clk    (clk),
		.rst_n  (rst_n),
		.a_n    (fire_n),
		.q      (q_oneshot)
	);

	// ---------------------------------------------------------------
	// Stage 2: envelope. One-pole toward VPEAK while gated (fast, tau=1ms,
	// much faster than the 21.15ms gate; the real D8/R6 charge dynamics are
	// not otherwise documented). Decays with tau=1.02s (R4 150K * C3 6.8uF)
	// once the gate drops.
	//   a_charge = exp(-1/(fs*0.001))  = 0.97938 -> Q0.16 = 64185
	// env_next = a*env + (1-a)*target   (target = VPEAK while gated, 0 while decaying)
	//
	// VPEAK = 3.80 V. V2 = 5.475 - 0.839*Venv crosses the MC3340's 3.1V knee
	// (full gain below it) at a fixed Venv = 2.83V regardless of VPEAK, so
	// VPEAK sets how long the channel stays at full gain before attenuation
	// ramps in.
	//
	// The decay pole must be Q0.24: its ideal value exp(-1/(fs*1.02)) =
	// 0.99997957 is not expressible in Q0.16 (65535/65536 gives tau = 1.365 s,
	// 65534/65536 gives 0.68 s). In Q0.24 the realised tau is 1.0191 s (0.09%
	// low).
	//   a_decay = 0.99997957 -> Q0.24 = 16776873
	// The charge pole is far from unity, so Q0.16 is enough there.
	// ---------------------------------------------------------------
	// 27 bits, not 32: a DSP multiplier is sized off the operand width
	// presented to `*`, not the constant's magnitude.
	localparam signed [26:0] VPEAK_SCALED = 27'sd3984589; // 3.80V * SCALE
	localparam signed [26:0] A_CHARGE = 27'sd64185;
	localparam signed [26:0] B_CHARGE = 27'sd1351;  // 65536 - A_CHARGE
	localparam signed [26:0] A_DECAY  = 27'sd16776873; // Q0.24; target 0, so (1-a)*target drops out

	logic signed [26:0] env;


	// ---------------------------------------------------------------
	// Stages 3-5: control leg (V2 -> VCA LUT) and filter leg (Tr1 conduction
	// -> IC12 time-varying 2-pole resonant filter) in parallel, recombined at
	// the output stage. Pipelined with one multiply (or one cheap
	// compare/add/mux) per register-to-register hop, free-running on `clk`;
	// 832 clk_sys cycles exist per audio sample and the pipeline is about a
	// dozen deep. The frac_gc divide-by-constant is folded into a precomputed
	// Q32 reciprocal multiply (RECIP_FRAC_Q32; error under 1 LSB of Q0.16
	// across the domain) so no iterative divider is synthesized.
	// ---------------------------------------------------------------

	// 27 bits, not 32, except RECIP_FRAC_Q32: a true Q0.32 reciprocal that
	// needs its full width for precision.

	// V2 = 5.475 - 0.839*Venv. V2_CONST_SCALED = 5.475*SCALE = 5,740,954.
	// COEF_0839 (Q0.16) = 0.839*65536 = 54985.
	localparam signed [26:0] V2_CONST_SCALED = 27'sd5740954;
	localparam signed [26:0] COEF_0839       = 27'sd54985;

	// Clamp into the LUT's covered range [2.0V, 6.0V) before indexing.
	localparam signed [26:0] V2_MIN_SCALED = 27'sd2097152;      // 2.0V * SCALE
	localparam signed [26:0] V2_MAX_SCALED = 27'sd6291455;      // 6.0V * SCALE - 1

	// Tr1 conduction, piecewise on Vbe = Venv*0.1803.
	//   gc = 0                     Vbe <= 0.60
	//      = gsat*(Vbe-0.60)/0.15  0.60 < Vbe < 0.75
	//      = gsat                  Vbe >= 0.75
	// frac_gc (0..65536, Q0.16) is this fraction; it indexes the IC12 biquad
	// coefficient LUT since the shunt impedance Z follows Tr1's conductance.
	localparam signed [26:0] VBE_COEF         = 27'sd11816;   // 0.1803 Q0.16
	localparam signed [26:0] VBE_LOW_SCALED   = 27'sd629146;  // 0.60V * SCALE
	localparam signed [26:0] VBE_RANGE_SCALED = 27'sd157286;  // 0.15V * SCALE
	// frac_gc = ((vbe_scaled-LOW) * 65536) / RANGE, folded into one Q32
	// reciprocal: RECIP_FRAC_Q32 = round(65536 * 2^32 / RANGE) = 1789574258.
	localparam signed [31:0] RECIP_FRAC_Q32 = 32'sd1789574258;

	// noise_a scaled up to the filter's internal scale (2^8 = 256x finer than
	// audio scale, matching every other channel's noise-fed filter).
	wire signed [26:0] noise_scaled = 27'({{16{noise_a[15]}}, noise_a} <<< 8);


	// ---------------------------------------------------------------
	// MC3340 VCA gain LUT: 65 points across V2 = 2.0 .. 6.0V, step 0.0625V.
	// With SCALE=1,048,576 LSB/V, 0.0625V * SCALE = 65536 exactly, so the
	// index and Q0.16 interpolation fraction are the high/low halves of
	// (v2_clamped - V2_MIN_SCALED), with no divide.
	//
	// Each entry is gain = 10^((13-A(V2))/20) from the piecewise A(V2), held
	// as 16 fractional bits in a 32-bit word (the +13 dB peak gain is 4.4668x,
	// which needs integer bits). The -77..-90 dB tail quantises to a few LSBs.
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

	// Return {gain_lo, gain_hi-gain_lo, frac}; interpolation itself is a
	// scheduled shared-lane operation, never a hidden inferred multiplier.
	function automatic logic [58:0] vca_lut_params(input logic signed [26:0] v2_in);
		logic signed [26:0] v2_clamped;
		logic [22:0] v2_off;
		logic [6:0]  lut_idx;
		logic [15:0] lut_frac;
		logic [31:0] gain_lo, gain_hi;
		logic signed [20:0] gain_base, gain_delta;
		begin
			v2_clamped = (v2_in < V2_MIN_SCALED) ? V2_MIN_SCALED :
						 (v2_in > V2_MAX_SCALED) ? V2_MAX_SCALED : v2_in;
			v2_off   = 23'(v2_clamped - V2_MIN_SCALED);   // 0 .. LUT_SIZE-1 in units of 65536
			lut_idx  = v2_off[22:16];           // 0 .. 63 (indices for interpolation)
			lut_frac = v2_off[15:0];            // Q0.16 fraction between idx and idx+1
			gain_lo  = VCA_GAIN_LUT[lut_idx];
			gain_hi  = VCA_GAIN_LUT[lut_idx + 7'd1];
			gain_base  = 21'($signed({1'b0, gain_lo}));
			gain_delta = 21'($signed({1'b0, gain_hi}) - $signed({1'b0, gain_lo}));
			vca_lut_params = {gain_base, gain_delta, 1'b0, lut_frac};
		end
	endfunction

	// ---------------------------------------------------------------
	// IC12 filter leg: a time-varying 2-pole biquad (see the header for the
	// transfer function). Coefficients come from a 33-entry table, precomputed
	// offline by bilinear-transforming the transfer function at 33 evenly
	// spaced points of Tr1's conductance (frac_gc = 0..65536) and looked up
	// without interpolation: frac_gc moves smoothly and only once per sample,
	// so 33 steps track the sweep with no interpolation multiplies.
	//
	// B1 is not stored. The numerator has a single zero (n1*s + n0), and
	// bilinear-transforming that shape gives the exact identity B1 = B0+B2, so
	//   B0*x[n] + B1*x[n-1] + B2*x[n-2]
	// becomes
	//   B0*(x[n]+x[n-1]) + B2*(x[n-1]+x[n-2]),
	// i.e. four real multiplies in total (B0, B2, A1, A2).
	//
	// State widths: x1/x2 fit in 27 bits. y1/y2 do not: at the highest-Q
	// setting (Tr1 saturated) the resonance gives peaks over 30x the input,
	// needing ~28 bits. They are declared 40 bits since a 27x27 DSP packs an
	// operand in ceil(width/27) chunks, so 28-54 bits cost the same two chunks.
	// ---------------------------------------------------------------
	localparam int FILT_LUT_SIZE = 33;
	localparam logic signed [26:0] IC12_B0_LUT [0:FILT_LUT_SIZE-1] = '{
		-27'sd4376043, -27'sd5209363, -27'sd5939612, -27'sd6584799,
		-27'sd7158969, -27'sd7673235, -27'sd8136508, -27'sd8556014,
		-27'sd8937675, -27'sd9286391, -27'sd9606252, -27'sd9900697,
		-27'sd10172639, -27'sd10424563, -27'sd10658601, -27'sd10876593,
		-27'sd11080133, -27'sd11270614, -27'sd11449252, -27'sd11617119,
		-27'sd11775161, -27'sd11924215, -27'sd12065028, -27'sd12198264,
		-27'sd12324518, -27'sd12444326, -27'sd12558169, -27'sd12666482,
		-27'sd12769658, -27'sd12868053, -27'sd12961993, -27'sd13051774,
		-27'sd13137666
	};
	localparam logic signed [26:0] IC12_B2_LUT [0:FILT_LUT_SIZE-1] = '{
		27'sd2226671, 27'sd1319474, 27'sd524485, -27'sd177901,
		-27'sd802974, -27'sd1362832, -27'sd1867176, -27'sd2323873,
		-27'sd2739370, -27'sd3119002, -27'sd3467220, -27'sd3787768,
		-27'sd4083819, -27'sd4358078, -27'sd4612864, -27'sd4850182,
		-27'sd5071767, -27'sd5279135, -27'sd5473610, -27'sd5656359,
		-27'sd5828412, -27'sd5990681, -27'sd6143977, -27'sd6289025,
		-27'sd6426473, -27'sd6556902, -27'sd6680838, -27'sd6798753,
		-27'sd6911075, -27'sd7018194, -27'sd7120463, -27'sd7218203,
		-27'sd7311710
	};
	localparam logic signed [26:0] IC12_A1_LUT [0:FILT_LUT_SIZE-1] = '{
		-27'sd31234973, -27'sd30510046, -27'sd29874783, -27'sd29313518,
		-27'sd28814032, -27'sd28366658, -27'sd27963645, -27'sd27598705,
		-27'sd27266688, -27'sd26963331, -27'sd26685075, -27'sd26428930,
		-27'sd26192360, -27'sd25973205, -27'sd25769609, -27'sd25579972,
		-27'sd25402907, -27'sd25237203, -27'sd25081801, -27'sd24935769,
		-27'sd24798284, -27'sd24668618, -27'sd24546121, -27'sd24430216,
		-27'sd24320384, -27'sd24216159, -27'sd24117124, -27'sd24022900,
		-27'sd23933145, -27'sd23847548, -27'sd23765827, -27'sd23687724,
		-27'sd23613005
	};
	localparam logic signed [26:0] IC12_A2_LUT [0:FILT_LUT_SIZE-1] = '{
		27'sd15372383, 27'sd15388102, 27'sd15401876, 27'sd15414046,
		27'sd15424877, 27'sd15434577, 27'sd15443316, 27'sd15451229,
		27'sd15458428, 27'sd15465005, 27'sd15471039, 27'sd15476593,
		27'sd15481722, 27'sd15486474, 27'sd15490889, 27'sd15495001,
		27'sd15498840, 27'sd15502433, 27'sd15505803, 27'sd15508969,
		27'sd15511950, 27'sd15514762, 27'sd15517418, 27'sd15519931,
		27'sd15522313, 27'sd15524573, 27'sd15526720, 27'sd15528763,
		27'sd15530709, 27'sd15532565, 27'sd15534337, 27'sd15536031,
		27'sd15537651
	};

	// IC12 output rails: a real clipping mechanism, not a format guard. IC12 is
	// an LM324, so it cannot leave roughly 0..10.5V, i.e. -6.00/+4.50V about
	// the 6V mid-rail. At the resonant peak (Tr1 saturated) the filter gain is
	// high enough to hit the rails. The clamp is applied before the state
	// capture, because the clipped value is what appears on the node feeding
	// back into IC12's own network (R35/C32/C33) and so what the next
	// sample's recursion must see. Filter scale here is 2^20 LSB/V
	// (4096*256), not 2^24.
	localparam signed [39:0] IC12_RAIL_HI = 40'sd4718592;   // +4.50V * 2^20
	localparam signed [39:0] IC12_RAIL_LO = -40'sd6291456;  // -6.00V * 2^20

	localparam signed [26:0] ATTEN_Q16    = 27'sd6495;   // 0.0991 * 65536
	localparam signed [26:0] OUT_GAIN_Q16 = -27'sd144179; // -2.2 * 65536
	// FIRE has fourteen sample-rate products: three clocks per native 27-bit
	// multiply (four for the 40-bit feedback terms), well below the 832 clocks
	// between sample_ce pulses. Start after a short settle window and commit
	// work atomically on the next CE.
	localparam logic [7:0] TAG_FIRE_BASE = 8'hC0;
	logic [3:0] op_index;
	logic waiting_response, next_valid;
	logic [6:0] settle_count;
	logic signed [26:0] ic12_x1, ic12_x2;
	logic signed [39:0] ic12_y1, ic12_y2;
	logic signed [26:0] vbe_work;
	logic signed [20:0] gain_base, gain_delta, gain_work;
	logic signed [16:0] gain_frac;
	logic [5:0] filt_idx_work;
	logic signed [127:0] b0_work, b2_work, a1_work;
	logic signed [39:0] ic12_y_work;
	logic signed [53:0] env_charge_a;
	logic signed [26:0] env_charge_work, env_decay_work;
	logic signed [15:0] fire_sample;

	wire signed [26:0] ic12_u1 = 27'(noise_scaled + ic12_x1);
	wire signed [26:0] ic12_u2 = 27'(ic12_x1 + ic12_x2);
	wire signed [127:0] filter_sum = b0_work + b2_work - a1_work - mul_rsp_product;
	wire signed [127:0] filter_scaled = filter_sum >>> 24;
	wire signed [31:0] rsp_q16_32 = 32'(mul_rsp_product >>> 16);
	wire signed [20:0] rsp_gain_q16 = 21'(mul_rsp_product >>> 16);
	wire signed [26:0] rsp_env_q16 = 27'(mul_rsp_product >>> 16);
	wire signed [26:0] rsp_env_q24 = 27'(mul_rsp_product >>> 24);
	// Quartus 17 cannot elaborate a part-select directly on a function-call
	// result, so the typed result is kept on a named wire.
	wire signed [26:0] v2_from_env = 27'(V2_CONST_SCALED - rsp_env_q16);
	wire        [58:0] vca_params_from_env = vca_lut_params(v2_from_env);
	wire signed [31:0] mix_full = rsp_q16_32 >>> 8;
	wire signed [15:0] mix_sat =
		(mix_full > 32'sd32767) ? 16'sd32767 :
		(mix_full < -32'sd32768) ? 16'sh8000 : mix_full[15:0];

	task automatic issue_multiply(
		input logic signed [63:0] a, input logic signed [63:0] b,
		input logic [6:0] aw, input logic [6:0] bw, input logic [7:0] tag
	);
		begin
			mul_req_a <= a; mul_req_b <= b;
			mul_req_a_width <= aw; mul_req_b_width <= bw;
			mul_req_tag <= tag; mul_req_valid <= 1'b1;
		end
	endtask

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			env <= '0; ic12_x1 <= '0; ic12_x2 <= '0; ic12_y1 <= '0; ic12_y2 <= '0;
			// Prime the first snapshot after reset so the first state update is
			// not deferred by a whole audio sample.
			op_index <= '0; waiting_response <= 1'b0; next_valid <= 1'b0; settle_count <= 7'd64;
			vbe_work <= '0; gain_base <= '0; gain_delta <= '0; gain_frac <= '0; gain_work <= '0;
			filt_idx_work <= '0; b0_work <= '0; b2_work <= '0; a1_work <= '0; ic12_y_work <= '0;
			env_charge_a <= '0; env_charge_work <= '0; env_decay_work <= '0;
			fire_sample <= '0; fire_mix <= '0;
			mul_req_valid <= 1'b0; mul_req_a <= '0; mul_req_b <= '0;
			mul_req_a_width <= 7'd1; mul_req_b_width <= 7'd1; mul_req_tag <= '0;
		end else begin
			fire_mix <= fire_sample;
			if (mul_req_valid && mul_req_ready) begin
				mul_req_valid <= 1'b0;
				waiting_response <= 1'b1;
			end
			if (sample_ce) begin
				settle_count <= 7'd64;
				if (next_valid) begin
					env <= q_oneshot ? env_charge_work : env_decay_work;
					ic12_x2 <= ic12_x1; ic12_x1 <= noise_scaled;
					ic12_y2 <= ic12_y1; ic12_y1 <= ic12_y_work;
					next_valid <= 1'b0;
				end
			end else if (settle_count != 0) begin
				settle_count <= settle_count - 1'b1;
			end
			if (!mul_req_valid && !waiting_response && settle_count == 7'd1) begin
				op_index <= 4'd0;
				issue_multiply(64'(COEF_0839), 64'(env), 7'd27, 7'd27, TAG_FIRE_BASE);
			end
			if (mul_rsp_valid && waiting_response) begin
				waiting_response <= 1'b0;
				case (op_index)
					4'd0: begin
						gain_base <= vca_params_from_env[58:38];
						gain_delta <= vca_params_from_env[37:17];
						gain_frac <= vca_params_from_env[16:0];
						op_index <= 4'd1; issue_multiply(64'(VBE_COEF),64'(env),7'd27,7'd27,TAG_FIRE_BASE+8'd1);
					end
					4'd1: begin vbe_work <= rsp_env_q16; op_index <= 4'd2; issue_multiply(64'(rsp_env_q16-VBE_LOW_SCALED),64'(RECIP_FRAC_Q32),7'd27,7'd32,TAG_FIRE_BASE+8'd2); end
					4'd2: begin
						filt_idx_work <= (vbe_work <= VBE_LOW_SCALED) ? 6'd0 :
										 (vbe_work >= VBE_LOW_SCALED+VBE_RANGE_SCALED) ? 6'd32 : 6'(mul_rsp_product >>> 43);
						op_index <= 4'd3; issue_multiply(64'(gain_delta),64'(gain_frac),7'd21,7'd17,TAG_FIRE_BASE+8'd3);
					end
					4'd3: begin gain_work <= gain_base + rsp_gain_q16; op_index <= 4'd4; issue_multiply(64'(IC12_B0_LUT[filt_idx_work]),64'(ic12_u1),7'd27,7'd27,TAG_FIRE_BASE+8'd4); end
					4'd4: begin b0_work <= mul_rsp_product; op_index <= 4'd5; issue_multiply(64'(IC12_B2_LUT[filt_idx_work]),64'(ic12_u2),7'd27,7'd27,TAG_FIRE_BASE+8'd5); end
					4'd5: begin b2_work <= mul_rsp_product; op_index <= 4'd6; issue_multiply(64'(IC12_A1_LUT[filt_idx_work]),64'(ic12_y1),7'd27,7'd40,TAG_FIRE_BASE+8'd6); end
					4'd6: begin a1_work <= mul_rsp_product; op_index <= 4'd7; issue_multiply(64'(IC12_A2_LUT[filt_idx_work]),64'(ic12_y2),7'd27,7'd40,TAG_FIRE_BASE+8'd7); end
					4'd7: begin
						ic12_y_work <= (filter_scaled > 128'(IC12_RAIL_HI)) ? IC12_RAIL_HI : (filter_scaled < 128'(IC12_RAIL_LO)) ? IC12_RAIL_LO : 40'(filter_scaled);
						op_index <= 4'd8; issue_multiply(64'(ATTEN_Q16),64'(ic12_y1),7'd27,7'd40,TAG_FIRE_BASE+8'd8);
					end
					4'd8: begin op_index <= 4'd9; issue_multiply(64'(rsp_q16_32),64'(gain_work),7'd32,7'd21,TAG_FIRE_BASE+8'd9); end
					4'd9: begin op_index <= 4'd10; issue_multiply(64'(OUT_GAIN_Q16),64'(rsp_q16_32),7'd27,7'd32,TAG_FIRE_BASE+8'd10); end
					4'd10: begin fire_sample <= mix_sat; op_index <= 4'd11; issue_multiply(64'(A_CHARGE),64'(env),7'd27,7'd27,TAG_FIRE_BASE+8'd11); end
					4'd11: begin env_charge_a <= 54'(mul_rsp_product); op_index <= 4'd12; issue_multiply(64'(B_CHARGE),64'(VPEAK_SCALED),7'd27,7'd27,TAG_FIRE_BASE+8'd12); end
					4'd12: begin env_charge_work <= 27'((env_charge_a + 54'(mul_rsp_product)) >>> 16); op_index <= 4'd13; issue_multiply(64'(A_DECAY),64'(env),7'd27,7'd27,TAG_FIRE_BASE+8'd13); end
					default: begin env_decay_work <= rsp_env_q24; next_valid <= 1'b1; end
				endcase
			end
		end
	end

`ifdef VERILATOR_SIM
	always_ff @(posedge clk) begin
		if (rst_n && mul_rsp_valid && waiting_response && (mul_rsp_tag != TAG_FIRE_BASE + 8'(op_index)))
			$error("FIRE shared-multiply tag mismatch");
		if (rst_n && sample_ce && (mul_req_valid || waiting_response))
			$error("FIRE shared multiply missed sample deadline");
	end
`endif

endmodule
