-- Dump attract + post-coin/start snapshots headless.
--   mame.exe buckrogn -video none -sound none -autoboot_script dump_frames.lua -str 8
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

	if frames == 400 then
		manager.machine.video:snapshot()
		manager.machine:exit()
	end
end)
