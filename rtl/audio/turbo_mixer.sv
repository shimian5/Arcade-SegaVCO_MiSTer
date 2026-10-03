// Turbo Mixer I (D-11/11) + Mixer II (D-7/11).
//
// Each bus (F/W/R/L on Mixer I, M on Mixer II) is a passive summing node -> 22K series
// -> LF351 inverting stage with a 100K feedback (a 4016 across the feedback implements
// MUTE). D-11/11 is annotated "R: 100K x 19": every input is 100K unless individually
// annotated; four inputs differ: OCAR.F (R280 = 22K), AMBULANCE (R276 = 22K), OCAR.R
// (R309 = 22K) and SLF (R303 = 68K, W bus only). The per-input gain therefore depends on
// how many inputs load that particular bus's node, not on one shared gain. Mixer II
// (D-7/11) has the same topology with a uniform 100K on each of its 12 M-bus inputs
// (R218 = 22K series, R230 = 100K feedback).
//
//   coeff = (G_i / SUM(G)) x (100K/22K), G_i = 1/100K for a normal input,
//   1/22K (or 1/68K for SLF) for an annotated exception.
//
// The Q16 constants below are round(coeff * 65536):
//
//     F: normal 0.2315 (Alarm/Skid/Crash.S/PlayerCar.F),
//        exception 1.0522 (OCAR.F, AMBULANCE)
//     W: normal 0.4126 (Crash.L/OCAR.W/PlayerCar.W),
//        exception 0.6068 (SLF, switched C108 transient)
//     R: normal 0.4098 (Alarm/Skid), exception 1.8629 (OCAR.R)
//     L: uniform 0.6024 (Alarm/Skid/OCAR.L; no exception on this bus)
//     M: uniform 0.274725 (Q16 18004): twelve fitted 100K legs, R218 = 22K input and
//        R230 = 100K feedback. The ten RTL sources all use this weight; the other two
//        fitted legs only contribute loading.
//
// The buses differ in gain (0.23 on F vs 0.60 on L), and OCAR.R (1.863x) and OCAR.F
// (1.052x) are the hottest paths, so Other Cars is deliberately hot on F/R when it plays.
//
// Per-channel bus assignment, read from D-11/11's input columns:
//
//   Channel      F   W   R   L   M
//   Alarm        x       x   x   x
//   Skid         x       x   x   x
//   Crash.S      x               x  (CRASH.SM)
//   Crash.L          x            x  (CRASH.LM)
//   Ambulance    x               x
//   Other Cars   x   x   x   x   x  (x4, one per spatial tap)
//   Player Car   x   x           x
//
// Each source channel computes one mix value per named tap, which is broadcast into
// every bus the hardware wires it to at that bus's own weight (on the board it is one
// VCA/filter node reaching several buses through independent coupling caps and
// summing resistors).
//
// MUTE: D-11/11 generates MUTE locally via IC42 (74LS123-family monostable, R286 =
// 220K / C137 = 33uF off a power-on 5V rail), a power-on delay mute. `mute` is tied
// inactive by the caller; the power-on delay is not modelled here.
//
// Gain stage: the 100K/22K second-stage ratio is already folded into each input's Q16
// coefficient, so the weighted terms are summed directly into the bus output. Each term
// is one constant multiply registered at sample_ce (47,999.4 Hz), so no shared_mul_pool
// client is needed.
module turbo_mixer (
	input  logic               clk,
	input  logic               rst_n,
	input  logic               sample_ce,
	input  logic                mute,   // board-wide MUTE; see header

	// One tap per channel, each broadcast into every bus D-11/11 feeds (see header table).
	input  logic signed [15:0] alarm_tap,
	input  logic signed [15:0] skid_tap,
	input  logic signed [15:0] crash_s_tap,
	input  logic signed [15:0] crash_l_tap,
	input  logic signed [15:0] ambulance_tap,
	// Other Cars has four independent VCA-gated taps, one per spatial bus: the same summed
	// tone times each bus's own IC40-decoded gain, so these are not duplicates.
	input  logic signed [15:0] othercars_f_tap,
	input  logic signed [15:0] othercars_l_tap,
	input  logic signed [15:0] othercars_r_tap,
	input  logic signed [15:0] othercars_w_tap,
	// Player Car produces distinct F/W/M values.
	input  logic signed [15:0] playercar_f,
	input  logic signed [15:0] playercar_w,
	input  logic signed [15:0] playercar_m,
	// SLF comes from turbo_playercar_chan.sv (IC3-pin7 / IC30 / C108 switched-level path);
	// it is a transient, not a free-running oscillator.
	input  logic signed [15:0] slf_w_tap,

	output logic signed [15:0] mixer2_m_out,
	output logic signed [15:0] mixer1_f_out,
	output logic signed [15:0] mixer1_w_out,
	output logic signed [15:0] mixer1_r_out,
	output logic signed [15:0] mixer1_l_out
);

	// Per-bus Q16 coefficients, round(coeff * 65536).
	localparam logic [17:0] COEFF_F_NORMAL = 18'd15173;  // 0.2315
	localparam logic [17:0] COEFF_F_EXCEPT = 18'd68953;  // 1.0522 (OCAR.F, AMBULANCE)
	localparam logic [17:0] COEFF_W_NORMAL = 18'd27043;  // 0.4126
	localparam logic [17:0] COEFF_W_EXCEPT = 18'd39775;  // 0.6068, SLF
	localparam logic [17:0] COEFF_R_NORMAL = 18'd26855;  // 0.4098
	localparam logic [17:0] COEFF_R_EXCEPT = 18'd122107; // 1.8629 (OCAR.R)
	localparam logic [17:0] COEFF_L_UNIFORM = 18'd39487; // 0.6024
	// Loaded M-bus coefficient: (100K/22K) * (1/100K) / (12/100K + 1/22K) = 0.274725...
	// The denominator counts all twelve fitted 100K legs, including schematic sources that
	// are not RTL inputs.
	localparam logic [17:0] COEFF_M_UNIFORM = 18'd18004; // round(0.274725... * 2^16)

	// wgain: one input's contribution to a bus, still in Q16 so several can be summed in a
	// wide accumulator before a single >>>16 and saturate.
	function automatic logic signed [39:0] wgain(input logic signed [15:0] tap, input logic [17:0] coeff_q16);
		wgain = $signed({{2{tap[15]}}, tap}) * $signed({1'b0, coeff_q16});
	endfunction

	function automatic logic signed [15:0] bus_out(input logic signed [39:0] acc_q16, input logic gate_mute);
		logic signed [39:0] shifted;
		logic signed [15:0] sat;
		begin
			// The real second stage is inverting.
			shifted = -(acc_q16 >>> 16);
			sat = (shifted > 40'sd32767)  ? 16'sd32767 :
				  (shifted < -40'sd32768) ? 16'sh8000  :
				  shifted[15:0];
			bus_out = gate_mute ? 16'sd0 : sat;
		end
	endfunction

	// M: alarm, skid, crash.s (SM), crash.l (LM), ambulance, all four othercars taps
	// (D-7/11's 12-input list), playercar.m, all at the uniform M weight.
	wire signed [39:0] m_sum = wgain(alarm_tap, COEFF_M_UNIFORM) + wgain(skid_tap, COEFF_M_UNIFORM)
							  + wgain(crash_s_tap, COEFF_M_UNIFORM) + wgain(crash_l_tap, COEFF_M_UNIFORM)
							  + wgain(ambulance_tap, COEFF_M_UNIFORM)
							  + wgain(othercars_f_tap, COEFF_M_UNIFORM) + wgain(othercars_l_tap, COEFF_M_UNIFORM)
							  + wgain(othercars_r_tap, COEFF_M_UNIFORM) + wgain(othercars_w_tap, COEFF_M_UNIFORM)
							  + wgain(playercar_m, COEFF_M_UNIFORM);

	// F: alarm, skid, crash.s, playercar.f at normal weight;
	// ambulance, othercars.f at the 22K-exception weight.
	wire signed [39:0] f_sum = wgain(alarm_tap, COEFF_F_NORMAL) + wgain(skid_tap, COEFF_F_NORMAL)
							  + wgain(crash_s_tap, COEFF_F_NORMAL) + wgain(playercar_f, COEFF_F_NORMAL)
							  + wgain(ambulance_tap, COEFF_F_EXCEPT) + wgain(othercars_f_tap, COEFF_F_EXCEPT);

	// W: crash.l, othercars.w, playercar.w at normal weight; SLF at its own exception weight.
	wire signed [39:0] w_sum = wgain(crash_l_tap, COEFF_W_NORMAL) + wgain(othercars_w_tap, COEFF_W_NORMAL)
							  + wgain(playercar_w, COEFF_W_NORMAL)
							  + wgain(slf_w_tap, COEFF_W_EXCEPT);

	// R: alarm, skid at normal weight; othercars.r at the 22K-exception weight (hottest path).
	wire signed [39:0] r_sum = wgain(alarm_tap, COEFF_R_NORMAL) + wgain(skid_tap, COEFF_R_NORMAL)
							  + wgain(othercars_r_tap, COEFF_R_EXCEPT);

	// L: alarm, skid, othercars.l -- uniform weight, no exception on this bus.
	wire signed [39:0] l_sum = wgain(alarm_tap, COEFF_L_UNIFORM) + wgain(skid_tap, COEFF_L_UNIFORM)
							  + wgain(othercars_l_tap, COEFF_L_UNIFORM);

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			mixer2_m_out <= 16'sd0;
			mixer1_f_out <= 16'sd0;
			mixer1_w_out <= 16'sd0;
			mixer1_r_out <= 16'sd0;
			mixer1_l_out <= 16'sd0;
		end else if (sample_ce) begin
			mixer2_m_out <= bus_out(m_sum, mute);
			mixer1_f_out <= bus_out(f_sum, mute);
			mixer1_w_out <= bus_out(w_sum, mute);
			mixer1_r_out <= bus_out(r_sum, mute);
			mixer1_l_out <= bus_out(l_sum, mute);
		end
	end

endmodule
