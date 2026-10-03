// Generic Intel 8255 PPI: mode 0 (latched I/O) plus the group-A mode-2
// output handshake.
//
// Register map (2-bit address): 0=port A, 1=port B, 2=port C, 3=control word.
// Mode-0 direction follows the control word as on the real chip: port A and
// port C-upper share group A's direction bit, port B and port C-lower share
// group B's.
//
// Mode 2 (group A) is the main-CPU -> sub-CPU command channel of the
// Buck Rogers board. Control word 0xC0 (D6=1) selects it, after which port C
// upper becomes handshake pins:
//   PC7 = /OBF  output: driven low on the trailing edge of a port A write,
//                       high again by /ACK.
//   PC6 = /ACK  input:  low pulse = peripheral took the byte.
//   PC5 = IBF, PC4 = /STB, PC3 = INTR: input half of mode 2, unconnected.
// On the CPU board (834-5120 sheet 5) IC90's PC7 drives the sub Z80's /INT and
// PC6 comes from its /IORQ with no gating, so the command write is the
// interrupt and the sub CPU's own /IORQ (acknowledge, then the ISR's IN)
// clears it; there is no software /INT-clear step.
// Only the output half of mode 2 is modelled.
//
// Read is registered (one clk of latency); the CPU holds its address for many
// clk cycles, so this is transparent.
module i8255
(
	input  wire        clk,
	input  wire        reset,

	input  wire         cs,
	input  wire         we,
	input  wire  [1:0]  addr,
	input  wire  [7:0]  din,
	output reg   [7:0]  dout,

	// pin values, sampled when the group is programmed as input
	input  wire  [7:0]  in_a,
	input  wire  [7:0]  in_b,
	input  wire  [7:0]  in_c,

	// Group-A mode-2 /ACK input (PC6). Active low; ignored unless the
	// control word selected mode 2. Tie high when unused.
	input  wire         ack_n,

	// Output latches (readable back even if reprogrammed, as on the real chip).
	// `pc` is the port C pin vector, so in mode 2 pc[7] is /OBF and can drive a
	// peripheral /INT directly.
	output reg   [7:0]  pa,
	output reg   [7:0]  pb,
	output wire  [7:0]  pc,

	// one-cycle strobes on a write to a port configured as output
	output reg          pa_wr,
	output reg          pb_wr,
	output reg          pc_wr
);

	// direction bits: 1 = input, 0 = output (matches 8255 control-word polarity)
	reg dir_a, dir_b, dir_c_hi, dir_c_lo;

	// group A mode 2 (control word D6), and its /OBF flip-flop
	reg mode2_a;
	reg obf_n;

	// port C data latch; `pc` below is the pin vector derived from it
	reg [7:0] pc_lat;

	// In mode 2 the upper port C bits are handshake pins; PC5/PC4/PC3
	// (IBF, /STB, INTR) are unconnected and carry idle levels.
	assign pc = mode2_a ? {obf_n, ack_n, 1'b0, 1'b1, 1'b0, pc_lat[2:0]}
						: pc_lat;

	// edge detectors: /ACK falling, and the trailing edge of a port A write
	// (a real 8255 clears /OBF on the trailing edge of /WR)
	reg ack_n_d;
	reg pa_cs_d;
	wire pa_cs = cs && we && (addr == 2'd0);

	always @(posedge clk) begin
		pa_wr <= 1'b0;
		pb_wr <= 1'b0;
		pc_wr <= 1'b0;

		ack_n_d <= ack_n;
		pa_cs_d <= pa_cs;

		if (reset) begin
			// The real chip resets to control word 0x9B (all inputs), leaving
			// the pins at their pulled-up idle level. Model that as latches
			// idling high so consumers tapping a latch as a control line (e.g.
			// PPI0 port C bit 7 -> sub /INT) see "not asserted" out of reset.
			dir_a    <= 1'b0;
			dir_b    <= 1'b0;
			dir_c_hi <= 1'b0;
			dir_c_lo <= 1'b0;
			mode2_a  <= 1'b0;
			obf_n    <= 1'b1;
			pa       <= 8'hFF;
			pb       <= 8'hFF;
			pc_lat   <= 8'hFF;
		end else begin
			// Group-A mode-2 output handshake; /ACK can arrive at any time.
			if (mode2_a) begin
				if (ack_n_d && !ack_n)      obf_n <= 1'b1;  // taken
				else if (pa_cs_d && !pa_cs) obf_n <= 1'b0;  // byte pending
			end

		if (cs && we) begin
			case (addr)
				2'd0: begin pa <= din; pa_wr <= 1'b1; end
				2'd1: begin pb <= din; pb_wr <= 1'b1; end
				2'd2: begin
					// In mode 2 only port C bits 2-0 are data; bits 7-3 are
					// handshake pins and a data write must not disturb them (Buck
					// Rogers writes 0xA0-0xA2 for FCHG0-2 with bit 7 = 1, which
					// would otherwise deassert the sub CPU's /INT).
					if (mode2_a) pc_lat[2:0] <= din[2:0];
					else         pc_lat      <= din;
					pc_wr <= 1'b1;
				end
				2'd3: begin
					if (din[7]) begin
						// Mode-set. D6 alone selects group A mode 2 (D5 don't-care);
						// mode 1 is not modelled. Also clears the handshake flags.
						mode2_a  <= din[6];
						obf_n    <= 1'b1;
						dir_a    <= din[4];
						dir_c_hi <= din[3];
						dir_b    <= din[1];
						dir_c_lo <= din[0];
					end else begin
						// BSR: D3-D1 select a port C bit, D0 sets/clears it. In mode 2,
						// BSR on bits 7-3 addresses INTE flip-flops, not the pins.
						if (!(mode2_a && din[3:1] >= 3'd3))
							pc_lat[din[3:1]] <= din[0];
						pc_wr <= 1'b1;
					end
				end
			endcase
		end
		end

		// registered read
		if (cs) begin
			case (addr)
				2'd0: dout <= dir_a ? in_a : pa;
				2'd1: dout <= dir_b ? in_b : pb;
				// Port C readback returns the pin vector: /OBF on bit 7 in mode 2.
				2'd2: dout <= mode2_a ? pc :
							  {dir_c_hi ? in_c[7:4] : pc_lat[7:4],
							   dir_c_lo ? in_c[3:0] : pc_lat[3:0]};
				2'd3: dout <= 8'hFF;
			endcase
		end
	end

endmodule
