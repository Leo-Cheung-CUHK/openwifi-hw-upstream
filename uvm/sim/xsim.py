#!/usr/bin/env python3
"""
xsim.py - Vivado xsim flow for the openwifi-hw UVM environment, Windows and Linux.

Same flow as `make ... SIM=xsim` (sim/Makefile), without bash, GNU make, sed or symlinks, so it
runs with the native Windows Vivado. The per-TB description (TOP_*, IPS_*, XIP_*, SRC_*,
TESTS_*) and the defaults (BOARD, PART, NUM_CLK_PER_US) are read from sim/Makefile, which stays
the single source of truth.

  python uvm/sim/xsim.py env                          tools, paths, pitfalls
  python uvm/sim/xsim.py list                         TBs and their tests
  python uvm/sim/xsim.py prep                         wrapper from system.bd + build/rtl tree
  python uvm/sim/xsim.py xip                          Xilinx IP models for openofdm_rx (Viterbi licence)
  python uvm/sim/xsim.py run --tb openofdm_tx --test otx_rate_sweep_test [--seed 1] [--plusargs "+N_PKT=50"]
  python uvm/sim/xsim.py regress [--tb xpu --tb side_ch]
  python uvm/sim/xsim.py rxlists                      vector lists for orx_vectors_test

Global options: --vivado <Vivado/2022.2 dir> (default: $XILINX_VIVADO, else vivado on PATH),
--hw <openwifi-hw checkout> (default: two levels up), --build (default: $OW_BUILD, else uvm/build),
--board, --part, --dry-run.

Vivado's xvlog/xelab/xsim are .bat files on Windows: every argument goes through a -f options
file, which avoids cmd.exe's 8191-character limit and its handling of '=' and '+'.
Each TB compiles once into build/xsim/<tb>/ and is reused while its sources are unchanged;
logs of every run go to build/xsim/run/<tb>_<test>_<seed>/.
"""
import argparse, concurrent.futures, glob, os, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
OW_UVM = os.path.dirname(HERE)
TBS = ["openofdm_tx", "openofdm_rx", "tx_intf", "rx_intf", "xpu", "side_ch", "chip"]


def fwd(p):
    return os.path.abspath(p).replace(os.sep, "/")


# ---------------------------------------------------------------- Makefile as the TB table
def read_makefile():
    txt = open(os.path.join(HERE, "Makefile"), encoding="utf-8").read().replace("\\\n", " ")
    var = {}
    for m in re.finditer(r"^(\w+)\s*(\?=|:=|=)\s*(.*)$", txt, re.M):
        var.setdefault(m.group(1), m.group(3).split("#")[0].strip())
    return var


def expand(s, var):
    s = s.replace("$(V)", fwd(os.path.join(OW_UVM, "verif"))).replace("$(OW_UVM)", fwd(OW_UVM))
    if "$(" in s:
        sys.exit(f"xsim.py: cannot expand {s!r} from sim/Makefile")
    return s.split()


def tb_table(var):
    t = {}
    for tb in TBS:
        try:
            t[tb] = dict(top=var[f"TOP_{tb}"], ips=var[f"IPS_{tb}"].split(), xip=var[f"XIP_{tb}"] == "1",
                         src=expand(var[f"SRC_{tb}"], var), tests=var[f"TESTS_{tb}"].split())
        except KeyError as e:
            sys.exit(f"xsim.py: sim/Makefile has no {e} for TB {tb}")
    return t


