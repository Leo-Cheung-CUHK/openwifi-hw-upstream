# openwifi-hw UVM environment

Chip-level and block-level UVM verification for [open-sdr/openwifi-hw](https://github.com/open-sdr/openwifi-hw)
(802.11a/g/n PL: tx_intf, openofdm_tx, rx_intf, openofdm_rx, xpu, side_ch).
Design and rationale: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). Flow from UVM to FPGA build, netlist sim and on-board emulation: [docs/FLOW.md](docs/FLOW.md). Test plan: [docs/test_plan.xlsx](docs/test_plan.xlsx). CI and runners: [docs/RUNNER.md](docs/RUNNER.md).

```
rtl_wrap/            openwifi_core_top.sv (generated from system.bd), axil_decoder.sv
verif/common/        shared VIP: axil, axis, iq, phy_rx, phy_tx, irq, wifi model, RAL, driver-replay sequences
verif/block/<ip>/    one UVM TB per IP (tb_<ip>.sv + <ip>_tb_pkg.sv)
verif/chip/          chip TB: DUT + peer station (second openofdm_tx/rx) + scoreboards
scripts/             gen_core_top.py, prep_rtl.py, wifi_ref_tx.py (802.11 reference TX),
                     gen_rx_vectors.py, check_tx_dumps.py, gen_xilinx_ip_sim.tcl, slang_lint.py,
                     ci_s0.sh (S0 gate, run by .github/workflows/s0.yml)
sim/                 Makefile (xsim / questa / vcs / xcelium), xsim.py (xsim flow for Windows + Linux),
                     gen_inc/ (FPGA-flow headers),
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
make xip   SIM=xsim                                # once, for openofdm_rx and chip (PART defaults to ZC706's xc7z045ffg900-2)
make run   TB=chip TEST=chip_ack_test SIM=xsim
```

Windows (native Vivado, no make/bash): `uvm/sim/xsim.py` runs the same xsim flow, see
[docs/RUNNER.md](docs/RUNNER.md) §2.3. Use a checkout path without spaces or `+`, e.g. `D:\ow`:
```powershell
python uvm\sim\xsim.py --vivado D:/Xilinx/Vivado/2022.2 env
python uvm\sim\xsim.py prep
python uvm\sim\xsim.py run --tb openofdm_tx --test otx_rate_sweep_test
python uvm\sim\xsim.py xip ; python uvm\sim\xsim.py regress
```

Built and checked against upstream `fa6c896` (the base of this branch), `ip/openofdm_rx` @ `2bb3ad1`.
After merging newer upstream RTL, re-run `make prep` and commit the regenerated `rtl_wrap/openwifi_core_top.sv`.

Status (2026-11-28): S0 CI runs on every push. All six block TBs run on Windows Vivado 2022.2 xsim
(openofdm_rx with the Xilinx IP models); RTL findings A–L are fixed on this branch (K in the sim
copy of the openofdm_rx submodule, with an upstream patch). The chip TB (S2) is next. Full,
current status: [docs/STATUS.md](docs/STATUS.md).
