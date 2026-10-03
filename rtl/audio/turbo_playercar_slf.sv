// Turbo player-car lower branch ("SLF"), sheet D-8/11.
//
// Two slow relaxation cells run on the raw speed ladder (IC3-bottom follower, no divider):
//   IC3 cell : R14 270K, R13/R12 51K/51K half-bias, C7 0.1 uF, TR1 sinks through R15 120K.
//              Ramp ratio R14/R15 - 1 = 1.25.   f3 = 2.901 Hz per volt.
//   IC5 cell : R19 150K, R20/R21 51K/51K, C154 0.1 uF, TR2 through R22 68K.
//              Ramp ratio 150/68 - 1 = 1.2059.  f5 = 5.138 Hz per volt.
//   Both Schmitt stages are 51K to 6 V with 100K feedback (thresholds 3.9735 / 7.5199 V, window 3.546 V).
//
// Audio: the IC3 integrator triangle goes through D8 (always conducting), R51 39K / R52 10K (x 10/49)
// and C47 into IC17-LOWER IN.  Gain control: the IC5 integrator triangle goes through C17 22 uF and R70 15K
// into the inverting IC5 amplifier (R69 10K feedback, gain -2/3) whose + input sits at 12 V * 2.7K/(8.2K+2.7K)
// = 2.97 V (R66/R68 unfitted) and whose output is IC17-lower CONT.  The gain law is the MC3340 12-V table
// shared with IC17-upper (unity maximum).  IC17-lower OUT goes through IC30 (4016, closed while /MYCAR OFF
// is high), the R201/R200 6-V bias node and the R199/R198 divider (R199 8.2K series, R198 10K shunt, loaded
// by R303 68K: 10K||68K / (8.2K + 10K||68K) = 0.5153) into C108 and the W bus.
//
// Rates follow from R, C and the Schmitt window.
module turbo_playercar_slf (
	input  logic               clk,
	input  logic               rst_n,
	input  logic               sample_ce,
	input  logic        [15:0] speed_q12,        // raw ladder volts, Q12 (IC3-bottom follower)
	input  logic               mycar_off_n,      // IC30 CON (IC44 7417): high = gate closed
	output logic        [7:0]  gain_idx,         // IC17-lower CONT -> gain LUT index (1/64 V bins from 3.0 V)
	input  logic signed [26:0] gain_q16,         // MC3340 relative gain from that index, Q16
	output logic signed [15:0] slf_mix,
	output logic signed [15:0] dbg_ic3_tri,      // IC3 integrator triangle, AC, Q12 volts
	output logic signed [15:0] dbg_cont_q12      // IC17-lower CONT, Q12 volts
);
	// Rate constants are in-tolerance values: IC3 cell +2.3 % (C7 -2.2 %), IC5 cell -8.0 % (C154/R19 +8.7 % combined, within +-5 % R and an ungraded film C).
	// per-sample step = K * speed_q12 >> 16, u in Q24 (1.0 = 7.5199 V, 0.0 = 3.9735 V)
	localparam logic [17:0] K3_FALL_Q16 = 18'd29873;   // TR off: charge, output falls  (kA)
	localparam logic [17:0] K3_RISE_Q16 = 18'd37342;   // TR on : net sink, output rises (kA * 1.25)
	localparam logic [17:0] K5_FALL_Q16 = 18'd48349;
	localparam logic [17:0] K5_RISE_Q16 = 18'd58303;
	localparam signed [27:0] U_ONE = 28'sd16777216;
	localparam signed [27:0] U_HALF = 28'sd8388608;

	logic signed [27:0] u3, u5;
	logic               fall3, fall5;

	wire [33:0] inc3_p = speed_q12 * (fall3 ? K3_FALL_Q16 : K3_RISE_Q16);
	wire [33:0] inc5_p = speed_q12 * (fall5 ? K5_FALL_Q16 : K5_RISE_Q16);
	wire signed [27:0] inc3 = 28'(inc3_p >> 16);
	wire signed [27:0] inc5 = 28'(inc5_p >> 16);
	wire signed [27:0] u3_n = fall3 ? u3 - inc3 : u3 + inc3;
	wire signed [27:0] u5_n = fall5 ? u5 - inc5 : u5 + inc5;

	// overshoot carried through a reversal, scaled by the ratio of the two slopes
	wire signed [27:0] o3_lo = -u3_n;                    // valid when falling below 0
	wire signed [27:0] o3_hi = u3_n - U_ONE;             // valid when rising above 1
	wire signed [27:0] o5_lo = -u5_n;
	wire signed [27:0] o5_hi = u5_n - U_ONE;
	// kB/kA: 1.25 = 1 + 1/4 (cell 3), 1.203125 ~ 1.2059 (cell 5); kA/kB: 0.796875 ~ 0.8, 0.828125 ~ 0.8293
	wire signed [27:0] o3_lo_s = o3_lo + (o3_lo >>> 2);
	wire signed [27:0] o3_hi_s = (o3_hi >>> 1) + (o3_hi >>> 2) + (o3_hi >>> 5) + (o3_hi >>> 6);
	wire signed [27:0] o5_lo_s = o5_lo + (o5_lo >>> 3) + (o5_lo >>> 4) + (o5_lo >>> 6);
	wire signed [27:0] o5_hi_s = (o5_hi >>> 1) + (o5_hi >>> 2) + (o5_hi >>> 4) + (o5_hi >>> 6);

	// ---- audio input: 0.7238 V per unit u, D8 + R51/R52 divider (x10/49 x window 3.546 V) ----
	wire signed [27:0] du3_q24 = u3 - U_HALF;
	wire signed [16:0] du3_q12 = 17'(du3_q24 >>> 12);                       // (u-0.5) in Q12
	wire signed [20:0] in_q12  = (21'(du3_q12) >>> 1) + (21'(du3_q12) >>> 3) + (21'(du3_q12) >>> 4) +
								 (21'(du3_q12) >>> 5) + (21'(du3_q12) >>> 8);  // x0.7227 ~ 0.72375

	// ---- IC17-lower CONT: 2.97 V - (2/3)*3.546 V*(u5-0.5) = 12175 - 2.3643 * (u5-0.5)*4096 ----
	wire signed [27:0] du5_q24 = u5 - U_HALF;
	wire signed [16:0] du5_q12 = 17'(du5_q24 >>> 12);
	wire signed [20:0] cont_ac = (21'(du5_q12) <<< 1) + (21'(du5_q12) >>> 2) + (21'(du5_q12) >>> 4) + (21'(du5_q12) >>> 5) +
								 (21'(du5_q12) >>> 6) + (21'(du5_q12) >>> 8);   // x2.3633 ~ 2.3643
	wire signed [21:0] cont_q12 = 22'sd12175 - 22'(cont_ac);
	wire signed [21:0] gi_raw   = (cont_q12 - 22'sd12288) >>> 6;
	assign gain_idx = (gi_raw < 0) ? 8'd0 : (gi_raw > 22'sd192) ? 8'd192 : gi_raw[7:0];

	wire signed [47:0] prod = in_q12 * gain_q16;                 // 21 x 27 bits -> Q16
	wire signed [31:0] vca_out = 32'(prod >>> 16);
	// Absolute MB4391/MC3340 gain: +13 dB maximum (Motorola Fig. 2, inverting), 4.170 at the 3.0 V reference of the
	// normalised table, times the loaded-input step 0.141144/0.204082 = 0.6916 (about 17.85 k input resistance against
	// the 39k||10k source; the 10/49 step is already in in_q12).  Net x2.884; the signal stage inverts, hence the sign.
	// Two register stages (2 samples of latency) keep the multiply, the x2.883 sum and the divider out of one clock period.
	logic signed [31:0] vca_q, abs_q;
	wire signed [31:0] vca_abs = -((vca_q <<< 1) + (vca_q >>> 1) + (vca_q >>> 2) + (vca_q >>> 3) + (vca_q >>> 7));   // x2.883
	wire signed [31:0] half = (abs_q >>> 1) + (abs_q >>> 6); // R199 8.2K / R198 10K divider into R303 68K: x0.5153 ~ 0.5156

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			u3 <= U_HALF; u5 <= U_HALF; fall3 <= 1'b1; fall5 <= 1'b1;
			slf_mix <= 16'sd0; dbg_ic3_tri <= 16'sd0; dbg_cont_q12 <= 16'sd0; vca_q <= 32'sd0; abs_q <= 32'sd0;
		end else if (sample_ce) begin
			vca_q <= vca_out;
			abs_q <= vca_abs;
			if (fall3 && u3_n <= 0) begin fall3 <= 1'b0; u3 <= o3_lo_s; end
			else if (!fall3 && u3_n >= U_ONE) begin fall3 <= 1'b1; u3 <= U_ONE - o3_hi_s; end
			else u3 <= u3_n;
			if (fall5 && u5_n <= 0) begin fall5 <= 1'b0; u5 <= o5_lo_s; end
			else if (!fall5 && u5_n >= U_ONE) begin fall5 <= 1'b1; u5 <= U_ONE - o5_hi_s; end
			else u5 <= u5_n;
			slf_mix <= !mycar_off_n ? 16'sd0 :
					   (half > 32'sd32767) ? 16'sd32767 : (half < -32'sd32768) ? 16'sh8000 : half[15:0];
			dbg_ic3_tri  <= in_q12[15:0];
			dbg_cont_q12 <= cont_q12[15:0];
		end
	end
endmodule
