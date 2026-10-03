#!/usr/bin/env python3
"""Manufacturer-only probe of finite steering-transistor current gain.

Resistors/topology fixed. No cabinet inputs. Generic transistor beta is not
published; this examines whether identical beta for all ten BJTs caused
the Figure3/7 discrepancy. No candidate is selected from cabinet scores.
"""
from __future__ import annotations
import json
from pathlib import Path
import numpy as np
from scipy.optimize import brentq
from playercar_mc3340_historical_check import HistoricalDevice, thd
from playercar_mc3340_device import TRANSISTORS, IN, QS, QR, D, junction


class SteeringDevice(HistoricalDevice):
    def __init__(self,*args,beta_steering=100.,beta_fixed=100.,beta_control=100.,area_input=1.,ikf_steering=None,nf_steering=1.,numerical_gmin=0.,**kwargs):
        super().__init__(*args,correct_control_pin=True,input_diode=True,control_diode=True,**kwargs)
        self.beta_steering=beta_steering
        self.beta_fixed=beta_fixed;self.beta_control=beta_control;self.area_input=area_input
        self.ikf_steering=ikf_steering
        self.nf_steering=nf_steering
        self.numerical_gmin=numerical_gmin

    def equations(self,x,control,vin=None):
        r,j=super().equations(x,control,vin)
        v=np.r_[x,self.vcc,0.,self.load_bias]
        for idx,(collector,base,emitter) in enumerate(TRANSISTORS):
            beta=self.beta_steering if 5<=idx<=8 else self.beta_fixed if idx==1 else self.beta_control if idx==2 else self.beta
            area=self.area_input if idx in (3,4) else 1.
            injection=self.ikf_steering is not None and 5<=idx<=8
            nf=self.nf_steering if 5<=idx<=8 else 1.
            if beta==self.beta and area==1 and not injection and nf==1:continue
            ebe,dbe=junction((v[base]-v[emitter])/self.vt)
            ebc,dbc=junction((v[base]-v[collector])/self.vt)
            f=self.isat*(ebe-1);rev=self.isat*(ebc-1)
            gf=self.isat*dbe/self.vt;gr=self.isat*dbc/self.vt
            da=area-1;db=area/beta-1/self.beta
            ic=da*(f-(1+1/self.br)*rev);ib=db*f+da*rev/self.br
            jc=np.array([da*gr*(1+1/self.br),da*(gf-gr*(1+1/self.br)),-da*gf])
            jb=np.array([-da*gr/self.br,db*gf+da*gr/self.br,-db*gf])
            if nf!=1:
                ef,df=junction((v[base]-v[emitter])/(self.vt*nf))
                newf=self.isat*(ef-1);newgf=self.isat*df/(self.vt*nf)
                ic+=newf-f;ib+=(newf-f)/beta
                jc+=np.array([0.,newgf-gf,gf-newgf])
                jb+=np.array([0.,(newgf-gf)/beta,(gf-newgf)/beta])
                f,gf=newf,newgf
            if injection:
                # Forward Gummel-Poon high-injection base charge, no fitted
                # audio limiter. Standard qB=(1+sqrt(1+4*If/IKF))/2.
                ikf=self.ikf_steering;rootq=np.sqrt(1+4*max(f,0)/ikf)
                qb=(1+rootq)/2;dq=1/(ikf*rootq) if f>0 else 0.
                ic+=(f-rev)*(1/qb-1)
                df=gf*(1/qb-1)-(f-rev)*dq*gf/qb**2
                dr=gr*(1-1/qb)
                jc+=np.array([-dr,df+dr,-df])
            nodes=(collector,base,emitter)
            for n,current,derivs in zip(nodes,(ic,ib,-ic-ib),(jc,jb,-jc-jb)):
                if n>=16 or (vin is not None and n==IN):continue
                r[n]+=1000*current
                for other,value in zip(nodes,derivs):
                    if other<16:j[n,other]+=1000*value
        # Optional numerical pivot for the nearly floating cutoff cascodes.
        # Not a board/component hypothesis; report the unregularized residual.
        for node in (QS,QR):
            r[node]+=1000*self.numerical_gmin*(x[node]-x[D])
            j[node,node]+=1000*self.numerical_gmin;j[node,D]-=1000*self.numerical_gmin
            r[D]-=1000*self.numerical_gmin*(x[node]-x[D])
            j[D,node]-=1000*self.numerical_gmin;j[D,D]+=1000*self.numerical_gmin
        return r,j

    def input_current(self,x):
        collector,base,emitter=TRANSISTORS[3]
        ebe,_=junction((x[base]-x[emitter])/self.vt)
        ebc,_=junction((x[base]-x[collector])/self.vt)
        from playercar_mc3340_device import G
        return (x[IN]-x[G])/20000+self.area_input*self.isat*((ebe-1)/self.beta+(ebc-1)/self.br)


def probe(beta_steering,vcc,beta_fixed=100.,beta_control=100.,area_input=1.,ikf_steering=None,nf_steering=1.):
    d=SteeringDevice(beta_steering=beta_steering,vcc=vcc,beta_fixed=beta_fixed,beta_control=beta_control,area_input=area_input,ikf_steering=ikf_steering,nf_steering=nf_steering)
    bias=float(d.solve(0.)[IN])
    def gain(c):
        return (d.pin_output(d.solve(c,bias+.0001))-d.pin_output(d.solve(c,bias-.0001)))/.0002
    g0=gain(0.);on=d.pin_output(d.solve(0.));off=d.pin_output(d.solve(8.))
    phase=np.arange(256)*2*np.pi/256;rows=[]
    for att in (0,10,20,30,40,50):
        c=0 if att==0 else brentq(lambda c:gain(c)/g0-10**(-att/20),0,8)
        y=np.array([d.pin_output(d.solve(c,bias+np.sqrt(2)*2.5/abs(g0)*np.sin(p))) for p in phase])
        rows.append(dict(attenuation_db=att,control_v=c,THD_percent=thd(y),out_rms_v=float(y.std())))
    return dict(beta_steering=beta_steering,beta_fixed=beta_fixed,beta_control=beta_control,area_input=area_input,ikf_steering=ikf_steering,nf_steering=nf_steering,vcc=vcc,bias=bias,max_gain_db=20*np.log10(abs(g0)),
        dc_shift_v=on-off,rows=rows,
        native_curve=[dict(control_v=c,attenuation_db=-20*np.log10(max(abs(gain(c)/g0),1e-12))) for c in np.arange(2.5,6.01,.1)])


def main():
    out=Path('sim/out/physical_vca_20260930');rows=[]
    for beta in (5.,10.,20.,50.,100.,200.):
        for vcc in (12.,16.):
            p=probe(beta,vcc);rows.append(p)
            (out/'steering_beta_probe.json').write_text(json.dumps(rows,indent=2)+'\n')
            print(beta,vcc,'gain',p['max_gain_db'],'dc',p['dc_shift_v'],
                'THD',[round(x['THD_percent'],3) for x in p['rows']],flush=True)


if __name__=='__main__':main()
