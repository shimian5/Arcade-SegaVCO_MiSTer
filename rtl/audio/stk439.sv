// Behavioral fixed-point model of one Sanyo STK439 channel on Turbo's separate
// 834-0121 power-amplifier board. audio_top.sv instantiates it independently for Upright
// Upper and Upright Lower.
//
// Input topology:
//   mixer -> 25K volume pot -> R1 1K -> C1 0.47uF -> STK439 input
//                                                           |
//                                                         R2 220K
//                                                           |
//                                                         ground
//
// The pot is upstream of R1/C1. For an ideal divider at fraction k,
// Vth = k*Vin, Rth = 25K*k*(1-k), and the modelled coupling pole is
// fc = 1/(2*pi*C1*(R2+R1+Rth)); R2 is the DC return for C1. C2 = 680pF with R1 is an
// RF pole far above the audio band and the Rg/C3 12K/220uF corner (~0.06 Hz) is far
// below it, so both are omitted.
//
// STK feedback is Rf = 390K, Rg = 12K: Av = 1 + 390K/12K = 33.5 = 30.501 dB.
// The Upright Upper has two 4-ohm speakers in series (8 ohms); the Upright Lower has one
// 8-ohm speaker, so both channels use the 8-ohm data-sheet reference. The 15 W into
// 8 ohms rating is a nominal 1%-THD behavioral saturation point, not an exact rail:
//   Vnominal_peak = sqrt(2*15W*8ohm) = 15.4919 V peak.
// With 4096 internal counts/V and 32767 at that peak:
//   c = 32767/(15.4919*4096) = 0.5163820203 codes/V
//   Av*c = 17.29879768 normalized codes/input-code
//   AVC_Q16 = round(Av*c*65536) = 1,133,694.
//
// POT_K_Q16 is the panel-pot setting (an assumption, not a measured value); A_HP_Q24
// is the matching coupling coefficient. If POT_K_Q16 changes, recompute Rth, Rseen,
// fc and A_HP_Q24 from the equations above. Upper and Lower use the same setting.
//
// Fixed point: mixer values are 4096 counts/V. The coupling state is Q32 (2^32 counts/V):
// y[n] = a*(y[n-1]+Vth[n]-Vth[n-1]), with fs = 39,935,064/832 = 47,998.875 Hz and
// A_HP_Q24 = round(a*2^24). The output multiply is Q32*Q16 and shifts by 36 to normalized
// PCM codes. Products are widened before shifting and signed rounding is symmetric.
//
// raw_out is the wide normalized value before the 16-bit clip; clip and clip_count are
// per-instance headroom diagnostics.
module stk439 #(
	parameter int POT_K_Q16 = 9438,       // k=0.14401, presentation only
	parameter int A_HP_Q24  = 16773898    // fc=1.51118 Hz for default k
) (
	input  logic               clk,
	input  logic               rst_n,
	input  logic               sample_ce,
	input  logic signed [15:0] mix_in,     // 4096 LSB = 1 V at mixer bus
	output logic signed [15:0] audio_out,
	output logic signed [63:0] raw_out,    // pre-clip normalized PCM code
	output logic               clip,
	output logic        [31:0] clip_count
);

	// Physical input values for the selected pot setting.
	localparam int R_POT_OHM = 25000;
	localparam int R1_OHM    = 1000;
	localparam int R2_OHM    = 220000;
	localparam int C1_NF     = 470;
	localparam longint RTH_OHM_Q16 =
		(longint'(R_POT_OHM) * longint'(POT_K_Q16) *
		 (longint'(65536) - longint'(POT_K_Q16))) >>> 16;
	localparam longint RSEEN_OHM_Q16 =
		((longint'(R1_OHM) + longint'(R2_OHM)) <<< 16) + RTH_OHM_Q16;

	// Physical gain/normalization values. Both Upright channels are 8 ohms.
	localparam int R_LOAD_OHM = 8;
	localparam int P_NOMINAL_W_8OHM = 15;
	localparam signed [26:0] AVC_Q16 = 27'sd1133694;

	// Vth=k*Vin in the house format. The product is widened so no 16-bit
	// intermediate can wrap before the divider shift.
	wire signed [63:0] pot_prod = 64'(mix_in) * 64'(POT_K_Q16);
	wire signed [63:0] pot_round =
		(pot_prod >= 0) ? (pot_prod + 64'sd32768) :
						  (pot_prod - 64'sd32768);
	wire signed [47:0] vth_house = 48'(pot_round >>> 16);
	wire signed [47:0] vth_q32 = 48'(vth_house) <<< 20;

	// Timing-closure pipeline register: mix_in changes only on sample_ce and is stable for
	// ~831 clocks before the next one, so a free-running register after the pot multiply is
	// bit-identical at every sample_ce while splitting the long mix_in -> pot multiply ->
	// hp_sum -> coefficient multiply -> y path in two.
	logic signed [47:0] vth_q32_r;
	always_ff @(posedge clk) vth_q32_r <= vth_q32;

	logic signed [47:0] vth_d;
	logic signed [47:0] y;

	wire signed [49:0] y_ext     = $signed({{2{y[47]}}, y});
	wire signed [49:0] vth_ext   = $signed({{2{vth_q32_r[47]}}, vth_q32_r});
	wire signed [49:0] vth_d_ext = $signed({{2{vth_d[47]}}, vth_d});
	wire signed [49:0] hp_sum = y_ext + vth_ext - vth_d_ext;

	// Width: hp_sum is 50 bits and the coefficient a positive 25-bit value, so the exact
	// signed product needs 75 bits; no truncation occurs, and the narrow width avoids
	// unnecessary multiplier/carry columns on the state-update path. The explicit casts
	// keep the multiply signed.
	wire signed [74:0] hp_prod = 75'(A_HP_Q24) * 75'(hp_sum);
	wire signed [74:0] hp_round =
		(hp_prod >= 0) ? (hp_prod + 75'sd8388608) :
						  (hp_prod - 75'sd8388608);
	wire signed [47:0] y_next = 48'(hp_round >>> 24);

	// The registered output uses the pre-update coupling state. The full-width value is
	// kept for clipping and raw_out. AVC_Q16 (27 bits) times y (48 bits) also fits in 75
	// bits, matching hp_prod's narrow signed form.
	wire signed [74:0] out_prod = 75'(AVC_Q16) * 75'(y);
	wire signed [74:0] out_round =
		(out_prod >= 0) ? (out_prod + 75'sd34359738368) :
						  (out_prod - 75'sd34359738368);
	wire signed [74:0] out_full = out_round >>> 36;
	wire out_is_clip = (out_full > 75'sd32767) ||
					   (out_full < -75'sd32768);
	wire signed [15:0] out_sat =
		(out_full > 75'sd32767)  ? 16'sd32767 :
		(out_full < -75'sd32768) ? 16'sh8000  :
		out_full[15:0];

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			vth_d      <= '0;
			y          <= '0;
			audio_out  <= '0;
			raw_out    <= '0;
			clip       <= 1'b0;
			clip_count <= '0;
		end else if (sample_ce) begin
			vth_d     <= vth_q32_r;
			y         <= y_next;
			audio_out <= out_sat;
				// The widened value is far below the 75-bit product range; saturation
				// still uses it before the 16-bit clip.
			raw_out <= out_full[63:0];
			clip    <= out_is_clip;
			if (out_is_clip)
				clip_count <= clip_count + 32'd1;
		end
	end

endmodule
