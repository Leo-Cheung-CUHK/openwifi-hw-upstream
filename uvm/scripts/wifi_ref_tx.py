#!/usr/bin/env python3
"""
wifi_ref_tx.py - independent floating-point 802.11a/g/n (20 MHz, 1SS, BCC) transmitter.

Golden model for openofdm_tx (block level) and stimulus generator for openofdm_rx /
chip-level RX tests.  Written from IEEE 802.11-2020 clauses 17 (OFDM) and 19 (HT),
not from the RTL, so it is an independent reference.

Inputs (one of):
  --mem FILE        openofdm_tx BRAM image (as in ip/openofdm_tx/unit_test/test_vec/*.mem)
  --json FILE       {"ht":1,"rate":7,"sgi":1,"mpdu_hex":"0801..."}   rate = legacy Mbps or HT MCS

Outputs:
  --out FILE        "I Q" per line at 20 Msps, scaled to --peak (int16), the same text
                    format as openofdm_rx/testing_inputs, so it can drive the RX TBs
  --compare FILE    RTL capture ("I Q" per line, e.g. the openofdm_tx TB dump): prints
                    per-symbol EVM after a per-symbol complex LS gain fit and exits 1 if
                    any symbol is worse than --evm-db (default -30 dB)

Scrambler seed defaults to 0x7F, matching OPENOFDM_TX_REG_INIT_DATA_STATE after hw_init.
"""
import argparse, json, sys
import numpy as np

# ------------------------------------------------------------------ tables
LEG = {6: (1, (1, 2)), 9: (1, (3, 4)), 12: (2, (1, 2)), 18: (2, (3, 4)),
       24: (4, (1, 2)), 36: (4, (3, 4)), 48: (6, (2, 3)), 54: (6, (3, 4))}
LEG_CODE = {6: 0b1011, 9: 0b1111, 12: 0b1010, 18: 0b1110, 24: 0b1001, 36: 0b1101, 48: 0b1000, 54: 0b1100}
CODE_LEG = {v: k for k, v in LEG_CODE.items()}
HT = [(1, (1, 2)), (2, (1, 2)), (2, (3, 4)), (4, (1, 2)), (4, (3, 4)), (6, (2, 3)), (6, (3, 4)), (6, (5, 6))]
PUNC = {(1, 2): ([1], [1]), (2, 3): ([1, 1], [1, 0]), (3, 4): ([1, 1, 0], [1, 0, 1]),
        (5, 6): ([1, 1, 0, 1, 0], [1, 0, 1, 0, 1])}

L_LTF = np.array([1, 1, -1, -1, 1, 1, -1, 1, -1, 1, 1, 1, 1, 1, 1, -1, -1, 1, 1, -1, 1, -1, 1, 1, 1, 1, 0,
                  1, -1, -1, 1, 1, -1, 1, -1, 1, -1, -1, -1, -1, -1, 1, 1, -1, -1, 1, -1, 1, -1, 1, 1, 1, 1], float)
HT_LTF = np.r_[1, 1, L_LTF, -1, -1]                       # -28..28
S = np.zeros(53, complex)                                   # L-STF, -26..26
for k, v in {-24: 1, -20: -1, -16: 1, -12: -1, -8: -1, -4: 1, 4: -1, 8: -1, 12: 1, 16: 1, 20: 1, 24: 1}.items():
    S[k + 26] = v * (1 + 1j) * np.sqrt(13 / 6)


def bits_le(data):  # bytes -> bits, LSB first
    return [(b >> i) & 1 for b in data for i in range(8)]


def crc32(data):
    c = 0xFFFFFFFF
    for b in data:
        c ^= b
        for _ in range(8):
            c = (c >> 1) ^ 0xEDB88320 if c & 1 else c >> 1
    return (~c) & 0xFFFFFFFF


def ht_sig_crc(bits34):  # 802.11-2020 19.3.9.4.4
    c = [1] * 8
    for b in bits34:
        t = b ^ c[7]
        c = [t, c[0] ^ t, c[1] ^ t, c[2], c[3], c[4], c[5], c[6]]
    return [1 - c[7 - i] for i in range(8)]   # c7 first, inverted


