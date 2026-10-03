// Clocked implementation of the reduced D8 IC3/IC5/IC7 transient boundary.
//
// Same component equations as turbo_playercar_d8_transient.sv, but each
// dependent analogue step is committed in its own emu-clock micro-stage, so no
// combinational path spans the whole C7/C154/C17/CFB/C6 chain (it would
// otherwise be a 74-level, 102 ns path).  sample_ce starts one transaction and
// the 39.9-MHz clock advances it; the 35-cycle reduction finishes well within
// the ~832 emu clocks between samples.  No electrical coefficient depends on
// this scheduling.
//
module turbo_playercar_d8_transient_pipe (
	input  logic               clk,
	input  logic               rst_n,
	input  logic               sample_ce,
	input  logic signed [15:0] source_in,
	output logic signed [15:0] n_bout_ac,
	output logic signed [15:0] mycar_cont_ac,
	output logic signed [20:0] n_bout_v_q12,
	output logic signed [20:0] mycar_cont_v_q12
);
	localparam logic signed [20:0] VREF6_Q12      = 21'sd24576;
	localparam logic signed [20:0] TACHO_Q12      = 21'sd22068;
	localparam logic signed [20:0] VMAX_Q12       = 21'sd43008;
	localparam logic signed [20:0] VBE_Q12        = 21'sd2744;
	localparam logic signed [20:0] VF_Q12         = 21'sd2867;
	localparam logic signed [20:0] VCE_SAT_Q12    = 21'sd819;

	localparam logic signed [20:0] SCHMITT_LO_Q12 = 21'sd16276;
	localparam logic signed [20:0] SCHMITT_HI_Q12 = 21'sd30802;

	localparam logic signed [15:0] C7_BETA_Q16    = 16'sd51;
	localparam logic signed [15:0] C154_BETA_Q16  = 16'sd91;
	localparam logic signed [15:0] C17_BETA_Q16   = 16'sd4;
	localparam logic signed [15:0] CFB_BETA_Q16   = 16'sd191;
	localparam logic signed [15:0] C6_BETA_Q16    = 16'sd6;

	// Every stage terminates at a flip-flop: no combinational dependence from one
	// analogue branch's final value to the next branch's input.
	localparam logic [5:0] ST_IDLE          = 6'd0;
	localparam logic [5:0] ST_CAPTURE       = 6'd1;
	localparam logic [5:0] ST_C7_BASE       = 6'd2;
	localparam logic [5:0] ST_C7_OUT0       = 6'd3;
	localparam logic [5:0] ST_C7_LOAD1      = 6'd4;
	localparam logic [5:0] ST_C7_APPLY1     = 6'd5;
	localparam logic [5:0] ST_C7_OUT1       = 6'd6;
	localparam logic [5:0] ST_C7_LOAD2      = 6'd7;
	localparam logic [5:0] ST_C7_APPLY2     = 6'd8;
	localparam logic [5:0] ST_C7_FINAL       = 6'd9;
	localparam logic [5:0] ST_C154_BASE     = 6'd10;
	localparam logic [5:0] ST_C154_OUT0     = 6'd11;
	localparam logic [5:0] ST_C154_LOAD1    = 6'd12;
	localparam logic [5:0] ST_C154_APPLY1   = 6'd13;
	localparam logic [5:0] ST_C154_OUT1     = 6'd14;
	localparam logic [5:0] ST_C154_LOAD2    = 6'd15;
	localparam logic [5:0] ST_C154_APPLY2   = 6'd16;
	localparam logic [5:0] ST_C154_FINAL    = 6'd17;
	localparam logic [5:0] ST_C17_STEP      = 6'd18;
	localparam logic [5:0] ST_C17_OUT       = 6'd19;
	localparam logic [5:0] ST_LOOP_DELTA    = 6'd20;
	localparam logic [5:0] ST_LOOP_EXT      = 6'd21;
	localparam logic [5:0] ST_LOOP_TERM     = 6'd22;
	localparam logic [5:0] ST_LOOP_OUT      = 6'd23;
	localparam logic [5:0] ST_CFB_PLUS      = 6'd24;
	localparam logic [5:0] ST_CFB_OUT0      = 6'd25;
	localparam logic [5:0] ST_CFB_DECIDE1   = 6'd26;
	localparam logic [5:0] ST_CFB_DELTA1    = 6'd27;
	localparam logic [5:0] ST_CFB_TERM1     = 6'd28;
	localparam logic [5:0] ST_CFB_MID       = 6'd29;
	localparam logic [5:0] ST_CFB_DECIDE2   = 6'd30;
	localparam logic [5:0] ST_CFB_DELTA2    = 6'd31;
	localparam logic [5:0] ST_CFB_TERM2     = 6'd32;
	localparam logic [5:0] ST_CFB_FINAL     = 6'd33;
	localparam logic [5:0] ST_CFB_COMMIT    = 6'd34;
	localparam logic [5:0] ST_COMMIT        = 6'd35;

	logic [5:0] state;
	logic signed [15:0] source_hold;

	logic signed [20:0] c7_q12, c154_q12, c17_q12, cfb_q12, c6_q12;
	logic                ic3d_hi, ic5b_hi, ic7c_hi;

	// Names shared with the Verilator diagnostic harness.
	logic signed [20:0] n_src_v;
	logic signed [20:0] bplus_v;
	logic signed [20:0] bout_v /* verilator public_flat */;
	logic signed [20:0] aplus_v;
	logic signed [20:0] aout_v /* verilator public_flat */;
	logic signed [20:0] n5bout_v /* verilator public_flat */;
	logic signed [20:0] n_c17_v /* verilator public_flat */;
	logic signed [20:0] n_loop_v /* verilator public_flat */;
	logic signed [20:0] b7plus_v;
	logic signed [20:0] b7out_v;
	logic signed [20:0] tr6_collector_v;
	logic signed [31:0] cfb_term_q12;
	logic signed [20:0] c7_next, c154_next, c17_next, cfb_next, c6_next;
	logic signed [20:0] tr1_load_q12, tr2_load_q12;
	logic               ic3d_next, ic5b_next, ic7c_next;

	logic signed [20:0] loop_delta_q12;
	logic signed [31:0] loop_delta_ext_q12;
	logic signed [31:0] loop_term_q12;
	logic signed [31:0] r87_delta_q12;
	logic signed [31:0] r84_delta_q12;

	function automatic logic signed [20:0] clamp_q12(
		input logic signed [31:0] value
	);
		begin
			if (value < 32'sd0)
				clamp_q12 = 21'sd0;
			else if (value > 32'sd43008)
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
			case (beta_q16)
				16'sd51:  alpha_delta_q12 = (delta_ext >>> 10) -
											 (delta_ext >>> 13) -
											 (delta_ext >>> 14) -
											 (delta_ext >>> 16);
				16'sd91:  alpha_delta_q12 = (delta_ext >>> 9) -
											 (delta_ext >>> 11) -
											 (delta_ext >>> 14) -
											 (delta_ext >>> 16);
				16'sd4:   alpha_delta_q12 = delta_ext >>> 14;
				16'sd191: alpha_delta_q12 = (delta_ext >>> 8) -
											 (delta_ext >>> 10) -
											 (delta_ext >>> 16);
				16'sd6:   alpha_delta_q12 = (delta_ext >>> 13) -
											 (delta_ext >>> 15);
				default:  alpha_delta_q12 = 32'sd0;
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
		logic signed [20:0] recovery_q12;
		logic signed [31:0] recovery_ext;
		begin
			delta = $signed(source) - $signed(plus);
			previous_ext = {{11{previous[20]}}, previous};
			plus_ext = {{11{plus[20]}}, plus};
			load_ext = {{11{load_q12[20]}}, load_q12};
			result = previous_ext + alpha_delta_q12(delta, beta_q16);
			q_pred = result - load_ext;
			output_pred = plus_ext - q_pred;
			if (output_pred < 0) begin
				recovery_q12 = alpha_step_q12(previous, source, beta_q16);
				recovery_ext = {{11{recovery_q12[20]}}, recovery_q12};
				opamp_cap_step_q12 = signed_clamp_q12(recovery_ext - load_ext);
			end else if (output_pred > 32'sd43008) begin
				recovery_q12 = alpha_step_q12(previous, source - VMAX_Q12, beta_q16);
				recovery_ext = {{11{recovery_q12[20]}}, recovery_q12};
				opamp_cap_step_q12 = signed_clamp_q12(recovery_ext - load_ext);
			end else begin
				opamp_cap_step_q12 = signed_clamp_q12(q_pred);
			end
		end
	endfunction

	function automatic logic signed [20:0] collector_load_q12(
		input logic drive_hi,
		input logic signed [20:0] collector_drive,
		input logic signed [15:0] resistor_shift
	);
		logic signed [31:0] overdrive;
		begin
			overdrive = $signed({{11{collector_drive[20]}}, collector_drive}) -
						$signed({{11{VCE_SAT_Q12[20]}}, VCE_SAT_Q12});
			if (!drive_hi || overdrive <= 0 ||
				VMAX_Q12 <= (VF_Q12 + VBE_Q12)) begin
				collector_load_q12 = 21'sd0;
			end else begin
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

	function automatic logic schmitt_next(
		input logic current_hi,
		input logic signed [20:0] value
	);
		begin
			if (!current_hi)
				schmitt_next = (value <= SCHMITT_LO_Q12);
			else
				schmitt_next = !(value >= SCHMITT_HI_Q12);
		end
	endfunction

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			state             <= ST_IDLE;
			source_hold       <= 16'sd0;
			c7_q12            <= 21'sd0;
			c154_q12          <= 21'sd0;
			c17_q12           <= 21'sd0;
			cfb_q12           <= 21'sd0;
			c6_q12            <= 21'sd0;
			ic3d_hi           <= 1'b0;
			ic5b_hi           <= 1'b0;
			ic7c_hi           <= 1'b0;
			n_src_v           <= 21'sd0;
			bplus_v           <= 21'sd0;
			bout_v            <= 21'sd0;
			aplus_v           <= 21'sd0;
			aout_v            <= 21'sd0;
			n5bout_v          <= 21'sd0;
			n_c17_v           <= 21'sd0;
			n_loop_v          <= TACHO_Q12;
			b7plus_v          <= 21'sd0;
			b7out_v           <= 21'sd0;
			tr6_collector_v   <= 21'sd0;
			cfb_term_q12      <= 32'sd0;
			c7_next           <= 21'sd0;
			c154_next         <= 21'sd0;
			c17_next          <= 21'sd0;
			cfb_next          <= 21'sd0;
			c6_next           <= 21'sd0;
			tr1_load_q12      <= 21'sd0;
			tr2_load_q12      <= 21'sd0;
			ic3d_next         <= 1'b0;
			ic5b_next         <= 1'b0;
			ic7c_next         <= 1'b0;
			loop_delta_q12    <= 21'sd0;
			loop_delta_ext_q12<= 32'sd0;
			loop_term_q12     <= 32'sd0;
			r87_delta_q12     <= 32'sd0;
			r84_delta_q12     <= 32'sd0;
			n_bout_ac         <= 16'sd0;
			mycar_cont_ac     <= 16'sd0;
			n_bout_v_q12      <= VREF6_Q12;
			mycar_cont_v_q12  <= TACHO_Q12;
		end else begin
			case (state)
				ST_IDLE: begin
					// Ignore a new request while a transaction is active.
					// In hardware sample_ce is one pulse every ~832 clocks.
					if (sample_ce) begin
						source_hold <= source_in;
						state <= ST_CAPTURE;
					end
				end

				ST_CAPTURE: begin
					n_src_v <= clamp_q12(
						$signed({{11{VREF6_Q12[20]}}, VREF6_Q12}) +
						$signed({{16{source_hold[15]}}, source_hold}));
					state <= ST_C7_BASE;
				end

				ST_C7_BASE: begin
					bplus_v <= n_src_v >>> 1;
					c7_next <= opamp_cap_step_q12(
						c7_q12, n_src_v, n_src_v >>> 1, C7_BETA_Q16, 21'sd0);
					state <= ST_C7_OUT0;
				end
				ST_C7_OUT0: begin
					bout_v <= clamp_q12(
						$signed({{11{bplus_v[20]}}, bplus_v}) -
						$signed({{11{c7_next[20]}}, c7_next}));
					state <= ST_C7_LOAD1;
				end
				ST_C7_LOAD1: begin
					ic3d_next <= schmitt_next(ic3d_hi, bout_v);
					tr1_load_q12 <= collector_load_q12(
						schmitt_next(ic3d_hi, bout_v),
						clamp_q12($signed({{11{c7_next[20]}}, c7_next}) +
								  $signed({{11{bout_v[20]}}, bout_v})),
						16'sd9);
					state <= ST_C7_APPLY1;
				end
				ST_C7_APPLY1: begin
					c7_next <= opamp_cap_step_q12(
						c7_q12, n_src_v, bplus_v, C7_BETA_Q16, tr1_load_q12);
					state <= ST_C7_OUT1;
				end
				ST_C7_OUT1: begin
					bout_v <= clamp_q12(
						$signed({{11{bplus_v[20]}}, bplus_v}) -
						$signed({{11{c7_next[20]}}, c7_next}));
					state <= ST_C7_LOAD2;
				end
				ST_C7_LOAD2: begin
					ic3d_next <= schmitt_next(ic3d_hi, bout_v);
					tr1_load_q12 <= collector_load_q12(
						schmitt_next(ic3d_hi, bout_v),
						clamp_q12($signed({{11{c7_next[20]}}, c7_next}) +
								  $signed({{11{bout_v[20]}}, bout_v})),
						16'sd9);
					state <= ST_C7_APPLY2;
				end
				ST_C7_APPLY2: begin
					c7_next <= opamp_cap_step_q12(
						c7_q12, n_src_v, bplus_v, C7_BETA_Q16, tr1_load_q12);
					state <= ST_C7_FINAL;
				end
				ST_C7_FINAL: begin
					bout_v <= clamp_q12(
						$signed({{11{bplus_v[20]}}, bplus_v}) -
						$signed({{11{c7_next[20]}}, c7_next}));
					state <= ST_C154_BASE;
				end

				ST_C154_BASE: begin
					aplus_v <= n_src_v >>> 1;
					c154_next <= opamp_cap_step_q12(
						c154_q12, n_src_v, n_src_v >>> 1,
						C154_BETA_Q16, 21'sd0);
					state <= ST_C154_OUT0;
				end
				ST_C154_OUT0: begin
					aout_v <= clamp_q12(
						$signed({{11{aplus_v[20]}}, aplus_v}) -
						$signed({{11{c154_next[20]}}, c154_next}));
					state <= ST_C154_LOAD1;
				end
				ST_C154_LOAD1: begin
					ic5b_next <= schmitt_next(ic5b_hi, aout_v);
					tr2_load_q12 <= collector_load_q12(
						schmitt_next(ic5b_hi, aout_v),
						clamp_q12($signed({{11{c154_next[20]}}, c154_next}) +
								  $signed({{11{aout_v[20]}}, aout_v})),
						16'sd8);
					state <= ST_C154_APPLY1;
				end
				ST_C154_APPLY1: begin
					c154_next <= opamp_cap_step_q12(
						c154_q12, n_src_v, aplus_v,
						C154_BETA_Q16, tr2_load_q12);
					state <= ST_C154_OUT1;
				end
				ST_C154_OUT1: begin
					aout_v <= clamp_q12(
						$signed({{11{aplus_v[20]}}, aplus_v}) -
						$signed({{11{c154_next[20]}}, c154_next}));
					state <= ST_C154_LOAD2;
				end
				ST_C154_LOAD2: begin
					ic5b_next <= schmitt_next(ic5b_hi, aout_v);
					tr2_load_q12 <= collector_load_q12(
						schmitt_next(ic5b_hi, aout_v),
						clamp_q12($signed({{11{c154_next[20]}}, c154_next}) +
								  $signed({{11{aout_v[20]}}, aout_v})),
						16'sd8);
					state <= ST_C154_APPLY2;
				end
				ST_C154_APPLY2: begin
					c154_next <= opamp_cap_step_q12(
						c154_q12, n_src_v, aplus_v,
						C154_BETA_Q16, tr2_load_q12);
					state <= ST_C154_FINAL;
				end
				ST_C154_FINAL: begin
					aout_v <= clamp_q12(
						$signed({{11{aplus_v[20]}}, aplus_v}) -
						$signed({{11{c154_next[20]}}, c154_next}));
					state <= ST_C17_STEP;
				end

				ST_C17_STEP: begin
					n5bout_v <= ic5b_next ? VMAX_Q12 : 21'sd0;
					c17_next <= alpha_step_q12(
						c17_q12,
						$signed(aout_v) - $signed(TACHO_Q12),
						C17_BETA_Q16);
					state <= ST_C17_OUT;
				end
				ST_C17_OUT: begin
					n_c17_v <= clamp_q12(
						$signed({{11{aout_v[20]}}, aout_v}) -
						$signed({{11{c17_next[20]}}, c17_next}));
					state <= ST_LOOP_DELTA;
				end
				ST_LOOP_DELTA: begin
					loop_delta_q12 <= $signed(TACHO_Q12) - $signed(n_c17_v);
					state <= ST_LOOP_EXT;
				end
				ST_LOOP_EXT: begin
					loop_delta_ext_q12 <= {{10{loop_delta_q12[20]}}, loop_delta_q12};
					state <= ST_LOOP_TERM;
				end
				ST_LOOP_TERM: begin
					loop_term_q12 <= (loop_delta_ext_q12 >>> 1) +
									 (loop_delta_ext_q12 >>> 3) +
									 (loop_delta_ext_q12 >>> 5) +
									 (loop_delta_ext_q12 >>> 7) +
									 (loop_delta_ext_q12 >>> 9);
					state <= ST_LOOP_OUT;
				end
				ST_LOOP_OUT: begin
					n_loop_v <= clamp_q12(
						$signed({{11{TACHO_Q12[20]}}, TACHO_Q12}) +
						$signed(loop_term_q12));
					state <= ST_CFB_PLUS;
				end

				ST_CFB_PLUS: begin
					b7plus_v <= n_loop_v >>> 1;
					state <= ST_CFB_OUT0;
				end
				ST_CFB_OUT0: begin
					b7out_v <= clamp_q12(
						$signed({{11{b7plus_v[20]}}, b7plus_v}) -
						$signed({{11{cfb_q12[20]}}, cfb_q12}));
					state <= ST_CFB_DECIDE1;
				end
				ST_CFB_DECIDE1: begin
					ic7c_next <= schmitt_next(ic7c_hi, b7out_v);
					tr6_collector_v <= schmitt_next(ic7c_hi, b7out_v) ?
									   VCE_SAT_Q12 : b7out_v;
					state <= ST_CFB_DELTA1;
				end
				ST_CFB_DELTA1: begin
					r87_delta_q12 <=
						$signed({{11{b7plus_v[20]}}, b7plus_v}) -
						$signed({{11{n_loop_v[20]}}, n_loop_v});
					r84_delta_q12 <=
						$signed({{11{b7plus_v[20]}}, b7plus_v}) -
						$signed({{11{tr6_collector_v[20]}}, tr6_collector_v});
					state <= ST_CFB_TERM1;
				end
				ST_CFB_TERM1: begin
					cfb_term_q12 <= (r87_delta_q12 >>> 9) +
									(r87_delta_q12 >>> 10) +
									(r84_delta_q12 >>> 7) -
									(r84_delta_q12 >>> 9) +
									(r84_delta_q12 >>> 12);
					state <= ST_CFB_MID;
				end
				ST_CFB_MID: begin
					b7out_v <= clamp_q12(
						$signed({{11{b7plus_v[20]}}, b7plus_v}) -
						$signed({{11{cfb_q12[20]}}, cfb_q12}) +
						$signed(cfb_term_q12));
					state <= ST_CFB_DECIDE2;
				end
				ST_CFB_DECIDE2: begin
					ic7c_next <= schmitt_next(ic7c_hi, b7out_v);
					tr6_collector_v <= schmitt_next(ic7c_hi, b7out_v) ?
									   VCE_SAT_Q12 : b7out_v;
					state <= ST_CFB_DELTA2;
				end
				ST_CFB_DELTA2: begin
					r87_delta_q12 <=
						$signed({{11{b7plus_v[20]}}, b7plus_v}) -
						$signed({{11{n_loop_v[20]}}, n_loop_v});
					r84_delta_q12 <=
						$signed({{11{b7plus_v[20]}}, b7plus_v}) -
						$signed({{11{tr6_collector_v[20]}}, tr6_collector_v});
					state <= ST_CFB_TERM2;
				end
				ST_CFB_TERM2: begin
					cfb_term_q12 <= (r87_delta_q12 >>> 9) +
									(r87_delta_q12 >>> 10) +
									(r84_delta_q12 >>> 7) -
									(r84_delta_q12 >>> 9) +
									(r84_delta_q12 >>> 12);
					state <= ST_CFB_FINAL;
				end
				ST_CFB_FINAL: begin
					b7out_v <= clamp_q12(
						$signed({{11{b7plus_v[20]}}, b7plus_v}) -
						$signed({{11{cfb_q12[20]}}, cfb_q12}) +
						$signed(cfb_term_q12));
					state <= ST_CFB_COMMIT;
				end
				ST_CFB_COMMIT: begin
					cfb_next <= signed_clamp_q12(
						$signed({{11{b7plus_v[20]}}, b7plus_v}) -
						$signed({{11{b7out_v[20]}}, b7out_v}));
					c6_next <= alpha_step_q12(
						c6_q12,
						$signed(n_loop_v) - $signed(b7out_v),
						C6_BETA_Q16);
					state <= ST_COMMIT;
				end

				ST_COMMIT: begin
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
					state <= ST_IDLE;
				end

				default: state <= ST_IDLE;
			endcase
		end
	end
endmodule
