#!/usr/bin/env python3
"""Joint D8 ramp/Schmitt diagnosis using published device timing curves.

No RTL edits or cabinet-fit constants. TI SLOA277B Figure 6-1/3/4 curves
are extracted from vector paths, not estimated from cabinet sound. They
describe legacy LM358 class behavior, not characterized 1982 LM2902N or
Fairchild uA324PC silicon. Recovery-progress integration is an explicitly
unvalidated extension of step-input measurements to a ramp input.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import pymupdf
from scipy.io import wavfile
from scipy.signal import resample_poly
import playercar_fast_model as M
import playercar_d8_ic17_reference as R
import playercar_brightness_diagnose as B
from playercar_ic7_device_tolerance import CELLS, rate
from playercar_vco_upstream_diagnose import tr6_table
from playercar_vca_loading_diagnose import Input, coupled_or


def path_points(drawing):
    result=[]
    for item in drawing['items']:
        if item[0]=='l':
            result.extend([(p.x,p.y) for p in item[1:]])
        elif item[0]=='c':
            p=np.array([(v.x,v.y) for v in item[1:]])
            t=np.linspace(0,1,101)[:,None]
            curve=(1-t)**3*p[0]+3*(1-t)**2*t*p[1]+3*(1-t)*t**2*p[2]+t**3*p[3]
            result.extend(curve.tolist())
        else: raise ValueError('Unexpected timing-curve path item')
    return np.array(result)


def blue_curves(page):
    return [d for d in page.get_drawings() if d['color'] and
            d['color'][2]-d['color'][0]>.3 and d['rect'].width>200]


def curves(pdf):
    doc=pymupdf.open(pdf)
    # Plot-coordinate calibration uses the vector grid bounds inspected
    # alongside the complete relevant pages. PDF indices 23 and 25.
    p=path_points(blue_curves(doc[23])[0])
    cm=(p[:,0]-144.5706177)/(520.0012817-144.5706177)*28
    delay=(631.8699951-p[:,1])/(631.8699951-430.3382263)*100e-6
    source={
        'source':'https://www.ti.com/lit/an/sloa277b/sloa277b.pdf',
        'sha256':hashlib.sha256(Path(pdf).read_bytes()).hexdigest(),
        'scope':'Legacy LM358-class measured curves; VCC=30V for recovery Figure 6-1. Not a characterized Fairchild or old National model.',
        'recovery_common_mode_v':cm.tolist(),'recovery_base_s':delay.tolist(),
    }
    for name,drawing,box,full in (
        ('recovery',blue_curves(doc[25])[0],(175.4824982,460.8098145,59.6049194,213.1175537),7),
        ('slew',blue_curves(doc[25])[1],(178.2906342,459.4070129,489.9138184,652.4750366),1)):
        p=path_points(drawing);left,right,top,bottom=box
        order=np.argsort(p[:,0]);p=p[order]
        x=10**(-2+2*(p[:,0]-left)/(right-left))
        y=full*(bottom-p[:,1])/(bottom-top)
        # The PDF includes off-plot Bezier continuation. Retain only the
        # plotted 10mV..1V range, including interpolated edge values.
        grid=np.geomspace(.01,1.,121)
        source[name+'_vid_v']=grid.tolist()
        source[name+'_factor']=np.interp(grid,x,y).tolist()
    source['figure_check']={
        'low_recovery_10V_us':float(np.interp(10,cm,delay)*1e6),
        'recovery_multiplier_20mV':float(np.interp(.020,source['recovery_vid_v'],source['recovery_factor'])),
        'slew_factor_10mV':float(source['slew_factor'][0]),
        'slew_factor_100mV':float(np.interp(.1,source['slew_vid_v'],source['slew_factor'])),
    }
    return source


def mc3340_curve(pdf):
    """Motorola Figure 3 solid 12V curve, original vector geometry.

    Indices refer to the saved four-page MC3340/D source. The figure
    labels mask parts of other voltage curves but not these 12V segments.
    Flat curve height defines its 0dB reference to avoid ~0.7dB stroke
    alignment error relative to the axis grid. Beyond its drawn ~90dB
    endpoint attenuation is held, not fitted or extrapolated to a cabinet.
    """
    d=pymupdf.open(pdf)[2].get_drawings()
    p=np.vstack([path_points(d[k]) for k in (36,38,147)])
    p=p[np.argsort(p[:,0])]
    x=1.5+5*(p[:,0]-86.2870026)/(289.8139954-86.2870026)
    attenuation=(p[:,1]-80.0499878)/(209.9340210-79.1430054)*100
    x=np.r_[1.5,x];attenuation=np.maximum(np.r_[0,attenuation],0)
    grid=np.arange(1.5,6.5001,.025)
    attenuation=np.interp(grid,x,attenuation)
    return dict(source='Motorola MC3340/D Figure 3 solid VCC=12V curve',
                sha256=hashlib.sha256(Path(pdf).read_bytes()).hexdigest(),
                control_v=grid.tolist(),attenuation_db=attenuation.tolist(),
                warning='Representative MC3340 curve, not MB4391 measurement. Plot stroke/digitization is approximate; out-of-range attenuation is held.')


def gain_from_curve(control,source):
    return 10**(-np.interp(control,source['control_v'],source['attenuation_db'])/20)


def simulate(bus,parts,drive,source,*,recovery=True,slew=True,high=10.5,low=0.,dt=.25e-6):
    """Separate source-curve recovery from slew; neither is a fixed delay.

    Recovery progress integrates reciprocal instantaneous step delay.
    Below the plotted 10mV, reciprocal delay and slew are continued
    proportionally to |VID|. No zero-overdrive finite switch is allowed.
    The extension is a hypothesis; published curves do not specify ramp
    history, transistor storage, or simultaneous output load dynamics.
    """
    ri,rs,c=parts;voltage,collector,_=drive
    rf=51000/(151000);b=bus/2
    signal=5.75;out=low;state=False;progress=0.
    cmx=np.array(source['recovery_common_mode_v']);cmy=np.array(source['recovery_base_s'])
    rx=np.array(source['recovery_vid_v']);ry=np.array(source['recovery_factor'])
    sx=np.array(source['slew_vid_v']);sy=np.array(source['slew_factor'])
    duration=max(.10,4/rate(bus,*parts));steps=int(duration/dt)
    history=np.empty((steps,3));edges=[];events=[]
    crossing_start=None
    for j in range(steps):
        plus=6*(1-rf)+out*rf
        diff=plus-signal;newstate=diff>0;av=abs(diff)
        small=min(av/.01,1.)
        if newstate!=state:
            if crossing_start is None:crossing_start=j
            if recovery:
                factor=float(np.interp(av,rx,ry))
                base=2e-6 if state else float(np.interp(plus,cmx,cmy))
                progress+=dt*small/(base*factor)
            else:progress=1.
            if progress>=1.:
                state=newstate;progress=0.
                events.append(((j-crossing_start)*dt*1e6,'rise' if state else 'fall'))
                crossing_start=None
        else:
            progress=0.;crossing_start=None
        target=high if state else low
        if slew:
            speed=.5e6*float(np.interp(av,sx,sy))*small
            out+=max(-speed*dt,min(speed*dt,target-out))
        else:out=target
        vc=float(np.interp(out,voltage,collector))
        signal+=((b-vc)/rs-(bus-b)/ri)/c*dt
        history[j]=(signal,out,vc)
        if j and history[j-1,1]<5<=out:edges.append(j)
    if len(edges)<3:raise RuntimeError('Too few settled cycles')
    start,end=edges[-2:];wave=history[start:end];period=(end-start)*dt
    phase=np.linspace(0,1,len(wave),endpoint=False)
    dense=np.linspace(0,1,4096,endpoint=False)
    cycle=np.column_stack([np.interp(dense,phase,wave[:,i]) for i in range(3)])
    z=np.fft.rfft(cycle[:,0]-cycle[:,0].mean())
    h={str(k):float(20*np.log10(max(abs(z[k]),1e-20)/abs(z[1]))) for k in range(2,13)}
    waits={name:float(np.mean([t for t,n in events[-6:] if n==name])) for name in ('rise','fall')}
    return cycle,dict(rate_Hz=1/period,triangle_min_v=float(wave[:,0].min()),triangle_max_v=float(wave[:,0].max()),
                      rise_recovery_wait_us=waits['rise'],fall_recovery_wait_us=waits['fall'],
                      harmonics_dBc=h,dt_us=dt*1e6,recovery=recovery,slew=slew,high=high,low=low,
                      warning='Joint legacy-class sensitivity, not characterized board silicon.')


def ideal_cycle():
    phase=np.arange(4096)/4096
    rf=51000/151000
    lo=6*(1-rf);hi=lo+10.5*rf
    result={}
    for key,(ri,rs,_) in CELLS.items():
        rising=1/(ri/rs) # ratio of rise time to entire period
        # First half is rising. Falling time fraction is 1-rising.
        y=np.where(phase<rising,lo+(hi-lo)*phase/rising,
                   hi-(hi-lo)*(phase-rising)/(1-rising))
        result[key]=np.column_stack((y,np.zeros_like(y),np.zeros_like(y)))
    return result


def waveform(cycle,hz,n,phase0):
    grid=np.arange(len(cycle))/len(cycle)
    return np.interp((np.arange(n)*hz/M.FS+phase0)%1,np.r_[grid,1.],np.r_[cycle[:,0],cycle[0,0]])


def product_strengths(power,rates):
    t,i,s=rates['T'],rates['I'],rates['S']
    products={'T':t,'I':i,'S':s,'I-T':i-t,'2S':2*s,'T-S':t-s,
              'T+S':t+s,'I-S':i-s,'I+S':i+s,'I+2S':i+2*s,
              '2I-T':2*i-t,'2I-S':2*i-s,'2I+S':2*i+s,'T+I':t+i}
    return {key:dict(hz=float(hz),power_dB_re_250_900=B.db_power(B.line(power,abs(hz))/B.anchor(power)))
            for key,hz in products.items()}


def compare_audio(cycles,rates,tab,out,attenuation):
    n=6*48000;device=Input(tab);ideal=ideal_cycle()
    phases=dict(zip(('T','S','I'),np.random.default_rng(1).random(3)))
    spectra={};table={};waves={}
    # Rate-only and shape-only controls keep causes separable. Every
    # model is rendered, not just the one closest to the cabinet.
    nominal={key:float(rate(R.ladder_v(42)*R.BUS_LOADED,*parts)) for key,parts in CELLS.items()}
    variants={'ideal':(ideal,nominal)}
    for case in cycles:
        variants[case+'_rate_only']=(ideal,rates[case])
        variants[case+'_shape_only']=(cycles[case],nominal)
        variants[case+'_both']=(cycles[case],rates[case])
    variants['original_vector_MC3340_curve']=(ideal,nominal)
    variants['original_vector_MC3340_curve_Rs100']=(ideal,nominal)
    variants['original_vector_MC3340_curve_Rs1_limit']=(ideal,nominal)
    variants['original_vector_MC3340_curve_slew_shape']=(cycles['slew_curve'],nominal)
    variants['original_vector_MC3340_curve_recovery_shape']=(cycles['recovery_and_slew_curves'],nominal)
    variants['original_vector_MC3340_curve_recovery_both']=(cycles['recovery_and_slew_curves'],rates['recovery_and_slew_curves'])
    for name,(shape,frequencies) in variants.items():
        y={key:waveform(shape[key],frequencies[key],n,phases[key]) for key in CELLS}
        rs=100. if name.endswith('_Rs100') else 1. if name.endswith('_Rs1_limit') else 1000.
        vin,ledger=coupled_or(y['T'],y['S'],device,rs=rs)
        # Re-center the IC7 C6 input by its own derived cycle mean.
        # Existing diode clamp and published 12V gain table stay fixed.
        cont=R.clamp_dc(R.ladder_v(42)*R.BUS_LOADED)+shape['I'][:,0].mean()-y['I']
        gate=gain_from_curve(cont,attenuation) if name.startswith('original_vector') else R.mc3340_gain(cont)
        audio=-(vin-vin.mean())*gate
        p=B.spectrum(resample_poly(audio,1,3)[2*B.FS:6*B.FS])
        spectra[name]=p
        table[name]=dict(rates_Hz=frequencies,
            products=product_strengths(p,frequencies),
            bands_dB={f'{lo}-{hi}':B.db_power(B.band(p,lo,hi)/B.anchor(p)) for lo,hi in B.BANDS},
            sidebands_dB={f'{k}I_minus_S_vs_plus_S':B.db_power(B.line(p,k*frequencies['I']-frequencies['S'])/
                  max(B.line(p,k*frequencies['I']+frequencies['S']),1e-30)) for k in (1,2,3)},
            upper_input_ac_rms=ledger['vin_ac_rms'],
            source_impedance_ohm=rs,input_node_kcl_max_A=ledger['max_kcl_error_A'],
            signed_I_minus_T_minus_2S=frequencies['I']-frequencies['T']-2*frequencies['S'])
        if name=='ideal' or name.endswith('_both') or name.startswith('original_vector'):
            wavfile.write(out/(name+'.wav'),48000,np.asarray(audio/max(abs(audio).max(),1e-12)*.85*32767,dtype='<i2'))
        if name=='ideal' or name.endswith('_shape_only') or name=='original_vector_MC3340_curve':waves[name]=p
    recording=B.decode(B.ROOT.parent/'turbo/docs/reference/turbo_cabinet_recording.weba')
    median=np.median([B.spectrum(recording[(sec-B.START)*B.FS:(sec-B.START+4)*B.FS]) for sec in B.BACKGROUND],axis=0)
    for sec in (748,763):
        p=np.maximum(B.spectrum(recording[(sec-B.START)*B.FS:(sec-B.START+4)*B.FS])-median,0)
        table['cab%d'%sec]={'bands_dB':{f'{lo}-{hi}':B.db_power(B.band(p,lo,hi)/B.anchor(p)) for lo,hi in B.BANDS}}
        table['cab%d'%sec]['products']=product_strengths(p,dict(zip(('T','I','S'),map(float,B.CAB_RATES))))
        waves['cab%d'%sec]=p
    return table,waves


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=Path('sim/out/vco_joint_20260930'))
    ap.add_argument('--pdf',type=Path,default=Path('sim/out/vco_joint_20260930/sloa277b.pdf'))
    ap.add_argument('--timing-only',action='store_true')
    ap.add_argument('--audio-only',action='store_true',help='Reuse completed ramp cycles for downstream source-curve comparison')
    ap.add_argument('--cap-bounds',action='store_true',help='Check timing-cap +/-5% endpoints with the same recovery/slew curves')
    ap.add_argument('--save-evidence',action='store_true',help='Save completed JSON and figures into docs/evidence')
    ap.add_argument('--evidence-only',action='store_true',help='Save existing completed results without rerunning models')
    a=ap.parse_args();a.out.mkdir(parents=True,exist_ok=True)
    if a.evidence_only:
        save_evidence(a.out);return
    source=curves(a.pdf)
    (a.out/'published_timing_curves.json').write_text(json.dumps(source,indent=2)+'\n')
    attenuation=mc3340_curve(Path('../turbo/docs/reference/MC3340.pdf'))
    (a.out/'MC3340_original_12V_curve.json').write_text(json.dumps(attenuation,indent=2)+'\n')
    allcases={};cycles={};rates={}
    if a.audio_only:
        report=json.loads((a.out/'joint_vco_curve_metrics.json').read_text())
        allcases=report['timing']
        for case in ('instant_drive','slew_curve','recovery_and_slew_curves'):
            with np.load(a.out/(case+'_cycles.npz')) as saved:cycles[case]={key:saved[key] for key in CELLS}
            rates[case]={key:allcases['42'][case][key]['rate_Hz'] for key in CELLS}
    for acc in (() if a.audio_only else (39,41,42)):
        bus=R.ladder_v(acc)*R.BUS_LOADED
        drives={key:tr6_table(bus,rsink=parts[1]) for key,parts in CELLS.items()}
        allcases[str(acc)]={'nominal_ideal_rates_Hz':{key:float(rate(bus,*parts)) for key,parts in CELLS.items()}}
        for case,recovery,slew in (('instant_drive',False,False),('slew_curve',False,True),('recovery_and_slew_curves',True,True)):
            results={};shapes={}
            for key,parts in CELLS.items():
                shapes[key],results[key]=simulate(bus,parts,drives[key],source,recovery=recovery,slew=slew)
            allcases[str(acc)][case]=results
            if acc==42:
                cycles[case]=shapes;rates[case]={key:r['rate_Hz'] for key,r in results.items()}
            print('ACC',acc,case,{key:round(r['rate_Hz'],3) for key,r in results.items()},flush=True)
    if not a.audio_only:
        bus=R.ladder_v(42)*R.BUS_LOADED
        _,half=simulate(bus,CELLS['I'],tr6_table(bus),source,dt=.125e-6)
        report=dict(assumptions=__doc__,source_curve_check=source['figure_check'],timing=allcases,IC7_half_step_check=half,
                caveats=['Output high/low fixed at existing 10.5/0 V reference, not solved from simultaneous transistor loads.',
                         'TI curves are not Fairchild data. Same-device joint cases test sensitivity, not the exact board.',
                         'Integrator bandwidth, transistor charge storage and input-bias offset remain separate omissions.'])
    if a.cap_bounds:
        report['timing_cap_5percent_endpoints']={}
        bus=R.ladder_v(42)*R.BUS_LOADED
        for key,parts in CELLS.items():
            drive=tr6_table(bus,rsink=parts[1]);endpoints=[]
            for scale in (.95,1.05):
                _,result=simulate(bus,(*parts[:2],parts[2]*scale),drive,source)
                endpoints.append(dict(cap_scale=scale,rate_Hz=result['rate_Hz']))
            report['timing_cap_5percent_endpoints'][key]=endpoints
            print('CAP ENDPOINTS',key,endpoints,flush=True)
    if not a.timing_only:
        tab=json.loads(Path('sim/out/vca_ic7_20260930/mc3340_on_transfer.json').read_text())[1]
        report['audio'],spectra=compare_audio(cycles,rates,tab,a.out,attenuation)
        report['MC3340_curve_checks']={str(v):dict(original_curve_db=float(np.interp(v,attenuation['control_v'],attenuation['attenuation_db'])),
            existing_table_db=float(-20*np.log10(R.mc3340_gain(v)))) for v in (3.,3.15,3.5,4.,4.5,5.)}
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        fig,axes=plt.subplots(2,2,figsize=(12,8),layout='constrained')
        ax=axes[0,0]
        for name in cycles:
            ax.plot(np.arange(4096)/4096,cycles[name]['I'][:,0],label=name)
        ax.set(xlabel='Cycle fraction',ylabel='IC7 integrator V',title='Nominal timing parts; different transition hypotheses')
        ax.legend(fontsize=8);ax.grid(alpha=.2)
        ax=axes[0,1]
        for case in ('nominal_ideal_rates_Hz','instant_drive','slew_curve','recovery_and_slew_curves'):
            yy=[allcases[str(acc)][case]['I'] if case=='nominal_ideal_rates_Hz' else allcases[str(acc)][case]['I']['rate_Hz'] for acc in (39,41,42)]
            ax.plot((39,41,42),yy,'o-',label=case)
        ax.set(xlabel='ACC',ylabel='IC7 Hz',title='Curves specify class sensitivity, not exact chip timing')
        ax.legend(fontsize=8);ax.grid(alpha=.2)
        ax=axes[1,0];ff=np.arange(len(next(iter(spectra.values()))))*.25
        for name,p in spectra.items():
            ax.plot(ff,10*np.log10(np.maximum(p/B.anchor(p),1e-15)),label=name,alpha=.7,linewidth=.7)
        ax.set(xlabel='Hz',ylabel='Power relative to 250–900 Hz (dB)',xlim=(250,3000),ylim=(-65,0),title='Shape-only comparison keeps all oscillator rates fixed')
        ax.legend(fontsize=7);ax.grid(alpha=.2)
        ax=axes[1,1]
        names=['ideal']+[key+'_shape_only' for key in cycles]+['original_vector_MC3340_curve','cab748','cab763']
        ax.barh(names,[report['audio'][name]['bands_dB']['900-3000'] for name in names])
        ax.set(xlabel='900–3000 / 250–900 Hz power (dB)',title='Reversal dynamics versus observed brightness')
        ax.tick_params(axis='y',labelsize=7);ax.grid(axis='x',alpha=.2)
        fig.suptitle('Player-car VCO switching: source-curve diagnostic, no cabinet-fit parameters')
        fig.savefig(a.out/'joint_vco_curves.png',dpi=150);plt.close(fig)
        fig,axes=plt.subplots(1,2,figsize=(11,4),layout='constrained')
        cv=np.linspace(2.75,5.5,551)
        axes[0].plot(cv,-20*np.log10(R.mc3340_gain(cv)),label='Existing table')
        axes[0].plot(cv,np.interp(cv,attenuation['control_v'],attenuation['attenuation_db']),label='Motorola 12 V solid curve')
        axes[0].set(xlabel='CONT voltage (V)',ylabel='Attenuation (dB)',title='Published curve changes the gate shape')
        axes[0].legend(fontsize=8);axes[0].grid(alpha=.2)
        names=['ideal','original_vector_MC3340_curve','original_vector_MC3340_curve_recovery_shape','cab748','cab763']
        labels=['Existing law','Original curve','Curve + recovery shape','Cabinet 748 s','Cabinet 763 s']
        axes[1].barh(labels,[report['audio'][name]['bands_dB']['900-3000'] for name in names])
        axes[1].set(xlabel='900–3000 / 250–900 Hz power (dB)',title='HF excess remains after electrical changes')
        axes[1].grid(axis='x',alpha=.2)
        fig.savefig(a.out/'original_vca_curve_comparison.png',dpi=160);plt.close(fig)
    for key in cycles:
        np.savez_compressed(a.out/(key+'_cycles.npz'),**cycles[key])
    (a.out/'joint_vco_curve_metrics.json').write_text(json.dumps(report,indent=2)+'\n')
    if a.save_evidence:save_evidence(a.out)
    print('SOURCE CHECK',source['figure_check'])
    print('REPORT',a.out/'joint_vco_curve_metrics.json')


def save_evidence(out):
    import shutil
    destination=Path(__file__).resolve().parents[1]/'docs/evidence'
    destination.mkdir(parents=True,exist_ok=True)
    data={name:json.loads((out/file).read_text()) for name,file in (
        ('joint','joint_vco_curve_metrics.json'),('timing_curves','published_timing_curves.json'),
        ('MC3340_12V_curve','MC3340_original_12V_curve.json'))}
    data['VCA_with_original_curve']=json.loads((out/'vca_original_curve/vca_loading_diagnosis.json').read_text())
    data['TI_model_audit']={'download':'https://www.ti.com/lit/zip/sglm009',
        'sha256':'816b9a73a5cdd5986c783000acfc276dcbf8f2e6427e3a26fcc148f026c337ec',
        'method':'Source inspection only, no SPICE execution.',
        'observation':'Fixed +/-1.2 V recovery clamp sources relative to VCLP; no explicit VIN+ + 1.3 V compensation-node overload law. Not demonstrated equivalent to application-note common-mode-dependent recovery.'}
    (destination/'playercar_vco_source_curve_metrics_20260930.json').write_text(json.dumps(data,indent=2)+'\n')
    shutil.copyfile(out/'joint_vco_curves.png',destination/'playercar_vco_source_curve_joint_20260930.png')
    shutil.copyfile(out/'original_vca_curve_comparison.png',destination/'playercar_vca_original_curve_comparison_20260930.png')


if __name__=='__main__':main()
