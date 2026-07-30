-- Per-frame HUD trace: SECT digit, RD digit, lives icons, TIME LEFT gauge,
-- and a whole-tilemap checksum. Format matches sim/tb_z80_3d.cpp --hudtrace
-- line-for-line so the two traces diff directly.
-- Coin/start frames come from the environment so the phase sweep can drive
-- both engines with the same schedule.
local COIN  = tonumber(os.getenv("BR_COIN"))  or 90
local START = tonumber(os.getenv("BR_START")) or 150
local NFRAMES = tonumber(os.getenv("BR_FRAMES")) or 1100
local OUT = os.getenv("BR_OUT") or "hud_trace.txt"
local f = 0
local out = assert(io.open(OUT,"w"))
CB = emu.register_periodic(function()
  f = f + 1
  local ioport = manager.machine.ioport
  local function setf(n,v) local x = ioport.ports[":IN1"].fields[n]; if x then x:set_value(v) end end
  if f == COIN then setf("Coin 1",0) end
  if f == COIN+10 then setf("Coin 1",1) end
  if f == START then setf("1 Player Start",0) end
  if f == START+10 then setf("1 Player Start",1) end
  local sp = manager.machine.devices[":maincpu"].spaces["program"]
  local sect = sp:read_u8(0xc05e)
  local rd   = sp:read_u8(0xc03e)
  local sum = 0
  for a=0xc000,0xc7ff do sum = (sum + sp:read_u8(a)*(a&0xff|1)) & 0xffffff end
  local bar = {}
  for c=0,31 do bar[#bar+1]=string.format("%02x", sp:read_u8(0xc000+25*32+c)) end
  local timer = {}
  for c=1,23 do timer[#timer+1]=string.format("%02x", sp:read_u8(0xc000+1*32+c)) end
  out:write(string.format("f=%d sect=%02x rd=%02x sum=%06x bar=%s timer=%s\n",
    f, sect, rd, sum, table.concat(bar,""), table.concat(timer,"")))
  if f > NFRAMES then out:close(); manager.machine:exit() end
end)
