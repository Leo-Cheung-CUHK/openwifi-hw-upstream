# Dual-link frequency diversity with post-decoding SOVA combining

Short-term product goal on top of openwifi: **two links on two different frequencies carry the same
PSDU; the receiver decodes each link on its own and combines the soft outputs (LLRs) after decoding.**
Decided 2026-11-28. Related: [ARCHITECTURE.md](ARCHITECTURE.md), [STATUS.md](STATUS.md), [FLOW.md](FLOW.md).

---

## 1. Decisions

| Topic | Decision | Why |
|---|---|---|
| Hardware | **Two FMCOMMS2 already on hand**, one per FMC slot on **ZC706**; move to **ZCU102** only if Z045 resources run out | Uses existing cards; ZC706 is already the first board target |
| Combining point | **After decoding** (SOVA LLRs on descrambled PSDU bits) | Each link can pick its own MCS; coded bits of the two links then differ, so pre-decoder LLR combining is not possible |
| Decoder | SOVA RTL IP, outputs LLRs, drop-in replacement for the Xilinx Viterbi IP in `openofdm_rx` | Needed for post-decoding combining; also removes the licensed Viterbi dependency |
| MAC | Simplified first: fixed MCS per link, no CSMA, no ACK, one-way broadcast | Get the PER curves first; rate adaptation and ACK later |
| RF test set-up | **Deferred** | Simulation (V1–V5) comes first |

---

## 2. Hardware: two FMCOMMS2 on ZC706

* One AD9361 per card, each on its own frequency (a single AD9361 cannot do this alone: its two RX
  channels share one RX LO).
* ZC706 has one HPC and one LPC FMC connector; FMCOMMS2 is an FMC-LPC card, so it fits either.
  The existing openwifi `zc706_fmcs2` BD drives one card; the second card needs its own
  `axi_ad9361` instance, pin constraints for the other slot, its own SPI and GPIOs (reset, enable/txnrx),
  taken from ADI's per-slot constraints.
* **Independent clocks.** Each card has its own 40 MHz reference, so the two AD9361 data clocks are
  unrelated: two `adc_clk` domains in the PL. This is fine for post-decoding combining — the links
  only meet at packet level (LLR buffer), not at sample level. Each RX chain runs in its own domain up
  to the SOVA output; the combiner sits in the common `clk` domain behind async FIFOs.
* Different TX/RX frequencies are set per AD9361 through the driver (two SPI devices); the Linux
  driver / device tree needs a second ad9361 instance.
* **Resource check before committing:** synthesize "one RX chain + SOVA" on Z045 first. The second RX
  chain (sync, FFT, equaliser, demod) plus SOVA (traceback + reliability update, several times a
  Viterbi) is the main cost. Over budget → ZCU102 (two HPC FMC slots; same two-card approach).

Open: RF test set-up (deferred).

---

## 3. Receiver architecture

```
 AD9361 #0 (f0) -> rx_intf -> openofdm_rx #0 (sync/CFO/FFT/eq/demod) -> SOVA #0 -> descramble LLR #0 --+
   [adc_clk0]                                                                                          +-> combiner -> FCS -> rx DMA
 AD9361 #1 (f1) -> rx_intf -> openofdm_rx #1 (sync/CFO/FFT/eq/demod) -> SOVA #1 -> descramble LLR #1 --+   [clk]
   [adc_clk1]
```

* **Per-link MCS and scrambler seed** are free. Each SOVA output is descrambled by flipping the LLR
  sign with that link's known scrambler sequence, giving two LLR sets for the same PSDU bits.
* **Fast path:** if either link passes FCS on its own, deliver it at once. Soft-combine only when both
  fail. Worst case is then never worse than MLO-style selection.
* **Combine:** LLR_sum = α·(LLR0 + LLR1), hard decision, FCS check. SOVA LLRs are over-confident;
  α (typically 0.6–0.8) is calibrated in simulation.
* **Alignment buffer + timeout:** with different MCS the same PSDU has different air time on the two
  links. Buffer the first link's LLRs (match by PSDU length + sequence number / content hash), give up
  after a timeout and deliver whatever passed (or nothing).
* LLR width and buffer depth: set from the max PSDU length and the SOVA LLR quantisation (to be
  decided with the SOVA IP).

---

## 4. Transmitter

* Two TX chains (tx_intf + openofdm_tx) fed from the same host frame; per-link `rate_hw` / GI.
* Each TX chain runs in its card's DAC clock domain.
* Same PSDU on both links; scrambler seed may differ (receiver handles it).
* MAC simplified: transmit on both links without CSMA, no ACK expected.

---

## 5. Verification plan

| # | Item | Checks | Depends on |
|---|---|---|---|
| V1 | **SOVA block TB** | Python reference SOVA, bit-exact hard decisions and LLRs; all legacy rates + MCS0–7 puncturing; tail/pad handling | Python reference SOVA |
| V2 | **SOVA in openofdm_rx (single link)** | replaces the Xilinx Viterbi; rerun the existing orx regression (vectors, impair, SNR sweep, len limits, b2b) with no loss vs the Viterbi | V1 |
| V3 | **Combiner TB** | different MCS per link, different scrambler seeds, one link lost, both failing, timeout, back-to-back packets, α scaling | V1 |
| V4 | **Chip dual-link TB** | two peer TX (one per frequency), independent AWGN / fading / CFO per link, **two unrelated ADC/DAC clocks** (different frequencies and ppm offset); end-to-end PSDU + FCS | S2 chip TB, V2, V3 |
| V5 | **PER-vs-SNR curves** | three curves: single link, selection combining (MLO-equivalent), soft combining; AWGN and fading | V4 |

**V5 is the headline result:** the extra dB of soft combining over selection combining is the
differentiator to show externally.

---

## 6. Milestones

1. Python: reference SOVA + post-decoding combiner; PER curves in pure Python (sets the expected gain and α).
2. SOVA RTL IP + V1 — first version in `ip/sova_dec/` (Verilator TB in `ip/sova_dec/tb/`).
3. SOVA in `openofdm_rx`, V2 (single-link drop-in).
4. Resource check on Z045 (one RX chain + SOVA) → keep ZC706 or move to ZCU102.
5. Combiner RTL + V3.
6. Dual-link chip TB (V4), PER curves (V5).
7. Board: dual-FMCOMMS2 BD on ZC706 (second `axi_ad9361`, second-slot constraints, two clock domains,
   second ad9361 in the device tree); cabled bring-up first.
8. Later: RF test set-up, rate adaptation per link, ACK path, CSMA on two channels.
