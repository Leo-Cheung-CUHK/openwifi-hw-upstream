# openwifi-hw — CI runners

Two kinds of runner (FLOW.md §1):

| Stage | Runner | Labels | Needs |
|---|---|---|---|
| S0 | GitHub-hosted `ubuntu-24.04` (`.github/workflows/s0.yml`) | — | nothing; Verilator and uvm-core are built once and cached |
| S1–S4 | self-hosted, on the Windows desktop (`.github/workflows/s1.yml`) | `self-hosted`, `windows`, `vivado` | Windows Vivado 2022.2, ZC706 device licence, Viterbi Decoder evaluation licence, Python 3.10+, Git |
| S5–S6 | the same desktop runner, or a small PC next to the board | `self-hosted`, `windows`, `board` | JTAG (hw_server) and Ethernet to the board |

## 1. S0 on GitHub-hosted runners

`.github/workflows/s0.yml` runs `uvm/scripts/ci_s0.sh` on every push to `uvm-verification` and on
pull requests that touch `uvm/`, `ip/` or `boards/`. The first run builds Verilator (~15–20 min);
later runs restore it and ccache from the Actions cache. The gate itself took about 4 min on a
2-core Linux box with warm ccache; on GitHub with caches about 5 min (2026-11-26, all steps PASS).

Steps of the gate (each prints PASS/FAIL, the table goes to the job summary):

| step | what | pass when |
|---|---|---|
| `prep` | `make prep` regenerates `rtl_wrap/openwifi_core_top.sv` from `system.bd` | no diff to the committed file |
| `lint` | slang elaboration of all 7 TBs | 7/7 |
| `rtlstrict` | slang on the prepared RTL of all 6 IPs without the use-before-declare allowance (xvlog rejects it, Vivado synthesis does not) | 6/6 |
| `xsimpy` | `sim/xsim.py` (the Windows xsim flow) against a fake Vivado: file lists equal the Makefile's for all 7 TBs, Xilinx IP grouping, compile-once, recompile on change | 0 failures |
| `smoke` | Verilator openofdm_tx + `wifi_ref_tx.py` | 20/20 |
| `backpressure` | FIFO-model and 12 periodic hold patterns × 4 frame types | 60/60 |
| `otx` | openofdm_tx UVM regression in Verilator (reg_reset, rate_sweep, random, backpressure) + `check_tx_dumps.py` on the rate_sweep dumps | no UVM_ERROR/FATAL, no assertion failure, 72/72 EVM |
| `golden` | fresh rate_sweep captures vs `vectors/otx_rate_sweep/fixed` | IQ (`rtl_*.txt`) bit-identical; every field of the golden `frame_*.json` equal (fields added later, e.g. seeds, are metadata) |
| `pyrx` | openofdm `decode.py` on the fresh captures — skipped when they are identical to golden (same bits, same decode), `PYRX_FORCE=1` to run it (~20 min) | 72/72 PSDU + FCS |
| `htsig` | short HT-SIG AWGN run, fixed vs upstream capture of frame 0069 | runs; fixed FER ≤ upstream FER |

Run the same gate anywhere: `UVM_SRC=<uvm-core>/src uvm/scripts/ci_s0.sh [steps…]`.

When the RTL changes on purpose (an openofdm_tx fix, a new upstream merge), the `golden` step fails
by design: re-run `otx`, check the new captures with `check_tx_dumps.py` and `py_rx_decode.py`,
then replace `vectors/otx_rate_sweep/fixed/` in the same commit and say why in the message.

## 2. Self-hosted runner on the Windows desktop (native Windows Vivado)

Decided 2026-11-26: the desktop runs the native Windows Vivado 2022.2, no WSL. On Windows the
flow is driven by `uvm/sim/xsim.py` instead of `sim/Makefile` (no bash, make, sed or symlinks
needed); it reads the TB table from the Makefile, so both stay in step, and S0 checks that on
every push (`xsimpy`).

### 2.1 Paths (read this first)

