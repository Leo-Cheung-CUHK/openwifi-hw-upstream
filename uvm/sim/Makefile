# openwifi-hw UVM -- build & run
#
#   make prep                                  wrapper + per-IP RTL tree (once, and after RTL/BD changes)
#   make xip                                   Xilinx IP sim models for openofdm_rx (needs Vivado + Viterbi licence)
#   make run TB=openofdm_tx TEST=otx_random_test [SEED=7] [PLUSARGS="+N_PKT=50"]
#   make regress                               every TB with its default test list
#   make lint                                  elaborate every TB with slang (pip install pyslang), no simulator needed
#   make smoke                                 Verilator + Python reference check of openofdm_tx (no licence)
#
#   make run TB=openofdm_rx VIT=sova ...       openofdm_rx with the open-source SOVA decoder (ip/sova_dec)
#                                              instead of the Xilinx Viterbi IP; `make xip VIT=sova` skips
#                                              the Viterbi IP, so no Viterbi licence is needed at all
#
# TB = openofdm_tx | openofdm_rx | tx_intf | rx_intf | xpu | side_ch | chip
# SIM = xsim (Vivado 2022.2, UVM 1.2 built in) | questa | vcs | xcelium
#     | verilator (>= 5.05x built from source, + z3 solver, UVM_SRC=<uvm-core/src>; no licence;
#       TBs without Xilinx IP only: openofdm_tx today, the others once XPM sources are available)

OW_HW          ?= $(abspath ../..)
OW_UVM         := $(abspath ..)
# block design used for the chip wrapper; first hardware target is ZC706 + FMCOMMS2/3/4
# (other boards: zcu102_fmcs2 + PART=xczu9eg-ffvb1156-2-e, rfsoc4x2 once its board dir exists)
BOARD          ?= zc706_fmcs2
# Zynq-7045 on ZC706; selects the 'zynq' (7-series) Xilinx IP variants
PART           ?= xc7z045ffg900-2
SIM            ?= xsim
TB             ?= openofdm_tx
SEED           ?= 1
VERB           ?= UVM_MEDIUM
# must match boards/openwifi.tcl for the build you verify
NUM_CLK_PER_US ?= 100
PLUSARGS       ?=
BUILD          := $(OW_UVM)/build
VARIANT        ?=
RUN             = $(BUILD)/run$(VARIANT)/$(TB)_$(TEST)_$(SEED)
XILINX_VIVADO  ?= $(shell v=$$(which vivado 2>/dev/null) && dirname $$(dirname $$v))
# Viterbi decoder inside openofdm_rx: xilinx (viterbi_v7_0 IP) | sova (ip/sova_dec, same module
# name and ports + LLR output; BR-SOVA, EXTRA_DEFS=+define+SOVA_HR for HR-SOVA)
VIT            ?= xilinx
SOVA_SRC       := $(OW_HW)/ip/sova_dec/src/sova_dec.sv $(OW_HW)/ip/sova_dec/src/viterbi_v7_0_sova.sv
# slang lint only: path to uvm-core/src
UVM_SRC        ?= 

# ---------------------------------------------------------------- per-TB description
V := $(OW_UVM)/verif
TOP_openofdm_tx := tb_openofdm_tx
IPS_openofdm_tx := openofdm_tx
XIP_openofdm_tx := 0
SRC_openofdm_tx  := $(V)/block/openofdm_tx/openofdm_tx_tb_pkg.sv $(V)/block/openofdm_tx/tb_openofdm_tx.sv
TESTS_openofdm_tx := otx_reg_reset_test otx_rate_sweep_test otx_random_test otx_backpressure_test \
                     otx_scrambler_seed_test otx_ampdu_test otx_reset_midpacket_test

TOP_openofdm_rx := tb_openofdm_rx
IPS_openofdm_rx := openofdm_rx
XIP_openofdm_rx := 1
SRC_openofdm_rx  := $(V)/block/openofdm_rx/openofdm_rx_tb_pkg.sv $(V)/block/openofdm_rx/tb_openofdm_rx.sv
TESTS_openofdm_rx := orx_reg_reset_test orx_vectors_test orx_impair_test \
                     orx_snr_sweep_test orx_len_limits_test orx_b2b_test

