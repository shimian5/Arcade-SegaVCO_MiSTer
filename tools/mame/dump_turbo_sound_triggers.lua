-- Turbo discrete audio: find out which sound lines the game ACTUALLY asserts,
-- and over what range, by tapping the sound PPI's data writes during a real
-- driven session.
--
-- PRIMARY QUESTION: does the game ever assert /CRASH.S (port A bit 0)?
-- MAME's own turbo_a.cpp:88 says "missing short crash sample, but I've never
-- seen it triggered". If that is right, /CRASH.L is the only crash the game
-- fires, and turbo_crash_chan.sv's CRASH.L stub -- not its fully-modelled
-- CRASH.S envelope -- is what needs the work.
--
-- SECONDARY: the ACC0-5 range and BSEL distribution the game really uses, for
-- turbo_playercar_chan.sv's STEP_LUT anchor (currently an inferred 120..900 Hz
-- linear map) and its BCONT0/1 stub.
--
-- Sound PPI is m_i8255[2] (sound_a_w/sound_b_w/sound_c_w in turbo.cpp's
-- machine config), mapped at 0xfa00-0xfa03 .mirror(0x00fc) -- so the whole
-- 0xfa00-0xfaff window answers and the register index is offset&3:
--     reg 0 = port A (sound_a), reg 1 = port B (sound_b), reg 2 = port C (sound_c)
--     reg 3 = the 8255 control word -- NOT port data, skipped below.
--
-- Bit map per docs/hardware-turbo.md's CN1 ledger, cross-checked against
-- turbo_a.cpp's sound_a_w/sound_b_w/sound_c_w:
--     port A: {CRASH.L, /SLIP, OSEL0, TRIG4, TRIG3, TRIG2, TRIG1, /CRASH.S}
--     port B: {/SPIN, /AMBU, ACC5..ACC0}
--     port C: {SPEED3..0, BSEL1, BSEL0, OSEL2, OSEL1}
--
--   mame.exe turbo -rompath ./roms -video none -sound none -skip_gameinfo \
--     -str 120 -autoboot_script tools/mame/dump_turbo_sound_triggers.lua
--
-- NOTE: tap handles must live in GLOBALS or they are garbage-collected and the
-- taps silently stop firing, leaving every counter reading a confident 0
-- (docs/INVESTIGATION_title_logo_garbling.md). `sound_w_tap` below is global
-- deliberately -- do not make it local.
--
-- NOTE: sound does not start until coin-up + start, and CRASH needs the car to
-- actually hit something. The drive script below floors the pedal and never
-- steers, so the car piles into roadside traffic on its own.

-- Active-low lines, reported on the falling edge (the sound board's 74123
-- one-shots are negative-edge triggered).
local LINES = {
    { name = "CRASH.S", reg = 0, bit = 0x01 },
    { name = "TRIG1",   reg = 0, bit = 0x02 },
    { name = "TRIG2",   reg = 0, bit = 0x04 },
    { name = "TRIG3",   reg = 0, bit = 0x08 },
    { name = "TRIG4",   reg = 0, bit = 0x10 },
    { name = "SLIP",    reg = 0, bit = 0x40 },
    { name = "CRASH.L", reg = 0, bit = 0x80 },
    { name = "AMBU",    reg = 1, bit = 0x40 },
    { name = "SPIN",    reg = 1, bit = 0x80 },
}

local frames  = 0
local writes  = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
local prev    = { [0] = nil, [1] = nil, [2] = nil }
local counts  = {}
local first   = {}
local everlow = {}   -- level-based, not edge-based: see note in the summary
for i = 1, #LINES do counts[i] = 0; first[i] = nil; everlow[i] = false end

-- ACC / BSEL / OSEL / SPEED observation, from the STORED byte each write
-- leaves behind rather than from event counts -- the same discipline the
-- CN1 command-channel checks use.
local acc_min, acc_max = 63, 0
local acc_hist = {}          -- bucketed by 8: acc_hist[0..7]
for i = 0, 7 do acc_hist[i] = 0 end
local bsel_hist = { [0] = 0, [1] = 0, [2] = 0, [3] = 0 }
local osel_hist = {}
for i = 0, 7 do osel_hist[i] = 0 end
local speed_min, speed_max = 15, 0

-- Fields are located by name so this does not depend on the driver's port tags.
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
local f_pedal = find_field("Pedal")
local f_gear  = find_field("Gear Shift")
print(string.format("inputs: coin=%s start=%s pedal=%s gear=%s",
                    tostring(f_coin ~= nil), tostring(f_start ~= nil),
                    tostring(f_pedal ~= nil), tostring(f_gear ~= nil)))

