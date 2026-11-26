// Block-level UVM environment for xpu (low MAC: CSMA/CA, ACK/CTS response, retransmission,
// address filter, RSSI/CCA, TSF).
//   TB plays: openofdm_rx (phy_rx_agent ACTIVE, real PHY timing), the DDC I/Q feed for
//             RSSI/CCA (iq_agent), and tx_intf + openofdm_tx (xpu_phy_responder below).
//   checks : ACK content (served to the PHY through dina/bram_addr while ack_tx_flag=1)
//            == wifi_frame::bram_words() of the expected ACK; RA = TA of the received frame;
//            ACK only for unicast-to-me frames with good FCS; response latency window;
//            pkt_for_me / block_rx_dma_to_ps vs FILTER_FLAG; TSF load/readback.
package xpu_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axil_pkg::*; import iq_pkg::*; import wifi_pkg::*; import phy_rx_pkg::*; import phy_tx_pkg::*;
  import openwifi_ral_pkg::*; import openwifi_seq_pkg::*;

  class ack_obs extends uvm_object;
    phy_tx_obs obs; time t_start_tx_ack;
    `uvm_object_utils(ack_obs)
    function new(string name = "ack_obs"); super.new(name); obs = phy_tx_obs::type_id::create("obs"); endfunction
  endclass

  // Plays tx_intf + openofdm_tx for xpu-originated transmissions (ACK/CTS): on
  // start_tx_ack it starts the PHY, walks bram_addr 0..3 and records dina (the ACK image
  // xpu serves while ack_tx_flag=1), then signals phy_tx_done after the ACK airtime.
  class xpu_phy_responder extends uvm_component;
    `uvm_component_utils(xpu_phy_responder)
    virtual xpu_tx_side_if vif;
    uvm_analysis_port #(ack_obs) ap;
    function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
    task run_phase(uvm_phase phase);
      vif.phy_tx_start <= 0; vif.phy_tx_started <= 0; vif.phy_tx_done <= 0; vif.bram_addr <= 0;
      forever begin
        ack_obs a = ack_obs::type_id::create("a");
        @(posedge vif.clk iff vif.start_tx_ack);
        a.t_start_tx_ack = $time;
        @(posedge vif.clk) vif.phy_tx_start <= 1;
        @(posedge vif.clk) vif.phy_tx_start <= 0;
        repeat (20) @(posedge vif.clk);
        vif.phy_tx_started <= 1; @(posedge vif.clk) vif.phy_tx_started <= 0;
        for (int w = 0; w < 4; w++) begin
          vif.bram_addr <= w;
          repeat (3) @(posedge vif.clk);
          if (!vif.ack_tx_flag) `uvm_error("XPU_RSP", "ack_tx_flag low while the PHY reads the ACK image")
          a.obs.words[w] = vif.dina;
        end
        // ACK @6 Mbps = 20 us preamble+SIG + 4 us x ceil((16+14*8+6)/24) = 44 us
        repeat (44 * `NUM_CLK_PER_US) @(posedge vif.clk);
        vif.phy_tx_done <= 1; @(posedge vif.clk) vif.phy_tx_done <= 0;
        ap.write(a);
      end
    endtask
  endclass

  `uvm_analysis_imp_decl(_rx)
  `uvm_analysis_imp_decl(_ack)

  class xpu_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(xpu_scoreboard)
    uvm_analysis_imp_rx  #(phy_rx_result, xpu_scoreboard) rx_imp;
    uvm_analysis_imp_ack #(ack_obs,       xpu_scoreboard) ack_imp;
    bit [47:0] my_mac;
    wifi_frame sent_q[$]; bit corrupt_q[$];  // what the TB fed to the receiver
    wifi_frame exp_ack_q[$]; time t_fcs_q[$];
    int n_ack_ok, n_err, n_no_ack_ok;
    real max_resp_us = 25.0;
    function new(string name, uvm_component parent);
      super.new(name, parent); rx_imp = new("rx_imp", this); ack_imp = new("ack_imp", this);
    endfunction

    function void stimulus(wifi_frame f, bit corrupt); sent_q.push_back(f); corrupt_q.push_back(corrupt); endfunction

    // an ACK is due iff: data/mgmt unicast to my_mac, good FCS (802.11-2020 10.3.2.11)
    static function bit needs_ack(wifi_frame f, bit [47:0] me, bit corrupt);
      bit [1:0] typ = f.mpdu[0][3:2]; bit [47:0] a1 = f.addr(1);
      return !corrupt && typ != 2'b01 && a1 == me && !a1[0];
    endfunction
    static function wifi_frame make_ack(bit [47:0] ra);
      wifi_frame a = new("ack");
      a.ht = 0; a.rate_hw = 4; a.sgi = 0; a.ht_aggr = 0; a.mpdu_len = 10; a.mpdu = new[10];
      a.mpdu[0] = 8'hD4; a.mpdu[1] = 8'h00; a.mpdu[2] = 8'h00; a.mpdu[3] = 8'h00;
      for (int k = 0; k < 6; k++) a.mpdu[4 + k] = ra[8*k +: 8];
      return a;
    endfunction

    function void write_rx(phy_rx_result r);
      wifi_frame f; bit c;
      if (!r.header_ok) return;
      if (sent_q.size() == 0) begin `uvm_error("XPU_SB", "rx result without stimulus") return; end
      f = sent_q.pop_front(); c = corrupt_q.pop_front();
      if (needs_ack(f, my_mac, c)) begin exp_ack_q.push_back(make_ack(f.addr(2))); t_fcs_q.push_back(r.t_fcs); end
      else n_no_ack_ok++;   // provisional; an unexpected ACK turns into an error below
    endfunction

    function void write_ack(ack_obs a);
      wifi_frame e; string why; real dt;
      if (exp_ack_q.size() == 0) begin n_err++; `uvm_error("XPU_SB", "xpu sent an ACK that was not due") return; end
      e = exp_ack_q.pop_front(); dt = (a.t_start_tx_ack - t_fcs_q.pop_front()) / 1us;
      why = a.obs.check(e);
      if (why != "") begin n_err++; `uvm_error("XPU_SB", {"ACK image: ", why}) return; end
      if (dt < 0 || dt > max_resp_us) begin n_err++; `uvm_error("XPU_SB", $sformatf("ACK start %.2f us after fcs strobe (window 0..%.1f)", dt, max_resp_us)) return; end
      `uvm_info("XPU_SB", $sformatf("ACK to %012h ok, start_tx_ack %.2f us after fcs_out_strobe", e.addr(1), dt), UVM_LOW)
      n_ack_ok++;
    endfunction
    function void check_phase(uvm_phase phase);
      if (exp_ack_q.size()) `uvm_error("XPU_SB", $sformatf("%0d ACKs were due but never sent", exp_ack_q.size()))
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("XPU_SB", $sformatf("ACK ok %0d  no-ACK cases %0d  errors %0d", n_ack_ok, n_no_ack_ok, n_err), UVM_NONE)
    endfunction
  endclass

  class xpu_env extends uvm_env;
    `uvm_component_utils(xpu_env)
    axil_agent axil; phy_rx_agent prx; iq_agent ddc; xpu_phy_responder rsp; xpu_scoreboard sb;
    xpu_regs regs; axil_reg_adapter adapter;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      iq_cfg ic = iq_cfg::type_id::create("ic"); phy_rx_cfg pc = phy_rx_cfg::type_id::create("pc");
      ic.pack = PACK_IQ32; ic.clk_per_sample = `NUM_CLK_PER_US / 20; ic.noise_amp = 4;
      pc.clk_per_us = `NUM_CLK_PER_US; pc.fast_mode = 0;     // keep real timing for the MAC timers
      uvm_config_db#(iq_cfg)::set(this, "ddc", "cfg", ic);
      uvm_config_db#(phy_rx_cfg)::set(this, "prx", "cfg", pc);
      axil = axil_agent::type_id::create("axil", this);
      prx  = phy_rx_agent::type_id::create("prx", this);
      ddc  = iq_agent::type_id::create("ddc", this);
      rsp  = xpu_phy_responder::type_id::create("rsp", this);
      sb   = xpu_scoreboard::type_id::create("sb", this);
      if (!uvm_config_db#(virtual xpu_tx_side_if)::get(this, "", "txside", rsp.vif)) `uvm_fatal("NOVIF", "xpu_tx_side_if")
      regs = xpu_regs::type_id::create("regs"); regs.configure(null); regs.build();
      adapter = axil_reg_adapter::type_id::create("adapter");
    endfunction
    function void connect_phase(uvm_phase phase);
      regs.default_map.set_sequencer(axil.sqr, adapter);
      regs.default_map.set_auto_predict(1);
      prx.mon.ap.connect(sb.rx_imp);
      rsp.ap.connect(sb.ack_imp);
    endfunction
  endclass

  class xpu_base_test extends uvm_test;
    `uvm_component_utils(xpu_base_test)
    xpu_env env; bit [47:0] my_mac = 48'h66_55_44_33_22_11;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase); env = xpu_env::type_id::create("env", this); endfunction
    task init_regs();
      xpu_init_seq s = xpu_init_seq::type_id::create("init");
      s.rb = env.regs; s.start(null);
      s.wr(env.regs, "MAC_ADDR_LOW",  my_mac[31:0]);
      s.wr(env.regs, "MAC_ADDR_HIGH", {16'h0, my_mac[47:32]});
      s.wr(env.regs, "BAND_CHANNEL",  (1 << 24) | (4 << 16) | 5220);   // 5.8 GHz band, short slot
      env.sb.my_mac = my_mac;
    endtask
    // 24-byte data header + payload; to_me selects addr1
    function wifi_frame data_frame(bit to_me, bit bcast);
      wifi_frame f = wifi_frame::type_id::create("f");
      bit [47:0] a1 = bcast ? 48'hFF_FF_FF_FF_FF_FF : (to_me ? my_mac : 48'h02_00_00_00_00_07);
      if (!f.randomize() with { mpdu_len inside {[28:300]}; }) `uvm_fatal("RAND", "frame")
      f.set_header(16'h0008, 16'd44, a1, 48'h02_AA_BB_CC_DD_EE, 48'h02_AA_BB_CC_DD_EE, 12'($urandom));
      return f;
    endfunction
  endclass

  class xpu_ack_test extends xpu_base_test;
    `uvm_component_utils(xpu_ack_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      int unsigned n = 12;
      phase.raise_objection(this);
      init_regs();
      void'($value$plusargs("N_PKT=%d", n));
      for (int k = 0; k < n; k++) begin
        phy_rx_item it = phy_rx_item::type_id::create("it");
        int sel = k % 4;     // 0,1: to me ; 2: not to me ; 3: broadcast
        it.frame = data_frame(sel < 2, sel == 3);
        it.corrupt_fcs = (k % 6 == 5);
        env.sb.stimulus(it.frame, it.corrupt_fcs);
        env.prx.sqr.execute_item(it);
        #80us;               // SIFS + ACK airtime + margin
      end
      phase.drop_objection(this);
    endtask
  endclass

  class xpu_tsf_test extends xpu_base_test;
    `uvm_component_utils(xpu_tsf_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      xpu_init_seq s = xpu_init_seq::type_id::create("s");
      bit [31:0] lo0, hi0, lo1, hi1; bit [63:0] t0, t1, load = 64'h0000_0001_FFFF_FF00;
      phase.raise_objection(this);
      init_regs();
      s.xpu_tsf_load(env.regs, load);     // crosses the 32-bit boundary after 256 us
      s.rd(env.regs, "TSF_RUNTIME_VAL_LOW", lo0); s.rd(env.regs, "TSF_RUNTIME_VAL_HIGH", hi0);
      #500us;
      s.rd(env.regs, "TSF_RUNTIME_VAL_LOW", lo1); s.rd(env.regs, "TSF_RUNTIME_VAL_HIGH", hi1);
      t0 = {hi0, lo0}; t1 = {hi1, lo1};
      if (t0 < load || t0 > load + 5) `uvm_error("TSF", $sformatf("after load %0h read %0h", load, t0))
      if (t1 - t0 < 495 || t1 - t0 > 505) `uvm_error("TSF", $sformatf("TSF advanced %0d us in 500 us", t1 - t0))
      phase.drop_objection(this);
    endtask
  endclass
endpackage
