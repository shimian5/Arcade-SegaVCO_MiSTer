#!/usr/bin/env python3
"""Measure whether cabinet 444/482 Hz states share the same D8 line family.

Observed frequency targets only label analysis bins; they never set a model
coefficient. Decode a short span of the long cabinet recording and print the
four-second Hann peak in a +/-0.6 Hz band around each target.
"""
from __future__ import annotations

from pathlib import Path
import subprocess
import imageio_ffmpeg
import numpy as np
from scipy.signal import find_peaks

FS = 4000
START = 696
END = 800
SOURCE = (Path(__file__).resolve().parents[2] / 'turbo' / 'docs' /
          'reference' / 'turbo_cabinet_recording.weba')
WINDOWS = (700, 704, 708, 720, 740, 744, 748, 756, 760, 764, 784, 792)
LINES = {'55':55.188,'299':299.172,'327':326.766,'354':354.359,
         '358':357.859,'444':444.156,'482':482.6,'743':743.328}


def decode() -> np.ndarray:
    cmd = [imageio_ffmpeg.get_ffmpeg_exe(), '-hide_banner', '-loglevel',
           'error', '-ss', str(START), '-t', str(END-START), '-i', str(SOURCE),
           '-ac', '1', '-ar', str(FS), '-f', 'f32le', '-']
    return np.frombuffer(subprocess.run(cmd, check=True, stdout=subprocess.PIPE).stdout,
                         dtype='<f4').astype(float)


def spectrum(y: np.ndarray, sec: int) -> tuple[np.ndarray, np.ndarray]:
    pos = (sec-START)*FS
    sample = y[pos:pos+4*FS]
    a = abs(np.fft.rfft(sample*np.hanning(len(sample))))
    f = np.fft.rfftfreq(len(sample), 1/FS)
    return f, a


def peak(f: np.ndarray, a: np.ndarray, hz: float) -> float:
    band = (f>hz-.6)&(f<hz+.6)
    return float(np.max(a[band]))


def main() -> None:
    y=decode()
    rows={}
    for sec in WINDOWS:
        f,a=spectrum(y,sec)
        rows[sec]={name:peak(f,a,hz) for name,hz in LINES.items()}
    print('Amplitude dB relative to that line\'s maximum among listed windows; not volume-normalized.')
    print('window ' + ' '.join(f'{name:>6}' for name in LINES))
    maxv={name:max(row[name] for row in rows.values()) for name in LINES}
    for sec,row in rows.items():
        print(f'{sec:3d}-{sec+4:<3d} ' + ' '.join(
            f'{20*np.log10(max(row[name],1e-10)/maxv[name]):+6.1f}'
            for name in LINES))
    print('Within-window ratio dB: 299/444, 327/444, 743/444; and 482/444')
    for sec,row in rows.items():
        print(f'{sec:3d}-{sec+4:<3d} ' + ' '.join(
            f'{20*np.log10(max(row[name],1e-10)/max(row["444"],1e-10)):+6.1f}'
            for name in ('299','327','743','482')))
    print('Strongest 285-850 Hz peaks for one 482-dominant and one 444-dominant window:')
    for sec in (700,764):
        f,a=spectrum(y,sec)
        band=(f>285)&(f<850)
        p,_=find_peaks(a[band],distance=6)
        top=sorted(p,key=lambda i:a[band][i],reverse=True)[:24]
        print(sec, ' '.join(f'{f[band][i]:.2f}' for i in top))
    print('3.5-Hz lower/upper neighbor divided by carrier, dB:')
    print('window 444(lo,hi) 358(lo,hi) 299(lo,hi) 202.375(lo,hi) 77.125(lo,hi)')
    for sec in (708,748,764,792):
        f,a=spectrum(y,sec)
        carriers=(444.156,357.859,299.172,202.375,77.125)
        vals=[(20*np.log10(max(peak(f,a,h-3.5),1e-12)/max(peak(f,a,h),1e-12)),
               20*np.log10(max(peak(f,a,h+3.5),1e-12)/max(peak(f,a,h),1e-12)))
              for h in carriers]
        print(f'{sec:3d}-{sec+4:<3d} '+' '.join(f'{lo:+5.1f}/{hi:+5.1f}' for lo,hi in vals))


if __name__=='__main__':
    main()
