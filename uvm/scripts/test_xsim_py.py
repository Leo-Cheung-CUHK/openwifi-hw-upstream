#!/usr/bin/env python3
"""
test_xsim_py.py - check sim/xsim.py without Vivado (S0 step `xsimpy`).

Builds a fake Vivado tree whose vivado/xvlog/xvhdl/xelab/xsim record their options files and
verify every file and include directory they are given, then runs xsim.py prep, xip, the full
regression (twice: the second time every TB must reuse its compiled model) and a recompile after
a source change. What it cannot check: the real tools' option syntax and .bat behaviour on
Windows; those are checked by the first run on the desktop runner (RUNNER.md §2).

  python3 uvm/scripts/test_xsim_py.py
"""
import json, os, shutil, stat, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
OW_UVM = os.path.dirname(HERE)
XSIM_PY = os.path.join(OW_UVM, "sim", "xsim.py")

FAKE = r'''#!/usr/bin/env python3
import json, os, sys
name = os.path.basename(sys.argv[0]); argv = sys.argv[1:]
if argv[:1] == ["-f"]:
    argv = [l.strip().strip('"') for l in open(argv[1]) if l.strip()]
calls = os.environ["FAKE_CALLS"]
with open(calls, "a") as fh:
    fh.write(json.dumps({"tool": name, "cwd": os.getcwd(), "args": argv}) + "\n")
def die(m):
    print("ERROR: [fake] " + m); sys.exit(1)
if name in ("xvlog", "xvhdl"):
    i = 0
    while i < len(argv):
        x = argv[i]
        if x in ("-i", "--work", "-L", "-d"):
            if x == "-i" and not os.path.isdir(argv[i + 1]): die("include dir missing: " + argv[i + 1])
            i += 2; continue
        if not x.startswith("-") and not os.path.isfile(x): die("source missing: " + x)
        if x.startswith("+"): die("plusarg-style option reached " + name + ": " + x)
        i += 1
    os.makedirs("xsim.dir/work", exist_ok=True)
elif name == "xelab":
    if "-s" not in argv: die("no snapshot")
    os.makedirs("xsim.dir/" + argv[argv.index("-s") + 1], exist_ok=True)
elif name == "xsim":
    snap = argv[0]
    if not os.path.isdir("xsim.dir/" + snap): die("snapshot not elaborated: " + snap)
    log = argv[argv.index("-log") + 1]
    tests = [a.split("=", 1)[1] for a in argv if a.startswith("UVM_TESTNAME=")]
    open(log, "w").write("UVM_INFO fake run of %s\n--- UVM Report Summary ---\nUVM_ERROR :    0\nUVM_FATAL :    0\n" % tests)
elif name == "vivado":
    targs = argv[argv.index("-tclargs") + 1:]
    hw, out, part, sim = targs[:4]
    if not os.path.isdir(hw + "/ip/openofdm_rx/verilog"): die("bad hw dir " + hw)
    os.makedirs(out + "/ip", exist_ok=True)
    fs = []
    for lib, lang, n in (("xbip_utils_v3_0_10", "vhdl", "a.vhd"), ("xbip_utils_v3_0_10", "vhdl", "b.vhd"),
                         ("viterbi_v9_1_15", "verilog", "c.v"), ("xil_defaultlib", "verilog", "d.v"),
                         ("xil_defaultlib", "verilog", "e.v")):
        p = out + "/ip/" + n; open(p, "w").write("// fake\n"); fs.append("%s %s %s" % (lib, lang, p))
    open(out + "/xip_sources.txt", "w").write("\n".join(fs) + "\n")
'''


