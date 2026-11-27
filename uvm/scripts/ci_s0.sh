#!/usr/bin/env bash
# ci_s0.sh - the S0 gate (docs/FLOW.md §2): everything that runs without Vivado or a licence.
# Used by .github/workflows/s0.yml; runs the same way on any Linux box:
#
#   UVM_SRC=/path/uvm-core/src uvm/scripts/ci_s0.sh            # all steps
#   UVM_SRC=... uvm/scripts/ci_s0.sh lint smoke                 # only some steps
#
# Needs: python3 + numpy + pyslang, Verilator >= 5.05x with z3 on PATH (for the Verilator steps),
#        uvm-core 2020.3.0 (UVM_SRC), ip/openofdm_rx submodule checked out.
# Steps: prep lint xsimpy smoke backpressure otx golden pyrx htsig
# Exit status is non-zero if any step fails; a summary table is printed at the end and,
# under GitHub Actions, written to the job summary.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OW_UVM=$(cd "$HERE/.." && pwd)
OW_HW=${OW_HW:-$(cd "$OW_UVM/.." && pwd)}
UVM_SRC=${UVM_SRC:?set UVM_SRC to uvm-core/src}
OUT=${CI_OUT:-$OW_UVM/build/ci}
JOBS=${JOBS:-$(nproc)}
STEPS=${*:-prep lint xsimpy smoke backpressure otx golden pyrx htsig}
OTX_TESTS="otx_reg_reset_test otx_rate_sweep_test otx_random_test otx_backpressure_test"
GOLDEN=$OW_UVM/vectors/otx_rate_sweep/fixed
export OW_HW
mkdir -p "$OUT"
declare -a RES

run_step() {   # run_step <name> <cmd...> : log to $OUT/<name>.log, record PASS/FAIL + time
  local name=$1; shift; local t0=$SECONDS
  echo "::group::$name"
  if ( "$@" ) 2>&1 | tee "$OUT/$name.log"; then st=PASS; else st=FAIL; fi
  echo "::endgroup::"
  RES+=("$name|$st|$((SECONDS - t0))s")
  echo "== $name: $st ($((SECONDS - t0))s)"
}

