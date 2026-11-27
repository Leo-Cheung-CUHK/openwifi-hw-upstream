#!/usr/bin/env python3
"""
gen_rx_vectors.py - random 802.11a/g/n RX stimulus for the openofdm_rx block TB and the
chip-level RX tests, with the expected PSDU stored next to each waveform.

  gen_rx_vectors.py --out vec_dir -n 50 [--snr 30] [--cfo-hz 20e3] [--seed 1]

Writes vec_dir/rxNNNN.txt ("I Q" per line, 20 Msps, 100 idle samples before / 200 after,
same layout as openofdm_rx/testing_inputs/simulated), rxNNNN.json:
  {"ht":1,"rate":5,"sgi":0,"mpdu_hex":"...","snr_db":30,"cfo_hz":2e4}
rxNNNN.exp (the same expectation in a form $fscanf can read), and vec_dir/list.txt for
+RX_VEC_LIST=.

  gen_rx_vectors.py --out craft_dir --craft     # ORX-07 header-limit vectors
writes crafted frames: <name>.rej ("<want_ht_unsupport> <reason>") for frames the
receiver must refuse, <name>.exp for boundary frames it must decode.
"""
import argparse, json, os, random
import numpy as np
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wifi_ref_tx as ref

LEG_RATES = [6, 9, 12, 18, 24, 36, 48, 54]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("-n", type=int, default=20)
    ap.add_argument("--snr", type=float, default=None, help="AWGN SNR in dB (default: clean)")
    ap.add_argument("--cfo-hz", type=float, default=0.0)
    ap.add_argument("--peak", type=int, default=8000)
    ap.add_argument("--min-len", type=int, default=14)
    ap.add_argument("--max-len", type=int, default=1500)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--craft", action="store_true", help="write the ORX-07 header-limit set instead")
    a = ap.parse_args()
    if a.craft:
        return craft(a)
    random.seed(a.seed); rng = np.random.default_rng(a.seed)
    os.makedirs(a.out, exist_ok=True)
    names = []
    for i in range(a.n):
        ht = random.random() < 0.5
        rate = random.randrange(8) if ht else random.choice(LEG_RATES)
        sgi = int(ht and random.random() < 0.5)
        mpdu = bytes(random.randrange(256) for _ in range(random.randint(a.min_len, a.max_len) - 4))
        x = np.concatenate(ref.build(int(ht), rate, sgi, mpdu))
        if a.cfo_hz:
            x = x * np.exp(2j * np.pi * a.cfo_hz * np.arange(len(x)) / 20e6)
        x = np.r_[np.zeros(100), x, np.zeros(200)]
        x = x / np.abs(x).max() * a.peak
        if a.snr is not None:
            p = np.mean(np.abs(x[100:-200]) ** 2)
            x = x + np.sqrt(p / 10 ** (a.snr / 10) / 2) * (rng.standard_normal(len(x)) + 1j * rng.standard_normal(len(x)))
        name = f"rx{i:04d}"
        np.savetxt(os.path.join(a.out, name + ".txt"), np.c_[np.round(x.real), np.round(x.imag)], fmt="%d")
        json.dump(dict(ht=int(ht), rate=rate, sgi=sgi, mpdu_hex=mpdu.hex(), snr_db=a.snr, cfo_hz=a.cfo_hz),
                  open(os.path.join(a.out, name + ".json"), "w"))
        # SV-friendly sidecar read by the TB: "ht rate_hw sgi mpdu_len" then the MPDU in hex
        rate_hw = rate if ht else 4 + LEG_RATES.index(rate)
        with open(os.path.join(a.out, name + ".exp"), "w") as fh:
            fh.write(f"{int(ht)} {rate_hw} {sgi} {len(mpdu)}\n{mpdu.hex()}\n")
        names.append(os.path.abspath(os.path.join(a.out, name + ".txt")))
    open(os.path.join(a.out, "list.txt"), "w").write("\n".join(names) + "\n")
    print(f"wrote {a.n} vectors to {a.out}")


