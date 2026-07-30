import sys, os
# Write a minimal MAME cfg pinning the buckrogn DIPs, so runs are reproducible
# instead of inheriting whatever a previous session left behind.
dsw1, dsw2 = int(sys.argv[1],0), int(sys.argv[2],0)
ports=[]
for tag,val,masks in ((':DSW1',dsw1,(0x07,0x38,0x40,0x80)), (':DSW2',dsw2,(0x01,0x02,0x04,0x08,0x10,0x60,0x80))):
    for m in masks:
        ports.append('            <port tag="%s" type="DIPSWITCH" mask="%d" defvalue="%d" value="%d" />'%(tag,m,m,val&m))
open(r'C:\MiSTerDev\mame\cfg\buckrogn.cfg','w',encoding='utf-8').write(
'<?xml version="1.0"?>\n<mameconfig version="10">\n    <system name="buckrogn">\n        <input>\n'
+ '\n'.join(ports) + '\n        </input>\n    </system>\n</mameconfig>\n')
print('cfg written dsw1=%02x dsw2=%02x'%(dsw1,dsw2))
