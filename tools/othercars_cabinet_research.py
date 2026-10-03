#!/usr/bin/env python3
"""D5/D6 Other Cars source/level audit; no RTL mutation.

Measured frequencies describe ONE cabinet profile. Component witnesses prove
feasibility; they do not identify the actual fitted components. Absolute VCA
gains are small-signal MC3340 references, not an approved MB4391 overload law.
"""
from pathlib import Path
import argparse
import json
import subprocess
import numpy as np
import imageio_ffmpeg
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
from scipy.io import wavfile
from scipy.optimize import brentq, least_squares
from scipy.signal import butter, sosfiltfilt, resample_poly
from playercar_vco_curve_check import mc3340_curve, gain_from_curve
import playercar_brightness_diagnose as B

ROOT = Path(__file__).resolve().parents[1]
FS = 16000
BUS = 12*10/43
GMAX = 10**(13/20)
CELLS = {
    'A': dict(ri=220e3, rc=100e3, cap=22e-9, rr=33e3, rf=150e3,
              mix=3300., measured=77.13),
    'B': dict(ri=270e3, rc=100e3, cap=4.7e-9, rr=51e3, rf=100e3,
              mix=3300., measured=202.31022),
    'C': dict(ri=150e3, rc=68e3, cap=6.8e-9, rr=51e3, rf=100e3,
              mix=10000., measured=202.39611),
}


def rate(p, ri=None, rc=None, cap=None):
    ri = p['ri'] if ri is None else ri
    rc = p['rc'] if rc is None else rc
    cap = p['cap'] if cap is None else cap
    window = 10.5*p['rr']/(p['rr']+p['rf'])
    return BUS*(ri-rc)/(2*window*cap*ri**2)


def source_h(hz):
    s=2j*np.pi*np.atleast_1d(hz)
    y=np.array([s*2.2e-6/(1+s*2.2e-6*p['mix']) for p in CELLS.values()])
    return -3.9*y/(1/1000+y.sum(axis=0))


def sources():
    out={}
    for j,(name,p) in enumerate(CELLS.items()):
        window=10.5*p['rr']/(p['rr']+p['rf'])
        duty=p['rc']/p['ri']
        amplitude=window/2*abs(source_h([p['measured']])[j,0])
        fundamental=2*amplitude*np.sin(np.pi*duty)/(np.pi**2*duty*(1-duty))/np.sqrt(2)
        # Timing-resistor +/-5% envelope, holding the common bus, 51k bias
        # dividers and Schmitt divider nominal. Ri has an interior extremum.
        candidates=[]
        for rc in (.95*p['rc'],1.05*p['rc']):
            for ri in (.95*p['ri'],1.05*p['ri'],np.clip(2*rc,.95*p['ri'],1.05*p['ri'])):
                for cap in (.95*p['cap'],1.05*p['cap']):
                    candidates.append(rate(p,ri,rc,cap))
        cap_witness=p['cap']*rate(p)/p['measured']
        rc_witness=p['rc']
        if cap_witness>1.05*p['cap']:
            cap_witness=1.05*p['cap']
            rc_witness=p['ri']-p['measured']*2*window*cap_witness*p['ri']**2/BUS
        out[name]=dict(**p,nominal_Hz=rate(p),duty_up=duty,triangle_Vpp=window,
            summer_half_amplitude_V=amplitude,fundamental_Vrms=fundamental,
            cap_only_Hz=[rate(p)/1.05,rate(p)/.95],
            timing_R_C_5pct_Hz=[min(candidates),max(candidates)],
            witness_cap_F=cap_witness,witness_rc_ohm=rc_witness,
            witness_cap_percent=100*(cap_witness/p['cap']-1),
            witness_rc_percent=100*(rc_witness/p['rc']-1),
            witness_Hz=rate(p,rc=rc_witness,cap=cap_witness))
        up=round(39935064/p['measured']*duty)
        down=round(39935064/p['measured']*(1-duty))
        amplitude_code=round(window/2*abs(source_h([1e6])[j,0])*4096)
        out[name]['profile_counter_nominal_duty']=dict(N_UP=up,N_DOWN=down,A=amplitude_code,
            STEP_UP=round(2*amplitude_code*65536/up),STEP_DOWN=round(2*amplitude_code*65536/down),
            actual_Hz=39935064/(up+down))
        assert abs(out[name]['witness_Hz']-p['measured'])<1e-8
        assert .95*p['cap']<=cap_witness<=1.05*p['cap']
        assert .95*p['rc']<=rc_witness<=1.05*p['rc']
    return out


