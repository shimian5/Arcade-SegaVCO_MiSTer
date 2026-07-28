-- Dump a running machine's palette to $PALOUT as one 6-digit hex RRGGBB per line.
--
--   set PALOUT=...\pal.txt
--   mame.exe buckrogn -video none -sound none -autoboot_script dump_palette.lua -str 5
--
-- Driven by tools/gen_tables.py --check-mame. Waits a few frames so the driver's
-- palette() callback has definitely run before reading.

local frames = 0

emu.register_periodic(function()
	frames = frames + 1
	if frames ~= 30 then return end

	local path = os.getenv("PALOUT")
	if not path then
		print("dump_palette.lua: PALOUT not set")
		manager.machine:exit()
		return
	end

	local palette = manager.machine.palettes[":palette"]
	local out = io.open(path, "w")
	for i = 0, palette.entries - 1 do
		out:write(string.format("%06x\n", palette:pen_color(i) & 0xffffff))
	end
	out:close()

	manager.machine:exit()
end)
