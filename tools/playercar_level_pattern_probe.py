#!/usr/bin/env python3
"""Compare the model's line-level PATTERN (250-900 Hz combinations of T, IC7, S) with the cabinet's, per VCA variant.

Uses the loaded-tap / production-population fast model (tools/playercar_vca_feedthrough_probe.render).
Cabinet (763-767 s, dB re the strongest line 444.15 = 2I-T): T -3.9, 2T -5.5, T+I -7.1, T-S -3.7, T+S -8.8, I-S -5.0,
I -10.1, 2I-T 0.0, 2I-S -0.3, 2I+S -2.9, I+2S -5.0.  A common offset is removed; the score is the RMS dB error
of the pattern.  Variants: MC3340 12-V law with/without large-signal compression, control feedthrough k, gate power p.
Device unknowns are explored, not fitted into the RTL.
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import playercar_vca_feedthrough_probe as P  # noqa: E402

CAB = {"T": -3.9, "2T": -5.5, "T+I": -7.1, "T-S": -3.7, "T+S": -8.8, "I-S": -5.0, "I": -10.1,
       "2I-T": 0.0, "2I-S": -0.3, "2I+S": -2.9, "I+2S": -5.0}


def freqs(T, I, S):
    return {"T": T, "2T": 2 * T, "T+I": T + I, "T-S": T - S, "T+S": T + S, "I-S": I - S, "I": I,
            "2I-T": 2 * I - T, "2I-S": 2 * I - S, "2I+S": 2 * I + S, "I+2S": I + 2 * S}


def main():
    acc = int(sys.argv[1]) if len(sys.argv) > 1 else 42
    rows = []
    for comp, comp2 in ((False, False), (True, False), (True, True)):
        for p in (0.5, 1.0, 2.0):
            for k in (0.0, 0.05, 0.1, 0.2):
                x, r = P.render(acc, 3.5, p, k, comp=comp, comp2=comp2)
                fr = freqs(r["T"], r["f7"], r["S"])
                lv = {n: P.level(x, f, bw=1.2) for n, f in fr.items()}
                ref = lv["2I-T"]
                db = {n: 20 * np.log10(max(v, 1e-12) / ref) for n, v in lv.items()}
                d = np.array([db[n] - CAB[n] for n in CAB])
                d -= d.mean()
                rows.append((float(np.sqrt(np.mean(d ** 2))), f"{int(comp)}{int(comp2)}", p, k, db))
    rows.sort(key=lambda t: t[0])
    print(f"ACC{acc} loaded tap, production population; RMS pattern error (dB) after removing a common offset")
    for e, comp, p, k, db in rows[:6]:
        print(f"  err {e:5.1f}  comp/comp2={comp} p={p} k={k:4.2f} | " + " ".join(f"{n}:{v:5.1f}" for n, v in db.items()))
    e0 = [r for r in rows if r[1] == '00' and r[2] == 1.0 and r[3] == 0.0][0]
    print(f"baseline (MC3340 law, no compression, k=0): err {e0[0]:.1f}  " + " ".join(f"{n}:{v:5.1f}" for n, v in e0[4].items()))
    print("cabinet:", CAB)


if __name__ == "__main__":
    main()
