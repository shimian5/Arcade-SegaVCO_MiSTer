#!/usr/bin/env python3
"""Offline diagnosis of Turbo cabinet brightness; never patches RTL.

Decode the ORIGINAL recording at 16 kHz (older 4 kHz scratch WAVs cannot
measure a 3 kHz band). Compare settled scenario-35 taps, reconstruct W with
the actual mixer weights, and compare existing VCA large-signal hypotheses.
Median subtraction is a background estimate, not an isolated engine stem.
The exported smooth ratio is empirical presentation data, NOT a circuit or
speaker identification. Cabinet frequencies below label measured lines only.
"""
from __future__ import annotations

import argparse
import csv
import itertools
import json
from pathlib import Path
import subprocess

import imageio_ffmpeg
import numpy as np
from scipy.io import wavfile
from scipy.signal import find_peaks, lfilter, resample_poly, sosfreqz

import playercar_vca_feedthrough_probe as P
import playercar_d8_ic17_reference as R
import speaker_guess_listen as SG

ROOT = Path(__file__).resolve().parents[1]
FS = 16000
START, SECONDS = 738, 52
BACKGROUND = (738, 742, 746, 750, 754, 758, 769, 773, 777, 781, 785)
BANDS = ((20, 150), (250, 900), (900, 1500), (1500, 3000), (900, 3000))
CAB_RATES = np.array((326.766, 385.469, 27.594))


def db_power(x):
    return float(10 * np.log10(max(float(x), 1e-30)))


def decode(path):
    args = [imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-loglevel', 'error',
            '-ss', str(START), '-t', str(SECONDS), '-i', str(path), '-ac', '1',
            '-ar', str(FS), '-f', 'f32le', '-']
    return np.frombuffer(subprocess.run(args, check=True, stdout=subprocess.PIPE).stdout,
                         dtype='<f4').astype(float)


def spectrum(x):
    """One-sided mean-square power per FFT bin, Hann energy normalized."""
    n = 4 * FS
    assert len(x) == n
    window = np.hanning(n)
    z = np.fft.rfft((x - np.mean(x)) * window)
    power = abs(z)**2 * 2 / (n * np.sum(window**2))
    power[[0, -1]] *= .5
    return power


F = np.fft.rfftfreq(4 * FS, 1 / FS)


def band(power, lo, hi):
    return float(power[(F >= lo) & (F < hi)].sum())


def line(power, hz, width=1.0):
    return float(power[abs(F - hz) <= width].sum())


def observed_peak(power, expected, radius=2):
    indices = np.flatnonzero(abs(F-expected) < radius)
    idx = indices[np.argmax(power[indices])]
    # Interpolate a Hann peak in log power. This labels a measured capture;
    # it does not alter the oscillator model or fit a synthesis parameter.
    y = np.log(np.maximum(power[idx-1:idx+2], 1e-30))
    delta = .5 * (y[0]-y[2]) / (y[0]-2*y[1]+y[2])
    return float(F[idx] + np.clip(delta, -.5, .5) * (F[1]-F[0]))


def anchor(power):
    # Common engine comparison band. Also report raw and residual so the
    # uncertainty caused by stationary engine energy is visible.
    return band(power, 250, 900)


def load_tap(directory, name):
    fs, x = wavfile.read(directory / ('turbo_' + name + '_scen35.wav'))
    if fs != 48000 or x.ndim != 1:
        raise ValueError('Expected synchronous 48 kHz mono scenario-35 taps')
    return resample_poly(x.astype(float) / 4096, 1, 3)


def current_amp(x):
    # Reconstruct the current (incorrectly read) RTL STK only, to compare
    # its missing W export. Gain/volume are common normalization here.
    a = 16773898 / 2**24
    a3 = a**3
    return lfilter([a3, -a3], [1, -a3], x)


def output_coupling(x):
    # Actual C7/C10 1000 uF with nominal 8-ohm resistive upright load.
    # Loudspeaker impedance is NOT constant in a real cabinet.
    a = np.exp(-1 / (FS * 8 * .001))
    return lfilter([a, -a], [1, -a], x)


