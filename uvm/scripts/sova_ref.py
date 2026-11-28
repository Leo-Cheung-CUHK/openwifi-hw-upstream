#!/usr/bin/env python3
"""Bit-true reference model of the openwifi SOVA decoder (drop-in for Xilinx Viterbi v9.1
as configured in ip/openofdm_rx: K=7, 133/171, soft width 3, offset binary, external
puncturing via 2-bit erase, traceback/decision depth 84).

This file is the *spec* the RTL must match bit-exactly.

Trellis
  state s = (u[k-1]<<5) | (u[k-2]<<4) | ... | u[k-6]
  next    = (u[k]<<5) | (s>>1)
  A (data_in0) = u[k]^u[k-2]^u[k-3]^u[k-5]^u[k-6]   (133 octal)
  B (data_in1) = u[k]^u[k-1]^u[k-2]^u[k-3]^u[k-6]   (171 octal)
  The two predecessors of state n are p0=((n&31)<<1) and p1=p0|1 (they differ in u[k-6]).

Input
  sym in 0..7, offset binary (0 = strongest '0', 7 = strongest '1'), as openofdm feeds it.
  Channel LLR  Lc = 7 - 2*sym  (odd, -7..+7, positive = bit 0); erased -> 0.

Metrics (maximised)
  bm   = (1-2a)*Lc0 + (1-2b)*Lc1
  pm'  = max(pm[p0]+bm0, pm[p1]+bm1); tie -> p0
  Delta = |m0 - m1|                 (metric units; Delta = 2 x max-log LLR in Lc units)
  RTL may use modulo path metrics: selection and Delta are unchanged.

Reliability (register exchange, per state, lags 0..D-1; lag 0 = newest bit)
  new bit enters with R = RMAX; for lag j < LR (reliability window):
    bits differ (survivor vs competitor):  R = min(Rs, Delta)
    bits equal, BR-SOVA:                   R = min(Rs, sat(Delta + Rc))
    bits equal, HR-SOVA:                   R = Rs
  lags >= LR are carried unchanged.  All R saturate at RMAX.

Output (one per input once D inputs have been seen, like the streaming Xilinx core)
  b = argmax pm (tie -> lowest state); bit = path[b][D-1]
  llr = sat_LLRW( (R[b][D-1] >> SHIFT) ), negated when bit == 1  (positive = bit 0)
"""
import numpy as np

K = 7
NS = 64
G0, G1 = 0o133, 0o171


def _parity(x):
    return bin(x).count("1") & 1


# encoder output for (predecessor state p, input u): register = u<<6 | p
_REG = np.array([[(u << 6) | p for u in (0, 1)] for p in range(NS)])
OUT_A = np.vectorize(lambda r: _parity(r & G0))(_REG)  # [p][u]
OUT_B = np.vectorize(lambda r: _parity(r & G1))(_REG)

N_IDX = np.arange(NS)
U_OF_N = N_IDX >> 5
P0 = (N_IDX & 31) << 1
P1 = P0 | 1
A0, B0 = OUT_A[P0, U_OF_N], OUT_B[P0, U_OF_N]
A1, B1 = OUT_A[P1, U_OF_N], OUT_B[P1, U_OF_N]


def encode(bits, state=0):
    """802.11 BCC rate 1/2, returns (A, B) arrays."""
    a, b = [], []
    for u in bits:
        a.append(OUT_A[state, u]); b.append(OUT_B[state, u])
        state = (u << 5) | (state >> 1)
    return np.array(a, dtype=np.int64), np.array(b, dtype=np.int64)


def sym_to_lc(sym, erase=0):
    return 0 if erase else 7 - 2 * int(sym)


