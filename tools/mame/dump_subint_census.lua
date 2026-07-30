-- Star-motion investigation: per-video-frame census of SUB-CPU activity, the
-- MAME-side counterpart of rtl/z80_3d.v's "+subintcount" SUBINT probe.
--   bmwr   -- writes into the sub CPU's bitmap window (prog 0000-dfff)
--   ioread -- sub CPU IN instructions (command-latch reads)
--   isr    -- entries to the sub CPU's interrupt service routine (PC==0038)
-- Same coin/start schedule as dump_bitmap_ram.lua so frame numbers line up
-- with the sim and with the star-tracking window (frames 420-459).
--   mame.exe buckrogn -rompath ./roms -video none -sound none -skip_gameinfo \
--            -str 8 -autoboot_script dump_subint_census.lua
local frames = 0
local bmwr = 0
local ioread = 0

local BMWR_LO = tonumber(os.getenv("BMWR_LO") or "-1")
local BMWR_HI = tonumber(os.getenv("BMWR_HI") or "-1")
local subcpu = manager.machine.devices[":subcpu"]
local prog = subcpu.spaces["program"]
local subpc = subcpu.state["PC"]
local io_sp = subcpu.spaces["io"]

-- NOTE: the tap handles MUST be kept in globals -- if they are garbage
-- collected the tap is silently removed and the counters read 0 forever.
-- BMWR_LO/BMWR_HI: frame window over which every individual bitmap write is
-- logged (address + bit), matching the RTL's +bmwrtrace_lo/+bmwrtrace_hi.
bmwr_tap = prog:install_write_tap(0x0000, 0xdfff, "bmwr_count", function(offset, data, mask)
    bmwr = bmwr + 1
    if frames >= BMWR_LO and frames <= BMWR_HI then
        print(string.format("BMWR frame=%d addr=%04x d=%d pc=%04x",
                            frames, offset, data & 1, subpc.value))
    end
    return data
end)

ioread_tap = io_sp:install_read_tap(0x0000, 0x00ff, "ioread_count", function(offset, data, mask)
    ioread = ioread + 1
    return data
end)

-- Sub ROM $030B is the top of the star updater (LD A,($F40B) = star count);
-- $0310 is its per-star loop body. Opcode fetches show up as program-space
-- reads, so a read tap on those two bytes counts invocations/iterations.
local loops = 0
local iters = 0
loop_tap = prog:install_read_tap(0x030b, 0x030b, "loop_count", function(o, d, m)
    loops = loops + 1
    return d
end)
iter_tap = prog:install_read_tap(0x0310, 0x0310, "iter_count", function(o, d, m)
    iters = iters + 1
    return d
end)

-- Sub ROM $0038 is the IM1 vector: the sub CPU's ENTIRE main->sub command
-- channel is this ISR (IN A,($00); store the low nibble at $F600+high
-- nibble). Counting fetches of $0038 counts interrupt acceptances, which
-- equals the number of command bytes that actually reach the sub CPU.
local isr = 0
isr_tap = prog:install_read_tap(0x0038, 0x0038, "isr_count", function(o, d, m)
    isr = isr + 1
    if frames >= BMWR_LO and frames <= BMWR_HI then
        print(string.format("ISR frame=%d t=%.6f", frames, manager.machine.time:as_double()))
    end
    return d
end)

-- Main-CPU writes to PPI0 port C ($C802): bit 7 is the sub CPU's /INT.
local mainprog = manager.machine.devices[":maincpu"].spaces["program"]
local pcwr = 0
local pcwr_lo = 0
-- Cover the whole PPI0 register file: the 8255's BSR command (control port
-- $C803, D7=0) can set/clear PC7 -- i.e. the sub /INT -- without ever
-- touching $C802, so watching $C802 alone misses most of the traffic.
-- PPI0 is mapped .mirror(0x07fc), i.e. it answers across the whole
-- $C800-$CFFF window; the register is offset&3. Tapping only $C800-$C803
-- sees a small fraction of the traffic.
portc_tap = mainprog:install_write_tap(0xc800, 0xcfff, "portc", function(o, d, m)
    if (o & 3) == 2 or ((o & 3) == 3 and (d & 0x80) == 0) then pcwr = pcwr + 1 end
    if (o & 3) == 3 and (d & 0x80) == 0 and (d & 0x0e) == 0x0e and (d & 1) == 0 then pcwr_lo = pcwr_lo + 1 end
    if frames >= BMWR_LO and frames <= BMWR_HI then
        print(string.format("PPI0WR frame=%d t=%.6f addr=%d data=%02x", frames,
                            manager.machine.time:as_double(), o & 3, d))
    end
    return d
end)

-- Does the main CPU poll PPI0 port C, and which bit? In 8255 mode 2 the
-- "command consumed" flag the main CPU can see is PC7 (/OBF), not PC6.
p0rd_tap = mainprog:install_read_tap(0xc800, 0xcfff, "p0rd", function(o, d, m)
    if frames >= BMWR_LO and frames <= BMWR_HI then
        print(string.format("PPI0RD frame=%d t=%.6f addr=%d data=%02x pc=%04x",
                            frames, manager.machine.time:as_double(), o & 3, d,
                            manager.machine.devices[":maincpu"].state["PC"].value))
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

    -- $F402 = per-frame star X step, $F403 = Y step, $F40B = star count,
    -- $F410 = row limit above which a star is not plotted.
    print(string.format(
        "SUBINT frame=%d bmwr=%d ioread=%d isr=%d pcwr=%d pclo=%d loop=%d iter=%d dx=%02x dy=%02x nstars=%02x horiz=%02x f600=%02x%02x%02x%02x%02x%02x%02x%02x",
        frames, bmwr, ioread, isr, pcwr, pcwr_lo, loops, iters,
        prog:read_u8(0xf402), prog:read_u8(0xf403),
        prog:read_u8(0xf40b), prog:read_u8(0xf410),
        prog:read_u8(0xf600), prog:read_u8(0xf601), prog:read_u8(0xf602),
        prog:read_u8(0xf603), prog:read_u8(0xf604), prog:read_u8(0xf605),
        prog:read_u8(0xf606), prog:read_u8(0xf607)))
    bmwr = 0
    ioread = 0
    loops = 0
    iters = 0
    isr = 0
    pcwr = 0
    pcwr_lo = 0

    if frames == 459 then
        manager.machine:exit()
    end
end)
