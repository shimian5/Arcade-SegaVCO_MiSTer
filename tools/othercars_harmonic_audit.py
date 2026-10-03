#!/usr/bin/env python3
"""D6 harmonic diagnosis; no RTL or production-table mutation.

Microphone harmonic ratios are not source waveforms. Bias-resistor tolerance
is included in the ramp law; a feasibility witness is not measured parts.
"""
from pathlib import Path
import argparse
import hashlib
import json
import numpy as np
from scipy.io import wavfile
from scipy.signal import butter, resample_poly, sosfiltfilt
import playercar_brightness_diagnose as B
from othercars_cabinet_research import BUS, CELLS, controls, source_h

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'sim/out/othercars_harmonics_20261001'


def harmonic(duty, n):
    return float(np.sin(n*np.pi*duty)/(n*n*np.sin(np.pi*duty)))


def db(amplitude):
    return float(20*np.log10(max(abs(amplitude), 1e-30)))


def harmonic_range(lo, hi, n):
    candidates = [lo, hi] + [x for x in (1/3, .5, 2/3) if lo <= x <= hi]
    values = [db(harmonic(x, n)) for x in candidates]
    has_zero = any(lo <= k/n <= hi for k in range(1, n))
    return dict(min_dB=None if has_zero else min(values), max_dB=max(values),
                min_note='Exact harmonic zero is within range' if has_zero else 'Finite bound')


def line_ratios(power):
    return dict(pair_H2_H1_dB=B.db_power(B.line(power, 404.7, 1.2)/B.line(power, 202.35, 1.2)),
                A_H2_H1_dB=B.db_power(B.line(power, 154.26, 1.2)/B.line(power, 77.13, 1.2)),
                A_H3_H1_dB=B.db_power(B.line(power, 231.39, 1.2)/B.line(power, 77.13, 1.2)))


def coherent_families(x):
    result = {}
    time = np.arange(len(x))/B.FS
    for name, p in CELLS.items():
        envelopes = {}
        for n in (1, 2, 3):
            z = resample_poly(x*np.exp(-2j*np.pi*n*p['measured']*time), 1, 4000)
            envelopes[n] = sosfiltfilt(butter(4, n*.018, fs=4, output='sos'), z)[80:400]
        result[name] = {str(n): np.percentile(
            20*np.log10(np.maximum(abs(envelopes[n]), 1e-20)
                        /np.maximum(abs(envelopes[1]), 1e-20)), [10, 50, 90]).tolist()
                       for n in (2, 3)}
    return dict(harmonic_over_own_fundamental_dB_p10_p50_p90=result,
                method='700-820s; heterodyne each family; resample4Hz; Butterworth4 cutoff n*0.018Hz; trim20s each end',
                warning='Approximate measured family ratios; drift, weak-line noise, distortion and acoustic transfer remain. Not source duty measurements.')


def pair_phase_range(duty_b, window_b):
    # Hann-energy-normalized four-second power, including close-line cross
    # terms. Sweep ALL relative carrier phases; none is chosen for scoring.
    time = np.arange(4*B.FS)/B.FS-2
    weight = np.hanning(len(time))**2
    delta = CELLS['C']['measured']-CELLS['B']['measured']
    gamma = {n: np.sum(weight*np.exp(2j*np.pi*n*delta*time))/weight.sum() for n in (1, 2)}
    phi = np.linspace(0, 2*np.pi, 4001)
    coefficients = []
    for name, duty, window in [('B', duty_b, window_b), ('C', 68/150, 10.5*51/151)]:
        j = list(CELLS).index(name)
        f = CELLS[name]['measured']
        coefficients.append([window*abs(source_h(n*f)[j, 0])*np.sin(n*np.pi*duty)
                             /(2*np.pi**2*n*n*duty*(1-duty)) for n in (1, 2)])
    power = {}
    for n in (1, 2):
        a, c = coefficients[0][n-1], coefficients[1][n-1]
        power[n] = a*a+c*c+2*a*c*np.real(gamma[n]*np.exp(1j*n*phi))
    ratio = 10*np.log10(power[2]/power[1])
    return dict(combined_pair_H2_H1_dB_min=float(ratio.min()),
                combined_pair_H2_H1_dB_max=float(ratio.max()),
                method='4s Hann-squared power integral; entire relative-phase sweep; nominal C and source weights; filter phase variation across the pair neglected',
                warning='Source-only sensitivity range. Not actual startup phase, measured installed components or an acoustic identification.')


