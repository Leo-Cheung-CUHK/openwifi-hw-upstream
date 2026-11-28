# openwifi-hw UVM — project status

Snapshot: **2026-11-28 00:50 (America/Vancouver)**, branch `uvm-verification` @ `5a87ec1`.
Flow and gates: [FLOW.md](FLOW.md). Findings in detail: [ARCHITECTURE.md](ARCHITECTURE.md) §8.
Runner and desktop: [RUNNER.md](RUNNER.md). The same status is kept as a spreadsheet
("openwifi-hw overall status", claude.ai).

## 1. Stages

| Stage | Status | Evidence / what is left |
|---|---|---|
| S0 static + Verilator (GitHub CI) | **running, green** | `s0.yml` on every push: prep, lint 7/7, RTL strict 6/6, xsimpy, smoke 20/20, backpressure 60/60, otx regression, golden, pyrx, htsig. Last run on `5a87ec1`: success |
| S1 block UVM on xsim (desktop) | **closing** | 6/6 TBs compile and run on Windows Vivado 2022.2 xsim; last results in §2. Left: final full regression (started 00:40 on `5a87ec1`), coverage closure (§5) |
| S2 chip UVM on xsim | not started | chip TB lints (slang); 12 tests, `chip_loopback_test`, tx_intf `wifi_iq_ready` delay root cause |
| S3 implementation (ZC706) | not started | `s3_build.tcl`, timing/CDC/DRC gates, RTL manifest |
| S4 netlist / SoC sim | not started | S4a BD-level smoke with AXI VIP, S4b funcsim of the S2 smoke set |
| S5/S6 bring-up and emulation | not started | ZC706 + FMCOMMS first; RFSoC 4x2 later |

## 2. Block tests

Verilator: `scripts/run_block_vlt.sh` with the XPM models (2026-11-27). xsim: Windows desktop,
Vivado 2022.2 (2026-11-27/28); "fixed" = after the finding named in the note.

| TB | test | Verilator | xsim | note |
|---|---|---|---|---|
| openofdm_tx | otx_reg_reset_test | PASS | PASS | |
| openofdm_tx | otx_rate_sweep_test | PASS 72/72 | PASS 72/72 | bit-identical to the Verilator golden set (`+OTX_REPLAY`) |
| openofdm_tx | otx_random_test | PASS | PASS | |
| openofdm_tx | otx_backpressure_test | PASS | PASS | |
| openofdm_tx | otx_scrambler_seed_test | PASS | PASS | |
| openofdm_tx | otx_ampdu_test | PASS | PASS | after finding 10 |
| openofdm_tx | otx_reset_midpacket_test | PASS | PASS | |
| openofdm_rx | orx_reg_reset_test | lint only | PASS | |
| openofdm_rx | orx_vectors_test | lint only | partial pass | first vectors PASS; full run in regression |
| openofdm_rx | orx_impair_test | lint only | partial pass | |
| openofdm_rx | orx_snr_sweep_test | lint only | partial pass | 10 PASS so far |
| openofdm_rx | orx_len_limits_test | lint only | FAIL → fixed | finding K (sim copy + upstream patch); in regression |
| openofdm_rx | orx_b2b_test | lint only | partial pass | |
| tx_intf | txi_basic_test | PASS | PASS | |
| tx_intf | txi_stress_test | PASS | PASS | |
| tx_intf | txi_queues_test | PASS | PASS | |
| tx_intf | txi_ampdu_test | PASS | PASS | |
| tx_intf | txi_cts_toself_test | FAIL (E/F) | PASS | after findings E/F (RTL fix) and 10 |
| tx_intf | txi_arbitrary_iq_test | PASS | PASS | |
| tx_intf | txi_ant_test | PASS | PASS | |
| rx_intf | rxi_adc_path_test | PASS | PASS | |
| rx_intf | rxi_frames_test | PASS | PASS | after finding 10 |
| rx_intf | rxi_dma_stall_test | PASS (notes H/I/J) | FAIL → fixed | now checks I and J; I re-fixed (FIFO flush), in regression |
| rx_intf | rxi_loopback_src_test | PASS | PASS | |
| rx_intf | rxi_mute_ant_test | PASS | PASS | |
| xpu | xpu_tsf_test | PASS | PASS | |
| xpu | xpu_ack_test | PASS | PASS | |
| xpu | xpu_csma_test | PASS | PASS | after findings 9, 10 and L (RTL fix) |
| xpu | xpu_retrans_test | PASS | PASS | |
| xpu | xpu_filter_test | PASS | PASS | |
| xpu | xpu_cts_test | PASS | PASS | |
| xpu | xpu_blkack_test | PASS (with G) | PASS | |
| xpu | xpu_rssi_test | PASS | PASS | |
| xpu | xpu_slice_test | PASS | PASS | |
| side_ch | sch_csi_test | PASS | PASS | |
| side_ch | sch_match_test | PASS | PASS | |
| side_ch | sch_iq_capture_test | PASS | PASS | |
| side_ch | sch_num_eq_test | PASS | PASS | |
| chip | 12 tests (CHP) | lint only | not run | S2 |

