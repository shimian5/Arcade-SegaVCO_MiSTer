#!/usr/bin/env python3
"""Scenario37 product/gain audit. Offline only, no RTL mutation.

Historical reconstructed MC3340 table is an UNVALIDATED manufacturer-topology
hypothesis. Even-term removal and linear-stage substitution are diagnostic
ablations, not board models or proposed transfer tables. No tanh/feedthrough.
"""
from pathlib import Path
import argparse
import hashlib
import json
import re
import numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly
import playercar_brightness_diagnose as B
import playercar_fast_model as M
import playercar_d8_ic17_reference as R
import playercar_physical_engine_model as P
from playercar_mc3340_physical_table import Input2D
from playercar_vco_curve_check import mc3340_curve, gain_from_curve
from playercar_absolute_gain_diagnose import output_network
from othercars_cabinet_research import source_h, controls, mixer

ROOT=Path(__file__).resolve().parents[1]
FS=48000
SECONDS=8
LINES=dict(A=77.13,pair=202.35,T=326.766,I=385.469,P444=444.156,P743=743.328)


def table(name):
    text=(ROOT/'rtl/audio/turbo_playercar_chan.sv').read_text()
    block=re.search(name+r'.*?=\s*\x27\{(.*?)\};',text,re.S).group(1)
    return np.array([int(x) for x in re.findall(r"\d+'sd(-?\d+)",block)])


def rates():
    # Actual integer shift/add slopes, with endpoint snapping at clk_sys.
    window=126162442-66664434
    result=[]
    for name in ('STEP_LUT','IC7_STEP_LUT','SUB_STEP_LUT'):
        down=int(table(name)[42]);up=down+(down>>2)
        if name!='STEP_LUT':up-=(down>>5)+(down>>6)
        count=int(np.ceil(window/up))+int(np.ceil(window/down))
        result.append(39935064/count)
    return np.array(result)


def spectrum(x,begin=2):
    y=resample_poly(x,1,3)
    return B.spectrum(y[int(begin*B.FS):int((begin+4)*B.FS)])


def metrics(x,ref,rates_hz=None,begin=2):
    p=spectrum(x,begin);centers=dict(LINES)
    if rates_hz is not None:
        t,i,s=rates_hz;centers.update(T=t,I=i,P444=2*i-t,P743=2*i-s)
    db={name:B.db_power(B.line(p,hz,1.2)/ref) for name,hz in centers.items()}
    t,i,s=B.CAB_RATES if rates_hz is None else rates_hz
    twins={}
    for name,main,lower in [('P444',2*i-t,i+2*s),('P743',2*i-s,t+i+s)]:
        delta=B.db_power(B.line(p,lower,1.2)/B.line(p,main,1.2));r=10**(delta/20)
        twins[name]=dict(lower_over_main_dB=delta,lower_over_main_amplitude=r,
            ideal_two_line_envelope_min_over_max=abs(1-r)/(1+r))
    return dict(relative_pair_dB=db,products_over_T_dB={n:db[n]-db['T'] for n in ('I','P444','P743')},
        twin_line_ratios=twins,beat_Hz=float(i-t-2*s),
        line_rms={n:float(np.sqrt(B.line(p,hz,1.2))) for n,hz in centers.items()})


def output(pin,g,device,kind):
    bias=device.tab['bias']
    if kind=='joint':return device.output(pin)
    quiet=device.output(np.full_like(pin,bias))
    if kind=='linear':return quiet+device.tab['max_signed_gain']*g*(pin-bias)
    if kind=='odd':return quiet+(device.output(pin)-device.output(2*bias-pin))/2
    raise ValueError(kind)


