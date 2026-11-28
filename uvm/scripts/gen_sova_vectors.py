#!/usr/bin/env python3
"""Generate sova_dec RTL test vectors from the bit-true model.

Output dir gets  in.txt  ("F <n>" per frame, then "<sym0> <sym1> <erase>" lines)
and  exp.txt  ("F <m>" per frame, then "<bit> <llr>" lines, m = n - D + 1).
Frame mix: noisy AWGN frames at every 802.11 rate, uniform-random symbols, constant
symbols (maximal ties), all-erased, strongest inputs, and short frames (< D: no output).
Usage: gen_sova_vectors.py <outdir> --mode BR|HR [--frames N] [--seed S] [--D 84 --LR 48]
"""
import argparse
import os
import numpy as np
from sova_ref import SovaRef, channel, PUNCT

ap = argparse.ArgumentParser()
ap.add_argument("outdir")
ap.add_argument("--mode", default="BR", choices=("BR", "HR"))
ap.add_argument("--frames", type=int, default=40)
ap.add_argument("--seed", type=int, default=1)
ap.add_argument("--D", type=int, default=84)
ap.add_argument("--LR", type=int, default=48)
a = ap.parse_args()
rng = np.random.default_rng(a.seed)
os.makedirs(a.outdir, exist_ok=True)

frames = []
rates = list(PUNCT)
for f in range(a.frames):
    kind = f % 8
    n = int(rng.integers(a.D + 1, 2400))
    if kind <= 3:          # noisy coded frames
        u = rng.integers(0, 2, n)
        rate = rates[f % 4]
        snr = float(rng.uniform(-2, 6))
        s0, s1, er, _, _ = channel(u, snr, rate, rng=rng)
    elif kind == 4:        # garbage
        s0, s1 = rng.integers(0, 8, n), rng.integers(0, 8, n)
        er = rng.integers(0, 4, n)
    elif kind == 5:        # constant -> many metric ties
        c = int(rng.integers(0, 8))
        s0 = np.full(n, c); s1 = np.full(n, c); er = np.zeros(n, int)
    elif kind == 6:        # all erased / strongest mix
        s0 = rng.choice([0, 7], n); s1 = rng.choice([0, 7], n)
        er = np.where(rng.random(n) < 0.5, 3, 0)
    else:                  # short frame, no output expected
        n = int(rng.integers(1, a.D))
        s0, s1 = rng.integers(0, 8, n), rng.integers(0, 8, n); er = rng.integers(0, 4, n)
    frames.append((np.asarray(s0), np.asarray(s1), np.asarray(er)))

nout = 0
with open(f"{a.outdir}/in.txt", "w") as fi, open(f"{a.outdir}/exp.txt", "w") as fe:
    for s0, s1, er in frames:
        d = SovaRef(D=a.D, LR=a.LR, mode=a.mode, rmax=63, llr_w=6, shift=1, arch="C")
        outs = [r for r in (d.step(int(x), int(y), int(e)) for x, y, e in zip(s0, s1, er))
                if r is not None]
        fi.write(f"F {len(s0)}\n")
        fi.writelines(f"{x} {y} {e}\n" for x, y, e in zip(s0, s1, er))
        fe.write(f"F {len(outs)}\n")
        fe.writelines(f"{b} {l}\n" for b, l in outs)
        nout += len(outs)
print(f"{len(frames)} frames, {sum(len(f[0]) for f in frames)} inputs, {nout} outputs -> {a.outdir}")