def _write(a, name, x, exp=None, rej=None):
    x = np.r_[np.zeros(100), x, np.zeros(200)]
    x = x / np.abs(x).max() * a.peak
    np.savetxt(os.path.join(a.out, name + ".txt"), np.c_[np.round(x.real), np.round(x.imag)], fmt="%d")
    if exp is not None:
        ht, rate_hw, sgi, mpdu = exp
        with open(os.path.join(a.out, name + ".exp"), "w") as fh:
            fh.write(f"{ht} {rate_hw} {sgi} {len(mpdu)}\n{mpdu.hex()}\n")
    else:
        with open(os.path.join(a.out, name + ".rej"), "w") as fh:
            fh.write(f"{rej[0]} {rej[1]}\n")
    return os.path.abspath(os.path.join(a.out, name + ".txt"))


def _htsig(mcs, length, sgi, cbw=0, stbc=0, fec=0, aggr=0):
    hs = [(mcs >> i) & 1 for i in range(7)] + [cbw] + [(length >> i) & 1 for i in range(16)]
    hs += [1, 1, 1, aggr, stbc & 1, (stbc >> 1) & 1, fec, sgi, 0, 0]
    return hs + ref.ht_sig_crc(hs) + [0] * 6


def craft(a):
    """ORX-07 set. Thresholds are the driver defaults (openofdm_rx hw_init):
    MIN_LEN_TH = 14 (slv_reg4[15:12], 4 bits wide), MAX_LEN_TH = 1700; signal_watchdog.v
    compares them with the L-SIG LENGTH (for HT frames: the spoofed 3*(4+N)-3)."""
    random.seed(a.seed)
    os.makedirs(a.out, exist_ok=True)
    rnd = lambda n: bytes(random.randrange(256) for _ in range(n))
    names = []
    # clean recovery frame first (orx_len_limits_test uses the first .exp vector)
    m = rnd(96)
    names.append(_write(a, "c00_clean_24M", np.concatenate(ref.build(0, 24, 0, m)), exp=(0, 8, 0, m)))
    # L-SIG LENGTH boundaries (PSDU incl. FCS = len(mpdu) + 4)
    for nm, L, ok in (("c01_len13_below_min", 13, 0), ("c02_len14_min", 14, 1),
                      ("c03_len1700_max", 1700, 1), ("c04_len1701_above_max", 1701, 0),
                      ("c05_len2000", 2000, 0)):
        m = rnd(L - 4); x = np.concatenate(ref.build(0, 54, 0, m))
        names.append(_write(a, nm, x, exp=(0, 11, 0, m)) if ok else _write(a, nm, x, rej=(0, f"L-SIG_LENGTH={L}")))
    # HT-SIG fields openofdm_rx does not support (dot11.v S_CHECK_HT_SIG); data coded as MCS0
    m = rnd(60); L = len(m) + 4
    for nm, hs, why in (("c06_ht_mcs8", _htsig(8, L, 0), "MCS=8"),
                        ("c07_ht_mcs15", _htsig(15, L, 0), "MCS=15"),
                        ("c08_ht_cbw40", _htsig(0, L, 0, cbw=1), "CBW40"),
                        ("c09_ht_stbc1", _htsig(0, L, 0, stbc=1), "STBC=1"),
                        ("c10_ht_ldpc", _htsig(0, L, 0, fec=1), "FEC=LDPC")):
        x = np.concatenate(ref.build(1, 0, 0, m, htsig_bits=hs))
        names.append(_write(a, nm, x, rej=(1, why)))
    # one-symbol HT frames: L-SIG LENGTH spoof = 3*(4+1)-3 = 12 < MIN_LEN_TH (14); per 802.11
    # these are valid frames and must decode
    for nm, mcs, n in (("c11_ht_mcs7_1sym", 7, 20), ("c12_ht_mcs5_1sym", 5, 14)):
        m = rnd(n)
        names.append(_write(a, nm, np.concatenate(ref.build(1, mcs, 0, m)), exp=(1, mcs, 0, m)))
    # two-symbol HT frame (L-SIG LENGTH 15) as the control
    m = rnd(40)
    names.append(_write(a, "c13_ht_mcs7_2sym", np.concatenate(ref.build(1, 7, 0, m)), exp=(1, 7, 0, m)))
    open(os.path.join(a.out, "list.txt"), "w").write("\n".join(names) + "\n")
    print(f"wrote {len(names)} crafted vectors to {a.out}")


if __name__ == "__main__":
    main()
