-- Full 2KB fg tilemap per frame over a window, binary, same layout as the
-- sim's --vramrange dump (sim/out/rtl_vram_NNNN.bin).
local LO, HI = 180, 260
local f = 0
CB = emu.register_periodic(function()
  f = f + 1
  local ioport = manager.machine.ioport
  local function setf(n,v) local x = ioport.ports[":IN1"].fields[n]; if x then x:set_value(v) end end
  if f == 90 then setf("Coin 1",0) end
  if f == 100 then setf("Coin 1",1) end
  if f == 150 then setf("1 Player Start",0) end
  if f == 160 then setf("1 Player Start",1) end
  if f >= LO and f <= HI then
    local sp = manager.machine.devices[":maincpu"].spaces["program"]
    local o = assert(io.open(string.format("vram/mame_vram_%04d.bin", f), "wb"))
    local t = {}
    for a=0,2047 do t[#t+1] = string.char(sp:read_u8(0xc000+a)) end
    o:write(table.concat(t)); o:close()
  end
  if f > HI then manager.machine:exit() end
end)
