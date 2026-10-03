#!/usr/bin/env python3
"""Physical-voltage BSEL2 reference, diagnosis only; no cabinet-fit parameters.

Exact external coupling/load networks with explicit device hypotheses. The
historical bias-diode transfer is NOT validated full MC3340/MB4391 silicon.
Cabinet recordings validate relative spectral patterns, not absolute volts.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
import pymupdf
from scipy.sparse.linalg import LinearOperator, gmres
from scipy.signal import resample_poly
from scipy.io import wavfile
import playercar_fast_model as M
import playercar_d8_ic17_reference as R
import playercar_brightness_diagnose as B
from playercar_ic7_device_tolerance import CELLS, rate
from playercar_vca_loading_diagnose import Input
from playercar_vco_curve_check import mc3340_curve, gain_from_curve, path_points
from playercar_absolute_gain_diagnose import output_network
from playercar_level_pattern_probe import freqs, CAB
from playercar_mc3340_physical_table import Input2D

ROOT=Path(__file__).resolve().parents[1]
FS=48000
GMAX=10**(13/20)


def filt(x,h):return np.fft.irfft(np.fft.rfft(x)*h,n=len(x))

def rin_of(device):
    return device.reference_rin if hasattr(device,'reference_rin') else float(1/device.deriv(device.tab['bias']))


def stats(x):
    y=x[2*FS:6*FS]
    return dict(mean_v=float(y.mean()),ac_rms_v=float(y.std()),
                min_v=float(y.min()),max_v=float(y.max()))


def nonlinear_coupling(source,h,z,device,initial=None):
    """Periodic KCL with DC charge fixed by zero average input current.

    H,Z describe the loaded linear network using incremental Rin as a
    preconditioner. This changes no circuit values; nonlinear input current
    remains in the residual. DC charge is solved, never per-control centered.
    """
    bias=device.tab['bias'];rin=rin_of(device)
    linear=filt(source,h);z=z.copy();z[0]=rin
    v=bias+linear if initial is None else initial.copy()
    def residual(v):return v-bias-linear+filt(device.current(v)-(v-bias)/rin,z)
    for iteration in range(25):
        r=residual(v);error=float(np.max(abs(r)))
        if error<2e-8:break
        slope=device.deriv(v)-1/rin
        jac=LinearOperator((len(v),len(v)),matvec=lambda dv:dv+filt(slope*dv,z))
        pre=LinearOperator((len(v),len(v)),matvec=lambda dv:dv/(1+z[-1].real*slope))
        delta,status=gmres(jac,-r,M=pre,rtol=1e-8,atol=1e-10,restart=20,maxiter=20)
        if status:raise RuntimeError('Coupling Newton linear solve failed: '+str(status))
        step=1.
        while np.max(abs(residual(v+step*delta)))>=error and step>1/1024:step*=.5
        v+=step*delta
    else:raise RuntimeError('Nonlinear coupling did not converge: '+str(error))
    return v,dict(iterations=iteration+1,max_voltage_residual_v=error,
        mean_cap_current_A=float(device.current(v).mean()),incremental_rin_ohm=float(rin),
        outside_device_table_samples=int(np.sum((v<device.v[0])|(v>device.v[-1]))))


def coupled_or(t,s,hz,device):
    """Two generic MA150 junctions, R79=10k, C76=10uF, VCA input KCL.

    Generic junction IS=1.8nA,N=1.9 at 25C is an assumption. Sources are
    ideal low-impedance integrator outputs, not a fictitious 1k board part.
    """
    sj=2j*np.pi*hz;rin=rin_of(device)
    h=sj*10e-6*rin/(1+sj*10e-6*rin);z=rin/(1+sj*10e-6*rin)
    v=np.full(len(t),device.tab['bias']);node=np.maximum(t,s)-.7
    vt=.02585*1.9;isat=1.8e-9
    for outer in range(30):
        current=device.current(v)
        for _ in range(15):
            it=isat*np.exp(np.clip((t-node)/vt,-60,50))
            isu=isat*np.exp(np.clip((s-node)/vt,-60,50))
            residual=it+isu-2*isat-node/10000-current
            node+=residual/((it+isu)/vt+1/10000)
        new,diag=nonlinear_coupling(node,h,z,device,initial=v)
        error=float(np.max(abs(new-v)))
        v=.5*(v+new)
        if error<2e-7:break
    else:raise RuntimeError('Diode-OR coupling did not converge')
    diag.update(outer_iterations=outer+1,max_pin_change_v=error,
                max_diode_node_kcl_error_A=float(np.max(abs(residual))),
                mean_C76_charge_voltage_v=float(np.mean(node-new)))
    return new,node,diag


def interstage(hz,rin,ron=300.,c106=22e-6):
    """Rout200+Ron -> 51k||51k -> C106 -> R155100k -> C1012.2u -> pin."""
    sj=2j*np.pi*hz;rs=200+ron;rb=25500.;rx=100000.
    za=1/(1/rs+1/rb)
    # Algebra stays finite at DC (coupling capacitors are open).
    open_h=rb/(rs+rb)*(sj*c106*rx)/(1+sj*c106*(rx+za))
    zx=rx*(1+sj*c106*za)/(1+sj*c106*(rx+za))
    adm=sj*2.2e-6/(1+sj*2.2e-6*zx)
    h=open_h*adm/(adm+1/rin)
    z=1/(adm+1/rin)
    return h,z


def distortion_curve(pdf):
    draws=pymupdf.open(pdf)[2].get_drawings()
    p=np.vstack([path_points(draws[k]) for k in (140,141,142)])
    p=p[np.argsort(p[:,0])]
    x=80*(p[:,0]-216.85)/(420.208-216.85)
    y=4*(640.857-p[:,1])/(640.857-509.272)
    grid=np.arange(0,50.01,.5)
    return dict(source='Motorola MC3340/D Figure 7, plotted typical stroke',
        sha256=hashlib.sha256(Path(pdf).read_bytes()).hexdigest(),
        attenuation_db=grid.tolist(),THD_percent=np.interp(grid,x,y).tolist(),
        conditions='Later curve: eo=2.5 Vrms,f=1kHz,0dB reference13dB. Original1976 header VCC16V. Test interpretation unresolved.')


def pattern(power,rates):
    fr=freqs(*rates)
    values={name:B.db_power(B.line(power,hz,1.2)) for name,hz in fr.items()}
    ref=values['2I-T']
    return {name:value-ref for name,value in values.items()}


def error(a,b):
    d=np.array([a[name]-b[name] for name in CAB]);d-=d.mean()
    return float(np.sqrt(np.mean(d*d)))


def render(tab,curve,*,ron=300,c106=22e-6,kind='historical',dc=True,quantized=False,joint=None,phases=(.51182,.14416,.95046)):
    time=np.arange(8*FS)/FS;hz=np.fft.rfftfreq(len(time),1/FS)
    bus=R.ladder_v(42)*R.BUS_LOADED
    rates=np.array([rate(bus,*CELLS[name]) for name in ('T','I','S')])
    tri=lambda f,ratio,phase:M.tri((time*f+phase)%1,ratio)
    t=tri(rates[0],1.25,phases[0]);s=tri(rates[2],220/100-1,phases[1])
    tri7=tri(rates[1],150/68-1,phases[2])
    sj=2j*np.pi*hz
    hp6=sj*22e-6*10000/(1+sj*22e-6*10000)
    cont=R.clamp_dc(bus)-filt(tri7,hp6)
    gain=gain_from_curve(cont,curve);g2=float(gain_from_curve(3.15,curve))
    if quantized:
        gain=np.round(gain*2**24)/2**24;g2=round(g2*2**24)/2**24
        if joint is not None:
            joint=dict(joint,vout=(np.round(np.array(joint['vout'])*65536)/65536).tolist(),
                       input_current=(np.round(np.array(joint['input_current'])*2**36)/2**36).tolist())
    if joint is not None:
        device=Input2D(joint,-20*np.log10(gain));device2=Input2D(joint,-20*np.log10(g2))
    else:device=Input(tab);device2=device
    pin1,node,diag1=coupled_or(t,s,hz,device)
    rin=rin_of(device2);h,z=interstage(hz,rin,ron,c106)
    roll=1/(1+sj*6200*680e-12)
    def vca(pin,g,dev):
        if quantized:
            pin=np.round(pin*65536)/65536;g=np.round(g*2**24)/2**24
        if joint is not None:out=dev.output(pin)
        elif kind=='linear':out=tab['off_dc']-GMAX*(pin-tab['bias'])*g
        elif kind=='tanh':out=tab['off_dc']+3.65*np.tanh(-GMAX*(pin-tab['bias'])*g/3.65)
        else:
            out=tab['off_dc']+g*(device.output(pin)-(tab['off_dc'] if dc else tab['on_dc']))
        if quantized:out=np.round(out*65536)/65536
        return out
    out1=filt(vca(pin1,gain,device),roll)
    pin2,diag2=nonlinear_coupling(out1,h,z,device2)
    out2=filt(vca(pin2,g2,device2),roll)
    network=output_network(hz,ron=ron,ic28_rout=200.)
    stages=dict(node=node,pin1=pin1,cont=cont,out1=out1,pin2=pin2,out2=out2)
    for name,index in (('divider',1),('F',2),('W',3),('M',4)):
        stages[name]=filt(out2,network[:,index,1])
    report=dict(rates_Hz=rates.tolist(),bus_v=bus,kind=kind,DC=dc,Ron_ohm=ron,C106_F=c106,
        stage1_coupling=diag1,stage2_coupling=diag2,stage_voltages={k:stats(v) for k,v in stages.items()},initial_phases=phases,
        physical_selected_IC28_control_V=3.15,selected_relative_gain=g2,
        VCA_hypothesis=(joint or tab).get('warning'),R219_R220_FWM_midband=network[-1,1:,1].real.tolist())
    return stages,report


def slf_check(joint,curve):
    time=np.arange(8*FS)/FS;hz=np.fft.rfftfreq(len(time),1/FS);sj=2j*np.pi*hz
    vl=R.ladder_v(42);f3=rate(vl,270000,120000,.1e-6);f5=rate(vl,150000,68000,.1e-6)
    tri=lambda f,ratio: M.tri((time*f+.271)%1,ratio)-(M.TH_HI+M.TH_LO)/2
    signal=tri(f3,1.25)*10/49
    control=12*2.7/10.9-2/3*filt(tri(f5,150/68-1),sj*.000022*15000/(1+sj*.000022*15000))
    att=-20*np.log10(gain_from_curve(control,curve));dev=Input2D(joint,att)
    rin=rin_of(dev);rs=1/(1/39000+1/10000);cap=10e-6
    h=sj*cap*rin/(1+sj*cap*(rs+rin));z=rin*(1+sj*cap*rs)/(1+sj*cap*(rs+rin))
    pin,diag=nonlinear_coupling(signal,h,z,dev)
    out=filt(dev.output(pin),1/(1+sj*6200*680e-12))
    w=filt(out,output_network(hz,ron=300.,ic28_rout=200.)[:,3,0])
    p=B.spectrum(resample_poly(w,1,3)[2*B.FS:6*B.FS])
    diag.update(f3_Hz=f3,f5_Hz=f5,pin=stats(pin),W=stats(w),
        f5_vs_f3_dB=B.db_power(B.line(p,f5)/B.line(p,f3)),
        line_rms_v={name:float(np.sqrt(B.line(p,hz))) for name,hz in
                    {'f3':f3,'f5':f5,'f5-f3':f5-f3,'f5+f3':f5+f3}.items()})
    return diag


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'sim/out/physical_vca_20260930')
    args=ap.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    tabs=json.loads((args.out/'corrected_on_transfer.json').read_text())
    joint=json.loads((args.out/'corrected_2D_transfer.json').read_text())
    device_probes=json.loads((args.out/'corrected_device_validation.json').read_text())
    source=ROOT.parent/'turbo/docs/reference/MC3340.pdf'
    curve=mc3340_curve(source);fig7=distortion_curve(source)
    (args.out/'MC3340_Figure7_curve.json').write_text(json.dumps(fig7,indent=2)+'\n')
    rec=B.decode(ROOT.parent/'turbo/docs/reference/turbo_cabinet_recording.weba')
    median=np.median([B.spectrum(rec[(sec-B.START)*B.FS:(sec-B.START+4)*B.FS]) for sec in B.BACKGROUND],axis=0)
    allpower={};results={}
    for sec in (748,763):
        raw=B.spectrum(rec[(sec-B.START)*B.FS:(sec-B.START+4)*B.FS])
        allpower[f'cab{sec}_raw']=raw;allpower[f'cab{sec}_residual']=np.maximum(raw-median,0)
    native=device_probes[2]['control_curve']
    native_curve=dict(control_v=[x['control_v'] for x in native],attenuation_db=[x['attenuation_db'] for x in native])
    for name,index,kind,dc in (('joint_Figure3_mapped',2,'joint',True),('joint_native_control',2,'joint_native',True),
        ('historical_bias_diode',2,'historical',True),('later_drawing',0,'historical',True),
        ('linear_signal_nonlinear_input',2,'linear',False),('two_tanh_reference',2,'tanh',False)):
        stages,diag=render(tabs[index],native_curve if kind=='joint_native' else curve,kind=kind,dc=dc,
                           joint=joint if kind.startswith('joint') else None)
        y=resample_poly(stages['W'],1,3);p=B.spectrum(y[2*B.FS:6*B.FS]);allpower[name]=p
        diag['pattern_dB_re_2IminusT']=pattern(p,diag['rates_Hz'])
        diag['old_manual_pattern_error_dB']=error(diag['pattern_dB_re_2IminusT'],CAB)
        diag['cabinet_pattern_error_dB']={key:error(diag['pattern_dB_re_2IminusT'],pattern(v,B.CAB_RATES)) for key,v in allpower.items() if key.startswith('cab')}
        results[name]=diag
        # One physical PCM scale for every candidate: 4V per full scale.
        peak=float(np.max(abs(stages['W'])));assert peak<4,'WAV scaling clipped'
        wavfile.write(args.out/(name+'_W.wav'),FS,np.round(stages['W']/4*32767).astype('<i2'))
        if name=='joint_Figure3_mapped':
            np.savez_compressed(args.out/'physical_voltages.npz',**stages)
            reference_stages=stages
        print(name,diag['old_manual_pattern_error_dB'],diag['cabinet_pattern_error_dB'],diag['stage_voltages']['W'],flush=True)
    quantized,qdiag=render(tabs[2],curve,kind='joint',quantized=True,joint=joint)
    qerr=quantized['W']-reference_stages['W']
    qp=B.spectrum(resample_poly(quantized['W'],1,3)[2*B.FS:6*B.FS])
    report=dict(scope=__doc__,cases=results,
        cabinet_patterns={key:pattern(v,B.CAB_RATES) for key,v in allpower.items() if key.startswith('cab')},
        quantization_check=dict(scope='Q16 pin/output voltages and transfer table, Q24 gain coordinates, Q36 table input current; filters/coupling remain float. Not an RTL equivalence test.',
            max_W_error_v=float(np.max(abs(qerr))),W_error_rms_v=float(qerr.std()),
            max_line_pattern_error_dB=float(max(abs(pattern(qp,qdiag['rates_Hz'])[k]-results['joint_Figure3_mapped']['pattern_dB_re_2IminusT'][k]) for k in CAB))),
        Figure7_extracted_samples={str(a):float(np.interp(a,fig7['attenuation_db'],fig7['THD_percent'])) for a in (0,10,20,30,40,50)},
        corrected_SLF_DC_check=slf_check(joint,curve),
        spectra={name:{f'{lo}-{hi}':B.db_power(B.band(p,lo,hi)/B.anchor(p)) for lo,hi in B.BANDS} for name,p in allpower.items()})
    (args.out/'physical_engine_validation.json').write_text(json.dumps(report,indent=2)+'\n')
    print('quantization',report['quantization_check'],flush=True)


if __name__=='__main__':main()
