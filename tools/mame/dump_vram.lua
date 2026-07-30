-- Dump buckrogn's fg tilemap VRAM + sprite RAM + sprite-position RAM at a
-- chosen frame, straight off the main CPU's program space.
--
--   mame.exe buckrogn -video none -sound none -skip_gameinfo \
--     -autoboot_script tools/mame/dump_vram.lua -str 4
--
-- Writes DUMP_PATH below. Used (2026-07-29) to settle "is the tunnel wall the
-- foreground tilemap or the sprite layer?" -- it is the tilemap: rows 6-23 of
-- the 32x32 grid hold the V-shaped tunnel (codes 0x90-0xcf on the flanks,
-- 0xe0 fill, 0x80 = sky). See docs/INVESTIGATION_title_logo_garbling.md.
--
-- FRAME 60 lands on the attract "GAME OVER / INSERT COIN" screen, which is the
-- state with the tunnel wall fully on screen -- the fg content that actually
-- exposes tile-boundary bugs, unlike the logo frame every earlier diff used.

local DUMP_FRAME = 60
local DUMP_PATH  = "vram_dump.txt"

local frames = 0

emu.register_periodic(function()
	frames = frames + 1
	if frames ~= DUMP_FRAME then return end

	local sp = manager.machine.devices[":maincpu"].spaces["program"]
	local f = assert(io.open(DUMP_PATH, "w"))

	f:write(string.format("-- frame %d\n-- videoram c000-c7ff, 32x32 tile codes (0x80 = blank)\n", frames))
	for row = 0, 31 do
		local line = {}
		for col = 0, 31 do
			line[#line + 1] = string.format("%02x", sp:read_u8(0xc000 + row * 32 + col))
		end
		f:write(table.concat(line, " ") .. "\n")
	end

	f:write("\n-- sprite RAM e400-e47f (16 slots x 8 bytes)\n")
	for e = 0, 15 do
		local line = {}
		for b = 0, 7 do line[#line + 1] = string.format("%02x", sp:read_u8(0xe400 + e * 8 + b)) end
		f:write(string.format("slot %2d: %s\n", e, table.concat(line, " ")))
	end

	f:write("\n-- sprite-position RAM e000-e0ff, first 64 words (hi<<8|lo)\n")
	for i = 0, 63 do
		f:write(string.format("%3d:%02x%02x ", i, sp:read_u8(0xe000 + i * 2 + 1), sp:read_u8(0xe000 + i * 2)))
		if i % 8 == 7 then f:write("\n") end
	end

	f:close()
	manager.machine:exit()
end)