class SovaRef:
    """arch="A": reliability carried with every path over all D lags (LR limits updates).
    arch="C": bits use depth D (register exchange / traceback, identical result); the
              reliability register exchange is only LR lags long.  At each step the best
              state's (bit, R) at lag LR-1 is pushed into a (D-LR)-deep delay line; the
              output LLR magnitude is that R, or 0 if its bit disagrees with the depth-D bit.
    """
    def __init__(self, D=84, LR=None, mode="BR", rmax=127, llr_w=6, shift=0,
                 init_penalty=64, known_start=True, arch="A"):
        self.arch = arch
        assert mode in ("BR", "HR")
        self.D, self.LR = D, (D if LR is None else LR)
        self.mode, self.rmax = mode, rmax
        self.llr_max = (1 << (llr_w - 1)) - 1
        self.shift = shift
        self.init_penalty, self.known_start = init_penalty, known_start
        self.reset()

    def reset(self):
        self.pm = np.zeros(NS, dtype=np.int64)
        if self.known_start:
            self.pm[1:] = -self.init_penalty
        self.bits = np.zeros((NS, self.D), dtype=np.int8)
        self.rel = np.full((NS, self.D), self.rmax, dtype=np.int64)
        self.k = 0
        self.dline = []
        self.disagree = 0

    # ---- one trellis step: Lc0, Lc1 are channel LLRs (int) ----
    def step_lc(self, l0, l1):
        bm0 = (1 - 2 * A0) * l0 + (1 - 2 * B0) * l1
        bm1 = (1 - 2 * A1) * l0 + (1 - 2 * B1) * l1
        m0 = self.pm[P0] + bm0
        m1 = self.pm[P1] + bm1
        sel = m1 > m0
        surv = np.where(sel, P1, P0)
        comp = np.where(sel, P0, P1)
        delta = np.minimum(np.abs(m0 - m1), self.rmax)[:, None]
        self.pm = np.maximum(m0, m1)
        self.pm -= self.pm.max()  # normalisation (model only; does not change results)

        bs, bc = self.bits[surv, :-1], self.bits[comp, :-1]
        rs, rc = self.rel[surv, :-1], self.rel[comp, :-1]
        differ = bs != bc
        if self.mode == "BR":
            eq = np.minimum(rs, np.minimum(delta + rc, self.rmax))
        else:
            eq = rs
        upd = np.where(differ, np.minimum(rs, delta), eq)
        lr = self.LR - 1  # lags 1..LR-1 after shift correspond to old lags 0..LR-2
        if lr < upd.shape[1]:
            upd[:, lr:] = rs[:, lr:]
        self.bits = np.concatenate([U_OF_N[:, None].astype(np.int8), bs], axis=1)
        self.rel = np.concatenate([np.full((NS, 1), self.rmax), upd], axis=1)
        self.k += 1
        best = int(np.argmax(self.pm))
        if self.arch == "C":
            if self.k >= self.LR:
                self.dline.append((int(self.bits[best, self.LR - 1]),
                                   int(self.rel[best, self.LR - 1])))
            if self.k >= self.D:
                rb, r = self.dline.pop(0)
                bit = int(self.bits[best, self.D - 1])
                if rb != bit:
                    r = 0; self.disagree += 1
                mag = min(r >> self.shift, self.llr_max)
                return bit, (-mag if bit else mag)
            return None
        if self.k >= self.D:
            return self._out(best, self.D - 1)
        return None

    def _out(self, state, lag):
        bit = int(self.bits[state, lag])
        mag = min(int(self.rel[state, lag]) >> self.shift, self.llr_max)
        return bit, (-mag if bit else mag)

    def step(self, sym0, sym1, erase=0):
        """Xilinx-style input: offset-binary 3-bit syms, erase[0]->sym0, erase[1]->sym1."""
        return self.step_lc(sym_to_lc(sym0, erase & 1), sym_to_lc(sym1, (erase >> 1) & 1))

    def finish(self, state=0):
        """Block mode helper: emit the bits still in the window, traced from `state`
        (0 for a tail-terminated block). Not part of the streaming RTL behaviour."""
        n = min(self.k, self.D) - (1 if self.k >= self.D else 0)
        return [self._out(state, lag) for lag in range(n - 1, -1, -1)]


def decode_block(l0, l1, terminated=True, **kw):
    """Decode a whole block of channel LLRs; returns (bits, llrs) of length len(l0)."""
    dec = SovaRef(**kw)
    out = []
    for a, b in zip(l0, l1):
        r = dec.step_lc(int(a), int(b))
        if r is not None:
            out.append(r)
    out += dec.finish(0 if terminated else int(np.argmax(dec.pm)))
    bits = np.array([o[0] for o in out]); llrs = np.array([o[1] for o in out])
    return bits, llrs


# ---------- channel helpers ----------
PUNCT = {"1/2": ([1], [1]), "2/3": ([1, 1], [1, 0]), "3/4": ([1, 1, 0], [1, 0, 1]),
         "5/6": ([1, 1, 0, 1, 0], [1, 0, 1, 0, 1])}


def channel(u, snr_db, rate="1/2", scale=2.0, rng=None):
    """BPSK + AWGN, 3-bit offset-binary quantisation, puncturing as erasures."""
    rng = rng or np.random.default_rng()
    a, b = encode(u)
    pa, pb = PUNCT[rate]
    ea = np.array([0 if pa[i % len(pa)] else 1 for i in range(len(u))])
    eb = np.array([0 if pb[i % len(pb)] else 1 for i in range(len(u))])
    sigma = np.sqrt(1 / (2 * 10 ** (snr_db / 10)))
    def q(c):
        y = (1 - 2 * c) + sigma * rng.standard_normal(len(c))   # + = bit 0
        lvl = np.clip(np.round(3.5 - y * scale), 0, 7)            # 0 strongest '0'
        return lvl.astype(int)
    s0, s1 = q(a), q(b)
    l0 = np.array([sym_to_lc(s, e) for s, e in zip(s0, ea)])
    l1 = np.array([sym_to_lc(s, e) for s, e in zip(s1, eb)])
    return s0, s1, ea | (eb << 1), l0, l1


if __name__ == "__main__":
    rng = np.random.default_rng(1)
    u = np.concatenate([rng.integers(0, 2, 200), np.zeros(6, int)])
    a, b = encode(u)
    bits, llrs = decode_block(7 - 14 * a, 7 - 14 * b, D=84)
    print("noise-free errors:", int(np.sum(bits != u)), " min |llr|:", int(np.abs(llrs).min()))
