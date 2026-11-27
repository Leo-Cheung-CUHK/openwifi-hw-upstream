#!/usr/bin/env python3
# slang_lint.py <top> <slang args...> : parse + elaborate with slang (pip install pyslang).
# Unknown modules (xpm_*, Xilinx IP) are black-boxed, so this checks TB/RTL syntax, types,
# port names/widths of everything we own, without a simulator licence.
import sys, pyslang
args=sys.argv[1:]; top=args[0]
d=pyslang.driver.Driver(); d.addStandardArgs()
cmd="slang --top "+top+" --ignore-unknown-modules -Wno-unused -Wno-unconnected-output-port -Wno-redef-macro --timescale 1ns/1ps --allow-use-before-declare --single-unit --error-limit=500 "+" ".join(args[1:])
a=d.parseCommandLine(cmd, pyslang.driver.CommandLineOptions()); b=d.processOptions(); c=d.parseAllSources()
comp=d.createCompilation(); ok=d.reportCompilation(comp,False)
# diagEngine applies slang's severity mapping (e.g. -Wstring-int-concat is an error by
# default); the raw getAllDiagnostics() list does not, and missed such errors
n=d.diagEngine.numErrors
ok = bool(a and b and c) and n == 0   # reportCompilation() returns None in pyslang
print("RESULT", "PASS" if ok else f"FAIL ({n} errors)")
sys.exit(0 if ok else 1)
