# openwifi-hw — from UVM to FPGA build, netlist sim and on-board emulation

This document defines the verification and build flow after the RTL-level UVM work
(see `ARCHITECTURE.md`). It runs in four stages: **RTL verification → SoC integration →
implementation and netlist sim → on-board emulation**. Each stage has a gate that must pass
before the next one runs. The same frame sets and Python reference models are reused at
every stage, so a hardware failure can be replayed in simulation.

"Emulation" here means running the real design on the target FPGA board (FPGA prototyping /
hardware-in-the-loop), not a Palladium/Protium-class emulator.

---

## 1. Overview

```
 S0  cloud CI (every push)        S1-S2 desktop runner [vivado] (PR + nightly)    S3-S4 [vivado] (nightly / release)     S5-S6 [board] (release / on demand)
 ------------------------         ---------------------------------------------   -----------------------------------   ------------------------------------------
 slang lint (7 TBs)               S1 block UVM, xsim, all 6 IPs                   S3 create_ip_repo + openwifi.tcl       S5 bring-up: bitstream+XSA -> SD image,
 Verilator: openofdm_tx UVM          (openofdm_rx with Xilinx IP models)             synth + impl at NUM_CLK_PER_US          driver load, register readback
   regression + smoke             S2 chip UVM, xsim (openwifi_core_top)              timing / CDC / methodology gates    S6 emulation:
 Python: check_tx_dumps,             tx / rx / ack / mixed / loopback             S4 netlist sim:                         a) FPGA internal loopback (rx_intf reg3[8])
   py_rx_decode, htsig_noise      coverage merge                                     a) BD-level SoC sim (real axi_dma,    b) side_ch IQ capture -> Python checkers
        |                                |                                           AXI VIP as PS)                       c) 2-board / commercial-STA RF tests
        v gate G0                        v gate G1/G2                                b) post-synth funcsim, chip tests     d) ILA on phy_tx/phy_rx buses
                                                                                     c) post-route timing sim (smoke)            |
                                                                                        |  gate G3/G4                            v gate G5/G6
                                                                                        v                                        |
                                                                                                                                 |
   <--------------------------- failure on hardware: IQ capture / ILA dump -> new directed UVM test (S1/S2) ---------------------+
```

| Stage | Where | Trigger | Run time (estimate) | Gate (all must hold) |
|---|---|---|---|---|
| S0 static + Verilator | GitHub-hosted CI (`s0.yml`, running) | every push | ~6 min (tools cached; first run ~12 min) | prep no diff; lint 7/7; RTL strict 6/6; smoke 20/20; backpressure 60/60; otx regression (reg_reset, rate_sweep 72/72, random, backpressure); captures == golden; py_rx_decode 72/72 when captures change; htsig |
| S1 block UVM | desktop runner `[vivado]`, xsim | PR, nightly | 1–3 h | all block tests pass, no UVM_ERROR/FATAL, no SVA failure; coverage targets per §3 |
| S2 chip UVM | `[vivado]`, xsim | PR (smoke set), nightly (full) | 2–6 h | chip_reg/tx/rx/ack/mixed/loopback pass; ACK latency in window |
| S3 implementation | `[vivado]` | nightly, release | 1–2 h per board | WNS ≥ 0, WHS ≥ 0; no unwaived `report_cdc` critical; DRC/methodology clean or waived; utilisation recorded |
| S4 netlist sim | `[vivado]`, xsim | nightly (4a, 4b), release (4c) | 2–8 h | same checks as S2 on the netlist; BD-sim smoke passes |
| S5 bring-up | `[board]` (runner with JTAG + Ethernet to the board) | release, on demand | ~30 min | bitstream loads; driver probes; register reset values == RAL |
| S6 emulation | `[board]` | release, on demand | 1–4 h | §6 pass criteria |