def mixer(hz):
    """Four VCA sources (F,L,R,W), 200ohm out, two 2.2uF legs each.

    Silent fitted source legs load all five passive buses. Other source
    impedances are treated as zero, as in the earlier physical ledger.
    Outputs are F,L,R,W,M LF351 outputs, signed per source.
    """
    s=2j*np.pi*hz
    a=np.zeros((9,9),complex);b=np.zeros((9,4),complex)
    def branch(i,j,y):
        a[i,i]+=y;a[j,j]+=y;a[i,j]-=y;a[j,i]-=y
    primary_r=[22000,100000,22000,100000]
    grounds=[1/22000+6/100000+1/22000,
             1/22000+2/100000,1/22000+2/100000,
             1/22000+4/100000+1/68000,1/22000+8/100000]
    for j in range(4):
        a[j,j]+=1/200;b[j,j]=1/200
        for node,r in ((4+j,primary_r[j]),(8,100000)):
            branch(j,node,s*2.2e-6/(1+s*2.2e-6*r))
    for j,g in enumerate(grounds):a[j+4,j+4]+=g
    result=np.linalg.solve(a,b)
    assert np.max(abs(a@result-b))<1e-14
    return -100000/22000*result[4:,:]


def controls():
    curve=mc3340_curve(ROOT.parent/'turbo/docs/reference/MC3340.pdf')
    out={}
    for field,pulldown in (('00',1/(1/10000+1/12000)),('01',12000.),('10',10000.)):
        dac=12*pulldown/(5600+pulldown)
        # Published external resistor network, generic MA150 proxy only.
        # Vf(I)=nVT log(1+I/Is); no cabinet-derived diode parameter.
        delta=max(dac-6,0.)
        i=brentq(lambda i:51000*i+1.9*.02585*np.log1p(i/1.8e-9)-delta,
                  0,max(delta/51000,1e-15)) if delta else 0.
        cont=6-100000*i
        gain=float(GMAX*gain_from_curve(cont,curve))
        corners=[float(GMAX*gain_from_curve(6-100000*max(delta-vf,0)/51000,curve))
                 for vf in (.45,.60)]
        out[field]=dict(dac_V=dac,diode_current_uA=i*1e6,CONT_V=cont,
                        absolute_gain=gain,absolute_Q16=round(gain*65536),
                        absolute_gain_Vf_045_060=sorted(corners))
    return out


def decode_cached(out, name, path, start, seconds):
    target=out/(name+'.npy')
    if target.exists():return np.load(target)
    cmd=[imageio_ffmpeg.get_ffmpeg_exe(),'-hide_banner','-loglevel','error',
         '-ss',str(start),'-t',str(seconds),'-i',str(path),'-ac','1',
         '-ar',str(FS),'-f','f32le','-']
    x=np.frombuffer(subprocess.run(cmd,check=True,stdout=subprocess.PIPE).stdout,dtype='<f4').astype(float)
    np.save(target,x);return x


def harmonic_peaks(x, fundamental, width=.012):
    n=len(x);f=np.fft.rfftfreq(n,1/FS)
    p=abs(np.fft.rfft((x-x.mean())*np.hanning(n)))**2
    rows=[]
    for k in (1,2,3):
        ix=np.flatnonzero(abs(f-k*fundamental)<k*width)
        idx=ix[np.argmax(p[ix])]
        rows.append(dict(harmonic=k,peak_Hz=float(f[idx]),divided_Hz=float(f[idx]/k)))
    return rows


def envelope(x,f,n):
    z=resample_poly(x*np.exp(-2j*np.pi*n*f*np.arange(len(x))/FS),1,4000)
    return sosfiltfilt(butter(4,n*.018,fs=4,output='sos'),z)[80:400]


