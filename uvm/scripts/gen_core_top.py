#!/usr/bin/env python3
"""
gen_core_top.py - build the chip-level DUT wrapper for UVM from the Vivado block design.

Reads   <openwifi-hw>/boards/<board>/src/system.bd   (JSON)
and the port lists of the six openwifi user IPs, then emits
    openwifi_core_top.sv

openwifi_core_top = the 'openwifi_ip' BD hierarchy with the Xilinx infrastructure
(axi_dma x2, axi_interconnect x3, proc_sys_reset) removed:
  * the PS AXI-lite path is replaced by one AXI-lite slave port + axil_decoder
    (same address map as the BD: base + 0x1_0000 * slot)
  * each DMA AXI-Stream is exported as a top-level AXIS port, so UVM AXIS agents
    stand in for the DMA engines
  * xlslice / xlconcat / xlconstant glue is rebuilt as continuous assigns
  * IP inputs that the BD leaves unconnected are tied to 0 (listed in a comment)

Usage:
    gen_core_top.py --hw <path/to/openwifi-hw> [--board zcu102_fmcs2] [-o openwifi_core_top.sv]
Re-run whenever system.bd changes; the wrapper is a pure function of the BD.
"""
import argparse, json, os, re, sys

IP_FILES = {
    "rx_intf":     "ip/rx_intf/src/rx_intf.v",
    "tx_intf":     "ip/tx_intf/src/tx_intf.v",
    "xpu":         "ip/xpu/src/xpu.v",
    "openofdm_tx": "ip/openofdm_tx/src/openofdm_tx.v",
    "openofdm_rx": "ip/openofdm_rx/verilog/openofdm_rx.v",
    "side_ch":     "ip/side_ch/src/side_ch.v",
}
# BD instance -> module
INST = {f"{m}_0": m for m in IP_FILES}
# AXI-lite slot in the BD address map (offset = slot * 0x1_0000 from 0xA000_0000)
AXIL_SLOT = {"openofdm_rx_0": 2, "openofdm_tx_0": 3, "rx_intf_0": 4,
             "side_ch_0": 5, "tx_intf_0": 6, "xpu_0": 7}
# DMA AXI-Stream endpoints -> exported top-level port prefix
AXIS_EXPORT = {
    ("tx_intf_0", "s00_axis"): "s_axis_tx",       # axi_dma_0 MM2S -> tx_intf
    ("rx_intf_0", "m00_axis"): "m_axis_rx",       # rx_intf -> axi_dma_1 S2MM
    ("side_ch_0", "m00_axis"): "m_axis_sidech",   # side_ch -> axi_dma_0 S2MM
    ("side_ch_0", "s00_axis"): "s_axis_sidech",   # axi_dma_1 MM2S -> side_ch
}
INFRA = ("axi_dma_", "axi_interconnect_", "sys_rstgen")
GLUE = ("xlslice_", "xlconcat_", "xlconstant_")


def strip_comments(t):
    t = re.sub(r"/\*.*?\*/", "", t, flags=re.S)
    return re.sub(r"//[^\n]*", "", t)


def parse_module(path):
    txt = strip_comments(open(path).read())
    m = re.search(r"\bmodule\s+(\w+)\s*#\s*\((.*?)\)\s*\((.*?)\)\s*;", txt, re.S)
    if not m:
        sys.exit(f"cannot parse module header in {path}")
    params = {}
    ptxt = re.sub(r"`(ifdef|ifndef|else|endif)[^\n]*", "", m.group(2))
    for pm in re.finditer(r"parameter\s+(?:integer\s+)?(\w+)\s*=\s*([^,\n]+)", ptxt):
        params.setdefault(pm.group(1), pm.group(2).strip())
    ports = {}
    body = re.sub(r"`\w+", "", m.group(3))  # drop `DEBUG_PREFIX etc.
    for decl in body.split(","):
        d = decl.strip()
        pm = re.match(r"(input|output|inout)\s+(?:wire|reg)?\s*(signed)?\s*(\[[^\]]+\])?\s*(\w+)$", d, re.S)
        if not pm:
            if d:
                print(f"WARN {path}: skipped port decl '{d[:60]}'", file=sys.stderr)
            continue
        ports[pm.group(4)] = dict(dir=pm.group(1), signed=bool(pm.group(2)),
                                  width=eval_width(pm.group(3), params))
    return ports