# ---------------------------------------------------------------- tools
class Tools:
    def __init__(self, a):
        self.dry = a.dry_run
        root = a.vivado or os.environ.get("XILINX_VIVADO")
        if not root:
            v = shutil.which("vivado")
            root = os.path.dirname(os.path.dirname(v)) if v else None
        self.root = root
        if root:   # what settings64.bat / settings64.sh do, as far as these tools need it
            os.environ["XILINX_VIVADO"] = root
            os.environ["PATH"] = os.path.join(root, "bin") + os.pathsep + os.environ.get("PATH", "")
        os.environ["PYTHONUTF8"] = "1"      # child scripts read/write UTF-8 on Windows too

    def need_root(self):
        if not self.root and not self.dry:
            sys.exit("xsim.py: Vivado not found: pass --vivado D:/Xilinx/Vivado/2022.2 or set XILINX_VIVADO")
        return self.root or "<XILINX_VIVADO>"

    def exe(self, name):
        p = shutil.which(name)          # honours PATHEXT on Windows -> finds xvlog.bat
        if not p and not self.dry:
            sys.exit(f"xsim.py: {name} not found on PATH (Vivado bin: {self.root})")
        return p or name

    def run(self, name, args, cwd, log=None, argfile=None):
        """run a Vivado tool with its arguments in an options file; returns True on success"""
        os.makedirs(cwd, exist_ok=True)
        cmd = [self.exe(name)]
        if argfile:
            with open(os.path.join(cwd, argfile), "w", newline="\n") as fh:
                for x in args:
                    fh.write((f'"{x}"' if " " in x else x) + "\n")
            cmd += ["-f", argfile]
        else:
            cmd += args
        print(f"[{os.path.basename(cwd)}] {' '.join([name] + (['-f', argfile] if argfile else args))}", flush=True)
        if self.dry:
            return True
        t0 = time.time()
        with subprocess.Popen(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                              text=True, errors="replace") as p:
            out = open(os.path.join(cwd, log), "w", newline="\n") if log else None
            err = False
            for line in p.stdout:
                sys.stdout.write(line)
                if out: out.write(line)
                if line.startswith(("ERROR:", "FATAL_ERROR:")): err = True
            if out: out.close()
        ok = p.returncode == 0 and not err
        print(f"[{os.path.basename(cwd)}] {name}: {'ok' if ok else 'FAILED'} ({time.time() - t0:.0f}s)", flush=True)
        return ok


def check_paths(*paths):
    """the usual reasons an otherwise correct flow fails on Windows"""
    msgs = []
    for p in paths:
        p = fwd(p)
        if " " in p:
            msgs.append(("ERROR", f"path has a space: {p} (Vivado IP generation and xsim break on it)"))
        if "+" in p:
            msgs.append(("WARN", f"path has '+': {p} (plusarg-style tools split on it; use e.g. D:/ow)"))
        if os.name == "nt" and len(p) > 60:
            msgs.append(("WARN", f"path is {len(p)} characters: generated IP paths can pass the Windows "
                                 "260-character limit; use a short root such as D:/ow (build: OW_BUILD=D:/owb)"))
    return msgs


# ---------------------------------------------------------------- .f files -> xvlog arguments
def read_f(path, ctx):
    """expand a filelist: +incdir+ -> -i, +define+ -> -d, -f recursion, ${OW_UVM}, // comments"""
    args = []
    for raw in open(path, encoding="utf-8"):
        line = raw.split("//")[0].strip() if not raw.lstrip().startswith("+") else raw.strip()
        if not line:
            continue
        line = line.replace("${OW_UVM}", fwd(OW_UVM))
        if line.startswith("-f "):
            args += read_f(line[3:].strip(), ctx)
        elif line.startswith("+incdir+"):
            args += [x for d in line[len("+incdir+"):].split("+") if d for x in ("-i", d)]
        elif line.startswith("+define+"):
            args += [x for d in line[len("+define+"):].split("+") if d for x in ("-d", d)]
        else:
            args.append(line)
    return args


def sources_of(args):
    return [x for i, x in enumerate(args) if x.endswith((".v", ".sv", ".vh", ".svh"))
            and not (i and args[i - 1] in ("-i", "-d"))]


# ---------------------------------------------------------------- commands
def cmd_env(a, var, tools):
    print(f"openwifi-hw : {a.hw}")
    print(f"uvm         : {fwd(OW_UVM)}")
    print(f"vivado      : {tools.root or 'NOT FOUND'}")
    for n in ("vivado", "xvlog", "xvhdl", "xelab", "xsim"):
        print(f"  {n:6s}: {shutil.which(n) or '-'}")
    print(f"python      : {sys.version.split()[0]} ({sys.executable})")
    print(f"board/part  : {a.board} / {a.part}, NUM_CLK_PER_US={var.get('NUM_CLK_PER_US')}")
    sub = os.path.join(a.hw, "ip", "openofdm_rx", "verilog")
    print(f"openofdm_rx : {'present' if os.path.isdir(sub) else 'MISSING: git submodule update --init ip/openofdm_rx'}")
    lic = os.environ.get("XILINXD_LICENSE_FILE") or os.environ.get("LM_LICENSE_FILE")
    print(f"licence env : {lic or '- (Vivado License Manager default location)'}")
    bad = False
    print(f"build       : {fwd(a.build)}")
    for lvl, m in check_paths(a.hw, a.build):
        print(f"{lvl}: {m}"); bad |= lvl == "ERROR"
    return 1 if bad else 0


def cmd_list(a, var, tools):
    for tb, d in tb_table(var).items():
        print(f"{tb:12s} top={d['top']:16s} xip={int(d['xip'])}  tests: {' '.join(d['tests'])}")
    return 0