| what | use | why |
|---|---|---|
| checkout | `D:\ow` | no spaces, no `+` (`D:\AI+Openwifi` breaks plusarg-style tools), short |
| build tree | `D:\owb` (`OW_BUILD`) | short (Vivado-generated IP paths hit the 260-character limit), outside the checkout so CI's clean keeps the IP models |
| runner | `D:\r` | its workspace is `D:\r\_work\openwifi-hw-upstream\openwifi-hw-upstream`, still short |
| Vivado | `D:\Xilinx\Vivado\2022.2` (or `C:\Xilinx\...`) | installer default is fine; no spaces |

Also: `git config --global core.longpaths true`, and enable Win32 long paths
(`gpedit` → Computer Configuration → Administrative Templates → System → Filesystem →
"Enable Win32 long paths", or the `LongPathsEnabled` registry value). Neither replaces short
paths: Vivado itself does not use long-path APIs everywhere.

### 2.2 Software

1. **Vivado 2022.2** (Windows, ML Edition or Enterprise), devices: Zynq-7000 (and Zynq
   UltraScale+ RFSoC later). Licences in the Vivado License Manager: the ZC706 device-locked
   licence and the Viterbi Decoder evaluation licence.
2. **Python 3.10+** from python.org, "Add python.exe to PATH" ticked; then
   `python -m pip install numpy` (only the Python checkers need it).
3. **Git for Windows**.
4. Cable drivers are installed with Vivado (`hw_server` for S5/S6).

### 2.3 First manual run

```powershell
git config --global core.longpaths true
git clone -b uvm-verification https://github.com/Leo-Cheung-CUHK/openwifi-hw-upstream D:\ow
cd D:\ow
git submodule update --init --depth 1 ip/openofdm_rx
$env:XILINX_VIVADO = 'D:\Xilinx\Vivado\2022.2'; $env:OW_BUILD = 'D:\owb'
python uvm\sim\xsim.py env                                   # tools, licence env, path warnings
python uvm\sim\xsim.py prep
python uvm\sim\xsim.py run --tb openofdm_tx --test otx_reg_reset_test   # no Xilinx IP, no Viterbi licence
python uvm\sim\xsim.py run --tb openofdm_tx --test otx_rate_sweep_test --plusargs "+TX_DUMP_DIR=D:/owb/dumps"
python uvm\scripts\check_tx_dumps.py D:\owb\dumps            # 72/72 expected, as in Verilator
python uvm\sim\xsim.py xip                                   # Xilinx IP models (Viterbi licence)
python uvm\sim\xsim.py regress
```
`openofdm_tx` is the TB already proven in Verilator, so it separates "xsim/Windows setup
problem" from "TB bring-up problem": get it to PASS first. `--vivado D:/Xilinx/Vivado/2022.2`
can replace `XILINX_VIVADO`. Logs: `D:\owb\xsim\run\<tb>_<test>_<seed>\sim.log`, compile logs
in `D:\owb\xsim\<tb>\`.

### 2.4 Register the runner

GitHub → repository **Settings → Actions → Runners → New self-hosted runner → Windows / x64**.
In PowerShell, run the download commands that page shows inside `D:\r`, then:
```powershell
cd D:\r
.\config.cmd --url https://github.com/Leo-Cheung-CUHK/openwifi-hw-upstream --token <from that page> `
             --name desktop --labels vivado --work _work --runasservice
