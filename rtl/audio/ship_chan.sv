// SHIP engine channel (sheet 1).  All sample-rate arithmetic is issued through
// one tagged shared-multiplier client.  The three VCO integrators remain at
// clk_sys so their threshold crossings retain their 25 ns resolution.
module ship_chan (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic               ship_on,
    input  logic         [3:0] acc,
    output logic signed [15:0] ship_mix,

    output logic               mul_req_valid,
    input  logic               mul_req_ready,
    output logic signed [63:0] mul_req_a,
    output logic signed [63:0] mul_req_b,
    output logic         [6:0] mul_req_a_width,
    output logic         [6:0] mul_req_b_width,
    output logic         [7:0] mul_req_tag,
    input  logic               mul_rsp_valid,
    input  logic signed [127:0] mul_rsp_product,
    input  logic         [7:0] mul_rsp_tag
);
    localparam logic signed [31:0] A_555_CH_Q24  = 32'sd16725893;
    localparam logic signed [31:0] B_555_CH_Q24  = 32'sd51323;
    localparam logic signed [31:0] A_555_DIS_Q24 = 32'sd16775468;
    localparam logic signed [39:0] V_CHG_TARGET = 40'sd191260262;
    localparam logic signed [39:0] TH_HI_555    = 40'sd134217728;
    localparam logic signed [39:0] TH_LO_555    = 40'sd67108864;
    localparam logic signed [39:0] V_TWELVE     = 40'sd201326592;
    localparam logic signed [39:0] TRI_MEAN     = 40'sd96413438;
    localparam logic signed [26:0] RECIP832_Q32 = 27'sd5162220;

    localparam logic signed [39:0] ACC_V_LUT [0:15] = '{
        40'sd0,40'sd21883325,40'sd50331648,40'sd62984856,
        40'sd77433305,40'sd86082051,40'sd98521524,40'sd104548201,
        40'sd167772160,40'sd168440575,40'sd169538183,40'sd170138719,
        40'sd170937672,40'sd171486953,40'sd172393429,40'sd172891776
    };
    localparam logic signed [31:0] ACC_A_LUT [0:15] = '{
        32'sd16776157,32'sd16776028,32'sd16775804,32'sd16775675,
        32'sd16775495,32'sd16775366,32'sd16775142,32'sd16775013,
        32'sd16770862,32'sd16770733,32'sd16770509,32'sd16770380,
        32'sd16770200,32'sd16770071,32'sd16769847,32'sd16769718
    };

    logic signed [39:0] v_c12, v_acc;
    logic c12_charging;
    wire signed [39:0] acc_target = ACC_V_LUT[acc];
    wire signed [31:0] acc_a = ACC_A_LUT[acc];
    wire signed [31:0] acc_b = 32'sd16777216 - acc_a;

    logic signed [39:0] step_tr2_up, step_tr2_dn, step_tr4_up, step_tr4_dn;
    logic signed [39:0] step_tr5_up, step_tr5_dn;
    logic signed [39:0] vint_acc_tr2, vint_acc_tr4, vint_acc_tr5;

    relax_vco u_tr2 (.clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .step_up_next(step_tr2_up), .step_dn_next(step_tr2_dn), .vint_acc(vint_acc_tr2), .vint());
    relax_vco u_tr4 (.clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .step_up_next(step_tr4_up), .step_dn_next(step_tr4_dn), .vint_acc(vint_acc_tr4), .vint());
    relax_vco u_tr5 (.clk(clk), .rst_n(rst_n), .sample_ce(sample_ce),
        .step_up_next(step_tr5_up), .step_dn_next(step_tr5_dn), .vint_acc(vint_acc_tr5), .vint());

    logic signed [39:0] avg_tr2, avg_tr4;
    logic signed [39:0] avg_tr2_prev, avg_tr4_prev, avg_tr5_prev;
    // Tr4/Tr5 DC requests are issued after the average-history registers
    // advance. Preserve each pre-advance input for this sample transaction.
    logic signed [39:0] dc_in_tr4, dc_in_tr5;
    logic signed [39:0] dc_cap_tr2, dc_cap_tr4, dc_cap_tr5;
    logic signed [47:0] dc_next_tr2, dc_next_tr4, dc_next_tr5;
    logic dc_commit_tr2, dc_commit_tr4, dc_commit_tr5;
    logic signed [39:0] hp_tr2, hp_tr4, hp_tr5;

    dc_block u_dc_tr2 (.clk(clk), .rst_n(rst_n), .commit_valid(dc_commit_tr2),
        .x_in(avg_tr2_prev), .x_capture(dc_cap_tr2), .x_reset(TRI_MEAN), .y_next(dc_next_tr2), .hp_sum(hp_tr2), .y_out());
    dc_block u_dc_tr4 (.clk(clk), .rst_n(rst_n), .commit_valid(dc_commit_tr4),
        .x_in(dc_in_tr4), .x_capture(dc_cap_tr4), .x_reset(TRI_MEAN), .y_next(dc_next_tr4), .hp_sum(hp_tr4), .y_out());
    dc_block u_dc_tr5 (.clk(clk), .rst_n(rst_n), .commit_valid(dc_commit_tr5),
        .x_in(dc_in_tr5), .x_capture(dc_cap_tr5), .x_reset(TRI_MEAN), .y_next(dc_next_tr5), .hp_sum(hp_tr5), .y_out());

    localparam logic signed [26:0] DC_A_TR2_TR5 = 27'sd16776494;
    localparam logic signed [26:0] DC_A_TR4     = 27'sd16775627;
    localparam logic signed [31:0] IC26_GAIN_Q24 = -32'sd2287697;
    localparam logic signed [31:0] CTRL_GAIN_Q24 = -32'sd8556380;
    localparam logic signed [31:0] VREF_SCALED   = 32'sd3122076;
    localparam logic signed [31:0] OUT_GAIN_Q16  = -32'sd144179;
    localparam logic signed [31:0] RAIL_HI = 32'sd18432;
    localparam logic signed [31:0] RAIL_LO = -32'sd24576;

    localparam int LUT_SIZE = 65;
    localparam logic [31:0] VCA_GAIN_LUT [0:LUT_SIZE-1] = '{
        32'd292739,32'd292739,32'd292739,32'd292739,32'd292739,32'd292739,32'd292739,32'd292739,
        32'd292739,32'd292739,32'd292739,32'd292739,32'd292739,32'd292739,32'd292739,32'd292739,
        32'd292739,32'd292739,32'd253501,32'd176901,32'd123447,32'd86145,32'd60115,32'd41950,
        32'd29274,32'd21952,32'd16462,32'd12345,32'd9257,32'd6942,32'd5206,32'd3904,
        32'd2927,32'd2195,32'd1646,32'd1234,32'd926,32'd694,32'd521,32'd390,
        32'd293,32'd220,32'd165,32'd123,32'd93,32'd69,32'd52,32'd39,
        32'd29,32'd25,32'd22,32'd19,32'd16,32'd14,32'd12,32'd11,
        32'd9,32'd9,32'd9,32'd9,32'd9,32'd9,32'd9,32'd9,32'd9
    };
    localparam logic signed [31:0] V2_MIN_SCALED = 32'sd2097152;
    localparam logic signed [31:0] V2_MAX_SCALED = 32'sd6291455;

    // {gain_base[20:0], gain_delta[20:0], frac[16:0]}; interpolation itself
    // is a tagged MAC operation rather than a hidden function multiplier.
    function automatic logic [58:0] vca_lut_params(input logic signed [31:0] v2_in);
        logic signed [31:0] v2c;
        logic [31:0] off;
        logic [6:0] idx;
        logic [15:0] frac;
        logic [31:0] lo, hi;
        begin
            v2c = (v2_in < V2_MIN_SCALED) ? V2_MIN_SCALED :
                  (v2_in > V2_MAX_SCALED) ? V2_MAX_SCALED : v2_in;
            off = v2c - V2_MIN_SCALED;
            idx = off[22:16]; frac = off[15:0];
            lo = VCA_GAIN_LUT[idx]; hi = VCA_GAIN_LUT[idx + 7'd1];
            vca_lut_params = {21'($signed({1'b0,lo})),
                              21'($signed({1'b0,hi})-$signed({1'b0,lo})),
                              1'b0, frac};
        end
    endfunction

    localparam logic [7:0] TAG_SHIP_BASE = 8'h50;
    // The original ACC low-pass was a free-running two-product pipeline.
    // Keep a separate tag for the short catch-up transaction used when the
    // PPI latch changes while the serialized sample graph is otherwise idle.
    localparam logic [7:0] TAG_SHIP_ACC_A = 8'h70;
    localparam logic [7:0] TAG_SHIP_ACC_B = 8'h71;
    logic [4:0] op_index;
    logic waiting_response, running, next_valid;
    logic [1:0] start_delay;
    logic signed [63:0] c12_a_w, acc_a_w;
    logic signed [63:0] acc_refresh_a_w;
    logic signed [39:0] next_c12, next_acc;
    logic next_charging;
    logic [3:0] acc_seen, acc_refresh_code;
    logic [1:0] acc_refresh_state;
    logic acc_refresh_pending;
    logic signed [31:0] vca_in_work;
    logic signed [31:0] ac_tr2_work, ac_tr4_work;
    logic signed [20:0] gain_base_work;
    logic signed [31:0] ship_sample;

    wire signed [39:0] vs_half_tr2 = (V_TWELVE-v_c12) >>> 1;
    wire signed [39:0] vs_half_tr4 = v_acc >>> 1;
    wire signed [39:0] vs_half_tr5 = v_c12 >>> 1;
    wire signed [39:0] rsp_q40 = 40'(mul_rsp_product >>> 40);
    wire signed [39:0] rsp_avg_q24 = 40'((mul_rsp_product + 128'sd2147483648) >>> 32);
    wire signed [47:0] rsp_dc_q32 = 48'((mul_rsp_product + 128'sd8388608) >>> 24);
    // The legacy registered tail added half an output LSB before both
    // Q24 conversions (IC26 and the IC22C control leg).  Keep that rounding
    // local to those two response operations; the generic Q24 response is
    // intentionally truncating for other uses.
    wire signed [31:0] rsp_q24_round = 32'((mul_rsp_product + 128'sd8388608) >>> 24);
    // The final VCA and IC28 gain stages both retained half-LSB rounding in
    // the legacy registered pipeline.
    wire signed [31:0] rsp_q16_round = 32'((mul_rsp_product + 128'sd32768) >>> 16);
    wire signed [20:0] rsp_gain_q16 = 21'(mul_rsp_product >>> 16);
    wire signed [58:0] vca_params_next = vca_lut_params(VREF_SCALED + rsp_q24_round);

    task automatic issue_multiply(
        input logic signed [63:0] a, input logic signed [63:0] b,
        input logic [6:0] aw, input logic [6:0] bw, input logic [7:0] tag
    ); begin
        mul_req_a <= a; mul_req_b <= b; mul_req_a_width <= aw; mul_req_b_width <= bw;
        mul_req_tag <= tag; mul_req_valid <= 1'b1;
    end endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            v_c12 <= '0; v_acc <= '0; c12_charging <= 1'b1;
            // Exact first raw-sample values from the old registered pipeline.
            next_c12 <= 40'sd585082; next_acc <= '0; next_charging <= 1'b1;
            step_tr2_up <= 40'sd2026; step_tr2_dn <= 40'sd1680;
            step_tr4_up <= '0; step_tr4_dn <= '0; step_tr5_up <= '0; step_tr5_dn <= '0;
            // relax_vco's registered average resets to zero (its accumulator
            // reset), while the DC caps themselves reset x_d to TRI_MEAN.
            // Starting these handoff registers at TRI_MEAN advances Tr4/Tr5
            // by a phantom sample and changes their high-pass phase.
            avg_tr2 <= '0; avg_tr4 <= '0;
            avg_tr2_prev <= '0; avg_tr4_prev <= '0; avg_tr5_prev <= '0;
            dc_in_tr4 <= '0; dc_in_tr5 <= '0;
            dc_cap_tr2 <= '0; dc_cap_tr4 <= '0; dc_cap_tr5 <= '0;
            dc_next_tr2 <= '0; dc_next_tr4 <= '0; dc_next_tr5 <= '0;
            dc_commit_tr2 <= 1'b0; dc_commit_tr4 <= 1'b0; dc_commit_tr5 <= 1'b0;
            op_index <= '0; waiting_response <= 1'b0; running <= 1'b0;
            next_valid <= 1'b1; start_delay <= '0;
            c12_a_w <= '0; acc_a_w <= '0; acc_refresh_a_w <= '0;
            acc_seen <= 4'd0; acc_refresh_code <= 4'd0;
            acc_refresh_state <= 2'd0; acc_refresh_pending <= 1'b0;
            vca_in_work <= '0; gain_base_work <= '0;
            ac_tr2_work <= '0; ac_tr4_work <= '0; ship_sample <= '0; ship_mix <= '0;
            mul_req_valid <= 1'b0; mul_req_a <= '0; mul_req_b <= '0;
            mul_req_a_width <= 7'd1; mul_req_b_width <= 7'd1; mul_req_tag <= '0;
        end else begin
            dc_commit_tr2 <= 1'b0; dc_commit_tr4 <= 1'b0; dc_commit_tr5 <= 1'b0;
            // IC10 is an asynchronous 4066 level gate after the VCA.  Do
            // not sample SHIP ON when the serialized tail starts: a port
            // change can occur while that graph is in flight and must affect
            // the already-computed audio before the next sample CE.
            ship_mix <= ship_on ? ship_sample[15:0] : 16'sd0;
            // IC6 is asynchronous to the 48 kHz sample enable.  In the
            // legacy design its two registered multipliers continue running
            // after this latch changes, so their already-pending result is
            // available at the immediately following sample CE.  The main
            // serialized graph has normally finished by then; remember the
            // real latch transition and refresh that pending result through
            // the same shared MAC lane.
            if (acc != acc_seen) begin
                acc_seen <= acc;
                acc_refresh_pending <= 1'b1;
            end
            if (mul_req_valid && mul_req_ready) begin
                mul_req_valid <= 1'b0;
                waiting_response <= 1'b1;
            end
            if (sample_ce) begin
                if (next_valid) begin
                    v_c12 <= next_c12; v_acc <= next_acc; c12_charging <= next_charging;
                    // Each VCO consumes the controls calculated over the
                    // preceding sample window, just as before the migration.
                    step_tr2_up <= step_tr2_up; step_tr2_dn <= step_tr2_dn;
                    step_tr4_up <= step_tr4_up; step_tr4_dn <= step_tr4_dn;
                    step_tr5_up <= step_tr5_up; step_tr5_dn <= step_tr5_dn;
                    next_valid <= 1'b0;
                end
                // Let the VCO window state settle before beginning the
                // serialized graph.  SHIP ON itself is gated at the output
                // stage below, so this delay does not add control latency.
                start_delay <= 2'd2;
            end else if (start_delay != 0) begin
                start_delay <= start_delay - 1'b1;
            end
            if (!running && !waiting_response && !mul_req_valid && !acc_refresh_pending &&
                (acc == acc_seen) && start_delay == 2'd1) begin
                // At this point sample_ce's state commits and all three VCO
                // window sums are stable.  The complete graph fits easily
                // before the next CE (worst case < 300 clk_sys clocks).
                running <= 1'b1; op_index <= 5'd0;
                issue_multiply(64'(c12_charging ? A_555_CH_Q24 : A_555_DIS_Q24),64'(v_c12),7'd32,7'd40,TAG_SHIP_BASE);
            end
            // Give an actual ACC-latch transition priority over launching a
            // new bulk graph.  It is only two MACs, and restores the old
            // always-running pipeline's CE visibility without instantiating
            // any dedicated DSPs.
            if (acc_refresh_pending && !waiting_response && !mul_req_valid && !running) begin
                acc_refresh_code <= acc;
                acc_refresh_pending <= 1'b0;
                acc_refresh_state <= 2'd1;
                issue_multiply(64'(ACC_A_LUT[acc]),64'(v_acc),7'd32,7'd40,TAG_SHIP_ACC_A);
            end
            if (mul_rsp_valid && waiting_response) begin
                waiting_response <= 1'b0;
                if (acc_refresh_state != 0) begin
                    if (acc_refresh_state == 2'd1) begin
                        acc_refresh_a_w <= 64'(mul_rsp_product);
                        acc_refresh_state <= 2'd2;
                        issue_multiply(64'(32'sd16777216 - ACC_A_LUT[acc_refresh_code]),
                                       64'(ACC_V_LUT[acc_refresh_code]),7'd32,7'd40,TAG_SHIP_ACC_B);
                    end else begin
                        next_acc <= 40'((acc_refresh_a_w + 64'(mul_rsp_product) + 64'sd8388608) >>> 24);
                        next_valid <= 1'b1;
                        acc_refresh_state <= 2'd0;
                    end
                end else case (op_index)
                    5'd0: begin c12_a_w <= 64'(mul_rsp_product); op_index <= 5'd1; issue_multiply(64'(c12_charging ? B_555_CH_Q24 : 32'sd0),64'(V_CHG_TARGET),7'd32,7'd40,TAG_SHIP_BASE+8'd1); end
                    5'd1: begin
                        next_c12 <= 40'((c12_a_w + 64'(mul_rsp_product) + 64'sd8388608) >>> 24);
                        next_charging <= c12_charging ? !(v_c12 >= TH_HI_555) : (v_c12 <= TH_LO_555);
                        op_index <= 5'd2; issue_multiply(64'(acc_a),64'(v_acc),7'd32,7'd40,TAG_SHIP_BASE+8'd2);
                    end
                    5'd2: begin acc_a_w <= 64'(mul_rsp_product); op_index <= 5'd3; issue_multiply(64'(acc_b),64'(acc_target),7'd32,7'd40,TAG_SHIP_BASE+8'd3); end
                    5'd3: begin
                        // ACC is an asynchronous PPI latch relative to the
                        // 48 kHz CE.  The legacy registered pipeline holds
                        // this completed value in next_acc until the *next*
                        // sample_ce commits it.  Publishing v_acc here would
                        // advance Tr4's control one audio sample early.
                        next_acc <= 40'((acc_a_w + 64'(mul_rsp_product) + 64'sd8388608) >>> 24);
                        op_index <= 5'd4; issue_multiply(64'(vs_half_tr2),64'(32'sd22133960),7'd40,7'd32,TAG_SHIP_BASE+8'd4);
                    end
                    5'd4: begin step_tr2_up <= rsp_q40; op_index <= 5'd5; issue_multiply(64'(vs_half_tr2),64'(32'sd18354991),7'd40,7'd32,TAG_SHIP_BASE+8'd5); end
                    5'd5: begin step_tr2_dn <= rsp_q40; op_index <= 5'd6; issue_multiply(64'(vs_half_tr4),64'(32'sd120239916),7'd40,7'd32,TAG_SHIP_BASE+8'd6); end
                    5'd6: begin step_tr4_up <= rsp_q40; op_index <= 5'd7; issue_multiply(64'(vs_half_tr4),64'(32'sd125147668),7'd40,7'd32,TAG_SHIP_BASE+8'd7); end
                    5'd7: begin step_tr4_dn <= rsp_q40; op_index <= 5'd8; issue_multiply(64'(vs_half_tr5),64'(32'sd9336413),7'd40,7'd32,TAG_SHIP_BASE+8'd8); end
                    5'd8: begin step_tr5_up <= rsp_q40; op_index <= 5'd9; issue_multiply(64'(vs_half_tr5),64'(32'sd5562119),7'd40,7'd32,TAG_SHIP_BASE+8'd9); end
                    5'd9: begin step_tr5_dn <= rsp_q40; op_index <= 5'd10; issue_multiply(64'(vint_acc_tr2),64'(RECIP832_Q32),7'd40,7'd27,TAG_SHIP_BASE+8'd10); end
                    5'd10: begin avg_tr2 <= rsp_avg_q24; op_index <= 5'd11; issue_multiply(64'(vint_acc_tr4),64'(RECIP832_Q32),7'd40,7'd27,TAG_SHIP_BASE+8'd11); end
                    5'd11: begin avg_tr4 <= rsp_avg_q24; op_index <= 5'd12; issue_multiply(64'(vint_acc_tr5),64'(RECIP832_Q32),7'd40,7'd27,TAG_SHIP_BASE+8'd12); end
                    5'd12: begin
                        // The three DC products are issued on consecutive
                        // response cycles.  Capture each source on the SAME
                        // cycle its hp_sum is sampled: after this edge the
                        // avg_*_prev registers advance, so pre-capturing
                        // Tr4/Tr5 issue after the history registers advance,
                        // so retain their matching pre-update hp_sum inputs.
                        // Tr2 is issued directly in this cycle.
                        dc_cap_tr2 <= avg_tr2_prev;
                        dc_in_tr4 <= avg_tr4_prev;
                        dc_in_tr5 <= avg_tr5_prev;
                        avg_tr2_prev <= avg_tr2; avg_tr4_prev <= avg_tr4; avg_tr5_prev <= rsp_avg_q24;
                        op_index <= 5'd13; issue_multiply(64'(DC_A_TR2_TR5),64'(hp_tr2),7'd27,7'd40,TAG_SHIP_BASE+8'd13);
                    end
                    5'd13: begin dc_next_tr2 <= rsp_dc_q32; ac_tr2_work <= 32'((rsp_dc_q32 + 48'sd2048) >>> 12); dc_commit_tr2 <= 1'b1; dc_cap_tr4 <= dc_in_tr4; op_index <= 5'd14; issue_multiply(64'(DC_A_TR4),64'(hp_tr4),7'd27,7'd40,TAG_SHIP_BASE+8'd14); end
                    5'd14: begin dc_next_tr4 <= rsp_dc_q32; ac_tr4_work <= 32'((rsp_dc_q32 + 48'sd2048) >>> 12); dc_commit_tr4 <= 1'b1; dc_cap_tr5 <= dc_in_tr5; op_index <= 5'd15; issue_multiply(64'(DC_A_TR2_TR5),64'(hp_tr5),7'd27,7'd40,TAG_SHIP_BASE+8'd15); end
                    5'd15: begin dc_next_tr5 <= rsp_dc_q32; dc_commit_tr5 <= 1'b1; op_index <= 5'd16; issue_multiply(64'(IC26_GAIN_Q24),64'(ac_tr2_work + 32'((rsp_dc_q32 + 48'sd2048) >>> 12)),7'd32,7'd32,TAG_SHIP_BASE+8'd16); end
                    5'd16: begin vca_in_work <= rsp_q24_round; op_index <= 5'd17; issue_multiply(64'(CTRL_GAIN_Q24),64'(ac_tr4_work),7'd32,7'd32,TAG_SHIP_BASE+8'd17); end
                    5'd17: begin
                        gain_base_work <= vca_params_next[58:38];
                        // vca_params_next is a packed (therefore unsigned)
                        // vector.  The LUT delta becomes negative in its
                        // falling sections; restore its signed interpretation
                        // before widening for the shared multiplier.
                        op_index <= 5'd18; issue_multiply(64'($signed(vca_params_next[37:17])),64'($signed(vca_params_next[16:0])),7'd21,7'd17,TAG_SHIP_BASE+8'd18);
                    end
                    5'd18: begin op_index <= 5'd19; issue_multiply(64'(vca_in_work),64'(gain_base_work + rsp_gain_q16),7'd32,7'd21,TAG_SHIP_BASE+8'd19); end
                    5'd19: begin op_index <= 5'd20; issue_multiply(64'(OUT_GAIN_Q16),64'(rsp_q16_round),7'd32,7'd32,TAG_SHIP_BASE+8'd20); end
                    default: begin
                        ship_sample <= ((rsp_q16_round + 32'sd128) >>> 8 > RAIL_HI) ? RAIL_HI :
                                       ((rsp_q16_round + 32'sd128) >>> 8 < RAIL_LO) ? RAIL_LO : ((rsp_q16_round + 32'sd128) >>> 8);
                        running <= 1'b0; next_valid <= 1'b1;
                    end
                endcase
            end
        end
    end

`ifdef VERILATOR_SIM
    always_ff @(posedge clk) begin
        if (rst_n && mul_rsp_valid && waiting_response &&
            ((acc_refresh_state == 2'd1 && mul_rsp_tag != TAG_SHIP_ACC_A) ||
             (acc_refresh_state == 2'd2 && mul_rsp_tag != TAG_SHIP_ACC_B) ||
             (acc_refresh_state == 2'd0 && mul_rsp_tag != TAG_SHIP_BASE + {3'd0, op_index})))
            $error("SHIP shared-multiply tag mismatch");
        if (rst_n && sample_ce && (running || waiting_response || mul_req_valid))
            $error("SHIP shared multiply missed sample deadline");
    end
`endif
endmodule
