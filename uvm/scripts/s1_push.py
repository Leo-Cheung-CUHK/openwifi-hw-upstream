#!/usr/bin/env python3
"""S1 push runs (.github/workflows/s1.yml): run each line of an args file as `xsim.py <line>`.
Lines are split like a shell (shlex): quote --plusargs "+A +B". '#' starts a comment line.
Exit status: the last non-zero xsim.py status, else 0."""
import shlex, subprocess, sys, os
HERE = os.path.dirname(os.path.abspath(__file__))
XSIM = os.path.join(HERE, "..", "sim", "xsim.py")
rc = 0
for line in open(sys.argv[1], encoding="utf-8"):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    args = shlex.split(line)
    print("== xsim.py " + " ".join(args), flush=True)
    r = subprocess.call([sys.executable, XSIM] + args)
    rc = r or rc
sys.exit(rc)
