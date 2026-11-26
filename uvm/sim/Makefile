# openwifi-hw UVM -- build & run
#
#   make prep                                  wrapper + per-IP RTL tree (once, and after RTL/BD changes)
#   make xip                                   Xilinx IP sim models for openofdm_rx (needs Vivado + Viterbi licence)
#   make run TB=openofdm_tx TEST=otx_random_test [SEED=7] [PLUSARGS="+N_PKT=50"]
#   make regress                               every TB with its default test list
#   make lint                                  elaborate every TB with slang (pip install pyslang), no simulator needed
#   make smoke                                 Verilator + Python reference check of openofdm_tx (no licence)
#
# TB = openofdm_tx | openofdm_rx | tx_intf | rx_intf | xpu | side_ch | chip
# SIM = xsim (Vivado 2022.2, UVM 1.2 built in) | questa | vcs | xcelium

OW_HW          ?= $(abspath ../..)
OW_UVM         := $(abspath ..)
# block design used for the chip wrapper (rfsoc4x2 once its board dir is available)
BOARD          ?= zcu102_fmcs2
# RFSoC4x2; selects the zynquplus Xilinx IP variants
PART           ?= xczu48dr-ffvg1517-2-e
SIM            ?= xsim
TB             ?= openofdm_tx
SEED           ?= 1
VERB           ?= UVM_MEDIUM
# must match boards/openwifi.tcl for the build you verify
NUM_CLK_PER_US ?= 100
PLUSARGS       ?=
BUILD          := $(OW_UVM)/build
RUN             = $(BUILD)/run/$(TB)_$(TEST)_$(SEED)
XILINX_VIVADO  ?= $(shell dirname $$(dirname $$(which vivado 2>/dev/null)) 2>/dev/null)
# slang lint only: path to uvm-core/src
UVM_SRC        ?= 

# ---------------------------------------------------------------- per-TB description
V := $(OW_UVM)/verif
TOP_openofdm_tx := tb_openofdm_tx
IPS_openofdm_tx := openofdm_tx
XIP_openofdm_tx := 0
SRC_openofdm_tx  := $(V)/block/openofdm_tx/openofdm_tx_tb_pkg.sv $(V)/block/openofdm_tx/tb_openofdm_tx.sv
TESTS_openofdm_tx := otx_reg_reset_test otx_rate_sweep_test otx_random_test otx_backpressure_test

TOP_openofdm_rx := tb_openofdm_rx
IPS_openofdm_rx := openofdm_rx
XIP_openofdm_rx := 1
SRC_openofdm_rx  := $(V)/block/openofdm_rx/openofdm_rx_tb_pkg.sv $(V)/block/openofdm_rx/tb_openofdm_rx.sv
TESTS_openofdm_rx := orx_reg_reset_test orx_vectors_test orx_impair_test

TOP_tx_intf := tb_tx_intf
IPS_tx_intf := tx_intf
XIP_tx_intf := 0
SRC_tx_intf      := $(V)/block/tx_intf/xpu_tx_stub.sv $(V)/block/tx_intf/tx_intf_tb_pkg.sv $(V)/block/tx_intf/tb_tx_intf.sv
TESTS_tx_intf    := txi_basic_test txi_stress_test

TOP_rx_intf := tb_rx_intf
IPS_rx_intf := rx_intf
XIP_rx_intf := 0
SRC_rx_intf      := $(V)/block/rx_intf/rx_side_if.sv $(V)/block/rx_intf/rx_intf_tb_pkg.sv $(V)/block/rx_intf/tb_rx_intf.sv
TESTS_rx_intf    := rxi_adc_path_test rxi_frames_test

TOP_xpu := tb_xpu
IPS_xpu := xpu
XIP_xpu := 0
SRC_xpu          := $(V)/block/xpu/xpu_tx_side_if.sv $(V)/block/xpu/xpu_tb_pkg.sv $(V)/block/xpu/tb_xpu.sv
TESTS_xpu        := xpu_tsf_test xpu_ack_test

