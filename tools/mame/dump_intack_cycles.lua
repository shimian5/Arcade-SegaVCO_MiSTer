-- Phase 3 follow-up (session 7): measure absolute T-state-since-start at
-- which the main CPU accepts each of the first ~15 vblank interrupts.
-- Z80 clock: MASTER_CLOCK/4 = 4,992,000 Hz (docs/reference/turbo.cpp). No
-- wait states in this design, so T-states == machine.time(sec) * 4,992,000.
local maincpu = manager.machine.devices[":maincpu"]
local dbg = maincpu.debug
local pc_state = maincpu.state["PC"]

local hits = 0
local MAX_HITS = 15
local prev_pc = -1
local started = false

emu.register_periodic(function()
	if hits >= MAX_HITS then return end
	if not started then
		started = true
		print(string.format("FIRST_TICK time=%.9f pc=%04x", manager.machine.time:as_double(), pc_state.value))
	end
	local step_count = 0
	while hits < MAX_HITS and step_count < 100000 do
		dbg:step(1)
		step_count = step_count + 1
		local pc = pc_state.value
		if pc == 0x0038 and prev_pc ~= 0x0038 then
			hits = hits + 1
			local t = manager.machine.time:as_double()
			local tstate = math.floor(t * 4992000 + 0.5)
			print(string.format("MAME_INTACK_ABS_TSTATE hit=%d abs_tstate=%d time=%.9f", hits, tstate, t))
		end
		prev_pc = pc
	end
	if hits >= MAX_HITS then
		manager.machine:exit()
	end
end)