def py(script, *args):
    cmd = [sys.executable, os.path.join(OW_UVM, "scripts", script), *args]
    print(" ".join(cmd), flush=True)
    return subprocess.call(cmd)


def cmd_prep(a, var, tools):
    if tools.dry:
        print("prep: gen_core_top.py, prep_rtl.py"); return 0
    return py("gen_core_top.py", "--hw", a.hw, "--board", a.board,
              "-o", os.path.join(OW_UVM, "rtl_wrap", "openwifi_core_top.sv")) or \
           py("prep_rtl.py", "--hw", a.hw, "--out", os.path.join(a.build, "rtl"))


def cmd_xip(a, var, tools):
    tools.need_root()
    out = os.path.join(a.build, "xip")
    os.makedirs(out, exist_ok=True)
    ok = tools.run("vivado", ["-mode", "batch", "-nojournal", "-nolog",
                              "-source", fwd(os.path.join(OW_UVM, "scripts", "gen_xilinx_ip_sim.tcl")),
                              "-tclargs", fwd(a.hw), fwd(out), a.part, "xsim"], cwd=out, log="xip.log")
    if ok and not tools.dry and not os.path.isfile(os.path.join(out, "xip_sources.txt")):
        print("xip: vivado finished but wrote no xip_sources.txt (licence? see build/xsim/../xip/xip.log)"); ok = False
    return 0 if ok else 1


def xip_groups(list_file):
    """consecutive (library, language) runs of xip_sources.txt, compile order kept"""
    groups = []
    for line in open(list_file, encoding="utf-8"):
        parts = line.strip().split(None, 2)
        if len(parts) != 3:
            continue
        lib, lang, f = parts
        lang = "vhdl" if lang == "vhdl" else "verilog"
        if groups and groups[-1][0] == lib and groups[-1][1] == lang:
            groups[-1][2].append(f)
        else:
            groups.append((lib, lang, [f]))
    return groups


def newest(paths):
    return max((os.path.getmtime(p) for p in paths if os.path.exists(p)), default=0)


def compile_tb(a, var, tools, tb, d):
    work = os.path.join(a.build, "xsim", tb)
    stamp = os.path.join(work, "compile.stamp")
    root = tools.need_root()
    rtl = os.path.join(a.build, "rtl")
    missing = [ip for ip in d["ips"] if not os.path.isfile(os.path.join(rtl, f"{ip}.f"))]
    if missing:
        if tools.dry:
            print(f"[{tb}] (dry run) build/rtl/{{{','.join(missing)}}}.f missing: run prep first")
        else:
            print(f"[{tb}] build/rtl not prepared ({', '.join(missing)}): running prep")
            if cmd_prep(a, var, tools): return False
    incs = ["-i", fwd(os.path.join(HERE, "gen_inc")), "-i", fwd(os.path.join(a.hw, "ip"))]
    defs = ["-d", f"NUM_CLK_PER_US={var.get('NUM_CLK_PER_US', '100')}"]
    common = read_f(os.path.join(OW_UVM, "verif", "common", "common.f"), None)
    rtl_args = [x for ip in d["ips"] if os.path.isfile(os.path.join(rtl, f"{ip}.f"))
                for x in read_f(os.path.join(rtl, f"{ip}.f"), None)]
    xpm = [f"{root}/data/ip/xpm/{n}/hdl/{n}.sv" for n in ("xpm_cdc", "xpm_fifo", "xpm_memory")]
    glbl = f"{root}/data/verilog/src/glbl.v"
    main = common + rtl_args + d["src"]
    xip_list = os.path.join(a.build, "xip", "xip_sources.txt")
    if d["xip"] and not os.path.isfile(xip_list) and not tools.dry:
        print(f"[{tb}] needs the Xilinx IP models: run `xsim.py xip` first (Vivado + Viterbi licence)")
        return False
    inputs = sources_of(main) + [os.path.join(rtl, f"{ip}.f") for ip in d["ips"]] + \
             ([xip_list] if d["xip"] else []) + [os.path.join(HERE, "Makefile")]
    if not tools.dry and os.path.isfile(stamp) and os.path.getmtime(stamp) >= newest(inputs):
        print(f"[{tb}] compiled model is up to date")
        return True
    if not tools.dry:
        bad = [f for f in sources_of(main) if not os.path.isfile(f)]
        if bad:
            print(f"[{tb}] missing sources:\n  " + "\n  ".join(bad)); return False
    shutil.rmtree(os.path.join(work, "xsim.dir"), ignore_errors=True)
    os.makedirs(work, exist_ok=True)
    libs = []
    if d["xip"]:
        for i, (lib, lang, files) in enumerate(xip_groups(xip_list) if os.path.isfile(xip_list) else []):
            tool = "xvhdl" if lang == "vhdl" else "xvlog"
            args = ["--work", lib] + ([] if lang == "vhdl" else ["-sv"]) + files
            if not tools.run(tool, args, work, log=f"xip_{i:03d}.log", argfile=f"xip_{i:03d}.args"): return False
            if lib not in libs: libs.append(lib)
    if not tools.run("xvlog", ["-sv", "-L", "uvm"] + incs + defs + xpm + [glbl], work, log="xvlog_xpm.log",
                     argfile="xvlog_xpm.args"): return False
    if not tools.run("xvlog", ["-sv", "-L", "uvm"] + incs + defs + main, work, log="xvlog.log",
                     argfile="xvlog.args"): return False
    lib_args = [x for l in libs for x in ("-L", l)]
    if not tools.run("xelab", ["-debug", "typical", "-L", "uvm", "-L", "xpm"] + lib_args +
                     ["-timescale", "1ns/1ps", f"work.{d['top']}", "work.glbl", "-s", f"{d['top']}_snap"],
                     work, log="xelab.log", argfile="xelab.args"): return False
    # $readmemh files are opened relative to the simulation directory (ifftmain.v)
    for m in glob.glob(os.path.join(a.hw, "ip", "openofdm_tx", "src", "icmem_*.mem")):
        shutil.copy(m, work)
    if not tools.dry:
        open(stamp, "w").write(time.ctime() + "\n")
    return True


