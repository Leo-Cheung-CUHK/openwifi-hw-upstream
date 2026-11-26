# openwifi-hw — UVM verification architecture (chip level + block level)

Target: `open-sdr/openwifi-hw` @ `fa6c896` (2026-10-13), `ip/openofdm_rx` @ `2bb3ad1`.
Driver reference: `open-sdr/openwifi` `driver/` (register map, init sequences, DMA formats).

---

## 1. What the design is (as read from the code)

openwifi-hw is the PL part of an 802.11a/g/n (20 MHz, 1x1, BCC) SoftMAC NIC. The FPGA
block design (`boards/<board>/src/system.bd`) places a hierarchy **`openwifi_ip`** between
the PS and the RF front-end. That hierarchy is the chip-level DUT.

```
            PS (Linux driver sdr.c)                                RF front-end
   M_AXI_GP (AXI-lite)      HP/ACP (DMA memory)             (AD9361 on most boards, RF-DC on RFSoC)
        |                        ^                                  |  adc_data 64b  ^ dac_data 64b
        v                        |                                  v  @40 MHz       | @40 MHz
 +------------------------------ openwifi_ip ------------------------------------------------+
 | axi_interconnect_1 --> 6 x s_axi + 2 x axi_dma lite                                         |
 |                                                                                              |
 |  axi_dma_0 MM2S ==AXIS==> tx_intf ==BRAM/ACC==> openofdm_tx                                  |
 |                             |  ^  (data_to_acc, bram_addr, result_iq, tx_hold, phy_tx_*)     |
 |                             |  |                                                             |
 |                             v  +--- xpu (CSMA/CA, ACK/CTS, retrans, filter, TSF, RSSI/CCA) --+|
 |                          dac_intf --> dac_data                       ^         ^             |
 |                                                                       |         |             |
 |  adc_data --> rx_intf(adc_intf, rx_iq_intf) --sample0--> openofdm_rx --header/bytes/fcs------+|
 |                  |                                           |                                |
 |  axi_dma_1 S2MM <==AXIS== rx_intf (descriptor + PSDU)        +--csi/equalizer--> side_ch      |
 |  axi_dma_0 S2MM <==AXIS== side_ch                                                           |
 +----------------------------------------------------------------------------------------------+
```

| IP | Role | Key interfaces | Notes for verification |
|---|---|---|---|
| `tx_intf` | 4 TX queues from DMA, builds PHY header words, BRAM for the PHY, I/Q FIFO to DAC, TX status FIFO | s00_axis (DMA), ACC bus to openofdm_tx, dac_data (dac_clk), xpu handshake | Two clocks. Writes L-SIG/HT-SIG (parity, HT-SIG CRC, HT length spoof) itself |
| `openofdm_tx` | BCC encoder, puncture/interleave, QAM, pilots, 64-pt IFFT (ZipCPU), preambles | BRAM read port, I/Q valid/ready (ready = ~tx_hold) | Pure RTL (no Xilinx IP) |
| `rx_intf` | ADC decimate-by-2 + gain, I/Q to receiver, RX descriptor + PSDU to DMA, rx interrupt | adc_data (adc_clk), sample0/strobe, openofdm_rx outputs, m00_axis | Two clocks |
| `openofdm_rx` | Sync, CFO, FFT, equaliser, demod, Viterbi, descramble, FCS | sample_in @20 Msps strobe, header/byte/fcs strobes, CSI | **Uses Xilinx IP**: xfft_v9, viterbi_v7_0 (licensed), complex_multiplier, div_gen, LUT ROMs |
| `xpu` | Low MAC: CSMA/CA, slices, ACK/CTS generation, retransmission, address filter, RSSI/CCA, TSF, SPI to AD9361 | everything above + 64 regs | Timing-critical (SIFS/slot/ACK timeout) |
| `side_ch` | CSI / IQ capture to host | openofdm_rx/xpu/tx taps, m00_axis | Optional (`HAS_SIDE_CH`) |

Clocks: `clk` = `m_axi_mm2s_aclk` = PS FCLK; every IP core runs on it (openofdm_tx/rx use the
AXI clock as core clock). `NUM_CLK_PER_US` = 100 in `boards/openwifi.tcl` (overrides
`ip_repo_gen.tcl`); UltraScale+ builds can use 250. `adc_clk` = 40 MHz (2 × 20 Msps) shared by
rx_intf (ADC) and tx_intf (DAC).

