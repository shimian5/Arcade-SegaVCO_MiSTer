// MM5837 pseudo-random noise generator (sheet 3). 17-bit LFSR, taps 17 and
// 14, XOR feedback, advanced once per sample_ce (47,999 Hz), which sits
// inside the part's nominal 32-64 kHz clock range and avoids any beat
// against the audio rate itself. See docs/audio-rtl-design.md, "NOISE --
// MM5837".
//
// Output amplitude, from docs/reference/MM5837.PDF. It is a PMOS part whose
// output swings essentially the whole Vss..Vdd span. The board wires
// Vss (pin 4) = +12 V, Vdd (pin 2) = ground, and Vgg tied to Vdd -- the
// degraded-Vgg case, so the datasheet's wider logic-0 limit applies:
//     logical 1: Vss - 1.5 .. Vss   = 10.5 .. 12.0 V
//     logical 0: Vdd .. Vdd + 3.5   =  0.0 ..  3.5 V
// which bounds the swing to 7.0 .. 12.0 Vpp. The datasheet gives no typical,
// so we take the midpoint, 9.5 V.
//
// Corroboration: the master mixer uses an identical 10 K summing resistor for
// every channel (only HIT differs, deliberately hotter), which implies the
// designer expected comparable channel amplitudes. Solving for the swing that
// puts FIRE's RMS level alongside ALARM's gives 9.3 V -- independently landing
// on the same midpoint. Two unrelated routes to the same number.
//
// This remains the single scaling knob for FIRE, EXP and HIT: all three are
// linear in it. The datasheet's own spec is taken under a 20 K/20 K load,
// whereas this board loads the pin with ~77 K (R140 100K parallel R144 330K),
// an order of magnitude lighter -- so if anything the true swing sits above
// the midpoint, nearer the 12 V rail span.
//
// Two buffered IC29 taps follow, both simple resistive-gain scalers (no
// filtering -- C86/C85 are DC-blocking coupling caps, not shaping the
// audio-band response we model here):
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

    // Q0.16 gain constants (see docs/audio-rtl-design.md)
    localparam signed [31:0] GAIN_A = -32'sd6554;    // -0.10  * 65536
    localparam signed [31:0] GAIN_B = -32'sd19857;   // -0.303 * 65536

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

    // widen to 64 bits so the >>>16 is a real Q0.16 fixed-point multiply
    wire signed [63:0] prod_a = 64'(noise_raw) * 64'(GAIN_A);
    wire signed [63:0] prod_b = 64'(noise_raw) * 64'(GAIN_B);

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
