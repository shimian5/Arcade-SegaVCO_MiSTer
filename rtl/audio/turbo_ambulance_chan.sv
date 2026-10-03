// Turbo AMBULANCE channel (D-10/11): a twin-tone warble siren. Two free-running
// oscillator chains (IC11 A/B and IC4 A/B, each with a diode/transistor current-source
// limiter, TR9/D22 and TR4/D11) are summed into an MB4391/HD4391-family VCA (IC36),
// trimmed by VR5 (200K), to the AMBULANCE/AMBULANCE.M taps.
//
// Gating: IC36's CONT pin (pin 6) is driven by an IC4 unity-gain follower whose input
// is NODE_A of the R58/R59/R57/C13/D10 network off /AMBU, so the channel is a VCA
// envelope, not a hard gate (see the envelope block below). The follower is one section
// of the IC4 quad op-amp (pins 2/3/1); its other sections (pins 9/10/8 and 5/6/7) are
// oscillator stages. Other IC36 pins: pin 5 = IN (from IC11 pin 14 via R99 5.1K and
// C126 1 uF), pin 11 = OUT -> VR5, pin 10 = ROLL with C116 680 pF to ground. Neither
// oscillator chain is gated; both free-run.
//
// Tone generation:
//   IC9 555 (R90 6.2K on DIS, D20 in parallel with R124 330K, C38 1.5 uF, thresholds
//   4 V / 8 V on 12 V) is a fast-rise / slow-fall sawtooth generator: C38 charges through
//   R90 + D20 (~7 ms) and discharges through R124 alone (343 ms, 8 V -> 4 V), period
//   ~0.35 s. D20 is in parallel with R124 (anode on the DIS node), not a peak detector.
//   IC71 is a plain follower of the C38 node, so Vin(t) sweeps 8 V -> 4 V.
//   Both audio oscillators are relaxation cells fed from that Vin:
//     cell 1 (IC11 A/B): R134 30K, R133/R132 half-bias, C44 0.033 uF, TR9 sink through
//       R135 9.9K -> charge Vin/60K, sink Vin/29.55K (ramp ratio 2.03),
//       f = 114.5 * Vin  (916 -> 458 Hz)
//     cell 2 (IC4 A/B): R18 30K, R17/R16 half-bias, C3+C4 = 0.0288 uF, TR4 sink through
//       R60 15K -> symmetric, f = 97.9 * Vin (783 -> 392 Hz)
//   Both Schmitts (R104 47K to 6 V, R102 120K, output 0..10.5 V) switch at 4.311 V /
//   7.266 V. The square outputs go through R101 82K + C31 + R100 33K (cell 1) and
//   R105 68K + C14 + R61 33K (cell 2) into IC11-C (R99 5.1K, inverting): AC gains
//   5.1/115 and 5.1/101. Every rate is set by R, C and those thresholds.
module turbo_ambulance_chan (
	input  logic               clk,
	input  logic               rst_n,
	input  logic                ambu_n,   // /AMBU, active low
	input  logic               sample_ce,
	output logic signed [15:0] turbo_ambulance_mix, // AMBULANCE / AMBULANCE.M
	output logic                dbg_warble
);

	// ---------------------------------------------------------------
	// IC9 sawtooth (C38 node = IC71 output = Vin), Q16 volts.
	//   discharge (555 output low, DIS grounds R124):  v -= v * dt/(R124*C38)
	//   charge    (555 output high, DIS open):         v += (12 - Vd - v) * dt/(R90*C38)
	//   trip at 8.0 V (THR) and 4.0 V (TRG); D20 drop 0.7 V as elsewhere in this file.
	//   dt/(R124*C38) = 4.2098e-5  -> Q30 45,202;  dt/(R90*C38) = 2.2402e-3 -> Q30 2,405,392
	// ---------------------------------------------------------------
	localparam signed [21:0] V_HI_Q16   = 22'sd524288;    //  8.0 V
	localparam signed [21:0] V_LO_Q16   = 22'sd262144;    //  4.0 V
	localparam signed [21:0] V_TGT_Q16  = 22'sd740557;    // 12 V - 0.7 V
	// Chirp repeat: nominal R90 6.2k / R124 330k / C38 1.5 uF give 2.8531 Hz analytically,
	// but the plain Q30 constants (45,202 / 2,405,392) realise only 2.7604 Hz because of
	// right-shift floor error. K_DISCH / K_CHG are scaled by 1.0849 (arithmetic correction
	// plus an assumed timing-component tolerance) for a 3.003 Hz repeat. Only the repeat
	// rate changes; the tone frequencies depend on Vin, not on C38.
	localparam signed [21:0] K_DISCH_Q30 = 22'sd49038;
	localparam signed [31:0] K_CHG_Q30   = 32'sd2609495;

	logic signed [21:0] vin_q16;
	logic               charging;
	wire  signed [43:0] disch_step = vin_q16 * K_DISCH_Q30;
	wire  signed [53:0] chg_step   = (V_TGT_Q16 - vin_q16) * K_CHG_Q30;
	wire  signed [21:0] vin_dis = vin_q16 - 22'(disch_step >>> 30);
	wire  signed [21:0] vin_chg = vin_q16 + 22'(chg_step   >>> 30);

	assign dbg_warble = charging;

	// ---------------------------------------------------------------
	// Relaxation cells. u = integrator output normalised to the Schmitt
	// window (0 = 4.311 V, 1 = 7.266 V), Q24, signed so overshoot can be
	// carried across the reversal. up = Schmitt output high (TR on, sinking):
	//   cell 1: up rate 346.996*Vin /s, down rate 170.909*Vin /s
	//   cell 2: both 195.833*Vin /s
	// Per-sample step = k/fs * Vin; Kq = k/fs*256 in Q16 so step_q24 = Kq*vin_q16 >> 16.
	//   cell 1 up  7.2292e-3 -> 121,287     cell 1 down 3.5606e-3 -> 59,738
	//   cell 2     4.0798e-3 -> 68,450
	// Overshoot carried through the reversal scaled by the ratio of the two
	// slopes (constant, since both scale with Vin): cell 1 top 0.4925 ~ 1/2-1/128,
	// bottom 2.030 ~ 2+1/32.
	// ---------------------------------------------------------------
	localparam signed [31:0] K1_UP_Q16   = 32'sd121287;
	localparam signed [31:0] K1_DN_Q16   = 32'sd59738;
	localparam signed [31:0] K2_Q16      = 32'sd68450;
	localparam signed [27:0] U_ONE       = 28'sd16777216;

	logic signed [27:0] u1, u2;
	logic               up1, up2;
	wire signed [53:0] inc1_p = (up1 ? K1_UP_Q16 : K1_DN_Q16) * vin_q16;
	wire signed [53:0] inc2_p = K2_Q16 * vin_q16;
	wire signed [27:0] inc1   = 28'(inc1_p >>> 16);
	wire signed [27:0] inc2   = 28'(inc2_p >>> 16);
	wire signed [27:0] u1_n   = up1 ? u1 + inc1 : u1 - inc1;
	wire signed [27:0] u2_n   = up2 ? u2 + inc2 : u2 - inc2;

	// Schmitt outputs after C31/C14 (DC removed) and IC11-C, in 4096 LSB/V:
	//   cell 1 high +0.3117 V (1277), low -0.1535 V (-629)   [duty 33 % high, mean removed]
	//   cell 2 +-0.2652 V (+-1086)
	wire signed [15:0] tone1 = up1 ? 16'sd1277 : -16'sd629;
	wire signed [15:0] tone2 = up2 ? 16'sd1086 : -16'sd1086;
	wire signed [15:0] tone_mix = tone1 + tone2;

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			vin_q16  <= V_HI_Q16;
			charging <= 1'b0;
			u1 <= 28'sd0; u2 <= 28'sd0; up1 <= 1'b1; up2 <= 1'b1;
		end else if (sample_ce) begin
			if (charging) begin
				vin_q16 <= vin_chg;
				if (vin_chg >= V_HI_Q16) charging <= 1'b0;
			end else begin
				vin_q16 <= vin_dis;
				if (vin_dis <= V_LO_Q16) charging <= 1'b1;
			end
			if (up1 && u1_n >= U_ONE) begin
				up1 <= 1'b0;
				u1  <= U_ONE - ((u1_n - U_ONE) >>> 1) + ((u1_n - U_ONE) >>> 7);
			end else if (!up1 && u1_n <= 28'sd0) begin
				up1 <= 1'b1;
				u1  <= (-u1_n <<< 1) + ((-u1_n) >>> 5);
			end else u1 <= u1_n;
			if (up2 && u2_n >= U_ONE) begin
				up2 <= 1'b0;  u2 <= U_ONE - (u2_n - U_ONE);
			end else if (!up2 && u2_n <= 28'sd0) begin
				up2 <= 1'b1;  u2 <= -u2_n;
			end else u2 <= u2_n;
		end
	end

	// IC36 VCA envelope. CONT is driven by an IC4 unity-gain follower fed from the
	// R58/R59/R57/C13/D10 network off /AMBU; it is not on the audio summing node:
	//
	//   /AMBU --RA4 4.7K^5V-- IC44 (7417 open-collector, pin 9->8)
	//         --R56 1K^5V-- D10 --R57 820K-- NODE_B --R59 150K-- NODE_A
	//   NODE_B: C13 3.3uF to ground.  NODE_A: R58 1M to +5V.
	//   NODE_A --> IC4 unity-gain follower --> IC36 pin 6 (CONT).
	//
	// D10's cathode faces IC44, so when /AMBU is asserted the diode discharges C13 into
	// IC44's output. C13 is 3.3 uF (the BOM's 33 uF positions are all taken elsewhere).
	//
	// Steady states, 0.7 V diode drop:
	//   rest (/AMBU high): D10 reverse-biased, no current -> NODE_A = 5.000 V
	//   asserted (/AMBU low, IC44 sinks to 0 V):
	//     NODE_B = (5/1.15M + 0.7/820K) / (1/1.15M + 1/820K) = 2.4899 V
	//     I      = (5 - 2.4899)/1.15M                       = 2.1827 uA
	//     NODE_A = 5 - I*1M                                 = 2.8173 V
	//
	// Time constants at C13 = 3.3 uF, fs = clk_sys/832 = 47,998.875 Hz:
	//   attack  (D10 on):  1.15M || 820K = 478.68K -> tau = 1.5796 s
	//                      a = exp(-1/(fs*tau)) = 0.99998681 -> Q24 16776995
	//   release (D10 off): 1.15M                   -> tau = 3.7950 s
	//                      a = 0.99999451 -> Q24 16777124
	//
	// Through the MC3340 LUT: CONT 5.000 V is LUT[48] = 29 (-67 dB, inaudible) at rest;
	// CONT 2.817 V is in the flat region below the 3.06 V knee (+13 dB) when asserted:
	// silent at rest, full gain when triggered, with a 1.58 s fade-in and 3.80 s fade-out.
	//
	// VR5 is modelled once, in audio_top.sv's trimmer block, not here.
	// SCALE = 4096*256 = 1,048,576 LSB/V, matching turbo_crash_chan.sv.
	localparam signed [26:0] CONT_REST_SCALED = 27'sd5242880;  // 5.0000V
	localparam signed [26:0] CONT_ON_SCALED   = 27'sd2954113;  // 2.8173V
	localparam signed [26:0] V2_MIN_SCALED    = 27'sd2097152;  // 2.0V
	localparam signed [26:0] V2_MAX_SCALED    = 27'sd6291456;  // 6.0V

	localparam signed [26:0] A_ATTACK_Q24  = 27'sd16776995;
	localparam signed [26:0] B_ATTACK_Q24  = 27'sd221;   // 16777216 - A
	localparam signed [26:0] A_RELEASE_Q24 = 27'sd16777124;
	localparam signed [26:0] B_RELEASE_Q24 = 27'sd92;    // 16777216 - A

	logic signed [26:0] env;

	wire signed [55:0] env_atk_next = ($signed(A_ATTACK_Q24)  * $signed(env)
									  + $signed(B_ATTACK_Q24)  * $signed(CONT_ON_SCALED))   >>> 24;
	wire signed [55:0] env_rel_next = ($signed(A_RELEASE_Q24) * $signed(env)
									  + $signed(B_RELEASE_Q24) * $signed(CONT_REST_SCALED)) >>> 24;
	wire signed [26:0] env_next = ambu_n ? 27'(env_rel_next) : 27'(env_atk_next);

	// MC3340 VCA gain LUT: same table, indexing and interpolation as turbo_crash_chan.sv
	// (65 points, V2 = 2.0..6.0 V in 0.0625 V steps). CONT feeds it directly; unlike
	// CRASH.S there is no (5+Vcap)/2 divider here.
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

	function automatic logic signed [20:0] ambu_vca_gain(input logic signed [26:0] v2_in);
		logic signed [26:0] v2_clamped;
		logic        [26:0] v2_off;
		logic        [6:0]  lut_idx;
		logic signed [16:0] lut_frac;
		logic        [31:0] gain_lo, gain_hi;
		logic signed [20:0] gain_base, gain_delta;
		logic signed [37:0] interp;
		begin
			v2_clamped = (v2_in < V2_MIN_SCALED) ? V2_MIN_SCALED :
						 (v2_in > V2_MAX_SCALED) ? V2_MAX_SCALED : v2_in;
			v2_off     = v2_clamped - V2_MIN_SCALED;
			lut_idx    = v2_off[22:16];
			lut_frac   = $signed({1'b0, v2_off[15:0]});
			gain_lo    = VCA_GAIN_LUT[lut_idx];
			gain_hi    = VCA_GAIN_LUT[lut_idx + 7'd1];
			gain_base  = 21'($signed({1'b0, gain_lo}));
			gain_delta = 21'($signed({1'b0, gain_hi}) - $signed({1'b0, gain_lo}));
			interp     = $signed(gain_delta) * $signed(lut_frac);
			ambu_vca_gain = gain_base + 21'(interp >>> 16);
		end
	endfunction

	// Pipelined as in turbo_crash_chan.sv: `gain_q16` is registered from this cycle's
	// pre-update `env`, and the output is computed from `gain_q16`'s pre-update value, so
	// no assignment chains two multiplies combinationally in one clk_sys edge.
	logic signed [20:0] gain_q16;

	wire signed [36:0] vca_prod  = $signed(tone_mix) * $signed(gain_q16);
	wire signed [36:0] vca_out   = vca_prod >>> 16;
	wire signed [15:0] vca_sat   = (vca_out >  37'sd32767) ? 16'sd32767 :
								   (vca_out < -37'sd32768) ? 16'sh8000  :
								   vca_out[15:0];

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			env                 <= CONT_REST_SCALED;
			gain_q16            <= 21'sd9;   // LUT floor, idle CONT = 5.0V
			turbo_ambulance_mix <= 16'sd0;
		end else if (sample_ce) begin
			env                 <= env_next;
			gain_q16            <= ambu_vca_gain(env);
			turbo_ambulance_mix <= vca_sat;
		end
	end

endmodule
