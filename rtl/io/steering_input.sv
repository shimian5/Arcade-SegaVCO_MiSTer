//============================================================================
//  steering_input -- combines MiSTer's three steering control schemes
//  (analog joystick, digital d-pad, spinner) into one free-running 8-bit
//  "virtual dial" position.
//
//  Ported from Arcade-SuperOffRoad_MiSTer/rtl/steering_input.sv for Turbo's
//  own free-spinning wheel (docs/WORKPLAN_TURBO_GRAPHICS.md Step 7):
//  turbo_state::analog_r() returns `m_dial->read() - m_last_analog`, i.e.
//  MAME's IPT_DIAL abstraction -- like Super Off-Road's wheel, only the
//  CHANGE between two reads ever matters, not an absolute angle, which is
//  exactly what a free-running mod-256 accumulator models.
//
//  RAMP_STEP/VEL_MAX/SHIFT/ANALOG_SHIFT made into parameters (defaults
//  reproduce the original SOR-tuned behavior exactly) so Turbo's instance
//  can be tuned independently -- MAME's turbo.cpp DIAL port carries
//  PORT_SENSITIVITY(50), i.e. real Turbo hardware/MAME already halves the
//  raw input before it reaches the game, which this port didn't reproduce.
//  ANALOG_SHIFT is split out from SHIFT so the analog stick's sensitivity
//  can be dialed down separately from the dpad ramp -- both were reported
//  far too twitchy in real play at the shared-SHIFT values. See
//  Arcade-SegaVCO.sv for Turbo's tuned instantiation.
//============================================================================

module steering_input #(
	parameter signed [8:0] RAMP_STEP    = 9'sd16, // per-frame velocity/deflection step
	parameter signed [8:0] VEL_MAX      = 9'sd16, // velocity-mode ramp ceiling
	parameter signed [8:0] POS_MAX      = 9'sd127,// position-mode deflection ceiling
	parameter integer       SHIFT       = 3,      // down-shift applied to dpad contribution before adding per-frame
	parameter integer       ANALOG_SHIFT = SHIFT  // down-shift applied to the analog-stick contribution; separate from SHIFT so stick sensitivity can be tuned independently of the dpad ramp
)
(
	input              clk_sys,
	input              reset,
	input              ce_frame,       // one-cycle pulse, once per video frame

	input              dpad_pos_mode,  // OSD: 0 = velocity ramp (default), 1 = position ramp w/ spring-return
	input  signed [7:0] analog_x,      // joystick_l_analog X, signed -128..127, 0 = centered
	input              dpad_left,
	input              dpad_right,
	input        [8:0] spinner,        // hps_io spinner_N: [8] = toggle (flips each update), [7:0] = signed delta

	output       [7:0] wheel_pos       // free-running accumulator -> the CPU-visible dial
);

	// Ramp rate: full accel/decel over ~8 frames (~0.13s @ 60Hz) at the
	// defaults -- responsive on a d-pad without feeling twitchy. Deflection/
	// velocity scaled down (>>>SHIFT) before being added per-frame so a held
	// d-pad or full analog deflection both reach a comparable top turn rate.

	reg signed [8:0] velocity; // velocity-mode ramp state
	reg signed [8:0] deflect;  // position-mode virtual stick deflection (spring-return)

	wire signed [8:0] dpad_dir = dpad_right ? 9'sd1 : (dpad_left ? -9'sd1 : 9'sd0);

	always @(posedge clk_sys) begin
		if (reset) begin
			velocity <= 9'sd0;
			deflect  <= 9'sd0;
		end else if (ce_frame) begin
			if (dpad_dir > 0)      velocity <= (velocity + RAMP_STEP > VEL_MAX) ? VEL_MAX : velocity + RAMP_STEP;
			else if (dpad_dir < 0) velocity <= (velocity - RAMP_STEP < -VEL_MAX) ? -VEL_MAX : velocity - RAMP_STEP;
			else if (velocity > 0) velocity <= (velocity - RAMP_STEP < 0) ? 9'sd0 : velocity - RAMP_STEP;
			else if (velocity < 0) velocity <= (velocity + RAMP_STEP > 0) ? 9'sd0 : velocity + RAMP_STEP;

			if (dpad_dir > 0)      deflect <= (deflect + RAMP_STEP > POS_MAX) ? POS_MAX : deflect + RAMP_STEP;
			else if (dpad_dir < 0) deflect <= (deflect - RAMP_STEP < -POS_MAX) ? -POS_MAX : deflect - RAMP_STEP;
			else if (deflect > 0)  deflect <= (deflect - RAMP_STEP < 0) ? 9'sd0 : deflect - RAMP_STEP;
			else if (deflect < 0)  deflect <= (deflect + RAMP_STEP > 0) ? 9'sd0 : deflect + RAMP_STEP;
		end
	end

	wire signed [8:0] dpad_contribution   = dpad_pos_mode ? (deflect >>> SHIFT) : (velocity >>> (SHIFT - 3));
	wire signed [8:0] analog_contribution = $signed({analog_x[7], analog_x}) >>> ANALOG_SHIFT;

	reg       spinner_toggle_d;
	reg [7:0] accum;

	// Mod-256 free-running add: correct wraparound "wheel" semantics whether
	// the byte being added is interpreted as signed or unsigned, so plain
	// 8-bit addition is used throughout (no need to sign-extend before adding).
	wire [7:0] spin_add = (spinner[8] != spinner_toggle_d) ? spinner[7:0] : 8'h00;
	wire [7:0] frame_add = ce_frame ? (dpad_contribution[7:0] + analog_contribution[7:0]) : 8'h00;

	always @(posedge clk_sys) begin
		if (reset) begin
			accum            <= 8'h00;
			spinner_toggle_d <= 1'b0;
		end else begin
			spinner_toggle_d <= spinner[8];
			accum            <= accum + spin_add + frame_add;
		end
	end

	assign wheel_pos = accum;

endmodule
