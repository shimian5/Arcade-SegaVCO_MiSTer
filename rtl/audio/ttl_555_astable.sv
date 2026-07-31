// Generic 555 astable multivibrator model. Free-running: `out` is high for
// T_HIGH clk_sys cycles, then low for T_LOW clk_sys cycles, forever. Starts
// high out of reset (matches the real chip's power-on behaviour: C charges
// from 0, so the first half-cycle is the "high" one).
//
// Duty cycle correctness only matters for channels that sample the 555
// output directly (SHIP, REBOUND); for ALARM it feeds a ripple divider
// whose taps are 50% duty regardless of the 555's duty, so exact T_HIGH/
// T_LOW values there are cosmetic but kept for reuse. See
// docs/audio-rtl-design.md.
module ttl_555_astable #(
    parameter int T_HIGH = 2048,
    parameter int T_LOW  = 747
)(
    input  logic clk,
    input  logic rst_n,
    output logic out
);

    localparam int MAX_T = (T_HIGH > T_LOW) ? T_HIGH : T_LOW;
    localparam int CNT_W = (MAX_T <= 1) ? 1 : $clog2(MAX_T);

    logic [CNT_W-1:0] cnt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            cnt <= '0;
            out <= 1'b1;
        end else begin
            if (out) begin
                if (cnt == T_HIGH[CNT_W-1:0] - 1'b1) begin
                    cnt <= '0;
                    out <= 1'b0;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end else begin
                if (cnt == T_LOW[CNT_W-1:0] - 1'b1) begin
                    cnt <= '0;
                    out <= 1'b1;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

endmodule