Address map (system.bd, PS view): `0xA000_0000 + slot·0x1_0000`: 0 axi_dma_0, 1 axi_dma_1,
2 openofdm_rx, 3 openofdm_tx, 4 rx_intf, 5 side_ch, 6 tx_intf, 7 xpu.

Data formats (all taken from RTL + driver, encoded in `verif/common/wifi/wifi_pkg.sv`):
* **TX register kick** (`sdr.c openwifi_tx`): `TX_CONFIG = {prio, bd_wr_idx, queue, retry, need_ack, num_dma_symbol}`,
  `PHY_HDR_CONFIG = {ht_aggr_start, rate_hw[19:16], ht[15], sgi[14], aggr[13], len_psdu[12:0]}`, then the MPDU
  (no FCS; zero padded to 64 bit) on DMA. `rate_hw`: legacy 4..11 = 6..54 Mbps, HT 0..7 = MCS.
* **openofdm_tx BRAM image** (written by `tx_bit_intf.v`): word0 = L-SIG incl. parity, word1 = HT-SIG incl. CRC
  (HT only), **PSDU from word 2 for legacy too**; FCS appended by `crc32_tx`. HT L-SIG LENGTH = 3·(4+N)−3.
* **RX DMA descriptor** (`rx_intf_pl_to_m_axis.v`): word0 TSF; word1 `{phase[7:0], aggr_last, aggr, sgi, ht, rate[3:0], len[15:0], 8'h01, gpio[7:0], 5'b0, rssi[10:0]}`;
  then PSDU, last byte bit 7 = fcs_ok.

Existing tests in the repo: `openofdm_rx/verilog/dot11_tb.v` (file-driven, plus MATLAB/captured
IQ vectors in `testing_inputs/`), `openofdm_tx/src/dot11_tx_tb.v` (+ 3 BRAM images), 3 small unit
TBs (adc_intf, fifo_sample_delay, mv_avg). No self-checking, no UVM, no chip-level sim.

---

## 2. Strategy

1. **Block level first, with independent references.** Each IP gets its own UVM TB where the
   neighbours are TB models. The two PHYs are checked against references that do *not* come
   from the RTL: an IEEE-802.11-2020 Python transmitter (`scripts/wifi_ref_tx.py`) for
   openofdm_tx, and MATLAB/captured vectors + Python-generated vectors for openofdm_rx.
2. **Chip level reuses the verified PHYs as the peer station.** Once openofdm_tx/rx pass at block
   level, a second instance of each in `tb_chip` acts as "the other STA": peer TX renders any
   frame the test wants into I/Q for the DUT; peer RX decodes everything the DUT puts on air.
   This gives end-to-end, payload-exact checking of TX, RX, ACK and timing without a
   behavioural PHY model.
3. **Driver replay for configuration.** Register bring-up sequences are transcriptions of the
   driver (`hw_init()` per IP, `openwifi_start()`, `openwifi_tx()`), so the TB configures the
   chip exactly as Linux does; tests override individual knobs.
4. **White-box localisation.** Chip-level passive monitors sit on the DUT's internal
   openofdm_rx outputs and the tx_intf↔openofdm_tx bus, so a chip failure points at a block.
5. **No-licence checks in CI.** `make lint` (slang + UVM) elaborates all seven TBs;
   `make smoke` runs openofdm_tx in Verilator against the Python reference.

---

## 3. Shared VIP (`verif/common`)

