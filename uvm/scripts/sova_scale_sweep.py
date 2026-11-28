#!/usr/bin/env python3
"""rmax and HR scaling sweep for arch C, LR=48.  Reports MI and the best-fit scale c that
maps the integer LLR to a calibrated LLR (min cross-entropy).  HR/BR ratio of c is the
fixed scaling factor HR needs to match BR calibration."""
import sys
import numpy as np
from sova_ref import SovaRef, channel
from sova_lr_sweep import mi
NB = 20000 if "--quick" in sys.argv else 40000

def best_c(u, L):
    x = 1 - 2 * u
    cs = np.linspace(0.02, 1.5, 300)
    ce = [np.mean(np.logaddexp(0, -c * x * L)) for c in cs]
    i = int(np.argmin(ce)); return cs[i], 1 - ce[i] / np.log(2)

for rate, snr in (("1/2", -1.0), ("1/2", 0.0), ("3/4", 3.0)):
    u = np.random.default_rng(7).integers(0, 2, NB)
    s0, s1, er, _, _ = channel(u, snr, rate, rng=np.random.default_rng(11))
    print(f"\nrate {rate}, Es/N0 {snr} dB")
    cb = {}
    for mode in ("BR", "HR"):
        for rmax in (63, 127):
            d = SovaRef(D=84, LR=48, mode=mode, shift=1, rmax=rmax, arch="C")
            res = [r for r in (d.step(a, b, e) for a, b, e in zip(s0, s1, er)) if r is not None]
            hb = np.array([r[0] for r in res]); L = np.array([r[1] for r in res]); uu = u[:len(hb)]
            c, mic = best_c(uu, L); cb[(mode, rmax)] = c
            print(f" {mode} rmax={rmax:3d}  MI={mi(uu, L):.4f}  best c={c:.3f}  MI@c={mic:.4f}  sat={np.mean(np.abs(L)==31):.3f}")
    print(f" HR/BR scale (rmax 63): {cb[('HR',63)]/cb[('BR',63)]:.3f}")