def theory():
    result = {}
    for name, p in CELLS.items():
        d = p['rc']/p['ri']
        lo = d*.95/1.05
        hi = d*1.05/.95
        # Divider voltage b=u*Rlower/(Rupper+Rlower); (u-b)/b=Rupper/Rlower.
        all_lo, all_hi = lo*.95/1.05, hi*1.05/.95
        result[name] = dict(nominal_short_ramp_fraction=d,
                            nominal_H2_dB=db(harmonic(d, 2)),
                            nominal_H3_dB=db(harmonic(d, 3)),
                            Ri_Rc_only_5pct_fraction=[lo, hi],
                            with_bias_divider_5pct_fraction=[all_lo, all_hi],
                            with_bias_divider_H2_dB_range=harmonic_range(all_lo, all_hi, 2),
                            with_bias_divider_H3_dB_range=harmonic_range(all_lo, all_hi, 3),
                            nominal_triangle_Vpp=10.5*p['rr']/(p['rr']+p['rf']),
                            max_required_ramp_V_per_us=10.5*p['rr']/(p['rr']+p['rf'])*p['measured']/min(d, 1-d)/1e6)
    ri, rc = 270e3*.95, 100e3*1.05
    upper, lower = 51e3*1.05, 51e3*.95
    bias = BUS*lower/(upper+lower)
    d = rc/ri*(BUS-bias)/bias
    reference, feedback = 51e3*.95, 100e3*1.05
    window = 10.5*reference/(reference+feedback)
    cap = (BUS-bias)/ri*(1-d)/(window*CELLS['B']['measured'])
    result['B_full_bias_feasibility_witness'] = dict(
        R109_ohm=ri, R110_ohm=rc, R113_ohm=upper, R114_ohm=lower,
        Schmitt_reference_ohm=reference, R115_feedback_ohm=feedback,
        C36_nF=cap*1e9, C36_change_percent=100*(cap/4.7e-9-1),
        short_ramp_fraction=d, nominal_device_frequency_Hz=CELLS['B']['measured'],
        H2_dB=db(harmonic(d, 2)), H3_dB=db(harmonic(d, 3)),
        warning='All external values within5%; zero collector voltage and nominal10.5V swing. Edge-correlated feasibility witness, not installed values or a selected correction.')
    result['nominal_pair_phase_range'] = pair_phase_range(100/270, 10.5*51/151)
    result['witness_pair_phase_range'] = pair_phase_range(d, window)
    result['triangle_third_harmonic_upper_bound_dB'] = db(1/3)
    inferred = float(np.arccos(2*10**(-26.5/20))/np.pi)
    result['isolated_unfiltered_H2_only_inverse'] = dict(
        D=inferred, collector_resistor_ohm=270e3*inferred,
        required_collector_V_with_nominal_resistors=BUS/2*(1-(100/270)/inferred),
        predicted_H3_dB=db(harmonic(inferred, 3)),
        warning='Conditional inverse, NOT inferred physical board values: ignores C, filter and nonlinearities.')
    for rc_new in (120e3, 127e3, 270e3*inferred):
        window_nominal = 10.5*51/151
        f_new = BUS*(270e3-rc_new)/(2*window_nominal*4.7e-9*270e3**2)
        result[f'unsupported_R110_{int(rc_new)}ohm_probe'] = dict(
            frequency_Hz=f_new, C36_needed_nF=4.7*f_new/CELLS['B']['measured'],
            warning='Other components held nominal. No supported R110 replacement.')
    return result


