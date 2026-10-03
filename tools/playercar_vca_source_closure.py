#!/usr/bin/env python3
"""Close manufacturer-only VCA mechanism checks; diagnosis, never RTL.

Parameters below are unpublished semiconductor sensitivities. They are
fixed before cabinet validation and none is approved as an MB4391 model.
Default: source curves, coupled datasheet test and Jacobian checks.
--render: build one diagnostic table, compare the physical engine, and
check initial phases. --archive: preserve small review artifacts in docs.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import shutil
import numpy as np
import pymupdf
from scipy.optimize import brentq
from scipy.signal import resample_poly
from scipy.io import wavfile
import matplotlib.pyplot as plt
from playercar_mc3340_steering_probe import SteeringDevice, probe
from playercar_mc3340_device import IN
from playercar_mc3340_historical_check import thd
from playercar_mc3340_physical_table import build
from playercar_vca_loading_diagnose import Input
from playercar_vco_curve_check import path_points, mc3340_curve
from playercar_physical_engine_model import nonlinear_coupling, filt, rin_of, render, pattern, error, slf_check
import playercar_brightness_diagnose as B

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'sim/out/physical_vca_20260930'
PDF=ROOT.parent/'turbo/docs/reference/MC3340.pdf'
CASES=(('baseline',{}),('low_steering_beta',dict(beta_steering=10)),
       ('high_injection',dict(beta_fixed=25,ikf_steering=.01)),
       ('effective_ideality',dict(beta_control=25,ikf_steering=.01,nf_steering=1.3)))


def save(name,data):
    (OUT/name).write_text(json.dumps(data,indent=2)+'\n')


def curves():
    drawings=pymupdf.open(PDF)[2].get_drawings()
    points=np.vstack([path_points(drawings[k]) for k in (37,144,143)])
    points=points[np.argsort(points[:,0])]
    sixteen=dict(control_v=(1.5+5*(points[:,0]-86.2870026)/(289.8139954-86.2870026)).tolist(),
        attenuation_db=np.maximum((points[:,1]-80.0499878)/(209.9340210-79.1430054)*100,0).tolist(),
        source='Motorola MC3340/D solid16V curve; vector paths37/144/143; digitization approximate',
        warning='Drawn segments overlap around4.48-4.52V, producing nonmonotone local ink geometry. Retained as source geometry, not a smooth device law. The10/20/30/40/50dB inverse checks are outside that overlap.')
    save('MC3340_original_16V_curve.json',sixteen)
    return {12:mc3340_curve(PDF),16:sixteen}


def source_checks():
    references=curves();result=[]
    for name,kw in CASES:
        for vcc in (12,16):
            p=probe(vcc=vcc,**dict(dict(beta_steering=100),**kw))
            p['name']=name;p['semiconductor_assumptions']=kw
            src=references[vcc]
            p['control_errors_V']={str(r['attenuation_db']):float(r['control_v']-
                np.interp(r['attenuation_db'],src['attenuation_db'],src['control_v']))
                for r in p['rows'][1:]}
            result.append(p);save('source_family_checks.json',result)
            print('Source',name,vcc,p['max_gain_db'],[round(x['THD_percent'],3) for x in p['rows']],flush=True)
    checks=[]
    for name,kw in CASES:
        d=SteeringDevice(vcc=16,**kw);bias=float(d.solve(0)[IN]);c=4.5
        state=d.solve(c,bias).copy();r,j=d.equations(state,c,bias);eps=1e-7
        numerical=np.column_stack([(d.equations(state+np.eye(16)[k]*eps,c,bias)[0]-
            d.equations(state-np.eye(16)[k]*eps,c,bias)[0])/(2*eps) for k in range(16)])
        relative=float(np.linalg.norm(j-numerical)/np.linalg.norm(j))
        assert relative<1e-6
        checks.append(dict(name=name,max_J_error=float(np.max(abs(j-numerical))),relative_J_error=relative,
                           max_KCL_residual_mA=float(np.max(abs(r)))))
    save('steering_jacobian_checks.json',checks)


def coupled_source_checks():
    result=[]
    for name,kw in CASES[:3]:
        d=SteeringDevice(vcc=16,numerical_gmin=1e-12,**kw);bias=float(d.solve(0)[IN])
        def gain(c):return (d.pin_output(d.solve(c,bias+.0001))-d.pin_output(d.solve(c,bias-.0001)))/.0002
        g0=gain(0);controls=[0]+[brentq(lambda c:gain(c)/g0-10**(-a/20),0,8) for a in (10,20,50)]
        n=512;phase=np.arange(n)*2*np.pi/n;hz=np.fft.rfftfreq(n,1/(n*1000));sj=2j*np.pi*hz;rows=[]
        for att,c in zip((0,10,20,50),controls):
            vs=np.linspace(bias-1.2,bias+1.2,1025);yy=[];ii=[]
            for v in vs:
                state=d.solve(c,float(v));yy.append(d.pin_output(state));ii.append(d.input_current(state))
            dev=Input(dict(bias=bias,vin=vs.tolist(),vout=yy,input_current=ii));rin=rin_of(dev)
            h=sj*1e-6*rin/(1+sj*1e-6*rin);z=rin/(1+sj*1e-6*rin)
            for ei in ([.1,2.5/abs(g0)] if att==0 else [2.5/abs(g0)]):
                pin,diag=nonlinear_coupling(np.sqrt(2)*ei*np.sin(phase),h,z,dev)
                y=filt(dev.output(pin),1/(1+sj*6200*620e-12))
                direct=dev.output(bias+np.sqrt(2)*ei*np.sin(phase))
                rows.append(dict(attenuation_db=att,control_v=c,input_source_rms_V=ei,
                    derived_pin_dc_v=float(pin.mean()),quiescent_pin_v=bias,THD_percent=thd(y),
                    old_fixed_bias_THD_percent=thd(direct),output_rms_v=float(y.std()),coupling=diag))
        result.append(dict(name=name,semiconductor_assumptions=kw,max_gain_db=float(20*np.log10(abs(g0))),
            rows=rows,max_kcl_residual_mA=d.max_residual,warning='16V/1kHz/1uF input/620pF ROLL. Fixed generator input giving linear-on output2.5Vrms; Figure7 protocol qualified. No cabinet parameters.'))
        save('datasheet_coupling_checks.json',result)
        print('Coupled source',name,[round(x['THD_percent'],4) for x in rows],flush=True)


def engine_checks():
    kw=CASES[2][1]
    d=SteeringDevice(vcc=12,numerical_gmin=1e-12,**kw)
    warning='Source-only mechanism probe: beta_fixed25,IKFsteering10mA,other beta100,NF1. Unpublished parameters; fails joint Figure3/7. Numerical pivot1pS. Not production.'
    joint=build(d,warning);joint.update(numerical_gmin_S=1e-12,semiconductor_probe=kw)
    save('steering_injection_2D_transfer.json',joint)
    old=json.loads((OUT/'corrected_2D_transfer.json').read_text())
    tab=json.loads((OUT/'corrected_on_transfer.json').read_text())[2]
    cab=json.loads((OUT/'physical_engine_validation.json').read_text())['cabinet_patterns'];curve=mc3340_curve(PDF)
    def check(table,phases=None):
        args={} if phases is None else dict(phases=phases)
        stage,diag=render(tab,curve,joint=table,**args)
        power=B.spectrum(resample_poly(stage['W'],1,3)[2*B.FS:6*B.FS]);q=pattern(power,diag['rates_Hz'])
        diag.update(pattern_dB_re_2IminusT=q,cabinet_pattern_error_dB={k:error(q,v) for k,v in cab.items()},
                    HF_re_mid_dB=B.db_power(B.band(power,900,3000)/B.anchor(power)))
        return stage,diag
    stage,diag=check(joint);diag['SLF_check']=slf_check(joint,curve)
    save('steering_injection_engine_validation.json',diag)
    assert np.max(abs(stage['W']))<4
    wavfile.write(OUT/'steering_injection_hypothesis_W.wav',48000,np.round(stage['W']/4*32767).astype('<i2'))
    rows=[]
    for phases in ((0,0,0),(.25,.5,.75),(.7,.1,.4)):
        _,diag=check(old,phases);rows.append(diag);save('phase_sensitivity.json',rows)
        print('Phase check',phases,diag['cabinet_pattern_error_dB'],flush=True)


def archive():
    evidence=ROOT/'docs/evidence';refs=curves()
    p=json.loads((OUT/'source_family_checks.json').read_text())
    fig7=json.loads((OUT/'MC3340_Figure7_curve.json').read_text())
    fig,axes=plt.subplots(1,3,figsize=(15,4.7),layout='constrained')
    for ax,vcc in zip(axes[:2],(12,16)):
        src=refs[vcc];ax.plot(src['control_v'],src['attenuation_db'],'k',lw=2,label='Manufacturer')
        for row in [r for r in p if r['vcc']==vcc]:
            a=row['native_curve'];ax.plot([x['control_v'] for x in a],[x['attenuation_db'] for x in a],label=row['name'])
        ax.set(xlim=((2.5,5.4) if vcc==12 else (3.5,6.4)),ylim=(0,80),xlabel='External control (V)',ylabel='Attenuation (dB)',title=f'Native control, {vcc}V')
        ax.grid(alpha=.2)
    ax=axes[2];ax.plot(fig7['attenuation_db'],fig7['THD_percent'],'k',lw=2,label='Manufacturer Figure7')
    for row in [r for r in p if r['vcc']==16]:
        ax.plot([x['attenuation_db'] for x in row['rows']],[x['THD_percent'] for x in row['rows']],'.-',label=row['name'])
    ax.set(ylim=(0,4),xlabel='Attenuation (dB)',ylabel='THD (%)',title='Fixed-input reference; protocol qualified');ax.grid(alpha=.2);ax.legend(fontsize=8)
    fig.suptitle('Manufacturer-only mechanism probes: none passes all constraints; no cabinet fit')
    fig.savefig(evidence/'playercar_vca_source_closure_20260930.png',dpi=150)
    for name in ('source_family_checks.json','datasheet_coupling_checks.json','steering_jacobian_checks.json',
                 'MC3340_original_16V_curve.json','phase_sensitivity.json','steering_injection_engine_validation.json'):
        shutil.copyfile(OUT/name,evidence/('playercar_'+name))


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--render',action='store_true');ap.add_argument('--archive',action='store_true')
    ap.add_argument('--evidence-only',action='store_true');args=ap.parse_args();OUT.mkdir(parents=True,exist_ok=True)
    if not args.evidence_only:source_checks();coupled_source_checks()
    if args.render:engine_checks()
    if args.archive:archive()


if __name__=='__main__':main()
