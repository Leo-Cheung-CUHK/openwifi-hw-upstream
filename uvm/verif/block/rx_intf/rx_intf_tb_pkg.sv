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
    bit may_drop;      // DMA stalled past TLAST_TIMEOUT_TOP / M_AXIS held in reset: may be lost or cut
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
    int n_pkt_ok, n_iq_ok, n_err, n_blocked, n_dropped, n_bb_bursts;
    function new(string name, uvm_component parent);
      super.new(name, parent);
      dma_imp = new("dma_imp", this); adc_imp = new("adc_imp", this); bb_imp = new("bb_imp", this);
    endfunction
    function void expect_pkt(rxi_expect e); if (e.blocked) n_blocked++; else exp_q.push_back(e); endfunction

    function void write_dma(axis_item t);
      byte unsigned b[$]; rx_desc d = rx_desc::type_id::create("d"); string why;
      t.to_bytes(b);
      // expectations marked may_drop are skipped when the packet on the bus is not theirs
      forever begin
        if (exp_q.size() == 0) begin
          n_err++; `uvm_error("RXI_SB", $sformatf("unexpected DMA packet (%0d bytes)", b.size())) return;
        end
        why = d.parse(b) ? check_pkt(exp_q[0], d) : $sformatf("unparsable DMA packet (%0d bytes)", b.size());
        if (why == "") begin void'(exp_q.pop_front()); n_pkt_ok++; return; end
        if (!exp_q[0].may_drop) begin n_err++; `uvm_error("RXI_SB", why) void'(exp_q.pop_front()); return; end
        // a later packet, past any run of may_drop expectations (those were lost entirely) ...
        if (d.parse(b)) begin
          int j = -1;
          for (int k = 1; k < exp_q.size(); k++) begin
            if (check_pkt(exp_q[k], d) == "") begin j = k; break; end
            if (!exp_q[k].may_drop) break;
          end
          if (j > 0) begin
            repeat (j) begin void'(exp_q.pop_front()); n_dropped++; end
            void'(exp_q.pop_front()); n_pkt_ok++; return;
          end
        end
        // ... or a cut-off transfer of the dropped packet itself (fake TLAST)
        `uvm_info("RXI_SB", {"dropped-packet remnant on DMA: ", why}, UVM_LOW)
        void'(exp_q.pop_front()); n_dropped++; return;
      end
    endfunction
    function string check_pkt(rxi_expect e, rx_desc d);
      byte unsigned p[$]; e.f.psdu(p);
      if (d.len != p.size())                 return $sformatf("len %0d != %0d", d.len, p.size());
      if (d.rate_idx != e.f.rx_rate_idx())   return $sformatf("rate_idx 0x%0h != 0x%0h", d.rate_idx, e.f.rx_rate_idx());
      if (d.ht && d.sgi != e.f.sgi)          return "sgi flag";
      if (d.agc[15:8] != 8'h01)              return $sformatf("pkt_exist byte 0x%02h != 0x01", d.agc[15:8]);
      if (d.agc[7:0] != e.gpio)              return $sformatf("gpio lock 0x%02h != 0x%02h", d.agc[7:0], e.gpio);
      if (d.rssi_half_db[10:0] != e.rssi)    return $sformatf("rssi %0d != %0d", d.rssi_half_db, e.rssi);
      if (d.tsf < e.tsf_min)                 return $sformatf("tsf %0d before stimulus start %0d", d.tsf, e.tsf_min);
      for (int k = 0; k < p.size() - 1; k++)
        if (d.payload[k] != p[k])            return $sformatf("payload byte %0d 0x%02h != 0x%02h", k, d.payload[k], p[k]);
      if (d.fcs_ok != e.fcs_ok)              return $sformatf("fcs_ok bit %0b != %0b", d.fcs_ok, e.fcs_ok);
      return "";
    endfunction

    function void write_adc(iq_item t); adc_q.push_back(t); endfunction
    function void write_bb(iq_item t);
      iq_item a; int unsigned n;
      n_bb_bursts++;
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
      foreach (exp_q[i]) if (!exp_q[i].may_drop) begin
        `uvm_error("RXI_SB", $sformatf("expected packet never reached the DMA: %s", exp_q[i].f.convert2string())) break;
      end
      if (adc_q.size()) `uvm_error("RXI_SB", $sformatf("%0d ADC bursts never reached the baseband output", adc_q.size()))
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("RXI_SB", $sformatf("packets ok %0d  blocked (expected dropped) %0d  lost to stalls %0d  iq bursts ok %0d  errors %0d",
                n_pkt_ok, n_blocked, n_dropped, n_iq_ok, n_err), UVM_NONE)
    endfunction
  endclass

  class rxi_env extends uvm_env;
    `uvm_component_utils(rxi_env)
    axil_agent axil; axis_agent dma; iq_agent adc; iq_agent bb; iq_agent txl; phy_rx_agent prx; rxi_scoreboard sb;
    rx_intf_regs regs; axil_reg_adapter adapter;
    virtual rx_side_if side; virtual irq_if irq;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      axis_cfg ac = axis_cfg::type_id::create("ac");
      iq_cfg adc_c = iq_cfg::type_id::create("adc_c"), bb_c = iq_cfg::type_id::create("bb_c");
      iq_cfg txl_c = iq_cfg::type_id::create("txl_c");
      phy_rx_cfg pc = phy_rx_cfg::type_id::create("pc");
      ac.role = AXIS_SLAVE; ac.ready_mode = READY_RANDOM; ac.ready_pct = 60;
      adc_c.pack = PACK_ADC64; adc_c.valid_style = VALID_LEVEL; adc_c.clk_per_sample = 1; adc_c.repeat_n = 2;
      bb_c.pack = PACK_IQ32; bb_c.end_gap_samples = 32;
      txl_c.pack = PACK_ADC64; txl_c.valid_style = VALID_PULSE; txl_c.clk_per_sample = `NUM_CLK_PER_US / 20;   // tx_intf iq0/iq1 + strobe
      pc.clk_per_us = `NUM_CLK_PER_US; pc.fast_mode = 1;
      uvm_config_db#(axis_cfg)::set(this, "dma", "cfg", ac);
      uvm_config_db#(iq_cfg)::set(this, "adc", "cfg", adc_c);
      uvm_config_db#(iq_cfg)::set(this, "bb", "cfg", bb_c);
      uvm_config_db#(iq_cfg)::set(this, "txl", "cfg", txl_c);
      uvm_config_db#(uvm_active_passive_enum)::set(this, "bb", "is_active", UVM_PASSIVE);
      uvm_config_db#(phy_rx_cfg)::set(this, "prx", "cfg", pc);
      axil = axil_agent::type_id::create("axil", this);
      dma  = axis_agent::type_id::create("dma", this);
      adc  = iq_agent::type_id::create("adc", this);
      bb   = iq_agent::type_id::create("bb", this);
      txl  = iq_agent::type_id::create("txl", this);
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
      env.sb.bb_gain_shift = 4;              // hw_init BB_GAIN
    endtask
    task wr(string name, bit [31:0] v);
      uvm_status_e st; env.regs.r(name).write(st, v);
      if (st != UVM_IS_OK) `uvm_error("REGWR", $sformatf("%s <= 0x%0h failed", name, v))
    endtask
    task rd(string name, output bit [31:0] v);
      uvm_status_e st; uvm_reg_data_t d; env.regs.r(name).read(st, d); v = d;
    endtask
    // one frame through the emulated openofdm_rx; returns the expectation
    task rx_frame(output rxi_expect e, input bit may_drop = 0, input int unsigned lmin = 14, input int unsigned lmax = 1500);
      phy_rx_item it = phy_rx_item::type_id::create("it");
      e = rxi_expect::type_id::create("e");
      if (!it.randomize() with { corrupt_fcs == 0; frame.mpdu_len inside {[lmin:lmax]}; }) `uvm_fatal("RAND", "item")
      e.f = it.frame; e.fcs_ok = 1; e.may_drop = may_drop;
      e.rssi = 11'($urandom_range(400)); e.gpio = 8'($urandom); e.tsf_min = env.side.tsf;
      env.side.set_rx(0, e.rssi, e.gpio);
      env.sb.expect_pkt(e);
      env.prx.sqr.execute_item(it);
    endtask
    function iq_item rand_iq(int unsigned n, bit lane1 = 0);
      iq_item it = iq_item::type_id::create("it");
      for (int k = 0; k < n; k++) begin
        it.i0.push_back(shortint'($urandom_range(2000) - 1000) | 1); it.q0.push_back(shortint'($urandom_range(2000) - 1000));
        it.i1.push_back(lane1 ? shortint'($urandom_range(2000) - 1000) | 1 : 0);
        it.q1.push_back(lane1 ? shortint'($urandom_range(2000) - 1000) : 0);
      end
      it.idle_before = 100;
      return it;
    endfunction
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

  // RXI-03: DMA (S2MM) back-pressure. (1) tready low for less than TLAST_TIMEOUT_TOP during a
  // packet: it must arrive intact once tready returns. (2) tready low for longer: rx_intf's
  // TLAST auto-recover (fake TLAST + M_AXIS reset) may cut or drop that packet, but the
  // following packets must arrive intact (no stuck state machine). (3) M_AXIS reset bit
  // (MULTI_RST[4], RX_INTF_REG_M_AXIS_RST_write) held while a packet arrives, then released.
  class rxi_dma_stall_test extends rxi_base_test;
    `uvm_component_utils(rxi_dma_stall_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      rxi_expect e; int unsigned n_ok0;
      int unsigned top_us = 1000;   // the timer also covers the rest of the airtime: above the 300-byte frames' ~450 us
      ow_reg_seq_base s = rx_intf_init_seq::type_id::create("s");
      phase.raise_objection(this);
      init_regs();
      env.dma.cfg.ready_mode = READY_ALWAYS;
      wr("TLAST_TIMEOUT_TOP", top_us);
      repeat (3) begin rx_frame(e, 0, 14, 300); #20us; end                    // baseline
      // (1) short stall
      repeat (4) begin
        env.dma.cfg.ready_mode = READY_NEVER;
        rx_frame(e, 0, 14, 300);
        #((top_us / 4) * 1us);
        env.dma.cfg.ready_mode = READY_ALWAYS;
        #40us;
      end
      if (env.sb.n_dropped) `uvm_error("RXI_STALL", "a packet stalled for less than TLAST_TIMEOUT_TOP was lost")
      // (2) long stall: auto-recover
      repeat (3) begin
        env.dma.cfg.ready_mode = READY_NEVER;
        rx_frame(e, 1, 200, 1500);
        #((top_us * 3) * 1us);
        env.dma.cfg.ready_mode = READY_ALWAYS;
        #20us;
        n_ok0 = env.sb.n_pkt_ok;
        repeat (2) begin rx_frame(e, 0, 14, 300); #20us; end
        if (env.sb.n_pkt_ok != n_ok0 + 2) `uvm_error("RXI_STALL", "packets after a TLAST timeout did not come through")
      end
      // (3) M_AXIS held in reset
      env.dma.cfg.ready_mode = READY_RANDOM;
      s.rx_m_axis_rst(env.regs, 1);
      rx_frame(e, 1); #30us;
      s.rx_m_axis_rst(env.regs, 0);
      #10us;
      // finding J: MULTI_RST[4] does not reset rx_intf_pl_to_m_axis (MULTI_RST[8]); the frame
      // taken during the hold parks it in WAIT_DMA_TLAST, so RX is blacked out until the TLAST
      // timeout. Frames inside that window may be lost; after it they must all arrive.
      n_ok0 = env.sb.n_pkt_ok;
      repeat (2) begin rx_frame(e, 1, 14, 300); #20us; end
      if (env.sb.n_pkt_ok == n_ok0) `uvm_info("RXI_STALL", "finding J: frames right after the M_AXIS reset release were not delivered (FSM parked until TLAST timeout)", UVM_NONE)
      #(top_us * 1us);
      repeat (4) begin rx_frame(e, 0, 14, 300); #20us; end
      #50us;
      `uvm_info("RXI_STALL", $sformatf("lost to stalls/resets: %0d (allowed)", env.sb.n_dropped), UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass

  // RXI-04: internal loopback source. IQ_SRC_SEL[8]=1 feeds openofdm_rx (sample0) from
  // tx_intf's iq0 + strobe instead of the ADC path: samples pass unchanged (no BB_GAIN shift),
  // and ADC activity must not leak through. Back to the ADC afterwards.
  class rxi_loopback_src_test extends rxi_base_test;
    `uvm_component_utils(rxi_loopback_src_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      init_regs();
      wr("BB_GAIN", 2); env.sb.bb_gain_shift = 0;
      wr("IQ_SRC_SEL", 32'h100);
      #2us;
      repeat (4) begin
        iq_item t = rand_iq(300), a = rand_iq(300);
        env.sb.write_adc(t);                                // expected at sample0: the tx_intf samples
        fork
          env.txl.sqr.execute_item(t);
          env.adc.sqr.execute_item(a);                      // concurrent ADC traffic, must be ignored
        join
        #20us;
      end
      wr("IQ_SRC_SEL", 0); env.sb.bb_gain_shift = 2;
      #2us;
      repeat (2) begin
        iq_item a = rand_iq(300), t = rand_iq(300);
        env.sb.write_adc(a);
        fork
          env.adc.sqr.execute_item(a);
          env.txl.sqr.execute_item(t);                      // tx_intf traffic, must be ignored now
        join
        #20us;
      end
      phase.drop_objection(this);
    endtask
  endclass

  // RXI-05: antenna select and mute. ANT_SEL[0] swaps the ADC lanes (sample0 from the second
  // antenna); mute_adc_out_to_bb (xpu, during own TX) zeroes the lane feeding sample0, so
  // openofdm_rx sees no samples while muted; un-muting restores the path.
  class rxi_mute_ant_test extends rxi_base_test;
    `uvm_component_utils(rxi_mute_ant_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      int unsigned nb;
      phase.raise_objection(this);
      init_regs();
      wr("BB_GAIN", 1); env.sb.bb_gain_shift = 1;
      for (int ant = 0; ant < 2; ant++) begin
        iq_item a = rand_iq(400, 1), e = iq_item::type_id::create("e");
        wr("ANT_SEL", ant); #2us;
        // expected sample0 stream: lane0, or lane1 when ANT_SEL[0]
        foreach (a.i0[k]) begin e.i0.push_back(ant ? a.i1[k] : a.i0[k]); e.q0.push_back(ant ? a.q1[k] : a.q0[k]); end
        env.sb.write_adc(e);
        env.adc.sqr.execute_item(a);
        #20us;
        `uvm_info("RXI_ANT", $sformatf("ANT_SEL=%0d: sample0 from ADC lane %0d", ant, ant), UVM_LOW)
      end
      for (int ant = 0; ant < 2; ant++) begin
        iq_item a = rand_iq(400, 1);
        wr("ANT_SEL", ant); #2us;
        env.side.mute_adc_out_to_bb = 1; #1us;             // CDC into adc_clk
        nb = env.sb.n_bb_bursts;
        env.adc.sqr.execute_item(a);
        #20us;
        if (env.sb.n_bb_bursts != nb) `uvm_error("RXI_MUTE", $sformatf("ANT_SEL=%0d: samples reached openofdm_rx while muted", ant))
        env.side.mute_adc_out_to_bb = 0; #1us;
      end
      begin
        iq_item a = rand_iq(300, 1);
        wr("ANT_SEL", 0); #2us;
        env.sb.write_adc(a); env.adc.sqr.execute_item(a); #20us;     // path restored
      end
      phase.drop_objection(this);
    endtask
  endclass
endpackage
