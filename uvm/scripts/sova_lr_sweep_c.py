#!/usr/bin/env python3
"""Arch C vs arch A (D=84) LLR quality; see sova_ref.SovaRef docstring."""
import sys
import numpy as np
from sova_ref import SovaRef, channel
from sova_lr_sweep import mi
NB = 20000 if "--quick" in sys.argv else 60000
for rate, snr in (("1/2", -1.0), ("3/4", 3.0)):
    u = np.random.default_rng(7).integers(0, 2, NB)
    s0, s1, er, _, _ = channel(u, snr, rate, rng=np.random.default_rng(11))
    print(f"\nrate {rate}, Es/N0 {snr} dB")
    print(" mode  LR | arch C  BER      MI     disagree")
    for mode in ("BR", "HR"):
        for lr in (24, 32, 48):
            d = SovaRef(D=84, LR=lr, mode=mode, shift=1, arch="C")
            res = [r for r in (d.step(a, b, e) for a, b, e in zip(s0, s1, er)) if r is not None]
            hb = np.array([r[0] for r in res]); L = np.array([r[1] for r in res]); uu = u[:len(hb)]
            print(f" {mode}  {lr:3d} |        {np.mean(hb != uu):.2e}  {mi(uu, L):.4f}  {d.disagree / len(hb):.4f}")
