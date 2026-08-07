// Turbo AMBULANCE channel (D-10/11): a twin-tone warble siren -- two
// continuously-running oscillator chains (IC11 stages A/B and IC4 stages
// A/B, each with its own diode/transistor current-source limiter, TR9/D22
// and TR4/D11) summed into an MB4391/HD4391-family VCA (IC36), trimmed by
// VR5 (200K) into the AMBULANCE/AMBULANCE.M output taps.
//
// GATING: IC36's CON pin (VCA gain control) is genuinely untraced anywhere
// in the 13-sheet set -- confirmed, not just unresolved, by a wider
// full-page 6x-DPI re-render specifically done to chase this wire (see
// docs/hardware-turbo.md's D-10/11 section, Uncertainty #9, and the Phase 4
// index). That same re-render DID establish two things with confidence:
// neither oscillator chain is gated by anything on this sheet (both free-
// run continuously), and /AMBU's own path (IC44->D10->R59/R58/C13 envelope
// ->IC4 follower) joins the AUDIO summing node feeding IC36's IN pin, not
// CONT. Since something has to silence the siren when /AMBU is idle, and
// /AMBU is the only signal left that plausibly explains it, this module
// gates the VCA hard on /AMBU -- INFERRED, not traced, and flagged as such
// (the same category of open item Ambulance carried into Step 3's plan from
// the start, now narrowed as far as this sheet alone can narrow it).
//
// TONE GENERATION -- reinterpreted, not just simplified, from the original
// plan's assumption. The two VCO chains' feedback caps (IC11's C44=0.033uF
// vs IC4's C3=6800pF + C4=0.022uF ~= 0.0288uF combined) are CLOSE to each
// other, not octaves apart -- consistent with a warble siren's two pitches
// beating near each other, not a dramatic high/low switch. A third
// component this module now assigns a role to: IC9 (555, R124=330K,
// C38=1.5uF), previously undescribed beyond "gated relaxation circuit."
// Read as a symmetric one-resistor astable (Ra=Rb=R124, a valid low-part-
// count 555 configuration), its period is far too slow to be an audio tone
// (~0.69s, ~1.46 Hz) -- squarely in warble-rate territory for a siren. This
// module therefore models IC9 as the WARBLE-RATE LFO, crossfading between
// the two VCO tones, rather than as a third audio-rate signal. This
// FUNCTIONAL ASSIGNMENT IS AN INTERPRETATION, not confirmed by any label on
// the sheet -- flagged plainly, same as every other INFERRED item here.
//
// Every numeric frequency below (both VCO tones AND the warble rate) is a
// documented PLACEHOLDER, not a schematic-computed value: docs/hardware-
// turbo.md's D-10/11 section already states the real center frequencies are
// "not sheet-computable-with-confidence" (the diode/transistor current-
// source topology sets frequency as a function of bias current, which this
// module does not attempt to derive -- the same simplification class
// applied to every current-source VCO in this phase so far). Picked only to
// be close together (per the feedback-cap observation above) and in an
// audible siren-like range; recalibrate freely once a reference exists.
module turbo_ambulance_chan (
    input  logic               clk,
    input  logic               rst_n,
    input  logic                ambu_n,   // /AMBU, active low
    input  logic               sample_ce,
    output logic signed [15:0] turbo_ambulance_mix, // AMBULANCE / AMBULANCE.M
    output logic                dbg_warble
);

    // ---------------------------------------------------------------
    // Two VCO tones, placeholder frequencies (see header). Both free-run
    // continuously -- confirmed by the re-render that nothing on this sheet
    // gates either oscillator chain.
    //   osc1 (IC11 A/B, C44=0.033uF):        500 Hz placeholder -> 39,935 cyc
    //   osc2 (IC4 A/B, C3+C4~=0.0288uF):      650 Hz placeholder -> 30,719 cyc
    // (both computed as symmetric T_HIGH=T_LOW = round(0.5/f * 39,935,064))
    // ---------------------------------------------------------------
    logic osc1, osc2;

    ttl_555_astable #(.T_HIGH(39935), .T_LOW(39935)) u_osc1 (
        .clk(clk), .rst_n(rst_n), .out(osc1));

    ttl_555_astable #(.T_HIGH(30719), .T_LOW(30719)) u_osc2 (
        .clk(clk), .rst_n(rst_n), .out(osc2));

    // ---------------------------------------------------------------
    // IC9 warble-rate LFO, placeholder ~1.46 Hz (R124=330K, C38=1.5uF, read
    // as a symmetric one-resistor astable: T_high=T_low=0.693*R*C=0.343s).
    // ---------------------------------------------------------------
    logic warble;

    ttl_555_astable #(.T_HIGH(13701710), .T_LOW(13701710)) u_warble (
        .clk(clk), .rst_n(rst_n), .out(warble));

    assign dbg_warble = warble;

    localparam signed [15:0] TONE_HALF = 16'sd8192; // 2V, placeholder -- same convention as turbo_skid_chan.sv

    wire signed [15:0] osc1_bipolar = osc1 ? TONE_HALF : -TONE_HALF;
    wire signed [15:0] osc2_bipolar = osc2 ? TONE_HALF : -TONE_HALF;
    wire signed [15:0] tone_mix     = warble ? osc1_bipolar : osc2_bipolar;

    // ---------------------------------------------------------------
    // Gate (see header) + output trim. VR5 (200K trimmer, no stated wiper
    // position) modelled as the same -1/16 placeholder gain used throughout
    // this phase (turbo_alarm_chan.sv's GAIN_SHIFT, turbo_crash_chan.sv's,
    // turbo_skid_chan.sv's).
    // ---------------------------------------------------------------
    wire gate = ~ambu_n;
    wire signed [15:0] gated = gate ? tone_mix : 16'sd0;

    localparam int GAIN_SHIFT = 4;
    wire signed [15:0] trim = -(gated >>> GAIN_SHIFT);

    always_ff @(posedge clk) begin
        if (!rst_n) turbo_ambulance_mix <= 16'sd0;
        else        turbo_ambulance_mix <= trim;
    end

endmodule
