-- Discrete audio: find out when, and from where, the game asserts the four
-- /ALARM lines. Reports every falling edge (the 74123 one-shots on the sound
-- board are negative-edge triggered) with the frame, time and main-CPU PC.
--
-- PPI1 is at $D000-$D003 with .mirror(0x07fc), so the whole $D000-$D7FF window
-- answers and the register index is offset&3: 0=port A, 1=port B.
--
-- Alarm bit assignment (docs/hardware-audio.md, confirmed against the sound
-- board connector pinout):
--     port A bit 6 = /ALARM0     port B bit 0 = /ALARM2
--     port A bit 7 = /ALARM1     port B bit 1 = /ALARM3
--
--   mame.exe buckrogn -rompath ./roms -video none -sound none -skip_gameinfo \
--     -str 60 -autoboot_script <this file>
--
-- NOTE: tap handles must live in globals or they are garbage-collected and the
-- taps silently stop firing (docs/INVESTIGATION_title_logo_garbling.md).

-- Every negative-edge-triggered sound line, in the order they are reported.
-- reg 0 = port A, reg 1 = port B; bit is the bit within that port.
local LINES = {
    { name = "ALARM0",  reg = 0, bit = 0x40 },
    { name = "ALARM1",  reg = 0, bit = 0x80 },
    { name = "ALARM2",  reg = 1, bit = 0x01 },
    { name = "ALARM3",  reg = 1, bit = 0x02 },
    { name = "FIRE",    reg = 1, bit = 0x04 },
    { name = "EXP",     reg = 1, bit = 0x08 },
    { name = "HIT",     reg = 1, bit = 0x10 },
    { name = "REBOUND", reg = 1, bit = 0x20 },
}

local frames = 0
local pa_prev = 0xff
local pb_prev = 0xff
local counts = {}
local first = {}
for i = 1, #LINES do counts[i] = 0; first[i] = nil end

-- Attract mode never touches the alarm lines, so the run has to coin up and
-- start a game. Fields are located by name so this does not depend on the
-- driver's port tags.
local function find_field(pattern)
    for _, port in pairs(manager.machine.ioport.ports) do
        for name, field in pairs(port.fields) do
            if name:find(pattern) then return field end
        end
    end
    return nil
end

local f_coin  = find_field("Coin 1")
local f_start = find_field("1 Player Start")
local f_fire  = find_field("Button 1")
print(string.format("inputs: coin=%s start=%s fire=%s",
                    tostring(f_coin ~= nil), tostring(f_start ~= nil),
                    tostring(f_fire ~= nil)))

local maincpu = manager.machine.devices[":maincpu"]
local mainprog = maincpu.spaces["program"]
local mainpc = maincpu.state["PC"]

local function report(idx, pc)
    counts[idx] = counts[idx] + 1
    local t = manager.machine.time:as_double()
    if first[idx] == nil then first[idx] = t end
    print(string.format("%-7s fall frame=%d t=%.3f pc=%04x",
                        LINES[idx].name, frames, t, pc))
end

ppi1_w_tap = mainprog:install_write_tap(0xd000, 0xd7ff, "ppi1w", function(o, d, m)
    local reg = o & 3
    if reg ~= 0 and reg ~= 1 then return d end
    local pc = mainpc.value
    local prev = (reg == 0) and pa_prev or pb_prev
    for i = 1, #LINES do
        local L = LINES[i]
        -- falling edge = bit was 1, now 0
        if L.reg == reg and (prev & L.bit) ~= 0 and (d & L.bit) == 0 then
            report(i, pc)
        end
    end
    if reg == 0 then pa_prev = d else pb_prev = d end
    return d
end)

-- This MAME build has no emu.register_stop, so the running tally is printed
-- periodically instead and the last block printed is the final answer.
local function hold(field, lo, hi)
    if field then field:set_value((frames >= lo and frames < hi) and 1 or 0) end
end

emu.register_frame_done(function()
    frames = frames + 1

    -- coin at ~2 s, start at ~4 s, then hold fire from 8 s so the run
    -- generates combat rather than idling into a wall
    hold(f_coin, 120, 135)
    hold(f_start, 240, 255)
    if frames > 480 then
        hold(f_fire, frames, frames + ((frames % 20 < 10) and 1 or 0))
    end

    if frames % 1200 == 0 then
        print("---- sound trigger summary ----")
        for i = 1, #LINES do
            print(string.format("%-7s: %5d triggers, first at t=%s",
                                LINES[i].name, counts[i],
                                first[i] and string.format("%.3f", first[i]) or "never"))
        end
        print(string.format("frames=%d", frames))
    end
end)
