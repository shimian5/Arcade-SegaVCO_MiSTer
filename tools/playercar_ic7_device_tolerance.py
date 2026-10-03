#!/usr/bin/env python3
"""D8 IC7 timing, loaded output states and BOM tolerance; never edits RTL.

No cabinet frequency is used to choose parameters. Delay values are a
sensitivity grid, not characterized LM2902 delays in this circuit. Uniform
tolerance draws illustrate an engineering envelope, not production odds.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import numpy as np
from scipy.optimize import root
import playercar_d8_ic17_reference as R

CELLS = {'T': (270e3,120e3,4.7e-9), 'S': (220e3,100e3,68e-9),
         'I': (150e3,68e3,6.8e-9)}


def rate(bus, rin, rsink, capacitance, bias=.5, rref=51e3, rfeed=100e3,
         high=10.5, low=0., vsat=0., delay_low=0., delay_high=0.):
    half = bus*bias
    fall = (bus-half)/rin/capacitance
    rise = ((half-vsat)/rsink-(bus-half)/rin)/capacitance
    window = rref/(rref+rfeed)*(high-low)
    period = window*(1/fall+1/rise)
    # Ramp keeps moving during recovery. Its overshoot must be traversed
    # on the next ramp, which explains the two slope-ratio multipliers.
    period += delay_low*(1+fall/rise)+delay_high*(1+rise/fall)
    return 1/period


def transistor(bus, high=10.5, beta=240., reverse_beta=1.):
    """TR6 generic junction estimate, anchored to published 2mA VBE=.67V.

    Reverse beta is unpublished; its sweep is not a characterized VCEsat.
    D14=.70 V is the existing diode-drop approximation, not a measured drop.
    """
    vt=.02585; isat=.002/np.exp(.67/vt)
    def eq(x):
        base, collector=x
        f=isat*np.expm1(np.clip(base/vt,-40,40))
        rev=isat*np.expm1(np.clip((base-collector)/vt,-40,40))
        ic=f-rev*(1+1/reverse_beta)
        ib=f/beta+rev/reverse_beta
        return [(high-.7-base)/1e4-base/2200-ib,
                (bus/2-collector)/68000-ic]
    sol=root(eq,[.67,.025],tol=1e-11)
    if np.max(np.abs(eq(sol.x)))>1e-10: raise RuntimeError('TR6 KCL failure')
    base,coll=sol.x
    ib=(high-.7-base)/1e4-base/2200
    ic=(bus/2-coll)/68000
    return dict(beta=beta,reverse_beta=reverse_beta,base_v=base,collector_v=coll,
                base_current_uA=ib*1e6,collector_current_uA=ic*1e6,forced_beta=ic/ib)


def tolerance(n=100000, seed=8340123):
    rng=np.random.default_rng(seed)
    rv=lambda nominal:nominal*rng.uniform(.95,1.05,n)
    rtap,rbottom=rv(4700.),rv(15000.)
    cells={}
    conductance=1/rbottom
    for name,(ri,rs,c) in CELLS.items():
        ri,rs,c=rv(ri),rv(rs),rv(c)
        top,bottom=rv(51000.),rv(51000.)
        bias=bottom/(top+bottom)
        conductance+=1/(top+bottom)+(1-bias)/ri
        cells[name]=(ri,rs,c,bias,rv(51000.),rv(100000.))
    ratio=1/(1+rtap*conductance)
    bus=R.ladder_v(42)*ratio
    rates={name:rate(bus,*parts[:3],bias=parts[3],rref=parts[4],rfeed=parts[5])
           for name,parts in cells.items()}
    delta=rates['I']-rates['T']-2*rates['S']
    summarize=lambda x:dict(zip(('p01','p05','p50','p95','p99'),
                               map(float,np.percentile(x,[1,5,50,95,99]))))
    return dict(draws=n,seed=seed,assumptions='Independent uniform +/-5% R and timing C; C19 +/-5% is assumed, not explicit in its BOM row. Fixed nominal raw ladder. VOH/VOL=10.5/0; no delays.',
                bus_ratio=summarize(ratio),rates_Hz={k:summarize(v) for k,v in rates.items()},
                signed_I_minus_T_minus_2S_Hz=summarize(delta),
                rate_correlation=np.corrcoef([rates[k] for k in ('T','S','I')]).tolist())


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=Path('sim/out/vca_ic7_20260930'))
    a=ap.parse_args();a.out.mkdir(parents=True,exist_ok=True)
    bus=R.ladder_v(42)*R.BUS_LOADED
    nominal={k:float(rate(bus,*v)) for k,v in CELLS.items()}
    device=[]
    for high,low,vsat in ((10.2,0.,0.),(10.4,0.,0.),(10.5,0.,0.),(10.6,0.,0.),(10.8,0.,0.),
                          (10.5,.5,0.),(10.5,0.,.025),(10.5,0.,.05),(10.5,0.,.2)):
        device.append(dict(high=high,low=low,vsat=vsat,
                           rate_I_Hz=float(rate(bus,*CELLS['I'],high=high,low=low,vsat=vsat))))
    delays=[]
    for dl in (0,10,20,30,40):
        rates={k:float(rate(bus,*v,delay_low=dl*1e-6,delay_high=2e-6)) for k,v in CELLS.items()}
        delays.append(dict(delay_low_us=dl,delay_high_us=2.,rates_Hz=rates))
    tr=[transistor(bus,beta=b,reverse_beta=br) for b in (160.,240.,320.) for br in (.5,1.,5.)]
    actual_tr=tr[4]
    high=10.5
    # D1: 1k/1k divider, one 470uF to +12 and one to ground. With
    # the supply an AC reference, their capacitances are in parallel.
    reference=[]
    for hz in (27.,324.,397.):
        impedance=abs(1/(1/500+2j*np.pi*hz*940e-6))
        step=10.5/151000
        reference.append(dict(hz=hz,impedance_ohm=impedance,
                               single_comparator_step_uV=step*impedance*1e6))
    report=dict(bus_v=bus,nominal_RC_rates_Hz=nominal,device_state_sensitivity=device,
                reference_D1=dict(resistors_ohm=[1000,1000],capacitors_uF=[470,470],ac=reference,
                                  note='DC reference offset shifts both thresholds equally; this impedance calculation assumes stiff +12V and nominal fitted capacitors.'),
                comparator_source_current_uA=((high-.7-actual_tr['base_v'])/10000+(high-6)/151000)*1e6,
                comparator_low_required_sink_uA=6/151000*1e6,
                transistor_estimates=tr,recovery_sensitivity=delays,
                C21_only_5percent_bounds_Hz=[nominal['I']/1.05,nominal['I']/.95],
                tolerance=tolerance())
    (a.out/'ic7_device_tolerance.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':main()
