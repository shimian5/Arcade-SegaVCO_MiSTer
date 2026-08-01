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
    output logic signed [15:0] fire_mix         // 4096 LSB = 1V
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

    logic signed [26:0] env, env_next;

    wire signed [63:0] env_charge_sum = A_CHARGE * env + B_CHARGE * VPEAK_SCALED;
    wire signed [63:0] env_decay_sum  = A_DECAY * env;
    assign env_next = q_oneshot ? env_charge_sum[47:16] : env_decay_sum[55:24];

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

    // Pipe stage 0 (every clk): the three multiplies that only depend on the
    // env register / the live noise_a port are independent -- share a stage.
    logic signed [63:0] p0_v2_prod, p0_vbe_prod;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            p0_v2_prod      <= '0;
            p0_vbe_prod     <= '0;
        end else begin
            p0_v2_prod      <= COEF_0839 * env;
            p0_vbe_prod     <= VBE_COEF * env;
        end
    end

    // Pipe stage 1: shift/subtract down to working scale (cheap).
    logic signed [26:0] p1_v2_scaled, p1_vbe_scaled;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            p1_v2_scaled   <= '0;
            p1_vbe_scaled  <= '0;
        end else begin
            p1_v2_scaled   <= 27'(V2_CONST_SCALED - p0_v2_prod[47:16]);
            p1_vbe_scaled  <= 27'(p0_vbe_prod[47:16]);
        end
    end

    // Pipe stage 2: clamp V2 (cheap); the reciprocal multiply that replaces
    // the original runtime division.
    logic signed [26:0] p2_v2_clamped, p2_vbe_scaled;
    logic signed [63:0] p2_frac_prod;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            p2_v2_clamped  <= '0;
            p2_vbe_scaled  <= '0;
            p2_frac_prod   <= '0;
        end else begin
            p2_v2_clamped  <= (p1_v2_scaled < V2_MIN_SCALED) ? V2_MIN_SCALED :
                              (p1_v2_scaled > V2_MAX_SCALED) ? V2_MAX_SCALED :
                              p1_v2_scaled;
            p2_vbe_scaled  <= p1_vbe_scaled;
            p2_frac_prod   <= (p1_vbe_scaled - VBE_LOW_SCALED) * RECIP_FRAC_Q32;
        end
    end

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

    function automatic logic signed [31:0] vca_lut_lookup(input logic signed [31:0] v2_in);
        logic [31:0] v2_off;
        logic [6:0]  lut_idx;
        logic [15:0] lut_frac;
        logic [31:0] gain_lo, gain_hi;
        logic signed [63:0] gain_interp_prod;
        begin
            v2_off   = v2_in - V2_MIN_SCALED;   // 0 .. LUT_SIZE-1 in units of 65536
            lut_idx  = v2_off[22:16];           // 0 .. 63 (indices for interpolation)
            lut_frac = v2_off[15:0];            // Q0.16 fraction between idx and idx+1
            gain_lo  = VCA_GAIN_LUT[lut_idx];
            gain_hi  = VCA_GAIN_LUT[lut_idx + 7'd1];
            gain_interp_prod = ($signed({1'b0, gain_hi}) - $signed({1'b0, gain_lo})) * $signed({1'b0, lut_frac});
            vca_lut_lookup = 32'($signed({1'b0, gain_lo}) + gain_interp_prod[47:16]);
        end
    endfunction

    // Pipe stage 3: the VCA LUT lookup (1 mult, inside the function) and the
    // gc fraction's clamp (cheap mux, resolving the divide-replacement
    // multiply from stage 2) run in parallel.
    logic signed [31:0] p3_vca_gain, p3_frac_gc;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            p3_vca_gain <= '0;
            p3_frac_gc  <= '0;
        end else begin
            p3_vca_gain <= vca_lut_lookup(32'(p2_v2_clamped));
            p3_frac_gc  <= (p2_vbe_scaled <= VBE_LOW_SCALED) ? 32'sd0 :
                          (p2_vbe_scaled >= (VBE_LOW_SCALED + VBE_RANGE_SCALED)) ? 32'sd65536 :
                          32'(p2_frac_prod >>> 32);
        end
    end

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

    // frac_gc ranges 0..65536 (17-bit range); >>11 gives 0..32, a clean
    // index into the 33-entry tables above.
    wire [5:0] filt_idx = 6'(p3_frac_gc[16:11]);

    logic signed [26:0] ic12_x1, ic12_x2;
    logic signed [39:0] ic12_y1, ic12_y2;

    // Cheap adds exploiting the B1=B0+B2 identity above -- see the note.
    wire signed [26:0] ic12_u1 = 27'(noise_scaled + ic12_x1);
    wire signed [26:0] ic12_u2 = 27'(ic12_x1 + ic12_x2);

    // Pipe stage f0 (every clk): the filter's four independent products.
    logic signed [63:0] f0_b0u1_prod, f0_b2u2_prod, f0_a1y1_prod, f0_a2y2_prod;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            f0_b0u1_prod <= '0;
            f0_b2u2_prod <= '0;
            f0_a1y1_prod <= '0;
            f0_a2y2_prod <= '0;
        end else begin
            f0_b0u1_prod <= IC12_B0_LUT[filt_idx] * ic12_u1;
            f0_b2u2_prod <= IC12_B2_LUT[filt_idx] * ic12_u2;
            f0_a1y1_prod <= IC12_A1_LUT[filt_idx] * ic12_y1;
            f0_a2y2_prod <= IC12_A2_LUT[filt_idx] * ic12_y2;
        end
    end

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

    // Pipe stage f1: sum -> rail-clip -> ic12_y_next (cheap add + clamp).
    wire signed [39:0] ic12_y_raw = 40'((f0_b0u1_prod + f0_b2u2_prod - f0_a1y1_prod - f0_a2y2_prod) >>> 24);

    logic signed [39:0] ic12_y_next;

    always_ff @(posedge clk) begin
        if (!rst_n) ic12_y_next <= '0;
        else        ic12_y_next <= (ic12_y_raw > IC12_RAIL_HI) ? IC12_RAIL_HI :
                                    (ic12_y_raw < IC12_RAIL_LO) ? IC12_RAIL_LO :
                                    ic12_y_raw;
    end

    // Pipe stages 4-6: carry vca_gain forward to stage 7, where it meets the
    // atten multiply -- unrelated to the filter's own pipeline above, which
    // settles independently and is only read (via the stable ic12_y1
    // register) at sample_ce.
    logic signed [31:0] p4_vca_gain, p5_vca_gain, p6_vca_gain;

    always_ff @(posedge clk) begin
        if (!rst_n) p4_vca_gain <= '0;
        else        p4_vca_gain <= p3_vca_gain;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) p5_vca_gain <= '0;
        else        p5_vca_gain <= p4_vca_gain;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) p6_vca_gain <= '0;
        else        p6_vca_gain <= p5_vca_gain;
    end

    // Pipe stage 7: the output stage's input-attenuator multiply on the
    // CURRENT ic12_y1 register (independent of the filter pipeline above --
    // ic12_y1 only advances once per sample_ce, so both are reading the
    // same stable value for this whole 832-cycle window).
    localparam signed [26:0] ATTEN_Q16    = 27'sd6495;   // 0.0991 * 65536
    localparam signed [26:0] OUT_GAIN_Q16 = -27'sd144179; // -2.2 * 65536

    logic signed [63:0] p7_atten_prod;
    logic signed [31:0] p7_vca_gain;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            p7_atten_prod <= '0;
            p7_vca_gain   <= '0;
        end else begin
            p7_atten_prod <= ATTEN_Q16 * ic12_y1;
            p7_vca_gain   <= p6_vca_gain;
        end
    end

    // Pipe stage 8: input atten x VCA gain.
    //
    // NOTE: a Verilog bit-select like `signal[47:16]` is ALWAYS UNSIGNED,
    // even when `signal` itself is declared signed -- so it must be routed
    // through its own signed-declared wire before it can be widened (via a
    // width cast) or arithmetically shifted (`>>>`) correctly. Chaining
    // `64'(wide_signal[47:16])` or `wide_signal[47:16] >>> N` directly, as a
    // first draft of this rework did, zero-extends/logically-shifts what
    // should be a sign-extended/arithmetic operation -- turning small
    // negative filter values into huge positive ones and pinning FIRE at
    // the positive rail even at idle. Caught by instrumenting this module
    // and comparing against a hand trace; not visible from the RTL alone.

    wire signed [31:0] p7_atten = p7_atten_prod[47:16];

    logic signed [63:0] p8_vca_prod;

    always_ff @(posedge clk) begin
        if (!rst_n) p8_vca_prod <= '0;
        else        p8_vca_prod <= p7_atten * p7_vca_gain;
    end

    // Pipe stage 9: output gain.
    wire signed [31:0] p8_vca = p8_vca_prod[47:16];

    logic signed [63:0] p9_out_prod;

    always_ff @(posedge clk) begin
        if (!rst_n) p9_out_prod <= '0;
        else        p9_out_prod <= OUT_GAIN_Q16 * p8_vca;
    end

    wire signed [31:0] p9_out    = p9_out_prod[47:16];
    wire signed [31:0] mix_full  = p9_out >>> 8; // filter scale -> audio scale

    wire signed [15:0] mix_sat =
        (mix_full > 32'sd32767)  ? 16'sd32767  :
        (mix_full < -32'sd32768) ? -16'sd32768 :
        mix_full[15:0];

    // fire_mix free-runs on `clk` like the rest of this pipeline, same
    // reasoning as ship_mix/rebound_mix: by the time it is next read (the
    // following sample_ce, at least ~820 clk_sys cycles after this one given
    // the ~10-stage pipeline above) it has long since settled.
    always_ff @(posedge clk) begin
        if (!rst_n) fire_mix <= 16'sd0;
        else        fire_mix <= mix_sat;
    end

    // env / ic12_x1,x2,y1,y2 remain sample_ce-gated: they are the recursive
    // filter states themselves and must only advance once per audio sample.
    // The IC12 states all reset to 0 -- noise has no DC bias, so (like
    // HIT/EXP's identical noise-fed biquads) zero genuinely is the idle
    // state, no special reset-derivation needed the way ALARM's was.
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            env     <= 27'sd0;
            ic12_x1 <= 27'sd0;
            ic12_x2 <= 27'sd0;
            ic12_y1 <= 40'sd0;
            ic12_y2 <= 40'sd0;
        end else if (sample_ce) begin
            env     <= env_next;
            ic12_x2 <= ic12_x1;
            ic12_x1 <= noise_scaled;
            ic12_y2 <= ic12_y1;
            ic12_y1 <= ic12_y_next;
        end
    end

endmodule
