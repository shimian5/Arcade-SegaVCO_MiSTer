-- Dump attract + post-coin/start/throttle snapshots headless for Turbo.
--   mame.exe turbo -video none -sound none -autoboot_script dump_frames_turbo.lua -str 8
--
-- Turbo's coin/start (unlike buckrogn) live on IN0, not IN1
-- (docs/reference/turbo.cpp:653-661) -- IPT_START1/IPT_COIN1 default field
-- names are still "1 Player Start"/"Coin 1" (generic per-IPT names, not
-- overridden). Schedule mirrors sim/tb_z80_3d.cpp's default coin@90/
-- start@150/accel@200 so frame indices are directly comparable to the
-- Verilator --turbo --turbodump/--accelframe runs.
local frames = 0
local coin_pulsed = false
local start_pulsed = false

emu.register_periodic(function()
	frames = frames + 1
	local ioport = manager.machine.ioport

	if frames == 30 then
		manager.machine.video:snapshot()
	end

	if frames == 90 and not coin_pulsed then
		local coin1 = ioport.ports[":IN0"].fields["Coin 1"]
		if coin1 then coin1:set_value(0) end
		coin_pulsed = true
	end
	if frames == 100 then
		local coin1 = ioport.ports[":IN0"].fields["Coin 1"]
		if coin1 then coin1:set_value(1) end
	end

	if frames == 150 and not start_pulsed then
		local start1 = ioport.ports[":IN0"].fields["1 Player Start"]
		if start1 then start1:set_value(0) end
		start_pulsed = true
	end
	if frames == 160 then
		local start1 = ioport.ports[":IN0"].fields["1 Player Start"]
		if start1 then start1:set_value(1) end
	end

	-- Hold the pedal from frame 200 on, matching --accelframe 200 --
	-- PEDAL is a separate analog IPT_PEDAL port (turbo.cpp:731-732), not
	-- an IN0 bit; set it near max travel so pedal_r() reads the same
	-- near-full-throttle gray code the Verilator harness drives.
	if frames == 200 then
		local pedal = ioport.ports[":PEDAL"]
		if pedal then
			for name, field in pairs(pedal.fields) do
				field:set_value(0xC0)
			end
		end
	end

	if frames == 350 then
		manager.machine.video:snapshot()
	end
	if frames == 400 then
		manager.machine.video:snapshot()
	end
	if frames == 401 then
		manager.machine.video:snapshot()
		manager.machine:exit()
	end
end)