def physical_cases(out,ref,conversion):
    tab=json.loads((ROOT/'sim/out/physical_vca_20260930/corrected_2D_transfer.json').read_text())
    curve=mc3340_curve(ROOT.parent/'turbo/docs/reference/MC3340.pdf')
    t=np.arange(SECONDS*FS)/FS;f=np.fft.rfftfreq(len(t),1/FS);sj=2j*np.pi*f
    rr=rates();bus=R.ladder_v(42)*R.BUS_LOADED
    tone=M.tri((t*rr[0]+.51182)%1,1.25)
    sub=M.tri((t*rr[2]+.14416)%1,1.2)
    tri7=M.tri((t*rr[1]+.95046)%1,150/68-1)
    cont=R.clamp_dc(bus)-P.filt(tri7,sj*22e-6*10000/(1+sj*22e-6*10000))
    gain=gain_from_curve(cont,curve);g2=float(gain_from_curve(3.15,curve))
    dev1=Input2D(tab,-20*np.log10(gain));dev2=Input2D(tab,-20*np.log10(g2))
    pin1,node,diag1=P.coupled_or(tone,sub,f,dev1)
    h,z=P.interstage(f,P.rin_of(dev2),300,22e-6)
    roll=1/(1+sj*6200*680e-12)
    network=output_network(f,ron=300,ic28_rout=200)
    results={};stage1_cache={}
    variants=[('linear_both','linear','linear'),('asym17_only','joint','linear'),
              ('asym28_only','linear','joint'),('asym_both','joint','joint'),
              ('odd17_asym28','odd','joint'),('asym17_odd28','joint','odd')]
    stages=dict(time=t,tone=tone,sub=sub,tri7=tri7,node=node,pin1=pin1,control=cont,gain=gain)
    for name,k1,k2 in variants:
        if k1 not in stage1_cache:
            o1=P.filt(output(pin1,gain,dev1,k1),roll)
            p2,diag2=P.nonlinear_coupling(o1,h,z,dev2)
            stage1_cache[k1]=(o1,p2,diag2)
        o1,p2,diag2=stage1_cache[k1]
        o2=P.filt(output(p2,g2,dev2,k2),roll)
        fb=P.filt(o2,network[:,2,1]);wb=P.filt(o2,network[:,3,1])
        pcm=fb*conversion
        results[name]=dict(stage1_kind=k1,stage2_kind=k2,**metrics(pcm,ref,rr),
            voltage_stats={n:P.stats(v) for n,v in [('pin1',pin1),('out1',o1),('pin2',p2),('out2',o2),('F',fb),('W',wb)]},
            stage1_KCL=diag1,stage2_KCL=diag2)
        stages[name+'_F']=fb
        wavfile.write(out/(name+'_engine_F_4VFS.wav'),FS,(fb/4).astype('float32'))
        print(name,results[name]['relative_pair_dB'],flush=True)
    np.savez_compressed(out/'physical_stages.npz',**stages)
    return results,dict(rates_Hz=rr.tolist(),bus_V=bus,IC28_control_V=3.15,IC28_relative_gain=g2,
        table_sha256=hashlib.sha256(json.dumps(tab).encode()).hexdigest(),
        warning=tab['warning'],control_mean_V=float(cont.mean()),gain_mean=float(gain.mean()),
        coupling_notes='Same nonlinear input-current model retained for all output-transfer ablations.')


