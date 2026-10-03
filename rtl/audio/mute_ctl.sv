// DC-mute control node -- LA4460 pin 6 (sheet 1).
//
// Pin 6 of the LA4460 is its "DC Audio Muting" input (quiescent 5.6 V).
// Asserting it gives infinite attenuation, unlike the AC mute on pin 1
// (only 38 dB down, left unconnected on this board): a hard kill, not a fade.
//
// Two pull-down-only drivers sit on that node, so it is muted when EITHER
// pulls low:
//
//   conn pin 16 -> IC5 7417 (pin 13 in, pin 12 out, OPEN COLLECTOR)
//                  RA3 47K pull-up to +12 V -> LA4460 pin 6
//
//   12 V --R107 470K--+-- IC26 sec.D pin 12 (+), pin 13 (-) tied to the 6 V rail
//                     +-- C58 4.7uF to ground
//                     +-- D9 anode here, cathode at 12 V
//   IC26 pin 14 -> D5, CATHODE toward IC26, ANODE toward LA4460 pin 6
//
// 1. GAME ON = ppi1_pb[7], active high. When it is LOW the 7417 (a non-inverting
//    open-collector buffer) sinks pin 6 => MUTE.
//
// 2. IC26 sec.D is an open-loop comparator against the 6 V rail. At power-on C58
//    is uncharged, so its `+` input is below 6 V and its output is low, sinking
//    pin 6 through D5 => MUTE. The node then charges toward 12 V through R107
//    and the comparator releases when it crosses 6 V:
//
//      tau      = R107 470K * C58 4.7uF     = 2.2090 s
//      t_cross  = tau * ln(12 / (12 - 6))   = 2.2090 * ln(2) = 1.5312 s
//               = 1.5312 * 39,935,064       = 61,147,057 clk_sys cycles
//
//    The crossing is deterministic (fixed rail, fixed RC), so a plain
//    clk-rate counter lands on exactly the same instant as the exponential.
//
//    D9 (anode at the node, cathode at 12 V) is reverse-biased in normal
//    operation. It only matters at power-OFF, where it dumps C58 into the
//    collapsing rail so the amp is muted before the speaker thumps. The FPGA
//    has no power-off event, so D9 is not modelled.
//
// RESET MODELS POWER-ON: the counter runs from `rst_n` release, so a core
// reset re-arms the full 1.53 s delay. The real board would not (C58 stays
// charged across a CPU reset); the harmless extra silence is a deliberate
// deviation.
module mute_ctl (
	input  logic clk,
	input  logic rst_n,
	input  logic game_on,    // ppi1_pb[7], ACTIVE HIGH
	output logic dc_mute     // 1 = muted
);

	localparam int unsigned POWERON_CYCLES = 61147057;
	localparam int CNT_W = $clog2(POWERON_CYCLES + 1);

	logic [CNT_W-1:0] poweron_cnt;
	logic             poweron_done;

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			poweron_cnt  <= '0;
			poweron_done <= 1'b0;
		end else if (!poweron_done) begin
			if (poweron_cnt == CNT_W'(POWERON_CYCLES - 1))
				poweron_done <= 1'b1;
			else
				poweron_cnt <= poweron_cnt + 1'b1;
		end
	end

	// Wire-OR of two open-collector / open-drain pull-downs.
	assign dc_mute = !game_on || !poweron_done;

endmodule
