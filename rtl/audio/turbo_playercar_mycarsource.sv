// IC6 MYCAR source model (D-8/11, 834-0123).
//
// Two IC6 relaxation cells are represented at the voltage boundary that the
// drawing actually exposes:
//
//   IC6/C5  (R28=270k, C5=4700pF, R31=120k) -> D7 --+
//   IC6/C18+C19 (R78=220k, C18||C19=0.090uF, R76=100k) -> D13 --+-- R79=10k
//                                                               |
//                                                               +-- C76
//
// The integrator outputs are exported, not the Schmitt comparator.  The tone
// rate comes from the STEP_LUT law; the sub rate is a named operating-point
// parameter (0.43 Hz/V) because TR5's in-circuit VCE is not recoverable from
// the schematic.  Cell slopes use the traced resistor ratios:
// R28/R31-1 = 1.25 and R78/R76-1 = 1.20.
//
// IC7's relaxation cell (R87/R84/C20||C21) is a third free-running cell here:
// its integrator output is not audio, it is the AC drive of IC7-C, which sets
// IC17's CONT pin (see the IC17 block in turbo_playercar_chan.sv).
//
// The diode node uses an explicit active-set KCL with R79 and a 1-kOhm
// low-current branch resistance (MA150/LM324 source-impedance corner, kept as
// a parameter).  The finite corner keeps the shared-load equation from
// collapsing into a plain max() shortcut.