TOP_tx_intf := tb_tx_intf
IPS_tx_intf := tx_intf
XIP_tx_intf := 0
SRC_tx_intf      := $(V)/block/tx_intf/xpu_stub_ctl_if.sv $(V)/block/tx_intf/xpu_tx_stub.sv $(V)/block/tx_intf/tx_intf_tb_pkg.sv $(V)/block/tx_intf/tb_tx_intf.sv
TESTS_tx_intf    := txi_basic_test txi_stress_test txi_queues_test txi_ampdu_test txi_cts_toself_test \
                    txi_arbitrary_iq_test txi_ant_test

TOP_rx_intf := tb_rx_intf
IPS_rx_intf := rx_intf
XIP_rx_intf := 0
SRC_rx_intf      := $(V)/block/rx_intf/rx_side_if.sv $(V)/block/rx_intf/rx_intf_tb_pkg.sv $(V)/block/rx_intf/tb_rx_intf.sv
TESTS_rx_intf    := rxi_adc_path_test rxi_frames_test rxi_dma_stall_test rxi_loopback_src_test rxi_mute_ant_test

TOP_xpu := tb_xpu
IPS_xpu := xpu
XIP_xpu := 0
SRC_xpu          := $(V)/block/xpu/xpu_tx_side_if.sv $(V)/block/xpu/xpu_tb_pkg.sv $(V)/block/xpu/tb_xpu.sv
TESTS_xpu        := xpu_tsf_test xpu_ack_test xpu_csma_test xpu_retrans_test xpu_filter_test xpu_cts_test \
                    xpu_blkack_test xpu_rssi_test xpu_slice_test

TOP_side_ch := tb_side_ch
IPS_side_ch := side_ch
XIP_side_ch := 0
SRC_side_ch      := $(V)/block/side_ch/side_ch_side_if.sv $(V)/block/side_ch/side_ch_tb_pkg.sv $(V)/block/side_ch/tb_side_ch.sv
TESTS_side_ch    := sch_csi_test sch_match_test sch_iq_capture_test sch_num_eq_test

TOP_chip := tb_chip
IPS_chip := openofdm_rx openofdm_tx rx_intf tx_intf xpu side_ch
XIP_chip := 1
SRC_chip         := $(OW_UVM)/rtl_wrap/axil_decoder.sv $(OW_UVM)/rtl_wrap/openwifi_core_top.sv \
                    $(V)/chip/dac_to_peer_rx.sv $(V)/chip/chip_tb_pkg.sv $(V)/chip/tb_chip.sv
TESTS_chip       := chip_reg_test chip_tx_test chip_rx_test chip_ack_test chip_mixed_test \
                    chip_retrans_test chip_tx_ack_test chip_filter_test chip_loopback_test chip_sidech_test \
                    chip_rx_impair_test chip_stress_test
# chip P1 tests, also run per clock variant by regress-clk (CHP-14)
TESTS_chip_p1    := chip_reg_test chip_tx_test chip_rx_test chip_ack_test chip_mixed_test \
                    chip_retrans_test chip_tx_ack_test chip_loopback_test

# per-test default plusargs (used by run/regress here and by xsim.py); PLUSARGS adds to them
ARGS_orx_vectors_test     := +RX_VEC_LIST=$(BUILD)/lists/rx_simulated.list
ARGS_orx_impair_test      := +RX_VEC_LIST=$(BUILD)/lists/rx_generated.list
ARGS_orx_snr_sweep_test   := +RX_VEC_LIST=$(BUILD)/lists/rx_clean.list
ARGS_orx_len_limits_test  := +RX_VEC_LIST=$(BUILD)/lists/rx_craft.list
ARGS_orx_b2b_test         := +RX_VEC_LIST=$(BUILD)/lists/rx_clean.list +IQ_NOISE=4

TOP   = $(strip $(TOP_$(TB)))
IPS   = $(IPS_$(TB))
XIP   = $(strip $(XIP_$(TB)))
TEST  ?= $(firstword $(TESTS_$(TB)))

