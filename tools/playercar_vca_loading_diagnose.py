#!/usr/bin/env python3
"""Settled VCA loading and nonlinear-transfer comparisons; no RTL edits.

Hybrid hypothesis: Figure-2 fully-on generic BJT transfer, existing project
attenuation approximation or an explicitly supplied source-curve JSON.
The full generic transistor control
law fails Figure 3, so it is NEVER used to generate these samples. Neither
the hybrid nor the internal DC-feedthrough estimate is validated MB4391.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import numpy as np
from scipy.optimize import brentq
from scipy.signal import lfilter, resample_poly
from scipy.io import wavfile
import playercar_fast_model as M
import playercar_d8_ic17_reference as R
import gen_playercar_ic17_tables as G
import playercar_brightness_diagnose as B
from playercar_mc3340_device import transfer


class Input:
    def __init__(self, tab):
        self.tab=tab
        self.v=np.array(tab['vin']);self.i=np.array(tab['input_current'])
        self.y=np.array(tab['vout']);self.di=np.gradient(self.i,self.v)
    def current(self,v):
        out=np.interp(v,self.v,self.i)
        # Bias resistor continues to draw current outside the grid; do not
        # silently turn it into an open circuit through np.interp clamping.
        out+=np.minimum(v-self.v[0],0)*self.di[0]
        out+=np.maximum(v-self.v[-1],0)*self.di[-1]
        return out
    def deriv(self,v):return np.interp(v,self.v,self.di)
    def output(self,v):return np.interp(v,self.v,self.y)


def coupled_or(t,s,device,rs=1000.):
    """Joint diode-OR/R79/input KCL and zero average C76 current.

    The settled capacitor voltage is derived, not a centering knob. Ripple
    of the 10uF capacitor is neglected here, not replaced by a fitted pole.
    Rs is the EXISTING estimated op-amp output resistance, not a board part.
    """
    u=t-M.VF;w=s-M.VF
    def solve(charge):
        node=np.maximum(u,w)*.90
        for _ in range(12):
            vin=node-charge
            cur=np.maximum(u-node,0)/rs+np.maximum(w-node,0)/rs-node/10000-device.current(vin)
            conductance=((u>node).astype(float)+(w>node).astype(float))/rs+1/10000+device.deriv(vin)
            node+=cur/conductance
        return node-charge,node
    charge=brentq(lambda q:device.current(solve(q)[0]).mean(),0.,8.,xtol=1e-10)
    vin,node=solve(charge)
    residual=np.maximum(u-node,0)/rs+np.maximum(w-node,0)/rs-node/10000-device.current(vin)
    return vin,dict(capacitor_voltage=charge,vin_mean=float(vin.mean()),
                    vin_ac_rms=float(vin.std()),vin_min=float(vin.min()),vin_max=float(vin.max()),
                    max_kcl_error_A=float(abs(residual).max()),mean_cap_current_A=float(device.current(vin).mean()))


def coupled_source(source,device,resistance):
    def solve(dc):
        vin=source+dc
        for _ in range(12):
            vin-=(vin+resistance*device.current(vin)-source-dc)/(1+resistance*device.deriv(vin))
        return vin
    dc=brentq(lambda d:device.current(solve(d)).mean(),-3.,5.,xtol=1e-10)
    vin=solve(dc)
    return vin,dict(derived_dc_offset=dc,vin_ac_rms=float(vin.std()),vin_min=float(vin.min()),vin_max=float(vin.max()),
                    mean_cap_current_A=float(device.current(vin).mean()))


def hp(x,fc,fs=M.FS):
    a=np.exp(-2*np.pi*fc/fs)
    # First-order reference for the actual capacitors; frequencies derived
    # from the external resistor network and estimated VCA input impedance.
    # Start from the derived steady DC charge rather than an empty
    # coupling capacitor. Zero-mean AC remains subject to this RC filter.
    return lfilter([a,-a],[1,-a],x,zi=[-a*np.mean(x)])[0]


def lp(x,fc,fs=M.FS):
    a=np.exp(-2*np.pi*fc/fs)
    return lfilter([1-a],[1,-a],x,zi=[a*np.mean(x)])[0]


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=Path('sim/out/vca_ic7_20260930'))
    ap.add_argument('--control-curve-json',type=Path,help='Optional independently extracted Motorola 12V Figure-3 curve; never changes the existing table')
    args=ap.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    table_path=args.out/'mc3340_on_transfer.json'
    tables=json.loads(table_path.read_text()) if table_path.exists() else [transfer(12.,beta) for beta in (50.,100.,200.)]
    table=tables[1]; device=Input(table)
    n=6*48000;vl=R.ladder_v(42);vb=vl*R.BUS_LOADED
    rates=np.array([R.K_TONE*vb,G.K_IC7*vb,G.K_SUB*vb])
    rng=np.random.default_rng(1)
    t=M.tri(M.phases(rates[0],n,rng.random()),M.RATIO_TONE)
    s=M.tri(M.phases(rates[2],n,rng.random()),M.RATIO_SUB)
    tri7=M.tri(M.phases(rates[1],n,rng.random()),M.RATIO_SUB)
    cont=R.clamp_dc(vb)+(M.TH_LO+M.TH_HI)/2-tri7
    curve=json.loads(args.control_curve_json.read_text()) if args.control_curve_json else None
    def gain_fn(control):
        if curve is None:return R.mc3340_gain(control)
        return 10**(-np.interp(control,curve['control_v'],curve['attenuation_db'])/20)
    gain=gain_fn(cont)
    vin,loading=coupled_or(t,s,device)
    on=device.output(vin)
    on_quiet=table['on_dc'];off=table['off_dc']
    # Current steering changes both the signal gain and DC. Separate the
    # hypothesized DC term so its impact is visible rather than concealed.
    relative=-(vin-vin.mean())*gain
    nonlinear=(on-on_quiet)*gain
    dcfeed=(on_quiet-off)*gain
    cases={'loaded_relative':relative,'one_asymmetric':nonlinear,
           'one_asymmetric_plus_DC':nonlinear+dcfeed}
    stage2={}
    for key in ('one_asymmetric','one_asymmetric_plus_DC'):
        first=hp(lp(cases[key],1/(2*np.pi*6200*680e-12)),1/(2*np.pi*.000022*(25500+18000)))
        # C106 biases through R202||R203; C101=2.2uF couples to IC28.
        # 200 ohms is Figure-2 output resistor, 1k switch is an explicit
        # illustrative Ron. Its sensitivity is separately calculated below.
        first*=18000/(18000+1200)
        first=hp(first,1/(2*np.pi*2.2e-6*(18000+1200)))
        second_in,stage2[key]=coupled_source(first,device,0.)
        # The selected TTL low is not exactly specified here. 3.00..3.15 V
        # follows (6 V + 0..0.3 V)/2. This DC attenuation is a common scale
        # in the hybrid; it does not tune the normalized spectrum.
        selected_gain=float(gain_fn(3.15))
        second=off+selected_gain*(device.output(second_in)-off)
        second=lp(second,1/(2*np.pi*6200*680e-12))
        # BSEL2: R219=100k, R220=12k with F,W and M output branches.
        # F bus R32122k || other source legs; W R32322k analogous,
        # M: D7 R210100k -> sum of eleven other 100k legs -> R22822k
        # -> IC31 virtual ground. F: six 100k legs plus OCAR's 22k.
        f_load=100000+1/(1/22000+1/22000+5/100000)
        w_load=100000+1/(1/22000+4/100000+1/68000)
        m_load=100000+1/(1/22000+11/100000)
        bottom=1/(1/12000+1/f_load+1/w_load+1/m_load)
        divider=bottom/(100000+bottom)
        branch_mean=(f_load+w_load+m_load)/3
        source_r=1/(1/100000+1/12000)
        # Three 1uF branches, similar 106..110k loads: common-pole
        # approximation retained only for these sub-2Hz couplings.
        cases['two_'+key]=hp(second*divider,1/(2*np.pi*1e-6*(3*source_r+branch_mean)))
    recording=B.decode(B.ROOT.parent/'turbo/docs/reference/turbo_cabinet_recording.weba')
    median=np.median([B.spectrum(recording[(sec-B.START)*B.FS:(sec-B.START+4)*B.FS]) for sec in B.BACKGROUND],axis=0)
    report=dict(assumptions=__doc__,rates_Hz=dict(zip(('T','I','S'),map(float,rates))),loading=loading,
                second_stage_inputs=stage2,device_on_dc=on_quiet,device_off_dc=off,
                bsel2_loaded_divider=divider, spectra={},sidebands={},products={},input_loading_sensitivity={})
    report['bsel2_branch_loads_ohm']=dict(F=f_load,W=w_load,M=m_load)
    report['control_curve_source']=curve['source'] if curve else 'Existing project table approximation'
    report['coupling_initial_state']='High-pass and roll-off capacitors start at rendered cycle-average DC, then evolve causally. C76 charge comes from zero mean input current.'
    report['bsel2_selected_cont_v']=3.15
    report['bsel2_selected_relative_gain']=selected_gain
    for ron in (0,200,1000,2000):
        report['input_loading_sensitivity'][str(ron)]=dict(Ron_ohm=ron,
                         estimated_IC28_input_gain=18000/(18000+200+ron))
    report['SLF_small_signal_loading']=[]
    for tab in tables:
        inp=Input(tab);rin=1/inp.deriv(tab['bias'])
        bottom=1/(1/10000+1/rin)
        loaded=bottom/(39000+bottom)
        original=10000/49000
        report['SLF_small_signal_loading'].append(dict(beta=tab['beta'],rin_ohm=float(rin),
                    input_gain=float(loaded),loading_dB=float(20*np.log10(loaded/original)),
                    max_on_gain=float((tab['vout'][np.searchsorted(tab['vin'],tab['bias'])+1]-tab['vout'][np.searchsorted(tab['vin'],tab['bias'])-1])/.01)))
    all_power={}
    for name,x in cases.items():
        y=resample_poly(x,1,3)
        # Exactly four seconds at the analysis rate, settled 2..6 s.
        power=B.spectrum(y[2*B.FS:6*B.FS]);all_power[name]=power
        norm=max(abs(x).max(),1e-9)
        wavfile.write(args.out/(name+'.wav'),48000,(.85*x/norm*32767).astype('<i2'))
    for sec in (748,763):
        raw=B.spectrum(recording[(sec-B.START)*B.FS:(sec-B.START+4)*B.FS])
        all_power['cab%d_residual'%sec]=np.maximum(raw-median,0)
    for name,power in all_power.items():
        report['spectra'][name]={f'{lo}-{hi}':B.db_power(B.band(power,lo,hi)/B.anchor(power)) for lo,hi in B.BANDS}
        r=B.CAB_RATES if name.startswith('cab') else rates
        t,i,s=r
        report['products'][name]={key:dict(hz=float(hz),power_dB_re_250_900=B.db_power(B.line(power,abs(hz))/B.anchor(power)))
            for key,hz in {'T':t,'I':i,'S':s,'I-T':i-t,'T-S':t-s,'2I-T':2*i-t,'2I-S':2*i-s}.items()}
        ratios={}
        for k in (1,2,3):
            ratios[f'{k}I_minus_S_vs_plus_S_dB']=B.db_power(B.line(power,k*r[1]-r[2])/max(B.line(power,k*r[1]+r[2]),1e-30))
        report['sidebands'][name]=ratios
    (args.out/'vca_loading_diagnosis.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='assumptions'},indent=2))


if __name__=='__main__':main()