def fast_cases(out,ref,conversion):
    t=np.arange(SECONDS*FS)/FS;rr=rates();f=np.fft.rfftfreq(len(t),1/FS);sj=2j*np.pi*f
    tone=M.tri((t*rr[0]+.51182)%1,1.25)
    sub=M.tri((t*rr[2]+.14416)%1,1.2)
    tri7=M.tri((t*rr[1]+.95046)%1,1.203125)
    node=np.maximum(np.maximum(233/256*(tone-.7),233/256*(sub-.7)),61/128*(tone+sub-1.4))
    alpha=14/65536
    hp=(1-alpha)*(1-np.exp(-sj/FS))/(1-(1-alpha)*np.exp(-sj/FS))
    ac=P.filt(node,hp)
    clamp=table('CLAMP_DC_LUT_Q12')/4096
    gain_table=table('GAIN17_LUT_Q16')/65536
    idx=int(R.ladder_v(42)*16)
    cont=clamp[idx]+23538/4096-tri7
    gi=np.clip(np.floor((cont-3)*64).astype(int),0,192)
    gate=gain_table[gi]
    curve=mc3340_curve(ROOT.parent/'turbo/docs/reference/MC3340.pdf')
    gate_continuous=gain_from_curve(cont,curve)/float(gain_from_curve(3,curve))
    net=output_network(f,ron=300,ic28_rout=200)[:,2,1]
    cases={'relative_current':-ac*gate*15173/65536,
           'continuous_gain_same_network':-ac*gate_continuous*15173/65536,
           'C6_control_HP':-ac*gain_from_curve(clamp[idx]-P.filt(tri7,sj*.22/(1+sj*.22)),curve)
                           /float(gain_from_curve(3,curve))*15173/65536,
           'linear_absolute_external':P.filt(ac*gate*10**(26/20)*float(gain_from_curve(3.15,curve)),net),
           'linear_absolute_sourcecurve_external':P.filt(ac*gain_from_curve(cont,curve)*10**(26/20)
                                                       *float(gain_from_curve(3.15,curve)),net)}
    # A/D resistor tolerance in the ACTUAL IC7 control op-amp and divider.
    # No sample is selected for cabinet score. Report the complete bounds.
    sweeps=[]
    for r38_factor in (.95,1.,1.05):
        for r39_factor in (.95,1.,1.05):
            r38=680*r38_factor;r39=330*r39_factor
            mid=12*r39/(r38+r39);rth=r38*r39/(r38+r39)
            for rbus_factor in (.95,1.05):
                vn=mid;vb=R.ladder_v(42)*R.BUS_LOADED
                for _ in range(60):
                    current=(vb-vn)/(10000*rbus_factor)
                    vd=1.9*.02585*np.log1p(abs(current)/1.8e-9)*np.sign(current)
                    vn=mid+current*rth+vd
                for gainratio in (.95/1.05,1.,1.05/.95):
                    g=gain_from_curve(vn-gainratio*(tri7-tri7.mean()),curve)
                    y=-ac*g*15173/65536*conversion
                    row=metrics(y,ref,rr)
                    sweeps.append(dict(r38_factor=r38_factor,r39_factor=r39_factor,
                        rbus_factor=rbus_factor,R35_R36=gainratio,clamp_V=vn,**row))
    return {n:metrics(y*conversion,ref,rr) for n,y in cases.items()},sweeps


def acoustic_requirement(core,cab):
    # Smooth response inference only; not a driver identification or proposal.
    difference=(cab['relative_pair_dB']['A']-core['relative_pair_dB']['A'])
    f1=77.13;f2=202.35
    def shape(f,fc,q):
        s=1j*f/fc
        return abs(s*s/(1+s/q+s*s))
    from scipy.optimize import brentq
    illustrative=[]
    for q in (.5,1/np.sqrt(2),1.):
        fc=brentq(lambda fc:20*np.log10(shape(f1,fc,q)/shape(f2,fc,q))-difference,10,1000)
        illustrative.append(dict(Q=q,corner_Hz=fc,
            response444_vs202_dB=20*np.log10(shape(444.156,fc,q)/shape(f2,fc,q)),
            response743_vs202_dB=20*np.log10(shape(743.328,fc,q)/shape(f2,fc,q)),
            warning='X: inferred effective high-pass example, no measured driver parameters. Not proposed for RTL.'))
    return dict(required77_vs202_dB=difference,illustrations=illustrative)


