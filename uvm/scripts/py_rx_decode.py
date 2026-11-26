#!/usr/bin/env python3
"""
py_rx_decode.py - decode TX captures with openofdm's own Python receiver
(ip/openofdm_rx/scripts/decode.py: LTF timing, channel estimate, pilot tracking,
48-bit HT-SIG Viterbi + CRC, BCC Viterbi via the bundled commpy, descrambler).

An independent *receiver* check of openofdm_tx, complementing the waveform check in
check_tx_dumps.py: a frame passes only if decode.py finds it, the (HT-)SIG fields match,
the PSDU equals the transmitted MPDU and its FCS is correct.

  py_rx_decode.py <dump_dir>                 # frame_NNNN.json + rtl_NNNN.txt (otx TB +TX_DUMP_DIR)
  py_rx_decode.py --iq file.txt --mpdu HEX [--ht 1 --rate 7 --sgi 0]

decode.py is loaded unmodified from the openwifi-hw tree; only Python-3 incompatibilities
are patched in memory (integer division, str/bytes) and its wltrace dependency is stubbed.
"""
import argparse, glob, io, json, os, re, sys, types, zlib, contextlib

HERE = os.path.dirname(os.path.abspath(__file__))
HW = os.environ.get("OW_HW", os.path.abspath(os.path.join(HERE, "..", "..")))
SCRIPTS = os.path.join(HW, "ip", "openofdm_rx", "scripts")


def load_decoder():
    # wltrace is only used for mcs_to_rate() and pretty-printing the MAC header
    wl = types.ModuleType("wltrace"); d11 = types.ModuleType("wltrace.dot11")
    d11.mcs_to_rate = lambda mcs: [6.5, 13, 19.5, 26, 39, 52, 58.5, 65][mcs]
    d11.Dot11Packet = lambda fh: None
    wl.dot11 = d11
    sys.modules["wltrace"] = wl; sys.modules["wltrace.dot11"] = d11
    import numpy as np                               # bundled commpy predates numpy 1.24,
    for k, v in (("complex", complex), ("float", float), ("int", int), ("bool", bool)):  # which
        if not hasattr(np, k): setattr(np, k, v)     # removed these aliases
    sys.path.insert(0, SCRIPTS)                      # bundled commpy
    src = open(os.path.join(SCRIPTS, "decode.py")).read()
    src = src.replace("min(len(data_bits)/8, signal.length)", "min(len(data_bits)//8, signal.length)")
    src = src.replace("fh = StringIO(''.join([chr(b) for b in data_bytes]))", "fh = None")
    src = re.sub(r"([\w\.]+)\.next\(\)", r"next(\1)", src)   # py2 iterator.next()
    src = src.replace("range(len(in_bits)/n_cbps)", "range(len(in_bits)//n_cbps)")
    mod = types.ModuleType("openofdm_decode"); mod.__file__ = os.path.join(SCRIPTS, "decode.py")
    exec(compile(src, mod.__file__, "exec"), mod.__dict__)
    return mod


def decode_one(dec_mod, iq_txt, mpdu, ht, rate, sgi):
    """Run decode.py's Decoder.decode() from the first sample of the burst. (decode.py's
    own find_pkt() takes the two largest LTF correlation values and requires them 64 apart;
    on clean captures a sidelobe of the first peak wins and decode_next() never returns.
    Packet detection is not what this check is about, so the burst start is used.)"""
    import numpy as np
    d = np.loadtxt(iq_txt, ndmin=2)
    nz = np.nonzero(np.abs(d[:, 0]) + np.abs(d[:, 1]))[0]
    if not len(nz):
        return False, "empty capture", ""
    samples = [complex(a, b) for a, b in d[nz[0]:]]
    log = io.StringIO()
    try:
        with contextlib.redirect_stdout(log):
            res = dec_mod.Decoder(None).decode(samples)
    except Exception as e:                           # decode.py asserts/raises on garbage
        return False, f"decoder error: {type(e).__name__} {e}".strip(), log.getvalue()
    if not res or len(res) < 7:
        return False, "no frame decoded (SIG check failed)", log.getvalue()
    signal, data = res[0], res[6]
    psdu = bytes(mpdu) + zlib.crc32(bytes(mpdu)).to_bytes(4, "little")
    if bool(signal.ht) != bool(ht):
        why = "decoded as legacy: HT-SIG CRC failed" if ht else "decoded as HT"
        return False, why, log.getvalue()
    if ht and (signal.mcs != rate or (signal.short_gi == "1") != bool(sgi)):
        return False, f"HT-SIG mcs={signal.mcs} sgi={signal.short_gi}", log.getvalue()
    if not ht and signal.rate != rate:
        return False, f"L-SIG rate {signal.rate} != {rate}", log.getvalue()
    if signal.length != len(psdu):
        return False, f"length {signal.length} != {len(psdu)}", log.getvalue()
    got = bytes(data)
    if got != psdu:
        k = next((i for i in range(min(len(got), len(psdu))) if got[i] != psdu[i]), min(len(got), len(psdu)))
        return False, f"PSDU differs from byte {k} ({len(got)} bytes decoded)", log.getvalue()
    return True, "PSDU + FCS ok", log.getvalue()


_DEC = None
def _init():
    global _DEC
    _DEC = load_decoder()
def _run(job):
    n, iq, mpdu, ht, rate, sgi = job
    return decode_one(_DEC, iq, mpdu, ht, rate, sgi)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir", nargs="?")
    ap.add_argument("--iq"); ap.add_argument("--mpdu")
    ap.add_argument("--ht", type=int, default=0); ap.add_argument("--rate", type=int, default=6)
    ap.add_argument("--sgi", type=int, default=0); ap.add_argument("-v", action="store_true")
    ap.add_argument("-j", type=int, default=os.cpu_count(), help="parallel decodes")
    a = ap.parse_args()
    jobs = []
    if a.iq:
        jobs.append(("cli", a.iq, bytes.fromhex(a.mpdu), a.ht, a.rate, a.sgi))
    else:
        for fj in sorted(glob.glob(os.path.join(a.dir, "frame_*.json"))):
            j = json.load(open(fj)); n = fj[-9:-5]
            jobs.append((n, os.path.join(a.dir, f"rtl_{n}.txt"), bytes.fromhex(j["mpdu_hex"]),
                         j["ht"], j["rate"], j.get("sgi", 0)))
    bad = 0
    from concurrent.futures import ProcessPoolExecutor
    with ProcessPoolExecutor(max_workers=a.j, initializer=_init) as ex:
        results = list(ex.map(_run, jobs))
    for (n, iq, mpdu, ht, rate, sgi), (ok, why, log) in zip(jobs, results):
        tag = f"{'HT-MCS%d' % rate if ht else '%dM' % rate}{'-SGI' if sgi else ''} len={len(mpdu)}"
        print(f"[{n}] {'PASS' if ok else 'FAIL'} {tag}: {why}")
        if a.v and not ok:
            print("    " + "\n    ".join(log.strip().splitlines()[:8]))
        bad += not ok
    print(f"{len(jobs) - bad}/{len(jobs)} frames decoded correctly by openofdm decode.py")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
