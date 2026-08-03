// Exact, time-multiplexed signed multiplier for the discrete-audio pipeline.
//
// Cyclone V has a native 27x27 DSP multiplier. Existing audio equations also
// contain deliberately wide states (notably the very-low-frequency filters),
// so narrowing every operand to 27 bits would change their behavior. This lane
// instead decomposes each magnitude into 27-bit limbs and accumulates the exact
    // partial products. A native-width request takes three clocks (multiply,
    // accumulate, then respond); a full 64x64 request takes nineteen. Two instances can
// service the whole sample-rate graph during the 832 clk_sys clocks between
// sample_ce pulses while consuming two physical multiplier blocks.
//
// Operand widths describe the meaningful signed width, 1..64, and determine
// how many limbs are evaluated. Inputs must already be sign-extended to 64 bits.
// The 128-bit result is the exact two's-complement product. `rsp_valid` pulses
// for one clock; the caller must capture the result then.
module shared_mul_lane (
    input  logic                clk,
    input  logic                rst_n,

    input  logic                req_valid,
    output logic                req_ready,
    input  logic signed [63:0]  req_a,
    input  logic signed [63:0]  req_b,
    input  logic          [6:0] req_a_width,
    input  logic          [6:0] req_b_width,
    input  logic          [7:0] req_tag,

    output logic                rsp_valid,
    output logic signed [127:0] rsp_product,
    output logic          [7:0] rsp_tag
);

    typedef enum logic [1:0] {ST_MUL, ST_ACC, ST_RESP} state_t;

    logic busy;
    state_t state;

    logic [63:0] mag_a, mag_b;
    logic        negate_result;
    logic [1:0]  a_limbs, b_limbs;
    logic [1:0]  limb_a_idx, limb_b_idx;
    logic [7:0]  tag_latched;

    logic [26:0] limb_a, limb_b;
    logic [53:0] partial_product;
    logic [6:0]  partial_shift;
    logic [6:0]  selected_shift;
    logic [127:0] accumulator;
    logic [127:0] final_magnitude;

    // `partial_shift` can only be 0, 27, 54, 81, or 108.  Express those
    // placements structurally rather than as a variable barrel shifter.  The
    // high bits discarded in the 81/108 cases are provably zero: those cases
    // include a top (10-bit) limb, so their products occupy at most 37/20 bits.
    logic [127:0] shifted_partial;
    always_comb begin
        case (partial_shift)
            7'd0:   shifted_partial = {{74{1'b0}}, partial_product};
            7'd27:  shifted_partial = {{47{1'b0}}, partial_product, {27{1'b0}}};
            7'd54:  shifted_partial = {{20{1'b0}}, partial_product, {54{1'b0}}};
            7'd81:  shifted_partial = {partial_product[46:0], {81{1'b0}}};
            7'd108: shifted_partial = {partial_product[19:0], {108{1'b0}}};
            default: shifted_partial = 128'd0;
        endcase
    end
    wire [127:0] accumulated_next = accumulator + shifted_partial;
    wire last_partial = (limb_a_idx == a_limbs - 1'b1) &&
                        (limb_b_idx == b_limbs - 1'b1);

    assign req_ready = !busy;

    function automatic logic [1:0] limb_count(input logic [6:0] width);
        if (width <= 7'd27)      limb_count = 2'd1;
        else if (width <= 7'd54) limb_count = 2'd2;
        else                     limb_count = 2'd3;
    endfunction

    // The limb selectors are combinational muxes from registered request
    // state. `partial_product` directly registers the bare 27x27 multiply,
    // the inference shape Quartus can pack into a DSP output register.
    always_comb begin
        case (limb_a_idx)
            2'd0: limb_a = mag_a[26:0];
            2'd1: limb_a = mag_a[53:27];
            default: limb_a = {17'd0, mag_a[63:54]};
        endcase
        case (limb_b_idx)
            2'd0: limb_b = mag_b[26:0];
            2'd1: limb_b = mag_b[53:27];
            default: limb_b = {17'd0, mag_b[63:54]};
        endcase
        case ({1'b0, limb_a_idx} + {1'b0, limb_b_idx})
            3'd0: selected_shift = 7'd0;
            3'd1: selected_shift = 7'd27;
            3'd2: selected_shift = 7'd54;
            3'd3: selected_shift = 7'd81;
            default: selected_shift = 7'd108;
        endcase
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            busy            <= 1'b0;
            state           <= ST_MUL;
            mag_a           <= 64'd0;
            mag_b           <= 64'd0;
            negate_result   <= 1'b0;
            a_limbs         <= 2'd1;
            b_limbs         <= 2'd1;
            limb_a_idx      <= 2'd0;
            limb_b_idx      <= 2'd0;
            tag_latched     <= 8'd0;
            partial_product <= 54'd0;
            partial_shift   <= 7'd0;
            accumulator     <= 128'd0;
            final_magnitude <= 128'd0;
            rsp_valid       <= 1'b0;
            rsp_product     <= 128'sd0;
            rsp_tag         <= 8'd0;
        end else begin
            rsp_valid <= 1'b0;

            if (!busy) begin
                if (req_valid) begin
                    // Unsigned two's-complement magnitude also handles the
                    // most-negative value: 0 - 0x8000... = 0x8000....
                    mag_a         <= req_a[63] ? (64'd0 - $unsigned(req_a)) : $unsigned(req_a);
                    mag_b         <= req_b[63] ? (64'd0 - $unsigned(req_b)) : $unsigned(req_b);
                    negate_result <= req_a[63] ^ req_b[63];
                    a_limbs       <= limb_count(req_a_width);
                    b_limbs       <= limb_count(req_b_width);
                    limb_a_idx    <= 2'd0;
                    limb_b_idx    <= 2'd0;
                    tag_latched   <= req_tag;
                    accumulator   <= 128'd0;
                    state         <= ST_MUL;
                    busy          <= 1'b1;
                end
            end else if (state == ST_MUL) begin
                partial_product <= limb_a * limb_b;
                partial_shift   <= selected_shift;
                state           <= ST_ACC;
            end else if (state == ST_ACC) begin
                if (last_partial) begin
                    // Register the completed magnitude before applying its
                    // sign. This keeps the 128-bit negate out of the
                    // shift/add accumulator hop.
                    final_magnitude <= accumulated_next;
                    state <= ST_RESP;
                end else begin
                    accumulator <= accumulated_next;
                    if (limb_b_idx == b_limbs - 1'b1) begin
                        limb_b_idx <= 2'd0;
                        limb_a_idx <= limb_a_idx + 1'b1;
                    end else begin
                        limb_b_idx <= limb_b_idx + 1'b1;
                    end
                    state <= ST_MUL;
                end
            end else begin
                rsp_product <= negate_result ? -$signed(final_magnitude)
                                             :  $signed(final_magnitude);
                rsp_tag     <= tag_latched;
                rsp_valid   <= 1'b1;
                busy        <= 1'b0;
            end
        end
    end

endmodule
