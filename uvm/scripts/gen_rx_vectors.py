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
    a = ap.parse_args()
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


if __name__ == "__main__":
    main()