def main():
    tmp = tempfile.mkdtemp(prefix="xsimpy_")
    root = os.path.join(tmp, "Vivado", "2022.2")
    os.makedirs(os.path.join(root, "bin"))
    for n in ("vivado", "xvlog", "xvhdl", "xelab", "xsim"):
        p = os.path.join(root, "bin", n)
        open(p, "w").write(FAKE); os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC)
    for n in ("xpm_cdc", "xpm_fifo", "xpm_memory"):
        d = os.path.join(root, "data", "ip", "xpm", n, "hdl"); os.makedirs(d)
        open(os.path.join(d, n + ".sv"), "w").write("// fake\n")
    os.makedirs(os.path.join(root, "data", "verilog", "src"))
    open(os.path.join(root, "data", "verilog", "src", "glbl.v"), "w").write("// fake\n")
    build = os.path.join(tmp, "build")
    calls = os.path.join(tmp, "calls.jsonl")
    env = dict(os.environ, FAKE_CALLS=calls, OW_XSIM_STAGGER="0")
    env.pop("XILINX_VIVADO", None)

    def xsim(*args):
        r = subprocess.run([sys.executable, XSIM_PY, "--vivado", root, "--build", build, *args],
                           env=env, capture_output=True, text=True)
        return r.returncode, r.stdout + r.stderr

    def log():
        return [json.loads(l) for l in open(calls)] if os.path.exists(calls) else []

    fails = []
    def check(cond, msg):
        print(("PASS " if cond else "FAIL ") + msg); cond or fails.append(msg)

    rc, out = xsim("list"); check(rc == 0 and out.count("top=") == 7, "list: 7 TBs from sim/Makefile")
    rc, out = xsim("prep"); check(rc == 0 and os.path.isfile(os.path.join(build, "rtl", "openofdm_tx.f")), "prep")
    rc, out = xsim("xip"); check(rc == 0 and os.path.isfile(os.path.join(build, "xip", "xip_sources.txt")), "xip")

    open(calls, "w").close()
    rc, out = xsim("regress")
    check(rc == 0, "regress: every TB compiles and passes with the fake tools" + ("" if rc == 0 else "\n" + out[-3000:]))
    L = log()
    elab = [c for c in L if c["tool"] == "xelab"]
    check(len(elab) == 7, f"regress: 7 elaborations, one per TB (got {len(elab)})")
    sims = [c for c in L if c["tool"] == "xsim"]
    n_tests = sum(len(l.split("tests:")[1].split()) for l in xsim("list")[1].splitlines() if "tests:" in l)
    check(len(sims) == n_tests, f"regress: {n_tests} test runs (got {len(sims)})")
    # Xilinx IP: grouped by (library, language) in order, only for the TBs that need it
    xip_calls = [c for c in L if c["tool"] in ("xvhdl",) or "--work" in c["args"]]
    tbs_with_xip = {os.path.basename(c["cwd"]) for c in xip_calls}
    check(tbs_with_xip == {"openofdm_rx", "chip"}, f"xip libraries compiled for openofdm_rx and chip only (got {sorted(tbs_with_xip)})")
    rx = [c for c in xip_calls if c["cwd"].endswith("openofdm_rx")]
    check([(c["tool"], c["args"][1]) for c in rx] == [("xvhdl", "xbip_utils_v3_0_10"), ("xvlog", "viterbi_v9_1_15"),
                                                       ("xvlog", "xil_defaultlib")], "xip: 3 compile groups in list order")
    e_rx = next(c for c in elab if c["cwd"].endswith("openofdm_rx"))["args"]
    check("xbip_utils_v3_0_10" in e_rx and "viterbi_v9_1_15" in e_rx, "xelab links the xip libraries")
    # main compile: UVM, defines, no plusarg-style options, test name passed to xsim
    main_tx = [c for c in L if c["tool"] == "xvlog" and c["cwd"].endswith("openofdm_tx") and "--work" not in c["args"]]
    a = main_tx[-1]["args"]
    check("-L" in a and "uvm" in a and "NUM_CLK_PER_US=100" in a, "xvlog: -L uvm and NUM_CLK_PER_US define")
    check(any(x.endswith("tb_openofdm_tx.sv") for x in a) and any(x.endswith("dot11_tx.v") for x in a),
          "xvlog: TB and prepared RTL sources")
    check(os.path.isfile(os.path.join(build, "xsim", "openofdm_tx", "icmem_ifft.mem")) or
          any(f.startswith("icmem_") for f in os.listdir(os.path.join(build, "xsim", "openofdm_tx"))),
          "ifft ROM .mem files copied next to the snapshot")
    s = next(c for c in sims if "UVM_TESTNAME=otx_rate_sweep_test" in c["args"])["args"]
    check(s[0] == "tb_openofdm_tx_snap" and "-testplusarg" in s and "-sv_seed" in s, "xsim: snapshot, seed, test plusargs")

    # same sources, same order as the Makefile xsim flow, for every TB
    rtl = os.path.join(build, "rtl")
    for tb in ("openofdm_tx", "openofdm_rx", "tx_intf", "rx_intf", "xpu", "side_ch", "chip"):
        mk = subprocess.run(["make", "-s", "-n", "-C", os.path.join(OW_UVM, "sim"), "compile", "SIM=xsim", f"TB={tb}",
                             f"XILINX_VIVADO={root}", f"BUILD={build}"], capture_output=True, text=True).stdout
        line = [l for l in mk.split("&&") if "xvlog" in l and "-L uvm" in l and "glbl" not in l][0].split()
        want = []
        for i, x in enumerate(line):
            if line[i - 1] == "-f":
                want += [l.strip() for l in open(x) if l.strip() and not l.startswith("+")]
            elif x.endswith((".sv", ".v")):
                want.append(x)
        got = [x for x in next(c for c in L if c["tool"] == "xvlog" and c["cwd"].endswith("/" + tb)
                               and "--work" not in c["args"] and not any(y.endswith("glbl.v") for y in c["args"]))["args"]
               if x.endswith((".sv", ".v"))]
        check(got == want, f"{tb}: xvlog sources == Makefile xsim flow ({len(got)} files)")

    # second regression: nothing recompiles
    open(calls, "w").close()
    rc, out = xsim("regress")
    check(rc == 0 and not [c for c in log() if c["tool"] != "xsim"], "second regress reuses all 7 compiled models")

    # parallel tests: same runs, one wdb per run dir
    open(calls, "w").close()
    rc, out = xsim("regress", "--jobs", "4")
    sims = [c for c in log() if c["tool"] == "xsim"]
    check(rc == 0 and len(sims) == n_tests and not [c for c in log() if c["tool"] != "xsim"],
          f"regress --jobs 4: {n_tests} runs, no recompile (got {len(sims)})")

    # touching one TB source recompiles that TB only
    src = os.path.join(OW_UVM, "verif", "block", "xpu", "tb_xpu.sv")
    st = os.stat(src); open(calls, "w").close()
    try:
        os.utime(src, (time.time() + 5, time.time() + 5))
        rc, out = xsim("run", "--tb", "xpu"); rc2, _ = xsim("run", "--tb", "side_ch")
        el = [os.path.basename(c["cwd"]) for c in log() if c["tool"] == "xelab"]
        check(rc == 0 and rc2 == 0 and el == ["xpu"], f"changed xpu source recompiles xpu only (got {el})")
    finally:
        os.utime(src, (st.st_atime, st.st_mtime))

    rc, out = xsim("--hw", "/tmp/AI+Openwifi", "env")
    check("'+'" in out, "env warns about '+' in the checkout path")
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"{'FAIL' if fails else 'PASS'}: test_xsim_py {len(fails)} failures")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
