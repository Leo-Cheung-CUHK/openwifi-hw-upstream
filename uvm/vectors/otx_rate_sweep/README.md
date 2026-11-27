# openofdm_tx captures from `otx_rate_sweep_test`

`frame_NNNN.json`: the frame the sequence sent (PHY fields + MPDU hex).
`rtl_NNNN.txt`: the RTL's I/Q output for that frame (`I Q` per line, 20 Msps).

* `fixed/`: all 72 frames, RTL with fixes A–D (Verilator, branch `uvm-verification`).
* `upstream_fa6c896/`: frames 0001, 0030, 0046, 0069 from the unmodified upstream RTL.
  0030 and 0069 (HT, 1504 B PSDU) show bug A.

Uses: regression data for the Python checkers, and the golden reference for on-board
captures (FLOW.md S6b).
```
python3 ../../scripts/check_tx_dumps.py fixed            # waveform vs wifi_ref_tx.py
python3 ../../scripts/py_rx_decode.py  fixed -j 4        # openofdm decode.py: 72/72
python3 ../../scripts/htsig_noise.py --cap old=upstream_fa6c896/rtl_0069.txt \
        --cap fixed=fixed/rtl_0069.txt --frame fixed/frame_0069.json
```
