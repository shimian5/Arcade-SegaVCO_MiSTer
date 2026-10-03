// Direct STK439 unit-test wrapper. The two cabinet channels deliberately use
// identical final parameters; a separate unity-pot instance exposes the
// physical Av*c normalization independently of the presentation pot.
module stk439_tb (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic signed [15:0] mix_in,
    output logic signed [15:0] upper_out,
    output logic signed [15:0] lower_out,
    output logic signed [15:0] unity_out,
    output logic signed [63:0] upper_raw,
    output logic signed [63:0] lower_raw,
    output logic signed [63:0] unity_raw,
    output logic               upper_clip,
    output logic               lower_clip,
    output logic               unity_clip,
    output logic        [31:0] upper_clip_count,
    output logic        [31:0] lower_clip_count,
    output logic        [31:0] unity_clip_count
);
    // WP7 shared neutral presentation setting, independently selected from
    // corrected ef11cd5 scenario 30: k=9438/65536=0.1440124512.
    stk439 #(.POT_K_Q16(9438), .A_HP_Q24(16773898)) u_upper (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .mix_in(mix_in),
        .audio_out(upper_out), .raw_out(upper_raw), .clip(upper_clip),
        .clip_count(upper_clip_count)
    );
    stk439 #(.POT_K_Q16(9438), .A_HP_Q24(16773898)) u_lower (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .mix_in(mix_in),
        .audio_out(lower_out), .raw_out(lower_raw), .clip(lower_clip),
        .clip_count(lower_clip_count)
    );
    // Unity pot: physical normalized gain and independent pole reference.
    stk439 #(.POT_K_Q16(65536), .A_HP_Q24(16773851)) u_unity (
        .clk(clk), .rst_n(rst_n), .sample_ce(sample_ce), .mix_in(mix_in),
        .audio_out(unity_out), .raw_out(unity_raw), .clip(unity_clip),
        .clip_count(unity_clip_count)
    );
endmodule
