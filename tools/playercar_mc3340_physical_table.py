#!/usr/bin/env python3
"""Unvalidated physical MC3340 candidate with the correctly connected pin2.

Gain-coordinate mapping uses ONLY the manufacturer attenuation curve. It
does not establish Figure7 agreement. Input and output DC remain absolute.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import numpy as np
from scipy.optimize import brentq
from playercar_mc3340_historical_check import HistoricalDevice
from playercar_mc3340_device import IN


def build(device=None,warning=None):
    d=device if device is not None else HistoricalDevice(input_diode=True,control_diode=True,correct_control_pin=True)
    quiet=d.solve(0.).copy();bias=float(quiet[IN]);g0=None
    def gain(c):
        return (d.pin_output(d.solve(c,bias+.0001))-d.pin_output(d.solve(c,bias-.0001)))/.0002
    g0=gain(0.);att=np.arange(0.,90.01,2.);v=np.linspace(-4.,5.,289)
    out=[];current=[];controls=[]
    for a in att:
        c=0. if a==0 else brentq(lambda c:gain(c)/g0-10**(-a/20),0,8.,xtol=1e-10)
        ys=[];ii=[]
        for pin in v:
            state=d.solve(c,float(pin));ys.append(d.pin_output(state));ii.append(d.input_current(state))
        out.append(ys);current.append(ii);controls.append(c)
        print('attenuation',a,'physical pin2',c,flush=True)
    return dict(vcc=d.vcc,bias=bias,max_signed_gain=g0,on_dc=d.pin_output(d.solve(0.)),
        off_dc=d.pin_output(d.solve(8.)),attenuation_db=att.tolist(),vin=v.tolist(),
        vout=out,input_current=current,physical_control_v=controls,
        input_bias_diode=True,control_bias_diode=True,correct_control_pin=True,
        max_kcl_residual_mA=d.max_residual,
        warning=warning or '1976 two-diode topology plus later resistor values, beta100, IS1e-14. Pin2 below3.9k. Gain-coordinate remapping to published Figure3 is explicit; Figure7 not validated. No cabinet parameters.')


class Input2D:
    def __init__(self,table,attenuation):
        self.tab=table;self.v=np.array(table['vin']);self.dv=self.v[1]-self.v[0]
        self.att=np.asarray(attenuation);grid=np.array(table['attenuation_db'])
        gains=10**(-grid/20);target=10**(-self.att/20)
        self.ai=np.clip(np.searchsorted(grid,self.att,side='right')-1,0,len(grid)-2)
        self.aw=(target-gains[self.ai])/(gains[self.ai+1]-gains[self.ai])
        self.y=np.array(table['vout']);self.i=np.array(table['input_current'])
        self.di=np.diff(self.i,axis=1)/self.dv
        self.reference_rin=float(1/self.di[0,int((table['bias']-self.v[0])/self.dv)])
    def interp(self,values,v):
        vi=np.clip(np.floor((v-self.v[0])/self.dv).astype(int),0,len(self.v)-2)
        w=(v-self.v[vi])/self.dv
        a=values[self.ai,vi]*(1-w)+values[self.ai,vi+1]*w
        b=values[self.ai+1,vi]*(1-w)+values[self.ai+1,vi+1]*w
        return a+(b-a)*self.aw
    def current(self,v):return self.interp(self.i,v)
    def deriv(self,v):
        vi=np.clip(np.floor((v-self.v[0])/self.dv).astype(int),0,len(self.v)-2)
        return self.di[self.ai,vi]*(1-self.aw)+self.di[self.ai+1,vi]*self.aw
    def output(self,v):return self.interp(self.y,v)


def main():
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out',type=Path,default=Path('sim/out/physical_vca_20260930'))
    a=ap.parse_args();a.out.mkdir(parents=True,exist_ok=True)
    (a.out/'corrected_2D_transfer.json').write_text(json.dumps(build(),indent=2)+'\n')


if __name__=='__main__':main()
