-- Dump the raw bitmap_ram memory_share (256x224x8-bit, only bit0 meaningful --
-- the STAR layer) for 40 consecutive frames of real gameplay, so star
-- trajectories can be tracked precisely (ground truth for star motion,
-- independent of any rendering/palette step). Same coin/start schedule as
-- dump_frames_range.lua.
--   mame.exe buckrogn -video none -sound none -autoboot_script dump_bitmap_ram.lua -str 8
local frames = 0
local coin_pulsed = false
local start_pulsed = false

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

    if frames >= 420 and frames <= 459 then
        local share = manager.machine.memory.shares[":bitmap_ram"]
        if share then
            local sz = share.size
            local t = {}
            for i = 0, sz - 1 do
                t[i + 1] = string.char(share:read_u8(i) & 1)
            end
            local f = io.open(string.format("bitmap_%03d.bin", frames), "wb")
            f:write(table.concat(t))
            f:close()
        else
            print("bitmap_ram share not found!")
        end
    end
    if frames == 459 then
        manager.machine:exit()
    end
end)
