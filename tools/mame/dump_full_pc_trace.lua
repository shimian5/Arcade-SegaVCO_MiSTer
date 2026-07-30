-- Phase 3 (CPU/game-state divergence): full per-instruction PC trace of the
-- main CPU, frames 1-48, to diff instruction-for-instruction against sim's
-- OPTRACE log (rtl/z80_3d.v, SIM_DEBUG_TRACE block). Unlike dump_pc_trace.lua
-- (one PC sample per frame at vblank), this uses the debugger's default
-- "trace" command (one line per instruction, "ADDR: disassembly") to match
-- the granularity of sim's main_m1_fetch_rise-driven OPTRACE.
--   mame.exe buckrogn -debug -video none -sound none -autoboot_script dump_full_pc_trace.lua
local dbg = manager.machine.debugger
local frames = 0

dbg:command("trace mame_full_trace.txt,maincpu,noloop")

emu.register_periodic(function()
	frames = frames + 1
	print(string.format("FRAME_MARK %d", frames))
	if frames == 49 then
		dbg:command("trace off")
		manager.machine:exit()
	end
end)