def oc_source_check(out):
    t=np.arange(SECONDS*FS)/FS;f=np.fft.rfftfreq(len(t),1/FS);sj=2j*np.pi*f
    raw=[]
    for freq,duty,window,phase in ((77.13,100/220,10.5*33/183,.0),
                                 (202.310,100/270,10.5*51/151,.0),
                                 (202.396,68/150,10.5*51/151,.0)):
        p=(t*freq+phase)%1
        raw.append(window*(np.where(p<duty,p/duty,(1-p)/(1-duty))-.5))
    source=sum(P.filt(v,source_h(f)[j]) for j,v in enumerate(raw))
    tab=json.loads((ROOT/'sim/out/physical_vca_20260930/corrected_2D_transfer.json').read_text())
    result={}
    roll=1/(1+sj*6200*680e-12)
    # Full-frequency matrix is large and unnecessary for this ratio;
    # all main F/mirror M load ratios are nearly flat above77Hz.
    ff=float(abs(mixer(202.35)[0,0]))
    for field in ('10','01'):
        control=controls()[field];gain=control['absolute_gain']/10**(13/20)
        device=Input2D(tab,-20*np.log10(gain));rin=P.rin_of(device)
        h=sj*2.2e-6*rin/(1+sj*2.2e-6*rin);z=rin/(1+sj*2.2e-6*rin)
        pin,diag=P.nonlinear_coupling(source,h,z,device)
        for name in ('source','linear','joint'):
            v=source if name=='source' else P.filt(output(pin,gain,device,name),roll)*ff
            p=spectrum(v);ref=B.line(p,202.35,1.2)
            result[field+'_'+name]=dict(A_vs_pair_dB=B.db_power(B.line(p,77.13,1.2)/ref),
                             pair_rms_V=float(np.sqrt(ref)),A_rms_V=float(np.sqrt(B.line(p,77.13,1.2))))
        result[field+'_input_KCL']=diag;result[field+'_control']=control
    return result


def coherent_a_response():
    x=np.load(ROOT/'sim/out/othercars_20260930/cab700_820.npy')
    from scipy.signal import butter,sosfiltfilt
    envelopes={}
    for n in (1,2,3,5):
        z=resample_poly(x*np.exp(-2j*np.pi*77.13*n*np.arange(len(x))/16000),1,4000)
        envelopes[n]=sosfiltfilt(butter(4,.05,fs=4,output='sos'),z)[80:400]
    result={};duty=100/220
    for n in (2,3,5):
        # Restore the common demodulation center for own harmonic phase.
        phase=np.angle(envelopes[n])-n*np.angle(envelopes[1])
        weight=abs(envelopes[n])*abs(envelopes[1])
        plv=abs(np.sum(weight*np.exp(1j*phase)))/weight.sum()
        ratio=abs(envelopes[n])/np.maximum(abs(envelopes[1]),1e-12)
        nominal=abs(np.sin(n*np.pi*duty)/(n*n*np.sin(np.pi*duty)))
        result[str(n)]=dict(phase_locking=float(plv),
            relative_A1_dB_percentiles=[float(v) for v in np.percentile(20*np.log10(ratio),[10,50,90])],
            effective_response_vs77_dB_percentiles=[float(v) for v in np.percentile(20*np.log10(ratio/nominal),[10,50,90])],
            warning='Empirical coherent-family ratio: includes VCA distortion, source-duty tolerance and acoustic/spatial path. Not a fitted production filter.')
    return result


def separate_I(core,cabinet):
    result={}
    for name,data,fs,frequencies in [('cabinet',cabinet,16000,[385.469,5*77.13]),
        ('core',core[3*FS:7*FS],FS,[rates()[1]*48000/(39935064/832),
                                  5*39935064/(235347+282416)*48000/(39935064/832)])]:
        t=np.arange(len(data))/fs;w=np.sqrt(np.hanning(len(data)))
        m=np.column_stack([v for f in frequencies for v in (np.cos(2*np.pi*f*t),np.sin(2*np.pi*f*t))]
                           +[np.ones(len(data))])
        coefficients=np.linalg.lstsq(m*w[:,None],data*w,rcond=None)[0]
        result[name]=dict(frequencies_Hz=frequencies,condition_number=float(np.linalg.cond(m*w[:,None])),
            fitted_sine_rms_PCM=[float(np.linalg.norm(coefficients[2*j:2*j+2])/np.sqrt(2)) for j in range(2)],
            warning='Four-second weighted two-carrier estimate, not exact isolated stems; modulation/nearby products are omitted.')
    return result


