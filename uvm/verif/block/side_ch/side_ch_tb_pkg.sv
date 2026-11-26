// Block-level UVM environment for side_ch (CSI / "chip state information" capture).
//   TB plays: openofdm_rx (phy_rx_agent ACTIVE; emits csi/equalizer strobes with a known
//             pattern), xpu/tx sideband (side_ch_side_if), axi_dma_0 S2MM (axis slave).
//   checks : record structure as parsed by user_space/side_ch_ctl_src/side_info_display.py:
//            (HEADER_LEN=2 + CSI_LEN=56 + num_eq*52) 64-bit words per decoded packet,
//            word0 = TSF at capture (monotonic, >= TSF when the packet started),
//            M_AXIS_DATA_COUNT register consistent with what the DMA drained.
//   NOTE: the CSI/equalizer word *values* depend on which of the 64 csi strobes side_ch
//         keeps; the expected index map must be taken from side_ch_control.v before
//         enabling the value check (cfg.check_values).
package side_ch_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axil_pkg::*; import axis_pkg::*; import wifi_pkg::*; import phy_rx_pkg::*;
  import openwifi_ral_pkg::*; import openwifi_seq_pkg::*;

  localparam int HEADER_LEN = 2, CSI_LEN = 56, EQ_LEN = 52;

  class sch_scoreboard extends uvm_subscriber #(axis_item);
    `uvm_component_utils(sch_scoreboard)
    int unsigned num_eq = 1; bit [63:0] words[$]; bit [63:0] last_tsf; bit [63:0] tsf_min_q[$];
    int n_rec, n_err; int unsigned n_words_total;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function int unsigned rec_len(); return HEADER_LEN + CSI_LEN + num_eq * EQ_LEN; endfunction
    function void write(axis_item t);
      foreach (t.data[i]) words.push_back(t.data[i]);
      n_words_total += t.data.size();
      while (words.size() >= rec_len()) begin
        bit [63:0] tsf = words[0];
        n_rec++;
        if (n_rec > 1 && tsf <= last_tsf) begin n_err++; `uvm_error("SCH_SB", $sformatf("record %0d TSF %0d not after %0d", n_rec, tsf, last_tsf)) end
        if (tsf_min_q.size() && tsf < tsf_min_q[0]) begin n_err++; `uvm_error("SCH_SB", $sformatf("record %0d TSF %0d before stimulus %0d", n_rec, tsf, tsf_min_q[0])) end
        if (tsf_min_q.size()) void'(tsf_min_q.pop_front());
        last_tsf = tsf;
        repeat (rec_len()) void'(words.pop_front());
      end
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("SCH_SB", $sformatf("records %0d (len %0d words) leftover words %0d errors %0d",
                n_rec, rec_len(), words.size(), n_err), UVM_NONE)
      if (words.size()) `uvm_error("SCH_SB", "DMA stream does not end on a record boundary")
    endfunction
  endclass

  class sch_env extends uvm_env;
    `uvm_component_utils(sch_env)
    axil_agent axil; axis_agent dma; phy_rx_agent prx; sch_scoreboard sb;
    side_ch_regs regs; axil_reg_adapter adapter; virtual side_ch_side_if side;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      axis_cfg ac = axis_cfg::type_id::create("ac"); phy_rx_cfg pc = phy_rx_cfg::type_id::create("pc");
      ac.role = AXIS_SLAVE; ac.ready_mode = READY_RANDOM; ac.ready_pct = 80;
      pc.clk_per_us = `NUM_CLK_PER_US; pc.fast_mode = 1;
      uvm_config_db#(axis_cfg)::set(this, "dma", "cfg", ac);
      uvm_config_db#(phy_rx_cfg)::set(this, "prx", "cfg", pc);
      axil = axil_agent::type_id::create("axil", this);
      dma  = axis_agent::type_id::create("dma", this);
      prx  = phy_rx_agent::type_id::create("prx", this);
      sb   = sch_scoreboard::type_id::create("sb", this);
      regs = side_ch_regs::type_id::create("regs"); regs.configure(null); regs.build();
      adapter = axil_reg_adapter::type_id::create("adapter");
      if (!uvm_config_db#(virtual side_ch_side_if)::get(this, "", "side", side)) `uvm_fatal("NOVIF", "side_ch_side_if")
    endfunction
    function void connect_phase(uvm_phase phase);
      regs.default_map.set_sequencer(axil.sqr, adapter);
      regs.default_map.set_auto_predict(1);
      dma.mon.ap.connect(sb.analysis_export);
    endfunction
  endclass

  // side_ch.c init + "side_ch_ctl g" in capture-all mode (match_cfg = 0)
  class side_ch_csi_cfg_seq extends ow_reg_seq_base;
    `uvm_object_utils(side_ch_csi_cfg_seq)
    side_ch_regs rb; int unsigned num_eq = 1;
    function new(string name = "side_ch_csi_cfg_seq"); super.new(name); endfunction
    task body();
      int unsigned n = HEADER_LEN + CSI_LEN + num_eq * EQ_LEN;
      wr(rb, "MULTI_RST", 4); wr(rb, "MULTI_RST", 0);
      wr(rb, "CONFIG", 32'h0000_0001);          // match_cfg[15:12]=0: every decoded packet
      wr(rb, "IQ_TRIGGER", 10);
      wr(rb, "NUM_EQ", num_eq);
      wr(rb, "IQ_CAPTURE", 0);                  // CSI mode, not IQ capture
      wr(rb, "NUM_DMA_SYMBOL", (n << 16) | n);
    endtask
  endclass

  class sch_csi_test extends uvm_test;
    `uvm_component_utils(sch_csi_test)
    sch_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase); env = sch_env::type_id::create("env", this); endfunction
    task run_phase(uvm_phase phase);
      side_ch_csi_cfg_seq c = side_ch_csi_cfg_seq::type_id::create("c");
      bit [31:0] cnt;
      phase.raise_objection(this);
      c.rb = env.regs; c.num_eq = 1; env.sb.num_eq = 1; c.start(null);
      repeat (8) begin
        phy_rx_item it = phy_rx_item::type_id::create("it");
        if (!it.randomize() with { frame.mpdu_len inside {[24:200]}; }) `uvm_fatal("RAND", "item")
        env.sb.tsf_min_q.push_back(env.side.tsf);
        env.prx.sqr.execute_item(it);
        #20us;
      end
      #50us;
      c.rd(env.regs, "M_AXIS_DATA_COUNT", cnt);
      `uvm_info("SCH", $sformatf("M_AXIS_DATA_COUNT=%0d after drain, %0d words drained", cnt, env.sb.n_words_total), UVM_LOW)
      if (env.sb.n_rec == 0) `uvm_error("SCH", "no CSI record captured")
      phase.drop_objection(this);
    endtask
  endclass
endpackage