def eval_width(rng, params):
    if not rng:
        return 1
    hi, lo = rng[1:-1].split(":")
    def ev(e):
        for _ in range(4):
            for k, v in params.items():
                e = re.sub(rf"\b{k}\b", f"({v})", e)
        return int(eval(e.replace("/", "//"), {}))
    return ev(hi) - ev(lo) + 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hw", required=True)
    ap.add_argument("--board", default="zcu102_fmcs2")
    ap.add_argument("-o", "--out", default="openwifi_core_top.sv")
    a = ap.parse_args()

    bd = json.load(open(os.path.join(a.hw, "boards", a.board, "src", "system.bd")))
    ow = bd["design"]["components"]["openwifi_ip"]
    mods = {m: parse_module(os.path.join(a.hw, f)) for m, f in IP_FILES.items()}

    def pinfo(ep):
        cell, pin = ep.split("/")
        return mods[INST[cell]][pin] if cell in INST else None

    used = {inst: set() for inst in INST}          # pins already connected
    conn = {inst: {} for inst in INST}             # inst -> pin -> expression
    decls, assigns, top_ports = [], [], []
    glue_out = {}                                  # 'xlslice_0/Dout' -> net name

    # ---- glue cells (expressions are filled in after nets are known)
    glue_in = {}                                   # 'xlslice_0/Din' -> net name

    hier_ports = ow.get("ports", {})
    keep_hier = {"adc_clk", "adc_data", "adc_rst", "adc_valid", "dac_data", "dac_ready",
                 "dac_valid", "gpio_status", "ps_clk", "spi0_csn", "spi0_mosi", "spi0_sclk",
                 "spi_csn", "spi_mosi", "spi_sclk", "rx_pkt_intr", "tx_itrpt",
                 "led0", "led1", "led2", "led3", "led4", "led5",
                 "gpio_pmod1_0", "gpio_pmod1_1", "gpio_pmod1_2"}

    # hierarchy pins of openwifi_ip that the system-level BD connects to something
    sys_driven = set()
    for kind in ("nets", "interface_nets"):
        for net in bd["design"].get(kind, {}).values():
            for e in net.get("ports", []) + net.get("interface_ports", []):
                if e.startswith("openwifi_ip/"):
                    sys_driven.add(e.split("/", 1)[1])
    keep_extra = set()

    for _, net in ow["nets"].items():
        eps = net["ports"]
        # clock / reset nets of the AXI domain
        if "m_axi_mm2s_aclk" in eps:
            name, w = "clk", 1
        elif any(e == "sys_rstgen1/peripheral_aresetn" for e in eps):
            name, w = "aresetn", 1
        elif "ext_reset_in" in eps:
            continue
        else:
            name, w = None, None
            # driver = IP output, glue output, or hierarchy input
            for e in eps:
                if "/" in e:
                    c, p = e.split("/")
                    pi = pinfo(e)
                    if pi and pi["dir"] == "output":
                        name, w = f"{c[:-2]}_{p}", pi["width"]; break
                    if c.startswith(GLUE) and p in ("Dout", "dout"):
                        name = f"{c}_dout"; break
                    if c.startswith("axi_dma_1") and p == "s2mm_introut":
                        name, w = "dma1_s2mm_intr", 1; break
                elif hier_ports.get(e, {}).get("direction") == "I":
                    name = e; break
            if name is None:
                print(f"WARN no driver for net {eps}", file=sys.stderr); continue
            if name in hier_ports and name not in keep_hier:
                if name not in sys_driven:
                    # hierarchy input left open in the system BD: the IP pins it feeds
                    # stay unconnected and are tied to 0 below (listed in the NOTE)
                    print(f"INFO hierarchy input {name} unconnected in system.bd, tied to 0", file=sys.stderr)
                    continue
                keep_extra.add(name)
        # width for glue-driven nets resolved from any IP sink
        if w is None:
            for e in eps:
                pi = pinfo(e) if "/" in e else None
                if pi:
                    w = pi["width"]; break
            if w is None and name in hier_ports:
                hp = hier_ports[name]; w = int(hp.get("left", 0)) + 1
            if w is None:
                w = 1
        is_top = False
        for e in eps:
            if "/" not in e:
                if e in keep_hier or e in keep_extra:
                    d = "input" if hier_ports[e]["direction"] == "I" else "output"
                    top_ports.append((d, w, e))
                    if e != name:
                        assigns.append(f"assign {e} = {name};")
                    is_top = is_top or e == name
                continue
            c, p = e.split("/")
            if c in INST:
                conn[c][p] = name; used[c].add(p)
            elif c.startswith(GLUE):
                glue_in[e] = name
            elif c == "axi_dma_1" and p == "s2mm_introut":
                top_ports.append(("input", 1, "dma1_s2mm_intr")); is_top = True
        if name in ("clk", "aresetn"):
            top_ports.append(("input", 1, name)); is_top = True
        if not is_top:
            decls.append(f"wire [{w-1}:0] {name};" if w > 1 else f"wire {name};")

    # ---- glue logic (from BD parameters)
    def gi(c, p):
        return glue_in.get(f"{c}/{p}", "1'b0")
    comps = ow["components"]
    for c, v in sorted(comps.items()):
        if not c.startswith(GLUE):
            continue
        prm = {k: x.get("value") for k, x in v.get("parameters", {}).items()}
        if c.startswith("xlslice_"):
            assigns.append(f"assign {c}_dout = {gi(c,'Din')}[{prm['DIN_FROM']}:{prm['DIN_TO']}];")
        elif c.startswith("xlconcat_"):
            assigns.append(f"assign {c}_dout = {{{gi(c,'In1')}, {gi(c,'In0')}}};")
        elif c.startswith("xlconstant_"):
            assigns.append(f"assign {c}_dout = {prm.get('CONST_VAL','1')};")

    # ---- AXI-lite and AXIS interface hookup
    axil_sig = ["awaddr", "awprot", "awvalid", "awready", "wdata", "wstrb", "wvalid", "wready",
                "bresp", "bvalid", "bready", "araddr", "arprot", "arvalid", "arready",
                "rdata", "rresp", "rvalid", "rready"]
    for inst, slot in AXIL_SLOT.items():
        for s in axil_sig:
            conn[inst][f"s00_axi_{s}"] = f"axil_{inst[:-2]}.{s}"
            used[inst].add(f"s00_axi_{s}")
    for (inst, prefix), port in AXIS_EXPORT.items():
        for p, pi in mods[INST[inst]].items():
            if p.startswith(prefix + "_t"):
                sig = p[len(prefix) + 1:]
                conn[inst][p] = f"{port}_{sig}"; used[inst].add(p)
                top_ports.append(("input" if pi["dir"] == "input" else "output", pi["width"], f"{port}_{sig}"))

    # ---- emit
    L = []
    L.append("// AUTO-GENERATED by scripts/gen_core_top.py from boards/%s/src/system.bd -- do not edit" % a.board)
    L.append("// openwifi_core_top: openwifi_ip hierarchy minus axi_dma/axi_interconnect/proc_sys_reset.")
    L.append("`timescale 1ns/1ps")
    L.append("module openwifi_core_top (")
    seen = set(); pl = []
    for d, w, n in top_ports:
        if n in seen:
            continue
        seen.add(n)
        pl.append(f"  {d:6} wire {'['+str(w-1)+':0] ' if w > 1 else ''}{n}")
    pl += ["  // single AXI-lite slave, BD address map (bits [18:16] select the IP)",
           "  input  wire [31:0] s_axil_awaddr", "  input  wire [2:0]  s_axil_awprot",
           "  input  wire        s_axil_awvalid", "  output wire        s_axil_awready",
           "  input  wire [31:0] s_axil_wdata", "  input  wire [3:0]  s_axil_wstrb",
           "  input  wire        s_axil_wvalid", "  output wire        s_axil_wready",
           "  output wire [1:0]  s_axil_bresp", "  output wire        s_axil_bvalid",
           "  input  wire        s_axil_bready", "  input  wire [31:0] s_axil_araddr",
           "  input  wire [2:0]  s_axil_arprot", "  input  wire        s_axil_arvalid",
           "  output wire        s_axil_arready", "  output wire [31:0] s_axil_rdata",
           "  output wire [1:0]  s_axil_rresp", "  output wire        s_axil_rvalid",
           "  input  wire        s_axil_rready"]
    L.append(",\n".join(pl))
    L.append(");")
    L += ["", "  // ---------------- nets ----------------"] + ["  " + d for d in decls]
    L += ["", "  // ---------------- AXI-lite fabric ----------------"]
    for inst in AXIL_SLOT:
        L.append(f"  axil_bus_if axil_{inst[:-2]} ();")
    L.append("  axil_decoder u_axil_decoder (")
    L.append("    .clk(clk), .aresetn(aresetn),")
    for s in axil_sig:
        L.append(f"    .s_{s}(s_axil_{s}),")
    L.append("    .m_openofdm_rx(axil_openofdm_rx), .m_openofdm_tx(axil_openofdm_tx), .m_rx_intf(axil_rx_intf),")
    L.append("    .m_side_ch(axil_side_ch), .m_tx_intf(axil_tx_intf), .m_xpu(axil_xpu));")
    L += ["", "  // ---------------- glue (xlslice/xlconcat/xlconstant) ----------------"]
    L += ["  " + x for x in assigns]
    for inst, mod in INST.items():
        ports = mods[mod]
        tied = [p for p, pi in ports.items() if pi["dir"] == "input" and p not in used[inst]]
        L += ["", f"  // ---------------- {inst} ----------------"]
        if tied:
            L.append(f"  // NOTE: inputs unconnected in system.bd, tied to 0: {', '.join(tied)}")
        L.append(f"  {mod} {inst} (")
        pc = []
        for p, pi in ports.items():
            if p in conn[inst]:
                pc.append(f"    .{p}({conn[inst][p]})")
            elif pi["dir"] == "input":
                pc.append(f"    .{p}({pi['width']}'d0)")
            else:
                pc.append(f"    .{p}()")
        L.append(",\n".join(pc))
        L.append("  );")
    L.append("endmodule")
    open(a.out, "w").write("\n".join(L) + "\n")
    print(f"wrote {a.out}")


if __name__ == "__main__":
    main()
