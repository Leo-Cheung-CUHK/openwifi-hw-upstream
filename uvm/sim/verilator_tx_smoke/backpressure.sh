#!/usr/bin/env bash
# openofdm_tx under back-pressure: (1) tx_intf-style FIFO-threshold hold, (2) periodic
# hold patterns. Every line must PASS (exact sample count, EVM vs reference).
#   OPENWIFI_HW=/path/to/openwifi-hw ./backpressure.sh
# On upstream fa6c896 (before the openofdm_tx fixes on this branch): (1) every packet
# is 1 sample short (last sample flushed by FSM3_reset), (2) several patterns never
# reach phy_tx_done (phy_tx_start lost while ~result_iq_ready).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HW=${OPENWIFI_HW:?set OPENWIFI_HW}
SRC=$HW/ip/openofdm_tx/src
WORK=${WORK:-$HERE/work_bp}; mkdir -p "$WORK" && cd "$WORK"
# -Wno-USEBEFOREDECL exists only in Verilator > 5.054
WNO_UBD=$(verilator -Wno-USEBEFOREDECL --version >/dev/null 2>&1 && echo -Wno-USEBEFOREDECL || true)
ln -sf "$SRC"/icmem_*.mem .
[ -x obj_dir/simv ] || verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style $WNO_UBD --top-module tb \
  -I"$SRC" -I"$HERE/../gen_inc" "$HERE/tb_backpressure.sv" \
  $(ls "$SRC"/*.v | grep -v -e _tb.v -e openofdm_tx.v -e s_axi) -o simv >/dev/null
[ -x obj_hp/simv ] || verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style $WNO_UBD --Mdir obj_hp \
  --top-module tb -I"$SRC" -I"$HERE/../gen_inc" "$HERE/tb_holdpattern.sv" \
  $(ls "$SRC"/*.v | grep -v -e _tb.v -e openofdm_tx.v -e s_axi) -o simv >/dev/null
fail=0
for cfg in "1 7 0 600" "0 54 0 1500" "1 3 1 800" "0 6 0 200"; do
  python3 "$HERE/mkmem.py" $cfg t.mem
  for th in 1000000 420 32; do
    r=$(./obj_dir/simv +MEM=t.mem +TH=$th | grep -E 'RESULT|TIMEOUT' || true)
    c=$(python3 "$HERE/../../scripts/wifi_ref_tx.py" --mem t.mem --compare tx_iq.txt --pad hold 2>&1 | tail -1 | cut -c1-50 || true)
    echo "[$cfg] hold_th=$th : $r : $c"; [[ $c == PASS* ]] || fail=1
  done
  for ph in "5 4" "5 1" "10 5" "8 4" "6 3" "20 19" "3 1" "2 1" "7 3" "4 3" "9 8" "11 5"; do
    set -- $ph
    r=$(./obj_hp/simv +MEM=t.mem +P=$1 +H=$2 | grep -E 'RESULT|TIMEOUT' || true)
    c=$(python3 "$HERE/../../scripts/wifi_ref_tx.py" --mem t.mem --compare tx_iq.txt --pad hold 2>&1 | tail -1 | cut -c1-50 || true)
    echo "[$cfg] hold P=$1 H=$2 : $r : $c"; [[ $c == PASS* ]] || fail=1
  done
done
exit $fail