def run_test(a, var, tools, tb, test, seed, plusargs, verb):
    t = tb_table(var)
    if tb not in t: sys.exit(f"xsim.py: unknown TB {tb} (one of {', '.join(TBS)})")
    d = t[tb]
    test = test or d["tests"][0]
    if not compile_tb(a, var, tools, tb, d):
        return "COMPILE-FAIL", None
    work = os.path.join(a.build, "xsim", tb)
    rdir = os.path.join(a.build, "xsim", "run", f"{tb}_{test}_{seed}")
    os.makedirs(rdir, exist_ok=True)
    log = os.path.join(rdir, "sim.log")
    pa = ["-testplusarg", f"UVM_TESTNAME={test}", "-testplusarg", f"UVM_VERBOSITY={verb}"]
    # per-test defaults from sim/Makefile ARGS_<test> (e.g. the vector list), then the caller's
    targs = var.get(f"ARGS_{test}", "").replace("$(BUILD)", fwd(a.build)).replace("$(OW_UVM)", fwd(OW_UVM))
    for p in targs.split() + list(plusargs):
        pa += ["-testplusarg", p.lstrip("+")]
    # waveform database per run dir, so tests of one TB can run in parallel (regress --jobs)
    ok = tools.run("xsim", [f"{d['top']}_snap", "-R", "-sv_seed", str(seed), "-log", fwd(log),
                            "-wdb", fwd(os.path.join(rdir, "sim.wdb"))] + pa,
                   work, argfile=f"xsim_{test}_{seed}.args")
    if tools.dry:
        return "DRY", log
    txt = open(log, encoding="utf-8", errors="replace").read() if os.path.isfile(log) else ""
    passed = ok and re.search(r"UVM_ERROR\s*:\s*0\b", txt) and re.search(r"UVM_FATAL\s*:\s*0\b", txt) \
        and not re.search(r"assertion.*fail|Error: Assertion", txt, re.I)
    return ("PASS" if passed else "FAIL"), log


def cmd_run(a, var, tools):
    st, log = run_test(a, var, tools, a.tb[0] if a.tb else "openofdm_tx", a.test, a.seed,
                       a.plusargs.split(), a.verb)
    print(f"{st} {a.tb[0] if a.tb else 'openofdm_tx'} {a.test or ''} log: {log}")
    return 0 if st in ("PASS", "DRY") else 1


