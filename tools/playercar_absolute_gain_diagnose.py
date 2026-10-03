#!/usr/bin/env python3
"""Offline voltage ledger for SLF and the emitted F/W path. Never edits RTL.

Exact external linear network, including the coupled F/W/M loads. MC3340
Figure-3 attenuation and +13 dB reference are manufacturer proxies; Rin,
switch Ron and the generic fully-on junction transfer are explicit hypotheses.
The optional woofer filter is presentation only. All synthesis uses nominal
parts, independently of cabinet frequencies or levels.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import re
from pathlib import Path
import numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly, sosfreqz
import playercar_fast_model as M
import playercar_d8_ic17_reference as R
import playercar_brightness_diagnose as B
import speaker_guess_listen as SG
from playercar_vco_curve_check import mc3340_curve, gain_from_curve
from playercar_vca_loading_diagnose import Input, coupled_source
from playercar_mc3340_device import transfer

ROOT = Path(__file__).resolve().parents[1]
FS = 48000
WINDOW = 3.5464
GMAX = 10**(13/20)
RS_INPUT = 1/(1/39000+1/10000)


def triangle(t, frequency, ratio):
    phase = (t*frequency+.271) % 1
    duty = 1/(1+ratio)
    unit = np.where(phase<duty, phase/duty, (1-phase)/(1-duty))
    return WINDOW*(unit-.5)


def rate(voltage, ri, rs, cap):
    return voltage/(2*WINDOW*cap*(ri+1/(1/rs-1/ri)))


def output_network(hz, ron=0., rout=200., capacitors=True, c108=2.2e-6,ic28_rout=0.):
    """Six-node KCL, SLF/IC28 voltage sources -> q,F,W,M and LF351 outs.

    o=IC30 out, q=R198 top, d=R220 top; other source voltages are zero.
    Source legs remain present when silent. All other source impedances
    are approximated as low in this reference. No isolated divider twice.
    """
    hz=np.atleast_1d(hz).astype(float); s=2j*np.pi*hz
    mat=np.zeros((len(hz),6,6),complex)
    rhs=np.zeros((len(hz),6,2),complex)
    def ground(node, g): mat[:,node,node]+=g
    def branch(a,b,g):
        mat[:,a,a]+=g;mat[:,b,b]+=g;mat[:,a,b]-=g;mat[:,b,a]-=g
    ground(0,1/(rout+ron));rhs[:,0,0]=1/(rout+ron)
    ground(0,2/51000);branch(0,1,1/8200);ground(1,1/10000)
    ground(2,1/12000+1/(100000+ic28_rout));rhs[:,2,1]=1/(100000+ic28_rout)
    def coupled_g(resistance, cap):
        return s*cap/(1+s*cap*resistance) if capacitors else np.full(len(hz),1/resistance)
    branch(1,4,coupled_g(68000,c108))
    for node in (3,4,5):branch(2,node,coupled_g(100000,1e-6))
    # F has both OCAR.F and Ambulance 22k legs, plus five other 100k
    # sources. Earlier load ledgers omitted the Ambulance leg.
    ground(3,1/22000+5/100000+2/22000)
    ground(4,1/22000+4/100000)
    ground(5,1/22000+11/100000)
    sol=np.linalg.solve(mat,rhs)
    assert np.max(abs(mat@sol-rhs)) < 1e-15, 'Nodal KCL did not converge'
    out=np.empty((len(hz),5,2),complex)
    out[:,0,:]=sol[:,1,:];out[:,1,:]=sol[:,2,:]
    out[:,2:,:]=-100000/22000*sol[:,3:,:]
    return out


def filter_transfer(x, response):
    return np.fft.irfft(np.fft.rfft(x)*response,n=len(x))


def stats(x):
    y=x[2*FS:6*FS]
    return dict(ac_rms_v=float(y.std()),peak_ac_v=float(abs(y-y.mean()).max()),
                mean_v=float(y.mean()))


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'sim/out/absolute_gain_20260930')
    args=ap.parse_args();args.out.mkdir(parents=True,exist_ok=True)
    rtl=(ROOT/'rtl/audio/turbo_playercar_chan.sv').read_text()
    block=re.search(r'GAIN17_LUT_Q16.*?=\s*\x27\{(.*?)\};',rtl,re.S).group(1)
    table=np.array([int(x) for x in re.findall(r"27'sd(\d+)",block)])/65536
    assert len(table)==193
    curve=mc3340_curve(ROOT.parent/'turbo/docs/reference/MC3340.pdf')
    tabpath=ROOT/'sim/out/vca_ic7_20260930/mc3340_on_transfer.json'
    tab=json.loads(tabpath.read_text())[1] if tabpath.exists() else transfer(12.,100.)
    device=Input(tab);rin=float(1/device.deriv(tab['bias']))
    t=np.arange(8*FS)/FS;f=np.fft.rfftfreq(len(t),1/FS)
    vl=R.ladder_v(42);f3=rate(vl,270000,120000,.1e-6);f5=rate(vl,150000,68000,.1e-6)
    raw=triangle(t,f3,1.25);control_ac=triangle(t,f5,150/68-1)
    control_tau=220e-7*15000
    hp17=2j*np.pi*f*control_tau/(1+2j*np.pi*f*control_tau)
    cont=12*2.7/10.9-2/3*filter_transfer(control_ac,hp17)
    physical_gain=gain_from_curve(cont,curve)
    # Actual present LUT uses the 3.0V-relative reference and clamps below it.
    code_cont=12175/4096-(2+1/4+1/16+1/32+1/64+1/256)*control_ac/WINDOW
    index=np.clip(np.floor((code_cont-3)*64).astype(int),0,192)
    code_input=raw/WINDOW*(.5+.125+.0625+.03125+.00390625)
    code_slf=code_input*table[index]*(.5+1/64)
    code_w=-code_slf*39775/65536
    tau47=10e-6*(RS_INPUT+rin)
    h47=rin/(RS_INPUT+rin)*2j*np.pi*f*tau47/(1+2j*np.pi*f*tau47)
    pin_ac=filter_transfer(raw*10/49,h47)
    linear_out=-GMAX*pin_ac*physical_gain
    ideal_input_out=-GMAX*raw*10/49*physical_gain
    vin,capcharge=coupled_source(filter_transfer(raw*10/49,
        2j*np.pi*f*tau47/(1+2j*np.pi*f*tau47)),device,RS_INPUT)
    asymmetric_out=(device.output(vin)-tab['on_dc'])*physical_gain
    with_dc=asymmetric_out+(tab['on_dc']-tab['off_dc'])*physical_gain
    h=output_network(f)
    stages={'IC3_triangle':raw,'unloaded_C47_drive':raw*10/49,
            'loaded_IC17_input_AC':pin_ac,'CONT':cont,
            'IC17_linear_13dB_gated':linear_out,
            'RTL_slf_tap':code_slf,'RTL_W_SLF_contribution':code_w}
    for name,x in [('linear_13dB',linear_out),('unloaded_input_13dB',ideal_input_out),('generic_asymmetric',asymmetric_out),
                   ('generic_asymmetric_plus_DC',with_dc)]:
        stages[name+'_C108_source']=filter_transfer(x,h[:,0,0])
        stages[name+'_W_mixer']=filter_transfer(x,h[:,3,0])
    # Electrical driver transfer is independent of the optional acoustic curve.
    s=2j*np.pi*f
    amp_input=s*.47e-6*220000/(1+s*.47e-6*221000)
    amp_feedback=1+12000/(120+1/np.where(s==0,1e-30,s*220e-6))
    output_cap=s*.001*8/(1+s*.001*8)
    electrical=amp_input*amp_feedback/101*output_cap
    stages['linear_13dB_W_driver_unity_midband']=filter_transfer(stages['linear_13dB_W_mixer'],electrical)
    stages['linear_13dB_W_optional_woofer_guess']=SG.woofer(stages['linear_13dB_W_driver_unity_midband'],FS)
    reference_network=output_network([1000.],capacitors=False)[0]
    generic_gain=float(np.interp(tab['bias']+.001,tab['vin'],tab['vout'])-
                       np.interp(tab['bias']-.001,tab['vin'],tab['vout']))/.002
    ledger=dict(source_sha256=hashlib.sha256(rtl.encode()).hexdigest(),
        slf_source_sha256=hashlib.sha256((ROOT/'rtl/audio/turbo_playercar_slf.sv').read_bytes()).hexdigest(),
        source_note='Read current source. RTL render is a continuous phase/float arithmetic mirror, not a new RTL simulation.',
        assumptions=['+13dB manufacturer nominal reference, not MB4391 measurement',
                     'Rin from generic beta100 junction model, Ron nominal 0 with sensitivity',
                     'Other silent source impedances approximated as low; nominal resistive 8ohm driver',
                     'Generic full VCA control model rejected; source Figure3 controls hybrid transfer',
                     'FFT filtering uses periodic steady-state boundary; analyze central 2..6 seconds'],
        ladder_v=vl,rates_hz=dict(IC3=f3,IC5=f5),rin_ohm=rin,
        absolute_gain_reference=GMAX,generic_on_gain=generic_gain,
        input_unloaded_gain=10/49,input_loaded_gain=10/49*rin/(rin+RS_INPUT),
        C47_corner_hz=1/(2*np.pi*tau47),C17_corner_hz=1/(2*np.pi*control_tau),
        physical_gating_mean=float(physical_gain.mean()),
        physical_gating_rms=float(np.sqrt(np.mean(physical_gain**2))),
        coupled_source_bias=capcharge,stages={k:stats(v) for k,v in stages.items()},
        dc_network=dict(C108_source_per_IC17=float(reference_network[0,0].real),
                        W_per_IC17=float(reference_network[3,0].real),
                        divider_per_IC28=float(reference_network[1,1].real),
                        F_per_IC28=float(reference_network[2,1].real),
                        W_per_IC28=float(reference_network[3,1].real)),
        Ron_sensitivity={},spectra={},line_rms_v={})
    for ron in (0,200,300,660,1000,2000):
        q=output_network([1000.],ron=ron,capacitors=False)[0]
        ledger['Ron_sensitivity'][str(ron)]=dict(W_per_IC17=float(q[3,0].real))
    alternate_c108=output_network(f,c108=22e-6)
    alternate_w=filter_transfer(linear_out,alternate_c108[:,3,0])
    ledger['C108_22uF_reading_sensitivity_dB']=float(20*np.log10(
        alternate_w[2*FS:6*FS].std()/stages['linear_13dB_W_mixer'][2*FS:6*FS].std()))
    products={'IC3':f3,'IC5':f5,'IC5-IC3':f5-f3,'IC3+IC5':f3+f5,'2IC5-IC3':2*f5-f3}
    for name in ['RTL_W_SLF_contribution','linear_13dB_W_mixer',
                 'generic_asymmetric_W_mixer','generic_asymmetric_plus_DC_W_mixer',
                 'linear_13dB_W_driver_unity_midband','linear_13dB_W_optional_woofer_guess']:
        x=resample_poly(stages[name],1,3)[2*B.FS:6*B.FS];power=B.spectrum(x)
        ledger['spectra'][name]={f'{lo}-{hi}':float(B.band(power,lo,hi)) for lo,hi in B.BANDS}
        ledger['line_rms_v'][name]={key:float(np.sqrt(B.line(power,hz))) for key,hz in products.items()}
    ledger['SLF_correction_dB_vs_emitted']=float(20*np.log10(
        stages['linear_13dB_W_mixer'][2*FS:6*FS].std()/code_w[2*FS:6*FS].std()))
    # Linear upper ledger: load, intermediate switch/input, two +13dB stages,
    # selected CONT. Large-signal input makes this a reference, not a solution.
    second_load=1/(1/rin+2/51000)
    second_input_gain=second_load/(second_load+200)
    selected=gain_from_curve(3.15,curve)
    upper_factor=GMAX**2*second_input_gain*selected*reference_network[3,1].real/(-27043/65536)
    ledger['upper_linear_reference']=dict(second_input_gain=second_input_gain,
        selected_relative_gain=float(selected),emitted_correction_factor=float(upper_factor),
        correction_db=float(20*np.log10(abs(upper_factor))),
        warning='Excludes upper input compression/loading; no global linear gain proposal.')
    # Independent resistor reduction checks the coupled midband solution.
    rb_f=1/(5/100000+3/22000);rb_m=1/(11/100000+1/22000)
    d_thev=1/(1/12000+1/100000+1/(100000+rb_f)+1/(100000+rb_m))
    rb_w=1/(4/100000+1/22000+1/(100000+d_thev))
    q_bottom=1/(1/10000+1/(68000+rb_w))
    o_load=1/(2/51000+1/(8200+q_bottom))
    q_gain=o_load/(200+o_load)*q_bottom/(8200+q_bottom)
    w_gain=-100000/22000*q_gain*rb_w/(68000+rb_w)
    assert abs(w_gain-reference_network[3,0])<1e-12
    ledger['independent_resistor_check']=dict(W_per_IC17=w_gain,
        C108_source_per_IC17=q_gain,error=float(abs(w_gain-reference_network[3,0])))
    ledger['input_loading_sensitivity']=[]
    tables=json.loads(tabpath.read_text()) if tabpath.exists() else [tab]
    for table_entry in tables:
        inp=Input(table_entry);rr=float(1/inp.deriv(table_entry['bias']))
        ledger['input_loading_sensitivity'].append(dict(beta=table_entry['beta'],rin_ohm=rr,
            input_gain=10/49*rr/(rr+RS_INPUT)))
    # Raw cabinet spectra are retained: median subtraction can erase a
    # stationary control line. No observed line changes synthesis parameters.
    recording=B.decode(ROOT.parent/'turbo/docs/reference/turbo_cabinet_recording.weba')
    med=np.median([B.spectrum(recording[(sec-B.START)*B.FS:(sec-B.START+4)*B.FS])
                   for sec in B.BACKGROUND],axis=0)
    ledger['cabinet_low_line_check']={}
    for sec in (748,763):
        raw_power=B.spectrum(recording[(sec-B.START)*B.FS:(sec-B.START+4)*B.FS])
        ledger['cabinet_low_line_check'][str(sec)]={}
        for tag,p in [('raw',raw_power),('median_residual',np.maximum(raw_power-med,0))]:
            checks={}
            for key,lo,hi in [('IC3_region',21,25),('IC5_region',38,43)]:
                ids=np.flatnonzero((B.F>=lo)&(B.F<=hi));peak=B.F[ids[np.argmax(p[ids])]]
                power=B.line(p,peak)
                checks[key]=dict(peak_hz=float(peak),line_power=power,
                    db_re_250_900=B.db_power(power/B.anchor(p)))
            checks['IC5_vs_IC3_dB']=B.db_power(checks['IC5_region']['line_power']/
                max(checks['IC3_region']['line_power'],1e-30))
            ledger['cabinet_low_line_check'][str(sec)][tag]=checks
    np.savez(args.out/'physical_voltage_stages.npz',**stages)
    for name in ('linear_13dB_W_mixer','generic_asymmetric_W_mixer',
                 'generic_asymmetric_plus_DC_W_mixer','linear_13dB_W_optional_woofer_guess'):
        # Shared conversion: 1.0V = 0.25 PCM full scale. No per-file normalization.
        x=stages[name][2*FS:6*FS]
        ledger.setdefault('wav_pcm',{})[name]=dict(volts_per_full_scale=4.,clipped_samples=int((abs(x)>4).sum()))
        wavfile.write(args.out/(name+'.wav'),FS,np.rint(np.clip(x/4,-1,1)*32767).astype(np.int16))
    (args.out/'absolute_gain_ledger.json').write_text(json.dumps(ledger,indent=2)+'\n')
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig,ax=plt.subplots(1,2,figsize=(12,4))
    for name in ('RTL_W_SLF_contribution','linear_13dB_W_mixer','generic_asymmetric_W_mixer','generic_asymmetric_plus_DC_W_mixer'):
        x=resample_poly(stages[name],1,3)[2*B.FS:6*B.FS];p=B.spectrum(x)
        ax[0].plot(B.F,10*np.log10(np.maximum(p,1e-20)),label=name)
    ax[0].set(xlim=(10,150),ylim=(-110,0),xlabel='Hz',ylabel='dB re 1 V² per FFT bin',title='SLF at W mixer, absolute voltage')
    ax[0].legend(fontsize=7)
    hz=np.geomspace(10,5000,400);ss=2j*np.pi*hz
    el=(ss*.47e-6*220000/(1+ss*.47e-6*221000))*(1+12000/(120+1/(ss*220e-6)))/101*(ss*.001*8/(1+ss*.001*8))
    ax[1].semilogx(hz,20*np.log10(abs(el)),label='STK electrical, normalized gain101')
    from scipy.signal import butter
    woofer_sos=np.vstack((SG.sos_hp2(SG.FC_HP,SG.Q_HP,FS),butter(2,SG.FC_LP,'low',fs=FS,output='sos')))
    _,ac=sosfreqz(woofer_sos,worN=hz,fs=FS)
    ax[1].semilogx(hz,20*np.log10(abs(ac)),label='Optional guessed woofer only')
    ax[1].set(xlabel='Hz',ylabel='dB re midband',ylim=(-35,2),title='Electrical coupling separated from acoustics');ax[1].legend(fontsize=8)
    fig.tight_layout();fig.savefig(args.out/'absolute_gain_diagnosis.png',dpi=160);plt.close(fig)
    print(json.dumps({k:ledger[k] for k in ('rates_hz','rin_ohm','dc_network','SLF_correction_dB_vs_emitted','upper_linear_reference','stages')},indent=2))


if __name__=='__main__':main()
