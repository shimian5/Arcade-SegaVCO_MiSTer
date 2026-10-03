#!/usr/bin/env python3
"""Export a reviewable fixed-point candidate and exact external load matrices.

This is a DIAGNOSTIC artifact, not an approved VCA ROM or RTL modification.
The device model still has Figure3/native-control and Figure7 limitations.
"""
from __future__ import annotations
import json
from pathlib import Path
import numpy as np
from scipy.signal import cont2discrete
from playercar_absolute_gain_diagnose import output_network

OUT=Path('sim/out/physical_vca_20260930')
FS=48000


def matrices(ron=300.,c108=2.2e-6):
    # o,q,d,F,W,M plus four series-capacitor output nodes.
    g=np.zeros((10,10));b=np.zeros((10,2));e=np.zeros((10,4))
    def ground(n,gs):g[n,n]+=gs
    def branch(a,c,gs):
        g[a,a]+=gs;g[c,c]+=gs;g[a,c]-=gs;g[c,a]-=gs
    ground(0,1/(200+ron)+2/51000);b[0,0]=1/(200+ron)
    branch(0,1,1/8200);ground(1,1/10000)
    ground(2,1/12000+1/100200);b[2,1]=1/100200
    ground(3,1/22000+5/100000+2/22000)
    ground(4,1/22000+4/100000);ground(5,1/22000+11/100000)
    for k,(a,c,d,r) in enumerate(((1,6,4,68000),(2,7,3,100000),(2,8,4,100000),(2,9,5,100000))):
        e[a,k]=1;e[c,k]=-1;branch(c,d,1/r)
    gi=np.linalg.inv(g);li=np.linalg.inv(e.T@gi@e);h=e.T@gi@b
    ci=np.diag(1/np.array([c108,1e-6,1e-6,1e-6]))
    ac=-ci@li;bc=ci@li@h
    select=np.zeros((3,10));select[np.arange(3),[3,4,5]]=-100000/22000
    cc=select@gi@e@li;dc=select@(gi@b-gi@e@li@h)
    ad,bd,cd,dd,_=cont2discrete((ac,bc,cc,dc),1/FS,method='bilinear')
    freq=np.geomspace(.01,3000,160)
    def response(a,b,c,d,f,discrete):
        z=np.exp(2j*np.pi*f/FS) if discrete else 2j*np.pi*f
        return np.array([c@np.linalg.solve(zi*np.eye(4)-a,b)+d for zi in z])
    continuous=response(ac,bc,cc,dc,freq,False)
    exact=output_network(freq,ron=ron,ic28_rout=200.)[:,2:,:]
    assert np.max(abs(continuous-exact))<1e-11
    warped=FS/np.pi*np.tan(np.pi*freq/FS)
    discrete=response(ad,bd,cd,dd,freq,True)
    continuous_warped=response(ac,bc,cc,dc,warped,False)
    assert np.max(abs(discrete-continuous_warped))<1e-9
    qmat=[np.round(x*2**30).astype(np.int64) for x in (ad,bd,cd,dd)]
    assert max(np.max(abs(x)) for x in qmat)<2**31
    quantized=response(*[x/2**30 for x in qmat],freq,True)
    audio=freq>=20
    return dict(Fs_Hz=FS,states='Four Tustin-transformed coupling-capacitor voltages, incremental AC; initialize from the chosen physical DC operating point.',
        inputs=['IC17_lower_emitter_V','IC28_emitter_V'],outputs=['F_LF351_V','W_LF351_V','M_LF351_V'],
        initialization='For absolute constant source u0 initialize x0=solve(I-A,B*u0), y0 is zero audio. Alternatively subtract a fixed quiescent source reference and initialize incremental states to zero. Do not recenter by control or waveform mean.',
        continuous={k:v.tolist() for k,v in zip(('A','B','C','D'),(ac,bc,cc,dc))},
        discrete={k:v.tolist() for k,v in zip(('A','B','C','D'),(ad,bd,cd,dd))},
        discrete_Q30={k:v.tolist() for k,v in zip(('A','B','C','D'),qmat)},
        checks=dict(max_continuous_KCL_transfer_error=float(np.max(abs(continuous-exact))),
            max_Tustin_warped_error=float(np.max(abs(discrete-continuous_warped))),
            max_Q30_frequency_response_absolute_error=float(np.max(abs(quantized-discrete))),
            max_Q30_audio_response_error_dB=float(np.max(abs(20*np.log10(abs(quantized[audio])/abs(discrete[audio]))))),
            Q30_residual_DC_gain=(qmat[2]/2**30@np.linalg.solve(np.eye(4)-qmat[0]/2**30,qmat[1]/2**30)+qmat[3]/2**30).tolist(),
            Q30_state_spectral_radius=float(max(abs(np.linalg.eigvals(qmat[0]/2**30))))))


def main():
    table=json.loads((OUT/'corrected_2D_transfer.json').read_text())
    qout=np.round(np.array(table['vout'])*2**16).astype('<i4')
    qi=np.round(np.array(table['input_current'])*2**36).astype('<i4')
    qout.tofile(OUT/'candidate_vout_Q16.bin');qi.tofile(OUT/'candidate_input_current_Q36.bin')
    spec=dict(status='UNVALIDATED device candidate; no production RTL/LUT approval',
        device_scope=table['warning'],ROM=dict(rows=len(table['attenuation_db']),columns=len(table['vin']),
            vin_min_V=table['vin'][0],vin_step_V=1/32,attenuation_db=table['attenuation_db'],
            layout='Row-major little-endian signed int32. Rows attenuation, columns absolute input voltage.',
            interpolation='Bilinear; row interpolation in gain alpha=10^(-attenuation/20), not in dB. Keep absolute output DC.',
            voltage_fraction_bits=16,current_fraction_bits=36,
            extrapolation='None approved. Reject any render leaving the characterized input domain.'),
        formats=dict(pin_and_output='signed32 Q16 volts',control='signed32 Q16 volts',
            source_gain_coordinate='unsigned32 Q24',input_current='signed32 Q36 amperes',
            capacitor_voltage_state='signed32 Q24 volts',matrix='signed32 Q30',
            multiply_accumulate='signed72 or wider, round once after each sum',
            output='Q16 volts at actual LF351 mixer, explicit conversion to existing Q12 taps; no FW_LOAD=1/3'),
        passive_output=matrices())
    (OUT/'fixedpoint_candidate_spec.json').write_text(json.dumps(spec,indent=2)+'\n')
    print(json.dumps(spec['passive_output']['checks'],indent=2))


if __name__=='__main__':main()