local maincpu  = manager.machine.devices[":maincpu"]
local mainprog = maincpu.spaces["program"]
local mainpc   = maincpu.state["PC"]

local function report(idx, pc)
    counts[idx] = counts[idx] + 1
    local t = manager.machine.time:as_double()
    if first[idx] == nil then first[idx] = t end
    -- Only the first few of each are printed; the periodic summary carries the
    -- totals. TRIG1-4 and SLIP fire constantly and would drown the log.
    if counts[idx] <= 5 then
        print(string.format("%-7s fall frame=%d t=%.3f pc=%04x",
                            LINES[idx].name, frames, t, pc))
    end
end

sound_w_tap = mainprog:install_write_tap(0xfa00, 0xfaff, "turbo_sound_w", function(o, d, m)
    local reg = o & 3
    writes[reg] = writes[reg] + 1
    if reg == 3 then return d end   -- 8255 control word, not port data

    local pc = mainpc.value
    local p  = prev[reg]

    for i = 1, #LINES do
        local L = LINES[i]
        if L.reg == reg then
            if (d & L.bit) == 0 then
                -- Level check, independent of edge detection: catches a line
                -- that was already low on the very first write we observe.
                everlow[i] = true
            end
            if p ~= nil and (p & L.bit) ~= 0 and (d & L.bit) == 0 then
                report(i, pc)
            end
        end
    end

    if reg == 1 then
        local acc = d & 0x3f
        if acc < acc_min then acc_min = acc end
        if acc > acc_max then acc_max = acc end
        acc_hist[acc >> 3] = acc_hist[acc >> 3] + 1
    elseif reg == 2 then
        local bsel = (d >> 2) & 3
        bsel_hist[bsel] = bsel_hist[bsel] + 1
        local spd = (d >> 4) & 0x0f
        if spd < speed_min then speed_min = spd end
        if spd > speed_max then speed_max = spd end
    end

    prev[reg] = d
    return d
end)

-- OSEL spans two ports (bit0 from A, bits1-2 from C), so it is sampled from
-- the two stored bytes together rather than from either write alone.
local function sample_osel()
    if prev[0] == nil or prev[2] == nil then return end
    local osel = ((prev[0] >> 5) & 1) | ((prev[2] & 3) << 1)
    osel_hist[osel] = osel_hist[osel] + 1
end

-- This MAME build has no emu.register_stop, so the running tally is printed
-- periodically and the last block printed is the final answer.
local function hold(field, lo, hi)
    if field then field:set_value((frames >= lo and frames < hi) and 1 or 0) end
end

emu.register_frame_done(function()
    frames = frames + 1
    sample_osel()

    -- coin at ~2 s, start at ~4 s, then floor the pedal from ~5.5 s and never
    -- steer -- the car drives itself into traffic, which is what fires CRASH.
    hold(f_coin,  120, 135)
    hold(f_start, 240, 255)
    if frames > 330 and f_pedal then f_pedal:set_value(255) end

    if frames % 900 == 0 then
        print("---- turbo sound trigger summary ----")
        print(string.format("frames=%d  port writes A=%d B=%d C=%d ctrl=%d",
                            frames, writes[0], writes[1], writes[2], writes[3]))
        for i = 1, #LINES do
            print(string.format("%-7s: %5d falling edges, ever-low=%-5s, first at t=%s",
                                LINES[i].name, counts[i], tostring(everlow[i]),
                                first[i] and string.format("%.3f", first[i]) or "never"))
        end
        print(string.format("ACC   range %d..%d  buckets(0-7,8-15,...): %d %d %d %d %d %d %d %d",
                            acc_min, acc_max, acc_hist[0], acc_hist[1], acc_hist[2],
                            acc_hist[3], acc_hist[4], acc_hist[5], acc_hist[6], acc_hist[7]))
        print(string.format("BSEL  0=%d 1=%d 2=%d 3=%d", bsel_hist[0], bsel_hist[1],
                            bsel_hist[2], bsel_hist[3]))
        print(string.format("OSEL  0=%d 1=%d 2=%d 3=%d 4=%d 5=%d 6=%d 7=%d",
                            osel_hist[0], osel_hist[1], osel_hist[2], osel_hist[3],
                            osel_hist[4], osel_hist[5], osel_hist[6], osel_hist[7]))
        print(string.format("SPEED range %d..%d", speed_min, speed_max))
    end
end)