| Package / interface | Contents | Used by |
|---|---|---|
| `axil_if`, `axil_pkg` | AXI-lite master (AW+W together, as the Xilinx s_axi template needs), monitor, protocol SVA, `axil_reg_adapter` | all |
| `axis_if`, `axis_pkg` | AXIS master (DMA MM2S), slave with READY_ALWAYS/RANDOM/NEVER (DMA S2MM), monitor, byte helpers | tx_intf, rx_intf, side_ch, chip |
| `iq_if`, `iq_pkg` | continuous I/Q driver (idle floor, repeat for 40 MHz ADC, strobe for 20 Msps), burst monitor (decimation/phase pick, valid/ready qualification), `I Q` file I/O, scale/CFO impairments | all PHY-facing TBs |
| `phy_rx_if`, `phy_rx_pkg` | openofdm_rx output bundle; **monitor** (header/bytes/fcs → `phy_rx_result`), **driver** emulating openofdm_rx timing from a `wifi_frame` (incl. CSI/equaliser strobes) | openofdm_rx (mon), rx_intf/xpu/side_ch (drv), chip (mon ×2) |
| `phy_tx_if`, `phy_tx_pkg` | tx_intf↔openofdm_tx bundle; roles BRAM_SERVER (TB = tx_intf, with HOLD_NONE/RANDOM/FIFO_MODEL back-pressure), ACC_MODEL (TB = openofdm_tx, ramp I/Q), passive monitor recording the BRAM image; handshake SVA | openofdm_tx, tx_intf, chip |
| `wifi_pkg` | `wifi_frame` (rand PHY/MAC fields, header builder, FCS, n_sym, exact sample count), all openwifi encodings (BRAM image incl. HT-SIG CRC, driver words, DMA bytes, rx rate_idx), `rx_desc` parser, `wifi_frame_cov` covergroup | all |
| `openwifi_ral_pkg` | RAL for all six IPs (names from `hw_def.h`, RO/volatile from RTL), chip map with the BD offsets | all |
| `openwifi_seq_pkg` | `*_init_seq` = driver `hw_init()`, `openwifi_start_seq`, `tx_kick_seq` | all |
| `irq_if` | interrupt edge counters + wait helpers | tx_intf, rx_intf, chip |

---

## 4. Block-level testbenches (`verif/block/<ip>`)

### 4.1 openofdm_tx
```
 phy_tx_agent(BRAM_SERVER) --phy_tx_start/bram_din/tx_hold--> [openofdm_tx] --result_iq--> iq_monitor
          | sent_ap                                               ^ s_axi                     |
          +------------------> otx_scoreboard <-------------------+-- axil/RAL                 |
                                 ^  length == wifi_frame::tx_samples()  <---------------------+
                                 +  dumps frame_N.json + rtl_N.txt -> scripts/check_tx_dumps.py (EVM per symbol)
```
Tests: `otx_reg_reset_test`, `otx_rate_sweep_test` (all 8 legacy rates + 8 MCS × LGI/SGI × 14/100/1500 B),
`otx_random_test`, `otx_backpressure_test` (FIFO-model hold, see §8 finding 1).
Coverage: `wifi_frame_cov` (format × rate × length bins, SGI, symbol-boundary padding).

### 4.2 openofdm_rx
```
 vector files / gen_rx_vectors.py -> iq_agent (20 Msps strobe) -> [openofdm_rx] -> phy_rx_monitor -> orx_scoreboard
                                     (impairments: gain, CFO)        ^ axil/RAL (driver hw_init)
```
One stimulus *window* per vector: exactly one decoded packet expected, header rate/len,
PSDU bytes (generated vectors), `fcs_ok`; spurious decodes are errors. Expectation source:
`.exp` sidecar (generated) or file-name convention (`ag_<N>M_len<L>`, `ht_mcs<M>_gi<G>_aggr<A>_len<L>`,
`dot11a_<N>mbps`). Tests: `orx_vectors_test`, `orx_impair_test`, `orx_reg_reset_test`.
Lists: `make rxlists` → `build/lists/rx_{simulated,conducted,generated}.list`.

### 4.3 tx_intf
TB plays DMA (AXIS master), openofdm_tx (`phy_tx_agent` ACC_MODEL), xpu (`xpu_tx_stub.sv`:
grants the medium, pulses `tx_try_complete`), DAC (iq monitor, 40 Msps zero-stuffed, decim 2).
Checks: BRAM image == `wifi_frame::bram_words()` (header build, parity, CRC, legacy-length spoof,
PSDU copy), DAC samples == ACC ramp × BB_GAIN >>> 7 **exactly** (nothing dropped/duplicated
across the CDC), `tx_itrpt` + `PKT_INFO1` (bd index, queue). Tests: `txi_basic_test`,
`txi_stress_test` (low TX_HOLD_THRESHOLD).

