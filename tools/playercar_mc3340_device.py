#!/usr/bin/env python3
"""MC3340 Figure-2 DC device probe, for offline diagnosis only.

WITHDRAWN full-control transcription: this legacy probe forces the internal
steering base; Figure2 pin2 is below its 3.9k resistor. The corrected solver
is playercar_mc3340_historical_check.HistoricalDevice(correct_control_pin=True).
Retained to reproduce earlier diagnoses, not as an implementation specification.

Resistor values were transcribed from Motorola MC3340/D Figure 2; the control
connection error is documented above and superseded by the corrected solver.
The generic Ebers-Moll junction parameters are explicitly UNKNOWN device
assumptions. They are swept, never fitted to cabinet audio. This is not a
published transistor model of MB4391, nor an exact MC3340 silicon model.
Pin numbering uses one MC3340 section; pin 6 is ROLL, pin 7 output.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from scipy.optimize import root, least_squares

NAMES = ('bias', 'bias_em', 'fixed_base', 'fixed_drive', 'cont', 'cont_drive',
         'input_bias', 'reference_base', 'reference_diode', 'input',
         'signal_em', 'reference_em', 'signal_cascode', 'reference_cascode',
         'roll', 'output_em')
A, B, C, D, CONT, E, G, H, DI, IN, ES, ER, QS, QR, ROLL, OUT = range(16)
VCC, GND, LOAD_BIAS = 16, 17, 18
RESISTORS = (
    (A, VCC, 5100), (A, GND, 4700), (B, C, 750), (C, GND, 10000),
    (B, CONT, 750), (CONT, GND, 3900), (D, GND, 5100), (E, GND, 5100),
    (G, VCC, 5100), (G, GND, 510), (IN, G, 20000),
    (H, VCC, 5100), (DI, GND, 510), (ES, GND, 1300), (ER, GND, 1500),
    (ROLL, VCC, 6200), (OUT, GND, 5100),
)
# Collector, base, emitter. The signal-side INNER steering transistor and
# reference-side OUTER steering transistor share the ROLL collector node.
TRANSISTORS = (
    (VCC, A, B), (VCC, C, D), (VCC, CONT, E),
    (QS, IN, ES), (QR, H, ER),
    (VCC, E, QS), (ROLL, D, QS),
    (VCC, D, QR), (ROLL, E, QR), (VCC, ROLL, OUT),
)


def junction(z):
    """Exponential with a continuous linear extension for Newton iterates."""
    limit = 30.
    if z > limit:
        e = np.exp(limit)
        return e*(1+z-limit), e
    e = np.exp(max(z, -50.))
    return e, e if z > -50. else 0.


class Device:
    def __init__(self, vcc=12., beta=100., beta_reverse=1., isat=1e-14,
                 vt=.02585, load=1e12, load_bias=6.):
        self.vcc, self.beta, self.br = vcc, beta, beta_reverse
        self.isat, self.vt = isat, vt
        self.load, self.load_bias = load, load_bias
        self.last = None
        self.max_residual = 0.

    def equations(self, x, control, vin=None):
        v = np.r_[x, self.vcc, 0., self.load_bias]
        r = np.zeros(16); jac = np.zeros((16, 16))
        for a, b, resistance in (*RESISTORS, (OUT, LOAD_BIAS, self.load+200)):
            current = (v[a]-v[b])/resistance
            if a < 16:
                r[a] += current; jac[a,a] += 1/resistance
                if b < 16: jac[a,b] -= 1/resistance
            if b < 16:
                r[b] -= current; jac[b,b] += 1/resistance
                if a < 16: jac[b,a] -= 1/resistance
        for collector, base, emitter in TRANSISTORS:
            ebe, dbe = junction((v[base]-v[emitter])/self.vt)
            ebc, dbc = junction((v[base]-v[collector])/self.vt)
            f = self.isat*(ebe-1); rev = self.isat*(ebc-1)
            gf = self.isat*dbe/self.vt; gr = self.isat*dbc/self.vt
            ic = f-rev*(1+1/self.br)
            ib = f/self.beta+rev/self.br
            currents = (ic, ib, -ic-ib)
            deriv = ((gr*(1+1/self.br), gf-gr*(1+1/self.br), -gf),
                     (-gr/self.br, gf/self.beta+gr/self.br, -gf/self.beta),
                     (-gr, -gf*(1+1/self.beta)+gr, gf*(1+1/self.beta)))
            nodes = (collector, base, emitter)
            for node, current, derivatives in zip(nodes, currents, deriv):
                if node < 16:
                    r[node] += current
                    for other, d in zip(nodes, derivatives):
                        if other < 16: jac[node,other] += d
        # Diode from reference_base down to reference_diode, Figure 2.
        exponential, derivative = junction((v[H]-v[DI])/self.vt)
        current = self.isat*(exponential-1); gd = self.isat*derivative/self.vt
        r[H] += current; r[DI] -= current
        jac[H,H] += gd; jac[H,DI] -= gd
        jac[DI,H] -= gd; jac[DI,DI] += gd
        # Current equations are in mA for numerical conditioning. An ideal
        # externally imposed pin voltage replaces that pin's KCL equation.
        r *= 1000; jac *= 1000
        r[CONT] = x[CONT]-control; jac[CONT,:] = 0; jac[CONT,CONT] = 1
        if vin is not None:
            r[IN] = x[IN]-vin; jac[IN,:] = 0; jac[IN,IN] = 1
        return r, jac

    def solve(self, control, vin=None):
        if self.last is not None and abs(self.last[CONT]-control) > .1:
            start = self.last[CONT]
            for c in np.linspace(start, control, int(abs(control-start)/.05)+2)[1:-1]:
                self.solve(float(c), vin)
        guess = np.array((5.7, 5., 4.65, 4., control, max(control-.65, 0),
                          self.vcc/11, self.vcc/11+.6, self.vcc/11,
                          self.vcc/11-.05, .4, 1., 3.3, 3.3,
                          self.vcc-2.5, self.vcc-3.2)) if self.last is None else self.last.copy()
        guess[CONT] = control
        if vin is not None: guess[IN] = vin
        result = root(lambda v: self.equations(v, control, vin)[0], guess,
                      jac=lambda v: self.equations(v, control, vin)[1], tol=1e-10)
        err = np.max(np.abs(self.equations(result.x, control, vin)[0]))
        if not np.isfinite(err) or err > 1e-6:
            result = least_squares(lambda v: self.equations(v, control, vin)[0], guess,
                                   jac=lambda v: self.equations(v, control, vin)[1],
                                   xtol=1e-12, ftol=1e-12, gtol=1e-12, max_nfev=2000)
            err = np.max(np.abs(self.equations(result.x, control, vin)[0]))
        if err > 1e-6:
            raise RuntimeError(f'DC solve failed at CONT={control}, IN={vin}: {err} mA')
        self.max_residual = max(self.max_residual, err)
        self.last = result.x.copy()
        return result.x

    def input_current(self, solution):
        v = solution
        ebe = np.exp(np.clip((v[IN]-v[ES])/self.vt, -50, 30))
        ebc = np.exp(np.clip((v[IN]-v[QS])/self.vt, -50, 30))
        return (v[IN]-v[G])/20000+self.isat*((ebe-1)/self.beta+(ebc-1)/self.br)

    def pin_output(self, solution):
        emitter = solution[OUT]
        return emitter-200*(emitter-self.load_bias)/(self.load+200)


def probe(vcc, beta, isat):
    dev = Device(vcc=vcc, beta=beta, isat=isat)
    rows = []
    for control in (0., 2.8, 3.0, 3.25, 3.5, 4.0, 4.5, 5., 6.5):
        op = dev.solve(control); bias = op[IN]
        y0 = dev.pin_output(op)
        lo = dev.solve(control, bias-.001).copy(); hi = dev.solve(control, bias+.001).copy()
        gain = (dev.pin_output(hi)-dev.pin_output(lo))/.002
        rin = .002/(dev.input_current(hi)-dev.input_current(lo))
        f, _ = junction((op[CONT]-op[E])/dev.vt)
        rev, _ = junction((op[CONT]-dev.vcc)/dev.vt)
        control_base_current=dev.isat*((f-1)/dev.beta+(rev-1)/dev.br)
        source_current=op[CONT]/3900+(op[CONT]-op[B])/750+control_base_current
        rows.append(dict(cont=control, input_bias=bias, output_dc=y0,
                         gain_signed=gain, gain_db=float(20*np.log10(max(abs(gain),1e-30))),
                         rin_ohm=rin, external_control_source_current_mA=source_current*1000))
    return dict(vcc=vcc, beta=beta, isat=isat, rows=rows,
                max_kcl_residual_mA=dev.max_residual)


def transfer(vcc=12., beta=100.):
    """Fully-on signal characteristic; control knee is NOT validated."""
    dev = Device(vcc=vcc, beta=beta)
    op = dev.solve(0.).copy()
    grid = np.linspace(-.5, 4.5, 1001)
    outputs, currents = [], []
    for vin in grid:
        state = dev.solve(0., float(vin))
        outputs.append(dev.pin_output(state)); currents.append(dev.input_current(state))
    off = dev.solve(8.)
    return dict(vcc=vcc, beta=beta, bias=op[IN], on_dc=dev.pin_output(op),
                off_dc=dev.pin_output(off), vin=grid.tolist(),
                vout=outputs, input_current=currents,
                max_kcl_residual_mA=dev.max_residual)


def validation():
    """Published conditions, independently of any cabinet recording."""
    tab = transfer(16.)
    phase = np.arange(4096)/4096*2*np.pi
    y = np.interp(tab['bias']+np.sqrt(2)*.1*np.sin(phase), tab['vin'], tab['vout'])
    z = np.fft.rfft(y-y.mean())
    thd = np.linalg.norm(z[2:20])/abs(z[1])*100
    dev=Device(vcc=16.);state=dev.solve(0.)
    residual,jac=dev.equations(state,0.)
    numerical=np.column_stack([(dev.equations(state+np.eye(16)[i]*1e-6,0.)[0]-
                                dev.equations(state-np.eye(16)[i]*1e-6,0.)[0])/2e-6 for i in range(16)])
    return dict(condition='16 V, CONT=0, 100 mVrms sinusoidal input, quasistatic',
                gain_db=20*np.log10(abs(z[1])*2/len(y)/(.1*np.sqrt(2))),
                thd_percent=thd, published_gain_typ_db=13., published_thd_typ_percent=.6,
                published_thd_max_percent=1.,
                max_operating_point_kcl_mA=float(abs(residual).max()),
                jacobian_max_relative_error=float(abs(numerical-jac).max()/max(abs(jac).max(),1)),
                warning='Figure-2 generic-junction model fails Figure-3 attenuation knee; not an exact device model.')


def output_load_probe():
    rows=[]
    for load in (1e12,25500.,10500.):
        dev=Device(load=load)
        op=dev.solve(0.).copy();bias=op[IN]
        low=dev.pin_output(dev.solve(0.,bias-.001))
        high=dev.pin_output(dev.solve(0.,bias+.001))
        rows.append(dict(load_ohm=load,dc_return_v=6.,output_dc=dev.pin_output(op),
                         small_signal_gain=(high-low)/.002))
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--out', type=Path, default=Path('sim/out/vca_ic7_20260930'))
    args = ap.parse_args(); args.out.mkdir(parents=True, exist_ok=True)
    results = [probe(vcc, beta, isat) for vcc,beta,isat in
               ((12,100,1e-14),(16,100,1e-14),(12,50,1e-14),(12,200,1e-14),
                (12,100,1e-15),(12,100,1e-13))]
    (args.out/'mc3340_dc_probe.json').write_text(json.dumps(results,indent=2)+'\n')
    report = validation()
    report['output_load_probe']=output_load_probe()
    (args.out/'mc3340_validation.json').write_text(json.dumps(report,indent=2)+'\n')
    print('DATASHEET VALIDATION', report)
    tables = [transfer(12.,beta) for beta in (50.,100.,200.)]
    (args.out/'mc3340_on_transfer.json').write_text(json.dumps(tables,indent=2)+'\n')
    for result in results:
        print('VCC/beta/Is',result['vcc'],result['beta'],result['isat'])
        for row in result['rows']:
            print(' CONT %.2f INbias %.3f OUTdc %.3f gain %+7.3f (%+.2f dB) Rin %.1fk' %
                  (row['cont'],row['input_bias'],row['output_dc'],row['gain_signed'],row['gain_db'],row['rin_ohm']/1000))


if __name__ == '__main__':
    main()
