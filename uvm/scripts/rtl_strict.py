#!/usr/bin/env python3
"""
rtl_strict.py - elaborate the prepared RTL of every IP with slang WITHOUT the
use-before-declare allowance that slang_lint.py needs for UVM. Vivado synthesis accepts
signals used before their declaration; xvlog in SV mode (and other simulators) reject them,
which is how dot11_tx.v failed the first Windows xsim run. Also fails on a narrower expression
connected to a wider input port (PortWidthExpand): xsim leaves the extra port bits undriven (Z),
which made tx_intf's S_AXIS_TREADY X. S0 step `rtlstrict`.

  python3 uvm/scripts/rtl_strict.py [--rtl uvm/build/rtl]      (run `make prep` / `xsim.py prep` first)
"""
import argparse, os, sys
import pyslang

IPS = ["openofdm_tx", "openofdm_rx", "tx_intf", "rx_intf", "xpu", "side_ch"]
# (file, port) widenings that live in a submodule repo and are handled elsewhere
KNOWN_WIDEN = set()   # openofdm_rx min_signal_len_th is patched in the sim copy (prep_rtl.py SIM_PATCHES)
HERE = os.path.dirname(os.path.abspath(__file__))
OW_UVM = os.path.dirname(HERE)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--rtl", default=os.path.join(OW_UVM, "build", "rtl"))
    a = ap.parse_args()
    bad = 0
    for ip in IPS:
        fl = os.path.join(a.rtl, f"{ip}.f")
        if not os.path.isfile(fl):
            sys.exit(f"{fl} missing: run make prep first")
        files = [l.strip() for l in open(fl) if l.strip() and not l.startswith("+")]
        d = pyslang.driver.Driver(); d.addStandardArgs()
        cmd = (f"slang --ignore-unknown-modules -Wno-unused --timescale 1ns/1ps --single-unit "
               f"-I {os.path.join(a.rtl, ip)} -I {os.path.join(OW_UVM, 'sim', 'gen_inc')} "
               f"-I {os.path.join(OW_UVM, '..', 'ip')} " + " ".join(files))
        d.parseCommandLine(cmd, pyslang.driver.CommandLineOptions()); d.processOptions(); d.parseAllSources()
        comp = d.createCompilation(); sm = comp.sourceManager
        errs = set()
        for x in comp.getAllDiagnostics():
            f, ln, code = os.path.basename(sm.getFileName(x.location)), sm.getLineNumber(x.location), str(x.code)
            if x.isError():
                errs.add((f, ln, code))
            elif "PortWidthExpand" in code:
                line = open(sm.getFileName(x.location), errors="replace").read().split("\n")[ln - 1]
                port = line.strip().lstrip(".").split("(")[0]
                if (f, port) not in KNOWN_WIDEN:
                    errs.add((f, ln, code + " ." + port))
        errs = sorted(errs)
        print(f"{ip:12s} {'PASS' if not errs else 'FAIL'} ({len(files)} files)")
        for f, ln, code in errs:
            print(f"    {f}:{ln} {code.replace('DiagCode(', '').rstrip(')')}")
        bad += len(errs)
    print("RESULT", "PASS" if not bad else f"FAIL ({bad} errors)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
