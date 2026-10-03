// MM5837 pseudo-random noise generator (sheet 3). 17-bit LFSR, taps 17 and
// 14, XOR feedback, advanced once per sample_ce (47,999 Hz), inside the
// part's nominal 32-64 kHz clock range and not beating against the audio rate.
//
// Output amplitude: PMOS part, output swings nearly the whole Vss..Vdd span.
// The board wires Vss (pin 4) = +12 V, Vdd (pin 2) = ground, Vgg tied to Vdd,
// so the datasheet's wider degraded-Vgg logic-0 limit applies:
//     logical 1: Vss - 1.5 .. Vss   = 10.5 .. 12.0 V
//     logical 0: Vdd .. Vdd + 3.5   =  0.0 ..  3.5 V
// giving 7.0 .. 12.0 Vpp; the datasheet gives no typical, so the midpoint
// (9.5 V) is used. This is the single scaling knob for FIRE, EXP and HIT (all
// linear in it). The datasheet is specified into 20 K/20 K, but this board
// loads the pin with ~77 K (R140 100K || R144 330K), so the true swing is
// likely at or above the midpoint.
//
// Two buffered IC29 taps follow, both resistive-gain scalers (C86/C85 are
// DC-blocking coupling caps, not audio-band shaping):
//   NOISE.A: gain -0.10  (R140 100K in, R139 10K fb)  -> FIRE, EXP
//   NOISE.B: gain -0.303 (R144 330K in, R143 100K fb) -> HIT
module noise_mm5837 #(
	parameter int NOISE_VPP_LSB = 38912  // 9.5 V * 4096 LSB/V (datasheet midpoint)
)(
	input  logic               clk,
	input  logic               rst_n,
	input  logic               sample_ce,
	output logic signed [15:0] noise_a,   // 4096 LSB = 1V, gain -0.10 tap
	output logic signed [15:0] noise_b    // 4096 LSB = 1V, gain -0.303 tap
);

	// 17-bit Fibonacci LFSR, bits 1..17 (1-indexed to match "taps 17,14").
	// Seeded non-zero out of reset so it can never lock up at all-zero.
	logic [17:1] lfsr;
	wire         fb = lfsr[17] ^ lfsr[14];

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			lfsr <= 17'h1ACE9; // arbitrary non-zero seed
		end else if (sample_ce) begin
			lfsr <= {lfsr[16:1], fb};
		end
	end

	// Map the output bit to +/- half the peak-to-peak amplitude.
	localparam signed [15:0] NOISE_HALF = 16'(NOISE_VPP_LSB / 2);
	wire signed [15:0] noise_raw = lfsr[17] ? NOISE_HALF : -NOISE_HALF;

	// Shift-add products (no DSP inference); the fixed gains decompose as:
	//   6554  = 4096 + 2048 + 256 + 128 + 16 + 8 + 2
	//   19857 = 16384 + 2048 + 1024 + 256 + 128 + 16 + 1
	// Both analogue buffers invert, so the products are negated.
	wire signed [63:0] noise_raw_ext = $signed({{48{noise_raw[15]}}, noise_raw});
	wire signed [63:0] prod_a = -((noise_raw_ext <<< 12) +
								  (noise_raw_ext <<< 11) +
								  (noise_raw_ext <<< 8)  +
								  (noise_raw_ext <<< 7)  +
								  (noise_raw_ext <<< 4)  +
								  (noise_raw_ext <<< 3)  +
								  (noise_raw_ext <<< 1));
	wire signed [63:0] prod_b = -((noise_raw_ext <<< 14) +
								  (noise_raw_ext <<< 11) +
								  (noise_raw_ext <<< 10) +
								  (noise_raw_ext <<< 8)  +
								  (noise_raw_ext <<< 7)  +
								  (noise_raw_ext <<< 4)  +
								  noise_raw_ext);

	always_ff @(posedge clk) begin
		if (!rst_n) begin
			noise_a <= 16'sd0;
			noise_b <= 16'sd0;
		end else if (sample_ce) begin
			noise_a <= prod_a[31:16];
			noise_b <= prod_b[31:16];
		end
	end

endmodule