### 4.4 rx_intf
TB plays ADC (iq agent @40 MHz, each sample twice), openofdm_rx (`phy_rx_agent` ACTIVE),
xpu sideband (`rx_side_if`: filter verdict pulsed after the header strobe, RSSI/AGC lock, TSF),
DMA S2MM (random back-pressure). Checks: ADC→`sample0` path per BB_GAIN shift; DMA packet ==
`rx_desc` (len, rate_idx, sgi, pkt-exist byte, gpio, rssi, tsf ≥ start, PSDU, fcs bit);
filtered packets never reach DMA; `rx_pkt_intr` count. Tests: `rxi_adc_path_test`, `rxi_frames_test`.

### 4.5 xpu
TB plays openofdm_rx (real PHY timing, not fast mode — MAC timers depend on it), DDC feed for
RSSI/CCA, and tx_intf+openofdm_tx (`xpu_phy_responder`: answers `start_tx_ack`, walks
`bram_addr`, records the ACK image xpu serves through `dina` while `ack_tx_flag`).
Checks: ACK due iff unicast-to-me data/mgmt with good FCS; ACK image == expected 10-byte ACK
(RA = TA of the received frame, 6 Mbps, len 14); response latency window; TSF load/rollover/rate.
Tests: `xpu_ack_test`, `xpu_tsf_test`. To add next: CSMA/backoff (slot/DIFS/CW from
`CSMA_CFG`), retransmission on missing ACK (`tx_pkt_need_ack`, `RECV_ACK_COUNT_TOP`),
CTS-to-RTS, filter-flag matrix, LBT threshold vs DDC power.

### 4.6 side_ch
TB plays openofdm_rx (CSI/equaliser strobes with a known pattern), xpu taps, DMA S2MM.
Checks the record framing used by `side_info_display.py` (2 + 56 + num_eq·52 words, TSF
monotonic) and `M_AXIS_DATA_COUNT`. Value-level CSI check is left switched off until the
kept-bin map is taken from `side_ch_control.v`. Test: `sch_csi_test`.

---

## 5. Chip-level testbench (`verif/chip`)

```
                        +---------------------------------- tb_chip ----------------------------------+
  chip_env              |                                                                              |
  axil_agent+RAL -------+--> s_axil --> axil_decoder --> 6 x s_axi      openwifi_core_top (DUT)        |
  axis master (DMA0) ---+--> s_axis_tx                                                                 |
  axis slave  (DMA1) <--+--- m_axis_rx                                   adc_data <---- iq_agent(ADC) <-+-- peer TX burst
  axis slave  (DMA0) <--+--- m_axis_sidech                               dac_data ----> iq_monitor(DAC) |      (+gain/CFO)
  irq_if <--------------+--- tx_itrpt / rx_pkt_intr                          |                          |
                        |   white-box: phy_rx_if (DUT openofdm_rx)            +--> dac_to_peer_rx --> peer openofdm_rx --> phy_rx_monitor
                        |              phy_tx_if (DUT tx_intf<->openofdm_tx)                                   |
                        |   peer openofdm_tx <-- phy_tx_agent(BRAM_SERVER) <-- vseq                           |
                        +-------------------------------------------------------------------------------------+
  scoreboards:
    chip_air_sb : expected air frames (host TX, ACKs)  vs  BRAM image (white-box) + DAC burst length/timing + peer decode (bytes, FCS)
    chip_rx_sb  : peer frames  vs  DUT openofdm_rx (white-box)  +  RX DMA descriptor/PSDU
```

* **DUT = `openwifi_core_top`**, generated from `system.bd` by `scripts/gen_core_top.py`: the six
  user IPs with exactly the BD wiring, Xilinx infrastructure removed (axi_dma ×2,
  axi_interconnect ×3, proc_sys_reset). One AXI-lite port with the BD address decode
  (`rtl_wrap/axil_decoder.sv`, absent DMA slots answer DECERR), four AXIS ports where the DMA
  engines were. Re-run the generator whenever the BD changes; it lists every IP input the BD
  leaves unconnected (e.g. `tx_intf.dma_*`, `openofdm_rx.para_*`).
  *Why not simulate the DMA too?* axi_dma is a verified Xilinx IP; its scatter-gather
  behaviour belongs to driver/SoC tests. An optional SoC-level config (BD-exported
  `openwifi_ip` + AXI memory slave model) can be added later for DMA-descriptor tests.
* **Bring-up** `chip_bringup_vseq` = `openwifi_start()` + peer PHY `hw_init`, filter flag
  per test (MONITOR_ALL by default, UNICAST_FOR_US|BROADCAST for ACK tests).
