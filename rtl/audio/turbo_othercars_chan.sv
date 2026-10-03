// Turbo OTHER CARS + OTHER CAR OSC channel (D-5/11 + D-6/11).
//
// D-6/11 hosts three always-running relaxation oscillators (IC14 A/B, IC13 A/B,
// IC13 C/D), each a Schmitt-comparator-driven integrator astable with a
// grounded-emitter NPN (TR8/TR7/TR10, 2SC458) discharging the integrator's summing
// node through a collector resistor. The transistor is a hard switch (deep
// saturation), so the frequency follows from R and C alone; no hFE/Vbe is needed.
// Each oscillator's audio tap is the integrator output (an asymmetric triangle),
// not the comparator square. The three taps sum through a passive network (R148/
// R150 = 3.3K, R149 = 10K, R147 = 1K to the virtual ground) into IC14-C (gain
// R332/R147 = 3.9K/1K), giving the composite "OTHER CAR" tone.
//
// The oscillator bias (D-5/11 R169 = 33K / R168 = 10K off 12 V, via IC4) is fixed,
// so frequency and amplitude do not depend on OSEL, and the three oscillators are
// permanently summed; there is no oscillator-select mux on the board.
//
// What OSEL does: the single composite tone is broadcast through a DC-blocking cap
// onto the IN pins of four MB4391 VCAs (F/L/R/W). IC40 (6330 PROM) is addressed by
// {DIP, OSEL2, OSEL1, OSEL0}; its byte, split into four 2-bit fields, sets each
// VCA's CONT bias through an IC32/IC12 buffer-and-shape chain. Each channel has
// three reachable gain states (mute / -6 dB / full); the fourth encoding never
// occurs in the PROM data. This module implements that decode as four gain-shaped
// taps (othercars_f/l/r/w).
//
// The idle-high OSEL default (address 7, or 15 with the DIP set) decodes to PROM
// byte 0x00: all four channels muted, which is why the real board is silent in
// attract mode.
module turbo_othercars_chan (
	input  logic               clk,
	input  logic               rst_n,
	input  logic                osel0,   // active-high
	input  logic                osel1,
	input  logic                osel2,
		// DIP "Sound System" bit (segavco.v's turbo_dsw3[7]; mra bit23):
		// 0 = Cockpit/4-speaker, 1 = Upright/2-speaker; selects the PROM's upper half.
	input  logic                dsw3_7,
	input  logic               sample_ce,
	output logic signed [15:0] othercars_f,
	output logic signed [15:0] othercars_l,
	output logic signed [15:0] othercars_r,
	output logic signed [15:0] othercars_w,
	output logic signed [15:0] dbg_osc_a,
	output logic signed [15:0] dbg_osc_b,
	output logic signed [15:0] dbg_osc_c,
	output logic         [16:0] dbg_gain_f_q16,
	output logic         [16:0] dbg_gain_l_q16,
	output logic signed [15:0] dbg_tone_sum
);

	// Three always-running triangle oscillators (D-6/11). Counter-authoritative timing: a
	// phase counter counts N_UP then N_DOWN clk_sys cycles (39,935,064 Hz), toggling
	// `rising`; a Q16 accumulator ramps between the thresholds and is snapped to the
	// exact +-A endpoint on every toggle, so the counter (not the accumulator) sets
	// frequency and step-rounding shows only as a kink at the peaks, never as drift.
	// A, STEP_UP and STEP_DOWN are in LSB (4096 LSB/V). Amplitudes (2686/5031/1660) and
	// duties are the schematic nominals; the three N_UP/N_DOWN/STEP pairs sit inside
	// the component tolerance band around the nominal frequencies (A 83 Hz -> 77.1 Hz,
	// B 195 Hz -> 202.3 Hz, C 211 Hz -> 202.4 Hz); that tolerance choice is an assumption.
	logic signed [15:0] osc_a, osc_b, osc_c;

	turbo_othercars_osc #(
		.N_UP(235347), .N_DOWN(282416), .A(2686), .STEP_UP(1496), .STEP_DOWN(1247)
	) u_osc_a (.clk(clk), .rst_n(rst_n), .out(osc_a));

	turbo_othercars_osc #(
		.N_UP(73109), .N_DOWN(124286), .A(5031), .STEP_UP(9020), .STEP_DOWN(5306)
	) u_osc_b (.clk(clk), .rst_n(rst_n), .out(osc_b));

	turbo_othercars_osc #(
		.N_UP(89448), .N_DOWN(107864), .A(1660), .STEP_UP(2432), .STEP_DOWN(2017)
	) u_osc_c (.clk(clk), .rst_n(rst_n), .out(osc_c));

	assign dbg_osc_a = osc_a;
	assign dbg_osc_b = osc_b;
	assign dbg_osc_c = osc_c;
	assign dbg_tone_sum = tone_sum;

	// Sum all three (no select, see header). Each oscillator's `A` already includes the
	// summing-network weight and the R332/R147 output gain, so the outputs are simply
	// added. The worst-case sum (+-9377) cannot overflow 16 bits; the saturating add
	// is kept as a guard.
	wire signed [17:0] tone_sum_ext = $signed({{2{osc_a[15]}}, osc_a})
									 + $signed({{2{osc_b[15]}}, osc_b})
									 + $signed({{2{osc_c[15]}}, osc_c});
	wire signed [15:0] tone_sum = (tone_sum_ext[17:15] == 3'b000 || tone_sum_ext[17:15] == 3'b111)
								 ? tone_sum_ext[15:0]
								 : (tone_sum_ext[17] ? 16'sh8000 : 16'sh7FFF);

	// IC40 PROM decode: 16 bytes of the pr-1279.sound-ic40 ROM (32 bytes, upper half all
	// FF, CRC32 0xb369a6ae), hard-coded here because the segavco.v proms blob is not
	// forwarded to this module.
	localparam bit [7:0] PROM_TABLE [0:15] = '{
		8'h02, 8'h29, 8'h05, 8'h84, 8'h11, 8'h90, 8'h68, 8'h00,
		8'h02, 8'h81, 8'h81, 8'h42, 8'h81, 8'h42, 8'h40, 8'h00
	};

	wire [3:0] prom_addr = {dsw3_7, osel2, osel1, osel0};
	wire [7:0] prom_byte = PROM_TABLE[prom_addr];

	// Per-channel 2-bit fields -> 3-level gain. Not monotonic in the raw field value:
	// 01 (12K leg, node less pulled down) is louder than 10 (10K leg), so do not "tidy"
	// this into a `>` comparison. `11` never occurs in the ROM; it maps to full gain
	// rather than being left undefined. Gains are Q16: 0 = mute, 32768 = -6 dB,
	// 65536 = full. The gain path is signed throughout (18 bits).
	function automatic logic signed [17:0] othercars_field_gain_q16(input logic [1:0] field);
		case (field)
			2'b00:   othercars_field_gain_q16 = 18'sd0;      // mute
			2'b01:   othercars_field_gain_q16 = 18'sd65536;  // full
			2'b10:   othercars_field_gain_q16 = 18'sd32768;  // -6dB, soft
			default: othercars_field_gain_q16 = 18'sd65536;  // 11: unreachable, full
		endcase
	endfunction

	wire signed [17:0] gain_f_target = othercars_field_gain_q16(prom_byte[1:0]);
	wire signed [17:0] gain_l_target = othercars_field_gain_q16(prom_byte[3:2]);
	wire signed [17:0] gain_r_target = othercars_field_gain_q16(prom_byte[5:4]);
	wire signed [17:0] gain_w_target = othercars_field_gain_q16(prom_byte[7:6]);

	// ~0.47 Hz CONT crossfade (C46/C45 = 3.4 uF non-polar pair + R137 = 100K), modelled as
	// a one-pole smoother per channel run at sample_ce (47,999.4 Hz): coefficient 2^-14
	// gives tau = 16384 samples = 0.3413 s without a multiplier. An abrupt step would click.
	//
	// The gain path is signed so that a downward step (negative delta) subtracts; an
	// unsigned operand would force the whole `+` expression unsigned.
	//
	// The state is carried at Q24 (8 fractional bits below the Q16 used elsewhere): at
	// Q16 the increment `(target - gain) >>> 14` truncates to zero within 16384 LSB of
	// the target (a 25 % dead zone, asymmetric because `>>>` floors negative values), so
	// the gain could mute fully but never fully un-mute. At Q24 the dead zone is 64 Q16
	// LSB (0.1 % of full gain); tau is unchanged.
	localparam int GAIN_SHIFT = 14;
	localparam int Q24_SHIFT  = 8;   // Q16 target -> Q24 state

	// 65536 << 8 = 16,777,216 needs 25 magnitude bits, +1 for sign.
	logic signed [25:0] gain_f_q24, gain_l_q24, gain_r_q24, gain_w_q24;

	wire signed [25:0] target_f_q24 = 26'($signed(gain_f_target)) <<< Q24_SHIFT;
	wire signed [25:0] target_l_q24 = 26'($signed(gain_l_target)) <<< Q24_SHIFT;
	wire signed [25:0] target_r_q24 = 26'($signed(gain_r_target)) <<< Q24_SHIFT;
	wire signed [25:0] target_w_q24 = 26'($signed(gain_w_target)) <<< Q24_SHIFT;

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			gain_f_q24 <= 26'sd0;
			gain_l_q24 <= 26'sd0;
			gain_r_q24 <= 26'sd0;
			gain_w_q24 <= 26'sd0;
		end else if (sample_ce) begin
			gain_f_q24 <= gain_f_q24 + ((target_f_q24 - gain_f_q24) >>> GAIN_SHIFT);
			gain_l_q24 <= gain_l_q24 + ((target_l_q24 - gain_l_q24) >>> GAIN_SHIFT);
			gain_r_q24 <= gain_r_q24 + ((target_r_q24 - gain_r_q24) >>> GAIN_SHIFT);
			gain_w_q24 <= gain_w_q24 + ((target_w_q24 - gain_w_q24) >>> GAIN_SHIFT);
		end
	end

	// Q24 state -> the Q16 the VCA multiply below speaks.
	wire signed [17:0] gain_f_q16 = 18'(gain_f_q24 >>> Q24_SHIFT);
	wire signed [17:0] gain_l_q16 = 18'(gain_l_q24 >>> Q24_SHIFT);
	wire signed [17:0] gain_r_q16 = 18'(gain_r_q24 >>> Q24_SHIFT);
	wire signed [17:0] gain_w_q16 = 18'(gain_w_q24 >>> Q24_SHIFT);

	assign dbg_gain_f_q16 = gain_f_q16[16:0];
	assign dbg_gain_l_q16 = gain_l_q16[16:0];

	// Apply each smoothed Q16 gain to the summed tone: one multiply per sample, registered
	// at sample_ce, so no shared_mul_pool client is needed.
	function automatic logic signed [15:0] apply_gain(input logic signed [15:0] tone, input logic signed [17:0] gain_q16);
		logic signed [33:0] prod;
		begin
			prod = $signed({tone[15], tone}) * gain_q16;
			apply_gain = prod[31:16];
		end
	endfunction

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			othercars_f <= 16'sd0;
			othercars_l <= 16'sd0;
			othercars_r <= 16'sd0;
			othercars_w <= 16'sd0;
		end else if (sample_ce) begin
			othercars_f <= apply_gain(tone_sum, gain_f_q16);
			othercars_l <= apply_gain(tone_sum, gain_l_q16);
			othercars_r <= apply_gain(tone_sum, gain_r_q16);
			othercars_w <= apply_gain(tone_sum, gain_w_q16);
		end
	end

