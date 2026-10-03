// Shared Turbo S2688 noise source (IC8, D-3/11 and D-4/11).
//
// The board has one physical S2688 (MM5837) noise IC, so CRASH and SKID consume this one
// stream rather than separate pseudo-noise generators. It is modelled as a 17-bit binary
// LFSR running at the documented typical 100 kHz internal oscillator. The physical output
// is integrated over each audio sample interval, so downstream analogue networks see the
// interval average rather than an aliased last-bit sample.
//
// The source amplitude is a single named assumption: 9.5 Vpp, not a confirmed S2688
// specification. A compile-time override exists only for the 7.0/9.5/12.0 Vpp sensitivity
// sweep:
//   +define+TURBO_S2688_SOURCE_VPP_LSB=<Vpp * 4096>
// No analogue gain or downstream normalization is hidden here.
module turbo_s2688_noise (
	input  logic               clk,
	input  logic               rst_n,
	input  logic               sample_ce,
	// Effective, interval-averaged source consumed by CRASH and SKID.
	output logic signed [15:0] noise_raw,
	// Optional physical-bit diagnostic. This is the binary source level at
	// the beginning of the interval represented by noise_raw.
	output logic signed [15:0] noise_physical,
	// Diagnostics for checking the fractional source/audio-rate relationship.
	output logic        [2:0]  source_ticks_last,
	output logic        [31:0] source_phase_q32,
	output logic [15:0] dbg_scheduler_cycles_last,
	output logic [15:0] dbg_scheduler_cycles_max
);

`ifdef TURBO_S2688_SOURCE_VPP_LSB
	localparam int SOURCE_VPP_LSB = `TURBO_S2688_SOURCE_VPP_LSB;