* **Tests**
  | test | what it proves |
  |---|---|
  | `chip_reg_test` | every register of every IP through the real decode: reset values, access policy |
  | `chip_tx_test` | host frame → DMA → tx_intf → openofdm_tx → DAC; BRAM image, exact burst length, peer decodes payload + FCS |
  | `chip_rx_test` | peer frame → ADC → rx_intf → openofdm_rx → rx_intf → DMA; descriptor + PSDU |
  | `chip_ack_test` | unicast to DUT: frame delivered to host **and** ACK on air to the peer, RA correct, DAC-start minus ADC-end within the SIFS window |
  | `chip_mixed_test` | TX and RX traffic concurrently (CSMA/CCA, mute during own TX, two DMA directions) |
* **ACK timing.** `SEND_ACK_WAIT_TOP` is calibrated in the driver for the *real* RF latency
  (AD9361 / RF-DC pipeline, `BB_RF_DELAY`). The TB has zero RF latency, so the measured gap is
  SIFS minus those latencies. `chip_cfg.sifs_{min,max}_us` (default 10–22 µs) is a sanity
  window; tighten it once the RFSoC adapter's latency is known, or model the latency in the
  ADC/DAC agents.

---

## 6. RFSoC notes

* `README.md` lists `rfsoc4x2` as a supported board, but `boards/rfsoc4x2/` is **not in this
  checkout**, so the RFSoC block design (RF-DC → openwifi_ip adapter, clocking) could not be read.
  The chip DUT boundary is `openwifi_ip`, which is the same for every board: 64-bit
  `{Q1,I1,Q0,I0}` ADC/DAC words at 40 MHz. The RF-DC adapter (decimation/interpolation,
  AXIS↔adc_data, clock crossing) should get its own block TB once its source is available;
  reuse `iq_agent` on both sides.
* Use the **zynquplus** Xilinx IP variants for openofdm_rx (`PART=xczu48dr-ffvg1517-2-e`).
* Set `NUM_CLK_PER_US` to the RFSoC build's value (100 in the current `openwifi.tcl`; 250 if the
  UltraScale+ build is switched to 250 MHz). Every TB derives clocks and timers from it.

---

## 7. Flow

```
cd sim
make prep OW_HW=/path/openwifi-hw            # wrapper + build/rtl/<ip>/ (+ module-name uniquification)
make xip  SIM=xsim PART=xczu48dr-ffvg1517-2-e # Xilinx IP models for openofdm_rx (Vivado 2022.2 + Viterbi licence)
make run  TB=openofdm_tx TEST=otx_rate_sweep_test SIM=xsim
make run  TB=openofdm_tx TEST=otx_random_test PLUSARGS="+TX_DUMP_DIR=dumps +N_PKT=200" && python3 ../scripts/check_tx_dumps.py <run>/dumps
make rxlists && make run TB=openofdm_rx PLUSARGS="+RX_VEC_LIST=../build/lists/rx_simulated.list"
make run  TB=chip TEST=chip_ack_test
make regress                                  # all TBs × default tests
make lint UVM_SRC=/path/uvm-core/src          # no simulator needed
make smoke                                    # Verilator + Python reference, no licence
```

Compile notes handled by the scripts:
* Module names collide across IPs and are **not** always identical (`mv_avg.v` in rx_intf ≠ xpu/openofdm_rx).
  `prep_rtl.py` renames every shared module to `<ip>__<module>` inside its IP.