TOP_side_ch := tb_side_ch
IPS_side_ch := side_ch
XIP_side_ch := 0
SRC_side_ch      := $(V)/block/side_ch/side_ch_side_if.sv $(V)/block/side_ch/side_ch_tb_pkg.sv $(V)/block/side_ch/tb_side_ch.sv
TESTS_side_ch    := sch_csi_test

TOP_chip := tb_chip
IPS_chip := openofdm_rx openofdm_tx rx_intf tx_intf xpu side_ch
XIP_chip := 1
SRC_chip         := $(OW_UVM)/rtl_wrap/axil_decoder.sv $(OW_UVM)/rtl_wrap/openwifi_core_top.sv \
                    $(V)/chip/dac_to_peer_rx.sv $(V)/chip/chip_tb_pkg.sv $(V)/chip/tb_chip.sv
TESTS_chip       := chip_reg_test chip_tx_test chip_rx_test chip_ack_test chip_mixed_test

TOP   = $(strip $(TOP_$(TB)))
IPS   = $(IPS_$(TB))
XIP   = $(strip $(XIP_$(TB)))
TEST  ?= $(firstword $(TESTS_$(TB)))

XPM_SRC = $(XILINX_VIVADO)/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv \
          $(XILINX_VIVADO)/data/ip/xpm/xpm_fifo/hdl/xpm_fifo.sv \
          $(XILINX_VIVADO)/data/ip/xpm/xpm_memory/hdl/xpm_memory.sv
GLBL    = $(XILINX_VIVADO)/data/verilog/src/glbl.v
INCS    = +incdir+$(OW_UVM)/sim/gen_inc +incdir+$(OW_HW)/ip
DEFS    = +define+NUM_CLK_PER_US=$(NUM_CLK_PER_US)
COMMON  = $(shell sed -e '/^\/\//d' -e 's#$${OW_UVM}#$(OW_UVM)#' $(V)/common/common.f)
RTL_F   = $(foreach i,$(IPS),-f $(BUILD)/rtl/$(i).f)
XIP_DIR = $(BUILD)/xip

.PHONY: prep xip compile run regress lint smoke rxlists clean

# vector lists for orx_vectors_test (+RX_VEC_LIST=...)
rxlists:
	mkdir -p $(BUILD)/lists
	ls $(OW_HW)/ip/openofdm_rx/testing_inputs/simulated/*.txt | grep -v _Fc_input > $(BUILD)/lists/rx_simulated.list
	ls $(OW_HW)/ip/openofdm_rx/testing_inputs/conducted/*.txt > $(BUILD)/lists/rx_conducted.list
	python3 $(OW_UVM)/scripts/gen_rx_vectors.py --out $(BUILD)/rxgen -n 50 --snr 30 --cfo-hz 20e3
	cp $(BUILD)/rxgen/list.txt $(BUILD)/lists/rx_generated.list

prep:
	python3 $(OW_UVM)/scripts/gen_core_top.py --hw $(OW_HW) --board $(BOARD) -o $(OW_UVM)/rtl_wrap/openwifi_core_top.sv
	python3 $(OW_UVM)/scripts/prep_rtl.py --hw $(OW_HW) --out $(BUILD)/rtl

xip:
	vivado -mode batch -nojournal -nolog -source $(OW_UVM)/scripts/gen_xilinx_ip_sim.tcl \
	  -tclargs $(OW_HW) $(XIP_DIR) $(PART) $(SIM) $(LIBMAP)

# ---------------------------------------------------------------- xsim
ifeq ($(SIM),xsim)
compile:
	mkdir -p $(RUN) && cd $(RUN) && \
	if [ "$(XIP)" = "1" ]; then $(OW_UVM)/sim/xip_compile.sh xsim $(XIP_DIR)/xip_sources.txt; fi && \
	xvlog -sv -L uvm $(INCS) $(DEFS) $(XPM_SRC) $(GLBL) && \
	xvlog -sv -L uvm $(INCS) $(DEFS) $(COMMON) $(RTL_F) $(SRC_$(TB)) && \
	xelab -debug typical -L uvm -L xpm $$( [ "$(XIP)" = "1" ] && sed 's/ .*//' $(XIP_DIR)/xip_sources.txt | sort -u | sed 's/^/-L /') \
	  -timescale 1ns/1ps work.$(TOP) work.glbl -s $(TOP)_snap
