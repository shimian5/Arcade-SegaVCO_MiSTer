// Turbo Mixer MUTE -- D-11/11's own power-on delay (IC42).
//
// Not the same circuit as Buck Rogers' mute_ctl.sv despite the similar
// "power-on delay mute" behaviour:
//
//   | | Buck (mute_ctl.sv) | Turbo (this module) |
//   |---|---|---|
//   | mechanism | LA4460 pin 6 DC-mute, infinite attenuation | 4016 shorting each mixer's feedback resistor |
//   | timing | comparator crossing an RC | 74LS123 one-shot |
//   | game-state term | yes -- GAME ON wire-ORed in | none -- purely power-on |
//   | output polarity | active low | active high |
//
// Generator (D-11/11): IC42 = 74LS123 (dual monostable, one half used).
// B (pin 10) and /CLR (pin 11) are tied to +5 V and A (pin 9) to ground, as drawn,
// so B's rise at power-on fires the one-shot.
// Timing network R286=220K/C137=33uF on Rext/Cext.
//
//   t_w = 0.45 * R * C = 0.45 * 220e3 * 33e-6 = 3.267 s
//       = 3.267 * 39,935,064 = 130,467,854 clk_sys cycles
//
// Q-bar of the one-shot feeds R275=1K pull-up / D32 / TR11's base (R285=2.2K
// to ground, emitter grounded) / TR11's collector = MUTE, pulled to +12V by
// R284=10K. During the pulse Q-bar is low, D32 is reverse-biased, TR11 is
// off and MUTE is HIGH; after the pulse Q-bar goes high, D32 conducts, TR11
// saturates and MUTE goes LOW. So MUTE is ACTIVE HIGH for ~3.27s from
// power-on, then low.
//
// MUTE drives IC45's four 4016 sections on D-11/11, each wired ACROSS a bus's
// 100K feedback resistor (F/W/R/L), plus D-7/11's IC30 across the M bus's
// feedback. Closing a 4016 shorts that resistor and collapses the bus gain
// to ~-40dB (R_on ~150-300 ohm against 22K); modelled as a hard zero via
// turbo_mixer.sv's `mute` port, which zeroes all five bus outputs. It is a
// gain collapse on each bus, not a gate upstream of the mixer.
//
// RESET MODELS POWER-ON (same deliberate deviation as mute_ctl.sv): a core
// reset re-arms the full 3.27s mute, whereas the real 74LS123 triggers only
// on the 5V rail rising.
module turbo_mute_ctl (
	input  logic clk,
	input  logic rst_n,
	output logic mute    // 1 = muted (active HIGH, opposite of Buck's dc_mute)
);

	localparam int unsigned POWERON_CYCLES = 130467854;
	localparam int CNT_W = 28;  // 2^27=134,217,728 > POWERON_CYCLES, +1 for headroom

	logic [CNT_W-1:0] poweron_cnt;
	logic             poweron_done;

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			poweron_cnt  <= '0;
			poweron_done <= 1'b0;
		end else if (!poweron_done) begin
			if (poweron_cnt == CNT_W'(POWERON_CYCLES - 1))
				poweron_done <= 1'b1;
			else
				poweron_cnt <= poweron_cnt + 1'b1;
		end
	end

	assign mute = !poweron_done;

endmodule
