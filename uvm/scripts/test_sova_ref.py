#!/usr/bin/env python3
"""Self-checks for sova_ref.py.

1. Hard decisions == an independent traceback Viterbi (same tie rules, same depth D),
   streaming, with puncturing/erasures and quantised noisy input.
2. BR-SOVA with a full-block window == max-log-MAP (BCJR) LLRs, exactly (integers).
3. AWGN: BER of the hard output, and LLR calibration (error rate per |LLR| bucket
   against the max-log prediction 1/(1+exp(|L|/2)) in Lc units).
Run: python3 uvm/scripts/test_sova_ref.py [--quick]
"""
import sys
import numpy as np
from sova_ref import (SovaRef, channel as _channel, PUNCT, decode_block, encode, sym_to_lc, NS, P0, P1, A0, B0, A1, B1,
                      U_OF_N, OUT_A, OUT_B)

QUICK = "--quick" in sys.argv
rng = np.random.default_rng(2026)
fails = 0


def check(name, ok, extra=""):
    global fails
    print(f"{'PASS' if ok else 'FAIL'}  {name} {extra}")
    fails += 0 if ok else 1


def channel(u, snr_db, rate="1/2", scale=2.0):
    return _channel(u, snr_db, rate, scale, rng)


# ---------- 1. independent traceback Viterbi ----------
def viterbi_tb(l0, l1, D=84, init_penalty=64):
    pm = np.zeros(NS, dtype=np.int64); pm[1:] = -init_penalty
    dec = []
    out = []
    for k, (x0, x1) in enumerate(zip(l0, l1)):
        m0 = pm[P0] + (1 - 2 * A0) * x0 + (1 - 2 * B0) * x1
        m1 = pm[P1] + (1 - 2 * A1) * x0 + (1 - 2 * B1) * x1
        sel = m1 > m0
        dec.append(sel.copy()); pm = np.maximum(m0, m1)
        if k + 1 >= D:
            s = int(np.argmax(pm))
            for j in range(D - 1):           # trace back D-1 branches
                t = k - j
                s = (P1 if dec[t][s] else P0)[s]
            out.append(s >> 5)                # u at time k-D+1 is MSB of that state
    return np.array(out)


for rate in PUNCT:
    u = rng.integers(0, 2, 600 if QUICK else 2000)
    s0, s1, er, l0, l1 = channel(u, 3.0, rate)
    d = SovaRef(D=84)
    got = [d.step(a, b, e) for a, b, e in zip(s0, s1, er)]
    got = np.array([g[0] for g in got if g is not None])
    ref = viterbi_tb(l0, l1, 84)
    check(f"hard == traceback Viterbi, rate {rate}", np.array_equal(got, ref),
          f"({len(ref)} bits)")


# ---------- 2. BR-SOVA == max-log-MAP ----------
def maxlog_map(l0, l1, init_penalty=64):
    N = len(l0)
    BIG = 10 ** 9
    al = np.full((N + 1, NS), -BIG, dtype=np.int64); al[0, :] = -init_penalty; al[0, 0] = 0
    be = np.full((N + 1, NS), -BIG, dtype=np.int64); be[N, 0] = 0
    gam = lambda k, p, u: (1 - 2 * OUT_A[p, u]) * l0[k] + (1 - 2 * OUT_B[p, u]) * l1[k]
    for k in range(N):
        for n in range(NS):
            u = n >> 5; p0, p1 = P0[n], P1[n]
            al[k + 1, n] = max(al[k, p0] + gam(k, p0, u), al[k, p1] + gam(k, p1, u))
    for k in range(N - 1, -1, -1):
        for p in range(NS):
            best = -BIG
            for u in (0, 1):
                n = (u << 5) | (p >> 1)
                best = max(best, gam(k, p, u) + be[k + 1, n])
            be[k, p] = best
    llr = np.zeros(N, dtype=np.int64)
    for k in range(N):
        m = [-BIG, -BIG]
        for p in range(NS):
            for u in (0, 1):
                n = (u << 5) | (p >> 1)
                m[u] = max(m[u], al[k, p] + gam(k, p, u) + be[k + 1, n])
        llr[k] = m[0] - m[1]
    return llr


ok_all = True
for trial in range(3 if QUICK else 8):
    N = 120
    u = np.concatenate([rng.integers(0, 2, N - 6), np.zeros(6, int)])
    rate = "1/2" if trial % 2 == 0 else "3/4"
    _, _, _, l0, l1 = channel(u, 1.0, rate)
    BIGR = 10 ** 8
    bits, llr = decode_block(l0, l1, D=N + 1, mode="BR", rmax=BIGR, llr_w=40)
    ref = maxlog_map(l0, l1)
    n = N - 6  # tail bits are known zeros: both sides 'infinite', compare data bits only
    ok = np.array_equal(llr[:n], ref[:n]) and np.array_equal(bits[:n], (ref[:n] < 0).astype(int))
    if not ok:
        bad = np.nonzero(llr != ref)[0]
        print("   mismatch at", bad[:10], llr[bad[:10]], ref[bad[:10]])
    ok_all &= ok
check("BR-SOVA (full window, no saturation) == max-log-MAP, bit-exact", ok_all)

bits, llr_hr = decode_block(l0, l1, D=N + 1, mode="HR", rmax=10 ** 8, llr_w=40)
over = np.mean(np.abs(llr_hr[:n]) >= np.abs(ref[:n]))
check("HR-SOVA |LLR| >= max-log |LLR| (HR over-estimates)", over == 1.0, f"({over:.3f})")


# ---------- 3. AWGN: BER and LLR calibration ----------
print("\nAWGN, rate 1/2, 3-bit input, D=84, LR=84, RMAX=127, 6-bit LLR (shift 1)")
print(" Es/N0 per coded bit (dB); Eb/N0 = +3 dB")
print(" SNR  mode   BER       |  calibration: bucket |L|/2 -> measured err / predicted")
nb = 20000 if QUICK else 60000
for snr in (-1.0, 0.0, 1.0):
    u = rng.integers(0, 2, nb)
    s0, s1, er, l0, l1 = channel(u, snr, "1/2")
    for mode in ("BR", "HR"):
        d = SovaRef(D=84, mode=mode, shift=1)
        res = [d.step(a, b, e) for a, b, e in zip(s0, s1, er)]
        res = [r for r in res if r is not None]
        hb = np.array([r[0] for r in res]); L = np.array([r[1] for r in res])
        uu = u[:len(hb)]
        err = hb != uu
        line = f" {snr:3.1f}  {mode}  {err.mean():.2e}  |"
        # measured vs predicted error prob per bucket (LLR in units of Lc, |L| = R/2)
        for lo, hi in ((0, 2), (2, 4), (4, 8), (8, 16), (16, 32)):
            m = (np.abs(L) >= lo) & (np.abs(L) < hi)
            if m.sum() > 50:
                sig2 = 1 / (2 * 10 ** (snr / 10))
                pred = np.mean(1 / (1 + np.exp(np.abs(L[m]) / (2.0 * sig2))))
                line += f" [{lo},{hi}) {err[m].mean():.4f}/{pred:.4f}"
        print(line)

print(f"\n{'ALL PASS' if fails == 0 else f'{fails} FAIL'}")
sys.exit(1 if fails else 0)
