// ALARM channel: IC15A 555 astable -> IC16 74LS393 ripple divider ->
// IC3/IC7 74123 retriggerable monostables (one per /ALARMn) -> IC11 74LS38
// open-collector wire-OR node -> R154/C88 one-pole high-pass -> IC29/IC25
// unity-follower + x(-2) gain stage. See docs/audio-rtl-design.md for every
// constant below; this module must not contradict that file.
module alarm_chan (
    input  logic               clk,
    input  logic               rst_n,
    input  logic         [3:0] alarm_n,    // bit n = /ALARMn, active low
    input  logic               sample_ce,  // 1 clk high every 832 clks
    output logic signed [15:0] alarm_mix,  // 4096 LSB = 1V, updates on sample_ce
    output logic               node        // wire-OR node bit, for debug
);

    // ---------------------------------------------------------------
    // Stage 1: IC15A 555 astable (defaults per docs/audio-rtl-design.md)
    // ---------------------------------------------------------------
    logic tone555;

    ttl_555_astable #(
        .T_HIGH (2048),
        .T_LOW  (747)
    ) u_555 (
        .clk    (clk),
        .rst_n  (rst_n),
        .out    (tone555)
    );

    // ---------------------------------------------------------------
    // Stage 2: IC16 74LS393 ripple divider, falling-edge triggered,
    // never reset after power-on (1CLR/2CLR grounded on the board).
    // A falling-edge-clocked ripple counter's stage N is bit N of a
    // plain binary counter clocked on the same edges, so this is
    // implemented as one 5-bit counter incremented on every falling
    // edge of tone555. Taps: 1QB=bit1(/4) 1QC=bit2(/8) 1QD=bit3(/16)
    // 2QA=bit4(/32).
    // ---------------------------------------------------------------
    logic tone555_d;
    wire  div_edge = tone555_d && !tone555; // falling edge

    logic [4:0] div_cnt;

    wire tone_1QB = div_cnt[1];
    wire tone_1QC = div_cnt[2];
    wire tone_1QD = div_cnt[3];
    wire tone_2QA = div_cnt[4];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tone555_d <= 1'b1;
            div_cnt   <= '0;
        end else begin
            tone555_d <= tone555;
            if (div_edge)
                div_cnt <= div_cnt + 1'b1;
        end
    end

    // ---------------------------------------------------------------
    // Stage 3: four retriggerable 74123 monostables, one per /ALARMn
    // ---------------------------------------------------------------
    logic q0, q1, q2, q3;

    ttl_74123 #(.WIDTH_CYCLES(5743600)) u_74123_0 (.clk(clk), .rst_n(rst_n), .a_n(alarm_n[0]), .q(q0));
    ttl_74123 #(.WIDTH_CYCLES(5743600)) u_74123_1 (.clk(clk), .rst_n(rst_n), .a_n(alarm_n[1]), .q(q1));
    ttl_74123 #(.WIDTH_CYCLES(5743600)) u_74123_2 (.clk(clk), .rst_n(rst_n), .a_n(alarm_n[2]), .q(q2));
    ttl_74123 #(.WIDTH_CYCLES(8446470)) u_74123_3 (.clk(clk), .rst_n(rst_n), .a_n(alarm_n[3]), .q(q3));

    // ---------------------------------------------------------------
    // Stage 4: IC11 74LS38 open-collector wire-OR node.
    // ALARM0->2QA(/32) ALARM1->1QD(/16) ALARM2->1QC(/8) ALARM3->1QB(/4)
    // ---------------------------------------------------------------
    assign node = ~((q0 & tone_2QA) | (q1 & tone_1QD) | (q2 & tone_1QC) | (q3 & tone_1QB));

    // ---------------------------------------------------------------
    // Decimator: box-average `node` over all 832 clk_sys cycles of one
    // audio sample (deliberate deviation from the schematic; the real
    // circuit has no anti-alias filter here -- see design doc).
    // ---------------------------------------------------------------
    logic [9:0] acc; // 0..832

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc <= '0;
        end else if (sample_ce) begin
            acc <= {9'd0, node};
        end else begin
            acc <= acc + {9'd0, node};
        end
    end

    // ---------------------------------------------------------------
    // Stage 5: analog tail. Everything below updates only on sample_ce.
    // x[n] = 506 + ((9226-506) * acc) / 832
    // y[n] = (a * (y[n-1] + x[n] - x[n-1])) >>> 16   (s32 state, a=65510 Q0.16)
    // alarm_mix = -2 * (y[n] >>> 8), saturated to s16
    // ---------------------------------------------------------------
    localparam signed [31:0] X_LOW  = 32'sd506;
    localparam signed [31:0] X_SPAN = 32'sd9226 - 32'sd506; // 8720
    localparam signed [31:0] A_COEF = 32'sd65510; // Q0.16

    logic signed [31:0] x_scaled_d;   // previous x<<8, s32 4096*256 LSB/V
    logic signed [31:0] y_state;      // s32 filter state, same scale

    // combinational: level map on the *latched* acc (i.e. the value from
    // the just-completed sample window). acc is valid on the sample_ce
    // cycle itself (it was latched to the burst-sum on the previous
    // sample_ce and has been accumulating ever since).
    wire signed [31:0] acc_s   = {22'd0, acc};
    wire signed [31:0] x_next  = X_LOW + ((X_SPAN * acc_s) / 32'sd832);
    wire signed [31:0] x_scaled_next = x_next <<< 8;

    // widen to 64 bits for the multiply so the >>>16 is a real Q0.16
    // fixed-point multiply, not a truncate-then-shift
    wire signed [63:0] hp_sum  = 64'(y_state) + 64'(x_scaled_next) - 64'(x_scaled_d);
    wire signed [63:0] hp_prod = 64'(A_COEF) * hp_sum;
    wire signed [31:0] y_next  = hp_prod[47:16];

    wire signed [31:0] mix_full = -32'sd2 * (y_next >>> 8);

    // saturate mix_full to signed 16-bit
    wire signed [15:0] mix_sat =
        (mix_full > 32'sd32767)  ? 16'sd32767  :
        (mix_full < -32'sd32768) ? -16'sd32768 :
        mix_full[15:0];

    // Idle level: with no alarm gated, every 74LS38 output is off and R153
    // holds the node HIGH, so x settles at X_LOW + X_SPAN. x_scaled_d must
    // reset to that, not to X_LOW -- otherwise the first sample sees a
    // full-scale 0 -> idle step and the high-pass rings for its whole 52 ms
    // tau, producing a reset click twice the amplitude of the alarm itself.
    //
    // Physically this starts C88 pre-charged. A real board powering up does
    // thump; the core's rst_n is not a power cycle of the analog board, and
    // the design contract requires bit-exact silence before the first alarm,
    // so we deliberately skip the power-on transient.
    localparam signed [31:0] X_IDLE = X_LOW + X_SPAN;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            x_scaled_d <= X_IDLE <<< 8;
            y_state    <= '0;
            alarm_mix  <= 16'sd0;
        end else if (sample_ce) begin
            y_state    <= y_next;
            x_scaled_d <= x_scaled_next;
            alarm_mix  <= mix_sat;
        end
    end

endmodule
