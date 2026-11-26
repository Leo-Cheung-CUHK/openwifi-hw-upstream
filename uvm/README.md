# openwifi-hw UVM environment

Chip-level and block-level UVM verification for [open-sdr/openwifi-hw](https://github.com/open-sdr/openwifi-hw)
(802.11a/g/n PL: tx_intf, openofdm_tx, rx_intf, openofdm_rx, xpu, side_ch).
Design and rationale: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Flow from UVM to FPGA build, netlist sim and on-board emulation: [docs/FLOW.md](docs/FLOW.md). Test plan: [docs/test_plan.xlsx](docs/test_plan.xlsx).

```
rtl_wrap/            openwifi_core_top.sv (generated from system.bd), axil_decoder.sv
verif/common/        shared VIP: axil, axis, iq, phy_rx, phy_tx, irq, wifi model, RAL, driver-replay sequences
verif/block/<ip>/    one UVM TB per IP (tb_<ip>.sv + <ip>_tb_pkg.sv)
verif/chip/          chip TB: DUT + peer station (second openofdm_tx/rx) + scoreboards
scripts/             gen_core_top.py, prep_rtl.py, wifi_ref_tx.py (802.11 reference TX),
                     gen_rx_vectors.py, check_tx_dumps.py, gen_xilinx_ip_sim.tcl, slang_lint.py
sim/                 Makefile (xsim / questa / vcs / xcelium), gen_inc/ (FPGA-flow headers),
                     verilator_tx_smoke/ (no-licence PHY check + back-pressure repro)
```

Quick start (this folder lives in the `uvm-verification` branch of the openwifi-hw fork;
`OW_HW` defaults to the repository root)
```bash
git clone -b uvm-verification https://github.com/Leo-Cheung-CUHK/openwifi-hw-upstream
cd openwifi-hw-upstream && git submodule update --init ip/openofdm_rx   # adi-hdl not needed for sim
cd uvm/sim
make prep                                          # regenerate wrapper from system.bd + per-IP RTL tree
make smoke                                         # Verilator, no licence
make run   TB=openofdm_tx TEST=otx_rate_sweep_test SIM=xsim
make xip   SIM=xsim PART=xczu48dr-ffvg1517-2-e     # once, for openofdm_rx and chip
make run   TB=chip TEST=chip_ack_test SIM=xsim
```

Built and checked against upstream `fa6c896` (the base of this branch), `ip/openofdm_rx` @ `2bb3ad1`.
After merging newer upstream RTL, re-run `make prep` and commit the regenerated `rtl_wrap/openwifi_core_top.sv`.

Status: all TBs elaborate cleanly (slang + UVM). The openofdm_tx UVM regression passes in Verilator
after fixing RTL bugs A–D. Its captures decode with openofdm's Python receiver. The other TBs need
xsim with the Xilinx IP models (see ARCHITECTURE.md §9 and FLOW.md).
