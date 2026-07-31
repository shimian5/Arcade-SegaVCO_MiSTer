// IC27 LA4460 -- the Sanyo BTL power amp, plus the input network between IC28
// (the master mixer's output amp) and its pin 2. Sheet 1, PDF page 45.
// Datasheet: docs/reference/LA4460.pdf.
//
//   IC28 out -> C69 4.7uF -> R45 100K -> VR1 20K pot (top at R45, bottom to
//               GND, wiper out) -> C83 4.7uF -> LA4460 pin 2 (IN, ri = 30K typ)
//   LA4460: BTL, pins 9/7 = OUT1/OUT2 across the speaker, gain fixed at 51 dB
//
// Everything runs at `sample_ce`. `mix_in` is the house format, 4096 LSB = 1 V,
// an AC quantity about the implicit 6 V rail.
//
// Four one-pole sections, in order:
//
//   1. C69 against (R45 + R_upper + R_par)          high-pass, 0.282 Hz
//   2. C83 against (R_src + ri)                     high-pass, 1.059 Hz
//   3. the amp's OWN low-frequency roll-off         high-pass, 47 Hz
//   4. the amp's own high-frequency roll-off        low-pass,  9 kHz
//
// Sections 3 and 4 are not on the schematic as R/C pairs -- they are read off
// the datasheet's "f Response" graph (page 4 of the PDF), which is exactly what
// that graph is for:
//
//   * The LF corner is set by the CNF caps C82/C81 = 47 uF. The graph plots a
//     100 uF and a 47 uF curve; the 47 uF curve is -3 dB at about 47 Hz and
//     -9 dB at 20 Hz. This is the single most audible thing the amp does to the
//     signal, and it is datasheet-backed rather than invented.
//   * The HF corner is set by Cx = C84 0.01 uF. Same graph: the "0.01 uF" curve
//     against the "C1 = 0" curve, which sits nearer 20 kHz. 9 kHz.
//
// Both of those are read off a PRINTED LOG GRAPH, so they are good to maybe
// +/-20 %. They are THE TWO TUNING KNOBS of this module; nothing else here is
// soft. Sections 1 and 2 are computed from schematic R and C values and are not
// knobs.
//
// ---------------------------------------------------------------------------
// Numeric format
// ---------------------------------------------------------------------------
// The high-pass states are carried at 2^32 LSB/V -- 20 fractional bits below
// the 4096 LSB/V input -- in signed [47:0], exactly as dc_block.sv does, and
// every shift rounds to nearest.
//
// This matters MORE here than anywhere else in the design, because the 0.282 Hz
// pole is the slowest in the whole thing. A leaky integrator STALLS once its
// per-step decrement falls below the rounding threshold, at |y| = 0.5/(1-a)
// state LSB:
//
//   pole        1-a          stall floor        as volts at 2^32 LSB/V
//   C69  0.282  3.695e-5     13530 state LSB    3.15 uV
//   C83  1.059  1.390e-4      3606 state LSB    0.84 uV
//   CNF  47.0   6.132e-3        82 state LSB    0.019 uV
//
// One output LSB is 1 / 3810 V = 262 uV, so even the worst of those is ~80x
// under the last bit and the amp reaches true digital silence. At the 2^20
// LSB/V that the channels use internally, the same 13530 codes would be 12.9 mV
// -- a permanent 49-LSB DC offset on the master output. Do not narrow this.
//
// At reset the coupling caps are UNCHARGED. Because the house format carries
// every channel as an AC quantity ABOUT the 6 V rail, an uncharged coupling cap
// on a 6 V node is exactly `x_d = 0` -- there is no step to inject and no reset
// transient. That is why C69 and C83, unlike ALARM's C88, contribute no thump
// of their own; C88 sits between a TTL node and a 6 V Thevenin and really does
// have a step across it.
module la4460 (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic               dc_mute,   // from mute_ctl, 1 = muted
    input  logic signed [15:0] mix_in,    // 4096 LSB = 1 V
    output logic signed [15:0] audio_out
);

    // Poles at fs = 47,998.875 Hz, all Q0.24. exp(-1/(fs*tau)) for the
    // high-passes, 1 - exp(-2*pi*f/fs) for the low-pass gain.
    localparam signed [63:0] A_C69_Q24 = 64'sd16776596;  // tau 0.5634 s, 0.282 Hz
    localparam signed [63:0] A_C83_Q24 = 64'sd16774890;  // tau 0.1502 s, 1.059 Hz
    localparam signed [63:0] A_CNF_Q24 = 64'sd16674312;  // 47.000 Hz
    localparam signed [63:0] B_CX_Q24  = 64'sd11612258;  // 9000.0 Hz low-pass

    // ---------------------------------------------------------------
    // Output gain and the clip point.
    //
    // OUT_GAIN_Q16 is the product of three factors:
    //
    //  a) VR1's divider, at wiper fraction k = 0.100:
    //       R_upper = 18 K, R_lower = 2 K, load ri = 30 K
    //       R_par   = 2K || 30K = 1.875 K
    //       divider = 1.875 / (100 + 18 + 1.875) = 0.015641
    //  b) the LA4460's fixed voltage gain, 51 dB = 354.8134 (spec 49/51/53 dB)
    //  c) the scale from 4096 LSB/V to digital full scale, where FULL SCALE IS
    //     THE AMP'S CLIP POINT:  32767 / (8.6 V * 4096) = 0.9302042
    //
    //   0.01564129 * 354.813389 * 0.9302042 = 5.162391,  x 65536 = 338322
    //
    // k = 0.100 is PROVISIONAL. It is the setting of VR1, a real 20 K panel pot,
    // so it is the one number in the whole chain chosen by taste rather than
    // derived -- and it will be recalibrated after a sim run. It is isolated so
    // that ONLY OUT_GAIN_Q16 changes when it moves, exactly as MASTER_VOL was
    // isolated before it. Nothing else in this file depends on k.
    //
    // THE SATURATION BELOW IS PHYSICAL, NOT A FORMAT GUARD. V_CLIP = 8.6 V
    // differential: the datasheet quotes 12 W into 4 ohm at Vcc = 13.2 V, i.e.
    // 9.8 V peak, so the device itself drops 3.4 V total; this board runs the
    // amp on 12 V, giving 12 - 3.4 = 8.6 V. Clipping here IS the real board
    // clipping, and it is a genuine part of how this cabinet sounds when several
    // channels pile up. It must not be tuned away by lowering k.
    // ---------------------------------------------------------------
    localparam longint OUT_GAIN_Q16 = 338322;

    // ---------------------------------------------------------------
    // 2^32 LSB/V states. |x| <= 8 V * 2^32 = 3.44e10 (36 bits), so |hp_sum|
    // stays under 2^38 and every product below fits a 64-bit intermediate.
    // ---------------------------------------------------------------
    logic signed [47:0] x1_d, y1;    // C69  high-pass
    logic signed [47:0] x2_d, y2;    // C83  high-pass
    logic signed [47:0] x3_d, y3;    // CNF  high-pass
    logic signed [47:0] y4;          // Cx   low-pass

    // 4096 (2^12) LSB/V -> 2^32 LSB/V
    wire signed [47:0] x1 = 48'(mix_in) <<< 20;

    // y[n] = a * (y[n-1] + x[n] - x[n-1]), rounded to nearest
    wire signed [63:0] hp1_sum  = 64'(y1) + 64'(x1)   - 64'(x1_d);
    wire signed [63:0] hp1_prod = A_C69_Q24 * hp1_sum + 64'sd8388608;
    wire signed [47:0] y1_next  = 48'(hp1_prod >>> 24);

    wire signed [63:0] hp2_sum  = 64'(y2) + 64'(y1_next) - 64'(x2_d);
    wire signed [63:0] hp2_prod = A_C83_Q24 * hp2_sum + 64'sd8388608;
    wire signed [47:0] y2_next  = 48'(hp2_prod >>> 24);

    wire signed [63:0] hp3_sum  = 64'(y3) + 64'(y2_next) - 64'(x3_d);
    wire signed [63:0] hp3_prod = A_CNF_Q24 * hp3_sum + 64'sd8388608;
    wire signed [47:0] y3_next  = 48'(hp3_prod >>> 24);

    // y += (b * (x - y)) >> 24, rounded to nearest
    wire signed [63:0] lp_diff  = 64'(y3_next) - 64'(y4);
    wire signed [63:0] lp_prod  = B_CX_Q24 * lp_diff + 64'sd8388608;
    wire signed [47:0] y4_next  = y4 + 48'(lp_prod >>> 24);

    // ---------------------------------------------------------------
    // Output stage. Spec form is
    //     sat16( (filtered * OUT_GAIN_Q16 + 32768) >>> 16 )
    // with `filtered` at 4096 LSB/V. Here the filter state is 20 bits finer, so
    // the two shifts are FOLDED into one >>> 36 rather than rounding down to
    // 4096 LSB/V first and then multiplying by 5.16 -- which would multiply the
    // intermediate rounding error by the gain for no reason. Identical intent,
    // one rounding instead of two.
    // ---------------------------------------------------------------
    wire signed [63:0] out_prod = 64'(y4_next) * 64'(OUT_GAIN_Q16)
                                + 64'sd34359738368;          // 2^35, round to nearest
    wire signed [63:0] out_full = out_prod >>> 36;

    wire signed [15:0] out_sat =
        (out_full >  64'sd32767) ?  16'sd32767 :
        (out_full < -64'sd32768) ? -16'sd32768 :
        out_full[15:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            // Coupling caps uncharged == zero AC state; see the header note.
            x1_d      <= '0;
            x2_d      <= '0;
            x3_d      <= '0;
            y1        <= '0;
            y2        <= '0;
            y3        <= '0;
            y4        <= '0;
            audio_out <= 16'sd0;
        end else if (sample_ce) begin
            x1_d <= x1;
            x2_d <= y1_next;
            x3_d <= y2_next;
            y1   <= y1_next;
            y2   <= y2_next;
            y3   <= y3_next;
            y4   <= y4_next;

            // DC mute is attenuation = INFINITY (datasheet), so this is a hard
            // zero, not an attenuator. The filter states keep running
            // underneath, which is what the real board does too: muting pin 6
            // kills the output stage, it does not discharge C69/C83/CNF. So
            // unmuting resumes mid-signal rather than thumping.
            audio_out <= dc_mute ? 16'sd0 : out_sat;
        end
    end

endmodule
