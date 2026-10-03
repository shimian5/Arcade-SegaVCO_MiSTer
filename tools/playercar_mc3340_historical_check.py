#!/usr/bin/env python3
"""Compare Motorola 1976 bias diodes with the later representative drawing.

No cabinet parameters. Resistances from later Figure2, omitted diodes from
the original 1976 drawing. Generic junction parameters remain assumptions;
the drawings do not establish that the two versions have identical values.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import numpy as np
from scipy.special import wrightomega
from scipy.optimize import brentq, root, least_squares
from playercar_mc3340_device import Device, G, A, IN, CONT, B, E, junction


class HistoricalDevice(Device):
    def __init__(self,*args,input_diode=True,control_diode=False,correct_control_pin=False,**kwargs):
        super().__init__(*args,**kwargs)
        self.input_diode=input_diode;self.control_diode=control_diode
        self.correct_control_pin=correct_control_pin;self.last_external_control=None

    def equations(self,x,control,vin=None):
        r,j=super().equations(x,control,vin)
        if self.correct_control_pin:
            # Pin2 is BELOW 3.9k, not the base/750/3.9k junction. Recover
            # that internal node's KCL, replacing the old forced-base row.
            ebe,dbe=junction((x[CONT]-x[E])/self.vt)
            ebc,dbc=junction((x[CONT]-self.vcc)/self.vt)
            ib=self.isat*((ebe-1)/self.beta+(ebc-1)/self.br)
            gbe=self.isat*dbe/self.vt/self.beta
            gbc=self.isat*dbc/self.vt/self.br
            r[CONT]=1000*((x[CONT]-x[B])/750+(x[CONT]-control)/3900+ib)
            j[CONT,:]=0
            j[CONT,CONT]=1000*(1/750+1/3900+gbe+gbc)
            j[CONT,B]=-1000/750;j[CONT,E]=-1000*gbe
        for node,resistance,enabled in ((G,510,self.input_diode),(A,4700,self.control_diode)):
            if not enabled:continue
            # Exact series resistor/diode current, avoiding exponential overflow.
            w=float(wrightomega(np.log(resistance*self.isat/self.vt)+
                               (x[node]+resistance*self.isat)/self.vt))
            current=self.vt/resistance*w-self.isat
            derivative=w/(resistance*(1+w))
            r[node]+=1000*(current-x[node]/resistance)
            j[node,node]+=1000*(derivative-1/resistance)
        return r,j

    def solve(self,control,vin=None):
        if not self.correct_control_pin:return super().solve(control,vin)
        if self.last_external_control is not None and abs(control-self.last_external_control)>.15:
            for c in np.linspace(self.last_external_control,control,int(abs(control-self.last_external_control)/.1)+2)[1:-1]:
                self.solve(float(c),vin)
        if vin is not None and self.last is not None and abs(vin-self.last[IN])>.08:
            for pin in np.linspace(self.last[IN],vin,int(abs(vin-self.last[IN])/.04)+2)[1:-1]:
                self.solve(control,float(pin))
        guess=np.array((5.7,5.,4.65,4.,4.5,3.85,self.vcc/11+.5,self.vcc/11+.6,
            self.vcc/11,self.vcc/11+.45,.9,1.,3.3,3.3,self.vcc-2.5,self.vcc-3.2)) if self.last is None else self.last.copy()
        if vin is not None:guess[IN]=vin
        result=root(lambda v:self.equations(v,control,vin)[0],guess,
                    jac=lambda v:self.equations(v,control,vin)[1],tol=1e-10)
        err=float(np.max(abs(self.equations(result.x,control,vin)[0])))
        if vin is not None and (not np.isfinite(err) or err>1e-6):
            # In deep cutoff a collector node is weakly determined. Restart
            # from the same-control quiescent root rather than that plateau.
            fresh=np.array((5.7,5.,4.65,4.,4.5,3.85,self.vcc/11+.5,self.vcc/11+.6,
                self.vcc/11,self.vcc/11+.45,.9,1.,3.3,3.3,self.vcc-2.5,self.vcc-3.2))
            quiet=root(lambda v:self.equations(v,control,None)[0],fresh,
                jac=lambda v:self.equations(v,control,None)[1],tol=1e-11)
            fresh=quiet.x.copy();fresh[IN]=vin
            result=root(lambda v:self.equations(v,control,vin)[0],fresh,
                jac=lambda v:self.equations(v,control,vin)[1],tol=1e-11)
            err=float(np.max(abs(self.equations(result.x,control,vin)[0])))
        if not np.isfinite(err) or err>1e-6:
            result=least_squares(lambda v:self.equations(v,control,vin)[0],guess,
                jac=lambda v:self.equations(v,control,vin)[1],x_scale='jac',xtol=1e-14,ftol=1e-14,gtol=1e-15,max_nfev=4000)
            err=float(np.max(abs(self.equations(result.x,control,vin)[0])))
        if err>1e-6:raise RuntimeError(f'Corrected control KCL failed: {control}, {vin}, {err}')
        self.max_residual=max(self.max_residual,err);self.last=result.x.copy();self.last_external_control=control
        return result.x


def table(vcc=12.,input_diode=True,control_diode=False,beta=100.,correct_control_pin=False):
    d=HistoricalDevice(vcc=vcc,beta=beta,input_diode=input_diode,control_diode=control_diode,correct_control_pin=correct_control_pin)
    quiet=d.solve(0.).copy();bias=float(quiet[IN]);on=d.pin_output(quiet)
    grid=np.linspace(-4.,5.,1801);y=[];i=[]
    for v in grid:
        sol=d.solve(0.,float(v));y.append(d.pin_output(sol));i.append(d.input_current(sol))
    off=d.pin_output(d.solve(9.))
    return dict(vcc=vcc,beta=beta,bias=bias,on_dc=on,off_dc=off,vin=grid.tolist(),vout=y,
                input_current=i,input_bias_diode=input_diode,control_bias_diode=control_diode,
                correct_control_pin=correct_control_pin,
                warning='Historical topology hypothesis with later resistor values and generic junctions; not validated full silicon.',
                max_kcl_residual_mA=d.max_residual)


def thd(y):
    z=np.fft.rfft(y-y.mean())
    return float(np.linalg.norm(z[2:50])/max(abs(z[1]),1e-30)*100)


def probe(vcc,diodes,correct_control_pin=False):
    d=HistoricalDevice(vcc=vcc,input_diode=diodes[0],control_diode=diodes[1],correct_control_pin=correct_control_pin)
    bias=float(d.solve(0.)[IN])
    def gain(c):
        lo=d.pin_output(d.solve(c,bias-.0001));hi=d.pin_output(d.solve(c,bias+.0001))
        return (hi-lo)/.0002
    g0=gain(0.);on_dc=d.pin_output(d.solve(0.));off_dc=d.pin_output(d.solve(9.))
    control10=brentq(lambda c:gain(c)/g0-10**(-10/20),2,9,xtol=1e-9)
    result=dict(vcc=vcc,input_diode=diodes[0],control_diode=diodes[1],correct_control_pin=correct_control_pin,input_bias=bias,
                max_gain=g0,max_gain_db=float(20*np.log10(abs(g0))),on_dc=on_dc,off_dc=off_dc,
                control_at_10dB=control10,THD_fixed_input=[],THD_constant_output=[])
    result['control_curve']=[dict(control_v=float(c),attenuation_db=float(-20*np.log10(max(abs(gain(float(c))/g0),1e-12)))) for c in np.arange(0.,6.51,.1)]
    phase=np.arange(256)*2*np.pi/256
    for att in (0.,10.,20.,30.,40.,50.):
        control=0 if att==0 else brentq(lambda c:gain(c)/g0-10**(-att/20),2,9,xtol=1e-9)
        for ei in (.1,2.5/abs(g0)):
            y=np.array([d.pin_output(d.solve(control,bias+np.sqrt(2)*ei*np.sin(p))) for p in phase])
            result['THD_fixed_input'].append(dict(attenuation_db=att,control_v=control,input_rms_v=ei,
                THD_percent=thd(y),output_mean_v=float(y.mean()),output_rms_v=float(y.std())))
        # Literal constant-output reading requires an input above the
        # allowed reference already near zero attenuation; preserve that flag.
        result['THD_constant_output'].append(dict(attenuation_db=att,
            required_small_signal_input_rms_v=2.5/(abs(g0)*10**(-att/20)),
            exceeds_published_0p5_Vrms=bool(2.5/(abs(g0)*10**(-att/20))>.5)))
    result['max_kcl_residual_mA']=d.max_residual
    return result


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=Path('sim/out/physical_vca_20260930'))
    ap.add_argument('--legacy-control-node',action='store_true',help='Reproduce the withdrawn base-node drive transcription')
    a=ap.parse_args();a.out.mkdir(parents=True,exist_ok=True)
    results=[]
    corrected=not a.legacy_control_node;prefix='corrected_' if corrected else 'historical_'
    tabs=[table(input_diode=x,control_diode=y,correct_control_pin=corrected) for x,y in ((False,False),(True,False),(True,True))]
    (a.out/(prefix+'on_transfer.json')).write_text(json.dumps(tabs,indent=2)+'\n')
    for vcc in (12.,16.):
        for diodes in ((False,False),(True,False),(True,True)):
            p=probe(vcc,diodes,corrected);results.append(p)
            (a.out/(prefix+'device_validation.json')).write_text(json.dumps(results,indent=2)+'\n')
            print('Probe',vcc,diodes,'gain',p['max_gain_db'],'DC shift',p['on_dc']-p['off_dc'],
                  'control10',p['control_at_10dB'],flush=True)
    (a.out/(prefix+'device_validation.json')).write_text(json.dumps(results,indent=2)+'\n')


if __name__=='__main__':main()