# ---------------------------------------------------------------- steps
s_prep() {   # wrapper regenerated from system.bd must equal the committed one
  make -C "$OW_UVM/sim" -s prep OW_HW="$OW_HW" &&
  git -C "$OW_HW" diff --exit-code -- uvm/rtl_wrap/openwifi_core_top.sv
}
s_lint() {
  make -C "$OW_UVM/sim" -s lint OW_HW="$OW_HW" UVM_SRC="$UVM_SRC" | tee /dev/stderr | grep -c "RESULT PASS" |
    { read n; echo "lint: $n/7 PASS"; [ "$n" = 7 ]; }
}
s_xsimpy() { python3 "$OW_UVM/scripts/test_xsim_py.py"; }   # Windows/Linux xsim driver, fake Vivado
s_smoke() { make -C "$OW_UVM/sim" -s smoke OW_HW="$OW_HW"; }
s_backpressure() {
  OPENWIFI_HW="$OW_HW" WORK="$OW_UVM/build/verilator_bp" "$OW_UVM/sim/verilator_tx_smoke/backpressure.sh"
}
s_otx() {   # openofdm_tx UVM regression in Verilator; rate_sweep dumps go to $OUT/dumps
  local fail=0 t log extra
  rm -rf "$OUT/dumps"; mkdir -p "$OUT/dumps"
  for t in $OTX_TESTS; do
    extra=""; [ "$t" = otx_rate_sweep_test ] && extra="+TX_DUMP_DIR=$OUT/dumps"
    make -C "$OW_UVM/sim" -s run SIM=verilator TB=openofdm_tx TEST="$t" SEED=1 VERB=UVM_LOW \
      OW_HW="$OW_HW" UVM_SRC="$UVM_SRC" PLUSARGS="$extra" > "$OUT/otx_$t.log" 2>&1
    log=$OW_UVM/build/run/openofdm_tx_${t}_1/sim.log
    if [ -f "$log" ] && grep -q "UVM_ERROR :    0" "$log" && grep -q "UVM_FATAL :    0" "$log" &&
       ! grep -qi "assertion failed" "$log"; then
      echo "PASS $t  $(grep -o 'packets [0-9]*  length-ok [0-9]*  errors [0-9]*' "$log" | head -1)"
    else
      echo "FAIL $t (see $OUT/otx_$t.log, $log)"; tail -20 "$OUT/otx_$t.log"; fail=1
    fi
  done
  [ $fail = 0 ] && python3 "$OW_UVM/scripts/check_tx_dumps.py" "$OUT/dumps"
}
s_golden() {   # fresh rate_sweep captures must be bit-identical to the committed golden set
  [ -d "$OUT/dumps" ] && ls "$OUT/dumps"/rtl_*.txt >/dev/null 2>&1 || { echo "no dumps: run the otx step first"; return 1; }
  python3 "$OW_UVM/scripts/check_tx_dumps.py" "$GOLDEN" | tail -1 &&
  diff -rq "$GOLDEN" "$OUT/dumps" && echo "golden: $(ls "$GOLDEN"/rtl_*.txt | wc -l) captures identical"
}
s_pyrx() {   # openofdm's own Python receiver (pure-Python Viterbi: ~10-20 min for 72 frames)
  # Captures bit-identical to the golden set decode exactly like it (72/72, see
  # docs/results_py_rx_decode_rate_sweep.txt), so the decode only runs when they differ
  # (the golden step then fails too), when there are no fresh dumps, or with PYRX_FORCE=1.
  local d=$OUT/dumps; ls "$d"/rtl_*.txt >/dev/null 2>&1 || d=$GOLDEN
  if [ "$d" != "$GOLDEN" ] && [ -z "${PYRX_FORCE:-}" ] && diff -rq "$GOLDEN" "$d" >/dev/null; then
    echo "captures identical to golden: decode result unchanged (72/72); PYRX_FORCE=1 to decode anyway"
    return 0
  fi
  python3 "$OW_UVM/scripts/py_rx_decode.py" -j "$JOBS" "$d" | tee "$OUT/pyrx_full.txt" | tail -3
  grep -q "^72/72 frames decoded correctly" "$OUT/pyrx_full.txt"
}
s_htsig() {   # short HT-SIG noise run: must run, fixed RTL must not be worse than upstream
  local up=$OW_UVM/vectors/otx_rate_sweep/upstream_fa6c896
  python3 "$OW_UVM/scripts/htsig_noise.py" -j "$JOBS" -n "${HTSIG_N:-100}" --snr 1:3:1 \
    --cap old="$up/rtl_0069.txt" --cap fixed="$GOLDEN/rtl_0069.txt" --frame "$GOLDEN/frame_0069.json" |
    tee "$OUT/htsig.txt" &&
  awk '/^ *[0-9.]+ +[0-9.]+ +[0-9.]+ *$/ { o+=$2; f+=$3 } END { printf "sum FER old %.3f fixed %.3f\n", o, f; exit !(f <= o) }' "$OUT/htsig.txt"
}

for s in $STEPS; do
  case $s in
    prep|lint|xsimpy|smoke|backpressure|otx|golden|pyrx|htsig) run_step "$s" "s_$s" ;;
    *) echo "unknown step $s"; exit 2 ;;
  esac
done

# ---------------------------------------------------------------- summary
fail=0
{ echo "| step | result | time |"; echo "|---|---|---|"
  for r in "${RES[@]}"; do IFS='|' read -r n st t <<< "$r"; echo "| $n | $st | $t |"; [ "$st" = PASS ] || fail=1; done
} > "$OUT/summary.md"
cat "$OUT/summary.md"
[ -n "${GITHUB_STEP_SUMMARY:-}" ] && { echo "### S0 gate"; cat "$OUT/summary.md"; } >> "$GITHUB_STEP_SUMMARY"
exit $fail