## 3. Findings

RTL (A–L; detail and commits in ARCHITECTURE.md §8):

| # | Block | Short | Status |
|---|---|---|---|
| A | openofdm_tx | BCC encoder reset inside HT-SIG | fixed `c38c16b` |
| B | openofdm_tx | pilot scrambler seed not loaded after driver init | fixed `72d4d0d` |
| C | openofdm_tx | `phy_tx_done` one sample early under `tx_hold` | fixed `c1bb9d2` |
| D | openofdm_tx | 1-cycle `phy_tx_start` missed under `tx_hold` | fixed `c1bb9d2` |
| E | tx_intf | CTS-to-self skips the data frame's PHY header | fixed, verified on xsim |
| F | tx_intf | CTS wait address wraps, extra `phy_tx_start` | fixed, verified on xsim |
| G | xpu | BlockAck TID in the wrong bits | fixed, verified |
| H | rx_intf, side_ch | TLAST follows TREADY while stalled | waived in the TBs (DMA tolerates it) |
| I | rx_intf | TLAST-timeout recovery does not terminate a stalled DMA | fixed (FAKE_TLAST + FIFO flush), in regression |
| J | rx_intf | M_AXIS reset does not reset the RX DMA FSM | fixed, verified on xsim |
| K | openofdm_rx | length watchdog never fires | fixed in sim copy; upstream patch `uvm/patches/`; in regression |
| L | xpu | backoff timer and logged slot count from different random draws | fixed, verified on xsim |

Environment, register map and simulator findings (ARCHITECTURE.md §8 "Other findings"): 0c
non-writable slv_regs (RAL models them RO); 2 pad bits scrambled with a frozen scrambler
(harmless); 3 `openwifi_ip.tcl` vs board BDs; 4 a 1025-word test vector; 5 `ht_sig_crc_calc.v`
out-of-range read; 6 blocking assignments in `adc_intf.v`; 7 `dot11_tx.v` use-before-declare
(fixed); 8 xsim parameterised property crash (TB rewritten); 9 xsim hang on a part-select in a
fork (TB rewritten); 10 xsim `randomize() with` in `run_phase` (TB rewritten). xsim flow fixes:
port widths (tx_intf, openofdm_rx sim copy), `div_gen_csi_over_nova` padding, IP model
generation (`gen_xilinx_ip_sim.tcl`), init `POWER_THRES[23:16]` DC threshold.

## 4. Infrastructure

| Item | Status |
|---|---|
| S0 CI (`s0.yml`, GitHub-hosted) | running on every push |
| Self-hosted runner (desktop) | registered 2026-11-28 as `desktop`, labels self-hosted/windows/x64/vivado; runs `D:\AI_Openwifi\r\run.cmd` in a window |
| S1 workflow (`s1.yml`) | ready; **to do:** make `uvm-verification` the default branch so "Run workflow" appears |
| `xsim.py` | env, prep, xip, rxlists, run, regress (`--jobs N`, staggered starts), cov |
| Xilinx IP models | built on the desktop (`build\xip`, Viterbi evaluation licence) |
| Desktop Linux VM | unavailable (hardware virtualization off in the BIOS) |

## 5. Coverage (FLOW.md §3)

Collected since `4927cfa`: TBs print `OWCOV <space> <bin> <hits>`, `scripts/cov_report.py`
(`xsim.py cov`) merges all runs. Targets: `wifi_frame` 100 %; `ral_<block>` 100 % (every
register read, every writable one written); `xpu_*` (CSMA states, filter rules,
queue × need_ack) ≥ 95 %; `sva` (AXI-Stream/AXI-Lite covers) 100 %. First merged numbers: from
the full regression in progress. Expected gap: register writes not done by any test.

## 6. Next steps

1. Read the full S1 regression and the coverage report; close gaps (register write/read test per
   block, frames for missing rate × length × GI bins).
2. Make `uvm-verification` the default branch; run S1 from GitHub Actions on the runner.
3. S2: chip TB on xsim (12 tests), `chip_loopback_test`, `wifi_iq_ready` delay.
4. Send the finding K patch upstream (open-sdr/openofdm).
5. S3 on ZC706, then S4, then the board (S5/S6).

Open decisions (project lead): runner for the board (desktop or a small PC next to it); RF test
equipment.
