#!/usr/bin/env python3
"""LR (reliability window) sweep for the SOVA reference model.

Variant A: decision depth D=84 (hard bits identical to Xilinx-depth Viterbi), R updated
           only on lags < LR.
Variant B: D = LR (whole decoder is a register exchange of length LR; cheapest, but the
           hard-decision depth shrinks too).
LLR quality metric: empirical mutual information I(U; LLR) from the joint histogram
(scale-free, 1.0 = perfect).  Same noise realisation for every config.
Run: python3 uvm/scripts/sova_lr_sweep.py [--quick]
"""
import sys
import numpy as np
from sova_ref import SovaRef, channel

QUICK = "--quick" in sys.argv
NB = 20000 if QUICK else 60000
LRS = (12, 18, 24, 32, 48, 84)


def mi(u, L):
    vals, inv = np.unique(L, return_inverse=True)
    j = np.zeros((2, len(vals)))
    np.add.at(j, (u, inv), 1)
    j /= j.sum()
    pu, pl = j.sum(1, keepdims=True), j.sum(0, keepdims=True)
    nz = j > 0
    return float(np.sum(j[nz] * np.log2(j[nz] / (pu @ pl)[nz])))


def run(s0, s1, er, u, D, LR, mode):
    d = SovaRef(D=D, LR=LR, mode=mode, shift=1)
    res = [d.step(a, b, e) for a, b, e in zip(s0, s1, er)]
    res = [r for r in res if r is not None]
    hb = np.array([r[0] for r in res]); L = np.array([r[1] for r in res])
    uu = u[:len(hb)]
    return np.mean(hb != uu), mi(uu, L), np.mean(np.abs(L) == 31)


def main():
  for rate, snr in (("1/2", -1.0), ("3/4", 3.0)):
      rng_u = np.random.default_rng(7)
      u = rng_u.integers(0, 2, NB)
      s0, s1, er, _, _ = channel(u, snr, rate, rng=np.random.default_rng(11))
      print(f"\nrate {rate}, Es/N0 {snr} dB, {NB} bits")
      print(" mode  LR | A: D=84  BER      MI     sat | B: D=LR  BER      MI")
      for mode in ("BR", "HR"):
          for lr in LRS:
              ba, ia, sa = run(s0, s1, er, u, 84, lr, mode)
              bb, ib, _ = run(s0, s1, er, u, lr, lr, mode) if lr < 84 else (ba, ia, sa)
              print(f" {mode}  {lr:3d} |       {ba:.2e}  {ia:.4f}  {sa:.2f} |       {bb:.2e}  {ib:.4f}")


if __name__ == "__main__":
    main()
