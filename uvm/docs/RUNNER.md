# openwifi-hw — CI runners

Two kinds of runner (FLOW.md §1):

| Stage | Runner | Labels | Needs |
|---|---|---|---|
| S0 | GitHub-hosted `ubuntu-24.04` (`.github/workflows/s0.yml`) | — | nothing; Verilator and uvm-core are built once and cached |
| S1–S4 | self-hosted, on the desktop | `self-hosted`, `linux`, `vivado` | Vivado 2022.2, ZC706 device licence, Viterbi Decoder evaluation licence |
| S5–S6 | the same desktop runner, or a small PC next to the board | `self-hosted`, `linux`, `board` | JTAG (hw_server) and Ethernet to the board |

## 1. S0 on GitHub-hosted runners

`.github/workflows/s0.yml` runs `uvm/scripts/ci_s0.sh` on every push to `uvm-verification` and on
pull requests that touch `uvm/`, `ip/` or `boards/`. The first run builds Verilator (~15–20 min);
later runs restore it and ccache from the Actions cache. The gate itself took about 4 min on a
2-core Linux box with warm ccache (2026-11-26, all 8 steps PASS).

Steps of the gate (each prints PASS/FAIL, the table goes to the job summary):

| step | what | pass when |
|---|---|---|
| `prep` | `make prep` regenerates `rtl_wrap/openwifi_core_top.sv` from `system.bd` | no diff to the committed file |
| `lint` | slang elaboration of all 7 TBs | 7/7 |
| `smoke` | Verilator openofdm_tx + `wifi_ref_tx.py` | 20/20 |
| `backpressure` | FIFO-model and 12 periodic hold patterns × 4 frame types | 60/60 |
| `otx` | openofdm_tx UVM regression in Verilator (reg_reset, rate_sweep, random, backpressure) + `check_tx_dumps.py` on the rate_sweep dumps | no UVM_ERROR/FATAL, no assertion failure, 72/72 EVM |
| `golden` | fresh rate_sweep captures vs `vectors/otx_rate_sweep/fixed` | bit-identical |
| `pyrx` | openofdm `decode.py` on the fresh captures — skipped when they are identical to golden (same bits, same decode), `PYRX_FORCE=1` to run it (~20 min) | 72/72 PSDU + FCS |
| `htsig` | short HT-SIG AWGN run, fixed vs upstream capture of frame 0069 | runs; fixed FER ≤ upstream FER |

Run the same gate anywhere: `UVM_SRC=<uvm-core>/src uvm/scripts/ci_s0.sh [steps…]`.

When the RTL changes on purpose (an openofdm_tx fix, a new upstream merge), the `golden` step fails
by design: re-run `otx`, check the new captures with `check_tx_dumps.py` and `py_rx_decode.py`,
then replace `vectors/otx_rate_sweep/fixed/` in the same commit and say why in the message.

## 2. Self-hosted runner on the Windows desktop

The scripts and the Makefile are bash/GNU make, so the runner should be a Linux environment.
Recommended: **WSL2 Ubuntu 22.04 with the Linux build of Vivado 2022.2** inside it, and the
JTAG cable served by `hw_server` on the Windows side. Alternatives are listed in §2.5.

### 2.1 WSL2

```powershell
wsl --install -d Ubuntu-22.04
```
In `%UserProfile%\.wslconfig`: give WSL most of the RAM (Vivado implementation of the 7z045 wants
16 GB or more) and enable mirrored networking so WSL reaches `hw_server` on `localhost`:
```ini
[wsl2]
memory=24GB
processors=8
networkingMode=mirrored
```
In Ubuntu, `/etc/wsl.conf` (so the runner can run as a systemd service):
```ini
[boot]
systemd=true
```
Then `wsl --shutdown` and reopen. Keep the checkout and the build tree in the Linux filesystem
(`~/…`), not under `/mnt/d/…`: builds on `/mnt` are several times slower.

### 2.2 Vivado 2022.2 inside WSL

Install the Linux edition (2022.2 lists Ubuntu 22.04 as supported) into `/tools/Xilinx`, plus
`sudo apt install libtinfo5 libncurses5 make git python3-pip`. Add the licences
(`XILINXD_LICENSE_FILE` or the Vivado License Manager): the ZC706 device-locked licence and the
Viterbi Decoder evaluation licence. Check:
```bash
source /tools/Xilinx/Vivado/2022.2/settings64.sh
vivado -version
cd openwifi-hw-upstream/uvm/sim && make xip SIM=xsim     # needs the Viterbi licence
```

### 2.3 Register the runner

GitHub → repository **Settings → Actions → Runners → New self-hosted runner → Linux / x64**.
Run the download and `config.sh` commands that page shows, inside WSL, with:
```bash
./config.sh --url https://github.com/Leo-Cheung-CUHK/openwifi-hw-upstream --token <from that page> \
            --name desktop-wsl --labels vivado --work _work
sudo ./svc.sh install && sudo ./svc.sh start
```
Add the `board` label later (Settings → Runners → the runner → labels) once the ZC706 is attached.
The runner service needs Vivado on its PATH: put `source /tools/Xilinx/Vivado/2022.2/settings64.sh`
in the job steps (S1+ workflows do this), not only in `~/.bashrc`.

### 2.4 Security (public repository)

A self-hosted runner executes whatever a workflow tells it to, on the desktop. This repository is
public, so:
* S1–S6 workflows run on `push` to your own branches, `schedule` and `workflow_dispatch` only —
  never on `pull_request` from forks;
* Settings → Actions → General: "Require approval for all external contributors";
* run the service as a normal user without sudo rights it does not need.

### 2.5 JTAG and alternatives

* **hw_server on Windows (recommended).** Install the Vivado Lab Edition (or the cable drivers) on
  Windows, run `hw_server`; Vivado in WSL connects with `open_hw_target -url localhost:3121` thanks
  to mirrored networking. No USB passthrough needed.
* USB passthrough with `usbipd-win` into WSL, hw_server inside WSL. Works, but the cable has to be
  re-attached after every replug or reboot.
* Native Windows Vivado + runner on Windows with Git Bash/MSYS2 make. Possible, but `Makefile`,
  `xip_compile.sh` and the smoke scripts would need porting; not recommended.
* Open decision (FLOW.md §7): a separate small PC next to the board as the `board` runner.
