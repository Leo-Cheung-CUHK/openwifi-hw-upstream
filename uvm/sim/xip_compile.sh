#!/usr/bin/env bash
# xip_compile.sh <xsim|questa|vcs> <xip_sources.txt>
# Compiles the Xilinx IP simulation sources listed by scripts/gen_xilinx_ip_sim.tcl
# ("<library> <verilog|systemverilog|vhdl> <file>", compile order) into per-IP libraries
# in the current directory. Encrypted IP (IEEE-1735) is supported by these simulators.
# For Questa/VCS the Xilinx unisim/xpm/secureip libraries must be precompiled with
# compile_simlib and mapped (modelsim.ini / synopsys_sim.setup) beforehand.
set -euo pipefail
sim=$1; list=$2
while read -r lib lang file; do
  [ -z "${lib:-}" ] && continue
  case "$sim:$lang" in
    xsim:vhdl)            xvhdl --work "$lib" "$file" ;;
    xsim:*)               xvlog --work "$lib" -sv "$file" ;;
    questa:vhdl)          vlib "$lib" 2>/dev/null || true; vcom -work "$lib" "$file" ;;
    questa:*)             vlib "$lib" 2>/dev/null || true; vlog -work "$lib" -sv "$file" ;;
    vcs:vhdl)             vhdlan -work "$lib" "$file" ;;
    vcs:*)                vlogan -full64 -sverilog -work "$lib" "$file" ;;
    *) echo "xip_compile.sh: unsupported simulator $sim" >&2; exit 1 ;;
  esac
done < "$list"