XPM_SRC = $(XILINX_VIVADO)/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv \
          $(XILINX_VIVADO)/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv \
          $(XILINX_VIVADO)/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv
GLBL    = $(XILINX_VIVADO)/data/verilog/src/glbl.v
# no Vivado (e.g. Verilator in CI): behavioural models of the XPM primitives the RTL uses
ifeq ($(strip $(XILINX_VIVADO)),)
XPM_SRC = $(OW_UVM)/sim/xpm_models/xpm_models.sv
endif
INCS    = +incdir+$(OW_UVM)/sim/gen_inc +incdir+$(OW_HW)/ip
EXTRA_DEFS ?=
DEFS    = +define+NUM_CLK_PER_US=$(NUM_CLK_PER_US) $(EXTRA_DEFS)
COMMON  = $(shell sed -e '/^\/\//d' -e 's#$${OW_UVM}#$(OW_UVM)#' $(V)/common/common.f)
RTL_F   = $(foreach i,$(IPS),-f $(BUILD)/rtl/$(i).f) \
          $(if $(and $(filter sova,$(VIT)),$(filter openofdm_rx,$(IPS))),$(SOVA_SRC))
XIP_DIR = $(BUILD)/xip
# VIT=sova: the Xilinx IP list without the Viterbi core (works with a full or a sova-only xip build),
# and separate model/run directories so both decoders can be kept side by side
ifeq ($(VIT),sova)
override VARIANT := $(VARIANT)_sova
XIP_LIST   = $(RUN)/xip_sources_sova.txt
XIP_FILTER = grep -iv viterbi $(XIP_DIR)/xip_sources.txt > $(XIP_LIST);
else
XIP_LIST   = $(XIP_DIR)/xip_sources.txt
XIP_FILTER =
endif

.PHONY: prep xip compile run regress regress-clk lint smoke rxlists clean

# vector lists for orx_vectors_test (+RX_VEC_LIST=...)
rxlists:
	mkdir -p $(BUILD)/lists
	ls $(OW_HW)/ip/openofdm_rx/testing_inputs/simulated/*.txt | grep -v _Fc_input > $(BUILD)/lists/rx_simulated.list
	ls $(OW_HW)/ip/openofdm_rx/testing_inputs/conducted/*.txt > $(BUILD)/lists/rx_conducted.list
	python3 $(OW_UVM)/scripts/gen_rx_vectors.py --out $(BUILD)/rxgen -n 50 --snr 30 --cfo-hz 20e3
	cp $(BUILD)/rxgen/list.txt $(BUILD)/lists/rx_generated.list
	python3 $(OW_UVM)/scripts/gen_rx_vectors.py --out $(BUILD)/rxclean -n 24 --seed 7 --max-len 400
	cp $(BUILD)/rxclean/list.txt $(BUILD)/lists/rx_clean.list
	python3 $(OW_UVM)/scripts/gen_rx_vectors.py --out $(BUILD)/rxcraft --craft
	cp $(BUILD)/rxcraft/list.txt $(BUILD)/lists/rx_craft.list
# rx_clean.list : clean generated frames, for orx_snr_sweep_test (AWGN added in the TB) and orx_b2b_test
# rx_craft.list : header-limit vectors (.rej / .exp), for orx_len_limits_test

prep:
	python3 $(OW_UVM)/scripts/gen_core_top.py --hw $(OW_HW) --board $(BOARD) -o $(OW_UVM)/rtl_wrap/openwifi_core_top.sv
	python3 $(OW_UVM)/scripts/prep_rtl.py --hw $(OW_HW) --out $(BUILD)/rtl

xip:
	OW_VIT=$(VIT) vivado -mode batch -nojournal -nolog -source $(OW_UVM)/scripts/gen_xilinx_ip_sim.tcl \
	  -tclargs $(OW_HW) $(XIP_DIR) $(PART) $(SIM) $(LIBMAP)

# ---------------------------------------------------------------- xsim
ifeq ($(SIM),xsim)
compile:
	mkdir -p $(RUN) && cd $(RUN) && \
	if [ "$(XIP)" = "1" ]; then $(XIP_FILTER) $(OW_UVM)/sim/xip_compile.sh xsim $(XIP_LIST); fi && \
	xvlog -sv -L uvm $(INCS) $(DEFS) $(XPM_SRC) $(GLBL) && \
	xvlog -sv -L uvm $(INCS) $(DEFS) $(COMMON) $(RTL_F) $(SRC_$(TB)) && \
	xelab -debug typical -L uvm -L xpm $$( [ "$(XIP)" = "1" ] && sed 's/ .*//' $(XIP_LIST) | sort -u | sed 's/^/-L /') \
	  -timescale 1ns/1ps work.$(TOP) work.glbl -s $(TOP)_snap
