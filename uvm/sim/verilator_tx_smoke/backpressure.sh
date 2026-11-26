#!/usr/bin/env bash
# Reproduces the openofdm_tx last-sample loss under tx_intf-style back-pressure.
#   OPENWIFI_HW=/path/to/openwifi-hw ./backpressure.sh
# Expected with the RTL as of open-sdr/openwifi-hw fa6c896: every packet is 1 sample short
# ("FAIL length: RTL N-1 vs ref N"); the first N-1 samples are bit-identical to the
# free-running output. dot11_tx.v S3_DATA raises phy_tx_done/FSM3_reset at
# nof_iq2send-2 regardless of result_iq_ready, so a sample stalled by tx_hold is flushed.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HW=${OPENWIFI_HW:?set OPENWIFI_HW}
SRC=$HW/ip/openofdm_tx/src
WORK=${WORK:-$HERE/work_bp}; mkdir -p "$WORK" && cd "$WORK"
ln -sf "$SRC"/icmem_*.mem .
[ -x obj_dir/simv ] || verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb \
  -I"$SRC" -I"$HERE/../gen_inc" "$HERE/tb_backpressure.sv" \
  $(ls "$SRC"/*.v | grep -v -e _tb.v -e openofdm_tx.v -e s_axi) -o simv >/dev/null
for cfg in "1 7 0 600" "0 54 0 1500" "1 3 1 800" "0 6 0 200"; do
  python3 "$HERE/mkmem.py" $cfg t.mem
  for th in 1000000 420 32; do
    r=$(./obj_dir/simv +MEM=t.mem +TH=$th | grep -E 'RESULT|TIMEOUT' || true)
    c=$(python3 "$HERE/../../scripts/wifi_ref_tx.py" --mem t.mem --compare tx_iq.txt --pad hold 2>&1 | tail -1 | cut -c1-50 || true)
    echo "[$cfg] hold_th=$th : $r : $c"
  done
done
