// Turbo SKID channel (D-3/11): an IC37 555 tone that is frequency-modulated by a slow
// relaxation oscillator (IC1-A) plus filtered S2688 noise (IC1-B), gated by /SLIP
// (IC54 monostable) or /SPIN into an IC18 VCA, then VR1 trim -> SKID.F/R/L/M
// (four identical coupled outputs, modelled as one node).
//
// Signal path:
//   IC1-A  ~15 Hz relaxation oscillator (R1 100k / R2 51k / R43 6.8k / C9 6.8 uF)
//   IC1-B  sums the buffered C9 ramp and the noise (C22 1 uF / R41 200k) and couples
//          it into IC37's CONT pin; the noise reaches the circuit only this way, as
//          modulation of the 555, never as additive audio.
//   IC37   NE555 astable, frequency-modulated through CONT.
//   IC1-D  SLIP/SPIN combiner; its output also drives IC18's CON pin, so the same
//          node that biases the 555 gates the VCA.
//   IC18   MB4391M = two MC3340 attenuators (see the MC3340 Figure 3 curve at 12 V).
//
// Deliberate simplifications:
//   A. Gating is a hard digital `gate` (q_slip | spin). The real combiner is an
//      analog level shaped by R5/R6/R7/D1/C1; only its two steady-state extremes
//      are modelled, as the MC3340 endpoints: V2=2.0 V (flat max gain, 4.4675x) and
//      V2=6.0 V (deep mute, 9/65536 ~ -78 dB). Both are fixed shift/add products
//      (4.5x = (x<<<2)+(x>>>1), 1/8192 = x>>>13); no multiplier is needed.
//   B. The noise source is the single S2688 instance from audio_top.sv passed in
//      through noise_in (its polynomial and amplitude are assumptions documented in
//      turbo_s2688_noise.sv).
//   C. TONE amplitude is an assumption: IC37's swing before VR1 is not computable
//      from the sheet, so TONE_HI/TONE_LO are round mid-scale values.
//   D. VR1 (200K trimmer, wiper unknown) is modelled once, in audio_top.sv; the
//      local RAIL_SHIFT below only keeps the VCA peak inside the board's output rail.
module turbo_skid_chan (
	input  logic               clk,
	input  logic               rst_n,
	input  logic                slip_n,     // /SLIP, active low
	input  logic                spin_n,     // /SPIN, active low
	input  logic               sample_ce,
	input  logic signed [15:0] noise_in,
	output logic signed [15:0] turbo_skid_mix,  // SKID.F/R/L/M (one common node)
	output logic                dbg_q_slip,
	output logic                dbg_gate
);

	// ---------------------------------------------------------------
	// SKID FM chain (D-3/11).  All states are Q24 volts, updated once per audio sample (47,998.875 Hz); the exponential step
	// coefficients are shift/add (no multipliers).
	//   IC1-A: C9 charges toward the comparator output through R43 (tau 46.24 ms); thresholds (100k*6 V + 51k*Vout)/151k =
	//     3.9802 / 7.5199 V for Vout 0.02 / 10.5 V (assumed op-amp output endpoints) -> 15.2 Hz.
	//   IC1-B summer (pin 1), AC about its 6 V bias: -(10k/68k)*(C9 - mean) - (10k/200k)*noise  (R40 10k feedback, R42 68k, R41 200k).
	//   Coupling capacitor (22 uF layout candidate; 33 uF on the handwritten sheet) into IC37 CONT pin 5 against the 555's internal
	//     5k/5k/5k divider (3.333 V behind 3.333k): high-pass corner 2.17 Hz.
	//   IC37 NE555 astable: charge 47k+68k = 115k into C130 0.01 uF toward 5 V, discharge through 68k, thresholds CONT and CONT/2
	//     (CONT = 3.333 V + the coupled signal) -> 788 Hz free-running.
	// At a threshold crossing the overshoot is carried into the next phase (rate ratio 3.375 at the upper trip, 1.17 at the
	// lower trip, nominal CONT) so the carrier is not quantised to whole samples.
	localparam signed [31:0] V_OH_Q24  = 32'sd176160768;      // IC1-A output high (X)
	localparam signed [31:0] V_OL_Q24  = 32'sd335544;      // IC1-A output low  (X)
	localparam signed [31:0] TH_HI_Q24 = 32'sd126162442;   // 7.5199 V
	localparam signed [31:0] TH_LO_Q24 = 32'sd66777764;   // 3.9802 V
	localparam signed [31:0] C9_MID_Q24 = 32'sd96468992;     // mean of the C9 swing: removes the DC of the slow term
	localparam signed [31:0] CON0_Q24  = 32'sd55924053;      // IC37 pin-5 bias (internal divider)
	localparam signed [31:0] VCC5_Q24  = 32'sd83886080;

	logic signed [31:0] vc9, x_sum, x_prev, hp_y, vcon, vt;
	logic               out14, hi;

	// stage A: C9 / IC1-A comparator
	wire signed [31:0] d9    = (out14 ? V_OH_Q24 : V_OL_Q24) - vc9;
	wire signed [31:0] step9 = (d9 >>> 11) - (d9 >>> 15) - (d9 >>> 17) + (d9 >>> 22) + (d9 >>> 24);
	wire signed [31:0] vc9_n = vc9 + step9;

	// stage B: IC1-B summer (ideal op-amp, AC about its bias)
	wire signed [31:0] c9_ac  = vc9 - C9_MID_Q24;
	wire signed [31:0] slow_t = (c9_ac >>> 3) + (c9_ac >>> 6) + (c9_ac >>> 8) + (c9_ac >>> 9);              // 10/68 ~ 0.1465
	wire signed [31:0] n24    = $signed({{16{noise_in[15]}}, noise_in}) <<< 12;                                             // Q12 -> Q24
	wire signed [31:0] noi_t  = (n24 >>> 5) + (n24 >>> 6) + (n24 >>> 9) + (n24 >>> 11);                      // 10/200 ~ 0.0493
	wire signed [31:0] x_n    = -slow_t - noi_t;

	// stage C: pin-5 coupling (high-pass, 2.17 Hz)
	wire signed [31:0] hp_loss = (hp_y >>> 12) + (hp_y >>> 15) + (hp_y >>> 17) + (hp_y >>> 19) - (hp_y >>> 22);
	wire signed [31:0] hp_n    = hp_y + (x_sum - x_prev) - hp_loss;

	// stage D: NE555 timing node (thresholds from the registered CONT)
	wire signed [31:0] vup = vcon;
	wire signed [31:0] vlo = vcon >>> 1;
	wire signed [31:0] dch = VCC5_Q24 - vt;
	wire signed [31:0] vt_c = vt + (dch >>> 6) + (dch >>> 9) + (dch >>> 11) - (dch >>> 13) + (dch >>> 17);   // charge, a = 0.017952
	wire signed [31:0] ddn = -vt;
	wire signed [31:0] vt_d = vt + (ddn >>> 5) - (ddn >>> 10) - (ddn >>> 13) + (ddn >>> 15) - (ddn >>> 17);  // discharge, a = 0.030174
	wire signed [31:0] e_up = vt_c - vup;
	wire signed [31:0] e_dn = vlo - vt_d;

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			vc9 <= 32'sd100663296;                 // 6.0 V
			out14 <= 1'b1;
			x_sum <= 32'sd0; x_prev <= 32'sd0; hp_y <= 32'sd0;
			vcon <= CON0_Q24;
			vt <= 32'sd33554432;                   // 2.0 V
			hi <= 1'b1;
		end else if (sample_ce) begin
			vc9 <= vc9_n;
			if (out14 && vc9_n >= TH_HI_Q24) out14 <= 1'b0;
			else if (!out14 && vc9_n <= TH_LO_Q24) out14 <= 1'b1;

			x_sum  <= x_n;
			x_prev <= x_sum;
			hp_y   <= hp_n;
			vcon   <= CON0_Q24 + hp_y;

			if (hi) begin
				if (vt_c >= vup) begin
					hi <= 1'b0;
					vt <= vup - ((e_up <<< 1) + e_up + (e_up >>> 2) + (e_up >>> 3));
				end else vt <= vt_c;
			end else begin
				if (vt_d <= vlo) begin
					hi <= 1'b1;
					vt <= vlo + (e_dn + (e_dn >>> 3) + (e_dn >>> 5) + (e_dn >>> 6));
				end else vt <= vt_d;
			end
		end
	end

	// 555 output as a zero-mean square (62.8 % nominal high duty; the coupling capacitors remove the DC). The 4 V p-p swing
	// is an assumption (header item C).
	localparam signed [15:0] TONE_HI = 16'sd6095;      //  +0.372 * 16384
	localparam signed [15:0] TONE_LO = -16'sd10289;    //  -0.628 * 16384
	wire signed [15:0] tone_bipolar = hi ? TONE_HI : TONE_LO;

	// ---------------------------------------------------------------
	// SLIP monostable: IC54, one section. Unlabeled 47k/3.3uF Rext/Cext --
	// same values as turbo_crash_chan.sv's CRASH.S (R329=47k/C152=3.3uF),
	// so the same WIDTH_CYCLES applies: 51.2 ms -> 2,044,675 cycles.
	// SPIN has no timing element on this sheet (IC44 is a plain buffer,
	// not a monostable) -- passed through as a raw active-low level.
	// ---------------------------------------------------------------
	logic q_slip;

	ttl_74123 #(.WIDTH_CYCLES(2044675)) u_74123_slip (
		.clk(clk), .rst_n(rst_n), .a_n(slip_n), .q(q_slip));

	wire spin_level = ~spin_n;

	assign dbg_q_slip = q_slip;

	// ---------------------------------------------------------------
	// Gate (header item A)
	// ---------------------------------------------------------------
	wire gate = q_slip | spin_level;
	assign dbg_gate = gate;

	wire signed [17:0] grit_sum18 = {{2{tone_bipolar[15]}}, tone_bipolar};   // tone only; noise acts through the 555 FM

	// ---------------------------------------------------------------
	// IC18's real MC3340 VCA law (see header) -- two fixed-constant
	// endpoints, each a shift/add decomposition, selected by `gate`.
	// grit_sum18 is bounded to +/-10289 by construction (zero-mean tone), so vca_on's peak
	// is bounded to ~10289*4.5 = 46300, comfortably inside signed [20:0].
	// ---------------------------------------------------------------
	wire signed [20:0] grit_ext = {{3{grit_sum18[17]}}, grit_sum18};
	wire signed [20:0] vca_on   = (grit_ext <<< 2) + (grit_ext >>> 1); // ~4.4675x
	wire signed [20:0] vca_off  = grit_ext >>> 13;                    // ~0.000122x
	wire signed [20:0] vca_out  = gate ? vca_on : vca_off;

	// OUTPUT SCALING: VR1 is modelled once in audio_top.sv (TRIM_SKID_Q16), so it is not repeated here. This is a rail
	// normalisation only: vca_on peaks near 58325 LSB, above the board's +-4.5 V limit (+-18432 LSB at 4096 LSB/V); /4 keeps
	// the peak inside the rail.
	localparam int RAIL_SHIFT = 2; // /4

	// Sign-extend into an explicitly-signed wire first: a bare concatenation is unsigned in SystemVerilog, so `>>>` on it
	// would become a logical shift.
	wire signed [22:0] vca_out_ext = {{2{vca_out[20]}}, vca_out};
	wire signed [22:0] trim23 = -(vca_out_ext >>> RAIL_SHIFT);
	wire signed [15:0] trim_sat =
		(trim23 > 23'sd32767)  ? 16'sd32767  :
		(trim23 < -23'sd32768) ? 16'sh8000 :
		trim23[15:0];

	always_ff @(posedge clk) begin
		if (!rst_n) turbo_skid_mix <= 16'sd0;
		else        turbo_skid_mix <= trim_sat;
	end

endmodule
