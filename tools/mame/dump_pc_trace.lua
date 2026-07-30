-- CPU/game-state divergence investigation (session 6 continuation): log the
-- main CPU's PC and cumulative executed cycles once per frame (register_
-- periodic runs on vblank, matching the point sim/tb_z80_3d.cpp's vblank_rise
-- fires -- see rtl/z80_3d.v's SIM_DEBUG_TRACE PCTRACE line, added for this
-- comparison), using the same coin/start schedule as sim/tb_z80_3d.cpp
-- (coin1 pulsed frames 90-99, start1 pulsed frames 150-159) so frame indices
-- line up directly with sim's PCTRACE frame=N pc=XXXX output.
--   mame.exe buckrogn -video none -sound none -autoboot_script dump_pc_trace.lua -str 8
local frames = 0
local coin_pulsed = false
local start_pulsed = false
local maincpu = manager.machine.devices[":maincpu"]
local pc_state = maincpu.state["PC"]
-- ISR flag bytes (0xf834/0xf835/0xf836, see rtl/z80_3d.v's ISRFLAGS probe --
-- sampled here once per frame too, at the same register_periodic point, for
-- a direct per-frame diff against sim's int_ack-instant sample).
local progspace = maincpu.spaces["program"]

emu.register_periodic(function()
	frames = frames + 1
	local ioport = manager.machine.ioport

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

	local f834 = progspace:read_u8(0xf834)
	local f835 = progspace:read_u8(0xf835)
	local f836 = progspace:read_u8(0xf836)
	print(string.format("PCTRACE frame=%d pc=%04x", frames, pc_state.value))
	print(string.format("ISRFLAGS frame=%d f834=%02x f835=%02x f836=%02x", frames, f834, f835, f836))

	if frames == 210 then
		manager.machine:exit()
	end
end)
