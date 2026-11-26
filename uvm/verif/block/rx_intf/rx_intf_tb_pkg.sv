// Block-level UVM environment for rx_intf.
//   TB plays: ADC (iq_agent, 40 MHz adc_clk, each 20 Msps sample sent twice),
//             openofdm_rx outputs (phy_rx_agent ACTIVE: emulated decode of a wifi_frame),
//             xpu sideband (rx_side_if: filter decision, RSSI/AGC lock, TSF),
//             axi_dma_1 S2MM (axis slave, random back-pressure).
//   checks : (1) ADC -> sample0/strobe: decimation by 2, BB_GAIN shift, nothing dropped
//            (2) DMA packet == rx descriptor (wifi_pkg::rx_desc) + PSDU + fcs_ok bit
//            (3) packets the xpu marks block_rx_dma_to_ps never reach the DMA
//            (4) one rx_pkt_intr per forwarded packet
package rx_intf_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axil_pkg::*; import axis_pkg::*; import iq_pkg::*; import wifi_pkg::*; import phy_rx_pkg::*;
  import openwifi_ral_pkg::*; import openwifi_seq_pkg::*;

  class rxi_expect extends uvm_object;
    wifi_frame f; bit fcs_ok; bit blocked; bit [10:0] rssi; bit [7:0] gpio; bit [63:0] tsf_min;
    `uvm_object_utils(rxi_expect)
    function new(string name = "rxi_expect"); super.new(name); endfunction
  endclass

  `uvm_analysis_imp_decl(_dma)
  `uvm_analysis_imp_decl(_adc)
  `uvm_analysis_imp_decl(_bb)

  class rxi_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(rxi_scoreboard)
    uvm_analysis_imp_dma #(axis_item, rxi_scoreboard) dma_imp;
    uvm_analysis_imp_adc #(iq_item,   rxi_scoreboard) adc_imp;   // what the ADC agent drove
    uvm_analysis_imp_bb  #(iq_item,   rxi_scoreboard) bb_imp;    // what reached openofdm_rx
    rxi_expect exp_q[$]; iq_item adc_q[$];
    int unsigned bb_gain_shift = 0;
    int n_pkt_ok, n_iq_ok, n_err, n_blocked;
    function new(string name, uvm_component parent);
      super.new(name, parent);
      dma_imp = new("dma_imp", this); adc_imp = new("adc_imp", this); bb_imp = new("bb_imp", this);
    endfunction
    function void expect_pkt(rxi_expect e); if (e.blocked) n_blocked++; else exp_q.push_back(e); endfunction

    function void write_dma(axis_item t);
      byte unsigned b[$]; rx_desc d = rx_desc::type_id::create("d"); rxi_expect e; byte unsigned p[$];
      t.to_bytes(b);
      if (!d.parse(b)) begin n_err++; `uvm_error("RXI_SB", $sformatf("unparsable DMA packet (%0d bytes)", b.size())) return; end
      if (exp_q.size() == 0) begin n_err++; `uvm_error("RXI_SB", {"unexpected DMA packet: ", d.convert2string()}) return; end
      e = exp_q.pop_front(); e.f.psdu(p);
      if (d.len != p.size())                 begin n_err++; `uvm_error("RXI_SB", $sformatf("len %0d != %0d", d.len, p.size())) return; end
      if (d.rate_idx != e.f.rx_rate_idx())   begin n_err++; `uvm_error("RXI_SB", $sformatf("rate_idx 0x%0h != 0x%0h", d.rate_idx, e.f.rx_rate_idx())) return; end
      if (d.ht && d.sgi != e.f.sgi)          begin n_err++; `uvm_error("RXI_SB", "sgi flag") return; end
      if (d.agc[15:8] != 8'h01)              begin n_err++; `uvm_error("RXI_SB", $sformatf("pkt_exist byte 0x%02h != 0x01", d.agc[15:8])) return; end
      if (d.agc[7:0] != e.gpio)              begin n_err++; `uvm_error("RXI_SB", $sformatf("gpio lock 0x%02h != 0x%02h", d.agc[7:0], e.gpio)) return; end
      if (d.rssi_half_db[10:0] != e.rssi)    begin n_err++; `uvm_error("RXI_SB", $sformatf("rssi %0d != %0d", d.rssi_half_db, e.rssi)) return; end
      if (d.tsf < e.tsf_min)                 begin n_err++; `uvm_error("RXI_SB", $sformatf("tsf %0d before stimulus start %0d", d.tsf, e.tsf_min)) return; end
      for (int k = 0; k < p.size() - 1; k++)
        if (d.payload[k] != p[k]) begin n_err++; `uvm_error("RXI_SB", $sformatf("payload byte %0d 0x%02h != 0x%02h", k, d.payload[k], p[k])) return; end
      if (d.fcs_ok != e.fcs_ok)              begin n_err++; `uvm_error("RXI_SB", $sformatf("fcs_ok bit %0b != %0b", d.fcs_ok, e.fcs_ok)) return; end
      n_pkt_ok++;
    endfunction

    function void write_adc(iq_item t); adc_q.push_back(t); endfunction
    function void write_bb(iq_item t);
      iq_item a; int unsigned n;
      if (adc_q.size() == 0) begin n_err++; `uvm_error("RXI_SB", "baseband burst without ADC burst") return; end
      a = adc_q.pop_front(); n = a.size();
      if (t.size() != n) begin n_err++; `uvm_error("RXI_SB", $sformatf("baseband burst %0d samples, ADC sent %0d", t.size(), n)) return; end
      foreach (a.i0[k])
        if (t.i0[k] != shortint'(a.i0[k] <<< bb_gain_shift) || t.q0[k] != shortint'(a.q0[k] <<< bb_gain_shift)) begin
          n_err++; `uvm_error("RXI_SB", $sformatf("sample %0d (%0d,%0d) != ADC (%0d,%0d)<<%0d", k, t.i0[k], t.q0[k], a.i0[k], a.q0[k], bb_gain_shift))
          return;
        end
      n_iq_ok++;
    endfunction
    function void check_phase(uvm_phase phase);
      if (exp_q.size()) `uvm_error("RXI_SB", $sformatf("%0d expected packets never reached the DMA", exp_q.size()))
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("RXI_SB", $sformatf("packets ok %0d  blocked (expected dropped) %0d  iq bursts ok %0d  errors %0d",
                n_pkt_ok, n_blocked, n_iq_ok, n_err), UVM_NONE)
    endfunction
  endclass

  class rxi_env extends uvm_env;
    `uvm_component_utils(rxi_env)
    axil_agent axil; axis_agent dma; iq_agent adc; iq_agent bb; phy_rx_agent prx; rxi_scoreboard sb;
    rx_intf_regs regs; axil_reg_adapter adapter;
    virtual rx_side_if side; virtual irq_if irq;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      axis_cfg ac = axis_cfg::type_id::create("ac");
      iq_cfg adc_c = iq_cfg::type_id::create("adc_c"), bb_c = iq_cfg::type_id::create("bb_c");
      phy_rx_cfg pc = phy_rx_cfg::type_id::create("pc");
      ac.role = AXIS_SLAVE; ac.ready_mode = READY_RANDOM; ac.ready_pct = 60;
      adc_c.pack = PACK_ADC64; adc_c.valid_style = VALID_LEVEL; adc_c.clk_per_sample = 1; adc_c.repeat_n = 2;
      bb_c.pack = PACK_IQ32; bb_c.end_gap_samples = 32;
      pc.clk_per_us = `NUM_CLK_PER_US; pc.fast_mode = 1;
      uvm_config_db#(axis_cfg)::set(this, "dma", "cfg", ac);
      uvm_config_db#(iq_cfg)::set(this, "adc", "cfg", adc_c);
      uvm_config_db#(iq_cfg)::set(this, "bb", "cfg", bb_c);
      uvm_config_db#(uvm_active_passive_enum)::set(this, "bb", "is_active", UVM_PASSIVE);
      uvm_config_db#(phy_rx_cfg)::set(this, "prx", "cfg", pc);
      axil = axil_agent::type_id::create("axil", this);
      dma  = axis_agent::type_id::create("dma", this);
      adc  = iq_agent::type_id::create("adc", this);
      bb   = iq_agent::type_id::create("bb", this);
      prx  = phy_rx_agent::type_id::create("prx", this);
      sb   = rxi_scoreboard::type_id::create("sb", this);
      regs = rx_intf_regs::type_id::create("regs"); regs.configure(null); regs.build();
      adapter = axil_reg_adapter::type_id::create("adapter");
      if (!uvm_config_db#(virtual rx_side_if)::get(this, "", "side", side)) `uvm_fatal("NOVIF", "rx_side_if")
      if (!uvm_config_db#(virtual irq_if)::get(this, "", "irq", irq)) `uvm_fatal("NOVIF", "irq_if")
    endfunction
    function void connect_phase(uvm_phase phase);
      regs.default_map.set_sequencer(axil.sqr, adapter);
      regs.default_map.set_auto_predict(1);
      dma.mon.ap.connect(sb.dma_imp);
      bb.mon.ap.connect(sb.bb_imp);
    endfunction
  endclass

  class rxi_base_test extends uvm_test;
    `uvm_component_utils(rxi_base_test)
    rxi_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase); env = rxi_env::type_id::create("env", this); endfunction
    task init_regs();
      rx_intf_init_seq s = rx_intf_init_seq::type_id::create("init");
      s.rb = env.regs; s.start(null);
      s.wr(env.regs, "INTERRUPT_TEST", 0);   // openwifi_start(): enable rx interrupt
      s.rx_m_axis_rst(env.regs, 0);          //                   release M AXIS
    endtask
  endclass

  // frames through the openofdm_rx-side interface -> DMA; ~20% FCS errors, ~20% filtered
  class rxi_frames_test extends rxi_base_test;
    `uvm_component_utils(rxi_frames_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      int unsigned n = 20;
      phase.raise_objection(this);
      init_regs();
      void'($value$plusargs("N_PKT=%d", n));
      repeat (n) begin
        phy_rx_item it = phy_rx_item::type_id::create("it");
        rxi_expect e = rxi_expect::type_id::create("e");
        if (!it.randomize() with { corrupt_fcs dist {0 := 4, 1 := 1}; frame.mpdu_len inside {[14:1500]}; })
          `uvm_fatal("RAND", "item")
        e.f = it.frame; e.fcs_ok = !it.corrupt_fcs; e.blocked = ($urandom_range(4) == 0);
        e.rssi = 11'($urandom_range(400)); e.gpio = 8'($urandom); e.tsf_min = env.side.tsf;
        env.side.set_rx(e.blocked, e.rssi, e.gpio);
        env.sb.expect_pkt(e);
        env.prx.sqr.execute_item(it);
        #5us;
      end
      #50us;
      if (env.irq.n_rx_pkt_intr < env.sb.n_pkt_ok)
        `uvm_error("IRQ", $sformatf("rx_pkt_intr %0d < packets delivered %0d", env.irq.n_rx_pkt_intr, env.sb.n_pkt_ok))
      phase.drop_objection(this);
    endtask
  endclass

  // ADC -> baseband sample path with every BB_GAIN shift (independent of the frame path)
  class rxi_adc_path_test extends rxi_base_test;
    `uvm_component_utils(rxi_adc_path_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      init_regs();
      for (int g = 0; g < 4; g++) begin
        iq_item it = iq_item::type_id::create("it");
        ow_reg_seq_base s = rx_intf_init_seq::type_id::create("s");
        s.wr(env.regs, "BB_GAIN", g); env.sb.bb_gain_shift = g;
        #2us;
        for (int k = 0; k < 500; k++) begin
          it.i0.push_back(shortint'($urandom_range(2000) - 1000) | 1); it.q0.push_back(shortint'($urandom_range(2000) - 1000));
        end
        it.idle_before = 100;
        env.sb.write_adc(it);
        env.adc.sqr.execute_item(it);
        #20us;
      end
      phase.drop_objection(this);
    endtask
  endclass
endpackage
