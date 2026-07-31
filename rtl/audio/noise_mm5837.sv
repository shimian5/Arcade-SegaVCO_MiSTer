// MM5837 pseudo-random noise generator (sheet 3). 17-bit LFSR, taps 17 and
// 14, XOR feedback, advanced once per sample_ce (47,999 Hz), which sits
// inside the part's nominal 32-64 kHz clock range and avoids any beat
// against the audio rate itself. See docs/audio-rtl-design.md, "NOISE --
// MM5837". Raw amplitude is undocumented on the schematic and is exposed
// as NOISE_VPP_LSB (default 4096 LSB = 1.0 V) for later tuning. Two
// buffered IC29 taps follow, both simple resistive-gain scalers (no
// filtering -- C86/C85 are DC-blocking coupling caps, not shaping the
// audio-band response we model here):
//   NOISE.A: gain -0.10  (R140 100K in, R139 10K fb)  -> FIRE, EXP
//   NOISE.B: gain -0.303 (R144 330K in, R143 100K fb) -> HIT
module noise_mm5837 #(
    parameter int NOISE_VPP_LSB = 4096   // 4096 LSB = 1V, undocumented amplitude
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