* RTL uses `bit` as an identifier (`ht_sig_crc.v`) → files are wrapped in `` `begin_keywords "1364-2005" ``.
* `common_defs.v` macros must precede the files using them → compile per IP as one unit (`-mfcu`).
* `ifftmain.v` `$readmemh`s `icmem_*.mem` from the CWD → the Makefile links them into the run dir.
* `clock_speed.v`, `*_pre_def.v`, git-rev headers are generated by the FPGA flow → sim copies in `sim/gen_inc`.
* XPM sources and `glbl.v` come from `$XILINX_VIVADO`.

---

## 8. Findings while building the environment

### openofdm_tx RTL bugs — fixed on this branch (`ip/openofdm_tx/src/dot11_tx.v`)

| # | Bug | Symptom | Fix (commit) |
|---|---|---|---|
| A | BCC encoder reset at `plcp_bit_cnt == 23` also fired inside HT-SIG (counter restarts per field) | HT-SIG1/2 encoded as two blocks instead of one (802.11-2020 19.3.9.4.3); HT-SIG2 wrong for HT PSDU ≥ 1024 B; boundary exactly 1023/1024 B | reset at bit 23 only in `S1_L_SIG`, bit 47 only in `S1_HT_SIG` (`c38c16b`) |
| B | `pilot_scram_state` loaded only on `reset_int`; driver writes `INIT_PILOT_STATE` after `MULTI_RST` | first frame after `hw_init` sent with pilot seed 0 (wrong pilot polarity, ≈ −4 dB EVM on affected symbols) | also load on `phy_tx_start`, like the data scrambler (`72d4d0d`) |
| C | `phy_tx_done`/`FSM3_reset` raised at `nof_iq2send-2`, last sample expected to leave in the reset cycle | under `tx_hold` (tx_intf FIFO above `TX_HOLD_THRESHOLD`) every packet one sample short | end on the last sample's handshake (`nof_iq2send-1 && valid`), no output in the reset cycle (`c1bb9d2`) |
| D | FSM3 only advances while `result_iq_ready`; 1-cycle `phy_tx_start` missed if `tx_hold` was high | FSM3 stuck in `S3_WAIT_PKT`, no `phy_tx_done`, FIFO data streamed out indefinitely | latch `phy_tx_start` until FSM3 leaves `S3_WAIT_PKT`; `result_iq_valid = 0` while waiting (`c1bb9d2`) |

How they were found: A from `otx_rate_sweep_test` + `check_tx_dumps.py` (16 HT 1500 B frames failing
at symbol 4) and the reference re-run with the encoder restarted at bit 24 (−74 dB match);
B from frame 1 failing only in the UVM run, a cycle-identical PHY interface trace vs the plain
harness, and the driver's init order; C and D from `otx_backpressure_test`, the
`a_no_pending_at_done` assertion and `sim/verilator_tx_smoke/backpressure.sh`.

After the fixes: `otx_reg_reset_test`, `otx_rate_sweep_test` (72/72), `otx_random_test` (100/100,
and 60/60 with 50 % and 90 % random hold), `otx_backpressure_test` (20/20), `backpressure.sh`
(60/60: FIFO-model and 12 periodic hold patterns × 4 frame types), `make smoke` (20/20) — exact
sample counts, worst-symbol EVM ≤ −71 dB, no assertion failures.

Still to check: the `openofdm_rx` RTL decoder's view of bug A (the Python receiver corrects it, see §9); interoperability of long HT frames with a commercial
802.11n receiver after the fix.

### Other findings

0c. **Register map: many slv_regs are not writable.** The write cases of several `*_s_axi.v`
   files are commented out (openofdm_tx implements only slv_reg0..2). Found by
   `otx_reg_reset_test`'s bit-bash; the RAL models non-writable slots as RO (`is_writable()`).
1. *(fixed, see C/D above)*
2. **Pad bits are scrambled with a frozen scrambler (deviation, harmless).** In `S11_TAIL` the
   scrambler state is held, so pad bits differ from IEEE 802.11-2020 §17.3.5.3 (only the last
   symbol differs; receivers ignore pad bits). `wifi_ref_tx.py --pad standard` shows it, `--pad hold` matches the RTL.
3. `ip/openwifi_ip.tcl` does not match the board BDs (`tx_itrpt0/1`, no side_ch) — the chip
   wrapper is therefore generated from `system.bd`, not from that script.
4. `openofdm_tx/unit_test/test_vec/ht_tx_intf_mem_mcs7_gi1_aggr0_byte8176.mem` has 1025 words,
   one more than the 10-bit BRAM address can hold.
5. `ht_sig_crc_calc.v` reads `data[34]` (out of range) on its final iteration; harmless (result
   latched from the previous state) but produces X in 4-state simulation.
6. `adc_intf.v` uses blocking assignments in the `default:` branch of a clocked `case`.

---

## 9. What has been checked, what has not

**UVM simulation (Verilator 5.055-devel + z3, Accellera uvm-core 2020-3.0, `make run SIM=verilator`):**

| test | upstream fa6c896 | with fixes A–D |
|---|---|---|
| `otx_reg_reset_test` | PASS (after the RAL fix 0c) | PASS |
| `otx_rate_sweep_test` (72 frames) | lengths 72/72, EVM 55/72 (A: 16 HT 1500 B; B: frame 1) | 72/72 |
| `otx_random_test` (100 frames, ≤ 400 B) | PASS | 100/100; also 60/60 at 50 % and 90 % random hold |
| `otx_backpressure_test` | FAIL (`a_no_pending_at_done`, C) | 20/20 |

Testbench bugs fixed while bringing this up: payload randomisation moved to
`post_randomize()` (no dynamic-array size constraints), 16 µs interframe gap in the BRAM
server, burst end-of-packet timeout raised to 1000 clocks, BRAM image read by the PHY now
checked against `bram_words()`. Other TBs need the XPM sources (`$XILINX_VIVADO`) or the
Xilinx IP models and have not been simulated yet.

**Independent receiver (`scripts/py_rx_decode.py`, openofdm `decode.py`):** the TX IQ
captures are decoded by openofdm's own Python receiver (Viterbi, soft decisions); PSDU and
FCS are compared with the frame the sequence sent.

| captures | result |
|---|---|
| fixed RTL, `otx_rate_sweep_test` (72 frames, legacy 6–54 M, HT MCS0–7, LGI/SGI, 14–1500 B) | 72/72 |
| upstream fa6c896, frames 0001/0030/0046/0069 | 4/4, including the two HT 1500 B frames that bug A breaks |

The receiver hides bug A. On frame 0069 (HT MCS7, 1504 B PSDU) the extra encoder reset
changes 2 of the 96 coded HT-SIG bits (the first pair of HT-SIG2). On a noise-free capture
the Viterbi decoder corrects those 2 bits, so the frame decodes. The bit-exact
`check_tx_dumps.py` comparison is the check that catches it.

Cost in noise (`scripts/htsig_noise.py`): AWGN on the captured burst, then decode.py's header
path up to the HT-SIG CRC (hard decisions, as in decode.py). 300 trials per point; both
captures see the same noise.

| SNR (dB) | 0 | 1 | 2 | 3 | 4 | ≥ 5 |
|---|---|---|---|---|---|---|
| HT-SIG frame error rate, upstream RTL | 0.87 | 0.60 | 0.28 | 0.063 | 0.027 | 0 |
| HT-SIG frame error rate, fixed RTL | 0.76 | 0.41 | 0.15 | 0.017 | 0.007 | 0 |

That is about 0.5 dB of HT-SIG margin lost at 10 % error rate and about 1 dB at 3 %. A failed
HT-SIG CRC makes openofdm treat the frame as legacy, so the frame is lost. The data part of a
long HT frame needs more SNR than HT-SIG, even at MCS0, so in practice this rarely limits a link.
The bug is a standard-compliance defect, not an interoperability blocker.
`python3 scripts/py_rx_decode.py <dump_dir> [-j N] [-v]` exits 1 on any mismatch.

Earlier static checks:

Checked here:
* All seven TBs (block ×6 + chip) parse and elaborate with **slang** against Accellera
  UVM (`make lint`): types, port names/widths against the real RTL, interface hookup.
* `openofdm_tx` RTL run in **Verilator** on 20 rate/MCS/GI/length configurations; every OFDM
  symbol matches the independent Python reference at ≈ −72 dB EVM (fixed-point floor). This
  also validates `wifi_frame::tx_samples()` and the BRAM image layout (the legacy word-2
  offset and the K_MOD/pilot scaling were corrected because of it).
* HT-SIG CRC model == RTL vector; gen_rx_vectors / check_tx_dumps run end-to-end.

Not yet run (no simulator licence / Vivado in this environment):
* Any UVM simulation; expect a first round of debug (timeouts, plusarg defaults, the xpu
  responder timing, side_ch start mode).
* `gen_xilinx_ip_sim.tcl` (needs Vivado 2022.2 + Viterbi licence).

Next steps, in order: (1) `make xip` + `openofdm_rx` vectors on xsim; (2) openofdm_tx/tx_intf/rx_intf
block regressions; (3) chip_tx/rx/ack; (4) xpu CSMA/retransmission tests and coverage closure
(rate × length × GI, CSMA states, filter flags, queue × priority); (5) RFSoC adapter TB.
