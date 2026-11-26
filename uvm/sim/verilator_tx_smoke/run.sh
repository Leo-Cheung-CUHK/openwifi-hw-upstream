#!/usr/bin/env bash
# No-license smoke regression for openofdm_tx (dot11_tx is pure RTL, no Xilinx IP):
# Verilator runs the RTL on generated BRAM images, wifi_ref_tx.py checks every OFDM
# symbol against the independent 802.11 reference (EVM < -30 dB).
#   usage: OPENWIFI_HW=/path/to/openwifi-hw ./run.sh
# Pad bits: the current RTL freezes the scrambler during the 6 tail bits (dot11_tx.v
# S11_TAIL), which differs from 802.11-2020 17.3.5.3 in the pad bits of the last symbol
# only. PAD=hold (default) matches the RTL; PAD=standard shows the deviation.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HW=${OPENWIFI_HW:?set OPENWIFI_HW to the openwifi-hw checkout}
SRC=$HW/ip/openofdm_tx/src
PAD=${PAD:-hold}
WORK=${WORK:-$HERE/work}
mkdir -p "$WORK" && cd "$WORK"
ln -sf "$SRC"/icmem_*.mem .            # ifftmain.v $readmemh's these from the CWD
if [ ! -x obj_dir/simv ]; then
  verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style --top-module tb \
    -I"$SRC" -I"$HERE/../gen_inc" "$HERE/tb.sv" \
    $(ls "$SRC"/*.v | grep -v -e _tb.v -e openofdm_tx.v -e s_axi) -o simv >/dev/null
fi
fail=0
while read -r ht rate sgi len; do
  python3 "$HERE/mkmem.py" "$ht" "$rate" "$sgi" "$len" t.mem
  ./obj_dir/simv +MEM=t.mem >/dev/null
  res=$(python3 "$HERE/../../scripts/wifi_ref_tx.py" --mem t.mem --compare tx_iq.txt --pad "$PAD" 2>&1 | grep -E 'PASS|FAIL' || true)
  echo "ht=$ht rate=$rate sgi=$sgi len=$len : $res"
  [[ $res == PASS* ]] || fail=1
done <<'EOF'
0 6 0 100
0 9 0 77
0 12 0 100
0 18 0 50
0 24 0 100
0 36 0 64
0 48 0 333
0 54 0 1500
1 0 0 100
1 1 0 100
1 2 0 90
1 3 0 100
1 4 0 100
1 5 0 100
1 6 0 100
1 7 0 100
1 7 1 300
1 4 1 200
1 0 1 14
1 5 1 1000
EOF
exit $fail
