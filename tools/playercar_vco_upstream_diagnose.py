#!/usr/bin/env python3
"""Upstream VCO diagnosis: physical ladder and comparator/TR6 dynamics.

NO cabinet-fitted parameters. Comparator internal state is a diagnostic
reduction of TI SLOA277B section 6, not a silicon macromodel. Ccomp is
inferred from its explicit 30us recovery example at VIN+=10V and VID=200mV.
The external slew limiter is illustrative and may overlap internal pole
dynamics; these results must NOT be ported as an exact delay constant.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import numpy as np
from scipy.optimize import root,least_squares
import playercar_d8_ic17_reference as R
from playercar_ic7_device_tolerance import CELLS
from playercar_mc3340_device import junction


def ladder(acc,series=50000.,supply=12.,low=0.,pullup=2200.):
    """Six-node D8 R-2R with OC pullups only in released branches."""
    matrix=np.zeros((6,6));rhs=np.zeros(6)
    for i in range(6):
        high=bool(acc&(1<<(5-i)))
        leg=100000.+(pullup if high else 0.)
        matrix[i,i]+=1/leg;rhs[i]+=(supply if high else low)/leg
        if i<5:
            matrix[i,i]+=1/series;matrix[i+1,i+1]+=1/series
            matrix[i,i+1]-=1/series;matrix[i+1,i]-=1/series
    matrix[-1,-1]+=1/100000.
    return float(np.linalg.solve(matrix,rhs)[0])


def tr6_table(bus,rsink=68000.):
    """Nonlinear drive via R80, D14 and R83; unpublished junction assumptions."""
    vt=.02585;isat=.002/np.exp(.67/vt);beta=240.;br=1.
    # The existing MA150 approximation is a switching-diode proxy. No
    # published MA150 SPICE parameters exist among the available sources.
    disat=1.8e-9;nvt=1.9*vt
    voltage=np.linspace(0.,11.,551);collector=[];base=[]
    last=np.array([0.,0.,bus/2])
    for vout in voltage:
        def eq(x):
            anode,vb,vc=x
            f,_=junction(vb/vt);rev,_=junction((vb-vc)/vt)
            ic=isat*((f-1)-(rev-1)*(1+1/br))
            ib=isat*((f-1)/beta+(rev-1)/br)
            d,_=junction((anode-vb)/nvt);di=disat*(d-1)
            return np.array([(anode-vout)/10000+di,vb/2200+ib-di,(vc-bus/2)/rsink+ic])*1000
        sol=root(eq,last,tol=1e-10)
        if max(abs(eq(sol.x)))>1e-7:
            sol=least_squares(eq,last,xtol=1e-12,ftol=1e-12,gtol=1e-12,max_nfev=2000)
        if max(abs(eq(sol.x)))>1e-7:raise RuntimeError(f'TR6 drive KCL failure at OUT={vout}: {eq(sol.x)}')
        last=sol.x
        base.append(float(last[1]));collector.append(float(last[2]))
    return voltage,np.array(collector),np.array(base)


def vco(bus,ri,rs,c,voltage,collector,*,high=10.5,low=0.,sr=.5,memory=True,dt=.25e-6):
    """Continuous ramp, finite slew and a recovering comparator state."""
    duration=.12
    rref=51000.;rfeed=100000.;vt=.02585
    # TI's internal node: .6V linear, VIN+ +1.3V in negative overload.
    ireg=6e-6
    ccomp=30e-6*ireg/(10.+1.3-.6)  # explicit source example, NOT audio fit
    signal=5.75;out=low;internal=6.*rfeed/(rfeed+rref)+low*rref/(rfeed+rref)+1.3
    crossings=[];last_sign=False;wave=[]
    for i in range(int(duration/dt)):
        plus=(6.*rfeed+out*rref)/(rfeed+rref)
        diff=plus-signal
        drive=np.tanh(diff/(2*vt))
        if memory:
            internal=np.clip(internal-ireg/ccomp*drive*dt,0.,plus+1.3)
            target=high if internal<.6 else low
        else:
            target=high if diff>0 else low
        if sr is None:out=target
        else:
            # Published SR applies with large VID. The differential factor
            # is a generic pair approximation, not digitized Figure 6-4.
            out+=np.clip(target-out,-sr*1e6*abs(drive)*dt,sr*1e6*abs(drive)*dt)
        vc=float(np.interp(out,voltage,collector))
        signal+=((bus/2-vc)/rs-bus/2/ri)/c*dt
        new_sign=out>5.
        if new_sign and not last_sign and i*dt>.04:crossings.append(i*dt)
        last_sign=new_sign
        if i*dt>.08 and i%4==0:wave.append(signal)
    if len(crossings)<3:raise RuntimeError('Too few settled VCO cycles')
    periods=np.diff(crossings)
    return dict(rate_Hz=float(1/periods.mean()),period_jitter_numerical_us=float(periods.std()*1e6),
                triangle_min_v=float(min(wave)),triangle_max_v=float(max(wave)),
                Ccomp_inferred_pF=ccomp*1e12,slew_V_per_us=sr,memory=memory,high=high,low=low,dt_us=dt*1e6)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=Path('sim/out/vca_ic7_20260930'))
    ap.add_argument('--save-evidence',action='store_true',help='Save combined reports and figure into docs/evidence after the other three tools have run')
    ap.add_argument('--evidence-only',action='store_true',help='Regenerate evidence from completed output JSON without rerunning the VCO')
    a=ap.parse_args();a.out.mkdir(parents=True,exist_ok=True)
    if a.evidence_only:
        save_evidence(a.out);return
    bus=R.ladder_v(42)*R.BUS_LOADED
    voltage,collector,base=tr6_table(bus)
    rise=(bus/2-collector)/68000-bus/2/150000
    threshold=float(np.interp(0.,rise,voltage))
    report=dict(assumptions=__doc__,raw_ladder_reference=R.ladder_v(42),ladder_cases=[],
                TR6_ramp_reversal_output_v=threshold,
                TR6_on_collector_v=float(np.interp(10.5,voltage,collector)),
                vco_cases=[])
    for series in (50000.,51000.):
        for vol in (0.,.1,.2):
            report['ladder_cases'].append(dict(series_ohm=series,OC_low_v=vol,
                acc42_v=ladder(42,series=series,low=vol),
                delta_percent=100*(ladder(42,series=series,low=vol)/R.ladder_v(42)-1)))
    report['supply_correlated_rate_factor']={str(v): (v/(v-1.5))/(12/10.5) for v in (11.5,12.,12.5)}
    for memory,sr,high,low in ((False,None,10.5,0.),(False,.5,10.5,0.),
                               (True,.5,10.5,0.),(True,.3,10.5,0.),
                               (True,.5,10.4,0.),(True,.5,10.5,.5)):
        result=vco(bus,*CELLS['I'],voltage,collector,high=high,low=low,sr=sr,memory=memory)
        report['vco_cases'].append(result)
    report['numerical_half_step_check']=vco(bus,*CELLS['I'],voltage,collector,sr=.5,memory=True,dt=.125e-6)
    tv,tc,_=tr6_table(bus,rsink=CELLS['T'][1])
    report['tone_same_device_proxy_only']=vco(bus,*CELLS['T'],tv,tc,sr=.5,memory=True)
    report['tone_same_device_warning']='IC6 photo is uA324PC, IC7 is LM2902N. This shared proxy shows direction; it is not a characterized IC6 prediction.'
    (a.out/'vco_upstream_diagnosis.json').write_text(json.dumps(report,indent=2)+'\n')
    if a.save_evidence:save_evidence(a.out)
    print(json.dumps(report,indent=2))


def save_evidence(out):
    """Scientific figure and compact handoff data, no inferred RTL constants."""
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    filenames=dict(mc3340_dc='mc3340_dc_probe.json',mc3340_validation='mc3340_validation.json',
                   ic7='ic7_device_tolerance.json',vca='vca_loading_diagnosis.json',
                   upstream='vco_upstream_diagnosis.json')
    data={key:json.loads((out/file).read_text()) for key,file in filenames.items()}
    destination=Path(__file__).resolve().parents[1]/'docs/evidence'
    destination.mkdir(parents=True,exist_ok=True)
    (destination/'playercar_vca_ic7_upstream_metrics_20260930.json').write_text(json.dumps(data,indent=2)+'\n')
    tab=json.loads((out/'mc3340_on_transfer.json').read_text())[1]
    fig,axes=plt.subplots(2,2,figsize=(12,8),layout='constrained')
    x=np.linspace(-1.5,1.5,401)
    ax=axes[0,0]
    ax.plot(x,np.interp(tab['bias']+x,tab['vin'],tab['vout'])-tab['on_dc'],label='Figure-2 on-state hypothesis')
    ax.plot(x,-4.33*x,'--',label='Small-signal linear')
    ax.plot(x,-3.65*np.tanh(4.4667*x/3.65),':',label='Previous symmetric tanh')
    ax.set(xlabel='Input pin AC (V)',ylabel='Output relative to quiescent (V)',title='VCA asymmetry: generic junctions, not verified silicon')
    ax.legend(fontsize=8);ax.grid(alpha=.2)
    names=['loaded_relative','two_one_asymmetric','two_one_asymmetric_plus_DC','cab763_residual']
    labels=['Relative gain','Two asymmetric','With DC hypothesis','Cabinet residual']
    ax=axes[0,1]
    ax.barh(labels,[data['vca']['spectra'][k]['900-3000'] for k in names],color=['#3274A1']*3+['#777777'])
    ax.set(xlabel='900–3000 Hz power / 250–900 Hz power (dB)',title='VCA hypotheses leave excess high-band energy')
    ax.grid(axis='x',alpha=.2)
    ax=axes[1,0]
    uc=data['upstream']['vco_cases']
    labels=['Instant / TR6','0.5 V/µs','Plus recovery proxy','Recovery / VOL=0.5']
    ax.scatter([uc[i]['rate_Hz'] for i in (0,1,2,5)],labels,s=60)
    ax.axvline(385.469,color='#777777',linestyle='--',label='Cabinet assigned I; observation only')
    ax.set(xlabel='IC7 rate (Hz)',title='Upstream transition changes rate by several percent')
    ax.legend(fontsize=8);ax.grid(axis='x',alpha=.2)
    ax=axes[1,1]
    lo,hi=data['ic7']['C21_only_5percent_bounds_Hz']
    nominal=data['ic7']['nominal_RC_rates_Hz']['I']
    ax.plot([lo,hi],[0,0],linewidth=8,color='#3274A1',label='BOM C21 ±5% alone')
    ax.scatter([nominal,385.469],[0,0],marker='|',s=300,color=['#D55E00','#555555'])
    ax.annotate('Nominal RC',xy=(nominal,0),xytext=(nominal,.16),ha='center')
    ax.annotate('Cabinet assigned I',xy=(385.469,0),xytext=(385.469,-.22),ha='center')
    ax.set(xlabel='IC7 rate (Hz)',ylim=(-.4,.4),yticks=[],title='C21 tolerance covers the assigned cabinet rate')
    ax.legend(loc='upper right',fontsize=8);ax.grid(axis='x',alpha=.2)
    fig.suptitle('Turbo player-car: diagnostic hypotheses; nominal components, no cabinet fit',fontsize=13)
    fig.savefig(destination/'playercar_vca_ic7_upstream_20260930.png',dpi=160)
    plt.close(fig)


if __name__=='__main__':main()