def smooth_ratios(reference, model):
    # Wide logarithmic bins avoid dividing slightly displaced spectral
    # lines point by point. Fit only a smooth DESCRIPTIVE acoustic+model
    # ratio: it does not distinguish an acoustic filter from VCA error.
    edges = np.geomspace(20, 3500, 25)
    centers = np.sqrt(edges[:-1] * edges[1:])
    ratios = np.array([db_power(band(reference, lo, hi) / max(band(model, lo, hi), 1e-30))
                       for lo, hi in zip(edges[:-1], edges[1:])])
    ratios -= db_power(anchor(reference) / anchor(model))
    # Ridge penalty on curvature, preserving broad shape without a
    # circuit-fitted pole or tuning any synthesis coefficient.
    d2 = np.diff(np.eye(len(centers)), n=2, axis=0)
    smooth = np.linalg.solve(np.eye(len(centers)) + 8 * d2.T @ d2, ratios)
    return centers, ratios, smooth


def lattice_label(hz, rates):
    candidates = []
    for coeff in itertools.product(range(-5, 6), range(-5, 6), range(-4, 5)):
        cost = sum(abs(v) for v in coeff)
        if not cost or cost > 8:
            continue
        pred = float(np.dot(coeff, rates))
        error = abs(pred - hz)
        if pred > 0 and error <= .65:
            candidates.append((cost, error, coeff))
    return min(candidates)[2] if candidates else None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--source', type=Path, default=ROOT.parent / 'turbo/docs/reference/turbo_cabinet_recording.weba')
    ap.add_argument('--sim', type=Path, default=ROOT / 'sim/out/audio_loaded_20260930/acc42')
    ap.add_argument('--out', type=Path, default=ROOT / 'sim/out/brightness_20260930')
    args = ap.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    recording = decode(args.source)
    cabraw = {sec: spectrum(recording[(sec-START)*FS:(sec-START+4)*FS]) for sec in (748, 763)}
    median = np.median(np.array([spectrum(recording[(sec-START)*FS:(sec-START+4)*FS])
                                for sec in BACKGROUND]), axis=0)
    cabres = {sec: np.maximum(power - median, 0) for sec, power in cabraw.items()}
    engine = load_tap(args.sim, 'playercar_dcblock_w')
    slf = load_tap(args.sim, 'playercar_slf')
    f_mix = engine * 15173 / 65536
    w_mix = engine * 27043 / 65536 + slf * 39775 / 65536
    # Scenario 35 is BSEL2: F and W engine taps are identical, OC disabled.
    # Analyze 2..6 s of an already settled 6 s export.
    models = {
        'RTL_F_only': spectrum(current_amp(f_mix)[2*FS:6*FS]),
        'RTL_W_reconstructed': spectrum(current_amp(w_mix)[2*FS:6*FS]),
        'RTL_W_actual_output_C': spectrum(output_coupling(current_amp(w_mix))[2*FS:6*FS]),
        'SLF_tap': spectrum(slf[2*FS:6*FS]),
        'engine_tap': spectrum(engine[2*FS:6*FS]),
    }
    slf_w_power = spectrum(current_amp(slf * 39775 / 65536)[2*FS:6*FS])
    models['RTL_equal_acoustic_power_F_W'] = models['RTL_F_only'] + models['RTL_W_reconstructed']
    # The existing tanh proxy is a hypothesis; the datasheet specifies
    # swing and gain, not this exact clipping transfer.
    rates = None
    for name, comp, comp2 in (('VCA_linear', False, False), ('VCA_one_bound', True, False), ('VCA_two_bounds', True, True)):
        x, rr = P.render(42, 6, 1, 0, comp=comp, comp2=comp2)
        x = resample_poly(x, 1, 3)
        power = spectrum(x[-4*FS:])
        models[name] = power
        rates = np.array((rr['T'], rr['f7'], rr['S']))
    ep = models['engine_tap']
    observed_t = observed_peak(ep, rates[0])
    observed_s = observed_peak(ep, rates[2])
    observed_i = .5 * (observed_peak(ep, rates[1]-rates[2]) +
                       observed_peak(ep, rates[1]+rates[2]))
    captured_rates = np.array((observed_t, observed_i, observed_s))
    report = dict(source=str(args.source), sim=str(args.sim), fs=FS,
                  cabinet_rates_labels_only=CAB_RATES.tolist(), model_rates=rates.tolist(),
                  observed_rtl_rates_labels_only=captured_rates.tolist(),
                  background_windows=list(BACKGROUND), bands={}, low_lines={}, high_lines=[])
    rows = {}
    for name, power in {**{f'cab{sec}_raw': p for sec, p in cabraw.items()},
                        **{f'cab{sec}_residual': p for sec, p in cabres.items()}, **models}.items():
        rows[name] = {f'{lo}-{hi}': round(db_power(band(power, lo, hi) / anchor(power)), 3)
                      for lo, hi in BANDS}
        low_mask = (F >= 20) & (F < 150)
        for nuisance in (60, 77.125, 97.0, 120):
            low_mask &= abs(F-nuisance) > 1
        rows[name]['20-150_excluding_nuisance_lines'] = round(db_power(power[low_mask].sum() / anchor(power)), 3)
    report['bands'] = rows
    # Each low-frequency attribution stays explicit. No claim that the
    # 58.69-Hz cabinet line equals the separate nominal 62.8-Hz SLF line.
    f3, f5 = R.ladder_v(42) * np.array((2.901, 5.138))
    for name, sim_hz, cab_hz in (
        ('SLF_f3_candidate', f3, 23.203), ('SLF_f5_minus_f3_unassigned_in_cab', f5-f3, f5-f3),
        ('SLF_f3_plus_f5_unassigned_in_cab', f3+f5, f3+f5),
        ('SLF_2f5_minus_f3_unassigned_in_cab', 2*f5-f3, 2*f5-f3),
        ('upper_I_minus_T', captured_rates[1]-captured_rates[0], CAB_RATES[1]-CAB_RATES[0]),
        ('upper_2S', 2*captured_rates[2], 2*CAB_RATES[2]),
        ('upper_2I_minus_2T', 2*(captured_rates[1]-captured_rates[0]), 2*(CAB_RATES[1]-CAB_RATES[0])),
    ):
        report['low_lines'][name] = dict(sim_hz=float(sim_hz), cab_probe_hz=float(cab_hz),
            db_re_anchor={source: round(db_power(line(power, hz) / anchor(models['RTL_W_reconstructed']
                              if source == 'SLF_W_contribution' else power)), 2)
                          for source, power, hz in (
                              ('cab763_raw', cabraw[763], cab_hz), ('cab763_residual', cabres[763], cab_hz),
                              ('RTL_W', models['RTL_W_reconstructed'], sim_hz),
                              ('SLF_W_contribution', slf_w_power, sim_hz),
                              ('engine_tap', models['engine_tap'], sim_hz))})
    power = models['engine_tap']
    pk, _ = find_peaks(power, distance=4)
    pk = [i for i in pk if 900 <= F[i] < 3000]
    for idx in sorted(pk, key=lambda i: power[i], reverse=True)[:30]:
        hz = float(F[idx]); coeff = lattice_label(hz, captured_rates)
        cabhz = float(np.dot(coeff, CAB_RATES)) if coeff else None
        row = dict(model_hz=hz, coefficients=coeff, cabinet_target_hz=cabhz,
                   model_db=round(db_power(line(power, hz) / anchor(power)), 2))
        if cabhz and cabhz < FS/2:
            row['cab_raw_db'] = round(db_power(line(cabraw[763], cabhz) / anchor(cabraw[763])), 2)
            row['cab_residual_db'] = round(db_power(line(cabres[763], cabhz) / anchor(cabres[763])), 2)
        report['high_lines'].append(row)
    fit_rows = []
    for name in ('RTL_W_reconstructed', 'VCA_two_bounds'):
        center, raw_ratio, fit = smooth_ratios(cabres[763], models[name])
        for c, raw, smooth in zip(center, raw_ratio, fit):
            fit_rows.append(dict(model=name, hz=c, raw_db=raw, smooth_db=smooth))
    with (args.out / 'empirical_response.csv').open('w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=('model', 'hz', 'raw_db', 'smooth_db'))
        writer.writeheader(); writer.writerows(fit_rows)
    report['sideband_lower_over_upper_db'] = {}
    for name, power, irate, srate in (
        ('cab748_residual', cabres[748], CAB_RATES[1], CAB_RATES[2]),
        ('cab763_residual', cabres[763], CAB_RATES[1], CAB_RATES[2]),
        ('RTL', models['engine_tap'], captured_rates[1], captured_rates[2]),
        ('VCA_one_bound', models['VCA_one_bound'], rates[1], rates[2]),
        ('VCA_two_bounds', models['VCA_two_bounds'], rates[1], rates[2]),
    ):
        report['sideband_lower_over_upper_db'][name] = {
            str(j): round(db_power(line(power, j*irate-srate) / max(line(power, j*irate+srate), 1e-30)), 2)
            for j in range(1, 6)}
    # Actual values supplied by the owner from the official parts layout.
    w_other_load = 1 / (5/100000 + 1/22000)
    slf_load = 68000 + w_other_load
    divider_bot = 1 / (1/10000 + 1/slf_load)
    divider = divider_bot / (8200 + divider_bot)
    rin = 18000  # explicitly an MC3340 internal-schematic estimate
    input_bot = 1 / (1/10000 + 1/rin)
    input_loss_db = 20*np.log10((input_bot/(39000+input_bot))/(10000/49000))
    report['physical_ledger'] = dict(R199_ohm=8200, R198_ohm=10000,
        value_source='owner-provided official parts layout, 2026-09-30',
        divider_unloaded=10000/18200, slf_load_approx_ohm=slf_load,
        divider_loaded_approx=divider, divider_db_vs_current_half=float(20*np.log10(divider/.5)),
        mc3340_rin_estimate_only_ohm=rin, lower_input_loading_estimate_db=float(input_loss_db),
        stk_feedback_gain=1+12000/120, current_rtl_stk_gain=1+390000/12000,
        stk_feedback_corner_hz=1/(2*np.pi*120*220e-6),
        stk_output_corner_resistive8ohm_hz=1/(2*np.pi*8*1000e-6),
        mc3340_rolloff_680pf_estimate_hz=1/(2*np.pi*6200*680e-12))
    # Compare guessed woofer attenuation with the empirical ratio. This is
    # the filter's transfer alone, without per-file RMS renormalization.
    centers = np.geomspace(20, 3500, 200)
    from scipy.signal import butter
    guess_fs = 48000  # existing listening file's actual filter design rate
    _, hp = sosfreqz(SG.sos_hp2(SG.FC_HP, SG.Q_HP, guess_fs), worN=centers, fs=guess_fs)
    _, lp = sosfreqz(butter(2, SG.FC_LP, fs=guess_fs, output='sos'), worN=centers, fs=guess_fs)
    guess_db = 20*np.log10(abs(hp*lp))
    import matplotlib
    matplotlib.use('Agg')
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(2, 1, figsize=(10, 9))
    for name in ('RTL_W_reconstructed', 'VCA_two_bounds'):
        values = [v for v in fit_rows if v['model'] == name]
        axes[0].semilogx([v['hz'] for v in values], [v['smooth_db'] for v in values], label=name)
    axes[0].semilogx(centers, guess_db, '--', label='existing guessed woofer (unnormalized)')
    axes[0].axvspan(20, 150, color='gray', alpha=.12, label='low band contains other sounds; not a speaker estimate')
    axes[0].set(title='Empirical cabinet / model ratio: descriptive only', ylabel='dB, common 250–900 Hz level removed')
    axes[0].legend(); axes[0].grid(True, which='both', alpha=.3)
    # Smooth PSD for display only; the quantitative tables use the original bins.
    from scipy.ndimage import gaussian_filter1d
    for name, power in (('cab763 raw', cabraw[763]), ('cab763 median residual', cabres[763]),
                        ('RTL W', models['RTL_W_reconstructed']), ('two VCA bounds', models['VCA_two_bounds'])):
        yy = 10*np.log10(np.maximum(gaussian_filter1d(power / anchor(power), 3), 1e-12))
        axes[1].plot(F, yy, label=name, alpha=.8)
    axes[1].set(xlim=(900, 3000), ylim=(-65, 0), xlabel='Hz', ylabel='dB power/bin re 250–900 Hz', title='High-frequency partials (slightly smoothed for display)')
    axes[1].legend(); axes[1].grid(True, alpha=.3)
    fig.tight_layout(); fig.savefig(args.out / 'brightness_diagnosis.png', dpi=160); plt.close(fig)
    (args.out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print('Rates', rates)
    print('Band power dB re 250–900 Hz:')
    for name, values in rows.items():
        print(name, values)
    print('Low lines:', json.dumps(report['low_lines'], indent=2))
    print('Top HF lines:', json.dumps(report['high_lines'][:12], indent=2))
    print('Wrote', args.out)


if __name__ == '__main__':
    main()
