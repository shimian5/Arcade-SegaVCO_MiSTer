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
    output logic signed [15:0] audio_out,

    // Shared exact multiplier client. LA4460 has a strictly dependent chain,
    // so it can have at most one request outstanding.
    output logic                mul_req_valid,
    input  logic                mul_req_ready,
    output logic signed [63:0]  mul_req_a,
    output logic signed [63:0]  mul_req_b,
    output logic          [6:0] mul_req_a_width,
    output logic          [6:0] mul_req_b_width,
    output logic          [7:0] mul_req_tag,
    input  logic                mul_rsp_valid,
    input  logic signed [127:0] mul_rsp_product,
    input  logic          [7:0] mul_rsp_tag
);

    // Poles at fs = 47,998.875 Hz, all Q0.24. exp(-1/(fs*tau)) for the
    // high-passes, 1 - exp(-2*pi*f/fs) for the low-pass gain.
    // Narrowed to 27 bits, not 32: every value here fits in ~25 bits, and
    // Cyclone V's DSP blocks natively multiply at 27x27 -- a 32-bit operand
    // needs 2 DSP blocks (or an 18x18 decomposition) for no numeric reason,
    // same fix as HIT/EXP/ALARM. See docs/audio-rtl-design.md, "DSP block
    // budget". The STATE side of each multiply stays at its documented
    // width below (up to ~38 bits) regardless -- narrowing the coefficient
    // doesn't and can't shrink that operand, but it stops the coefficient
    // itself from wasting a second block.
    localparam signed [26:0] A_C69_Q24 = 27'sd16776596;  // tau 0.5634 s, 0.282 Hz
    localparam signed [26:0] A_C83_Q24 = 27'sd16774890;  // tau 0.1502 s, 1.059 Hz
    localparam signed [26:0] A_CNF_Q24 = 27'sd16674312;  // 47.000 Hz
    localparam signed [26:0] B_CX_Q24  = 27'sd11612258;  // 9000.0 Hz low-pass

    // ---------------------------------------------------------------
    // Output gain and the clip point.
    //
    // OUT_GAIN_Q16 is the product of three factors:
    //
    //  a) VR1's divider, at wiper fraction k = 0.085:
    //       R_upper = (1-k)*20K = 18.3 K, R_lower = k*20K = 1.7 K, load ri = 30 K
    //       R_par   = 1.7K || 30K = 1.610 K
    //       divider = 1.610 / (100 + 18.3 + 1.610) = 0.013417
    //  b) the LA4460's fixed voltage gain, 51 dB = 354.8134 (spec 49/51/53 dB)
    //  c) the scale from 4096 LSB/V to digital full scale, where FULL SCALE IS
    //     THE AMP'S CLIP POINT:  32767 / (8.6 V * 4096) = 0.9302042
    //
    //   0.013417 * 354.813389 * 0.9302042 = 4.42863,  x 65536 = 290214
    //
    // k = 0.085 -- RECALIBRATED. Was 0.100, chosen provisionally when SHIP was
    // built and this file's output stage first replaced the old scalar
    // MASTER_VOL; that calibration targeted scenario 20 (the worst-case
    // pile-up: ALARM+HIT+SHIP+FIRE) landing at -1.66 dBFS, matching the old
    // MASTER_VOL-era loudness. FIRE's envelope and filter were both wrong at
    // the time (see fire_chan.sv) and sat far quieter than the real board, so
    // that calibration was implicitly done a fraction of a channel light: once
    // FIRE was fixed to its correct, considerably louder level, scenario 20's
    // peak crept up to -0.14 dBFS -- uncomfortably close to the amp's own
    // clip point on top of the individual channels already railing into it.
    // Recalibrated the same way, against the same scenario and the same
    // -1.66 dBFS target, now that all six channels are correctly modelled:
    // k=0.085 lands scenario 20 at -1.62 dBFS (measured after the FIRE fix,
    // 31700/32767 -> 27192/32767).
    //
    // k remains the one number in the whole chain chosen by taste rather than
    // derived -- a real 20 K panel pot -- and is isolated so that ONLY
    // OUT_GAIN_Q16 changes when it moves, exactly as MASTER_VOL was isolated
    // before it. Nothing else in this file depends on k.
    //
    // THE SATURATION BELOW IS PHYSICAL, NOT A FORMAT GUARD. V_CLIP = 8.6 V
    // differential: the datasheet quotes 12 W into 4 ohm at Vcc = 13.2 V, i.e.
    // 9.8 V peak, so the device itself drops 3.4 V total; this board runs the
    // amp on 12 V, giving 12 - 3.4 = 8.6 V. Clipping here IS the real board
    // clipping, and it is a genuine part of how this cabinet sounds when several
    // channels pile up. It must not be tuned away by lowering k further than
    // this -- k=0.085 relieves the MASTER stage's own headroom squeeze, it
    // does not (and should not) stop any individual channel from railing.
    // ---------------------------------------------------------------
    localparam signed [26:0] OUT_GAIN_Q16 = 27'sd290214;

    // ---------------------------------------------------------------
    // 2^32 LSB/V states. |x| <= 8 V * 2^32 = 3.44e10 (36 bits), so |hp_sum|
    // stays under 2^38 and every product below fits a 64-bit intermediate.
    // Do not narrow these below their documented width -- see the header
    // note on the 0.282 Hz pole's stall floor.
    // ---------------------------------------------------------------
    logic signed [47:0] x1_d, y1;    // C69  high-pass
    logic signed [47:0] x2_d, y2;    // C83  high-pass
    logic signed [47:0] x3_d, y3;    // CNF  high-pass
    logic signed [47:0] y4;          // Cx   low-pass

    // 4096 (2^12) LSB/V -> 2^32 LSB/V. mix_in is the final six-channel sum,
    // read live (not sample_ce-gated) same as HIT/EXP read their noise
    // input -- it only actually changes once per audio sample once its own
    // producers have settled, hundreds of clk_sys cycles before it matters.
    wire signed [47:0] x1 = 48'(mix_in) <<< 20;

    // ---------------------------------------------------------------
    // PIPELINED: this was four cascaded one-pole filters (three highpass,
    // one lowpass) chaining FIVE serial multiplies (three highpass poles,
    // the lowpass gain, and the output gain) in one combinational cloud
    // between sample_ce edges -- the identical failure mode SHIP's
    // original five-multiply tail had, just spread across four filter
    // sections instead of one VCA chain. A real Quartus build with
    // HIT/EXP/ALARM already fixed put the domain's new worst path here:
    // `la4460:u_amp|x2_d[23]` to `audio_out[14]`, 56.311 ns data delay,
    // -32.095 ns slack. See docs/audio-rtl-design.md, "DSP block budget".
    //
    // Same discipline as everywhere else in this design: one multiply per
    // register-to-register hop, free-running on `clk`. Each stage's sum/
    // diff wire already routes every operand through its own explicit
    // width cast (`40'(y1)`, etc.) before the add/sub, and every product is
    // registered directly from a bare `coef * sum + rounding_const`
    // expression -- both patterns were already correct in the prior
    // combinational form (see hit_chan.sv's header note on why this
    // matters), so converting each `wire` below into a pipeline register is
    // purely mechanical, not a rewrite.
    //
    // Unlike alarm_chan.sv's pipeline, no special reset-value derivation is
    // needed: this file's true idle state is exactly zero at every stage
    // (uncharged coupling caps -- see the header note), which is also the
    // pipeline's natural power-on value, so a plain zero reset is already
    // self-consistent. The one scenario that captures this file's output
    // from reset without settling (mute-release timing) has its output
    // forced to hard zero by `dc_mute` throughout that exact window
    // regardless of internal pipeline state, so it cannot expose a
    // warm-up transient even in principle.
    // ---------------------------------------------------------------

    // The old free-running pipeline instantiated all five multipliers at once.
    // This micro-sequencer evaluates the identical dependency chain through one
    // shared lane after each sample_ce. All state commits together after the
    // fifth response, well before the next sample_ce (832 clocks later).
    localparam logic [7:0] TAG_HP1 = 8'hA0;
    localparam logic [7:0] TAG_HP2 = 8'hA1;
    localparam logic [7:0] TAG_HP3 = 8'hA2;
    localparam logic [7:0] TAG_LP  = 8'hA3;
    localparam logic [7:0] TAG_OUT = 8'hA4;

    logic [2:0] op_index;
    logic waiting_response;
    logic [6:0] settle_count;
    logic next_valid;
    logic signed [47:0] x1_sample;
    logic signed [47:0] y1_work, y2_work, y3_work, y4_work;
    logic signed [15:0] amp_sample;

    wire signed [127:0] rounded_q24 = mul_rsp_product + 128'sd8388608;
    wire signed [47:0] rsp_q24 = 48'(rounded_q24 >>> 24);
    wire signed [127:0] rounded_out = mul_rsp_product + 128'sd34359738368;
    wire signed [127:0] rsp_out_full = rounded_out >>> 36;
    wire signed [15:0] rsp_out_sat =
        (rsp_out_full > 128'sd32767)  ?  16'sd32767 :
        (rsp_out_full < -128'sd32768) ? -16'sd32768 :
        rsp_out_full[15:0];
    wire signed [39:0] hp1_sum_start = 40'(y1) + 40'(x1) - 40'(x1_d);
    wire signed [39:0] hp2_sum_rsp   = 40'(y2) + 40'(rsp_q24) - 40'(x2_d);
    wire signed [39:0] hp3_sum_rsp   = 40'(y3) + 40'(rsp_q24) - 40'(x3_d);
    wire signed [39:0] lp_diff_rsp   = 40'(rsp_q24) - 40'(y4);

    task automatic issue_multiply(
        input logic signed [63:0] a,
        input logic signed [63:0] b,
        input logic [6:0] aw,
        input logic [6:0] bw,
        input logic [7:0] tag
    );
        begin
            mul_req_a       <= a;
            mul_req_b       <= b;
            mul_req_a_width <= aw;
            mul_req_b_width <= bw;
            mul_req_tag     <= tag;
            mul_req_valid   <= 1'b1;
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            x1_d <= '0;
            x2_d <= '0;
            x3_d <= '0;
            y1   <= '0;
            y2   <= '0;
            y3   <= '0;
            y4   <= '0;
            x1_sample <= '0;
            y1_work <= '0;
            y2_work <= '0;
            y3_work <= '0;
            y4_work <= '0;
            amp_sample <= '0;
            audio_out <= '0;
            op_index <= 3'd0;
            waiting_response <= 1'b0;
            settle_count <= 7'd0;
            next_valid <= 1'b0;
            mul_req_valid <= 1'b0;
            mul_req_a <= '0;
            mul_req_b <= '0;
            mul_req_a_width <= 7'd1;
            mul_req_b_width <= 7'd1;
            mul_req_tag <= '0;
        end else begin
            audio_out <= dc_mute ? 16'sd0 : amp_sample;

            if (mul_req_valid && mul_req_ready) begin
                mul_req_valid <= 1'b0;
                waiting_response <= 1'b1;
            end

            // Upstream channel pipelines settle shortly after sample_ce. The
            // former free-running LA4460 pipeline continuously recomputed from
            // that settled value, so its next state was already waiting when
            // the following sample_ce arrived. Preserve that phase: wait 64
            // clocks, compute during the sample window, and commit at the next
            // sample_ce. Starting work on sample_ce instead would add exactly
            // one audio sample of latency to the entire cabinet mix.
            if (sample_ce) begin
                settle_count <= 7'd64;
                if (next_valid) begin
                    x1_d <= x1_sample;
                    x2_d <= y1_work;
                    x3_d <= y2_work;
                    y1 <= y1_work;
                    y2 <= y2_work;
                    y3 <= y3_work;
                    y4 <= y4_work;
                    next_valid <= 1'b0;
                end
            end else if (settle_count != 0) begin
                settle_count <= settle_count - 1'b1;
            end

            if (!mul_req_valid && !waiting_response && settle_count == 7'd1) begin
                x1_sample <= x1;
                op_index <= 3'd0;
                issue_multiply(64'(A_C69_Q24),
                    64'(hp1_sum_start),
                    7'd27, 7'd40, TAG_HP1);
            end

            if (mul_rsp_valid && waiting_response) begin
                waiting_response <= 1'b0;
                case (op_index)
                    3'd0: begin
                        y1_work <= rsp_q24;
                        op_index <= 3'd1;
                        issue_multiply(64'(A_C83_Q24),
                            64'(hp2_sum_rsp),
                            7'd27, 7'd40, TAG_HP2);
                    end
                    3'd1: begin
                        y2_work <= rsp_q24;
                        op_index <= 3'd2;
                        issue_multiply(64'(A_CNF_Q24),
                            64'(hp3_sum_rsp),
                            7'd27, 7'd40, TAG_HP3);
                    end
                    3'd2: begin
                        y3_work <= rsp_q24;
                        op_index <= 3'd3;
                        issue_multiply(64'(B_CX_Q24),
                            64'(lp_diff_rsp),
                            7'd27, 7'd40, TAG_LP);
                    end
                    3'd3: begin
                        y4_work <= y4 + rsp_q24;
                        op_index <= 3'd4;
                        issue_multiply(64'(OUT_GAIN_Q16),
                            64'(y4 + rsp_q24), 7'd27, 7'd48, TAG_OUT);
                    end
                    default: begin
                        amp_sample <= rsp_out_sat;
                        next_valid <= 1'b1;
                    end
                endcase
            end
        end
    end

`ifdef VERILATOR_SIM
    always_ff @(posedge clk) begin
        if (rst_n && mul_rsp_valid && waiting_response &&
            (mul_rsp_tag != (TAG_HP1 + op_index))) begin
            $error("LA4460 shared-multiply tag mismatch");
        end
        if (rst_n && sample_ce && (mul_req_valid || waiting_response)) begin
            $error("LA4460 shared multiply missed sample deadline");
        end
    end
`endif

endmodule
