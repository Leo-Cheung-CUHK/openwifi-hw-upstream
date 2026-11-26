// Block-level UVM environment for tx_intf.
//   TB plays: axi_dma_0 MM2S (axis master), openofdm_tx (phy_tx ACC model), xpu (stub
//   module in tb_top), the AD9361/RF DAC (iq monitor on dac_data, 40 Msps zero-stuffed).
//   checks : (1) BRAM image handed to the PHY == wifi_frame::bram_words()  -- verifies the
//                L-SIG/HT-SIG build, parity, HT-SIG CRC, legacy-length spoof, PSDU copy
//            (2) DAC samples == ACC ramp * BB_GAIN >>> 7, exact, nothing lost or repeated
//            (3) tx_itrpt fires per packet; PKT_INFO1 reports the bd index / queue we gave
package tx_intf_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axil_pkg::*; import axis_pkg::*; import iq_pkg::*; import wifi_pkg::*; import phy_tx_pkg::*;
  import openwifi_ral_pkg::*; import openwifi_seq_pkg::*;

  `uvm_analysis_imp_decl(_obs)
  `uvm_analysis_imp_decl(_dac)

  class txi_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(txi_scoreboard)
    uvm_analysis_imp_obs #(phy_tx_obs, txi_scoreboard) obs_imp;
    uvm_analysis_imp_dac #(iq_item,    txi_scoreboard) dac_imp;
    wifi_frame bram_q[$], dac_q[$];
    int unsigned bb_gain = 250;
    int n_bram_ok, n_dac_ok, n_err;
    event tx_done_ev;
    function new(string name, uvm_component parent);
      super.new(name, parent); obs_imp = new("obs_imp", this); dac_imp = new("dac_imp", this);
    endfunction
    function void expect_frame(wifi_frame f); bram_q.push_back(f); dac_q.push_back(f); endfunction

    function void write_obs(phy_tx_obs o);
      wifi_frame f; string why;
      if (bram_q.size() == 0) begin `uvm_error("TXI_SB", "PHY started a packet nobody queued") return; end
      f = bram_q.pop_front();
      why = o.check(f);
      if (why == "") n_bram_ok++;
      else begin n_err++; `uvm_error("TXI_SB", {"BRAM image ", f.convert2string(), ": ", why}) end
      ->tx_done_ev;
    endfunction

    function void write_dac(iq_item b);
      wifi_frame f; int unsigned n;
      if (dac_q.size() == 0) begin `uvm_error("TXI_SB", "DAC burst with no packet") return; end
      f = dac_q.pop_front(); n = f.tx_samples();
      if (b.size() != n) begin
        n_err++; `uvm_error("TXI_SB", $sformatf("DAC burst %0d samples, expected %0d (%s)", b.size(), n, f.convert2string()))
        return;
      end
      for (int k = 0; k < n; k++) begin
        shortint i, q; logic signed [31:0] ei, eq;
        phy_tx_acc_model::ramp(k, i, q);
        ei = (32'(i) * $signed(10'(bb_gain))) >>> 7; eq = (32'(q) * $signed(10'(bb_gain))) >>> 7;
        if (b.i0[k] !== 16'(ei) || b.q0[k] !== 16'(eq)) begin
          n_err++;
          `uvm_error("TXI_SB", $sformatf("DAC sample %0d: (%0d,%0d) expected (%0d,%0d)", k, b.i0[k], b.q0[k], 16'(ei), 16'(eq)))
          return;
        end
      end
      n_dac_ok++;
    endfunction
    function void check_phase(uvm_phase phase);
      if (bram_q.size() || dac_q.size())
        `uvm_error("TXI_SB", $sformatf("outstanding: %0d never reached the PHY, %0d never reached the DAC", bram_q.size(), dac_q.size()))
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("TXI_SB", $sformatf("BRAM ok %0d  DAC ok %0d  errors %0d", n_bram_ok, n_dac_ok, n_err), UVM_NONE)
    endfunction
  endclass

  class txi_env extends uvm_env;
    `uvm_component_utils(txi_env)
    axil_agent axil; axis_agent dma; phy_tx_agent acc; iq_agent dac; txi_scoreboard sb;
    tx_intf_regs regs; axil_reg_adapter adapter;
    virtual interface irq_if irq;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      axis_cfg ac = axis_cfg::type_id::create("ac");
      phy_tx_cfg pc = phy_tx_cfg::type_id::create("pc");
      iq_cfg dc = iq_cfg::type_id::create("dc");
      ac.role = AXIS_MASTER;
      pc.role = PHY_TX_ACC_MODEL; pc.acc_clk_per_sample = `NUM_CLK_PER_US / 20;
      dc.pack = PACK_ADC64; dc.valid_style = VALID_LEVEL; dc.decim = 2; dc.end_gap_samples = 64;
      uvm_config_db#(axis_cfg)::set(this, "dma", "cfg", ac);
      uvm_config_db#(phy_tx_cfg)::set(this, "acc", "cfg", pc);
      uvm_config_db#(iq_cfg)::set(this, "dac", "cfg", dc);
      uvm_config_db#(uvm_active_passive_enum)::set(this, "dac", "is_active", UVM_PASSIVE);
      axil = axil_agent::type_id::create("axil", this);
      dma  = axis_agent::type_id::create("dma", this);
      acc  = phy_tx_agent::type_id::create("acc", this);
      dac  = iq_agent::type_id::create("dac", this);
      sb   = txi_scoreboard::type_id::create("sb", this);
      regs = tx_intf_regs::type_id::create("regs"); regs.configure(null); regs.build();
      adapter = axil_reg_adapter::type_id::create("adapter");
      if (!uvm_config_db#(virtual irq_if)::get(this, "", "irq", irq)) `uvm_fatal("NOVIF", "irq_if")
    endfunction
    function void connect_phase(uvm_phase phase);
      regs.default_map.set_sequencer(axil.sqr, adapter);
      regs.default_map.set_auto_predict(1);
      acc.mon.ap.connect(sb.obs_imp);
      dac.mon.ap.connect(sb.dac_imp);
    endfunction
  endclass

  // driver openwifi_tx() replay: regs, then DMA; waits for the PHY to finish each packet,
  // then services the interrupt like openwifi_tx_interrupt() (reads PKT_INFO1/2)
  class txi_tx_vseq extends ow_reg_seq_base;
    `uvm_object_utils(txi_tx_vseq)
    txi_env env; int unsigned n = 10; bit check_pkt_info = 1;
    function new(string name = "txi_tx_vseq"); super.new(name); endfunction
    task body();
      for (int k = 0; k < n; k++) begin
        wifi_frame f = wifi_frame::type_id::create($sformatf("f%0d", k));
        tx_kick_seq kick = tx_kick_seq::type_id::create("kick");
        axis_item dm = axis_item::type_id::create("dm");
        byte unsigned b[$]; bit [31:0] info1, info2;
        if (!f.randomize() with { mpdu_len inside {[24:600]}; queue_idx == 0; need_ack == 0; })
          `uvm_fatal("RAND", "frame")
        env.sb.expect_frame(f);
        void'(env.acc.acc.exp_mb.try_put(f));
        kick.rb = env.regs; kick.f = f; kick.bd_wr_idx = k[5:0];
        kick.start(null, this);
        f.tx_dma_bytes(b); dm.from_bytes_word_padded(b);
        env.dma.sqr.execute_item(dm);
        @(env.sb.tx_done_ev);
        if (check_pkt_info) begin
          env.irq.wait_tx_itrpt(200_000);
          rd(env.regs, "PKT_INFO1", info1); rd(env.regs, "PKT_INFO2", info2);
          if (info1[10:5] != k[5:0] || info1[16:15] != f.queue_idx)
            `uvm_error("PKT_INFO", $sformatf("PKT_INFO1=0x%08h: bd_idx %0d (exp %0d) queue %0d (exp %0d)",
                       info1, info1[10:5], k[5:0], info1[16:15], f.queue_idx))
        end
      end
    endtask
  endclass

  class txi_base_test extends uvm_test;
    `uvm_component_utils(txi_base_test)
    txi_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase); env = txi_env::type_id::create("env", this); endfunction
    task init_regs();
      tx_intf_init_seq s = tx_intf_init_seq::type_id::create("init");
      s.rb = env.regs; s.start(null);
      env.sb.bb_gain = s.bb_gain;
      // driver enables the tx interrupt in openwifi_start()
      s.wr(env.regs, "INTERRUPT_SEL", 32'h4);
    endtask
  endclass

  class txi_basic_test extends txi_base_test;
    `uvm_component_utils(txi_basic_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      txi_tx_vseq v = txi_tx_vseq::type_id::create("v");
      phase.raise_objection(this);
      init_regs();
      v.env = env; void'($value$plusargs("N_PKT=%d", v.n));
      v.start(null);
      #20us;
      phase.drop_objection(this);
    endtask
  endclass

  // DMA with random idle beats and PHY back-pressure through TX_HOLD_THRESHOLD
  class txi_stress_test extends txi_basic_test;
    `uvm_component_utils(txi_stress_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      txi_tx_vseq v = txi_tx_vseq::type_id::create("v");
      phase.raise_objection(this);
      init_regs();
      v.wr(env.regs, "TX_HOLD_THRESHOLD", 64);   // hold engages early -> exercises tx_hold handshake
      v.env = env; v.n = 30;
      v.start(null);
      #20us;
      phase.drop_objection(this);
    endtask
  endclass
endpackage