Runners: S0 runs on GitHub-hosted Linux runners or the cloud container (no licence needed). S1–S6 run on the
self-hosted runner on the Windows desktop (native Vivado 2022.2, Viterbi evaluation licence), labels `vivado` and `board`
(setup: [RUNNER.md](RUNNER.md); on Windows the xsim flow runs through `sim/xsim.py`).
The board is reached over JTAG (bitstream, ILA) and Ethernet (ssh to the board's Linux).

---

## 2. S0 — static checks and Verilator (in CI since 2026-11-26)

Already in place on `uvm-verification`:
`make lint`, `make smoke`, `make run SIM=verilator TB=openofdm_tx TEST=…`,
`sim/verilator_tx_smoke/backpressure.sh`, `scripts/check_tx_dumps.py`, `scripts/py_rx_decode.py`,
`scripts/htsig_noise.py`.

CI: `.github/workflows/s0.yml` builds Verilator v5.054 + uvm-core 2020.3.0 once (Actions cache) and
runs `scripts/ci_s0.sh` (steps prep, lint, rtlstrict, xsimpy, smoke, backpressure, otx, golden, pyrx, htsig; see
[RUNNER.md](RUNNER.md) §1). This is the only stage that must pass on every push. The same script runs
locally: `UVM_SRC=<uvm-core>/src scripts/ci_s0.sh [steps…]`.

---

## 3. S1/S2 — RTL UVM on xsim

Flow (already scripted, not yet run on xsim; on Windows use `python sim/xsim.py prep|xip|regress`):
```
make prep OW_HW=$PWD/..                 # build/rtl copy + module renames
make xip  SIM=xsim PART=<board part>    # Xilinx IP sim models for openofdm_rx (xfft, viterbi, cmult, div_gen)
make regress SIM=xsim                   # all TBs x default tests
```
Status 2026-11-27: tx_intf, rx_intf, xpu and side_ch already run in Verilator in the cloud with the
behavioural XPM models (`scripts/run_block_vlt.sh <tb>`): 24/25 pass, `txi_cts_toself_test` fails on
RTL bug E/F (ARCHITECTURE.md §8). That TB bring-up (timeouts, responder timing, side_ch pull mode,
init sequences) is done, so on xsim the work left is: openofdm_rx with the Xilinx IP models
(ORX-01..08), the same block set against the real XPM library (catches any model deviation), then
chip. Verilator remains the fast pre-check before an S1 run.

Two additions tie S2 to the later stages:

* **`chip_loopback_test`** (new). Sets `rx_intf slv_reg3[8]` (FPGA internal loopback: tx_intf I/Q
  routed into the receiver), sends host frames and checks that the DUT's own openofdm_rx decodes them
  and that they reach RX DMA. This is the same mode used for the first on-board test (S6a). Note that
  `tx_intf.v` carries a comment that this loopback "will not work" without an extra 1-clock delay
  on `wifi_iq_ready`. The root cause is open, so it should be understood in simulation before hardware.
* **Frame-set export.** Every TX test writes its frames as `frame_NNNN.json` (already done for
  openofdm_tx). S6 replays the same JSON sets on hardware, so the expected results are identical.

Coverage closure targets (S1/S2 nightly, merged with `xcrg`): `wifi_frame_cov` 100 % of
rate × length-bin × GI bins; RAL access 100 %; xpu CSMA states, filter flags, queue × priority ≥ 95 %;
SVA cover properties hit.

---

## 4. S3 — IP packaging and implementation

Uses the project's own scripts so the verified RTL is the RTL that gets built:
```
cd boards/$BOARD_NAME
../create_ip_repo.sh $XILINX_DIR        # packages ip/* into ip_repo
vivado -mode batch -source ../openwifi.tcl -tclargs <...>   # BD project, synth, impl, bitstream, XSA
```
Wrap this in `uvm/flow/s3_build.tcl` (new), which also writes the gate reports:

| Report | Gate |
|---|---|
| `report_timing_summary` | WNS ≥ 0, WHS ≥ 0 at the chosen `NUM_CLK_PER_US` (100; 250 if the RFSoC build uses it) |
| `report_cdc -severity Critical` | none unwaived; the clock crossings are clk ↔ adc_clk (40 MHz) in tx_intf/rx_intf and the AXI/DMA crossings |
| `report_methodology`, `report_drc` | clean or waived in `uvm/flow/waivers.tcl` with a reason |
| `report_utilization` | recorded per build, trended (not gated) |
| RTL manifest | sha256 of every `ip/**/src/*.v` used by the IP repo == the set S1/S2 ran on (new `prep_rtl.py --manifest` option) |

The manifest check closes a gap: `make prep` copies RTL into `uvm/build/rtl`. If someone edits
`ip/` and forgets to rerun it, the UVM results describe different RTL from the RTL that gets built.
(This happened once while fixing bugs A–D.)

**First hardware target: ZC706 + FMCOMMS2/3/4 (`zc706_fmcs2`).** Zynq-7045, part
`xc7z045ffg900-2`, AD9361 front-end. This is now the default `BOARD`/`PART` in `sim/Makefile`, so the
chip TB wrapper, the Xilinx IP models (7-series `zynq` variants of openofdm_rx's IP) and S3 all use the
same block design.
* Licence: the 7z045 is not covered by the free Vivado edition. Use the device-locked licence that
  ships with the ZC706 kit, plus the Viterbi Decoder evaluation licence.
* Board prerequisites from the openwifi-hw README:
  `./prepare_adi_lib.sh $XILINX_DIR`, `./prepare_adi_board_ip.sh $XILINX_DIR zc706_fmcs2`,
  `./get_ip_openofdm_rx.sh`, then `cd boards/zc706_fmcs2 && ../create_ip_repo.sh $XILINX_DIR`.
* Clock: `NUM_CLK_PER_US` 100 (default) or 200 on zc706. Start with 100; the UVM env takes it from the same define.
* Wrapper differences from zcu102: no LED/PMOD/SPI debug outputs on the hierarchy, and `tx_intf.dma_data/dma_valid`
  are hierarchy inputs the system BD leaves open. `gen_core_top.py` now ties such inputs to 0 (they would
  otherwise have floated to X).

**RFSoC later.** `rfsoc4x2` is listed in the README but `boards/rfsoc4x2/` is not in this checkout
(master @ fa6c896). Once it comes from openwifi's RFSoC branch or release, repeat S3–S6 with
`BOARD=rfsoc4x2 PART=xczu48dr-ffvg1517-2-e` and add the RF-DC adapter TB (ARCHITECTURE.md §6).

---

## 5. S4 — netlist and SoC-level simulation

The chip TB's DUT (`openwifi_core_top`) is generated from `system.bd` with the DMA and
interconnect removed (ARCHITECTURE.md §5). S4 covers what that leaves out, and checks that
synthesis did not change behaviour.

**4a. BD-level SoC sim.** Export the `openwifi_ip` hierarchy (`export_simulation`) with the real
`axi_dma` ×2, interconnects and resets. Replace the PS with an AXI VIP master (register access)
and an AXI VIP slave (DDR for DMA buffers and descriptors). One smoke test: driver `hw_init`
sequence, one TX frame through MM2S scatter-gather, one RX frame through S2MM, interrupts.
This checks the BD wiring and address map and confirms that `gen_core_top.py` matches the BD.
The UVM RAL sequences are reused through a small VIP adapter.

**4b. Post-synthesis functional sim.** Out-of-context synthesis of `openwifi_core_top`, then
`write_verilog -mode funcsim`. Run the S2 smoke set (chip_tx, chip_rx, chip_ack, chip_loopback)
against the netlist with the same UVM env. Only the DUT file list changes. This catches
sim/synth mismatches. Known candidates are the blocking assignments in `adc_intf.v`
(finding 6) and the out-of-range `data[34]` read in `ht_sig_crc_calc.v` (finding 5).

**4c. Post-route timing sim (release only).** `write_verilog -mode timesim` + SDF, a single
chip_tx and chip_rx frame. This is slow and mainly confirms the CDC paths and reset release.
Static timing (S3) remains the real timing sign-off.

---

## 6. S5/S6 — on-board bring-up and emulation

**S5 bring-up.** `sdk_update.sh` → openwifi-hw-img → openwifi SD image (openwifi repo, kernel +
`sdr.ko`). On the board: load the bitstream, insmod the driver, then read every register through
`/dev/mem` or the driver debugfs and compare with the RAL reset values. The RAL is exported as a
JSON register list for this (`openwifi_ral_pkg` → `uvm/flow/regs.json`, new).

**S6 emulation levels**, simplest first. Each reuses the simulation reference models:

| Level | Setup | What is checked | Reference |
|---|---|---|---|
| a. FPGA internal loopback | one board, `rx_intf slv_reg3[8]=1`, no RF | host-injected frames (openwifi `inject_80211`, payloads from the S2 frame JSON) come back through openofdm_rx and RX DMA byte-exact with good FCS | same frame JSON as S2 `chip_loopback_test` |
| b. TX waveform capture | one board, internal loopback on, `side_ch` IQ capture (`slv_reg3[0]`, `iq_len_target`) of the samples rx_intf receives, i.e. the TX waveform after tx_intf | captured I/Q per frame vs `wifi_ref_tx.py` (EVM per symbol) and `py_rx_decode.py` (payload) | `check_tx_dumps.py`, `py_rx_decode.py`, unchanged |
| c. RF tests | two boards cabled through an attenuator, then a commercial 802.11n STA | PER vs attenuation per rate/MCS, ACK timing (SIFS measured with side_ch timestamps), interop of long HT frames (bug A fix) | `htsig_noise.py` curves as the expected HT-SIG margin |
| d. ILA debug | ILA on the `phy_tx_if` / `phy_rx_if` signal sets (openwifi already supports ILA insertion, `.ltx` in the img) | used when a–c fail: trigger on the failing frame, dump | ILA CSV → `phy_tx_pkg` trace format |

S6 gate (release): (a) 100 % of the frame set; (b) worst-symbol EVM at the RTL-sim fixed-point floor (≈ −70 dB after the tx_intf
BB_GAIN scaling; the path is digital, so the capture should match simulation); (c) PER < 10 % at the 802.11 minimum sensitivity margin for each rate
and no ACK timeouts at high SNR. The RF limits are provisional and are set from the first RFSoC measurements.

**Failure loop.** Every hardware failure ends as a simulation test before it is fixed:
an ILA dump or side_ch IQ capture becomes an `orx_vectors_test` vector file (RX path) or a
directed `wifi_frame` in a new sequence (TX path), it fails in S1/S2, it is fixed, and the test stays
in the regression.

---

## 7. Work items, in order

1. ~~CI workflow for S0 (`.github/workflows/s0.yml`)~~ done. Self-hosted runner on the Windows desktop (native Vivado, decided 2026-11-26) with labels `vivado` and later `board`: `sim/xsim.py` + `.github/workflows/s1.yml` done, runner setup in [RUNNER.md](RUNNER.md) §2 (to do on the desktop).
2. S1 on xsim: `make xip`, openofdm_rx vectors (ORX-01..08); re-run tx_intf, rx_intf, xpu, side_ch on real XPM (already passing in Verilator). Decide RTL fixes for E/F (tx_intf CTS-to-self) and I/J (rx_intf recovery/reset).
3. S2: chip tests on xsim, plus `chip_loopback_test` and the tx_intf `wifi_iq_ready` delay root cause.
4. S3 on ZC706 (`zc706_fmcs2`): `s3_build.tcl`, gates, RTL manifest.
5. S4a BD-level smoke with AXI VIP; S4b funcsim of the S2 smoke set.
6. Get `boards/rfsoc4x2`; repeat S3/S4 for RFSoC (`xczu48dr-ffvg1517-2-e`, RF-DC adapter TB from ARCHITECTURE.md §6).
7. S5/S6 on the board: regs.json readback, loopback, side_ch capture + Python checkers, then RF tests.

First hardware target: ZC706 + FMCOMMS (decided 2026-11-26).

Open decisions (owner: project lead):
* whether the board gets its own runner (Raspberry Pi / small PC next to it) or hangs off the desktop;
* the RF test equipment available (attenuators, a second board, a reference 802.11n STA or sniffer).
