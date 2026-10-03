// SPDX-License-Identifier: MIT
//
// Reduced electrical boundary for the D8 player-car source (sheet D-8/11).
//
// D8/MA150 -> R51 -> C47/IC17 sits directly on IC3's pin-14 node (N_BOUT),
// not on the IC7-C output or the IC6/TR3/TR5 branch.  The caller supplies a
// bounded AC departure from the 6-V analogue midpoint at N_BOUT:
//
//     N_BOUT -> D8 (MA150) -> R51=39k -> N_D8
//                                      |-> R52=10k -> GND
//                                      +-> C47=10u -> IC17 input
//
// The IC17 input impedance is off-sheet, so C47 is modelled as a bounded
// AC-coupling high-pass state.  Internal quantities are Q12 volts; source_out
// is the AC component at the C47 boundary.

module turbo_playercar_d8_source (
	input  logic               clk,
	input  logic               rst_n,
	input  logic               sample_ce,
	input  logic signed [15:0] source_in,
	output logic signed [15:0] source_out
);
	localparam logic signed [20:0] VREF6_Q12     = 21'sd24576;
	localparam logic signed [20:0] LM324_LO_Q12 = 21'sd0;
	localparam logic signed [20:0] LM324_HI_Q12 = 21'sd43008; // 10.5 V

	// MA150 low-current VF is not on the sheet; 0.700 V is the midpoint of the
	// 0.45..0.95 V interval.
	localparam logic signed [20:0] MA150_VF_N_Q12 = 21'sd2867; // 0.700 V

	// D8/R51/R52 attenuation is 10k/(39k+10k) = 0.20408; the shift/add form below
	// is 13/64 = 0.203125 (no multiplier or divider).  C47's far-side load is
	// off-sheet, so a 1/4096 per-sample pole approximates the AC coupling.
	logic signed [20:0] c47_lp_v;

	function automatic logic signed [20:0] rail_limit(
		input logic signed [22:0] value
	);
		begin
			if (value < $signed({2'b0, LM324_LO_Q12}))
				rail_limit = LM324_LO_Q12;
			else if (value > $signed({2'b0, LM324_HI_Q12}))
				rail_limit = LM324_HI_Q12;
			else
				rail_limit = value[20:0];
		end
	endfunction

	function automatic logic signed [20:0] rail_limit_wide(
		input logic signed [26:0] value
	);
		begin
			if (value < $signed({6'b0, LM324_LO_Q12}))
				rail_limit_wide = LM324_LO_Q12;
			else if (value > $signed({6'b0, LM324_HI_Q12}))
				rail_limit_wide = LM324_HI_Q12;
			else
				rail_limit_wide = value[20:0];
		end
	endfunction

	function automatic logic signed [20:0] sat16_q12(
		input logic signed [22:0] value
	);
		begin
			if (value > 23'sd32767)
				sat16_q12 = 21'sd32767;
			else if (value < -23'sd32768)
				sat16_q12 = -21'sd32768;
			else
				sat16_q12 = value[20:0];
		end
	endfunction

	always_ff @(posedge clk) begin : d8_boundary_stage
		logic signed [22:0] n_bout_wide;
		logic signed [20:0] n_bout_v;
		logic signed [21:0] diode_overdrive;
		logic signed [22:0] d8_node_wide;
		logic signed [20:0] d8_node_v;
		logic signed [21:0] hp_delta;
		logic signed [22:0] hp_step;
		logic signed [26:0] c47_next_wide;
		logic signed [20:0] hp_out_v;

		if (!rst_n) begin
			c47_lp_v <= '0;
			source_out <= 16'sd0;
		end
		else if (sample_ce) begin
			// source_in is an AC departure from the 6-V bias at N_BOUT; bound the
			// single-supply node before the diode.
			n_bout_wide = $signed({{2{VREF6_Q12[20]}}, VREF6_Q12}) +
						  $signed({{7{source_in[15]}}, source_in});
			n_bout_v = rail_limit(n_bout_wide);

			// D8 conducts only from N_BOUT toward R51 (fixed MA150 VF, no symmetric clamp).
			diode_overdrive = $signed(n_bout_v) - $signed(MA150_VF_N_Q12);
			if (diode_overdrive <= 0) begin
				d8_node_v = 21'sd0;
			end
			else begin
				d8_node_wide = $signed({{1{diode_overdrive[21]}}, diode_overdrive});
				// 13/64 ~= R52/(R51+R52)
				d8_node_wide = (d8_node_wide >>> 2) -
								(d8_node_wide >>> 5) -
								(d8_node_wide >>> 6);
				d8_node_v = rail_limit(d8_node_wide);
			end

			// C47 removes the rectifier's positive bias: export the instantaneous AC
			// departure, then update the slow coupling state.
			hp_delta = $signed(d8_node_v) - $signed(c47_lp_v);
			hp_step = $signed({{1{hp_delta[21]}}, hp_delta}) >>> 12;
			hp_out_v = sat16_q12($signed({{1{hp_delta[21]}}, hp_delta}));
			c47_next_wide =
				$signed({{5{c47_lp_v[20]}}, c47_lp_v}) +
				$signed({{3{hp_step[22]}}, hp_step});
			c47_lp_v <= rail_limit_wide(c47_next_wide);

			if (hp_out_v > 21'sd32767)
				source_out <= 16'sd32767;
			else if (hp_out_v < -21'sd32768)
				source_out <= 16'sh8000;
			else
				source_out <= hp_out_v[15:0];
		end
	end
endmodule