run: compile
	cd $(RUN) && ln -sf $(OW_HW)/ip/openofdm_tx/src/icmem_*.mem . && \
	xsim $(TOP)_snap -R -sv_seed $(SEED) -testplusarg UVM_TESTNAME=$(TEST) -testplusarg UVM_VERBOSITY=$(VERB) \
	  $(foreach p,$(PLUSARGS),-testplusarg $(patsubst +%,%,$(p))) | tee sim.log
endif

# ---------------------------------------------------------------- Questa
ifeq ($(SIM),questa)
compile:
	mkdir -p $(RUN) && cd $(RUN) && vlib work && \
	if [ "$(XIP)" = "1" ]; then $(OW_UVM)/sim/xip_compile.sh questa $(XIP_DIR)/xip_sources.txt; fi && \
	vlog -sv -mfcu $(INCS) $(DEFS) $(XPM_SRC) $(GLBL) $(COMMON) $(RTL_F) $(SRC_$(TB)) -timescale 1ns/1ps
run: compile
	cd $(RUN) && ln -sf $(OW_HW)/ip/openofdm_tx/src/icmem_*.mem . && \
	vsim -c -sv_seed $(SEED) $(TOP) glbl $$( [ "$(XIP)" = "1" ] && sed 's/ .*//' $(XIP_DIR)/xip_sources.txt | sort -u | sed 's/^/-L /') \
	  +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) $(PLUSARGS) -do "run -all; quit -f" | tee sim.log
endif

# ---------------------------------------------------------------- VCS
ifeq ($(SIM),vcs)
compile:
	mkdir -p $(RUN) && cd $(RUN) && \
	if [ "$(XIP)" = "1" ]; then $(OW_UVM)/sim/xip_compile.sh vcs $(XIP_DIR)/xip_sources.txt; fi && \
	vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps $(INCS) $(DEFS) $(XPM_SRC) $(GLBL) \
	  $(COMMON) $(RTL_F) $(SRC_$(TB)) -top $(TOP) -top glbl -o simv
run: compile
	cd $(RUN) && ln -sf $(OW_HW)/ip/openofdm_tx/src/icmem_*.mem . && \
	./simv +ntb_random_seed=$(SEED) +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) $(PLUSARGS) | tee sim.log
endif

# ---------------------------------------------------------------- Xcelium
ifeq ($(SIM),xcelium)
run:
	mkdir -p $(RUN) && cd $(RUN) && ln -sf $(OW_HW)/ip/openofdm_tx/src/icmem_*.mem . && \
	xrun -64bit -uvm -timescale 1ns/1ps $(INCS) $(DEFS) $(XPM_SRC) $(GLBL) $(COMMON) $(RTL_F) $(SRC_$(TB)) \
	  -top $(TOP) -top glbl -svseed $(SEED) +UVM_TESTNAME=$(TEST) +UVM_VERBOSITY=$(VERB) $(PLUSARGS) | tee sim.log
endif

# ---------------------------------------------------------------- regression
regress:
	@for tb in openofdm_tx openofdm_rx tx_intf rx_intf xpu side_ch chip; do \
	  for t in $$($(MAKE) -s print-tests TB=$$tb); do \
	    $(MAKE) run TB=$$tb TEST=$$t SEED=$(SEED) > /dev/null 2>&1; \
	    log=$(BUILD)/run/$${tb}_$${t}_$(SEED)/sim.log; \
	    if grep -q "UVM_ERROR :    0" $$log && grep -q "UVM_FATAL :    0" $$log; then echo "PASS $$tb $$t"; else echo "FAIL $$tb $$t ($$log)"; fi; \
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