`else
		// Default assumption: 9.5 Vpp in the 4096 LSB/V house format.
	localparam int SOURCE_VPP_LSB = 38912;
`endif
	localparam int SOURCE_HALF_LSB = SOURCE_VPP_LSB / 2;
	localparam logic signed [15:0] SOURCE_HALF = 16'(SOURCE_HALF_LSB);
	localparam logic signed [63:0] SOURCE_HALF_Q12 = 64'(SOURCE_HALF_LSB);

	// sample_ce is clk/832 of the 39,935,064 Hz clock, i.e. 47,998.875 Hz. These constants
	// are 100,000 / 47,998.875 (source ticks per sample) and its reciprocal, unsigned Q32.
	localparam logic [33:0] SOURCE_TICKS_PER_SAMPLE_Q32 = 34'd8948058253;
	localparam logic signed [63:0] SAMPLE_PER_SOURCE_TICK_Q32 = 64'sd2061535984;
	localparam logic signed [63:0] Q32_ONE = 64'sd4294967296;

	// Assumed S2688 register convention: 17 bits, feedback from stages 17 and 14.
	localparam logic [16:0] LFSR_SEED = 17'h0B5E7;
	logic [17:1] lfsr;
	logic [31:0] phase_q32;

	function automatic logic [17:1] lfsr_step(input logic [17:1] value);
		begin
			lfsr_step = {value[16:1], value[17] ^ value[14]};
		end
	endfunction

	function automatic logic signed [63:0] bipolar_weight(
		input logic               one_level,
		input logic signed [63:0] weight
	);
		begin
			bipolar_weight = one_level ? weight : -weight;
		end
	endfunction

	// Widths: the area is bounded by three Q32 dwells (35 signed bits), the Q32 reciprocal is
	// a positive 32-bit value, the averaged Q16 result needs 18 signed bits and SOURCE_HALF
	// is a positive 16-bit Q12 value. A private multiplier lane performs both products.
	function automatic logic signed [63:0] sign_extend_width(
		input logic [63:0] value,
		input integer width
	);
		integer i;
		begin
			sign_extend_width = '0;
			for (i = 0; i < 64; i = i + 1)
				sign_extend_width[i] = (i < width) ? value[i] : value[width - 1];
		end
	endfunction

	function automatic logic signed [63:0] shifted_lane_product(
		input logic signed [127:0] product,
		input logic [6:0] shift
	);
		logic signed [127:0] shifted;
		begin
			shifted = product >>> shift;
			shifted_lane_product = shifted[63:0];
		end
	endfunction

	function automatic logic signed_ext_ok(
		input logic signed [63:0] value,
		input logic [6:0] width
	);
		integer i;
		begin
			signed_ext_ok = (width >= 1) && (width <= 64);
			if (signed_ext_ok)
				for (i = 0; i < 64; i = i + 1)
					if ((i >= width) && (value[i] != value[width - 1]))
						signed_ext_ok = 1'b0;
		end
	endfunction

	logic [17:1] lfsr_txn;
	logic [31:0] phase_txn;
	logic [33:0] phase_total_q32;
	logic [31:0] phase_next_q32;
	logic [2:0] source_ticks_next;
	logic [17:1] lfsr_next;
	logic signed [63:0] area_q32;
	logic signed [63:0] interval_weight_q32;
	logic signed [63:0] average_q16;
	logic signed [63:0] effective_q12;
	logic signed [15:0] physical_q12;

	always_comb begin
		phase_total_q32 = {2'b00, phase_txn} + SOURCE_TICKS_PER_SAMPLE_Q32;
		source_ticks_next = {1'b0, phase_total_q32[33:32]};
		phase_next_q32 = phase_total_q32[31:0];

		interval_weight_q32 = Q32_ONE - $signed({32'b0, phase_txn});
		area_q32 = bipolar_weight(lfsr_txn[17], interval_weight_q32);
		lfsr_next = lfsr_txn;
		for (int i = 1; i <= 3; i = i + 1) begin
			if (i <= source_ticks_next) begin
				lfsr_next = lfsr_step(lfsr_next);
				if (i < source_ticks_next)
					interval_weight_q32 = Q32_ONE;
				else
					interval_weight_q32 = $signed({32'b0, phase_next_q32});
				area_q32 = area_q32 + bipolar_weight(lfsr_next[17], interval_weight_q32);
			end
		end
		physical_q12 = lfsr_txn[17] ? SOURCE_HALF : -SOURCE_HALF;
	end

	function automatic logic signed [15:0] limit_source_q12(
		input logic signed [63:0] value
	);
		begin
			if (value > SOURCE_HALF_Q12)
				limit_source_q12 = SOURCE_HALF;
			else if (value < -SOURCE_HALF_Q12)
				limit_source_q12 = -SOURCE_HALF;
			else
				limit_source_q12 = value[15:0];
		end
	endfunction

	typedef enum logic [1:0] {S_IDLE, S_REQ, S_WAIT, S_READY} s_state_t;
	typedef enum logic {S_OP_AVERAGE, S_OP_SCALE} s_op_t;
	s_state_t s_state;
	s_op_t s_op;
	logic s_result_ready;
	logic [15:0] s_cycle_counter;
	logic signed [63:0] s_average_mul;
	logic signed [63:0] s_effective_mul;

	logic s_lane_req_valid, s_lane_req_ready;
	logic signed [63:0] s_lane_req_a, s_lane_req_b;
	logic [6:0] s_lane_req_a_width, s_lane_req_b_width;
	logic [7:0] s_lane_req_tag;
	logic s_lane_rsp_valid;
	logic signed [127:0] s_lane_rsp_product;
	logic [7:0] s_lane_rsp_tag;

	always_comb begin
		s_lane_req_a = 64'sd0;
		s_lane_req_b = 64'sd0;
		s_lane_req_a_width = 7'd1;
		s_lane_req_b_width = 7'd1;
		s_lane_req_tag = {7'd0, s_op};
		if (s_op == S_OP_AVERAGE) begin
			s_lane_req_a = sign_extend_width(area_q32, 35);
			s_lane_req_b = sign_extend_width(SAMPLE_PER_SOURCE_TICK_Q32, 32);
			s_lane_req_a_width = 7'd35;
			s_lane_req_b_width = 7'd32;
		end else begin
			s_lane_req_a = sign_extend_width(s_average_mul, 18);
			s_lane_req_b = sign_extend_width(SOURCE_HALF, 16);
			s_lane_req_a_width = 7'd18;
			s_lane_req_b_width = 7'd16;
		end
	end

	assign s_lane_req_valid = (s_state == S_REQ);

	shared_mul_lane u_s2688_shared_mul_lane (
		.clk(clk), .rst_n(rst_n),
		.req_valid(s_lane_req_valid), .req_ready(s_lane_req_ready),
		.req_a(s_lane_req_a), .req_b(s_lane_req_b),
		.req_a_width(s_lane_req_a_width), .req_b_width(s_lane_req_b_width),
		.req_tag(s_lane_req_tag),
		.rsp_valid(s_lane_rsp_valid), .rsp_product(s_lane_rsp_product),
		.rsp_tag(s_lane_rsp_tag)
	);

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			lfsr <= LFSR_SEED;
			phase_q32 <= 32'd0;
			noise_raw <= 16'sd0;
			noise_physical <= 16'sd0;
			source_ticks_last <= 3'd0;
			source_phase_q32 <= 32'd0;
			lfsr_txn <= LFSR_SEED;
			phase_txn <= 32'd0;
			s_state <= S_IDLE;
			s_op <= S_OP_AVERAGE;
			s_result_ready <= 1'b0;
			s_cycle_counter <= 16'd0;
			s_average_mul <= '0;
			s_effective_mul <= '0;
			dbg_scheduler_cycles_last <= 16'd0;
			dbg_scheduler_cycles_max <= 16'd0;
		end else begin
			if (s_state != S_IDLE && s_state != S_READY)
				s_cycle_counter <= s_cycle_counter + 1'b1;
			if (s_state == S_READY) begin
				if (sample_ce) begin
					lfsr <= lfsr_next;
					phase_q32 <= phase_next_q32;
					noise_raw <= limit_source_q12(s_effective_mul);
					noise_physical <= physical_q12;
					source_ticks_last <= source_ticks_next;
					source_phase_q32 <= phase_next_q32;
					s_result_ready <= 1'b0;
					s_state <= S_IDLE;
				end
			end else if (s_state == S_IDLE) begin
				lfsr_txn <= lfsr;
				phase_txn <= phase_q32;
				s_op <= S_OP_AVERAGE;
				s_cycle_counter <= 16'd0;
				s_state <= S_REQ;
			end else if (s_state == S_REQ) begin
				if (s_lane_req_ready)
					s_state <= S_WAIT;
			end else if (s_state == S_WAIT) begin
				if (s_lane_rsp_valid) begin
					if (s_op == S_OP_AVERAGE) begin
						s_average_mul <= shifted_lane_product(s_lane_rsp_product, 48);
						s_op <= S_OP_SCALE;
						s_state <= S_REQ;
					end else begin
						s_effective_mul <= shifted_lane_product(s_lane_rsp_product, 16);
						s_result_ready <= 1'b1;
						dbg_scheduler_cycles_last <= s_cycle_counter + 1'b1;
						if ((s_cycle_counter + 1'b1) > dbg_scheduler_cycles_max)
							dbg_scheduler_cycles_max <= s_cycle_counter + 1'b1;
						s_state <= S_READY;
					end
				end
			end
		end
	end

	always_ff @(posedge clk) begin
		if (rst_n) begin
			assert (!(s_lane_rsp_valid && (s_state != S_WAIT)))
				else $error("S2688 response with no pending request");
			if (s_lane_rsp_valid)
				assert (s_lane_rsp_tag == {7'd0, s_op})
					else $error("S2688 response tag/order mismatch");
			if (s_lane_req_valid && s_lane_req_ready) begin
				assert (signed_ext_ok(s_lane_req_a, s_lane_req_a_width))
					else $error("S2688 A sign extension");
				assert (signed_ext_ok(s_lane_req_b, s_lane_req_b_width))
					else $error("S2688 B sign extension");
			end
			if (sample_ce)
				assert (s_state == S_READY && s_result_ready)
					else $error("S2688 not complete at sample_ce");
			if (s_state == S_READY)
				assert (s_result_ready)
					else $error("S2688 READY without result");
		end else begin
			assert (s_state == S_IDLE && !s_result_ready)
				else $error("S2688 reset did not return idle");
		end
	end
endmodule
