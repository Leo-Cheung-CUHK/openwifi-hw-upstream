#!/usr/bin/env python3
"""
check_tx_dumps.py - post-process the openofdm_tx block TB dumps (+TX_DUMP_DIR=<dir>).

For every frame_NNNN.json / rtl_NNNN.txt pair, rebuild the waveform with the
independent reference (wifi_ref_tx.py) and check per-symbol EVM.
Exit status 0 only if every packet passes -> usable as a regression gate.

  check_tx_dumps.py <dir> [--pad hold|standard] [--evm-db -30]
"""
import argparse, glob, json, os, sys
import numpy as np
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import wifi_ref_tx as ref


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--pad", default="hold", choices=["hold", "standard"])
    ap.add_argument("--evm-db", type=float, default=-30.0)
    a = ap.parse_args()
    files = sorted(glob.glob(os.path.join(a.dir, "frame_*.json")))
    if not files:
        sys.exit(f"no frame_*.json in {a.dir}")
    bad = 0
    for fj in files:
        n = fj[-9:-5]
        j = json.load(open(fj))
        syms = ref.build(j["ht"], j["rate"], j.get("sgi", 0), bytes.fromhex(j["mpdu_hex"]), pad_mode=a.pad)
        d = np.loadtxt(os.path.join(a.dir, f"rtl_{n}.txt"), ndmin=2)
        r = d[:, 0] + 1j * d[:, 1]
        x = np.concatenate(syms)
        tag = f"{'HT-MCS%d' % j['rate'] if j['ht'] else '%dM' % j['rate']}{'-SGI' if j.get('sgi') else ''} len={len(j['mpdu_hex'])//2}"
        if len(r) != len(x):
            print(f"[{n}] FAIL {tag}: {len(r)} samples, reference {len(x)}"); bad += 1; continue
        worst, pos, worst_i = -999.0, 0, -1
        for i, s in enumerate(syms):
            seg = r[pos:pos + len(s)]
            g = np.vdot(s, seg) / np.vdot(s, s)
            e = 10 * np.log10(np.sum(np.abs(seg - g * s) ** 2) / max(np.sum(np.abs(g * s) ** 2), 1e-30))
            if e > worst:
                worst, worst_i = e, i
            pos += len(s)
        ok = worst <= a.evm_db
        bad += (not ok)
        print(f"[{n}] {'PASS' if ok else 'FAIL'} {tag}: worst EVM {worst:.1f} dB (symbol {worst_i}/{len(syms)-1})")
    print(f"{len(files) - bad}/{len(files)} packets pass")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
