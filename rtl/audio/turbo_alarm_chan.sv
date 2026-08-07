// Turbo ALARM channel (D-2/11): IC48 555 astable -> IC43 393 ripple divider
// -> IC46/IC53 74123 retriggerable monostables (one per /Trig1-4) -> IC47
// 74LS38 open-collector wire-OR node -> 5.1K/4.7uF one-pole high-pass ->
// IC33-A follower -> IC33-B gain stage -> ALARM.M/F/R/L (one common node;
// all four are the same signal through separate 4.7uF coupling caps, so
// this module produces one tap, same convention as Buck's alarm_chan.sv).
//
// D-2/11's own speedmeter half (SPEED0-3 -> IC33-C -> CN3 "Speed Meter Out")
// is NOT built here: docs/hardware-turbo.md's Step 2 ledger confirms it is a
// cabinet gauge output, not audio (no wire from that ladder reaches any
// mixer input).
//
// STRUCTURAL REUSE, JUSTIFIED BY COMPONENT IDENTITY (not assumed): the
// wire-OR node's own pull-up (1K), the following series resistor (5.1K),
// the AC-coupling cap (4.7uF), and the IC33-A follower's bias divider
// (10K/10K from 12V, i.e. a 6V Thevenin with 5K source impedance) are
// numerically IDENTICAL to Buck Rogers' own R153/R154/C88 and R155/R156
// (docs/hardware-audio.md's ALARM section, alarm_chan.sv's header/reset
// derivation) -- confirmed by directly comparing docs/trace/
// turbo_audio_D2of11.md's section 4 against alarm_chan.sv's own reset-value
// comments, not by assuming the two boards share a design. Because of that
// identity, this module reuses alarm_chan.sv's X_LOW/X_SPAN/X_IDLE/X_SIXV/
// A_COEF constants and its 833-entry X_LEVEL_LUT verbatim: they describe the
// SAME physical front-end circuit, not a borrowed approximation.
//
// WHERE TURBO GENUINELY DIFFERS from Buck's alarm chain, and this module
// diverges accordingly:
//   1. IC48's 555 timing (R=470/120 ohm, C=0.1uF) differs from Buck's
//      IC15A (R=470/270 ohm, C=0.1uF) -- different T_HIGH/T_LOW below.
//   2. The four monostables' Rext/Cext values differ (see WIDTH_CYCLES),
//      giving 15.5/155/512/155 ms one-shot widths instead of Buck's
//      144/144/144/211 ms -- docs/hardware-turbo.md Item (a), confirmed by
//      direct high-DPI re-read, not just the dead MAME netlist.
//   3. The counter-tap-to-trigger gating (D-2/11's own trace, section 5, and
//      the ledger's corroboration against the dead netlist) assigns
//      TRIG1->2QA(/32), TRIG2->1QD(/16), TRIG3->1QC(/8), TRIG4->1QB(/4) --
//      the SAME bit positions Buck's ALARM0-3 use, so the divider/gating
//      code is structurally identical to alarm_chan.sv's; only the trigger
//      NAMES differ.
//   4. IC33-B's own gain stage differs from Buck's IC25: Turbo uses a 22K
//      input resistor into a feedback network that is R225 (1K) IN PARALLEL
//      WITH VR2, a 20K TRIMMER whose wiper position the schematic does not
//      state. R225 alone would give -1K/22K = -1/22 (~-0.045x); VR2 in
//      parallel can only pull that gain toward zero, never above it. THIS
//      IS AN OPEN ITEM, not resolved by the ledger. Modelled here as a
//      fixed -1/16 (a single right-shift, zero DSP cost) as a documented
//      INFERRED placeholder -- picked as a clean power-of-two near the
//      R225-alone bound, not derived from a known trim setting. If VR2's
//      real setting is ever established (e.g. from a board photo or a
//      cabinet recording level-match), replace GAIN_SHIFT below; nothing
//      else in this module depends on its value. This is the same category
//      of open calibration Buck's own la4460.sv already carries for VR1.
module turbo_alarm_chan (
    input  logic               clk,
    input  logic               rst_n,
    input  logic         [3:0] trig_n,     // bit0=/Trig1 ... bit3=/Trig4, active low
    input  logic                sample_ce,  // 1 clk high every 832 clks
    output logic signed [15:0] turbo_alarm_mix, // 4096 LSB = 1V, updates on sample_ce
    output logic                node         // wire-OR node bit, for debug
);

    // ---------------------------------------------------------------
    // Stage 1: IC48 555 astable. R=470 ohm (5V->pin7/8), R=120 ohm
    // (pin7->THR/TRG node), C=0.1uF -- docs/trace/turbo_audio_D2of11.md
    // section 3/4. Read as a standard Ra/Rb astable (Ra=470, Rb=120), the
    // same reduction the Phase 4 ledger and the dead MAME netlist both use:
    // T_high = 0.693*(Ra+Rb)*C = 40.887 us -> 1633 clk_sys cycles
    // T_low  = 0.693*Rb*C      =  8.316 us ->  332 clk_sys cycles
    // (clk_sys = 39,935,064 Hz, matching sim/audio_tb.cpp's CLK_HZ and
    // audio_top.sv's clk_sys/832 = 47,999.4 Hz sample-rate derivation.)
    // f = 1/(T_high+T_low) = 20,324 Hz, matching the ledger's ~20.3 kHz.
    // ---------------------------------------------------------------
    logic tone555;

    ttl_555_astable #(
        .T_HIGH (1633),
        .T_LOW  (332)
    ) u_555 (
        .clk    (clk),
        .rst_n  (rst_n),
        .out    (tone555)
    );

    // ---------------------------------------------------------------
    // Stage 2: IC43 393 ripple divider, falling-edge triggered, never
    // reset after power-on (1CL/2CL grounded, per the trace). Same
    // single-counter reduction as Buck's IC16 (alarm_chan.sv): a
    // falling-edge-clocked ripple counter's stage N is bit N of a plain
    // binary counter clocked on the same edges. Taps, per the ledger's
    // Item (a)/section-5 mapping (corroborated by the dead netlist):
    // 1QB=bit1(/4)->TRIG4  1QC=bit2(/8)->TRIG3  1QD=bit3(/16)->TRIG2
    // 2QA=bit4(/32)->TRIG1
    // ---------------------------------------------------------------
    logic tone555_d;
    wire  div_edge = tone555_d && !tone555; // falling edge

    logic [4:0] div_cnt;

    wire tap_1QB = div_cnt[1];
    wire tap_1QC = div_cnt[2];
    wire tap_1QD = div_cnt[3];
    wire tap_2QA = div_cnt[4];

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            tone555_d <= 1'b1;
            div_cnt   <= '0;
        end else begin
            tone555_d <= tone555;
            if (div_edge)
                div_cnt <= div_cnt + 1'b1;
        end
    end

    // ---------------------------------------------------------------
    // Stage 3: four retriggerable 74123 monostables, one per /Trig(n).
    // WIDTH_CYCLES = round(T_seconds * 39,935,064):
    //   Trig1 (R296=47k, C138=1uF):  15.5 ms -> 618,993
    //   Trig2 (R316=47k, C141=10uF): 155  ms -> 6,189,935
    //   Trig3 (R328=47k, C151=33uF): 512  ms -> 20,446,753
    //   Trig4 (R315=47k, C142=10uF): 155  ms -> 6,189,935
    // Every one of these periods is CONFIRMED (docs/hardware-turbo.md's
    // Item (a): 47k re-read directly at high DPI, not INFERRED from the
    // dead netlist alone).
    // ---------------------------------------------------------------
    logic q1, q2, q3, q4;

    ttl_74123 #(.WIDTH_CYCLES(618993))    u_74123_trig1 (.clk(clk), .rst_n(rst_n), .a_n(trig_n[0]), .q(q1));
    ttl_74123 #(.WIDTH_CYCLES(6189935))   u_74123_trig2 (.clk(clk), .rst_n(rst_n), .a_n(trig_n[1]), .q(q2));
    ttl_74123 #(.WIDTH_CYCLES(20446753))  u_74123_trig3 (.clk(clk), .rst_n(rst_n), .a_n(trig_n[2]), .q(q3));
    ttl_74123 #(.WIDTH_CYCLES(6189935))   u_74123_trig4 (.clk(clk), .rst_n(rst_n), .a_n(trig_n[3]), .q(q4));

    // ---------------------------------------------------------------
    // Stage 4: IC47 74LS38 open-collector wire-OR node.
    // TRIG1->2QA(/32) TRIG2->1QD(/16) TRIG3->1QC(/8) TRIG4->1QB(/4)
    // ---------------------------------------------------------------
    assign node = ~((q1 & tap_2QA) | (q2 & tap_1QD) | (q3 & tap_1QC) | (q4 & tap_1QB));

    // ---------------------------------------------------------------
    // Decimator: box-average `node` over all 832 clk_sys cycles of one
    // audio sample. Same deliberate deviation from the schematic as
    // alarm_chan.sv (the real circuit has no anti-alias filter here).
    // ---------------------------------------------------------------
    logic [9:0] acc; // 0..832

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc <= '0;
        end else if (sample_ce) begin
            acc <= {9'd0, node};
        end else begin
            acc <= acc + {9'd0, node};
        end
    end

    // ---------------------------------------------------------------
    // Stage 5: analog tail. Front-end constants (X_LOW/X_SPAN/X_IDLE/
    // X_SIXV/A_COEF, and the X_LEVEL_LUT table) are reused VERBATIM from
    // alarm_chan.sv -- see this file's header for why that is justified by
    // component identity, not assumed. Only the final gain stage (last two
    // lines below) differs from Buck's -2x: see the header's item 4 for
    // why -1/16 is used and why it is an open calibration item.
    //
    // x[n] = 506 + ((9226-506) * acc) / 832
    // y[n] = (a * (y[n-1] + x[n] - x[n-1])) >>> 16   (s32 state, a=65510 Q0.16)
    // turbo_alarm_mix = -(y[n] >>> 16) >>> 4, saturated to s16
    //
    // Same pipelining/latency discipline as alarm_chan.sv, for the same
    // reason (a real Quartus build already forced this shape once for
    // Buck's alarm tail -- see alarm_chan.sv's own header for the timing
    // failure this avoids).
    // ---------------------------------------------------------------
    localparam signed [31:0] X_LOW  = 32'sd506;
    localparam signed [31:0] X_SPAN = 32'sd9226 - 32'sd506; // 8720
    localparam signed [31:0] X_IDLE = X_LOW + X_SPAN;
    localparam signed [31:0] X_SIXV = 32'sd11071;  // 6 V * (5/11.1) * 4096

    localparam signed [31:0] X_SCALED_RESET = X_IDLE <<< 16;
    localparam signed [31:0] Y_STATE_RESET  = (X_IDLE - X_SIXV) <<< 16;
    // A_COEF is 65510 = 65536 - 26 (see alarm_chan.sv). Same shift/add
    // decomposition, reused because the front-end this pole models is
    // component-identical to Buck's, per the header note above.
    localparam signed [63:0] Y_STATE_RESET_64 = $signed({{32{Y_STATE_RESET[31]}}, Y_STATE_RESET});
    localparam signed [63:0] HP_TIMES_26_RESET = (Y_STATE_RESET_64 <<< 4) +
                                                  (Y_STATE_RESET_64 <<< 3) +
                                                  (Y_STATE_RESET_64 <<< 1);
    localparam signed [63:0] HP_PROD_RESET  = (Y_STATE_RESET_64 <<< 16) -
                                               HP_TIMES_26_RESET + 64'sd32768;
    localparam signed [31:0] Y_NEXT_RESET   = 32'(HP_PROD_RESET >>> 16);

    logic signed [31:0] x_scaled_d;   // previous x<<16, s32 4096*65536 LSB/V
    logic signed [31:0] y_state;      // s32 filter state, same scale

    localparam [9:0] ACC_IDLE = 10'd832;
    logic [9:0] acc_latched;

    // X_LOW + (X_SPAN * i) / 832 for i = 0..832 -- IDENTICAL table to
    // alarm_chan.sv's X_LEVEL_LUT (same front-end component values, see
    // header). Reused verbatim rather than retyped.
    localparam logic signed [15:0] X_LEVEL_LUT [0:832] = '{
        16'sd506, 16'sd516, 16'sd526, 16'sd537, 16'sd547, 16'sd558, 16'sd568, 16'sd579,
        16'sd589, 16'sd600, 16'sd610, 16'sd621, 16'sd631, 16'sd642, 16'sd652, 16'sd663,
        16'sd673, 16'sd684, 16'sd694, 16'sd705, 16'sd715, 16'sd726, 16'sd736, 16'sd747,
        16'sd757, 16'sd768, 16'sd778, 16'sd788, 16'sd799, 16'sd809, 16'sd820, 16'sd830,
        16'sd841, 16'sd851, 16'sd862, 16'sd872, 16'sd883, 16'sd893, 16'sd904, 16'sd914,
        16'sd925, 16'sd935, 16'sd946, 16'sd956, 16'sd967, 16'sd977, 16'sd988, 16'sd998,
        16'sd1009, 16'sd1019, 16'sd1030, 16'sd1040, 16'sd1051, 16'sd1061, 16'sd1071, 16'sd1082,
        16'sd1092, 16'sd1103, 16'sd1113, 16'sd1124, 16'sd1134, 16'sd1145, 16'sd1155, 16'sd1166,
        16'sd1176, 16'sd1187, 16'sd1197, 16'sd1208, 16'sd1218, 16'sd1229, 16'sd1239, 16'sd1250,
        16'sd1260, 16'sd1271, 16'sd1281, 16'sd1292, 16'sd1302, 16'sd1313, 16'sd1323, 16'sd1333,
        16'sd1344, 16'sd1354, 16'sd1365, 16'sd1375, 16'sd1386, 16'sd1396, 16'sd1407, 16'sd1417,
        16'sd1428, 16'sd1438, 16'sd1449, 16'sd1459, 16'sd1470, 16'sd1480, 16'sd1491, 16'sd1501,
        16'sd1512, 16'sd1522, 16'sd1533, 16'sd1543, 16'sd1554, 16'sd1564, 16'sd1575, 16'sd1585,
        16'sd1596, 16'sd1606, 16'sd1616, 16'sd1627, 16'sd1637, 16'sd1648, 16'sd1658, 16'sd1669,
        16'sd1679, 16'sd1690, 16'sd1700, 16'sd1711, 16'sd1721, 16'sd1732, 16'sd1742, 16'sd1753,
        16'sd1763, 16'sd1774, 16'sd1784, 16'sd1795, 16'sd1805, 16'sd1816, 16'sd1826, 16'sd1837,
        16'sd1847, 16'sd1858, 16'sd1868, 16'sd1878, 16'sd1889, 16'sd1899, 16'sd1910, 16'sd1920,
        16'sd1931, 16'sd1941, 16'sd1952, 16'sd1962, 16'sd1973, 16'sd1983, 16'sd1994, 16'sd2004,
        16'sd2015, 16'sd2025, 16'sd2036, 16'sd2046, 16'sd2057, 16'sd2067, 16'sd2078, 16'sd2088,
        16'sd2099, 16'sd2109, 16'sd2120, 16'sd2130, 16'sd2141, 16'sd2151, 16'sd2161, 16'sd2172,
        16'sd2182, 16'sd2193, 16'sd2203, 16'sd2214, 16'sd2224, 16'sd2235, 16'sd2245, 16'sd2256,
        16'sd2266, 16'sd2277, 16'sd2287, 16'sd2298, 16'sd2308, 16'sd2319, 16'sd2329, 16'sd2340,
        16'sd2350, 16'sd2361, 16'sd2371, 16'sd2382, 16'sd2392, 16'sd2403, 16'sd2413, 16'sd2423,
        16'sd2434, 16'sd2444, 16'sd2455, 16'sd2465, 16'sd2476, 16'sd2486, 16'sd2497, 16'sd2507,
        16'sd2518, 16'sd2528, 16'sd2539, 16'sd2549, 16'sd2560, 16'sd2570, 16'sd2581, 16'sd2591,
        16'sd2602, 16'sd2612, 16'sd2623, 16'sd2633, 16'sd2644, 16'sd2654, 16'sd2665, 16'sd2675,
        16'sd2686, 16'sd2696, 16'sd2706, 16'sd2717, 16'sd2727, 16'sd2738, 16'sd2748, 16'sd2759,
        16'sd2769, 16'sd2780, 16'sd2790, 16'sd2801, 16'sd2811, 16'sd2822, 16'sd2832, 16'sd2843,
        16'sd2853, 16'sd2864, 16'sd2874, 16'sd2885, 16'sd2895, 16'sd2906, 16'sd2916, 16'sd2927,
        16'sd2937, 16'sd2948, 16'sd2958, 16'sd2968, 16'sd2979, 16'sd2989, 16'sd3000, 16'sd3010,
        16'sd3021, 16'sd3031, 16'sd3042, 16'sd3052, 16'sd3063, 16'sd3073, 16'sd3084, 16'sd3094,
        16'sd3105, 16'sd3115, 16'sd3126, 16'sd3136, 16'sd3147, 16'sd3157, 16'sd3168, 16'sd3178,
        16'sd3189, 16'sd3199, 16'sd3210, 16'sd3220, 16'sd3231, 16'sd3241, 16'sd3251, 16'sd3262,
        16'sd3272, 16'sd3283, 16'sd3293, 16'sd3304, 16'sd3314, 16'sd3325, 16'sd3335, 16'sd3346,
        16'sd3356, 16'sd3367, 16'sd3377, 16'sd3388, 16'sd3398, 16'sd3409, 16'sd3419, 16'sd3430,
        16'sd3440, 16'sd3451, 16'sd3461, 16'sd3472, 16'sd3482, 16'sd3493, 16'sd3503, 16'sd3513,
        16'sd3524, 16'sd3534, 16'sd3545, 16'sd3555, 16'sd3566, 16'sd3576, 16'sd3587, 16'sd3597,
        16'sd3608, 16'sd3618, 16'sd3629, 16'sd3639, 16'sd3650, 16'sd3660, 16'sd3671, 16'sd3681,
        16'sd3692, 16'sd3702, 16'sd3713, 16'sd3723, 16'sd3734, 16'sd3744, 16'sd3755, 16'sd3765,
        16'sd3776, 16'sd3786, 16'sd3796, 16'sd3807, 16'sd3817, 16'sd3828, 16'sd3838, 16'sd3849,
        16'sd3859, 16'sd3870, 16'sd3880, 16'sd3891, 16'sd3901, 16'sd3912, 16'sd3922, 16'sd3933,
        16'sd3943, 16'sd3954, 16'sd3964, 16'sd3975, 16'sd3985, 16'sd3996, 16'sd4006, 16'sd4017,
        16'sd4027, 16'sd4038, 16'sd4048, 16'sd4058, 16'sd4069, 16'sd4079, 16'sd4090, 16'sd4100,
        16'sd4111, 16'sd4121, 16'sd4132, 16'sd4142, 16'sd4153, 16'sd4163, 16'sd4174, 16'sd4184,
        16'sd4195, 16'sd4205, 16'sd4216, 16'sd4226, 16'sd4237, 16'sd4247, 16'sd4258, 16'sd4268,
        16'sd4279, 16'sd4289, 16'sd4300, 16'sd4310, 16'sd4321, 16'sd4331, 16'sd4341, 16'sd4352,
        16'sd4362, 16'sd4373, 16'sd4383, 16'sd4394, 16'sd4404, 16'sd4415, 16'sd4425, 16'sd4436,
        16'sd4446, 16'sd4457, 16'sd4467, 16'sd4478, 16'sd4488, 16'sd4499, 16'sd4509, 16'sd4520,
        16'sd4530, 16'sd4541, 16'sd4551, 16'sd4562, 16'sd4572, 16'sd4583, 16'sd4593, 16'sd4603,
        16'sd4614, 16'sd4624, 16'sd4635, 16'sd4645, 16'sd4656, 16'sd4666, 16'sd4677, 16'sd4687,
        16'sd4698, 16'sd4708, 16'sd4719, 16'sd4729, 16'sd4740, 16'sd4750, 16'sd4761, 16'sd4771,
        16'sd4782, 16'sd4792, 16'sd4803, 16'sd4813, 16'sd4824, 16'sd4834, 16'sd4845, 16'sd4855,
        16'sd4866, 16'sd4876, 16'sd4886, 16'sd4897, 16'sd4907, 16'sd4918, 16'sd4928, 16'sd4939,
        16'sd4949, 16'sd4960, 16'sd4970, 16'sd4981, 16'sd4991, 16'sd5002, 16'sd5012, 16'sd5023,
        16'sd5033, 16'sd5044, 16'sd5054, 16'sd5065, 16'sd5075, 16'sd5086, 16'sd5096, 16'sd5107,
        16'sd5117, 16'sd5128, 16'sd5138, 16'sd5148, 16'sd5159, 16'sd5169, 16'sd5180, 16'sd5190,
        16'sd5201, 16'sd5211, 16'sd5222, 16'sd5232, 16'sd5243, 16'sd5253, 16'sd5264, 16'sd5274,
        16'sd5285, 16'sd5295, 16'sd5306, 16'sd5316, 16'sd5327, 16'sd5337, 16'sd5348, 16'sd5358,
        16'sd5369, 16'sd5379, 16'sd5390, 16'sd5400, 16'sd5411, 16'sd5421, 16'sd5431, 16'sd5442,
        16'sd5452, 16'sd5463, 16'sd5473, 16'sd5484, 16'sd5494, 16'sd5505, 16'sd5515, 16'sd5526,
        16'sd5536, 16'sd5547, 16'sd5557, 16'sd5568, 16'sd5578, 16'sd5589, 16'sd5599, 16'sd5610,
        16'sd5620, 16'sd5631, 16'sd5641, 16'sd5652, 16'sd5662, 16'sd5673, 16'sd5683, 16'sd5693,
        16'sd5704, 16'sd5714, 16'sd5725, 16'sd5735, 16'sd5746, 16'sd5756, 16'sd5767, 16'sd5777,
        16'sd5788, 16'sd5798, 16'sd5809, 16'sd5819, 16'sd5830, 16'sd5840, 16'sd5851, 16'sd5861,
        16'sd5872, 16'sd5882, 16'sd5893, 16'sd5903, 16'sd5914, 16'sd5924, 16'sd5935, 16'sd5945,
        16'sd5956, 16'sd5966, 16'sd5976, 16'sd5987, 16'sd5997, 16'sd6008, 16'sd6018, 16'sd6029,
        16'sd6039, 16'sd6050, 16'sd6060, 16'sd6071, 16'sd6081, 16'sd6092, 16'sd6102, 16'sd6113,
        16'sd6123, 16'sd6134, 16'sd6144, 16'sd6155, 16'sd6165, 16'sd6176, 16'sd6186, 16'sd6197,
        16'sd6207, 16'sd6218, 16'sd6228, 16'sd6238, 16'sd6249, 16'sd6259, 16'sd6270, 16'sd6280,
        16'sd6291, 16'sd6301, 16'sd6312, 16'sd6322, 16'sd6333, 16'sd6343, 16'sd6354, 16'sd6364,
        16'sd6375, 16'sd6385, 16'sd6396, 16'sd6406, 16'sd6417, 16'sd6427, 16'sd6438, 16'sd6448,
        16'sd6459, 16'sd6469, 16'sd6480, 16'sd6490, 16'sd6501, 16'sd6511, 16'sd6521, 16'sd6532,
        16'sd6542, 16'sd6553, 16'sd6563, 16'sd6574, 16'sd6584, 16'sd6595, 16'sd6605, 16'sd6616,
        16'sd6626, 16'sd6637, 16'sd6647, 16'sd6658, 16'sd6668, 16'sd6679, 16'sd6689, 16'sd6700,
        16'sd6710, 16'sd6721, 16'sd6731, 16'sd6742, 16'sd6752, 16'sd6763, 16'sd6773, 16'sd6783,
        16'sd6794, 16'sd6804, 16'sd6815, 16'sd6825, 16'sd6836, 16'sd6846, 16'sd6857, 16'sd6867,
        16'sd6878, 16'sd6888, 16'sd6899, 16'sd6909, 16'sd6920, 16'sd6930, 16'sd6941, 16'sd6951,
        16'sd6962, 16'sd6972, 16'sd6983, 16'sd6993, 16'sd7004, 16'sd7014, 16'sd7025, 16'sd7035,
        16'sd7046, 16'sd7056, 16'sd7066, 16'sd7077, 16'sd7087, 16'sd7098, 16'sd7108, 16'sd7119,
        16'sd7129, 16'sd7140, 16'sd7150, 16'sd7161, 16'sd7171, 16'sd7182, 16'sd7192, 16'sd7203,
        16'sd7213, 16'sd7224, 16'sd7234, 16'sd7245, 16'sd7255, 16'sd7266, 16'sd7276, 16'sd7287,
        16'sd7297, 16'sd7308, 16'sd7318, 16'sd7328, 16'sd7339, 16'sd7349, 16'sd7360, 16'sd7370,
        16'sd7381, 16'sd7391, 16'sd7402, 16'sd7412, 16'sd7423, 16'sd7433, 16'sd7444, 16'sd7454,
        16'sd7465, 16'sd7475, 16'sd7486, 16'sd7496, 16'sd7507, 16'sd7517, 16'sd7528, 16'sd7538,
        16'sd7549, 16'sd7559, 16'sd7570, 16'sd7580, 16'sd7591, 16'sd7601, 16'sd7611, 16'sd7622,
        16'sd7632, 16'sd7643, 16'sd7653, 16'sd7664, 16'sd7674, 16'sd7685, 16'sd7695, 16'sd7706,
        16'sd7716, 16'sd7727, 16'sd7737, 16'sd7748, 16'sd7758, 16'sd7769, 16'sd7779, 16'sd7790,
        16'sd7800, 16'sd7811, 16'sd7821, 16'sd7832, 16'sd7842, 16'sd7853, 16'sd7863, 16'sd7873,
        16'sd7884, 16'sd7894, 16'sd7905, 16'sd7915, 16'sd7926, 16'sd7936, 16'sd7947, 16'sd7957,
        16'sd7968, 16'sd7978, 16'sd7989, 16'sd7999, 16'sd8010, 16'sd8020, 16'sd8031, 16'sd8041,
        16'sd8052, 16'sd8062, 16'sd8073, 16'sd8083, 16'sd8094, 16'sd8104, 16'sd8115, 16'sd8125,
        16'sd8136, 16'sd8146, 16'sd8156, 16'sd8167, 16'sd8177, 16'sd8188, 16'sd8198, 16'sd8209,
        16'sd8219, 16'sd8230, 16'sd8240, 16'sd8251, 16'sd8261, 16'sd8272, 16'sd8282, 16'sd8293,
        16'sd8303, 16'sd8314, 16'sd8324, 16'sd8335, 16'sd8345, 16'sd8356, 16'sd8366, 16'sd8377,
        16'sd8387, 16'sd8398, 16'sd8408, 16'sd8418, 16'sd8429, 16'sd8439, 16'sd8450, 16'sd8460,
        16'sd8471, 16'sd8481, 16'sd8492, 16'sd8502, 16'sd8513, 16'sd8523, 16'sd8534, 16'sd8544,
        16'sd8555, 16'sd8565, 16'sd8576, 16'sd8586, 16'sd8597, 16'sd8607, 16'sd8618, 16'sd8628,
        16'sd8639, 16'sd8649, 16'sd8660, 16'sd8670, 16'sd8681, 16'sd8691, 16'sd8701, 16'sd8712,
        16'sd8722, 16'sd8733, 16'sd8743, 16'sd8754, 16'sd8764, 16'sd8775, 16'sd8785, 16'sd8796,
        16'sd8806, 16'sd8817, 16'sd8827, 16'sd8838, 16'sd8848, 16'sd8859, 16'sd8869, 16'sd8880,
        16'sd8890, 16'sd8901, 16'sd8911, 16'sd8922, 16'sd8932, 16'sd8943, 16'sd8953, 16'sd8963,
        16'sd8974, 16'sd8984, 16'sd8995, 16'sd9005, 16'sd9016, 16'sd9026, 16'sd9037, 16'sd9047,
        16'sd9058, 16'sd9068, 16'sd9079, 16'sd9089, 16'sd9100, 16'sd9110, 16'sd9121, 16'sd9131,
        16'sd9142, 16'sd9152, 16'sd9163, 16'sd9173, 16'sd9184, 16'sd9194, 16'sd9205, 16'sd9215,
        16'sd9226
    };

    wire signed [15:0] x_lut = X_LEVEL_LUT[acc_latched];

    logic signed [31:0] x_scaled_pA;

    always_ff @(posedge clk) begin
        if (!rst_n) x_scaled_pA <= X_SCALED_RESET;
        else        x_scaled_pA <= 32'(x_lut) <<< 16;
    end

    logic signed [31:0] hp_sum_pB;

    always_ff @(posedge clk) begin
        if (!rst_n) hp_sum_pB <= Y_STATE_RESET;
        else        hp_sum_pB <= y_state + x_scaled_pA - x_scaled_d;
    end

    logic signed [63:0] hp_prod_pC;
    wire signed [63:0] hp_sum_pB_64 = $signed({{32{hp_sum_pB[31]}}, hp_sum_pB});
    wire signed [63:0] hp_times_26 = (hp_sum_pB_64 <<< 4) +
                                      (hp_sum_pB_64 <<< 3) +
                                      (hp_sum_pB_64 <<< 1);
    wire signed [63:0] hp_prod_next = (hp_sum_pB_64 <<< 16) -
                                       hp_times_26 + 64'sd32768;

    always_ff @(posedge clk) begin
        if (!rst_n) hp_prod_pC <= HP_PROD_RESET;
        else        hp_prod_pC <= hp_prod_next;
    end

    logic signed [31:0] y_next_D;

    always_ff @(posedge clk) begin
        if (!rst_n) y_next_D <= Y_NEXT_RESET;
        else        y_next_D <= 32'(hp_prod_pC >>> 16);
    end

    // GAIN_SHIFT = 4 -> -1/16, the IC33-B placeholder gain (see header
    // item 4). Rounded to nearest before the final shift, same discipline
    // as alarm_chan.sv's own "+2" rounding term.
    localparam int GAIN_SHIFT = 4;
    wire signed [31:0] mix_full =
        -((32'(y_next_D + 32'sd32768) >>> 16) >>> GAIN_SHIFT);

    wire signed [15:0] mix_sat =
        (mix_full > 32'sd32767)  ? 16'sd32767  :
        (mix_full < -32'sd32768) ? 16'sh8000 :
        mix_full[15:0];

    always_ff @(posedge clk) begin
        if (!rst_n) turbo_alarm_mix <= 16'sd0;
        else        turbo_alarm_mix <= mix_sat;
    end

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            acc_latched <= ACC_IDLE;
            x_scaled_d  <= X_SCALED_RESET;
            y_state     <= Y_STATE_RESET;
        end else if (sample_ce) begin
            acc_latched <= acc;
            y_state     <= y_next_D;
            x_scaled_d  <= x_scaled_pA;
        end
    end

endmodule
