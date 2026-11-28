#!/usr/bin/env bash
# Bit-exact regression of sova_dec vs uvm/scripts/sova_ref.py (Verilator >= 5, numpy).
# Usage: ip/sova_dec/tb/run_vlt.sh [frames=60] [seeds="11 12 13"]
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
B=${OW_BUILD:-/tmp/owb}/sova_dec; mkdir -p "$B"
FR=${1:-60}; SEEDS=${2:-"11 12 13"}
for m in 1 0; do
  verilator --binary --timing -j 0 -Wno-fatal -Wno-WIDTH -GBR=$m --top-module tb_sova_dec \
    -Mdir "$B/obj$m" -o sim "$ROOT/ip/sova_dec/src/sova_dec.sv" "$ROOT/ip/sova_dec/tb/tb_sova_dec.sv" >"$B/build$m.log"
done
fail=0
for s in $SEEDS; do
  for m in 1 0; do
    mode=$([ $m = 1 ] && echo BR || echo HR)
    python3 "$ROOT/uvm/scripts/gen_sova_vectors.py" "$B/vec_${mode}_$s" --mode $mode --frames "$FR" --seed "$s" >/dev/null
    for g in 0 50 90; do
      r=$("$B/obj$m/sim" +VEC="$B/vec_${mode}_$s" +GAP=$g +SEED=$s | grep -E "^(PASS|FAIL)")
      echo "$mode seed=$s gap=$g: $r"; [[ $r == PASS* ]] || fail=1
    done
  done
done
exit $fail
