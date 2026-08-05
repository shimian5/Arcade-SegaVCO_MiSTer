// One fixed three-client front end for a shared 27x27 multiplier lane.
//
// Ports are deliberately flat for Quartus 17.  Each client holds req_valid
// until its one-cycle req_ready pulse, then waits for its tagged response.
// The lane owner is registered at acceptance, so the response path is a
// direct three-way demux rather than a pool-wide crossbar.
module shared_mul_arb3 (
    input  logic clk,
    input  logic rst_n,

    input  logic c0_req_valid, output logic c0_req_ready,
    input  logic signed [63:0] c0_req_a, c0_req_b,
    input  logic [6:0] c0_req_a_width, c0_req_b_width, input logic [7:0] c0_req_tag,
    output logic c0_rsp_valid, output logic signed [127:0] c0_rsp_product, output logic [7:0] c0_rsp_tag,

    input  logic c1_req_valid, output logic c1_req_ready,
    input  logic signed [63:0] c1_req_a, c1_req_b,
    input  logic [6:0] c1_req_a_width, c1_req_b_width, input logic [7:0] c1_req_tag,
    output logic c1_rsp_valid, output logic signed [127:0] c1_rsp_product, output logic [7:0] c1_rsp_tag,

    input  logic c2_req_valid, output logic c2_req_ready,
    input  logic signed [63:0] c2_req_a, c2_req_b,
    input  logic [6:0] c2_req_a_width, c2_req_b_width, input logic [7:0] c2_req_tag,
    output logic c2_rsp_valid, output logic signed [127:0] c2_rsp_product, output logic [7:0] c2_rsp_tag
);
    logic [1:0] rr_client, owner;
    logic owner_valid;
    logic sel_valid, accepted;
    logic [1:0] sel_client;

    logic lane_req_valid, lane_req_ready;
    logic signed [63:0] lane_req_a, lane_req_b;
    logic [6:0] lane_req_a_width, lane_req_b_width;
    logic [7:0] lane_req_tag;
    logic lane_rsp_valid;
    logic signed [127:0] lane_rsp_product;
    logic [7:0] lane_rsp_tag;

    // Fixed rotating priority.  The c0/c1/c2 placement in the wrapper fixes
    // the reset order for each physical lane.
    always_comb begin
        sel_valid = 1'b0;
        sel_client = rr_client;
        if (lane_req_ready) begin
            case (rr_client)
                2'd0: begin
                    if (c0_req_valid) begin sel_valid = 1'b1; sel_client = 2'd0; end
                    else if (c1_req_valid) begin sel_valid = 1'b1; sel_client = 2'd1; end
                    else if (c2_req_valid) begin sel_valid = 1'b1; sel_client = 2'd2; end
                end
                2'd1: begin
                    if (c1_req_valid) begin sel_valid = 1'b1; sel_client = 2'd1; end
                    else if (c2_req_valid) begin sel_valid = 1'b1; sel_client = 2'd2; end
                    else if (c0_req_valid) begin sel_valid = 1'b1; sel_client = 2'd0; end
                end
                default: begin
                    if (c2_req_valid) begin sel_valid = 1'b1; sel_client = 2'd2; end
                    else if (c0_req_valid) begin sel_valid = 1'b1; sel_client = 2'd0; end
                    else if (c1_req_valid) begin sel_valid = 1'b1; sel_client = 2'd1; end
                end
            endcase
        end
    end

    always_comb begin
        lane_req_a = '0; lane_req_b = '0;
        lane_req_a_width = 7'd1; lane_req_b_width = 7'd1; lane_req_tag = '0;
        case (sel_client)
            2'd0: begin lane_req_a = c0_req_a; lane_req_b = c0_req_b; lane_req_a_width = c0_req_a_width; lane_req_b_width = c0_req_b_width; lane_req_tag = c0_req_tag; end
            2'd1: begin lane_req_a = c1_req_a; lane_req_b = c1_req_b; lane_req_a_width = c1_req_a_width; lane_req_b_width = c1_req_b_width; lane_req_tag = c1_req_tag; end
            default: begin lane_req_a = c2_req_a; lane_req_b = c2_req_b; lane_req_a_width = c2_req_a_width; lane_req_b_width = c2_req_b_width; lane_req_tag = c2_req_tag; end
        endcase

        c0_req_ready = sel_valid && (sel_client == 2'd0);
        c1_req_ready = sel_valid && (sel_client == 2'd1);
        c2_req_ready = sel_valid && (sel_client == 2'd2);
        lane_req_valid = sel_valid;
    end
    assign accepted = lane_req_valid && lane_req_ready;

    shared_mul_lane u_lane (
        .clk(clk), .rst_n(rst_n), .req_valid(lane_req_valid), .req_ready(lane_req_ready),
        .req_a(lane_req_a), .req_b(lane_req_b), .req_a_width(lane_req_a_width), .req_b_width(lane_req_b_width), .req_tag(lane_req_tag),
        .rsp_valid(lane_rsp_valid), .rsp_product(lane_rsp_product), .rsp_tag(lane_rsp_tag)
    );

    // Product and tag are meaningful only alongside the one-cycle valid
    // pulse. Broadcasting them removes six wide owner-selected response
    // muxes; each client already gates consumption with its own rsp_valid.
    assign c0_rsp_product = lane_rsp_product;
    assign c1_rsp_product = lane_rsp_product;
    assign c2_rsp_product = lane_rsp_product;
    assign c0_rsp_tag = lane_rsp_tag;
    assign c1_rsp_tag = lane_rsp_tag;
    assign c2_rsp_tag = lane_rsp_tag;

    always_comb begin
        c0_rsp_valid = 1'b0; c1_rsp_valid = 1'b0; c2_rsp_valid = 1'b0;
        if (lane_rsp_valid && owner_valid) begin
            case (owner)
                2'd0:   c0_rsp_valid = 1'b1;
                2'd1:   c1_rsp_valid = 1'b1;
                default:c2_rsp_valid = 1'b1;
            endcase
        end
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            rr_client <= 2'd0;
            owner <= 2'd0;
            owner_valid <= 1'b0;
        end else begin
            if (lane_rsp_valid && owner_valid)
                owner_valid <= 1'b0;
            if (accepted) begin
                owner <= sel_client;
                owner_valid <= 1'b1;
                case (sel_client)
                    2'd0: rr_client <= 2'd1;
                    2'd1: rr_client <= 2'd2;
                    default: rr_client <= 2'd0;
                endcase
            end
        end
    end

`ifdef VERILATOR_SIM
    always_ff @(posedge clk) begin
        if (rst_n && lane_rsp_valid && !owner_valid)
            $error("shared_mul_arb3 response without an owner");
        if (rst_n && accepted && owner_valid && !lane_rsp_valid)
            $error("shared_mul_arb3 accepted while prior owner is still in flight");
    end
`endif
endmodule
