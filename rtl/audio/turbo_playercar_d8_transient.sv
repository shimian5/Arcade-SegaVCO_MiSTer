// Bounded fixed-point reduction of the D8 IC3/IC5/IC7 transient path (sheet D-8/11).
//
// A source-shaper boundary, not an oscillator: the upstream waveform comes from
// turbo_playercar_chan.sv and is placed at the lower IC3 pin-8 N_SRC node.  The
// C7/C154/C17/C20+C21/C6 states are carried and two taps are exported:
//
//   N_BOUT       -> D8/R51/R52/C47/IC17 input boundary
//   MY CAR CONT  -> IC7-A input / D9 BSEL1 source boundary
//
// All voltages are Q12 volts.  Update equations use shift/add constants for
// the nominal RC corners (no multipliers or dividers).  LM324 rails and Schmitt
// state are explicit; the 2SC458/MA150 branches use VBE/VF thresholds and
// collector-load terms.
//
module turbo_playercar_d8_transient (
	input  logic               clk,
	input  logic               rst_n,
	input  logic               sample_ce,
	// AC departure from the N_SRC 6-V analogue midpoint, Q12.
	input  logic signed [15:0] source_in,
	output logic signed [15:0] n_bout_ac,
	output logic signed [15:0] mycar_cont_ac,
	output logic signed [20:0] n_bout_v_q12,
	output logic signed [20:0] mycar_cont_v_q12
);
	localparam logic signed [20:0] VREF6_Q12      = 21'sd24576;
	localparam logic signed [20:0] TACHO_Q12      = 21'sd22068; // 5.387755 V
	localparam logic signed [20:0] VMAX_Q12       = 21'sd43008; // 10.5 V
	localparam logic signed [20:0] VBE_Q12        = 21'sd2744;  // 0.67 V
	localparam logic signed [20:0] VF_Q12         = 21'sd2867;  // 0.70 V
	localparam logic signed [20:0] VCE_SAT_Q12    = 21'sd819;   // 0.20 V

	// Schmitt thresholds from the traced 51-k/100-k, 6-V positive-feedback
	// networks: 3.9735 V and 7.5199 V.
	localparam logic signed [20:0] SCHMITT_LO_Q12 = 21'sd16276;
	localparam logic signed [20:0] SCHMITT_HI_Q12 = 21'sd30802;

	// beta = 1-exp(-dt/tau), fs=39,935,064/832 Hz, Q16.
	localparam logic signed [15:0] C7_BETA_Q16    = 16'sd51;  // 270k*0.1u
	localparam logic signed [15:0] C154_BETA_Q16  = 16'sd91;  // 150k*0.1u
	localparam logic signed [15:0] C17_BETA_Q16   = 16'sd4;   // 15k*22u
	localparam logic signed [15:0] CFB_BETA_Q16   = 16'sd191; // 150k*47.68n
	localparam logic signed [15:0] C6_BETA_Q16    = 16'sd6;   // 10k*22u

	logic signed [20:0] c7_q12, c154_q12, c17_q12, cfb_q12, c6_q12;
	logic               ic3d_hi, ic5b_hi, ic7c_hi;

	logic signed [20:0] n_src_v;
	logic signed [20:0] bplus_v, bout_v;
	logic signed [20:0] aplus_v, aout_v /* verilator public_flat */;
	logic signed [20:0] n5bout_v /* verilator public_flat */;
	logic signed [20:0] n_c17_v /* verilator public_flat */;
	logic signed [20:0] n_loop_v;
	logic signed [20:0] b7plus_v, b7out_v;
	logic signed [20:0] tr6_collector_v;
	logic signed [31:0] cfb_term_q12;
	logic signed [20:0] c7_next, c154_next, c17_next, cfb_next, c6_next;
	logic signed [20:0] tr1_load_q12, tr2_load_q12;
	logic               ic3d_next, ic5b_next, ic7c_next;

	function automatic logic signed [20:0] clamp_q12(
		input logic signed [31:0] value
	);
		begin
			if (value < 32'sd0)
				clamp_q12 = 21'sd0;
			else if (value > $signed({{11{VMAX_Q12[20]}}, VMAX_Q12}))
				clamp_q12 = VMAX_Q12;
			else
				clamp_q12 = value[20:0];
		end
	endfunction

	function automatic logic signed [20:0] signed_clamp_q12(
		input logic signed [31:0] value
	);
		begin
			if (value < -32'sd43008)
				signed_clamp_q12 = -21'sd43008;
			else if (value > 32'sd43008)
				signed_clamp_q12 = 21'sd43008;
			else
				signed_clamp_q12 = value[20:0];
		end
	endfunction

	function automatic logic signed [15:0] sat16_q12(
		input logic signed [31:0] value
	);
		begin
			if (value > 32'sd32767)
				sat16_q12 = 16'sd32767;
			else if (value < -32'sd32768)
				sat16_q12 = 16'sh8000;
			else
				sat16_q12 = value[15:0];
		end
	endfunction

	function automatic logic signed [31:0] alpha_delta_q12(
		input logic signed [21:0] delta,
		input logic signed [15:0] beta_q16
	);
		logic signed [31:0] delta_ext;
		begin
			delta_ext = {{10{delta[21]}}, delta};
			// Shift/add forms of the five compile-time RC betas (avoids inferring a DSP block).
			case (beta_q16)
				16'sd51:  alpha_delta_q12 = (delta_ext >>> 10) -
											 (delta_ext >>> 13) -
											 (delta_ext >>> 14) -
											 (delta_ext >>> 16);
				16'sd91:  alpha_delta_q12 = (delta_ext >>> 9) -
											 (delta_ext >>> 11) -
											 (delta_ext >>> 14) -
											 (delta_ext >>> 16);
				16'sd4:   alpha_delta_q12 = (delta_ext >>> 14);
				16'sd191: alpha_delta_q12 = (delta_ext >>> 8) -
											 (delta_ext >>> 10) -
											 (delta_ext >>> 16);
				16'sd6:   alpha_delta_q12 = (delta_ext >>> 13) -
											 (delta_ext >>> 15);
				default:  alpha_delta_q12 = '0;
			endcase
		end
	endfunction

	function automatic logic signed [20:0] alpha_step_q12(
		input logic signed [20:0] previous,
		input logic signed [20:0] target,
		input logic signed [15:0] beta_q16
	);
		logic signed [21:0] delta;
		logic signed [31:0] result;
		logic signed [31:0] previous_ext;
		begin
			delta = $signed(target) - $signed(previous);
			previous_ext = {{11{previous[20]}}, previous};
			result = previous_ext + alpha_delta_q12(delta, beta_q16);
			alpha_step_q12 = signed_clamp_q12(result);
		end
	endfunction

	function automatic logic signed [20:0] integrator_step_q12(
		input logic signed [20:0] previous,
		input logic signed [20:0] increment,
		input logic signed [15:0] beta_q16
	);
		logic signed [21:0] delta;
		logic signed [31:0] result;
		logic signed [31:0] previous_ext;
		begin
			delta = {{1{increment[20]}}, increment};
			previous_ext = {{11{previous[20]}}, previous};
			result = previous_ext + alpha_delta_q12(delta, beta_q16);
			integrator_step_q12 = signed_clamp_q12(result);
		end
	endfunction

	// Backward-Euler capacitor-feedback update with a collector-load term already
	// expressed as the capacitor voltage change per sample (Q12 volts).  At an op-amp
	// rail the virtual short is released and the capacitor recovers through its
	// source resistor.
	function automatic logic signed [20:0] opamp_cap_step_q12(
		input logic signed [20:0] previous,
		input logic signed [20:0] source,
		input logic signed [20:0] plus,
		input logic signed [15:0] beta_q16,
		input logic signed [20:0] load_q12
	);
		logic signed [21:0] delta;
		logic signed [31:0] result;
		logic signed [31:0] previous_ext;
		logic signed [31:0] plus_ext;
		logic signed [31:0] load_ext;
		logic signed [31:0] q_pred;
		logic signed [31:0] output_pred;
		logic signed [31:0] recovery_ext;
		logic signed [20:0] recovery_q12;
		begin
			delta = $signed(source) - $signed(plus);
			previous_ext = {{11{previous[20]}}, previous};
			plus_ext = {{11{plus[20]}}, plus};
			load_ext = {{11{load_q12[20]}}, load_q12};
			result = previous_ext + alpha_delta_q12(delta, beta_q16);
			q_pred = result - load_ext;
			output_pred = plus_ext - q_pred;
			if (output_pred < 0)
				begin
					// Named temporary: the target Quartus parser rejects a bit-select
					// on a function-call expression.
					recovery_q12 = alpha_step_q12(previous, source, beta_q16);
					recovery_ext = {{11{recovery_q12[20]}}, recovery_q12};
					opamp_cap_step_q12 = signed_clamp_q12(recovery_ext - load_ext);
				end
			else if (output_pred > 32'sd43008)
				begin
					recovery_q12 = alpha_step_q12(previous, source - VMAX_Q12, beta_q16);
					recovery_ext = {{11{recovery_q12[20]}}, recovery_q12};
					opamp_cap_step_q12 = signed_clamp_q12(recovery_ext - load_ext);
				end
			else
				opamp_cap_step_q12 = signed_clamp_q12(q_pred);
		end
	endfunction

	// Saturated common-emitter collector load as a capacitor voltage decrement per
	// sample: dt/(Rcollector*C) in shift/add form.
	//   TR1: 120k * 0.1uF -> approximately 1/576
	//   TR2:  68k * 0.1uF -> approximately 1/326
	//   TR6:  68k * 47.68nF -> approximately 1/156
	function automatic logic signed [20:0] collector_load_q12(
		input logic drive_hi,
		input logic signed [20:0] collector_drive,
		input logic signed [15:0] resistor_shift
	);
		logic signed [31:0] overdrive;
		begin
			overdrive = $signed({{11{collector_drive[20]}}, collector_drive}) -
						$signed({{11{VCE_SAT_Q12[20]}}, VCE_SAT_Q12});
			// The branch is fed through an MA150 and a 2SC458 base junction, so the
			// collector load conducts only once those forward drops are exceeded.
			if (!drive_hi || overdrive <= 0 ||
				VMAX_Q12 <= (VF_Q12 + VBE_Q12))
				collector_load_q12 = 21'sd0;
			else begin
				// resistor_shift is a compile-time constant at each callsite; the case
				// avoids a variable barrel shift.
				case (resistor_shift)
					16'sd9: collector_load_q12 = signed_clamp_q12(
						(overdrive >>> 9) - (overdrive >>> 12));
					16'sd8: collector_load_q12 = signed_clamp_q12(
						(overdrive >>> 8) - (overdrive >>> 10) +
						(overdrive >>> 13));
					16'sd7: collector_load_q12 = signed_clamp_q12(
						(overdrive >>> 7) - (overdrive >>> 9) +
						(overdrive >>> 11) - (overdrive >>> 14));
					default: collector_load_q12 = 21'sd0;
				endcase
			end
		end
	endfunction

	always_comb begin
		// Place the source at the N_SRC analogue midpoint.
		n_src_v = clamp_q12($signed({{11{VREF6_Q12[20]}}, VREF6_Q12}) +
							$signed({{16{source_in[15]}}, source_in}));

		// IC3-D/C7 branch: 51/51 divider on the non-inverting input, C7 0.1 uF in
		// feedback; TR1/D9 collector load is applied after the Schmitt decision.
		bplus_v = n_src_v >>> 1;
		// Interior operation is an integrator: q[n+1] = q[n] + beta*(N_SRC-N_BPLUS);
		// at an LM324 rail the capacitor recovers toward the source instead.
		c7_next = opamp_cap_step_q12(c7_q12, n_src_v, bplus_v,
									 C7_BETA_Q16, 21'sd0);
		bout_v = clamp_q12($signed({{11{bplus_v[20]}}, bplus_v}) -
						   $signed({{11{c7_next[20]}}, c7_next}));
		if (($signed({{11{bplus_v[20]}}, bplus_v}) -
			 $signed({{11{c7_next[20]}}, c7_next})) < 0)
			c7_next = opamp_cap_step_q12(c7_q12, n_src_v, bplus_v,
										 C7_BETA_Q16, 21'sd0);
		else if (($signed({{11{bplus_v[20]}}, bplus_v}) -
				  $signed({{11{c7_next[20]}}, c7_next})) > 43008)
			c7_next = opamp_cap_step_q12(c7_q12, n_src_v, bplus_v,
										 C7_BETA_Q16, 21'sd0);
		bout_v = clamp_q12($signed({{11{bplus_v[20]}}, bplus_v}) -
						   $signed({{11{c7_next[20]}}, c7_next}));
		if (!ic3d_hi)
			ic3d_next = (bout_v <= SCHMITT_LO_Q12);
		else
			ic3d_next = !(bout_v >= SCHMITT_HI_Q12);
		tr1_load_q12 = collector_load_q12(
			ic3d_next, clamp_q12($signed({{11{c7_next[20]}}, c7_next}) +
								  $signed({{11{bout_v[20]}}, bout_v})), 16'sd9);
		c7_next = opamp_cap_step_q12(c7_q12, n_src_v, bplus_v,
									 C7_BETA_Q16, tr1_load_q12);
		bout_v = clamp_q12($signed({{11{bplus_v[20]}}, bplus_v}) -
						   $signed({{11{c7_next[20]}}, c7_next}));
		if (!ic3d_hi)
			ic3d_next = (bout_v <= SCHMITT_LO_Q12);
		else
			ic3d_next = !(bout_v >= SCHMITT_HI_Q12);
		tr1_load_q12 = collector_load_q12(
			ic3d_next, clamp_q12($signed({{11{c7_next[20]}}, c7_next}) +
								  $signed({{11{bout_v[20]}}, bout_v})), 16'sd9);
		c7_next = opamp_cap_step_q12(c7_q12, n_src_v, bplus_v,
									 C7_BETA_Q16, tr1_load_q12);
		bout_v = clamp_q12($signed({{11{bplus_v[20]}}, bplus_v}) -
						   $signed({{11{c7_next[20]}}, c7_next}));

		// IC5-A/C154 parallel branch from the same N_SRC fork.
		aplus_v = n_src_v >>> 1;
		c154_next = opamp_cap_step_q12(c154_q12, n_src_v, aplus_v,
									   C154_BETA_Q16, 21'sd0);
		aout_v = clamp_q12($signed({{11{aplus_v[20]}}, aplus_v}) -
						   $signed({{11{c154_next[20]}}, c154_next}));
		if (($signed({{11{aplus_v[20]}}, aplus_v}) -
			 $signed({{11{c154_next[20]}}, c154_next})) < 0)
			c154_next = alpha_step_q12(c154_q12, n_src_v,
									   C154_BETA_Q16);
		else if (($signed({{11{aplus_v[20]}}, aplus_v}) -
				  $signed({{11{c154_next[20]}}, c154_next})) > 43008)
			c154_next = alpha_step_q12(c154_q12, n_src_v - VMAX_Q12,
									   C154_BETA_Q16);
		aout_v = clamp_q12($signed({{11{aplus_v[20]}}, aplus_v}) -
						   $signed({{11{c154_next[20]}}, c154_next}));
		if (!ic5b_hi)
			ic5b_next = (aout_v <= SCHMITT_LO_Q12);
		else
			ic5b_next = !(aout_v >= SCHMITT_HI_Q12);
		tr2_load_q12 = collector_load_q12(
			ic5b_next, clamp_q12($signed({{11{c154_next[20]}}, c154_next}) +
								  $signed({{11{aout_v[20]}}, aout_v})), 16'sd8);
		c154_next = opamp_cap_step_q12(c154_q12, n_src_v, aplus_v,
									   C154_BETA_Q16, tr2_load_q12);
		aout_v = clamp_q12($signed({{11{aplus_v[20]}}, aplus_v}) -
						   $signed({{11{c154_next[20]}}, c154_next}));
		if (!ic5b_hi)
			ic5b_next = (aout_v <= SCHMITT_LO_Q12);
		else
			ic5b_next = !(aout_v >= SCHMITT_HI_Q12);
		tr2_load_q12 = collector_load_q12(
			ic5b_next, clamp_q12($signed({{11{c154_next[20]}}, c154_next}) +
								  $signed({{11{aout_v[20]}}, aout_v})), 16'sd8);
		c154_next = opamp_cap_step_q12(c154_q12, n_src_v, aplus_v,
									   C154_BETA_Q16, tr2_load_q12);
		aout_v = clamp_q12($signed({{11{aplus_v[20]}}, aplus_v}) -
						   $signed({{11{c154_next[20]}}, c154_next}));

		// C17/R70 is fed from the IC5-A output into the IC5-C inverting node (not from
		// the IC5-B Schmitt state); the 5.387755-V R65/R67 node is its + reference.
		// This node is the MY CAR CONT source after the IC7-A follower.
		n5bout_v = ic5b_next ? VMAX_Q12 : 21'sd0;
		c17_next = alpha_step_q12(c17_q12, aout_v - TACHO_Q12,
								  C17_BETA_Q16);
		n_c17_v = clamp_q12($signed({{11{aout_v[20]}}, aout_v}) -
							$signed({{11{c17_next[20]}}, c17_next}));
		// 10k/15k = 2/3, as 341/512 (binary expansion truncated at 1/512).
		begin : loop_reduce
			logic signed [21:0] loop_delta;
			logic signed [31:0] loop_term;
			logic signed [31:0] loop_delta_ext;
			loop_delta = $signed(TACHO_Q12) - $signed(n_c17_v);
			loop_delta_ext = {{10{loop_delta[21]}}, loop_delta};
			loop_term = (loop_delta_ext >>> 1) + (loop_delta_ext >>> 3) +
						(loop_delta_ext >>> 5) + (loop_delta_ext >>> 7) +
						(loop_delta_ext >>> 9);
			n_loop_v = clamp_q12($signed({{11{TACHO_Q12[20]}}, TACHO_Q12}) +
								 $signed(loop_term));
		end

		// IC7-B/C feedback state: the two resistor currents (R87 150k, R84 68k) plus the
		// TR6 collector load; dt/(150k*CFB) and dt/(68k*CFB) as shift/add constants.
		b7plus_v = n_loop_v >>> 1;
		b7out_v = clamp_q12($signed({{11{b7plus_v[20]}}, b7plus_v}) -
							$signed({{11{cfb_q12[20]}}, cfb_q12}));
		if (!ic7c_hi)
			ic7c_next = (b7out_v <= SCHMITT_LO_Q12);
		else
			ic7c_next = !(b7out_v >= SCHMITT_HI_Q12);
		tr6_collector_v = ic7c_next ? VCE_SAT_Q12 : b7out_v;
		begin : cfb_reduce
			logic signed [31:0] r87_delta;
			logic signed [31:0] r84_delta;
			r87_delta = $signed({{11{b7plus_v[20]}}, b7plus_v}) -
						$signed({{11{n_loop_v[20]}}, n_loop_v});
			r84_delta = $signed({{11{b7plus_v[20]}}, b7plus_v}) -
						$signed({{11{tr6_collector_v[20]}}, tr6_collector_v});
			// 0.00293 ~= dt/(150k*47.68nF).
			// 0.00635 ~= dt/(68k*47.68nF).
			cfb_term_q12 = (r87_delta >>> 9) + (r87_delta >>> 10) +
						   (r84_delta >>> 7) - (r84_delta >>> 9) +
						   (r84_delta >>> 12);
		end
		b7out_v = clamp_q12($signed({{11{b7plus_v[20]}}, b7plus_v}) -
							$signed({{11{cfb_q12[20]}}, cfb_q12}) +
							$signed(cfb_term_q12));
		if (!ic7c_hi)
			ic7c_next = (b7out_v <= SCHMITT_LO_Q12);
		else
			ic7c_next = !(b7out_v >= SCHMITT_HI_Q12);
		tr6_collector_v = ic7c_next ? VCE_SAT_Q12 : b7out_v;
		begin : cfb_reduce_final
			logic signed [31:0] r87_delta_final;
			logic signed [31:0] r84_delta_final;
			r87_delta_final = $signed({{11{b7plus_v[20]}}, b7plus_v}) -
							  $signed({{11{n_loop_v[20]}}, n_loop_v});
			r84_delta_final = $signed({{11{b7plus_v[20]}}, b7plus_v}) -
							  $signed({{11{tr6_collector_v[20]}}, tr6_collector_v});
			cfb_term_q12 = (r87_delta_final >>> 9) +
						   (r87_delta_final >>> 10) +
						   (r84_delta_final >>> 7) -
						   (r84_delta_final >>> 9) +
						   (r84_delta_final >>> 12);
		end
		b7out_v = clamp_q12($signed({{11{b7plus_v[20]}}, b7plus_v}) -
							$signed({{11{cfb_q12[20]}}, cfb_q12}) +
							$signed(cfb_term_q12));
		cfb_next = signed_clamp_q12(
			$signed({{11{b7plus_v[20]}}, b7plus_v}) -
			$signed({{11{b7out_v[20]}}, b7out_v}));
		c6_next = alpha_step_q12(c6_q12, n_loop_v - b7out_v, C6_BETA_Q16);
	end

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			c7_q12          <= '0;
			c154_q12        <= '0;
			c17_q12         <= '0;
			cfb_q12         <= '0;
			c6_q12          <= '0;
			ic3d_hi         <= 1'b0;
			ic5b_hi         <= 1'b0;
			ic7c_hi         <= 1'b0;
			n_bout_ac       <= 16'sd0;
			mycar_cont_ac   <= 16'sd0;
			n_bout_v_q12    <= VREF6_Q12;
			mycar_cont_v_q12 <= TACHO_Q12;
		end
		else if (sample_ce) begin
			c7_q12   <= c7_next;
			c154_q12 <= c154_next;
			c17_q12  <= c17_next;
			cfb_q12  <= cfb_next;
			c6_q12   <= c6_next;
			ic3d_hi  <= ic3d_next;
			ic5b_hi  <= ic5b_next;
			ic7c_hi  <= ic7c_next;

			n_bout_v_q12 <= bout_v;
			mycar_cont_v_q12 <= n_loop_v;
			n_bout_ac <= sat16_q12(
				$signed({{11{bout_v[20]}}, bout_v}) -
				$signed({{11{VREF6_Q12[20]}}, VREF6_Q12}));
			mycar_cont_ac <= sat16_q12(
				$signed({{11{n_loop_v[20]}}, n_loop_v}) -
				$signed({{11{TACHO_Q12[20]}}, TACHO_Q12}));
		end
	end
endmodule