```
Environment for the jobs: create `D:\r\.env` with
```
XILINX_VIVADO=D:\Xilinx\Vivado\2022.2
OW_BUILD=D:\owb
PYTHONUTF8=1
```
and restart the service (`Restart-Service "actions.runner.*"`). If the service account cannot
see your Python or the Vivado licence, change the service to log on as your user
(services.msc → the runner service → Log On), or run `.\run.cmd` in a terminal instead.
Add the `board` label later, once the ZC706 is attached.

Check: Actions → **S1 (xsim, Windows desktop)** → Run workflow → branch `uvm-verification`,
`what = env`. Then `run` (openofdm_tx), then `xip`, then `regress`.

GitHub only shows "Run workflow" for a `workflow_dispatch` workflow whose file is on the
**default branch**. The fork's default is `master` (it tracks upstream), so either make
`uvm-verification` the default branch (Settings → General → Default branch), or start it from a
terminal: `gh workflow run s1.yml --ref uvm-verification -f what=env` (this also needs the file
on the default branch the first time GitHub registers it). Changing the default branch is the
simple option for this fork.

**Done on the desktop (2026-11-28):** registered as `desktop` (labels self-hosted, windows, x64,
vivado) by `runner_setup.cmd` in `D:\AI_Openwifi`; runner dir `D:\AI_Openwifi\r`, build tree
`D:\AI_Openwifi\build` (`.env` also puts Anaconda first on PATH). It runs `run.cmd` in a console
window (not as a service). Left: default branch → `uvm-verification`.

### 2.5 Security (public repository)

A self-hosted runner executes whatever a workflow tells it to, on the desktop. This repository is
public, so:
* `s1.yml` runs on `workflow_dispatch` only; later stages add `schedule`, never `pull_request`;
* Settings → Actions → General: "Require approval for all external contributors";
* the runner service account should not be an administrator.

### 2.6 Status on the desktop (2026-11-27)

`xsim.py` is tested in S0 against a fake Vivado (file lists, order, grouping, caching). On the
desktop (Windows, Vivado 2022.2, checkout `D:\AI_Openwifi\ow`):
* `openofdm_tx` `otx_reg_reset_test` PASS.
* `openofdm_tx` `otx_rate_sweep_test` with `+OTX_REPLAY=uvm/vectors/otx_rate_sweep/fixed`: PASS
  (9.5 ms simulated, ~9 min wall), `check_tx_dumps.py` 72/72, and `compare_golden.py`
  **72/72 frames bit-identical to the Verilator golden set** — the cross-simulator check.
* Needed on the way: ARCHITECTURE.md findings 7 and 8 (xvlog/xelab), and `iq_agent` calling
  `super.build_phase` (its passive mode was ignored; the driver fought the TB-top `assign` on
  `iqo.valid`, which xsim resolved as a stuck 1).
* Block regression on xsim (2026-11-27 evening, all TBs in parallel, ~16 min wall):

  | TB | result | notes |
  |---|---|---|
  | openofdm_tx | 7/7 | `otx_ampdu_test` after finding 10 |
  | tx_intf | 6/7 | `txi_cts_toself_test` fails on RTL findings E/F, as in Verilator |
  | rx_intf | 5/5 | `rxi_frames_test` after finding 10 |
  | xpu | 8/9 | `xpu_csma_test`: 9 of 16 busy-medium cases off; see below |
  | side_ch | 4/4 | |

  Needed: tx_intf port widths (a5369c9), findings 9 and 10. Open: in `xpu_csma_test` every
  measured backoff fits the queue's CW, but on queues 1–3 it often does not match the
  `num_slot_random` the TB samples at `backoff_done` (shorter by 2–4 slots, once longer) —
  needs a waveform side by side with Verilator.
* openofdm_rx on xsim (2026-11-27 night, first run in any simulator): `xsim.py xip` works with
  the Viterbi evaluation licence (fixes in `gen_xilinx_ip_sim.tcl`: compile order per IP, `.coe/.mif`
  to `xip_data.txt`); the sim copy of the RTL zero-extends `min_signal_len_th` and the byte-padded
  `div_gen_csi_over_nova` tdata (`prep_rtl.py` SIM_PATCHES); the init sequence sets the watchdog
  DC threshold (`POWER_THRES[23:16]` = 64; 0 held the receiver in reset). Results so far:
  `orx_reg_reset_test` PASS; vectors, impairments, SNR sweep and back-to-back decode and pass
  frame by frame; `orx_len_limits_test` fails on RTL finding K (length watchdog masked).
  `regress --jobs 6` runs the six tests side by side (starts staggered 15 s: `xsim -R` shares
  `xsim_script.tcl` per snapshot).
* Not run yet on xsim: chip.
