// Two fixed shared-multiplier lanes for the six discrete-audio clients.
//
// Keeping each client on one physical lane eliminates the former 6-client
// crossbar.  The c0/c1/c2 order preserves the old global round-robin's reset
// acceptance pairs: (LA,EXP), then (FIRE,SHIP), then (REBOUND,HIT).
module shared_mul_pool (
    input  logic clk,
    input  logic rst_n,

    input  logic la_req_valid, output logic la_req_ready,
    input  logic signed [63:0] la_req_a, la_req_b,
    input  logic [6:0] la_req_a_width, la_req_b_width, input logic [7:0] la_req_tag,
    output logic la_rsp_valid, output logic signed [127:0] la_rsp_product, output logic [7:0] la_rsp_tag,

    input  logic exp_req_valid, output logic exp_req_ready,
    input  logic signed [63:0] exp_req_a, exp_req_b,
    input  logic [6:0] exp_req_a_width, exp_req_b_width, input logic [7:0] exp_req_tag,
    output logic exp_rsp_valid, output logic signed [127:0] exp_rsp_product, output logic [7:0] exp_rsp_tag,

    input  logic fire_req_valid, output logic fire_req_ready,
    input  logic signed [63:0] fire_req_a, fire_req_b,
    input  logic [6:0] fire_req_a_width, fire_req_b_width, input logic [7:0] fire_req_tag,
    output logic fire_rsp_valid, output logic signed [127:0] fire_rsp_product, output logic [7:0] fire_rsp_tag,

    input  logic ship_req_valid, output logic ship_req_ready,
    input  logic signed [63:0] ship_req_a, ship_req_b,
    input  logic [6:0] ship_req_a_width, ship_req_b_width, input logic [7:0] ship_req_tag,
    output logic ship_rsp_valid, output logic signed [127:0] ship_rsp_product, output logic [7:0] ship_rsp_tag,

    input  logic rebound_req_valid, output logic rebound_req_ready,
    input  logic signed [63:0] rebound_req_a, rebound_req_b,
    input  logic [6:0] rebound_req_a_width, rebound_req_b_width, input logic [7:0] rebound_req_tag,
    output logic rebound_rsp_valid, output logic signed [127:0] rebound_rsp_product, output logic [7:0] rebound_rsp_tag,

    input  logic hit_req_valid, output logic hit_req_ready,
    input  logic signed [63:0] hit_req_a, hit_req_b,
    input  logic [6:0] hit_req_a_width, hit_req_b_width, input logic [7:0] hit_req_tag,
    output logic hit_rsp_valid, output logic signed [127:0] hit_rsp_product, output logic [7:0] hit_rsp_tag
);
    // Even client IDs: LA -> FIRE -> REBOUND.
    shared_mul_arb3 u_lane0 (
        .clk(clk), .rst_n(rst_n),
        .c0_req_valid(la_req_valid), .c0_req_ready(la_req_ready), .c0_req_a(la_req_a), .c0_req_b(la_req_b), .c0_req_a_width(la_req_a_width), .c0_req_b_width(la_req_b_width), .c0_req_tag(la_req_tag), .c0_rsp_valid(la_rsp_valid), .c0_rsp_product(la_rsp_product), .c0_rsp_tag(la_rsp_tag),
        .c1_req_valid(fire_req_valid), .c1_req_ready(fire_req_ready), .c1_req_a(fire_req_a), .c1_req_b(fire_req_b), .c1_req_a_width(fire_req_a_width), .c1_req_b_width(fire_req_b_width), .c1_req_tag(fire_req_tag), .c1_rsp_valid(fire_rsp_valid), .c1_rsp_product(fire_rsp_product), .c1_rsp_tag(fire_rsp_tag),
        .c2_req_valid(rebound_req_valid), .c2_req_ready(rebound_req_ready), .c2_req_a(rebound_req_a), .c2_req_b(rebound_req_b), .c2_req_a_width(rebound_req_a_width), .c2_req_b_width(rebound_req_b_width), .c2_req_tag(rebound_req_tag), .c2_rsp_valid(rebound_rsp_valid), .c2_rsp_product(rebound_rsp_product), .c2_rsp_tag(rebound_rsp_tag)
    );

    // Odd client IDs: EXP -> SHIP -> HIT.
    shared_mul_arb3 u_lane1 (
        .clk(clk), .rst_n(rst_n),
        .c0_req_valid(exp_req_valid), .c0_req_ready(exp_req_ready), .c0_req_a(exp_req_a), .c0_req_b(exp_req_b), .c0_req_a_width(exp_req_a_width), .c0_req_b_width(exp_req_b_width), .c0_req_tag(exp_req_tag), .c0_rsp_valid(exp_rsp_valid), .c0_rsp_product(exp_rsp_product), .c0_rsp_tag(exp_rsp_tag),
        .c1_req_valid(ship_req_valid), .c1_req_ready(ship_req_ready), .c1_req_a(ship_req_a), .c1_req_b(ship_req_b), .c1_req_a_width(ship_req_a_width), .c1_req_b_width(ship_req_b_width), .c1_req_tag(ship_req_tag), .c1_rsp_valid(ship_rsp_valid), .c1_rsp_product(ship_rsp_product), .c1_rsp_tag(ship_rsp_tag),
        .c2_req_valid(hit_req_valid), .c2_req_ready(hit_req_ready), .c2_req_a(hit_req_a), .c2_req_b(hit_req_b), .c2_req_a_width(hit_req_a_width), .c2_req_b_width(hit_req_b_width), .c2_req_tag(hit_req_tag), .c2_rsp_valid(hit_rsp_valid), .c2_rsp_product(hit_rsp_product), .c2_rsp_tag(hit_rsp_tag)
    );
endmodule