def locking(x):
    out={}
    for name,p in CELLS.items():
        z1=envelope(x,p['measured'],1);row={}
        for n in (2,3):
            zn=envelope(x,p['measured'],n);w=abs(z1)*abs(zn)
            row[str(n)]=float(abs(np.sum(w*np.exp(1j*(np.angle(zn)-n*np.angle(z1)))))/w.sum())
        out[name]=row
    for source,other in (('B','C'),('C','B')):
        z1=envelope(x,CELLS[other]['measured'],1)
        for n in (2,3):
            zn=envelope(x,CELLS[source]['measured'],n);w=abs(z1)*abs(zn)
            # Different heterodyne centers must be restored before testing
            # physical phase locking between the two carriers.
            t=np.arange(len(z1))/4+20
            delta=2*np.pi*n*(CELLS[source]['measured']-CELLS[other]['measured'])*t
            out[source]['cross_'+str(n)]=float(abs(np.sum(w*np.exp(1j*(np.angle(zn)-n*np.angle(z1)+delta))))/w.sum())
    return out


def phase_fit(x):
    ref=202.31
    z=resample_poly(x*np.exp(-2j*np.pi*ref*np.arange(len(x))/FS),1,800)
    z=sosfiltfilt(butter(4,2,fs=20,output='sos'),z)[100:2300:2]
    t=np.arange(len(z))/10-55;scale=np.sqrt(np.mean(abs(z)**2))
    result=[]
    for pair in (False,True):
        def vectors(p):
            v=np.exp(1j*(p[0]+2*np.pi*p[1]*t+np.pi*p[2]*t*t))
            if pair:v+=p[6]*np.exp(1j*(p[3]+2*np.pi*p[4]*t+np.pi*p[5]*t*t))
            amp=np.maximum(np.real(z*np.conj(v))/abs(v)**2,0)
            return amp,v
        def residual(p):
            a,v=vectors(p);r=(z-a*v)/scale
            return np.r_[r.real,r.imag]
        if pair:
            bounds=([-np.pi,-.1,-.001,-np.pi,.035,-.001,.03],
                    [np.pi,.1,.001,np.pi,.15,.001,.95])
            starts=[[.8,0,-.0002,ph,.086,0,.4] for ph in np.linspace(-2.9,2.9,7)]
        else:
            bounds=([-np.pi,-.1,-.001],[np.pi,.1,.001]);starts=[[.8,0,-.0002]]
        fits=[least_squares(residual,p,bounds=bounds,max_nfev=350) for p in starts]
        fit=min(fits,key=lambda v:np.sum(v.fun**2));p=fit.x;a,v=vectors(p)
        row=dict(pair=pair,parameters=p.tolist(),reference_Hz=ref,
            residual_fraction=float(np.sqrt(np.mean(abs((z-a*v)/scale)**2))),
            mean_B_line_rms_PCM=float(np.sqrt(2)*np.mean(a)),mid_B_Hz=ref+p[1],
            B_drift_Hz_per_s=p[2])
        if pair:row.update(mid_C_Hz=ref+p[4],C_drift_Hz_per_s=p[5],
            C_over_B_amplitude=p[6],C_over_B_dB=float(20*np.log10(p[6])))
        result.append(row)
    return result


def samples(out, src):
    fs=48000;t=np.arange(20*fs)/fs
    for profile in ('nominal','cabinet_tolerance'):
        waves=[]
        for j,(name,p) in enumerate(src.items()):
            f=p['nominal_Hz'] if profile=='nominal' else p['measured']
            d=p['witness_rc_ohm']/p['ri'] if profile!='nominal' else p['duty_up']
            phase=(t*f+.17*j)%1
            tri=p['triangle_Vpp']*(np.where(phase<d,phase/d,(1-phase)/(1-d))-.5)
            grid=np.fft.rfftfreq(len(tri),1/fs)
            waves.append(np.fft.irfft(np.fft.rfft(tri)*source_h(grid)[j],n=len(tri)))
        composite=sum(waves)
        # Floating WAV, one fixed scale for BOTH files: PCM unity=4V at
        # IC14 output. No per-file normalization, VCA or acoustic filtering.
        wavfile.write(out/(profile+'_three_cells_preVCA_4VFS.wav'),fs,(composite/4).astype('float32'))


