-- Starfield investigation: log every main-CPU access to PPI0 with the
-- main-CPU PC, over a frame window, plus the sub-CPU ISR entries. The RTL
-- counterpart is z80_3d.v's +bmwrtrace_lo/+bmwrtrace_hi PPI0WR/PPI0RD lines.
--
-- PPI0 is mapped .mirror(0x07fc), so the whole $C800-$CFFF window answers and
-- the register index is offset&3: 0=port A (the command latch), 2=port C
-- (whose bit 7 is /OBF, the "command consumed" flag the main CPU polls).
--
--   PPI0_LO=40 PPI0_HI=60 mame.exe buckrogn -rompath ./roms -video none \
--     -sound none -skip_gameinfo -str 12 -autoboot_script dump_ppi0_traffic.lua
--
-- NOTE: tap handles must live in globals or they are garbage-collected and
-- the taps silently stop firing (see docs/INVESTIGATION_title_logo_garbling.md).
local frames = 0
local LO = tonumber(os.getenv("PPI0_LO") or "40")
local HI = tonumber(os.getenv("PPI0_HI") or "60")

local maincpu = manager.machine.devices[":maincpu"]
local mainprog = maincpu.spaces["program"]
local mainpc = maincpu.state["PC"]
local subcpu = manager.machine.devices[":subcpu"]
local subprog = subcpu.spaces["program"]

ppi0_w_tap = mainprog:install_write_tap(0xc800, 0xcfff, "ppi0w", function(o, d, m)
    if frames >= LO and frames <= HI then
        print(string.format("PPI0WR frame=%d t=%.6f addr=%d data=%02x pc=%04x",
                            frames, manager.machine.time:as_double(), o & 3, d,
                            mainpc.value))
    end
    return d
end)

ppi0_r_tap = mainprog:install_read_tap(0xc800, 0xcfff, "ppi0r", function(o, d, m)
    if frames >= LO and frames <= HI then
        print(string.format("PPI0RD frame=%d t=%.6f addr=%d data=%02x pc=%04x",
                            frames, manager.machine.time:as_double(), o & 3, d,
                            mainpc.value))
    end
    return d
end)

isr_tap = subprog:install_read_tap(0x0038, 0x0038, "isr", function(o, d, m)
    if frames >= LO and frames <= HI then
        print(string.format("ISR    frame=%d t=%.6f", frames,
                            manager.machine.time:as_double()))
    end
    return d
end)

emu.register_periodic(function()
    frames = frames + 1
    local ioport = manager.machine.ioport
    if frames == 90 then
        local c = ioport.ports[":IN1"].fields["Coin 1"]; if c then c:set_value(0) end
    end
    if frames == 100 then
        local c = ioport.ports[":IN1"].fields["Coin 1"]; if c then c:set_value(1) end
    end
    if frames == 150 then
        local s = ioport.ports[":IN1"].fields["1 Player Start"]; if s then s:set_value(0) end
    end
    if frames == 160 then
        local s = ioport.ports[":IN1"].fields["1 Player Start"]; if s then s:set_value(1) end
    end
    if frames > HI then manager.machine:exit() end
end)
