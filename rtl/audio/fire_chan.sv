// FIRE channel (laser), sheet 3. See docs/audio-rtl-design.md, "FIRE --
// laser" for the full derivation; this module must not contradict that
// file. Chain:
//   /FIRE -> IC4 74123 one-shot (tw=21.15ms) -> envelope (fast charge to
//   3.80V while gated, tau=1.02s decay) -> splits into:
//     control leg:  V2 = 5.475 - 0.839*Venv -> piecewise A(V2) -> VCA gain
//                   (LUT, linear interpolation)
//     filter leg:   Tr1 conduction -> IC12, a genuine 2-pole filter with a
//                   RESONANT PEAK that sweeps continuously with Tr1's
//                   conductance (NOT a simple gain/pole blend -- see below)
//   signal path: noise_a -> IC12 (filter leg) -> input atten 0.0991 ->
//                x VCA gain (control leg) -> output gain -2.2 -> FIRE MIX
//
// IC12 CORRECTION (found chasing a real-hardware report: "should sound like
// a laser whistle pitching down, ours is flat/a puff of noise"). IC12's
// feedback isn't just R35 in parallel with C32+C33 -- C32/C33's MIDPOINT is
// tapped and returned to ground through R31 (100 ohm) + Tr1's variable
// collector resistance (parallel with R32 1.5K), a FINITE, non-zero, non-
// infinite shunt impedance in every Tr1 state. A bridged-capacitor feedback
// network with a finite-impedance midpoint tap is a genuine 2-pole network,
// not a 1-pole low-pass whose corner merely shifts -- nodal analysis (see
// docs/audio-rtl-design.md) gives
//   H(s) = -(1/R33) * (2*C*s + 1/Z) / (C^2*s^2 + (2*C/R35)*s + 1/(R35*Z))
// where Z = R31 + (R32 || Tr1's Rce) is the shunt impedance at the C32/C33
// midpoint. This has a genuine RESONANT PEAK whose frequency depends on Z:
// ~1.8 kHz when Tr1 is off (Z=1.6K) sweeping up to ~7.3 kHz when Tr1
// saturates (Z=148R) -- a whistle that sweeps DOWN as the envelope decays
// and Tr1 desaturates, confirmed independently by measuring MAME's own
// fire.wav (a real descending sweep, ~4.3 kHz down to ~1.9 kHz, comfortably
// inside the range this transfer function predicts).
module fire_chan (
    input  logic               clk,
    input  logic               rst_n,
    input  logic               sample_ce,
    input  logic                fire_n,          // /FIRE, active low, falling edge triggers
    input  logic signed [15:0] noise_a,
    output logic signed [15:0] fire_mix,        // 4096 LSB = 1V

    // Shared-multiplier client.  FIRE submits one operation at a time; the
    // deterministic sequence below completes well inside one 832-clock audio
    // sample interval and commits its recursive state on the next sample_ce.
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

    // ---------------------------------------------------------------
    // Filter-state fixed point: 4096*256 = 1,048,576 LSB/V, same convention
    // as alarm_chan's high-pass state (state widths vary per signal below,
    // narrowed to 27 bits wherever DSP packing allows it -- see "DSP block
    // budget" in docs/audio-rtl-design.md). All Q0.16 coefficients below are
    // computed at clk_sys = 39,935,064 Hz and sample rate fs =
    // clk_sys/832 = 47,998.875 Hz.
    // (SCALE = 4096*256 = 1,048,576 LSB/V; folded directly into the
    // localparam constants below rather than kept as its own signal.)

    // ---------------------------------------------------------------
    // Stage 1: IC4 sec.2 74123 one-shot.
    // tw = 0.45 * R7(47K) * C4(1uF) = 21.15 ms
    // WIDTH_CYCLES = 0.02115 * 39,935,064 = 844,626.6 -> 844,627
    // ---------------------------------------------------------------
    logic q_oneshot;

    ttl_74123 #(.WIDTH_CYCLES(844627)) u_74123_fire (
        .clk    (clk),
        .rst_n  (rst_n),
        .a_n    (fire_n),
        .q      (q_oneshot)
    );

    // ---------------------------------------------------------------
    // Stage 2: envelope. One-pole toward VPEAK while gated (fast,
    // tau=1ms -- chosen only to be much faster than the 21.15ms gate, per
    // spec's "reaching it within the gate is correct"; the real charge
    // dynamics through D8/R6 are not otherwise documented). Decays with
    // tau=1.02s (R4 150K * C3 6.8uF) once the gate drops.
    //   a_charge = exp(-1/(fs*0.001))  = 0.97938 -> Q0.16 = 64185
    // env_next = a*env + (1-a)*target   (target = VPEAK while gated, 0 while decaying)
    //
    // VPEAK = 3.80 V, not 3.16 V. This was flagged as an open question in
    // docs/audio-rtl-design.md ("FIRE decays faster than the recording"):
    // fitting the schematic's 74123 V_OH less D8's drop gave 3.16 V, but our
    // decay reached -20dB 2.7x faster than MAME's fire.wav, and a real
    // cabinet recording (docs/reference/buckrog_cabinet_audio.wav) confirms
    // FIRE is audibly as loud as SHIP/EXP in practice, not the ~9-17dB-down
    // "thin, quiet laser" our old trace predicted. 3.16V happened to fit the
    // 3.5V knee-crossing point instead of the 3.1V one -- equally plausible
    // as a 74123 V_OH reading, and the doc's own alternate candidate is
    // 3.80V, fit against the 3.1V knee. This also explains the SHAPE
    // mismatch, not just the level: V2 = 5.475 - 0.839*Venv crosses the
    // MC3340's 3.1V knee (full gain below it) at a FIXED Venv = 2.83V
    // regardless of VPEAK, so raising VPEAK means Venv takes longer to decay
    // down to that crossing point -- the channel spends longer at full,
    // un-attenuated gain before attenuation starts ramping, i.e. a longer
    // flat plateau before the collapse, exactly the shape the recording
    // shows and the old VPEAK did not.
    //   a_charge = exp(-1/(fs*0.001))  = 0.97938 -> Q0.16 = 64185
    //
    // The DECAY pole must be carried in Q0.24, not Q0.16. Its ideal value is
    // exp(-1/(fs*1.02)) = 0.99997957, and Q0.16 cannot express it: 65535/65536
    // yields tau = 1.365 s (+34%) and 65534/65536 yields 0.68 s (-33%), with
    // the target falling between two adjacent codes. Eight more fractional
    // bits put the realised tau at 1.0191 s, 0.09% low.
    //   a_decay = 0.99997957 -> Q0.24 = 16776873
    // (The charge path keeps Q0.16: its pole is nowhere near unity, so it has
    // no precision problem, and its tau is a free choice anyway.)
    // ---------------------------------------------------------------
    // Declared at 27 bits, not 32: every value here fits in ~23 bits, and a
    // DSP-block multiplier is sized off the operand width Verilog presents
    // to `*`, not off the constant's magnitude -- see docs/audio-rtl-design.md,
    // "DSP block budget".
    localparam signed [26:0] VPEAK_SCALED = 27'sd3984589; // 3.80V * SCALE
    localparam signed [26:0] A_CHARGE = 27'sd64185;
    localparam signed [26:0] B_CHARGE = 27'sd1351;  // 65536 - A_CHARGE
    localparam signed [26:0] A_DECAY  = 27'sd16776873; // Q0.24; target 0, so (1-a)*target drops out

    logic signed [26:0] env;


    // ---------------------------------------------------------------
    // Stages 3-5: control leg (V2 -> VCA LUT) and filter leg (Tr1 conduction
    // -> IC12, now a genuine time-varying 2-pole resonant filter, see the
    // header note) in parallel, recombined at the output stage.
    //
    // TIMING-CLOSURE NOTE. As first written this whole tail -- both legs
    // plus the output multiplies -- was one combinational cloud between
    // sample_ce edges, the same pattern already found and fixed in
    // `ship_chan.sv` and `rebound_chan.sv` (see docs/audio-rtl-design.md,
    // "Real hardware sounded like static"). A real Quartus build of the
    // RTL with SHIP and REBOUND already pipelined reported FIRE as the new
    // worst `clk_sys` setup path (`env` register to `y_ic12` register,
    // -139 ns), confirming the pattern recurs per-channel and has to be
    // fixed per-channel. The filter leg also had a genuine RUNTIME DIVISION
    // (`frac_gc_num / VBE_RANGE_SCALED`) -- Quartus has no divider hardware,
    // so that synthesizes to a full iterative non-restoring divider, likely
    // the single largest contributor to this channel's depth. Fixed by
    // folding the divide-by-constant into a precomputed Q32 reciprocal
    // multiply (RECIP_FRAC_Q32 below; error is under 1 LSB of Q0.16 across
    // the whole domain, checked numerically).
    //
    // Fix, same discipline as SHIP/REBOUND: one multiply (or one cheap
    // compare/add/mux) per register-to-register hop, free-running on `clk`.
    // 832 clk_sys cycles exist per audio sample; this pipeline is about a
    // dozen deep, so the added latency is inaudible.
    // ---------------------------------------------------------------

    // Declared at 27 bits, not 32: every value here fits in ~23 bits (see
    // docs/audio-rtl-design.md, "DSP block budget"), EXCEPT RECIP_FRAC_Q32,
    // which is a genuine Q0.32 reciprocal and needs its full width for
    // precision -- narrowing it would defeat the point of using it in place
    // of a runtime divide.

    // V2 = 5.475 - 0.839*Venv. V2_CONST_SCALED = 5.475*SCALE = 5,740,954.
    // COEF_0839 (Q0.16) = 0.839*65536 = 54985.
    localparam signed [26:0] V2_CONST_SCALED = 27'sd5740954;
    localparam signed [26:0] COEF_0839       = 27'sd54985;

    // Clamp into the LUT's covered range [2.0V, 6.0V) before indexing.
    localparam signed [26:0] V2_MIN_SCALED = 27'sd2097152;      // 2.0V * SCALE
    localparam signed [26:0] V2_MAX_SCALED = 27'sd6291455;      // 6.0V * SCALE - 1

    // Tr1 conduction, piecewise on Vbe = Venv*0.1803.
    //   gc = 0                     Vbe <= 0.60
    //      = gsat*(Vbe-0.60)/0.15  0.60 < Vbe < 0.75
    //      = gsat                  Vbe >= 0.75
    // frac_gc (0..65536, Q0.16) is this fraction, still needed below -- not
    // to blend a one-pole coefficient anymore, but as the index into the
    // IC12 biquad coefficient LUT (see the header note's transfer function;
    // Z depends on Tr1's conductance, which is exactly what frac_gc tracks).
    localparam signed [26:0] VBE_COEF         = 27'sd11816;   // 0.1803 Q0.16
    localparam signed [26:0] VBE_LOW_SCALED   = 27'sd629146;  // 0.60V * SCALE
    localparam signed [26:0] VBE_RANGE_SCALED = 27'sd157286;  // 0.15V * SCALE
    // frac_gc = ((vbe_scaled-LOW) * 65536) / RANGE, folded into one Q32
    // reciprocal: RECIP_FRAC_Q32 = round(65536 * 2^32 / RANGE) = 1789574258.
    localparam signed [31:0] RECIP_FRAC_Q32 = 32'sd1789574258;

    // noise_a scaled up to the filter's internal scale (2^8 = 256x finer than
    // audio scale, matching every other channel's noise-fed filter).
    wire signed [26:0] noise_scaled = 27'({{16{noise_a[15]}}, noise_a} <<< 8);


    // ---------------------------------------------------------------
    // MC3340 VCA gain LUT: 65 points across V2 = 2.0 .. 6.0V, step 0.0625V.
    // The step was chosen so that, in the SCALE=1,048,576 LSB/V fixed point
    // above, 0.0625V * SCALE = 65536 exactly -- an index and Q0.16
    // interpolation fraction fall straight out of the low/high halves of
    // (v2_clamped - V2_MIN_SCALED) with no divide.
    //
    // Each entry is gain = 10^((13-A(V2))/20) from the piecewise A(V2) in
    // docs/audio-rtl-design.md, stored as a 16-fractional-bit fixed point
    // value (Q0.16 by fractional-bit count) but held in a 32-bit word
    // rather than the classic unsigned-16 container: the VCA's +13 dB peak
    // gain is 4.4668x, which needs integer bits a 16-bit unsigned Q0.16
    // doesn't have. The -77..-90 dB tail quantises to a handful of LSBs
    // (and eventually 0 at fs=47999Hz*Q0.16), inaudible and the accepted
    // floor per the design doc.
    // ---------------------------------------------------------------
    localparam int LUT_SIZE = 65;
    localparam logic [31:0] VCA_GAIN_LUT [0:LUT_SIZE-1] = '{
        32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739,
        32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739, 32'd292739,
        32'd292739, 32'd292739, 32'd253501, 32'd176901, 32'd123447, 32'd86145,  32'd60115,  32'd41950,
        32'd29274,  32'd21952,  32'd16462,  32'd12345,  32'd9257,   32'd6942,   32'd5206,   32'd3904,
        32'd2927,   32'd2195,   32'd1646,   32'd1234,   32'd926,    32'd694,    32'd521,    32'd390,
        32'd293,    32'd220,    32'd165,    32'd123,    32'd93,     32'd69,     32'd52,     32'd39,
        32'd29,     32'd25,     32'd22,     32'd19,     32'd16,     32'd14,     32'd12,     32'd11,
        32'd9,      32'd9,      32'd9,      32'd9,      32'd9,      32'd9,      32'd9,      32'd9,
        32'd9
    };

    // Return {gain_lo, gain_hi-gain_lo, frac}; interpolation itself is a
    // scheduled shared-lane operation, never a hidden inferred multiplier.
    function automatic logic [58:0] vca_lut_params(input logic signed [26:0] v2_in);
        logic signed [26:0] v2_clamped;
        logic [22:0] v2_off;
        logic [6:0]  lut_idx;
        logic [15:0] lut_frac;
        logic [31:0] gain_lo, gain_hi;
        logic signed [20:0] gain_base, gain_delta;
        begin
            v2_clamped = (v2_in < V2_MIN_SCALED) ? V2_MIN_SCALED :
                         (v2_in > V2_MAX_SCALED) ? V2_MAX_SCALED : v2_in;
            v2_off   = 23'(v2_clamped - V2_MIN_SCALED);   // 0 .. LUT_SIZE-1 in units of 65536
            lut_idx  = v2_off[22:16];           // 0 .. 63 (indices for interpolation)
            lut_frac = v2_off[15:0];            // Q0.16 fraction between idx and idx+1
            gain_lo  = VCA_GAIN_LUT[lut_idx];
            gain_hi  = VCA_GAIN_LUT[lut_idx + 7'd1];
            gain_base  = 21'($signed({1'b0, gain_lo}));
            gain_delta = 21'($signed({1'b0, gain_hi}) - $signed({1'b0, gain_lo}));
            vca_lut_params = {gain_base, gain_delta, 1'b0, lut_frac};
        end
    endfunction

    // ---------------------------------------------------------------
    // IC12 filter leg: a genuine time-varying 2-pole biquad, not a one-pole
    // blend -- see this file's header note for the transfer function and
    // why. Coefficients come from a 33-entry table, precomputed offline by
    // bilinear-transforming the nodal-analysis transfer function at 33
    // evenly-spaced points of Tr1's conductance (frac_gc = 0..65536), and
    // looked up with NO interpolation between entries -- same discipline as
    // HIT's DIS-network LUT (hit_chan.sv): frac_gc only changes once per
    // audio sample and moves smoothly as the envelope decays, so 33 discrete
    // steps track the sweep closely with zero interpolation multiplies.
    //
    // B1 is deliberately NOT stored. The transfer function's numerator has
    // a single zero (n1*s + n0), not a full 2-zero biquad numerator, and
    // bilinear-transforming that shape gives the exact identity B1 = B0+B2
    // (both share the same 2*n0/A0 term by construction). That turns the
    // FIR half of the biquad,
    //   B0*x[n] + B1*x[n-1] + B2*x[n-2],
    // into
    //   B0*(x[n]+x[n-1]) + B2*(x[n-1]+x[n-2]),
    // i.e. two cheap adds feeding two multiplies instead of three -- this
    // filter costs 4 real multiplies total (B0, B2, A1, A2), matching the
    // one-pole-blend implementation it replaces (no net DSP change).
    //
    // State widths: x1/x2 (input history) only ever hold noise_scaled's own
    // range and fit in 27 bits. y1/y2 (output history) do not -- a real
    // white-noise simulation of this filter at its highest-Q setting (Tr1
    // saturated) showed peaks over 30x the input amplitude from the
    // resonance, needing about 28 bits. Declared at 40 anyway: a Cyclone V
    // 27x27 DSP packs an operand in ceil(width/27) chunks, so 28-54 bits all
    // cost the SAME 2 chunks for the A1/A2 multiplies -- there's no reason
    // to cut this margin close when it's free, and it's the same 2-chunk
    // cost the old y_ic12-based recursion already paid (y_ic12 was declared
    // 32 bits) -- not a new cost this pass adds.
    // ---------------------------------------------------------------
    localparam int FILT_LUT_SIZE = 33;
    localparam logic signed [26:0] IC12_B0_LUT [0:FILT_LUT_SIZE-1] = '{
        -27'sd4376043, -27'sd5209363, -27'sd5939612, -27'sd6584799,
        -27'sd7158969, -27'sd7673235, -27'sd8136508, -27'sd8556014,
        -27'sd8937675, -27'sd9286391, -27'sd9606252, -27'sd9900697,
        -27'sd10172639, -27'sd10424563, -27'sd10658601, -27'sd10876593,
        -27'sd11080133, -27'sd11270614, -27'sd11449252, -27'sd11617119,
        -27'sd11775161, -27'sd11924215, -27'sd12065028, -27'sd12198264,
        -27'sd12324518, -27'sd12444326, -27'sd12558169, -27'sd12666482,
        -27'sd12769658, -27'sd12868053, -27'sd12961993, -27'sd13051774,
        -27'sd13137666
    };
    localparam logic signed [26:0] IC12_B2_LUT [0:FILT_LUT_SIZE-1] = '{
        27'sd2226671, 27'sd1319474, 27'sd524485, -27'sd177901,
        -27'sd802974, -27'sd1362832, -27'sd1867176, -27'sd2323873,
        -27'sd2739370, -27'sd3119002, -27'sd3467220, -27'sd3787768,
        -27'sd4083819, -27'sd4358078, -27'sd4612864, -27'sd4850182,
        -27'sd5071767, -27'sd5279135, -27'sd5473610, -27'sd5656359,
        -27'sd5828412, -27'sd5990681, -27'sd6143977, -27'sd6289025,
        -27'sd6426473, -27'sd6556902, -27'sd6680838, -27'sd6798753,
        -27'sd6911075, -27'sd7018194, -27'sd7120463, -27'sd7218203,
        -27'sd7311710
    };
    localparam logic signed [26:0] IC12_A1_LUT [0:FILT_LUT_SIZE-1] = '{
        -27'sd31234973, -27'sd30510046, -27'sd29874783, -27'sd29313518,
        -27'sd28814032, -27'sd28366658, -27'sd27963645, -27'sd27598705,
        -27'sd27266688, -27'sd26963331, -27'sd26685075, -27'sd26428930,
        -27'sd26192360, -27'sd25973205, -27'sd25769609, -27'sd25579972,
        -27'sd25402907, -27'sd25237203, -27'sd25081801, -27'sd24935769,
        -27'sd24798284, -27'sd24668618, -27'sd24546121, -27'sd24430216,
        -27'sd24320384, -27'sd24216159, -27'sd24117124, -27'sd24022900,
        -27'sd23933145, -27'sd23847548, -27'sd23765827, -27'sd23687724,
        -27'sd23613005
    };
    localparam logic signed [26:0] IC12_A2_LUT [0:FILT_LUT_SIZE-1] = '{
        27'sd15372383, 27'sd15388102, 27'sd15401876, 27'sd15414046,
        27'sd15424877, 27'sd15434577, 27'sd15443316, 27'sd15451229,
        27'sd15458428, 27'sd15465005, 27'sd15471039, 27'sd15476593,
        27'sd15481722, 27'sd15486474, 27'sd15490889, 27'sd15495001,
        27'sd15498840, 27'sd15502433, 27'sd15505803, 27'sd15508969,
        27'sd15511950, 27'sd15514762, 27'sd15517418, 27'sd15519931,
        27'sd15522313, 27'sd15524573, 27'sd15526720, 27'sd15528763,
        27'sd15530709, 27'sd15532565, 27'sd15534337, 27'sd15536031,
        27'sd15537651
    };

    // IC12 OUTPUT RAILS -- a real clipping mechanism, not a format guard,
    // same reasoning as every other op-amp stage in this design (SHIP/HIT/
    // EXP/LA4460's own RAIL_HI/RAIL_LO). IC12 is an LM324 like the rest of
    // this board, so it cannot leave roughly 0..10.5V, i.e. -6.00/+4.50V
    // referred to the 6V mid-rail -- see docs/audio-rtl-design.md, "Op-amp
    // output rails". Found necessary here specifically: at the resonant
    // peak (Tr1 saturated), this filter's real gain is high enough that its
    // output, carried through unchanged, would exceed the LM324's own rails
    // well before reaching the atten/VCA/output-gain stages -- a real board
    // clips right here, at IC12's output, not three stages later. Clamping
    // BEFORE the state capture (not just at the final mix) matters: a real
    // clipped op-amp output is what actually appears on the node feeding
    // back into IC12's own feedback network (R35/C32/C33), so the clipped
    // value, not the raw one, is what the NEXT sample's recursion must see.
    // Filter scale here is 2^20 LSB/V (4096*256, this file's own SCALE --
    // see the header note at the top of the module), NOT 2^24: an earlier
    // draft of this clamp used 2^24 by mistake, making it 16x too permissive
    // and letting the resonant peak blow straight through the 16-bit format
    // guard three stages later instead of clipping here, where it should.
    localparam signed [39:0] IC12_RAIL_HI = 40'sd4718592;   // +4.50V * 2^20
    localparam signed [39:0] IC12_RAIL_LO = -40'sd6291456;  // -6.00V * 2^20

    localparam signed [26:0] ATTEN_Q16    = 27'sd6495;   // 0.0991 * 65536
    localparam signed [26:0] OUT_GAIN_Q16 = -27'sd144179; // -2.2 * 65536
    // FIRE has fourteen sample-rate products.  At three clocks per native
    // 27-bit multiply (four for the 40-bit feedback terms), the sequence is
    // comfortably below the 832 clocks between sample_ce pulses.  Start
    // after a short settle window and commit work atomically on the next CE.
    localparam logic [7:0] TAG_FIRE_BASE = 8'hC0;
    logic [3:0] op_index;
    logic waiting_response, next_valid;
    logic [6:0] settle_count;
    logic signed [26:0] ic12_x1, ic12_x2;
    logic signed [39:0] ic12_y1, ic12_y2;
    logic signed [26:0] vbe_work;
    logic signed [20:0] gain_base, gain_delta, gain_work;
    logic signed [16:0] gain_frac;
    logic [5:0] filt_idx_work;
    logic signed [127:0] b0_work, b2_work, a1_work;
    logic signed [39:0] ic12_y_work;
    logic signed [53:0] env_charge_a;
    logic signed [26:0] env_charge_work, env_decay_work;
    logic signed [15:0] fire_sample;

    wire signed [26:0] ic12_u1 = 27'(noise_scaled + ic12_x1);
    wire signed [26:0] ic12_u2 = 27'(ic12_x1 + ic12_x2);
    wire signed [127:0] filter_sum = b0_work + b2_work - a1_work - mul_rsp_product;
    wire signed [127:0] filter_scaled = filter_sum >>> 24;
    wire signed [31:0] rsp_q16_32 = 32'(mul_rsp_product >>> 16);
    wire signed [20:0] rsp_gain_q16 = 21'(mul_rsp_product >>> 16);
    wire signed [26:0] rsp_env_q16 = 27'(mul_rsp_product >>> 16);
    wire signed [26:0] rsp_env_q24 = 27'(mul_rsp_product >>> 24);
    // Quartus 17 cannot elaborate a part-select directly on a function-call
    // result. Keep the full typed result on a named wire, exactly as EXP does.
    wire signed [26:0] v2_from_env = 27'(V2_CONST_SCALED - rsp_env_q16);
    wire        [58:0] vca_params_from_env = vca_lut_params(v2_from_env);
    wire signed [31:0] mix_full = rsp_q16_32 >>> 8;
    wire signed [15:0] mix_sat =
        (mix_full > 32'sd32767) ? 16'sd32767 :
        (mix_full < -32'sd32768) ? 16'sh8000 : mix_full[15:0];

    task automatic issue_multiply(
        input logic signed [63:0] a, input logic signed [63:0] b,
        input logic [6:0] aw, input logic [6:0] bw, input logic [7:0] tag
    );
        begin
            mul_req_a <= a; mul_req_b <= b;
            mul_req_a_width <= aw; mul_req_b_width <= bw;
            mul_req_tag <= tag; mul_req_valid <= 1'b1;
        end
    endtask

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            env <= '0; ic12_x1 <= '0; ic12_x2 <= '0; ic12_y1 <= '0; ic12_y2 <= '0;
            // Prime the first snapshot after reset too.  The legacy
            // free-running pipeline had already derived its first next-state
            // before the first sample_ce; starting at zero here would defer
            // that update by one complete audio sample forever.
            op_index <= '0; waiting_response <= 1'b0; next_valid <= 1'b0; settle_count <= 7'd64;
            vbe_work <= '0; gain_base <= '0; gain_delta <= '0; gain_frac <= '0; gain_work <= '0;
            filt_idx_work <= '0; b0_work <= '0; b2_work <= '0; a1_work <= '0; ic12_y_work <= '0;
            env_charge_a <= '0; env_charge_work <= '0; env_decay_work <= '0;
            fire_sample <= '0; fire_mix <= '0;
            mul_req_valid <= 1'b0; mul_req_a <= '0; mul_req_b <= '0;
            mul_req_a_width <= 7'd1; mul_req_b_width <= 7'd1; mul_req_tag <= '0;
        end else begin
            fire_mix <= fire_sample;
            if (mul_req_valid && mul_req_ready) begin
                mul_req_valid <= 1'b0;
                waiting_response <= 1'b1;
            end
            if (sample_ce) begin
                settle_count <= 7'd64;
                if (next_valid) begin
                    env <= q_oneshot ? env_charge_work : env_decay_work;
                    ic12_x2 <= ic12_x1; ic12_x1 <= noise_scaled;
                    ic12_y2 <= ic12_y1; ic12_y1 <= ic12_y_work;
                    next_valid <= 1'b0;
                end
            end else if (settle_count != 0) begin
                settle_count <= settle_count - 1'b1;
            end
            if (!mul_req_valid && !waiting_response && settle_count == 7'd1) begin
                op_index <= 4'd0;
                issue_multiply(64'(COEF_0839), 64'(env), 7'd27, 7'd27, TAG_FIRE_BASE);
            end
            if (mul_rsp_valid && waiting_response) begin
                waiting_response <= 1'b0;
                case (op_index)
                    4'd0: begin
                        gain_base <= vca_params_from_env[58:38];
                        gain_delta <= vca_params_from_env[37:17];
                        gain_frac <= vca_params_from_env[16:0];
                        op_index <= 4'd1; issue_multiply(64'(VBE_COEF),64'(env),7'd27,7'd27,TAG_FIRE_BASE+8'd1);
                    end
                    4'd1: begin vbe_work <= rsp_env_q16; op_index <= 4'd2; issue_multiply(64'(rsp_env_q16-VBE_LOW_SCALED),64'(RECIP_FRAC_Q32),7'd27,7'd32,TAG_FIRE_BASE+8'd2); end
                    4'd2: begin
                        filt_idx_work <= (vbe_work <= VBE_LOW_SCALED) ? 6'd0 :
                                         (vbe_work >= VBE_LOW_SCALED+VBE_RANGE_SCALED) ? 6'd32 : 6'(mul_rsp_product >>> 43);
                        op_index <= 4'd3; issue_multiply(64'(gain_delta),64'(gain_frac),7'd21,7'd17,TAG_FIRE_BASE+8'd3);
                    end
                    4'd3: begin gain_work <= gain_base + rsp_gain_q16; op_index <= 4'd4; issue_multiply(64'(IC12_B0_LUT[filt_idx_work]),64'(ic12_u1),7'd27,7'd27,TAG_FIRE_BASE+8'd4); end
                    4'd4: begin b0_work <= mul_rsp_product; op_index <= 4'd5; issue_multiply(64'(IC12_B2_LUT[filt_idx_work]),64'(ic12_u2),7'd27,7'd27,TAG_FIRE_BASE+8'd5); end
                    4'd5: begin b2_work <= mul_rsp_product; op_index <= 4'd6; issue_multiply(64'(IC12_A1_LUT[filt_idx_work]),64'(ic12_y1),7'd27,7'd40,TAG_FIRE_BASE+8'd6); end
                    4'd6: begin a1_work <= mul_rsp_product; op_index <= 4'd7; issue_multiply(64'(IC12_A2_LUT[filt_idx_work]),64'(ic12_y2),7'd27,7'd40,TAG_FIRE_BASE+8'd7); end
                    4'd7: begin
                        ic12_y_work <= (filter_scaled > 128'(IC12_RAIL_HI)) ? IC12_RAIL_HI : (filter_scaled < 128'(IC12_RAIL_LO)) ? IC12_RAIL_LO : 40'(filter_scaled);
                        op_index <= 4'd8; issue_multiply(64'(ATTEN_Q16),64'(ic12_y1),7'd27,7'd40,TAG_FIRE_BASE+8'd8);
                    end
                    4'd8: begin op_index <= 4'd9; issue_multiply(64'(rsp_q16_32),64'(gain_work),7'd32,7'd21,TAG_FIRE_BASE+8'd9); end
                    4'd9: begin op_index <= 4'd10; issue_multiply(64'(OUT_GAIN_Q16),64'(rsp_q16_32),7'd27,7'd32,TAG_FIRE_BASE+8'd10); end
                    4'd10: begin fire_sample <= mix_sat; op_index <= 4'd11; issue_multiply(64'(A_CHARGE),64'(env),7'd27,7'd27,TAG_FIRE_BASE+8'd11); end
                    4'd11: begin env_charge_a <= 54'(mul_rsp_product); op_index <= 4'd12; issue_multiply(64'(B_CHARGE),64'(VPEAK_SCALED),7'd27,7'd27,TAG_FIRE_BASE+8'd12); end
                    4'd12: begin env_charge_work <= 27'((env_charge_a + 54'(mul_rsp_product)) >>> 16); op_index <= 4'd13; issue_multiply(64'(A_DECAY),64'(env),7'd27,7'd27,TAG_FIRE_BASE+8'd13); end
                    default: begin env_decay_work <= rsp_env_q24; next_valid <= 1'b1; end
                endcase
            end
        end
    end

`ifdef VERILATOR_SIM
    always_ff @(posedge clk) begin
        if (rst_n && mul_rsp_valid && waiting_response && (mul_rsp_tag != TAG_FIRE_BASE + 8'(op_index)))
            $error("FIRE shared-multiply tag mismatch");
        if (rst_n && sample_ce && (mul_req_valid || waiting_response))
            $error("FIRE shared multiply missed sample deadline");
    end
`endif

endmodule
