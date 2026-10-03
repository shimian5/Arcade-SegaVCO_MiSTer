// Generic 74123 retriggerable monostable model. B and CL are assumed tied
// high (as on the real board), so the only trigger is a falling edge on
// `a_n`. A fresh falling edge (re)loads the full WIDTH_CYCLES countdown
// whether or not `q` is already high. `q` is high for exactly WIDTH_CYCLES
// clk_sys cycles after the most recent triggering edge.
module ttl_74123 #(
	parameter int WIDTH_CYCLES = 5743600
)(
	input  logic clk,
	input  logic rst_n,
	input  logic a_n,     // active-low trigger, NEGATIVE EDGE, retriggerable
	output logic q
);

	localparam int CNT_W = $clog2(WIDTH_CYCLES + 1);

	logic [CNT_W-1:0] cnt;
	logic             a_n_d;

	wire trigger = a_n_d && !a_n; // falling edge on a_n

	// `a_n_d` resets to the CURRENT value of `a_n`, not to 1: when one-shots
	// are cascaded (EXP wires sec.B's a_n to sec.A's q, which idles LOW) a
	// hardcoded 1 would create a falling edge on the first clock after reset
	// and fire a phantom full-width pulse.
	always_ff @(posedge clk) begin
		if (!rst_n) begin
			a_n_d <= a_n;
			cnt   <= '0;
			q     <= 1'b0;
		end else begin
			a_n_d <= a_n;

			if (trigger) begin
				cnt <= WIDTH_CYCLES[CNT_W-1:0];
				q   <= 1'b1;
			end else if (q) begin
				if (cnt <= 1) begin
					cnt <= '0;
					q   <= 1'b0;
				end else begin
					cnt <= cnt - 1'b1;
				end
			end
		end
	end

endmodule