run: compile
	cd $(RUN) && ln -sf $(OW_HW)/ip/openofdm_tx/src/icmem_*.mem . && \
	xsim $(TOP)_snap -R -sv_seed $(SEED) -testplusarg UVM_TESTNAME=$(TEST) -testplusarg UVM_VERBOSITY=$(VERB) \
	  $(foreach p,$(ARGS_$(TEST)) $(PLUSARGS),-testplusarg $(patsubst +%,%,$(p))) | tee sim.log
endif

# ---------------------------------------------------------------- Questa
ifeq ($(SIM),questa)
compile:
	mkdir -p $(RUN) && cd $(RUN) && vlib work && \
	if [ "$(XIP)" = "1" ]; then $(XIP_FILTER) $(OW_UVM)/sim/xip_compile.sh questa $(XIP_LIST); fi && \
	vlog -sv -mfcu $(INCS) $(DEFS) $(XPM_SRC) $(GLBL) $(COMMON) $(RTL_F) $(SRC_$(TB)) -timescale 1ns/1ps
run: compile
	cd $(RUN) && ln -sf $(OW_HW)/ip/openofdm_tx/src/icmem_*.mem . && \
	vsim -c -sv_seed $(SEED) $(TOP) glbl $$( [ "$(XIP)" = "1" ] && sed 's/ .*//' $(XIP_LIST) | sort -u | sed 's/^/-L /') \
	  +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) $(ARGS_$(TEST)) $(PLUSARGS) -do "run -all; quit -f" | tee sim.log
endif

# ---------------------------------------------------------------- VCS
ifeq ($(SIM),vcs)
compile:
	mkdir -p $(RUN) && cd $(RUN) && \
	if [ "$(XIP)" = "1" ]; then $(XIP_FILTER) $(OW_UVM)/sim/xip_compile.sh vcs $(XIP_LIST); fi && \
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps $(INCS) $(DEFS) $(XPM_SRC) $(GLBL) \
	  $(COMMON) $(RTL_F) $(SRC_$(TB)) -top $(TOP) -top glbl -o simv
run: compile
	cd $(RUN) && ln -sf $(OW_HW)/ip/openofdm_tx/src/icmem_*.mem . && \
	./simv +ntb_random_seed=$(SEED) +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) $(ARGS_$(TEST)) $(PLUSARGS) | tee sim.log
endif

# ---------------------------------------------------------------- Xcelium
ifeq ($(SIM),xcelium)
run:
	mkdir -p $(RUN) && cd $(RUN) && ln -sf $(OW_HW)/ip/openofdm_tx/src/icmem_*.mem . && \
	xrun -64bit -uvm -timescale 1ns/1ps $(INCS) $(DEFS) $(XPM_SRC) $(GLBL) $(COMMON) $(RTL_F) $(SRC_$(TB)) \
	  -top $(TOP) -top glbl -svseed $(SEED) +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) $(ARGS_$(TEST)) $(PLUSARGS) | tee sim.log
endif