def fixedpoint_reference(out):
    curve=mc3340_curve(ROOT.parent/'turbo/docs/reference/MC3340.pdf')
    controls_grid=1.5+np.arange(321)/64
    signed=-10**(13/20)*gain_from_curve(controls_grid,curve)
    lines=['control_V,signed_gain_V_per_V,signed_gain_Q16']
    lines.extend(f'{v:.6f},{g:.9f},{round(g*65536)}' for v,g in zip(controls_grid,signed))
    (out/'MC3340_absolute_gain_Q16.csv').write_text('\n'.join(lines)+'\n')
    input_gain=-10**(13/20)*float(gain_from_curve(3.,curve))
    second_gain=-10**(13/20)*float(gain_from_curve(3.15,curve))
    return dict(source='Original Motorola MC3340/D Figure3 12V plus13dB typical gain',
        source_sha256=curve['sha256'],control_min_V=1.5,control_step_V=1/64,entries=321,
        IC17_at3V_signed_Q16=round(input_gain*65536),IC28_at315V_signed_Q16=round(second_gain*65536),
        signed_gain_width_bits=20,absolute_voltage_width_bits_Q16=21,
        warning='Linear gain reference only, accepted MC3340 proxy P1. Not an asymmetric ROM or an overload law.')


def source_bounds():
    # Generous corner screen: timing caps not varied because they do not
    # determine the Schmitt window. Duty extremes vary Rc/Ri +/-5% at
    # equal bias. Do not constrain to measured rate, making this permissive.
    def unit(window,duty):
        return window*np.sin(np.pi*duty)/(np.pi**2*duty*(1-duty))/np.sqrt(2)
    def win(rr,rf):return 10.5*rr/(rr+rf)
    da=np.r_[np.linspace(100*.95/(220*1.05),100*1.05/(220*.95),1001)]
    db=np.linspace(100*.95/(270*1.05),100*1.05/(270*.95),1001)
    dc=np.linspace(68*.95/(150*1.05),68*1.05/(150*.95),1001)
    wa=win(33*.95,150*1.05);wb=win(51*1.05,100*.95)
    amin=min(unit(wa,da))/(3300*1.05)
    bmax=max(unit(wb,db))/(3300*.95)
    cmax=max(unit(wb,dc))/(10000*.95)
    return dict(A_over_max_constructive_BplusC_dB=float(20*np.log10(amin/(bmax+cmax))),
        duty_preserving_A_witness=dict(C34_nF=23.1,R125_ohm=220000*83.05080553608501/(77.13*1.05),
                                      R121_ohm=100000*83.05080553608501/(77.13*1.05),
                                      resistor_change_percent=100*(83.05080553608501/(77.13*1.05)-1)),
        warning='Permissive +/-5% timing/mixing resistor corner screen, equal nominal bias, ideal output swing, negligible coupling correction. Not a guaranteed bound on unknown silicon/acoustics.')


def envelope_metrics(data,fs,beat):
    from scipy.signal import butter,sosfiltfilt,hilbert
    band=sosfiltfilt(butter(4,[250,900],btype='bandpass',fs=fs,output='sos'),data)
    env=sosfiltfilt(butter(4,20,fs=fs,output='sos'),abs(hilbert(band)))
    env=resample_poly(env,200,fs)[50:-50]
    mean=float(env.mean());window=np.hanning(len(env))
    z=np.fft.rfft((env-mean)*window)
    f=np.fft.rfftfreq(len(env),1/200)
    power=abs(z)**2*2/(len(env)*np.sum(window**2))
    return dict(method='250-900Hz Butterworth4 zero-phase; Hilbert magnitude; 20Hz Butterworth4; 200Hz resample; trim0.25s each edge',
        envelope_p05_p95_over_peak=[float(v/env.max()) for v in np.percentile(env,[5,95])],
        beat_band_rms_over_mean=float(np.sqrt(power[abs(f-beat)<.4].sum())/mean),
        warning='Contains Other Cars harmonics as well as engine. Not the unspecified quoted envelope metric.')


