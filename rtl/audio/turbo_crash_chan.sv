// Turbo CRASH channel (D-4/11): two independently-triggered
// monostable->filter->VCA chains (/CRASH.S, /CRASH.L) sharing one NOISE
// input, plus a third, un-triggered sub-channel that automatically
// retriggers off IC55 section-1's own Q output every time /CRASH.L fires,
// producing a short secondary "tick" after the main hit -- a deliberate
// double-thump crash sound, not an extra control line from the main board.
// docs/hardware-turbo.md's ledger resolves the third channel's output as
// summing into the SAME CRASH.L/CRASH.LM node (Section 5, uncertainty #8's
// resolution: "both feed the shared output/mixing bus that ultimately
// reaches IC33's summing input"), so this module produces exactly two
// output taps, not three.
//
// SIMPLIFICATIONS, all deliberate and documented (not guesses at unknown
// component values -- the schematic values used below ARE read off D-4/11;
// what's simplified is the DIGITAL FILTER SHAPE and the VCA's response
// curve, per the same discipline turbo_ambulance_chan.sv's planned
// mitigation will use for its own untraced CONT source):
//
//   1. NOISE SOURCE: D-3/11's IC8/S2688 (the board's one physical noise
//      chip) is not yet built as a shared module -- Skid (a later step)
//      owns it canonically. This module instantiates its own local 17-bit
//      LFSR (taps 17/14, same MM5837-family polynomial `noise_mm5837.sv`
//      already uses for Buck, reused here structurally but WITHOUT
//      noise_mm5837.sv's own NOISE.A/NOISE.B gain taps -- those bake in
//      Buck-specific resistor values, R140/R139/R144/R143, that do not
//      appear anywhere on this Turbo sheet). Nominal amplitude reused from
//      noise_mm5837.sv's own datasheet-midpoint derivation (9.5V, same
//      physical noise-IC family, same board-wide rail scheme) -- INFERRED,
//      flagged, not independently re-derived for Turbo's S2688.
//   2. FILTER: D-4/11's actual noise-shaping path is a multi-stage op-amp
//      chain (IC2 sections A/B/C for CRASH.S; IC10 sections 3/4 for
//      CRASH.L) whose individual R/C values are read off the sheet but do
//      not reduce to one clean corner frequency without further derivation
//      this step did not budget for (open item, same category as the
//      workplan's Other-Cars-bias-ladder gap, just smaller). The clearest
//      SINGLE corner-setting element visible in CRASH.S's own chain is
//      R46(10K)/C16(0.01uF) at IC2 section-C's + input: tau = 100 us,
//      corner ~= 1.6 kHz. No equivalently clean single-pole element exists
//      in CRASH.L's own trace (its R98/C29/C36 network is a feedback pair,
//      not a shunt-to-ground corner), so this filter's corner is APPLIED TO
//      BOTH taps by structural analogy (CRASH.L uses the same board-wide
//      biasing convention throughout the rest of this design), INFERRED and
//      flagged -- not a re-derivation of CRASH.L's own network.
//      Implemented as the nearest convenient shift-based one-pole
//      (y[n]=y[n-1]+((x[n]-y[n-1])>>>2), a=0.75, tau~=72us, corner~=2.2kHz)
//      rather than matching 1.6kHz exactly -- a documented implementation
//      approximation, zero DSP cost.
//   3. VCA: IC36 (CRASH.S) and IC29-section-1/IC33 (CRASH.L) are MB4391/
//      HD4391-family VCAs whose control-voltage shaping this step does not
//      model. Modelled here as a hard gate synchronised to each channel's
//      own monostable Q output (filtered noise passes through unchanged
//      while Q is high, zero otherwise) -- no attack/decay envelope beyond
//      the monostable's own on/off window. Same simplification category
//      Ambulance's plan already accepts for its own untraced CONT source.
//   4. OUTPUT TRIM: VR4 (CRASH.S) and VR3 (CRASH.L), both 200K trimmers with
//      no stated wiper position, modelled as a fixed -1/16 placeholder gain
//      (a single right-shift, zero DSP cost) -- same convention as
//      turbo_alarm_chan.sv's GAIN_SHIFT for IC33-B's own uncalibrated VR2.
module turbo_crash_chan (
    input  logic               clk,
    input  logic               rst_n,
    input  logic                crash_s_n,   // /CRASH.S, active low
    input  logic                crash_l_n,   // /CRASH.L, active low
    input  logic               sample_ce,
    output logic signed [15:0] turbo_crash_s_mix,  // CRASH.S / CRASH.SM
    output logic signed [15:0] turbo_crash_l_mix,  // CRASH.L / CRASH.LM (main + retrigger tail summed)
    output logic                dbg_q_crash_s,
    output logic                dbg_q_crash_l_main,
    output logic                dbg_q_crash_l_tail
);

    // ---------------------------------------------------------------
    // Local NOISE source. See header item 1.
    // ---------------------------------------------------------------
    localparam int NOISE_VPP_LSB = 38912; // 9.5 V * 4096 LSB/V, per noise_mm5837.sv
    localparam signed [15:0] NOISE_HALF = 16'(NOISE_VPP_LSB / 2);

    logic [17:1] lfsr;
    wire         fb = lfsr[17] ^ lfsr[14];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= 17'h0B5E7; // distinct seed from noise_mm5837.sv's, non-zero
        end else if (sample_ce) begin
            lfsr <= {lfsr[16:1], fb};
        end
    end

    wire signed [15:0] noise_raw = lfsr[17] ? NOISE_HALF : -NOISE_HALF;

    // ---------------------------------------------------------------
    // Shared one-pole low-pass. See header item 2.
    // ---------------------------------------------------------------
    logic signed [15:0] filtered_noise;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            filtered_noise <= 16'sd0;
        end else if (sample_ce) begin
            filtered_noise <= filtered_noise + ((noise_raw - filtered_noise) >>> 2);
        end
    end

    // ---------------------------------------------------------------
    // Monostables. WIDTH_CYCLES = round(T_seconds * 39,935,064):
    //   CRASH.S (IC54, R329=47k, C152=3.3uF):        51.2 ms -> 2,044,675
    //   CRASH.L main (IC55 sec.1, R87=47k, C=4.7uF):  72.9 ms -> 2,911,266
    //   CRASH.L tail (IC55 sec.2, R330=4.7k, C153=4.7uF): 7.3 ms -> 291,526
    // Every period above is RESOLVED (docs/hardware-turbo.md's D-4/11
    // section: no INFERRED component values gate these timings).
    //
    // The tail monostable's `a_n` is driven directly by the MAIN
    // monostable's own Q (not Q-bar) output -- exactly how IC55 section-2's
    // pin9 (A) is wired on the real board (from section-1's pin13, Q). Since
    // A inputs are negative-edge triggered (ttl_74123.sv's own convention),
    // this fires the tail exactly when the main pulse ENDS, not when it
    // starts -- the "short secondary transient" landing just after the main
    // hit, matching the ledger's "double-pulse crash" description.
    // ---------------------------------------------------------------
    logic q_crash_s, q_crash_l_main, q_crash_l_tail;

    ttl_74123 #(.WIDTH_CYCLES(2044675)) u_74123_crash_s (
        .clk(clk), .rst_n(rst_n), .a_n(crash_s_n), .q(q_crash_s));

    ttl_74123 #(.WIDTH_CYCLES(2911266)) u_74123_crash_l_main (
        .clk(clk), .rst_n(rst_n), .a_n(crash_l_n), .q(q_crash_l_main));

    ttl_74123 #(.WIDTH_CYCLES(291526)) u_74123_crash_l_tail (
        .clk(clk), .rst_n(rst_n), .a_n(q_crash_l_main), .q(q_crash_l_tail));

    assign dbg_q_crash_s      = q_crash_s;
    assign dbg_q_crash_l_main = q_crash_l_main;
    assign dbg_q_crash_l_tail = q_crash_l_tail;

    // ---------------------------------------------------------------
    // Gate + sum + output trim. See header items 3-4. Gating is a plain
    // select (0 or filtered_noise), never a multiply -- zero DSP cost.
    // ---------------------------------------------------------------
    wire signed [15:0] gated_s        = q_crash_s      ? filtered_noise : 16'sd0;
    wire signed [15:0] gated_l_main   = q_crash_l_main  ? filtered_noise : 16'sd0;
    wire signed [15:0] gated_l_tail   = q_crash_l_tail  ? filtered_noise : 16'sd0;
    wire signed [16:0] gated_l_sum    = {gated_l_main[15], gated_l_main} +
                                         {gated_l_tail[15], gated_l_tail};

    localparam int GAIN_SHIFT = 4; // -1/16, same placeholder convention as turbo_alarm_chan.sv

    wire signed [15:0] s_trim   = -(gated_s        >>> GAIN_SHIFT);
    wire signed [16:0] l_trim17 = -(gated_l_sum     >>> GAIN_SHIFT);
    wire signed [15:0] l_trim   =
        (l_trim17 > 17'sd32767)  ? 16'sd32767  :
        (l_trim17 < -17'sd32768) ? 16'sh8000 :
        l_trim17[15:0];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            turbo_crash_s_mix <= 16'sd0;
            turbo_crash_l_mix <= 16'sd0;
        end else begin
            turbo_crash_s_mix <= s_trim;
            turbo_crash_l_mix <= l_trim;
        end
    end

endmodule