endmodule

// Single triangle-wave relaxation-oscillator model for D-6/11's three OTHER CAR VCO
// branches (see turbo_othercars_chan's header); N_UP/N_DOWN are phase lengths in clk_sys
// cycles and A/STEP_UP/STEP_DOWN are per-instance constants in LSB.
module turbo_othercars_osc #(
	parameter int N_UP      = 1,
	parameter int N_DOWN    = 1,
	parameter int A         = 1,
	parameter int STEP_UP   = 1,
	parameter int STEP_DOWN = 1
)(
	input  logic clk,
	input  logic rst_n,
	output logic signed [15:0] out
);

	localparam int MAX_N = (N_UP > N_DOWN) ? N_UP : N_DOWN;
	localparam int CNT_W = $clog2(MAX_N + 1);

	logic [CNT_W-1:0]   cnt;
	logic                rising;
	logic signed [31:0] tri_q16;

	wire signed [31:0] a_q16 = $signed(32'(A)) <<< 16;

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			cnt     <= '0;
			rising  <= 1'b1;
			tri_q16 <= -a_q16;
		end else begin
			logic at_top;
			at_top = rising ? (cnt == CNT_W'(N_UP - 1)) : (cnt == CNT_W'(N_DOWN - 1));
			if (at_top) begin
				cnt     <= '0;
				rising  <= ~rising;
				tri_q16 <= rising ? a_q16 : -a_q16;
			end else begin
				cnt     <= cnt + 1'b1;
				tri_q16 <= tri_q16 + (rising ? $signed(32'(STEP_UP)) : -$signed(32'(STEP_DOWN)));
			end
		end
	end

	assign out = tri_q16[31:16];

endmodule