def a_harmonics(core,cabinet):
    pp=[spectrum(core,3),B.spectrum(cabinet)]
    result={}
    duty=100/220
    for n in (2,3,5):
        expected=20*np.log10(abs(np.sin(n*np.pi*duty)/(n*n*np.sin(np.pi*duty))))
        ratios=[B.db_power(B.line(p,77.13*n,1.2)/B.line(p,77.13,1.2)) for p in pp]
        result[str(n)]=dict(nominal_source_dB=expected,core_dB=ratios[0],cabinet763_dB=ratios[1],
                           apparent_response_vs77_dB=ratios[1]-expected,
                           warning='Cabinet harmonic band can include engine/other products; no transfer identification from four-second band alone.')
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--physical',action='store_true')
    ap.add_argument('--out',type=Path,default=ROOT/'sim/out/s37_products_20260930')
    args=ap.parse_args();out=args.out;out.mkdir(parents=True,exist_ok=True)
    fs,core=wavfile.read(ROOT/'sim/out/audio_oc/turbo_audio_l_scen37.wav')
    assert fs==FS and core.ndim==1
    core=core.astype(float)/32768
    _,right=wavfile.read(ROOT/'sim/out/audio_oc/turbo_audio_r_scen37.wav')
    right=right.astype(float)/32768
    p=spectrum(core,3);ref=B.line(p,202.35,1.2)
    measured=metrics(core,ref,begin=3)
    x=np.load(ROOT/'sim/out/othercars_20260930/cab700_820.npy')[63*B.FS:67*B.FS]
    cp=B.spectrum(x);cr=B.line(cp,202.35,1.2)
    cab=dict(relative_pair_dB={n:B.db_power(B.line(cp,h,1.2)/cr) for n,h in LINES.items()})
    cab['products_over_T_dB']={n:cab['relative_pair_dB'][n]-cab['relative_pair_dB']['T'] for n in ('I','P444','P743')}
    t,i,s=B.CAB_RATES
    cab['twin_line_ratios']={}
    for name,main,lower in [('P444',2*i-t,i+2*s),('P743',2*i-s,t+i+s)]:
        delta=B.db_power(B.line(cp,lower,1.2)/B.line(cp,main,1.2));r=10**(delta/20)
        cab['twin_line_ratios'][name]=dict(lower_over_main_dB=delta,lower_over_main_amplitude=r,
                                         ideal_two_line_envelope_min_over_max=abs(1-r)/(1+r))
    stk=(ROOT/'rtl/audio/stk439.sv').read_text()
    pot=int(re.search(r'POT_K_Q16\s*=\s*(\d+)',stk).group(1))/65536
    # Current emitted STK constant and house-to-PCM scale, no normalization fit.
    conversion=4096/32768*1133694/65536*pot
    fast,sweep=fast_cases(out,ref,conversion)
    result=dict(source_commit='4efd013',source_sha256=hashlib.sha256((ROOT/'rtl/audio/turbo_playercar_chan.sv').read_bytes()).hexdigest(),
        core=measured,cabinet763=cab,engine_bus_V_to_current_PCM=conversion,
        OC_pair_core_rms_PCM=float(np.sqrt(ref)),fast_cases=fast,control_R_tolerance_sweep=sweep,
        acoustic_requirement=acoustic_requirement(measured,cab),A_harmonics=a_harmonics(core,x),
        OtherCars_device_probe=oc_source_check(out),coherent_A_harmonics=coherent_a_response(),
        IC7_vs_A5_decomposition=separate_I(core,x),source_R_tolerance_screen=source_bounds(),
        fixedpoint_gain_reference=fixedpoint_reference(out))
    result['channel_comparisons']={}
    for name,wave in [('F',core),('W',right),('FplusW',core+right)]:
        data=wave[3*FS:7*FS]
        result['channel_comparisons'][name]=dict(**metrics(wave,ref,rates()*48000/(39935064/832),begin=3),
            crest=float(np.max(abs(data))/np.std(data)),
            time_above15pct=float(np.mean(abs(data)>.15*np.max(abs(data)))))
    result['explicit_band_envelope']={
        'core':envelope_metrics(core[3*FS:7*FS],FS,result['channel_comparisons']['F']['beat_Hz']),
        'cabinet':envelope_metrics(x,16000,float(B.CAB_RATES[1]-B.CAB_RATES[0]-2*B.CAB_RATES[2]))}
    if args.physical:
        cases,notes=physical_cases(out,ref,conversion);result.update(physical_cases=cases,physical_notes=notes)
    (out/'audit.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({n:result[n] for n in ('core','cabinet763','fast_cases','acoustic_requirement')},indent=2))


if __name__=='__main__':main()
