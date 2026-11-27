#!/bin/bash
# Block TBs on Verilator with the behavioural XPM models (no Vivado needed).
# usage: scripts/run_block_vlt.sh <tb> [test ...]     (default: every test of the TB)
#   env: UVM_SRC (uvm-core/src), VERILATOR on PATH. Compiles one TB at a time (VLT_JOBS=1):
#   a UVM model needs ~2.5 GB per C++ job, so never run two of these in parallel on 7 GB.
# Prints one PASS/FAIL line per test; exit 1 if any failed. openofdm_rx and chip need the
# Xilinx IP models (xsim) and are not supported here.
set -u
here=$(cd "$(dirname "$0")/../sim" && pwd); cd "$here"
export SIM=verilator VLT_JOBS=${VLT_JOBS:-1}
tb=$1; shift
tests=${*:-$(make -s print-tests TB=$tb)}
make -s compile TB=$tb > /tmp/vlt_build_$tb.log 2>&1 || { grep %Error /tmp/vlt_build_$tb.log | head; echo "BUILD FAIL $tb"; exit 1; }
rc=0
for t in $tests; do
  make -s run TB=$tb TEST=$t > /dev/null 2>&1
  l=../build/run/${tb}_${t}_1/sim.log
  if grep -q "UVM_ERROR :    0" $l && grep -q "UVM_FATAL :    0" $l; then echo "PASS $tb $t"; else echo "FAIL $tb $t ($l)"; rc=1; fi
  grep -h "NOTE finding" $l | sed 's/^/     /'
done
exit $rc
