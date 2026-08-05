// SHIP relaxation oscillator.  The sample-rate products live in ship_chan's
// shared-MAC transaction stream; the full-rate integrator remains local.
module relax_vco (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic signed [39:0] step_up_next,
    input  logic signed [39:0] step_dn_next,
    output logic signed [39:0] vint_acc,   // completed window sum, Q24
    output logic signed [39:0] vint         // instantaneous integrator, Q24
);
    localparam logic signed [39:0] TH_HI   = 40'sd126162442;
    localparam logic signed [39:0] TH_LO   = 40'sd66664434;
    localparam logic signed [39:0] TH_MEAN = 40'sd96413438;

    logic signed [39:0] step_up, step_dn;
    logic signed [39:0] acc;
    logic sq;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            vint     <= TH_MEAN;
            sq       <= 1'b0;
            acc      <= '0;
            vint_acc <= '0;
            step_up  <= '0;
            step_dn  <= '0;
        end else begin
            if (sample_ce) begin
                // The values were calculated during the preceding 832-clock
                // window from the pre-edge control state.  Applying them here
                // preserves the old registered-multiply phase exactly.
                step_up  <= step_up_next;
                step_dn  <= step_dn_next;
                vint_acc <= acc;
                acc      <= vint;
            end else begin
                acc <= acc + vint;
            end

            vint <= sq ? (vint + step_up) : (vint - step_dn);
            if (sq && (vint >= TH_HI))
                sq <= 1'b0;
            else if (!sq && (vint <= TH_LO))
                sq <= 1'b1;
        end
    end
endmodule