def device_probe():
    # Diagnostic only: this historical reconstruction fails joint source
    # validation. Compare to its OWN linear output with the same input load.
    from playercar_mc3340_physical_table import Input2D
    import playercar_physical_engine_model as P
    fs = 48000
    t = np.arange(8*fs)/fs
    f = np.fft.rfftfreq(len(t), 1/fs)
    s = 2j*np.pi*f
    source = np.zeros_like(t)
    for j, p in enumerate(CELLS.values()):
        duty = p['rc']/p['ri']
        phase = (t*p['measured']) % 1
        window = 10.5*p['rr']/(p['rr']+p['rf'])
        triangle = window*(np.where(phase < duty, phase/duty, (1-phase)/(1-duty))-.5)
        source += P.filt(triangle, source_h(f)[j])
    tab = json.loads((ROOT/'sim/out/physical_vca_20260930/corrected_2D_transfer.json').read_text())
    result = {}
    for field in ('10', '01'):
        control = controls()[field]
        gain = control['absolute_gain']/10**(13/20)
        device = Input2D(tab, -20*np.log10(gain))
        rin = P.rin_of(device)
        h = s*2.2e-6*rin/(1+s*2.2e-6*rin)
        z = rin/(1+s*2.2e-6*rin)
        pin, kcl = P.nonlinear_coupling(source, h, z, device)
        quiet = device.output(np.full_like(pin, device.tab['bias']))
        output = dict(linear_output=quiet+device.tab['max_signed_gain']*gain*(pin-device.tab['bias']),
                      joint=device.output(pin))
        ratios = {}
        for name, wave in output.items():
            y = P.filt(wave, 1/(1+s*6200*680e-12))
            power = B.spectrum(resample_poly(y, 1, 3)[2*B.FS:6*B.FS])
            ratios[name] = line_ratios(power)
            ratios[name]['pair_H3_H1_dB'] = B.db_power(B.line(power, 607.1, 1.2)/B.line(power, 202.35, 1.2))
        result[field] = dict(control=control, ratios=ratios, KCL=kcl,
                             warning='X: unvalidated historical device; output ablations retain nonlinear input current; zero synthetic starting phases, not captured RTL startup.')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device-probe', action='store_true')
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    cache = ROOT/'sim/out/othercars_20260930/cab700_820.npy'
    x = np.load(cache)
    measurements = {}
    for start in (700, 708, 720, 740, 748, 760, 763, 764, 784, 792, 812):
        measurements[str(start)] = line_ratios(B.spectrum(x[(start-700)*B.FS:(start-696)*B.FS]))
    core_path = ROOT/'sim/out/audio_oc/turbo_audio_l_scen37.wav'
    fs, core = wavfile.read(core_path)
    assert fs == 48000 and core.ndim == 1
    core = resample_poly(core.astype(float)/32768, 1, 3)
    core_metrics = line_ratios(B.spectrum(core[3*B.FS:7*B.FS]))
    network = {}
    for j, (name, p) in enumerate(CELLS.items()):
        network[name] = {str(n): db(source_h(n*p['measured'])[j, 0]/source_h(p['measured'])[j, 0]) for n in (2, 3)}
    alpha = 5/32
    shaper = lambda f: alpha/(1-(1-alpha)*np.exp(-2j*np.pi*f/48000))
    shaper_relative = db(shaper(404.7)**2/shaper(202.35)**2)
    result = dict(
        measurement_core='Existing scenario37 F WAV from4efd013, before output-shaper commits',
        measurements=measurements, core_F=core_metrics, coherent_families=coherent_families(x),
        theory=theory(), D6_coupling_summer_Hn_H1_dB=network,
        output_shaper_H404_H202_dB=shaper_relative,
        expected_shaped_core_H2_H1_dB=core_metrics['pair_H2_H1_dB']+shaper_relative,
        owner_supplied_new_recording_H2_H1_dB=-16.6,
        new_recording_note='No newly supplied recording file was available in this turn; -16.6dB is the owner measurement, not an independent remeasurement.',
        visual_findings=dict(R110='Photo next to TR7: brown-black-yellow, consistent100k; D6 printed100k; BOM100k qty75,120k qty4; no127k/130k',
                             taps='A IC14pin8->C47; B IC13pin14->C49; C IC13pin7->C48; all integrator outputs',
                             summer='R3323.9k feedback only, no feedback capacitor; common R1471k; coupling2.2uF and3.3k/3.3k/10k'),
        source_hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [cache, core_path, ROOT/'rtl/audio/turbo_othercars_chan.sv', ROOT/'rtl/audio/turbo_out_shaper.sv']},
        primary_source_hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [
            ROOT.parent/'turbo/docs/evidence/turbo_834-0123_revB_board_photo_1982_full.png',
            ROOT.parent/'turbo/docs/schematics/turbo/turbo_sheet_audio_D6of11_othercarosc_printed130_pdf12.png',
            ROOT/'docs/evidence/bom_834-0123/BOM_834-0123_transcription.md',
            ROOT/'docs/evidence/bom_834-0123/bom_p114_items_127-151.jpg']},
        warnings=['Resistor5% is BOM-family assumption. Ideal device bias/swing is not measured installed silicon.',
                  'Neither the microphone202Hz pair ratio nor A3/A1 directly identifies oscillator duty.',
                  'No replacement resistor, fitted waveform, notch, comparator delay, VCA ROM or RTL change is proposed.'])
    if args.device_probe:
        result['unvalidated_VCA_probe'] = device_probe()
    (OUT/'audit.json').write_text(json.dumps(result, indent=2)+'\n')
    print(json.dumps({key:result[key] for key in ['core_F', 'coherent_families', 'theory', 'D6_coupling_summer_Hn_H1_dB', 'output_shaper_H404_H202_dB']}, indent=2))


if __name__ == '__main__':
    main()
