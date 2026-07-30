-- Dump the sub CPU's work RAM (0xe000-0xe7ff, 2048 bytes -- plain `.ram()` in
-- sub_prg_map, no named memory_share) every frame from frame 1 through 250,
-- for a per-frame byte diff against sim/tb_z80_3d.cpp's --dumpworkram output
-- (rtl_workram_NNN.bin). Same coin/start schedule as the other dump scripts.
--   mame.exe buckrogn -video none -sound none -autoboot_script dump_subcpu_workram.lua -str 8
local frames = 0
local coin_pulsed = false
local start_pulsed = false
local subcpu = manager.machine.devices[":subcpu"]
local progspace = subcpu.spaces["program"]

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

    if frames >= 1 and frames <= 250 then
        local t = {}
        for i = 0, 2047 do
            t[i + 1] = string.char(progspace:read_u8(0xe000 + i))
        end
        local f = io.open(string.format("mame_workram_%03d.bin", frames), "wb")
        f:write(table.concat(t))
        f:close()
    end
    if frames == 250 then
        manager.machine:exit()
    end
end)
