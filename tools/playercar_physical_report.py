#!/usr/bin/env python3
"""Archive physical-model diagnosis and plot source/device validation."""
import hashlib
import json
from pathlib import Path
import shutil
import numpy as np
import matplotlib.pyplot as plt

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'sim/out/physical_vca_20260930'
EVIDENCE=ROOT/'docs/evidence'


def main():
    data=json.loads((OUT/'physical_engine_validation.json').read_text())
    probes=json.loads((OUT/'corrected_device_validation.json').read_text())
    spec=json.loads((OUT/'fixedpoint_candidate_spec.json').read_text())
    fig7=json.loads((OUT/'MC3340_Figure7_curve.json').read_text())
    curve=json.loads((ROOT/'sim/out/vco_joint_20260930/MC3340_original_12V_curve.json').read_text())
    device=json.loads((OUT/'corrected_2D_transfer.json').read_text())
    fig,axes=plt.subplots(2,2,figsize=(14,9),layout='constrained')
    ax=axes[0,0]
    ax.plot(curve['control_v'],curve['attenuation_db'],label='Motorola Figure3: 12V',color='black',lw=2)
    for p,label in zip(probes[:3],('Later drawing','Input diode restored','Both historical diodes')):
        ax.plot([x['control_v'] for x in p['control_curve']],[x['attenuation_db'] for x in p['control_curve']],label=label)
    ax.set(xlim=(2.5,5.1),ylim=(0,80),xlabel='External pin2 control (V)',ylabel='Attenuation (dB)',title='Corrected pin2 connection; native control still differs')
    ax.legend(fontsize=8);ax.grid(alpha=.2)
    ax=axes[0,1]
    ax.plot(fig7['attenuation_db'],fig7['THD_percent'],label='Published Figure7',color='black',lw=2)
    for p,label in zip(probes[3:6],('Later drawing','Input diode restored','Both historical diodes')):
        points=p['THD_fixed_input'][1::2]
        ax.plot([x['attenuation_db'] for x in points],[x['THD_percent'] for x in points],'.-',label=label)
    ax.set(xlim=(0,50),ylim=(0,4),xlabel='Attenuation (dB)',ylabel='THD (%)',title='16V; fixed input giving 2.5Vrms in linear on-state')
    ax.text(.03,.92,'Figure7 test interpretation remains qualified',transform=ax.transAxes,fontsize=8)
    ax.legend(fontsize=8,loc='lower right');ax.grid(alpha=.2)
    ax=axes[1,0];keys=list(data['cabinet_patterns']['cab763_residual']);x=np.arange(len(keys))
    ax.bar(x-.18,[data['cabinet_patterns']['cab763_residual'][k] for k in keys],.36,label='Cabinet763 residual',color='#444444')
    ax.bar(x+.18,[data['cases']['joint_Figure3_mapped']['pattern_dB_re_2IminusT'][k] for k in keys],.36,label='Physical candidate',color='#247fa5')
    ax.set_xticks(x,keys,rotation=45,ha='right');ax.set(ylabel='dB relative to 2I-T',title='Line hierarchy is not reproduced (3.79dB centered error)')
    ax.legend(fontsize=8);ax.grid(axis='y',alpha=.2)
    ax=axes[1,1];vin=np.array(device['vin'])
    for k in (0,1,5,10):
        ax.plot(vin,device['vout'][k],label=f"{device['attenuation_db'][k]:g}dB attenuation")
    ax.set(xlim=(-3,4.5),ylim=(0,12),xlabel='Absolute input pin voltage (V)',ylabel='Absolute output voltage (V)',title='Two-input asymmetric candidate; DC retained')
    ax.axvline(device['bias'],color='gray',lw=.7);ax.legend(fontsize=8);ax.grid(alpha=.2)
    fig.suptitle('Sega player-car physical VCA diagnosis — no cabinet parameters, no RTL edits',fontsize=15)
    EVIDENCE.mkdir(exist_ok=True,parents=True)
    fig.savefig(EVIDENCE/'playercar_physical_vca_validation_20260930.png',dpi=150)
    for filename in ('physical_engine_validation.json','corrected_device_validation.json','corrected_beta_sensitivity.json',
                     'MC3340_Figure7_curve.json','corrected_2D_transfer.json','fixedpoint_candidate_spec.json',
                     'candidate_vout_Q16.bin','candidate_input_current_Q36.bin'):
        shutil.copyfile(OUT/filename,EVIDENCE/('playercar_'+filename))
    for page in (897,898):
        shutil.copyfile(OUT/f'Motorola_1976_MC3340_{page}.png',EVIDENCE/f'Motorola_1976_MC3340_{page}.png')
    sources=dict(book_url='https://bitsavers.trailing-edge.com/components/motorola/_dataBooks/1976_Motorola_Semiconductor_Data_Library_Volume_6_Series_B_Linear_Integrated_Circuits.pdf',
        book_sha256=hashlib.sha256((OUT/'Motorola_1976_linear.pdf').read_bytes()).hexdigest(),
        pages='PDF pages897/898, printed7-170/7-171',
        original_source_sha256=curve['sha256'],
        candidates={filename:hashlib.sha256((OUT/filename).read_bytes()).hexdigest() for filename in
                    ('corrected_2D_transfer.json','candidate_vout_Q16.bin','candidate_input_current_Q36.bin')})
    (EVIDENCE/'playercar_physical_sources_20260930.json').write_text(json.dumps(sources,indent=2)+'\n')


if __name__=='__main__':main()
