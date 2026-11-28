#!/usr/bin/env python3
"""
prep_rtl.py - collect openwifi-hw RTL into a simulator-agnostic build tree.

Why: Vivado packages each user IP separately, so module names may collide between
IPs without harm on the FPGA.  In one simulation they do collide, and some
collisions are NOT identical code (e.g. mv_avg.v in rx_intf differs from the one
in xpu/openofdm_rx).  This script copies each IP into build/rtl/<ip>/ and renames
every module that is defined by more than one IP to <ip>__<module>, rewriting the
instantiations inside that IP.  Identical and non-identical duplicates are handled
the same way so the rule stays simple.

It also writes build/rtl/<ip>.f filelists and build/rtl/all.f.

Usage: prep_rtl.py --hw <openwifi-hw> [--out build/rtl]
"""
import argparse, collections, os, re, shutil


def fwd(p):
    """absolute path with forward slashes: valid in .f files for every simulator, Windows included"""
    return os.path.abspath(p).replace(os.sep, "/")

IPS = {
    "openofdm_rx": "ip/openofdm_rx/verilog",
    "openofdm_tx": "ip/openofdm_tx/src",
    "rx_intf":     "ip/rx_intf/src",
    "tx_intf":     "ip/tx_intf/src",
    "xpu":         "ip/xpu/src",
    "side_ch":     "ip/side_ch/src",
}
# Edits to the simulation copy of RTL that lives in a submodule (fixed here, not upstream yet).
# Each must match exactly once, so an upstream change shows up as a prep error.
SIM_PATCHES = {
    # 1) 4-bit register field on signal_watchdog's 16-bit port: Vivado synthesis zero-extends, xsim
    #    leaves the upper 12 bits Z (same class as the tx_intf fix a5369c9)
    # 2) uvm finding K (RTL fix, upstream patch in uvm/patches/): the length checks (event3/event4)
    #    see sig_valid only after state has left S_DECODE_SIGNAL, where the watchdog is disabled
    ("openofdm_rx", "openofdm_rx.v"): [
        (".min_signal_len_th(slv_reg4[15:12]),", ".min_signal_len_th({12'd0, slv_reg4[15:12]}),"),
        ("assign signal_watchdog_enable = ((state <= S_DECODE_SIGNAL) & (~slv_reg1[13]));",
         "assign signal_watchdog_enable = (((state <= S_DECODE_SIGNAL) | sig_valid) & (~slv_reg1[13]));")],
    # div_gen_csi_over_nova's AXI-Stream ports are byte-padded (divisor 32, dividend 40, dout 40 bits);
    # synthesis zero-extends/drops the padding, xsim rejects the width mismatch at a VHDL port
    ("openofdm_rx", "ofdm_decoder.v"): [
        ("wire [35:0] csi_square_over_noise_var_full;",
         "wire [35:0] csi_square_over_noise_var_full; wire [3:0] csi_square_over_noise_var_pad;"),
        (".s_axis_divisor_tdata(noise_var_new),", ".s_axis_divisor_tdata({7'd0, noise_var_new}),"),
        (".s_axis_dividend_tdata(csi_square_scaled),", ".s_axis_dividend_tdata({6'd0, csi_square_scaled}),"),
        (".m_axis_dout_tdata(csi_square_over_noise_var_full)",
         ".m_axis_dout_tdata({csi_square_over_noise_var_pad, csi_square_over_noise_var_full})")],
}
# testbenches / unused models that live next to the RTL
EXCLUDE = re.compile(r"(_tb\.v$|^rand_gen_tb\.v$)")
MOD_RE = re.compile(r"^\s*module\s+(\w+)", re.M)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hw", required=True)
    ap.add_argument("--out", default="build/rtl")
    a = ap.parse_args()

    files, copy_all = {}, {}
    owners = collections.defaultdict(set)
    for ip, d in IPS.items():
        src = os.path.join(a.hw, d)
        fl = sorted(f for f in os.listdir(src) if f.endswith(".v") and not EXCLUDE.search(f))
        files[ip] = []
        for f in fl:
            mods = MOD_RE.findall(open(os.path.join(src, f), errors="ignore").read())
            if mods:                      # files without a module are `include-only
                files[ip].append(f)
            for m in mods:
                owners[m].add(ip)
        copy_all[ip] = fl
    shared = {m for m, s in owners.items() if len(s) > 1}

    os.makedirs(a.out, exist_ok=True)
    allf = []
    for ip, d in IPS.items():
        src = os.path.join(a.hw, d)
        dst = os.path.join(a.out, ip)
        shutil.rmtree(dst, ignore_errors=True)
        os.makedirs(dst)
        for f in copy_all[ip]:
            t = open(os.path.join(src, f), errors="ignore").read()
            for m in shared:
                # definition and instantiation:  module m  /  m #(  /  m inst (
                t = re.sub(rf"(\bmodule\s+){m}\b", rf"\g<1>{ip}__{m}", t)
                t = re.sub(rf"^(\s*){m}(\s*(#|\w+\s*\())", rf"\g<1>{ip}__{m}\2", t, flags=re.M)
            for old, new in SIM_PATCHES.get((ip, f), []):
                if t.count(old) != 1:
                    raise SystemExit(f"prep_rtl.py: sim patch for {ip}/{f} no longer matches: {old}")
                t = t.replace(old, new)
            if f in files[ip]:
                # RTL is Verilog-2005 (uses 'bit' as a port name etc.); keep SV keywords
                # out of it even when the simulator compiles everything in SV mode.
                t = '`begin_keywords "1364-2005"\n' + t + '\n`end_keywords\n'
            open(os.path.join(dst, f), "w", newline="\n").write(t)
        # board_def.v sits in ip/ and is copied into each IP by boards/ip_repo_gen.tcl
        shutil.copy(os.path.join(a.hw, "ip", "board_def.v"), dst)
        # copy LUT init files ($readmemh targets etc.)
        for f in os.listdir(src):
            if f.endswith((".mif", ".coe", ".mem", ".hex")):
                shutil.copy(os.path.join(src, f), dst)
        fl = os.path.join(a.out, f"{ip}.f")
        with open(fl, "w", newline="\n") as fh:
            fh.write(f"+incdir+{fwd(dst)}\n")
            # `define-only include files first (some RTL relies on compile order for them)
            for f in copy_all[ip]:
                if f not in files[ip]:
                    body = open(os.path.join(src, f), errors="ignore").read()
                    if "`define" in body and "localparam" not in body:
                        fh.write(fwd(os.path.join(dst, f)) + "\n")
            for f in files[ip]:
                fh.write(fwd(os.path.join(dst, f)) + "\n")
        allf.append(f"-f {fwd(fl)}")
    open(os.path.join(a.out, "all.f"), "w", newline="\n").write("\n".join(allf) + "\n")
    print("renamed shared modules:", ", ".join(sorted(shared)) or "none")


if __name__ == "__main__":
    main()