def scramble(bits, seed=0x7F):
    s = [(seed >> i) & 1 for i in range(7)]   # s[0]=x1 ... s[6]=x7
    out = []
    for b in bits:
        fb = s[6] ^ s[3]
        out.append(b ^ fb)
        s = [fb] + s[:6]
    return out


def pilot_polarity(n=127, seed=0x7F):
    # dot11_tx.v pilot_scram_state: same LFSR as the data scrambler, bit i == s[i];
    # 802.11 p_n is the sequence from the all-ones state (seed 0x7F)
    s = [(seed >> i) & 1 for i in range(7)]
    p = []
    for _ in range(n):
        fb = s[6] ^ s[3]
        p.append(1 - 2 * fb)
        s = [fb] + s[:6]
    return p


POL = pilot_polarity()


def conv(bits):
    st = [0] * 6
    a, b = [], []
    for x in bits:
        r = [x] + st
        a.append(r[0] ^ r[2] ^ r[3] ^ r[5] ^ r[6])   # g0 = 133o
        b.append(r[0] ^ r[1] ^ r[2] ^ r[3] ^ r[6])   # g1 = 171o
        st = r[:6]
    return a, b


def puncture(a, b, rate):
    pa, pb = PUNC[rate]
    out = []
    for i in range(len(a)):
        if pa[i % len(pa)]:
            out.append(a[i])
        if pb[i % len(pb)]:
            out.append(b[i])
    return out