module turbo_playercar_mycarsource (
	input  logic               clk,
	input  logic               rst_n,
	input  logic               sample_ce,
	input  logic signed [39:0] tone_step_q24,
	input  logic signed [39:0] sub_step_q24,
	input  logic signed [39:0] ic7_step_q24,
	output logic signed [15:0] tone_ac,
	output logic signed [15:0] sub_ac,
	output logic signed [15:0] node_ac,
	output logic signed [20:0] tone_v_q12,
	output logic signed [20:0] sub_v_q12,
	output logic signed [20:0] node_v_q12,
	output logic signed [20:0] ic7_v_q12
);
	localparam logic signed [39:0] TH_LO_Q24   = 40'sd66664434;
	localparam logic signed [39:0] TH_HI_Q24   = 40'sd126162442;
	localparam logic signed [39:0] TH_MEAN_Q24 = 40'sd96413438;
	localparam logic signed [20:0] TH_MEAN_Q12 = 21'sd23538;
	localparam logic signed [20:0] MA150_VF_Q12 = 21'sd2867; // 0.700 V
	// R79=10k with the 1k branch resistance gives 10k/(10k+1k) ~ 233/256 for one
	// active diode, and 10k/(1k+2*10k) ~ 61/128 on the sum when both conduct.
	localparam logic signed [20:0] BRANCH_R_OHM = 21'sd1000;

	logic signed [39:0] tone_v_q24, sub_v_q24, ic7_v_q24;
	logic               tone_rising, sub_rising, ic7_rising;
	logic signed [39:0] tone_step_hold, sub_step_hold, ic7_step_hold;
	// C76 coupling state: Q12 volts with 16 extra fractional bits.  The pole is only
	// 14/65536 per sample, so a plain Q12 state would round small steps to zero and
	// leave DC in the node tap.
	logic signed [36:0] c76_lp_q28;

	// The sampled reduction is split into registered stages (a 26 ns path at 39.9 MHz
	// otherwise); the sample interval leaves hundreds of clocks to settle.
	logic [1:0] src_pipe_valid;
	logic signed [20:0] tone_sample_hold_q12;
	logic signed [20:0] sub_sample_hold_q12;
	logic signed [20:0] node_stage_q12;

	wire signed [39:0] tone_step_up = tone_step_hold + (tone_step_hold >>> 2);
	wire signed [39:0] sub_step_up = sub_step_hold + (sub_step_hold >>> 2) -
									 (sub_step_hold >>> 5) - (sub_step_hold >>> 6);
	// IC7 cell (R87=150k, R84=68k -> ratio 1.206; the shift/add form 1.203125 is within
	// 0.25 %).  Its integrator drives IC7-C through C6/R36 (see turbo_playercar_chan).
	wire signed [39:0] ic7_step_up = ic7_step_hold + (ic7_step_hold >>> 2) -
									 (ic7_step_hold >>> 5) - (ic7_step_hold >>> 6);

	function automatic logic signed [39:0] cell_next(
		input logic signed [39:0] value,
		input logic               rising,
		input logic signed [39:0] step_up,
		input logic signed [39:0] step_down
	);
		logic signed [39:0] next_value;
		begin
			next_value = rising ? value + step_up : value - step_down;
			if (rising && next_value >= TH_HI_Q24)
				cell_next = TH_HI_Q24;
			else if (!rising && next_value <= TH_LO_Q24)
				cell_next = TH_LO_Q24;
			else
				cell_next = next_value;
		end
	endfunction

	function automatic logic next_rising(
		input logic signed [39:0] value,
		input logic               rising,
		input logic signed [39:0] step_up,
		input logic signed [39:0] step_down
	);
		logic signed [39:0] next_value;
		begin
			next_value = rising ? value + step_up : value - step_down;
			if (rising && next_value >= TH_HI_Q24)
				next_rising = 1'b0;
			else if (!rising && next_value <= TH_LO_Q24)
				next_rising = 1'b1;
			else
				next_rising = rising;
		end
	endfunction

	function automatic logic signed [20:0] q24_to_q12(
		input logic signed [39:0] value
	);
		logic signed [39:0] shifted;
		begin
			shifted = value >>> 12;
			if (shifted < 0)
				q24_to_q12 = 21'sd0;
			else if (shifted > 40'sd43008)
				q24_to_q12 = 21'sd43008;
			else
				q24_to_q12 = shifted[20:0];
		end
	endfunction

	function automatic logic signed [15:0] sat16(
		input logic signed [31:0] value
	);
		begin
			if (value > 32'sd32767) sat16 = 16'sd32767;
			else if (value < -32'sd32768) sat16 = 16'sh8000;
			else sat16 = value[15:0];
		end
	endfunction

	// Two MA150 branches into R79 with the 1-kOhm branch resistance.  Closed-form
	// node voltages for the three conduction sets:
	//   tone only : Vt' * R79/(R79+Rb)          = Vt' * 10/11  ~= 233/256
	//   sub only  : Vs' * 10/11
	//   both      : (Vt'+Vs')/2 * R79/(R79+Rb/2) = (Vt'+Vs') * 10/21 ~= 61/128
	// (Vx' = source - VF).  The physical solution is the maximum of the three
	// candidates: a diode set only conducts when it raises the node, and the
	// maximum is continuous in both sources.
	function automatic logic signed [20:0] solve_node(
		input logic signed [20:0] tone_source,
		input logic signed [20:0] sub_source,
		input logic signed [20:0] previous_node
	);
		logic signed [21:0] tone_drive, sub_drive, both_sum;
		logic signed [21:0] cand_tone, cand_sub, cand_both, candidate;
		begin
			tone_drive = $signed({tone_source[20], tone_source}) -
						 $signed({MA150_VF_Q12[20], MA150_VF_Q12});
			sub_drive = $signed({sub_source[20], sub_source}) -
						$signed({MA150_VF_Q12[20], MA150_VF_Q12});
			both_sum = tone_drive + sub_drive;
			// 233/256 = 1 - 1/16 - 1/32 + 1/256 ~= 10/11
			cand_tone = tone_drive - (tone_drive >>> 4) - (tone_drive >>> 5) +
						(tone_drive >>> 8);
			cand_sub  = sub_drive  - (sub_drive  >>> 4) - (sub_drive  >>> 5) +
						(sub_drive  >>> 8);
			// 61/128 = 1/2 - 1/64 - 1/128 ~= 10/21
			cand_both = (both_sum >>> 1) - (both_sum >>> 6) - (both_sum >>> 7);
			candidate = cand_tone;
			if (cand_sub > candidate)
				candidate = cand_sub;
			if (cand_both > candidate)
				candidate = cand_both;
			if (candidate < 0)
				solve_node = 21'sd0;
			else if (candidate > 22'sd43008)
				solve_node = 21'sd43008;
			else
				solve_node = candidate[20:0];
		end
	endfunction

	wire signed [20:0] tone_sample_q12 = q24_to_q12(tone_v_q24);
	wire signed [20:0] sub_sample_q12  = q24_to_q12(sub_v_q24);
	wire signed [20:0] ic7_sample_q12 = q24_to_q12(ic7_v_q24);
	// The node is solved into a register first; the C76 update and AC conversion use
	// the settled value on the following clock.
	wire signed [20:0] node_sample_q12 = node_stage_q12;
	wire signed [36:0] c76_node_q28 = $signed({node_sample_q12, 16'd0});
	wire signed [36:0] c76_delta_q28 = c76_node_q28 - c76_lp_q28;
	wire signed [36:0] c76_step_q28 = (c76_delta_q28 >>> 12) -
									  (c76_delta_q28 >>> 15); // 14/65536
	wire signed [36:0] c76_next_q28 = c76_lp_q28 + c76_step_q28;
	wire signed [21:0] c76_ac = $signed({node_sample_q12[20], node_sample_q12}) -
								$signed(c76_next_q28[37-1:16]);

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			tone_v_q24 <= TH_MEAN_Q24;
			sub_v_q24 <= TH_MEAN_Q24;
			ic7_v_q24 <= TH_MEAN_Q24;
			tone_rising <= 1'b1;
			sub_rising <= 1'b1;
			ic7_rising <= 1'b1;
			tone_step_hold <= 40'sd0;
			sub_step_hold <= 40'sd0;
			ic7_step_hold <= 40'sd0;
			c76_lp_q28 <= 37'sd0;
			src_pipe_valid <= 2'b00;
			tone_sample_hold_q12 <= 21'sd0;
			sub_sample_hold_q12 <= 21'sd0;
			node_stage_q12 <= 21'sd0;
			tone_ac <= 16'sd0;
			sub_ac <= 16'sd0;
			node_ac <= 16'sd0;
			tone_v_q12 <= 21'sd0;
			sub_v_q12 <= 21'sd0;
			node_v_q12 <= 21'sd0;
			ic7_v_q12 <= 21'sd0;
		end else begin
			tone_v_q24 <= cell_next(tone_v_q24, tone_rising,
									tone_step_up, tone_step_hold);
			sub_v_q24 <= cell_next(sub_v_q24, sub_rising,
								   sub_step_up, sub_step_hold);
			ic7_v_q24 <= cell_next(ic7_v_q24, ic7_rising,
								   ic7_step_up, ic7_step_hold);
			ic7_rising <= next_rising(ic7_v_q24, ic7_rising,
									  ic7_step_up, ic7_step_hold);
			tone_rising <= next_rising(tone_v_q24, tone_rising,
									   tone_step_up, tone_step_hold);
			sub_rising <= next_rising(sub_v_q24, sub_rising,
									  sub_step_up, sub_step_hold);
			// Valid marker shifted through the two scheduling stages.
			src_pipe_valid <= {src_pipe_valid[0], sample_ce};
			if (sample_ce) begin
				tone_step_hold <= tone_step_q24;
				sub_step_hold <= sub_step_q24;
				ic7_step_hold <= ic7_step_q24;
				ic7_v_q12 <= ic7_sample_q12;
				tone_sample_hold_q12 <= tone_sample_q12;
				sub_sample_hold_q12 <= sub_sample_q12;
				tone_v_q12 <= tone_sample_q12;
				sub_v_q12 <= sub_sample_q12;
				tone_ac <= sat16($signed({{11{tone_sample_q12[20]}}, tone_sample_q12}) -
								  $signed({{11{TH_MEAN_Q12[20]}}, TH_MEAN_Q12}));
				sub_ac <= sat16($signed({{11{sub_sample_q12[20]}}, sub_sample_q12}) -
								 $signed({{11{TH_MEAN_Q12[20]}}, TH_MEAN_Q12}));
			end
			if (src_pipe_valid[0]) begin
				node_stage_q12 <= solve_node(tone_sample_hold_q12,
											  sub_sample_hold_q12,
											  node_v_q12);
			end
			if (src_pipe_valid[1]) begin
				node_v_q12 <= node_sample_q12;
				c76_lp_q28 <= c76_next_q28;
				node_ac <= sat16($signed({{10{c76_ac[21]}}, c76_ac}));
			end
		end
	end
endmodule
