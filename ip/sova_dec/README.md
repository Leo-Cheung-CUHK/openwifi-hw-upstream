# sova_dec — soft-output Viterbi decoder for openofdm_rx

Open-source replacement for the Xilinx Viterbi v9.1 core (`viterbi_v7_0`) in
`ip/openofdm_rx/verilog/ofdm_decoder.v`, with a per-bit LLR output.

| item | value |
|---|---|
| code | 802.11 BCC, K=7, 133/171 (octal), rate 1/2 mother code; 2/3, 3/4, 5/6 via erase |
| input | 3-bit soft, offset binary (0 = strongest '0'), `tdata = {5'b0,sym1,5'b0,sym0}`, `tuser[1:0]` = erase |
| hard output | `m_axis_data_tdata[0]`, decision depth D = 84 (as the Xilinx configuration) |
| LLR output | `m_axis_llr_tdata`: signed 6-bit sign-extended to 8, positive = bit 0, unit = channel LLR Lc = 7 − 2·sym |
| SOVA rule | `BR=1` BR-SOVA (Battail/Fossorier, = max-log-MAP for a full window), `BR=0` HR-SOVA (Hagenauer) |
| throughput | one input per clock; output 9 clocks after the input; one output per input once 84 inputs were seen since reset |
| storage | ≈ 30 k flip-flops (register exchange: 64×84 bits, 64×48×(1+6) reliability); BR adds ≈ 3 k 6-bit saturating adders |

## Files

| file | what |
|---|---|
| `src/sova_dec.sv` | the decoder |
| `src/viterbi_v7_0_sova.sv` | drop-in module `viterbi_v7_0` (same ports + `m_axis_llr_tdata`); `+define+SOVA_HR` selects HR |
| `tb/tb_sova_dec.sv`, `tb/run_vlt.sh` | bit-exact regression against the Python model (Verilator ≥ 5) |
| `uvm/scripts/sova_ref.py` | bit-true reference model = the specification (`SovaRef(..., arch="C")`) |
| `uvm/scripts/test_sova_ref.py` | model self-check: hard bits == traceback Viterbi (all rates), BR-SOVA == max-log-MAP (bit-exact), AWGN calibration |
| `uvm/scripts/gen_sova_vectors.py` | RTL vectors from the model |
| `uvm/scripts/sova_lr_sweep*.py`, `sova_scale_sweep.py` | design-space sweeps behind LR = 48, RMAX = 63, no HR scaling |

## Architecture (arch C of the model)

1. **S** — branch metrics, 64 ACS (modulo path metrics, 10 bit; ties → even predecessor),
   survivor bits by register exchange over D = 84 lags, Δ = |m0 − m1| saturated to 63.
2. **R** — reliability register exchange over LR = 48 lags:
   bits differ → `min(Rs, Δ)`; bits equal → `min(Rs, Δ + Rc)` (BR) or `Rs` (HR).
3. **T** — 6-level registered best-state tree (lowest index wins ties) carrying
   (bit @ lag 83, bit @ lag 47, R @ lag 47).
4. **O** — 36-deep delay line aligns R with the depth-84 bit; LLR = ±(R >> 1), 0 if the two
   bits disagree (≈ 0.15 % of bits at BER 1e-2).

## Design choices (from the sweeps)

* D must stay 84: shrinking the whole decoder to 32 lags raises BER by ≈ 40 %.
* LR = 48 costs < 0.2 % mutual information against carrying reliabilities over all 84 lags.
* RMAX 63 and 127 give identical outputs (saturation commutes with min), so R is 6 bits.
* HR vs BR: mutual information within 0.002–0.004, best-fit LLR scale HR/BR 0.93–1.0, so HR
  is not scaled; both are kept as a parameter until synthesis numbers decide.

## Running

```
python3 uvm/scripts/test_sova_ref.py            # model self-check (--quick: seconds)
ip/sova_dec/tb/run_vlt.sh [frames] ["seeds"]    # RTL == model, BR and HR
make -C uvm/sim run SIM=xsim TB=openofdm_rx VIT=sova TEST=orx_vectors_test   # in openofdm_rx
python uvm/sim/xsim.py --vit sova xip|run|regress                            # same on Windows
```
`VIT=sova` compiles `src/*.sv` instead of the Xilinx Viterbi model, in separate `*_sova` model and
run directories; `make xip VIT=sova` / `xsim.py --vit sova xip` generate the other Xilinx IP models
without the Viterbi core, so no Viterbi licence is needed. S0 step `sova` runs the model check,
the RTL regression and a slang elaboration of openofdm_rx with the wrapper.

## Status / open items

* [x] model, RTL, bit-exact in Verilator (BR, HR; all rates, ties, erasures, gaps, aclken, resets)
* [x] wrapper ports elaborate inside openofdm_rx (slang); xsim/Makefile `VIT=sova` flow (fake-Vivado test)
* [ ] openofdm_rx and chip regressions on xsim with `VIT=sova` — first real check that the
      output count/latency suits ofdm_decoder's end-of-frame padding (Xilinx latency may differ)
* [ ] Vivado synthesis on xc7z045 and RFSoC: resources, 100/200 MHz timing; BR vs HR decision
* [ ] LLR consumer in ofdm_decoder (port unconnected today)