def interleave(bits, nbpsc, ncbps, ht):
    s = max(nbpsc // 2, 1)
    out = [0] * ncbps
    for k in range(ncbps):
        if ht:
            i = 4 * nbpsc * (k % 13) + k // 13
            j = s * (i // s) + (i + ncbps - (13 * i // ncbps)) % s
        else:
            i = (ncbps // 16) * (k % 16) + k // 16
            j = s * (i // s) + (i + ncbps - (16 * i // ncbps)) % s
        out[j] = bits[k]
    return out


def qam(bits, nbpsc):
    if nbpsc == 1:
        return np.array([2 * b - 1 for b in bits], complex)
    lv = {2: {(0,): -1, (1,): 1},
          4: {(0, 0): -3, (0, 1): -1, (1, 1): 1, (1, 0): 3},
          6: {(0, 0, 0): -7, (0, 0, 1): -5, (0, 1, 1): -3, (0, 1, 0): -1,
              (1, 1, 0): 1, (1, 1, 1): 3, (1, 0, 1): 5, (1, 0, 0): 7}}[nbpsc]
    h = nbpsc // 2
    kmod = {2: 1 / np.sqrt(2), 4: 1 / np.sqrt(10), 6: 1 / np.sqrt(42)}[nbpsc]   # Table 17-11
    out = []
    for i in range(0, len(bits), nbpsc):
        g = bits[i:i + nbpsc]
        out.append(kmod * (lv[tuple(g[:h])] + 1j * lv[tuple(g[h:])]))
    return np.array(out, complex)


def ofdm_sym(data, pilots_val, ht, cp=16):
    X = np.zeros(64, complex)
    lo = 28 if ht else 26
    pil = {-21: 0, -7: 1, 7: 2, 21: 3}
    di = 0
    for k in range(-lo, lo + 1):
        if k == 0:
            continue
        if k in pil:
            X[k % 64] = pilots_val[pil[k]]
        else:
            X[k % 64] = data[di]; di += 1
    x = np.fft.ifft(X) * 64 / np.sqrt(56 if ht else 52)
    return np.r_[x[-cp:], x]


def field_symbols(bits, nbpsc, rate, ht_il, n_sym, pol_start, ht_pilots, qbpsk=False, sgi=False, pol=None):
    pol = POL if pol is None else pol
    ncbps = nbpsc * (52 if ht_il else 48)
    a, b = conv(bits)
    coded = puncture(a, b, rate)
    out = []
    for n in range(n_sym):
        blk = interleave(coded[n * ncbps:(n + 1) * ncbps], nbpsc, ncbps, ht_il)
        d = qam(blk, nbpsc)
        if qbpsk:
            d = d * 1j
        p = pol[(pol_start + n) % 127]
        if ht_pilots:
            psi = [1, 1, 1, -1]
            pv = [p * psi[(m + n) % 4] for m in range(4)]
        else:
            pv = [p, p, p, -p]
        out.append(ofdm_sym(d, pv, ht_il, 8 if sgi else 16))
    return out


def build(ht, rate, sgi, mpdu, seed=0x7F, lsig_bits=None, htsig_bits=None, pad_mode="standard",
          aggr=False, pilot_seed=0x7F):
    # aggr: mpdu is the whole A-MPDU PSDU (delimiters, MPDUs with FCS, pad); no FCS added
    psdu = list(mpdu) if aggr else list(mpdu) + list(crc32(bytes(mpdu)).to_bytes(4, "little"))
    pol = pilot_polarity(seed=pilot_seed)
    L = len(psdu)
    if ht:
        nbpsc, cr = HT[rate]
    else:
        nbpsc, cr = LEG[rate]
    ndbps = nbpsc * (52 if ht else 48) * cr[0] // cr[1]
    n_sym = -(-(16 + 8 * L + 6) // ndbps)
    # ---- SIG fields (standard), optionally replaced by the DUT's raw bits
    if ht:
        n_leg = -(-(n_sym * (72 if sgi else 80)) // 80)
        lsig_len = 3 * (4 + n_leg) - 3
        rcode = LEG_CODE[6]
    else:
        lsig_len, rcode = L, LEG_CODE[rate]
    lsig = [(rcode >> i) & 1 for i in range(4)] + [0] + [(lsig_len >> i) & 1 for i in range(12)]
    lsig += [sum(lsig) & 1] + [0] * 6
    if lsig_bits is not None and lsig_bits != lsig:
        print("WARN: DUT L-SIG bits differ from standard encoding", file=sys.stderr)
        lsig = lsig_bits
    syms = []
    t = np.fft.ifft(np.r_[S[26:], np.zeros(11), S[:26]]) * 64 / np.sqrt(12)
    syms.append(np.tile(t, 3)[:160])                                   # L-STF
    ltf = np.fft.ifft(np.r_[L_LTF[26:], np.zeros(11), L_LTF[:26]]) * 64 / np.sqrt(52)
    syms.append(np.r_[ltf[-32:], ltf, ltf])                             # L-LTF
    syms += field_symbols(lsig, 1, (1, 2), False, 1, 0, False, pol=pol)  # L-SIG
    pol0 = 1
    if ht:
        hs = [(rate >> i) & 1 for i in range(7)] + [0] + [(L >> i) & 1 for i in range(16)]
        hs += [1, 1, 1, int(bool(aggr)), 0, 0, 0, int(sgi), 0, 0]   # smoothing, not-sounding, rsvd, aggregation, STBC, FEC, SGI, Ness
        hs += ht_sig_crc(hs) + [0] * 6
        if htsig_bits is not None and htsig_bits != hs:
            print("WARN: DUT HT-SIG bits differ from standard encoding (using DUT bits)", file=sys.stderr)
            hs = htsig_bits
        syms += field_symbols(hs, 1, (1, 2), False, 2, 1, False, qbpsk=True, pol=pol)  # HT-SIG1/2
        syms.append(np.tile(t, 5)[:80])                                  # HT-STF
        hl = np.zeros(64, complex)
        for k in range(-28, 29):
            hl[k % 64] = HT_LTF[k + 28]
        hl = np.fft.ifft(hl) * 64 / np.sqrt(56)
        syms.append(np.r_[hl[-16:], hl])                                 # HT-LTF1
        pol0 = 3
    # ---- DATA
    bits = [0] * 16 + bits_le(psdu)
    bits += [0] * 6
    bits += [0] * (n_sym * ndbps - len(bits))
    tail0 = 16 + 8 * L
    if pad_mode == "standard":
        # 17.3.5.3: scrambler runs over the tail; the 6 scrambled tail bits are then zeroed
        sc = scramble(bits, seed)
        sc[tail0:tail0 + 6] = [0] * 6
    else:
        # "hold": scrambler state frozen during the tail (dot11_tx.v S11_TAIL), so the pad
        # bits use the sequence 6 steps earlier than a standard transmitter would
        sc = scramble(bits[:tail0] + bits[tail0 + 6:], seed)
        sc = sc[:tail0] + [0] * 6 + sc[tail0:]
    syms += field_symbols(sc, nbpsc, cr, ht, n_sym, pol0, ht, sgi=sgi and ht, pol=pol)
    return syms


def parse_mem(path):
    w = [int(x, 16) for x in open(path).read().split()]
    w0 = w[0]
    ht = (w0 >> 24) & 1
    lsig = [(w0 >> i) & 1 for i in range(24)]
    if ht:
        w1 = w[1]
        hsig = [(w1 >> i) & 1 for i in range(48)]
        mcs = w1 & 0x7F; ln = (w1 >> 8) & 0xFFFF; sgi = (w1 >> 31) & 1
        data = w[2:]
        return dict(ht=1, rate=mcs, sgi=sgi, mpdu=_words_to_bytes(data, ln - 4), lsig=lsig, hsig=hsig)
    ln = (w0 >> 5) & 0xFFF
    return dict(ht=0, rate=CODE_LEG[w0 & 0xF], sgi=0, mpdu=_words_to_bytes(w[2:], ln - 4), lsig=lsig, hsig=None)  # PSDU at word2 for legacy too


def _words_to_bytes(words, n):
    b = []
    for x in words:
        b += [(x >> (8 * k)) & 0xFF for k in range(8)]
    return b[:n]


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--mem"); g.add_argument("--json")
    ap.add_argument("--out"); ap.add_argument("--compare")
    ap.add_argument("--peak", type=int, default=9000)
    ap.add_argument("--seed", type=lambda s: int(s, 0), default=0x7F)
    ap.add_argument("--evm-db", type=float, default=-30.0)
    ap.add_argument("--pad", choices=["standard", "hold"], default="standard",
                    help="pad-bit scrambling: 'standard' (802.11) or 'hold' (current openofdm_tx RTL)")
    a = ap.parse_args()
    if a.mem:
        p = parse_mem(a.mem)
        syms = build(p["ht"], p["rate"], p["sgi"], p["mpdu"], a.seed, p["lsig"], p["hsig"], a.pad)
    else:
        j = json.load(open(a.json))
        syms = build(j["ht"], j["rate"], j.get("sgi", 0), bytes.fromhex(j["mpdu_hex"]), j.get("seed", a.seed),
                     pad_mode=a.pad, aggr=j.get("aggr", 0), pilot_seed=j.get("pilot_seed", 0x7F))
    x = np.concatenate(syms)
    print(f"reference: {len(syms)} fields/symbols, {len(x)} samples @20Msps")
    if a.out:
        y = x / np.abs(x).max() * a.peak
        np.savetxt(a.out, np.c_[np.round(y.real), np.round(y.imag)], fmt="%d")
    if a.compare:
        d = np.loadtxt(a.compare)
        r = d[:, 0] + 1j * d[:, 1]
        if len(r) != len(x):
            print(f"FAIL length: RTL {len(r)} vs ref {len(x)}"); sys.exit(1)
        worst, pos = 0.0, 0
        for i, s in enumerate(syms):
            seg = r[pos:pos + len(s)]
            gfit = np.vdot(s, seg) / np.vdot(s, s)            # LS complex gain
            evm = 10 * np.log10(np.sum(np.abs(seg - gfit * s) ** 2) / np.sum(np.abs(gfit * s) ** 2))
            worst = max(worst, evm) if i else evm
            if evm > a.evm_db:
                print(f"  sym {i:3d} @{pos:5d}: EVM {evm:6.1f} dB  gain {abs(gfit):.3f}")
            pos += len(s)
        print(f"{'PASS' if worst <= a.evm_db else 'FAIL'} worst-symbol EVM {worst:.1f} dB (limit {a.evm_db} dB)")
        sys.exit(0 if worst <= a.evm_db else 1)


if __name__ == "__main__":
    main()
