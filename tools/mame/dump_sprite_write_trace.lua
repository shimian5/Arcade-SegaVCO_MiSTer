-- Open thread #1 (docs/INVESTIGATION_title_logo_garbling.md): measure WHEN
-- (which vpos/hpos) MAME's buckrog_state CPU writes sprite RAM and
-- sprite-position RAM, for direct comparison against the equivalent RTL
-- trace (rtl/video/sprite_engine.v's VERILATOR_SIM dbg_wr_fh block, dumped
-- to sim/out/dbg_rtl_writes.txt by `make -C sim dump`).
--
-- Address ranges taken from docs/reference/turbo.cpp,
-- buckrog_state::main_prg_map (NOT turbo_v.cpp's turbo/subroc3d map, which
-- differs):
--   map(0xe000, 0xe3ff).ram().share(m_sprite_position);  -- CONT RAM (SPRPOS)
--   map(0xe400, 0xe7ff).ram().share(m_spriteram);        -- CONT RAM (SPRRAM)
-- These match rtl/video/sprite_engine.v's own comments (cpu_sprram e400-e7ff,
-- cpu_sprpos e000-e3ff) and rtl/z80_3d.v wires cpu_sprram_addr/cpu_sprpos_addr
-- to cpu_a[9:0]. NOTE: the tap's `offset` argument is the ABSOLUTE CPU address
-- (logged as e.g. `addr=e400`), not an offset relative to the tap range start,
-- so mask it with 0x3ff before comparing against the RTL log's addr field.
--
-- Same coin/start input schedule as dump_frames_logo.lua (coin1 pulsed
-- frames 90-99, start1 pulsed frames 150-159) so this lands on the SAME
-- title-logo frame as sim's `--dumpframe 150` -- see sim/tb_z80_3d.cpp's
-- comment: "matches tools/mame/dump_frames.lua's schedule exactly".
--
-- vpos/hpos: probed empirically (see tools/mame/reset_phase_capture.lua-style
-- scripts) that this MAME build's screen_device Lua binding has no vpos()/
-- hpos() methods; reconstruct from scr:time_until_pos(0,0) plus the cached
-- scan_period/pixel_period, exactly like reset_phase_capture.lua.
--
--   mame.exe buckrogn -video none -sound none -autoboot_script tools/mame/dump_sprite_write_trace.lua -str 8

-- !! CRITICAL, do not "clean this up" !!  The two tap objects returned by
-- install_write_tap MUST stay reachable from _G for the lifetime of the run.
-- If they are discarded (or held only in a local that the periodic closure
-- doesn't capture), Lua garbage-collects them and the taps SILENTLY STOP
-- FIRING -- no error, no warning, the log just ends. The first version of
-- this script discarded them and appeared to prove that MAME's CPU stops
-- writing sprite RAM after frame ~13, which is false: with the taps rooted
-- here, MAME writes ~160 times per frame, every frame, indefinitely. Always
-- check the "last frame a tap fired" line below before trusting a trace.
_G.KEPT_TAPS = {}

local f = io.open("dump_sprite_write_trace.log", "w")
local m = manager.machine

local scr = m.screens:at(1)
local FRAME_PERIOD = scr.frame_period
local SCAN_PERIOD  = scr.scan_period
local PIXEL_PERIOD = scr.pixel_period

local function beam_pos()
	local rem = scr:time_until_pos(0, 0)
	local elapsed = FRAME_PERIOD - rem
	if elapsed < 0 then elapsed = elapsed + FRAME_PERIOD end
	if elapsed >= FRAME_PERIOD then elapsed = elapsed - FRAME_PERIOD end
	local vpos = math.floor(elapsed / SCAN_PERIOD)
	local hpos = math.floor((elapsed - vpos * SCAN_PERIOD) / PIXEL_PERIOD)
	return vpos, hpos
end

local frames = 0
local coin_pulsed = false
local start_pulsed = false
local wr_count = 0
local last_tap_frame = -1
local done = false

local mdev = m.devices[":maincpu"]
local mprog = mdev and mdev.spaces["program"] or nil

f:write(string.format("maincpu program space=%s scan_period=%.9f pixel_period=%.9f frame_period=%.9f\n",
	tostring(mprog ~= nil), SCAN_PERIOD, PIXEL_PERIOD, FRAME_PERIOD))
f:flush()

if mprog then
	_G.KEPT_TAPS[1] = mprog:install_write_tap(0xe000, 0xe3ff, "sprpos_wr", function(offset, data, mask)
		local ok, err = pcall(function()
			local vpos, hpos = beam_pos()
			wr_count = wr_count + 1
			last_tap_frame = frames
			f:write(string.format("SPRPOS frame=%d vpos=%d hpos=%d addr=%03x data=%02x\n",
				frames, vpos, hpos, offset, data & 0xff))
		end)
		if not ok then f:write("LUA ERR sprpos tap " .. tostring(err) .. "\n") end
	end)

	_G.KEPT_TAPS[2] = mprog:install_write_tap(0xe400, 0xe7ff, "sprram_wr", function(offset, data, mask)
		local ok, err = pcall(function()
			local vpos, hpos = beam_pos()
			wr_count = wr_count + 1
			last_tap_frame = frames
			f:write(string.format("SPRRAM frame=%d vpos=%d hpos=%d addr=%03x data=%02x\n",
				frames, vpos, hpos, offset, data & 0xff))
		end)
		if not ok then f:write("LUA ERR sprram tap " .. tostring(err) .. "\n") end
	end)
else
	f:write("no maincpu program space -- taps not installed\n")
end
f:flush()

emu.register_periodic(function()
	if done then return end
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

	-- Same window as dump_frames_logo.lua, plus enough runway past 160 to
	-- capture the writes that program the logo frame's sprites.
	if frames >= 130 and frames <= 170 then
		manager.machine.video:snapshot()
	end

	if frames == 170 then
		done = true
		-- Validity check, not decoration: if last_tap_frame is far below
		-- total_frames the taps were collected mid-run and everything after
		-- that point is missing rather than absent. See the _G.KEPT_TAPS note.
		f:write(string.format("trace complete: total_frames=%d total_writes=%d last_tap_frame=%d\n",
			frames, wr_count, last_tap_frame))
		f:flush()
		f:close()
		manager.machine:exit()
	end
end)