def cmd_regress(a, var, tools):
    t = tb_table(var)
    rows, fail = [], 0
    def one(tb, test):
        t0 = time.time()
        st, log = run_test(a, var, tools, tb, test, a.seed, a.plusargs.split(), a.verb)
        return (tb, test, st, int(time.time() - t0), log)
    for tb in a.tb or TBS:
        tests = t[tb]["tests"]
        if a.jobs > 1:
            # compile once, then the tests side by side (each has its own run dir, log and wdb)
            if not compile_tb(a, var, tools, tb, t[tb]):
                rows.append((tb, tests[0], "COMPILE-FAIL", 0, None)); fail = 1; continue
            with concurrent.futures.ThreadPoolExecutor(a.jobs) as ex:
                res = list(ex.map(lambda x: one(tb, x), tests))
            rows += res
            fail |= any(r[2] not in ("PASS", "DRY") for r in res)
            continue
        for test in tests:
            r = one(tb, test)
            rows.append(r)
            fail |= r[2] not in ("PASS", "DRY")
            if r[2] == "COMPILE-FAIL":
                break                       # the other tests of this TB would fail the same way
    os.makedirs(os.path.join(a.build, "xsim"), exist_ok=True)
    md = ["| tb | test | result | time | log |", "|---|---|---|---|---|"] + \
         [f"| {r[0]} | {r[1]} | {r[2]} | {r[3]}s | {r[4] and fwd(r[4])} |" for r in rows]
    open(os.path.join(a.build, "xsim", "regress.md"), "w", newline="\n").write("\n".join(md) + "\n")
    print("\n".join(md))
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        open(os.environ["GITHUB_STEP_SUMMARY"], "a").write("### xsim regression\n" + "\n".join(md) + "\n")
    return fail


def cmd_rxlists(a, var, tools):
    lists = os.path.join(a.build, "lists"); os.makedirs(lists, exist_ok=True)
    ti = os.path.join(a.hw, "ip", "openofdm_rx", "testing_inputs")
    sim = sorted(f for f in glob.glob(os.path.join(ti, "simulated", "*.txt")) if "_Fc_input" not in f)
    con = sorted(glob.glob(os.path.join(ti, "conducted", "*.txt")))
    for n, fl in (("rx_simulated.list", sim), ("rx_conducted.list", con)):
        open(os.path.join(lists, n), "w", newline="\n").write("".join(fwd(f) + "\n" for f in fl))
    gen = os.path.join(a.build, "rxgen")
    if tools.dry:
        print("rxlists: gen_rx_vectors.py"); return 0
    for out, lst, args in (("rxgen", "rx_generated.list", ["-n", "50", "--snr", "30", "--cfo-hz", "20e3"]),
                           ("rxclean", "rx_clean.list", ["-n", "24", "--seed", "7", "--max-len", "400"]),
                           ("rxcraft", "rx_craft.list", ["--craft"])):       # same sets as `make rxlists`
        d = os.path.join(a.build, out)
        rc = py("gen_rx_vectors.py", "--out", d, *args)
        if rc:
            return rc
        shutil.copy(os.path.join(d, "list.txt"), os.path.join(lists, lst))
    return 0


def main():
    var = read_makefile()
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vivado", help="Vivado install dir, e.g. D:/Xilinx/Vivado/2022.2")
    ap.add_argument("--hw", default=os.path.dirname(OW_UVM), help="openwifi-hw checkout")
    ap.add_argument("--board", default=var.get("BOARD", "zc706_fmcs2"))
    ap.add_argument("--part", default=var.get("PART", "xc7z045ffg900-2"))
    ap.add_argument("--build", default=os.environ.get("OW_BUILD") or os.path.join(OW_UVM, "build"),
                    help="build tree (default $OW_BUILD, else uvm/build); keep it outside the checkout on a "
                         "CI runner so the Xilinx IP models survive actions/checkout's clean")
    ap.add_argument("--dry-run", action="store_true", help="print the tool calls, run nothing")
    sp = ap.add_subparsers(dest="cmd", required=True)
    for n in ("env", "list", "prep", "xip", "rxlists"):
        sp.add_parser(n)
    for n in ("run", "regress"):
        p = sp.add_parser(n)
        p.add_argument("--tb", action="append", help="TB name (repeat for regress)")
        p.add_argument("--test"); p.add_argument("--seed", type=int, default=1)
        p.add_argument("--verb", default="UVM_MEDIUM"); p.add_argument("--plusargs", default="")
        p.add_argument("--jobs", type=int, default=1, help="regress: tests of a TB run in parallel")
    a = ap.parse_args()
    a.hw = fwd(a.hw); a.build = os.path.abspath(a.build)
    tools = Tools(a)
    for lvl, m in check_paths(a.hw, a.build):
        if a.cmd != "env": print(f"{lvl}: {m}")
    return {"env": cmd_env, "list": cmd_list, "prep": cmd_prep, "xip": cmd_xip, "run": cmd_run,
            "regress": cmd_regress, "rxlists": cmd_rxlists}[a.cmd](a, var, tools)


if __name__ == "__main__":
    sys.exit(main())
