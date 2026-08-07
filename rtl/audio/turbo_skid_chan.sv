// Turbo SKID channel (D-3/11): a continuously-running IC37 555 tone,
// textured by filtered NOISE (IC1 sections A/B/C) and audible while
// /SLIP or /SPIN is active, into an IC18 VCA -> VR1 trim -> four identical
// coupled outputs (SKID.F/R/L/M).
//
// One structural finding from docs/trace/turbo_audio_D3of11.md drove the
// output-stage architecture here, not just component-value approximations:
// the noise-filter chain (IC1 A/B/C) and the SLIP/SPIN combiner (through
// IC1 section D, a follower) converge on THE SAME node feeding IC37's 555
// timing network -- i.e., on the real board, SLIP/SPIN and NOISE both
// bias/modulate the 555's oscillation, they do not gate a VCA the way every
// other channel's trigger does at the point they converge.
//
// **IC18's CON pin, RESOLVED 2026-08-06** (was UNTRACED as of Step 7's
// original build): a wider full-page 6x-DPI re-render followed CON's wire
// past where the original narrower crop cut it off, and found it lands
// exactly on IC1 section D's own output (pin 8) -- the identical node
// already known to feed the 555's bias network above. This CONFIRMS, not
// infers, that IC18's VCA gain control is driven by the SLIP/SPIN
// combiner. Step 7's original gate (below) was chosen as a board-wide-
// pattern INFERENCE with no supporting wire at all; it now matches a
// directly-traced fact instead. See docs/hardware-turbo.md's D-3/11
// section for the full resolution.
//
// SIMPLIFICATIONS, all deliberate and documented:
//
//   A. GATING (now CONFIRMED, not inferred, per the resolution above):
//      "/SLIP's monostable active OR /SPIN asserted" is the real gating
//      condition. What remains a simplification is HOW it gates: the real
//      IC1-section-D node is an analog combiner voltage (shaped by R7/D1/R6
//      for SLIP and R5 for SPIN, bypassed by C1), not an idealised hard
//      digital 0/1 -- modelled here as a hard gate anyway, the same
//      ordinary category of simplification used for every other channel's
//      VCA response curve in this phase, not a gap unique to this sheet.
//   B. MODULATION -> TEXTURE (reworks the noise/555 convergence noted above
//      into something buildable): rather than literally frequency-
//      modulating a 555 model (which
//      ttl_555_astable.sv does not support, and building a fully variable
//      relaxation oscillator here is out of this step's scope), IC37 is
//      modelled as a FIXED-frequency tone, and the noise-filter chain's
//      contribution is instead summed in as an additive "grit" component
//      at the output stage. This preserves the qualitative character (a
//      tone roughened by noise, not a pure tone or pure noise) without
//      claiming to reproduce the real board's actual FM behaviour.
//   C. NOISE SOURCE: a local LFSR, same as turbo_crash_chan.sv and for the
//      same reason (Skid, not Crash, is the sheet that actually owns
//      D-3/11's IC8/S2688 -- but Crash was built first and already has its
//      own instance committed). Left as two independent instances rather
//      than refactoring Crash's already-committed port list: both use the
//      identical LFSR polynomial and nominal amplitude, so the only real
//      difference from a single shared chip is that the two channels' noise
//      textures are decorrelated instead of identical -- inaudible in
//      isolation, and only matters if Crash and Skid are analysed together
//      for correlation, which no gameplay scenario does.
//   D. IC1 A/B/C's own filter corner is not cleanly computable from the
//      sheet (section A's R43/C9 feedback pair implies an implausibly slow
//      ~3.4 Hz corner if read as a simple single-pole low-pass, and section
//      C's own feedback, R40 alone with no capacitor, is a pure resistive
//      gain stage, not a filter at all) -- reused the same shift-based
//      one-pole approximation (a=0.75, >>>2, corner ~2.2kHz) already used
//      as a documented placeholder in turbo_crash_chan.sv, for the same
//      reason: a clean, cheap, honestly-approximate corner rather than an
//      unjustified precise one.
//   E. TONE AMPLITUDE: IC37's own output swing before VR1's trim is not
//      computable from the sheet (no absolute op-amp gain chain reduces to
//      a stated peak voltage the way ALARM's did). A placeholder amplitude
//      (TONE_HALF, chosen as a round mid-scale value) is used -- VR1's own
//      uncalibrated trim absorbs any absolute-level error regardless.
//   F. OUTPUT TRIM: VR1 (200K trimmer, no stated wiper position) modelled
//      as the same -1/16 placeholder gain convention used throughout this
//      phase (turbo_alarm_chan.sv's GAIN_SHIFT, turbo_crash_chan.sv's).
module turbo_skid_chan (
    input  logic               clk,
    input  logic               rst_n,
    input  logic                slip_n,     // /SLIP, active low
    input  logic                spin_n,     // /SPIN, active low
    input  logic               sample_ce,
    output logic signed [15:0] turbo_skid_mix,  // SKID.F/R/L/M (one common node)
    output logic                dbg_q_slip,
    output logic                dbg_gate
);

    // ---------------------------------------------------------------
    // Local NOISE source. See header item C.
    // ---------------------------------------------------------------
    localparam int NOISE_VPP_LSB = 38912; // 9.5 V * 4096 LSB/V, per noise_mm5837.sv
    localparam signed [15:0] NOISE_HALF = 16'(NOISE_VPP_LSB / 2);

    logic [17:1] lfsr;
    wire         fb = lfsr[17] ^ lfsr[14];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            lfsr <= 17'h13579; // distinct seed from the other two LFSR instances
        end else if (sample_ce) begin
            lfsr <= {lfsr[16:1], fb};
        end
    end

    wire signed [15:0] noise_raw = lfsr[17] ? NOISE_HALF : -NOISE_HALF;

    // ---------------------------------------------------------------
    // Shared one-pole low-pass. See header item D.
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
    // IC37 555, fixed frequency. R268=47k (5V->pin7/DIS), unlabeled 68k
    // (pin7->THR/TRG node), C130=0.01uF (THR/TRG node->ground) -- same
    // Ra/Rb astable reduction as turbo_alarm_chan.sv's IC48:
    //   T_high = 0.693*(Ra+Rb)*C = 796.95 us -> 31,826 clk_sys cycles
    //   T_low  = 0.693*Rb*C      = 471.24 us -> 18,819 clk_sys cycles
    // f = 788.5 Hz. Every value here is legibly transcribed in the trace's
    // own tables (docs/trace/turbo_audio_D3of11.md section 4) and was NOT
    // flagged as an open uncertainty by that trace's own self-check -- so
    // this reuses the transcription's stated confidence rather than
    // independently re-rendering the crop, unlike D-2/11's Rext values
    // (which the trace itself flagged as ambiguous and Step 2 had to
    // resolve with a fresh high-DPI re-read).
    // ---------------------------------------------------------------
    logic tone555;

    ttl_555_astable #(
        .T_HIGH (31826),
        .T_LOW  (18819)
    ) u_555 (
        .clk    (clk),
        .rst_n  (rst_n),
        .out    (tone555)
    );

    localparam signed [15:0] TONE_HALF = 16'sd8192; // 2V, placeholder -- see header item E
    wire signed [15:0] tone_bipolar = tone555 ? TONE_HALF : -TONE_HALF;

    // ---------------------------------------------------------------
    // SLIP monostable: IC54, one section. Unlabeled 47k/3.3uF Rext/Cext --
    // same values as turbo_crash_chan.sv's CRASH.S (R329=47k/C152=3.3uF),
    // so the same WIDTH_CYCLES applies: 51.2 ms -> 2,044,675 cycles.
    // SPIN has no timing element on this sheet (IC44 is a plain buffer,
    // not a monostable) -- passed through as a raw active-low level.
    // ---------------------------------------------------------------
    logic q_slip;

    ttl_74123 #(.WIDTH_CYCLES(2044675)) u_74123_slip (
        .clk(clk), .rst_n(rst_n), .a_n(slip_n), .q(q_slip));

    wire spin_level = ~spin_n;

    assign dbg_q_slip = q_slip;

    // ---------------------------------------------------------------
    // Gate (header item A) + grit sum (header item B) + output trim
    // (header item F).
    // ---------------------------------------------------------------
    wire gate = q_slip | spin_level;
    assign dbg_gate = gate;

    wire signed [17:0] grit_sum18 = {{2{tone_bipolar[15]}}, tone_bipolar} +
                                     {{2{filtered_noise[15]}}, filtered_noise >>> 2};

    localparam int GAIN_SHIFT = 4; // -1/16, same placeholder convention as the other Phase 4 channels

    wire signed [17:0] gated18 = gate ? grit_sum18 : 18'sd0;
    wire signed [17:0] trim18  = -(gated18 >>> GAIN_SHIFT);
    wire signed [15:0] trim_sat =
        (trim18 > 18'sd32767)  ? 16'sd32767  :
        (trim18 < -18'sd32768) ? 16'sh8000 :
        trim18[15:0];

    always_ff @(posedge clk) begin
        if (!rst_n) turbo_skid_mix <= 16'sd0;
        else        turbo_skid_mix <= trim_sat;
    end

endmodule
