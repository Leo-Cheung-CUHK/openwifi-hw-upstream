#!/usr/bin/env python3
"""
htsig_noise.py - how much L-SIG/HT-SIG margin does a TX capture have?

Adds complex AWGN to a captured openofdm_tx burst and runs the header part of
openofdm's decode.py receiver (channel estimate, pilot tracking, hard-decision demod,
48-bit HT-SIG Viterbi, HT-SIG CRC) many times per SNR. Several captures of the *same*
frame (e.g. upstream RTL vs fixed RTL) see the same noise realisations, so the
difference between them is paired.

  htsig_noise.py --cap old=/tmp/old/dump/rtl_0069.txt --cap fixed=dumps/rtl_0069.txt \
                 --frame dumps/frame_0069.json --snr 0:10:1 -n 500

A trial passes when L-SIG passes decode.py's checks, the HT-SIG CRC is good and the HT-SIG
MCS/length/SGI equal the frame's. A bad HT-SIG CRC makes openofdm treat the frame as legacy,
so the frame is lost.
"""
import argparse, contextlib, io, json, os, sys
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from py_rx_decode import load_decoder

N_HDR = 160 + 160 + 3 * 80 + 400   # STF+LTF+L-SIG+2xHT-SIG, plus spare for the estimator


def load_burst(path):
    d = np.loadtxt(path, ndmin=2)
    nz = np.nonzero(np.abs(d[:, 0]) + np.abs(d[:, 1]))[0]
    x = d[nz[0]:, 0] + 1j * d[nz[0]:, 1]
    return x[:N_HDR], np.mean(np.abs(x[:nz[-1] - nz[0] + 1]) ** 2)


def header(dec, samples):
    """decode.py Decoder.decode() up to the HT-SIG CRC. Returns (signal, ht_signal,
    raw HT-SIG coded bits after deinterleaving)."""
    m = dec.Decoder(None)
    eq = dec.ChannelEstimator(list(samples))
    sig = dec.Signal(m.viterbi_decode(m.deinterleave(m.demodulate(eq.next_symbol()))))
    if not m.check_signal(sig) or sig.rate != 6:
        return sig, None, None
    bits = []
    for _ in range(2):
        bits.extend(m.demodulate([c * -1j for c in eq.next_symbol()]))
    raw = m.deinterleave(bits)
    return sig, dec.HTSignal(m.viterbi_decode(raw)), raw


def ok(dec, samples, fr):
    with contextlib.redirect_stdout(io.StringIO()):
        try:
            _, hs, _ = header(dec, samples)
        except Exception:
            return False
    if hs is None or not hs.crc_ok:
        return False
    return (hs.mcs == fr["rate"] and hs.length == len(bytes.fromhex(fr["mpdu_hex"])) + 4
            and (hs.short_gi == "1") == bool(fr["sgi"]))


_DEC = None
def _init():
    global _DEC
    _DEC = load_decoder()


def _point(job):
    snr, n, seed, caps, fr = job
    rng = np.random.default_rng(seed + int(round(snr * 100)))
    fails = dict.fromkeys(caps, 0)
    for _ in range(n):
        w = (rng.standard_normal(N_HDR) + 1j * rng.standard_normal(N_HDR)) / np.sqrt(2)
        for k, (x, p) in caps.items():
            if not ok(_DEC, x + w * np.sqrt(p / 10 ** (snr / 10)), fr):
                fails[k] += 1
    return snr, fails


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cap", action="append", required=True, help="name=rtl_NNNN.txt (repeatable)")
    ap.add_argument("--frame", required=True, help="frame_NNNN.json of the captured frame")
    ap.add_argument("--snr", default="0:10:1", help="start:stop:step in dB (inclusive)")
    ap.add_argument("-n", type=int, default=500, help="trials per SNR point")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("-j", type=int, default=os.cpu_count())
    a = ap.parse_args()

    dec = load_decoder()
    fr = json.load(open(a.frame))
    caps = {}
    for c in a.cap:
        name, path = c.split("=", 1)
        caps[name] = load_burst(path)

    # coded-bit view on the clean captures: where do they differ inside HT-SIG?
    with contextlib.redirect_stdout(io.StringIO()):
        raws = {k: header(dec, x)[2] for k, (x, _) in caps.items()}
    names = list(caps)
    for k in names[1:]:
        diff = [i for i, (p, q) in enumerate(zip(raws[names[0]], raws[k])) if p != q]
        print(f"clean HT-SIG coded bits {names[0]} vs {k}: {len(diff)}/96 differ at {diff}")
    for k in names:
        print(f"clean {k}: header ok = {ok(dec, caps[k][0], fr)}")

    s0, s1, st = (float(v) for v in a.snr.split(":"))
    snrs = np.arange(s0, s1 + st / 2, st)
    print(f"\nframe: HT MCS{fr['rate']} sgi={fr['sgi']} len={len(fr['mpdu_hex'])//2 + 4}, {a.n} trials/point")
    print("SNR dB  " + "  ".join(f"{k:>12}" for k in names) + "   (HT-SIG frame error rate)")
    from concurrent.futures import ProcessPoolExecutor
    jobs = [(snr, a.n, a.seed, caps, fr) for snr in snrs]
    rows = []
    with ProcessPoolExecutor(a.j, initializer=_init) as ex:
        for snr, fails in ex.map(_point, jobs):
            rows.append((snr, fails))
            print(f"{snr:6.1f}  " + "  ".join(f"{fails[k] / a.n:12.4f}" for k in names), flush=True)
    return rows


if __name__ == "__main__":
    main()
