#!/usr/bin/env python3
"""
compare_golden.py - compare openofdm_tx dumps with a golden set.

  compare_golden.py <dump_dir> [--golden uvm/vectors/otx_rate_sweep/fixed]

Pass when every golden rtl_NNNN.txt (I/Q) is byte-identical in <dump_dir> and every field of the
golden frame_NNNN.json (ht, rate, sgi, mpdu_hex) has the same value there; fields added to the
dumps later (aggr, seed, pilot_seed, ...) are metadata and do not count. Used by ci_s0.sh (golden
step, Verilator) and for the cross-simulator check: xsim with +OTX_REPLAY=<golden> must give the
same I/Q as Verilator. Line endings are normalised, so a Windows dump compares equal.
"""
import argparse, glob, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))


def lines(p):
    with open(p, "rb") as fh:
        return fh.read().replace(b"\r\n", b"\n").rstrip(b"\n").split(b"\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump_dir")
    ap.add_argument("--golden", default=os.path.join(HERE, "..", "vectors", "otx_rate_sweep", "fixed"))
    a = ap.parse_args()
    g, d = a.golden, a.dump_dir
    frames = sorted(glob.glob(os.path.join(g, "rtl_*.txt")))
    if not frames:
        sys.exit(f"no rtl_*.txt in {g}")
    bad = []
    for f in frames:
        n = os.path.basename(f)[4:8]
        o = os.path.join(d, os.path.basename(f))
        why = None
        if not os.path.isfile(o):
            why = "missing"
        else:
            A, B = lines(f), lines(o)
            if A != B:
                diff = next((i for i, (x, y) in enumerate(zip(A, B)) if x != y), min(len(A), len(B)))
                why = f"I/Q differs from sample {diff} ({len(B)} vs {len(A)} samples)"
        jg, jd = os.path.join(g, f"frame_{n}.json"), os.path.join(d, f"frame_{n}.json")
        if why is None and os.path.isfile(jg):
            if not os.path.isfile(jd):
                why = "frame json missing"
            else:
                A, B = json.load(open(jg)), json.load(open(jd))
                keys = [k for k, v in A.items() if B.get(k) != v]
                if keys:
                    why = "frame differs in " + ", ".join(keys)
        if why:
            bad.append((n, why))
    for n, why in bad[:20]:
        print(f"  frame {n}: {why}")
    print(f"golden: {len(frames) - len(bad)}/{len(frames)} frames identical")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