def plot_pair(out, x):
    n=len(x);f=np.fft.rfftfreq(n,1/FS)
    p=abs(np.fft.rfft((x-x.mean())*np.hanning(n)))**2
    fig,axes=plt.subplots(3,1,figsize=(9,7),sharex=True)
    for k,ax in enumerate(axes,1):
        mask=(f/k>202.22)&(f/k<202.45)
        ax.plot(f[mask]/k,10*np.log10(np.maximum(p[mask]/p[mask].max(),1e-20)))
        for name,c in [('B','tab:red'),('C','tab:green')]:
            ax.axvline(CELLS[name]['measured'],color=c,ls='--',label=name)
        ax.set_ylim(-55,2);ax.set_ylabel(f'Harmonic {k}\nrelative dB');ax.grid(alpha=.3)
    axes[0].legend();axes[-1].set_xlabel('FFT frequency / harmonic number (Hz)')
    fig.suptitle('Original cabinet 700-820 s: close Other Cars carrier families')
    fig.tight_layout();fig.savefig(out/'close_pair.png',dpi=160);plt.close(fig)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=ROOT/'sim/out/othercars_20260930')
    args=ap.parse_args();out=args.out;out.mkdir(parents=True,exist_ok=True)
    src=sources();g=controls()
    cab=ROOT.parent/'turbo/docs/reference/turbo_cabinet_recording.weba'
    x=decode_cached(out,'cab700_820',cab,700,120)
    later=decode_cached(out,'cab900_1020',cab,900,120)
    levels={}
    for start in (748,763,764,792):
        p=B.spectrum(x[(start-700)*FS:(start-696)*FS])
        rms={name:float(np.sqrt(B.line(p,hz,1.2))) for name,hz in
             [('OC_pair',202.35),('A',77.13),('T',326.766),('I',385.469),('engine444',444.156),('engine743',743.328)]}
        levels[str(start)]=dict(line_rms_PCM=rms,pair_over_T_dB=20*np.log10(rms['OC_pair']/rms['T']),
                               pair_over_444_dB=20*np.log10(rms['OC_pair']/rms['engine444']))
    ledger={}
    for field,control in g.items():
        ledger[field]={}
        for name,p in src.items():
            h=mixer(p['measured']);v=p['fundamental_Vrms']*control['absolute_gain']
            ledger[field][name]=dict(preVCA_fundamental_Vrms=p['fundamental_Vrms'],
                VCA_linear_fundamental_Vrms=v,
                main_linear_Vrms={bus:float(v*abs(h[j,j])) for j,bus in enumerate(('F','L','R','W'))},
                M_per_spatial_source_linear_Vrms=[float(v*abs(h[4,j])) for j in range(4)])
    fit=phase_fit(x)
    phone=decode_cached(out,'newrecording',ROOT/'docs/newrecording.mp4.mp4',0,60)
    phone_p=np.median([B.spectrum(phone[j:j+4*FS]) for j in range(4*FS,len(phone)-4*FS,4*FS)],axis=0)
    report=dict(bus_V=BUS,sources=src,controls=g,linear_level_ledger=ledger,
        harmonic_peaks_700_820={n:harmonic_peaks(x,p['measured']) for n,p in CELLS.items()},
        harmonic_peaks_900_1020={n:harmonic_peaks(later,f) for n,f in [('A',77.125),('B',202.2667),('C',202.3861)]},
        harmonic_phase_locking=locking(x),two_carrier_phase_fit=fit,recording_levels=levels,
        second_cabinet_phone_peaks_Hz={name:B.observed_peak(phone_p,f,1) for name,f in [('A',81.3),('B',182.5),('C',208.3)]},
        raw_composite_nominal_Vrms=float(np.sqrt(sum((p['summer_half_amplitude_V']/np.sqrt(3))**2 for p in src.values()))),
        warnings=['R +/-5% is resistor-family assumption; cap +/-5% explicitly marked on sheet/BOM.',
                  'Nominal op-amp swing 10.5V and collector 0V are comparison references, not board measurements.',
                  'MC3340 generic diode control proxy and published typical curve do not characterize MB4391.',
                  'Linear VCA outputs are reference levels: composite input exceeds published 0.5Vrms limit.',
                  'Recording PCM levels do not identify board volts or unknown speaker/microphone response.',
                  'C/B recorded amplitude includes gating, acoustics and nonlinear combination products; not a source resistor ratio.'])
    (out/'othercars_research.json').write_text(json.dumps(report,indent=2)+'\n')
    (out/'two_carrier_phase_fit.json').write_text(json.dumps(fit,indent=2)+'\n')
    samples(out,src)
    plot_pair(out,x)
    print(json.dumps({k:report[k] for k in ('sources','controls','raw_composite_nominal_Vrms','recording_levels')},indent=2))


if __name__=='__main__':main()