# ---------------------------------------------------------------- Verilator (open source)
VERILATOR ?= verilator
# -Wno-USEBEFOREDECL exists only in Verilator > 5.054; pass it when the binary knows it
VLT_WNO_UBD = $(shell $(VERILATOR) -Wno-USEBEFOREDECL --version >/dev/null 2>&1 && echo -Wno-USEBEFOREDECL)
# One model per TB, shared by all its tests and seeds: Verilator skips regeneration when its
# inputs are unchanged (--skip-identical, the default), so only the first test of a TB compiles.
# The UVM C++ needs ~2.5 GB per compiler job: lower VLT_JOBS on small machines.
VLT_DIR  = $(BUILD)/vlt$(VARIANT)/$(TB)
VLT_JOBS ?= $(shell nproc)
ifeq ($(SIM),verilator)
compile:
	mkdir -p $(VLT_DIR) && cd $(VLT_DIR) && \
	$(VERILATOR) --binary --timing -j $(VLT_JOBS) -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH $(VLT_WNO_UBD) \
	  --top-module $(TOP) +define+UVM_NO_DPI $(DEFS) +incdir+$(UVM_SRC) $(INCS) \
	  $$( [ "$(XIP)" = "1" -o "$(TB)" != "openofdm_tx" ] && echo $(XPM_SRC) ) \
	  $(UVM_SRC)/uvm_pkg.sv $(COMMON) $(RTL_F) $(SRC_$(TB)) -o simv > build.log 2>&1 || (grep %Error build.log | head; exit 1)
run: compile
	mkdir -p $(RUN) && cd $(RUN) && ln -sf $(OW_HW)/ip/openofdm_tx/src/icmem_*.mem . && \
	$(VLT_DIR)/obj_dir/simv +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) +verilator+seed+$(SEED) $(ARGS_$(TEST)) $(PLUSARGS) | tee sim.log
endif

# ---------------------------------------------------------------- regression
regress: rxlists
	@for tb in openofdm_tx openofdm_rx tx_intf rx_intf xpu side_ch chip; do \
	  for t in $$($(MAKE) -s print-tests TB=$$tb); do \
	    $(MAKE) run TB=$$tb TEST=$$t SEED=$(SEED) > /dev/null 2>&1; \
	    log=$(BUILD)/run/$${tb}_$${t}_$(SEED)/sim.log; \
	    if grep -q "UVM_ERROR :    0" $$log && grep -q "UVM_FATAL :    0" $$log; then echo "PASS $$tb $$t"; else echo "FAIL $$tb $$t ($$log)"; fi; \
	  done; done
# CHP-14: chip P1 tests at every core clock the boards build with (zc706/adrv9361: 100, 200;
# zcu102: 240). VARIANT keeps each clock's models and runs in their own directories.
CLK_VARIANTS ?= 100 200
regress-clk:
	@for c in $(CLK_VARIANTS); do \
	  for t in $(TESTS_chip_p1); do \
	    $(MAKE) run TB=chip TEST=$$t SEED=$(SEED) NUM_CLK_PER_US=$$c VARIANT=_clk$$c > /dev/null 2>&1; \
	    log=$(BUILD)/run_clk$$c/chip_$${t}_$(SEED)/sim.log; \
	    if grep -q "UVM_ERROR :    0" $$log && grep -q "UVM_FATAL :    0" $$log; then echo "PASS clk$$c $$t"; else echo "FAIL clk$$c $$t ($$log)"; fi; \
	  done; done
print-tests:
	@echo $(TESTS_$(TB))

# ---------------------------------------------------------------- no-simulator checks
lint:
	@for tb in openofdm_tx openofdm_rx tx_intf rx_intf xpu side_ch chip; do \
	  echo "== $$tb"; $(MAKE) -s lint-one TB=$$tb; done
lint-one:
	@python3 $(OW_UVM)/scripts/slang_lint.py $(TOP) +incdir+$(UVM_SRC) $(INCS) $(DEFS) \
	  $(UVM_SRC)/uvm_pkg.sv $(COMMON) $(RTL_F) $(SRC_$(TB))

smoke:
	OPENWIFI_HW=$(OW_HW) WORK=$(BUILD)/verilator_tx_smoke $(OW_UVM)/sim/verilator_tx_smoke/run.sh

clean:
	rm -rf $(BUILD)/run
