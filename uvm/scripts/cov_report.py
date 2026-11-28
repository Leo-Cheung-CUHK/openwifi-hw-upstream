#!/usr/bin/env python3
"""
cov_report.py - merge the functional coverage of many simulation runs and check FLOW.md §3 targets.

Every TB prints, at the end of a run, one line per coverage bin (ow_cov_pkg / interface covers):
    OWCOV <space> <bin> <hits>
This script reads those lines from sim logs (xsim or Verilator), merges them (a bin is covered when
any run hit it), and writes a markdown report.

  python3 uvm/scripts/cov_report.py [--out cov.md] LOG_OR_DIR ...
      a directory is searched for */sim.log (e.g. build/xsim/run)
Exit code 1 when a space with a target is below it.
"""
import argparse, collections, glob, os, re, sys

# space (regex) -> minimum % ; spaces not listed are reported without a gate
TARGETS = [
    (r"^wifi_frame$", 100.0),        # rate x length bin x GI
    (r"^ral_", 100.0),               # every register read, every writable one written
    (r"^xpu_", 95.0),                # CSMA states, filter rules, queue x need_ack
    (r"^sva$", 100.0),               # every cover property hit somewhere
]
LINE = re.compile(r"^OWCOV (\S+) (\S+) (\d+)\s*$")


def target_of(space):
    for pat, t in TARGETS:
        if re.search(pat, space):
            return t
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("--out", default=None)
    a = ap.parse_args()
    logs = []
    for p in a.inputs:
        logs += sorted(glob.glob(os.path.join(p, "*", "sim.log"))) if os.path.isdir(p) else [p]
    bins = collections.defaultdict(lambda: collections.defaultdict(int))   # space -> bin -> hits
    used = 0
    for f in logs:
        n = 0
        for line in open(f, errors="replace"):
            m = LINE.match(line.strip())
            if m:
                bins[m.group(1)][m.group(2)] += int(m.group(3)); n += 1
        used += n > 0
    rows, fail = [], 0
    for sp in sorted(bins):
        b = bins[sp]; hit = sum(1 for v in b.values() if v); pct = 100.0 * hit / len(b)
        t = target_of(sp)
        ok = t is None or pct >= t - 1e-9
        fail |= not ok
        miss = sorted(k for k, v in b.items() if not v)
        rows.append((sp, hit, len(b), pct, t, ok, miss))
    md = [f"# Functional coverage ({used} runs with coverage lines, {len(logs)} logs)", "",
          "| space | covered | % | target | |", "|---|---|---|---|---|"]
    for sp, hit, n, pct, t, ok, miss in rows:
        md.append(f"| {sp} | {hit}/{n} | {pct:.1f} | {'' if t is None else f'{t:.0f}'} | {'PASS' if ok else 'FAIL'} |")
    md.append("")
    for sp, hit, n, pct, t, ok, miss in rows:
        if miss:
            md.append(f"- **{sp}** missing ({len(miss)}): " + ", ".join(miss[:40]) + (" ..." if len(miss) > 40 else ""))
    text = "\n".join(md) + "\n"
    print(text)
    if a.out:
        open(a.out, "w", newline="\n").write(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        open(os.environ["GITHUB_STEP_SUMMARY"], "a").write(text)
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
