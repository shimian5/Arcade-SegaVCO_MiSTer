-- Snapshot frames 60 and 155, matching sim/tb_z80_3d.cpp's own frame
-- numbering and coin/start schedule (coin1 pulsed 90-99, start1 pulsed
-- 150-159), so these are directly comparable to sim/out/buckrogn_060.ppm
-- and sim/out/buckrogn_155.ppm.
--   mame.exe buckrogn -video none -sound none -autoboot_script dump_frames_60_155.lua -str 8
local frames = 0
local coin_pulsed = false
local start_pulsed = false

emu.register_periodic(function()
	frames = frames + 1
	local ioport = manager.machine.ioport

	if frames == 60 then
		manager.machine.video:snapshot()
	end

	if frames == 90 and not coin_pulsed then
		local coin1 = ioport.ports[":IN1"].fields["Coin 1"]
		if coin1 then coin1:set_value(0) end
		coin_pulsed = true
	end
	if frames == 100 then
		local coin1 = ioport.ports[":IN1"].fields["Coin 1"]
		if coin1 then coin1:set_value(1) end
	end

	if frames == 150 and not start_pulsed then
		local start1 = ioport.ports[":IN1"].fields["1 Player Start"]
		if start1 then start1:set_value(0) end
		start_pulsed = true
	end
	if frames == 160 then
		local start1 = ioport.ports[":IN1"].fields["1 Player Start"]
		if start1 then start1:set_value(1) end
	end

	if frames == 155 then
		manager.machine.video:snapshot()
	end
	if frames == 156 then
		manager.machine:exit()
	end
end)
