// Chip-level UVM environment: openwifi_core_top (all six openwifi IPs as wired in
// system.bd) between a software/DMA model on one side and an over-the-air peer station
// on the other.
//
//   host side  : axil_agent + openwifi_regmodel (PS M_AXI_GP), AXIS agents in place of
//                axi_dma_0/1 (TX MM2S, RX S2MM, side_ch S2MM/MM2S), irq_if
//   RF side    : ADC iq_agent (adc_clk 40 MHz) / DAC iq monitor
//   peer       : a second openofdm_tx + openofdm_rx in tb_chip, already verified at block
//                level, used as the "other station": peer TX renders arbitrary frames to
//                I/Q for the DUT receiver, peer RX decodes whatever the DUT puts on air
//   white-box  : passive monitors on the DUT's internal openofdm_rx outputs and on the
//                tx_intf<->openofdm_tx bus (localises failures to a block)
//
//   scoreboards: chip_air_sb  host TX frame / xpu ACK  ->  DAC burst + peer decode + BRAM image
//                chip_rx_sb   peer frame  ->  DUT openofdm_rx  ->  rx_intf DMA descriptor
package chip_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axil_pkg::*; import axis_pkg::*; import iq_pkg::*; import wifi_pkg::*;
  import phy_rx_pkg::*; import phy_tx_pkg::*; import openwifi_ral_pkg::*; import openwifi_seq_pkg::*;

  // ------------------------------------------------------------------ expectations
  class air_expect extends uvm_object;
    wifi_frame f; string why;            // "host-tx" / "ack"
    time t_ref; real gap_min_us, gap_max_us;   // response-time window (t_ref = end of stimulus)
    `uvm_object_utils(air_expect)
    function new(string name = "air_expect"); super.new(name); endfunction
  endclass

  `uvm_analysis_imp_decl(_dac)
  `uvm_analysis_imp_decl(_prx)
  `uvm_analysis_imp_decl(_obs)

  class chip_air_sb extends uvm_scoreboard;
    `uvm_component_utils(chip_air_sb)
    uvm_analysis_imp_dac #(iq_item,       chip_air_sb) dac_imp;
    uvm_analysis_imp_prx #(phy_rx_result, chip_air_sb) prx_imp;
    uvm_analysis_imp_obs #(phy_tx_obs,    chip_air_sb) obs_imp;
    air_expect dac_q[$], prx_q[$], obs_q[$];
    int n_ok_dac, n_ok_prx, n_ok_obs, n_err;
    event air_done_ev;
    event dac_ev; time t_last_dac_end;      // end of the last DUT burst on the DAC (last sample)
    function new(string name, uvm_component parent);
      super.new(name, parent); dac_imp = new("dac_imp", this); prx_imp = new("prx_imp", this); obs_imp = new("obs_imp", this);
    endfunction
    function void expect_air(air_expect e); dac_q.push_back(e); prx_q.push_back(e); obs_q.push_back(e); endfunction

    function void write_obs(phy_tx_obs o);
      air_expect e; string w;
      if (!obs_q.size()) begin n_err++; `uvm_error("AIR_SB", "DUT PHY transmitted with nothing expected") return; end
      e = obs_q.pop_front(); w = o.check(e.f);
      if (w != "") begin n_err++; `uvm_error("AIR_SB", {e.why, " BRAM image: ", w}) end else n_ok_obs++;
    endfunction
    function void write_dac(iq_item b);
      air_expect e; real gap;
      if (!dac_q.size()) begin n_err++; `uvm_error("AIR_SB", $sformatf("unexpected DAC burst (%0d samples)", b.size())) return; end
      t_last_dac_end = b.t_start + b.size() * 50ns; ->dac_ev;
      e = dac_q.pop_front();
      if (b.size() != e.f.tx_samples()) begin
        n_err++; `uvm_error("AIR_SB", $sformatf("%s %s: DAC burst %0d samples, expected %0d", e.why, e.f.convert2string(), b.size(), e.f.tx_samples()))
      end else n_ok_dac++;
      if (e.t_ref != 0) begin
        gap = (b.t_start - e.t_ref) / 1us;
        if (gap < e.gap_min_us || gap > e.gap_max_us) begin
          n_err++; `uvm_error("AIR_SB", $sformatf("%s on air %.2f us after stimulus end (window %.1f..%.1f us)", e.why, gap, e.gap_min_us, e.gap_max_us))
        end else `uvm_info("AIR_SB", $sformatf("%s response gap %.2f us", e.why, gap), UVM_LOW)
      end
    endfunction
    function void write_prx(phy_rx_result r);
      air_expect e; string w;
      if (!prx_q.size()) begin n_err++; `uvm_error("AIR_SB", {"peer decoded an unexpected frame: ", r.convert2string()}) return; end
      e = prx_q.pop_front(); w = r.check(e.f);
      if (w != "") begin n_err++; `uvm_error("AIR_SB", {e.why, " decoded by peer: ", w}) end else n_ok_prx++;
      ->air_done_ev;
    endfunction
    function void check_phase(uvm_phase phase);
      if (dac_q.size() || prx_q.size() || obs_q.size())
        `uvm_error("AIR_SB", $sformatf("outstanding air frames: phy %0d dac %0d peer-decode %0d", obs_q.size(), dac_q.size(), prx_q.size()))
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("AIR_SB", $sformatf("BRAM ok %0d  DAC ok %0d  peer-decoded ok %0d  errors %0d", n_ok_obs, n_ok_dac, n_ok_prx, n_err), UVM_NONE)
    endfunction
  endclass

  class rx_expect_c extends uvm_object;
    wifi_frame f; bit to_host = 1;
    `uvm_object_utils(rx_expect_c)
    function new(string name = "rx_expect_c"); super.new(name); endfunction
  endclass

  `uvm_analysis_imp_decl(_dma)
  `uvm_analysis_imp_decl(_core)

  class chip_rx_sb extends uvm_scoreboard;
    `uvm_component_utils(chip_rx_sb)
    uvm_analysis_imp_dma  #(axis_item,     chip_rx_sb) dma_imp;
    uvm_analysis_imp_core #(phy_rx_result, chip_rx_sb) core_imp;   // DUT's own openofdm_rx
    rx_expect_c core_q[$], dma_q[$];
    int n_ok_core, n_ok_dma, n_err, n_filtered;
    event dma_ev;
    bit [63:0] tsf_q[$];                       // RX descriptor TSF of every delivered packet
    function new(string name, uvm_component parent);
      super.new(name, parent); dma_imp = new("dma_imp", this); core_imp = new("core_imp", this);
    endfunction
    function void expect_rx(rx_expect_c e);
      core_q.push_back(e);
      if (e.to_host) dma_q.push_back(e); else n_filtered++;
    endfunction
    function void write_core(phy_rx_result r);
      rx_expect_c e; string w;
      if (!r.header_ok) return;
      if (!core_q.size()) begin `uvm_warning("RX_SB", {"DUT decoded a frame no test sent (own TX echo?): ", r.convert2string()}) return; end
      e = core_q.pop_front(); w = r.check(e.f);
      if (w != "") begin n_err++; `uvm_error("RX_SB", {"DUT openofdm_rx: ", w}) end else n_ok_core++;
    endfunction
    function void write_dma(axis_item t);
      byte unsigned b[$], p[$]; rx_desc d = rx_desc::type_id::create("d"); rx_expect_c e;
      t.to_bytes(b);
      if (!d.parse(b)) begin n_err++; `uvm_error("RX_SB", "unparsable RX DMA packet") return; end
      tsf_q.push_back(d.tsf);
      if (!dma_q.size()) begin n_err++; `uvm_error("RX_SB", {"unexpected RX DMA packet: ", d.convert2string()}) return; end
      e = dma_q.pop_front(); e.f.psdu(p);
      if (d.len != p.size() || d.rate_idx != e.f.rx_rate_idx() || !d.fcs_ok) begin
        n_err++; `uvm_error("RX_SB", $sformatf("descriptor %s vs expected len %0d rate_idx 0x%0h", d.convert2string(), p.size(), e.f.rx_rate_idx()))
      end else begin
        for (int k = 0; k < p.size() - 1; k++) if (d.payload[k] != p[k]) begin
          n_err++; `uvm_error("RX_SB", $sformatf("RX DMA payload byte %0d 0x%02h != 0x%02h", k, d.payload[k], p[k])) return;
        end
        n_ok_dma++;
      end
      ->dma_ev;
    endfunction
    function void check_phase(uvm_phase phase);
      if (core_q.size() || dma_q.size()) `uvm_error("RX_SB", $sformatf("outstanding: %0d never decoded, %0d never reached the host", core_q.size(), dma_q.size()))
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("RX_SB", $sformatf("decoded ok %0d  delivered ok %0d  filtered %0d  errors %0d", n_ok_core, n_ok_dma, n_filtered, n_err), UVM_NONE)
    endfunction
  endclass

  // ------------------------------------------------------------------ peer station
  // renders frames with the peer openofdm_tx and hands back the 20 Msps burst
  class peer_tx_capture extends uvm_subscriber #(iq_item);
    `uvm_component_utils(peer_tx_capture)
    mailbox #(iq_item) mb = new();
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void write(iq_item t); void'(mb.try_put(t)); endfunction
  endclass

  class peer_env extends uvm_env;
    `uvm_component_utils(peer_env)
    axil_agent tx_axil, rx_axil; phy_tx_agent ptx; iq_agent tx_iq; phy_rx_agent prx; peer_tx_capture cap;
    openofdm_tx_regs tx_regs; openofdm_rx_regs rx_regs; axil_reg_adapter adapter;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      phy_tx_cfg pc = phy_tx_cfg::type_id::create("pc"); iq_cfg ic = iq_cfg::type_id::create("ic");
      pc.role = PHY_TX_BRAM_SERVER;
      ic.pack = PACK_IQ32; ic.end_gap_clks = 1000; ic.end_gap_samples = 100000; ic.use_ready = 1;
      uvm_config_db#(phy_tx_cfg)::set(this, "ptx", "cfg", pc);
      uvm_config_db#(iq_cfg)::set(this, "tx_iq", "cfg", ic);
      uvm_config_db#(uvm_active_passive_enum)::set(this, "tx_iq", "is_active", UVM_PASSIVE);
      uvm_config_db#(uvm_active_passive_enum)::set(this, "prx", "is_active", UVM_PASSIVE);
      tx_axil = axil_agent::type_id::create("tx_axil", this);
      rx_axil = axil_agent::type_id::create("rx_axil", this);
      ptx = phy_tx_agent::type_id::create("ptx", this);
      tx_iq = iq_agent::type_id::create("tx_iq", this);
      prx = phy_rx_agent::type_id::create("prx", this);
      cap = peer_tx_capture::type_id::create("cap", this);
      adapter = axil_reg_adapter::type_id::create("adapter");
      tx_regs = openofdm_tx_regs::type_id::create("peer_tx_regs"); tx_regs.configure(null); tx_regs.build();
      rx_regs = openofdm_rx_regs::type_id::create("peer_rx_regs"); rx_regs.configure(null); rx_regs.build();
    endfunction
    function void connect_phase(uvm_phase phase);
      tx_regs.default_map.set_sequencer(tx_axil.sqr, adapter);
      rx_regs.default_map.set_sequencer(rx_axil.sqr, adapter);
      tx_iq.mon.ap.connect(cap.analysis_export);
    endfunction
    // frame -> I/Q burst (20 Msps), blocking
    task render(wifi_frame f, output iq_item b);
      ptx.sqr.execute_item(f);
      cap.mb.get(b);
    endtask
  endclass

  // ------------------------------------------------------------------ chip env
  class chip_cfg extends uvm_object;
    bit [47:0] dut_mac  = 48'h66_55_44_33_22_12;
    bit [47:0] peer_mac = 48'h02_AA_BB_CC_DD_EE;
    real       sifs_min_us = 10.0, sifs_max_us = 22.0;   // see ARCHITECTURE.md "ACK timing"
    real       chan_gain = 0.5;  real chan_cfo_hz = 0.0;
    `uvm_object_utils(chip_cfg)
    function new(string name = "chip_cfg"); super.new(name); endfunction
  endclass

  class chip_env extends uvm_env;
    `uvm_component_utils(chip_env)
    chip_cfg cfg;
    axil_agent axil; openwifi_regmodel rm; axil_reg_adapter adapter;
    axis_agent dma_tx, dma_rx, dma_sch;
    iq_agent adc, dac;
    phy_rx_agent core_rx;      // passive, DUT openofdm_rx outputs
    phy_tx_agent core_tx;      // passive, DUT tx_intf <-> openofdm_tx
    peer_env peer;
    chip_air_sb air_sb; chip_rx_sb rx_sb;
    virtual irq_if irq;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      axis_cfg c_tx = axis_cfg::type_id::create("c_tx"), c_rx = axis_cfg::type_id::create("c_rx"), c_sch = axis_cfg::type_id::create("c_sch");
      iq_cfg c_adc = iq_cfg::type_id::create("c_adc"), c_dac = iq_cfg::type_id::create("c_dac");
      phy_tx_cfg c_core_tx = phy_tx_cfg::type_id::create("c_core_tx");
      if (!uvm_config_db#(chip_cfg)::get(this, "", "cfg", cfg)) cfg = chip_cfg::type_id::create("cfg");
      c_tx.role = AXIS_MASTER; c_rx.role = AXIS_SLAVE; c_sch.role = AXIS_SLAVE;
      c_rx.ready_mode = READY_RANDOM; c_rx.ready_pct = 70;
      c_adc.pack = PACK_ADC64; c_adc.valid_style = VALID_LEVEL; c_adc.clk_per_sample = 1; c_adc.repeat_n = 2;
      void'($value$plusargs("ADC_NOISE=%d", c_adc.noise_amp));
      c_dac.pack = PACK_ADC64; c_dac.valid_style = VALID_LEVEL; c_dac.decim = 2; c_dac.end_gap_samples = 64;
      c_core_tx.role = PHY_TX_PASSIVE;
      uvm_config_db#(axis_cfg)::set(this, "dma_tx", "cfg", c_tx);
      uvm_config_db#(axis_cfg)::set(this, "dma_rx", "cfg", c_rx);
      uvm_config_db#(axis_cfg)::set(this, "dma_sch", "cfg", c_sch);
      uvm_config_db#(iq_cfg)::set(this, "adc", "cfg", c_adc);
      uvm_config_db#(iq_cfg)::set(this, "dac", "cfg", c_dac);
      uvm_config_db#(uvm_active_passive_enum)::set(this, "dac", "is_active", UVM_PASSIVE);
      uvm_config_db#(uvm_active_passive_enum)::set(this, "core_rx", "is_active", UVM_PASSIVE);
      uvm_config_db#(phy_tx_cfg)::set(this, "core_tx", "cfg", c_core_tx);
      axil = axil_agent::type_id::create("axil", this);
      dma_tx = axis_agent::type_id::create("dma_tx", this);
      dma_rx = axis_agent::type_id::create("dma_rx", this);
      dma_sch = axis_agent::type_id::create("dma_sch", this);
      adc = iq_agent::type_id::create("adc", this);
      dac = iq_agent::type_id::create("dac", this);
      core_rx = phy_rx_agent::type_id::create("core_rx", this);
      core_tx = phy_tx_agent::type_id::create("core_tx", this);
      peer = peer_env::type_id::create("peer", this);
      air_sb = chip_air_sb::type_id::create("air_sb", this);
      rx_sb  = chip_rx_sb::type_id::create("rx_sb", this);
      rm = openwifi_regmodel::type_id::create("rm"); rm.build();
      adapter = axil_reg_adapter::type_id::create("adapter");
      if (!uvm_config_db#(virtual irq_if)::get(this, "", "irq", irq)) `uvm_fatal("NOVIF", "irq_if")
    endfunction
    function void connect_phase(uvm_phase phase);
      rm.default_map.set_sequencer(axil.sqr, adapter);
      rm.default_map.set_auto_predict(1);
      dac.mon.ap.connect(air_sb.dac_imp);
      peer.prx.mon.ap.connect(air_sb.prx_imp);
      core_tx.mon.ap.connect(air_sb.obs_imp);
      core_rx.mon.ap.connect(rx_sb.core_imp);
      dma_rx.mon.ap.connect(rx_sb.dma_imp);
    endfunction
  endclass

  // ------------------------------------------------------------------ virtual sequences
  virtual class chip_vseq_base extends ow_reg_seq_base;
    chip_env env;
    function new(string name); super.new(name); endfunction
    // host TX exactly like openwifi_tx(): TX_CONFIG/PHY_HDR_CONFIG, then MM2S DMA
    task host_tx(wifi_frame f, bit [5:0] bd_idx);
      tx_kick_seq kick = tx_kick_seq::type_id::create("kick");
      axis_item dm = axis_item::type_id::create("dm"); byte unsigned b[$];
      kick.rb = env.rm.tx_intf; kick.f = f; kick.bd_wr_idx = bd_idx; kick.start(null, this);
      f.tx_dma_bytes(b); dm.from_bytes_word_padded(b);
      env.dma_tx.sqr.execute_item(dm);
    endtask
    // peer carrier sense: wait until the DUT has been silent on the DAC for 'us'
    task wait_medium_idle(real us = 4.0);
      int unsigned quiet = 0, need = $rtoi(us * 40);   // dac_clk = 40 MHz
      while (quiet < need) begin
        @(posedge env.dac.vif.clk);
        quiet = (env.dac.vif.data[31:0] == 0) ? quiet + 1 : 0;
      end
    endtask
    // peer -> air -> DUT ADC, with the configured channel
    task peer_send(wifi_frame f, int unsigned idle_before = 400, output time t_end);
      iq_item b;
      env.peer.render(f, b);
      wait_medium_idle();
      iq_impair::scale(b, env.cfg.chan_gain);
      if (env.cfg.chan_cfo_hz != 0) iq_impair::cfo(b, env.cfg.chan_cfo_hz);
      b.idle_before = idle_before;
      env.adc.sqr.execute_item(b);
      t_end = b.t_end;
    endtask
    function wifi_frame ack_frame(bit [47:0] ra);
      wifi_frame a = new("ack");
      a.ht = 0; a.rate_hw = 4; a.sgi = 0; a.ht_aggr = 0; a.mpdu_len = 10; a.mpdu = new[10];
      a.mpdu[0] = 8'hD4; a.mpdu[1] = 0; a.mpdu[2] = 0; a.mpdu[3] = 0;
      for (int b = 0; b < 6; b++) a.mpdu[4 + b] = ra[8*b +: 8];
      return a;
    endfunction
    // the peer answers the DUT's last burst with a pre-rendered frame, SIFS after its last sample
    task peer_reply_sifs(iq_item b, real sifs_us = 16);
      real waited;
      @(env.air_sb.dac_ev);
      waited = ($time - env.air_sb.t_last_dac_end) / 1us;
      b.idle_before = (sifs_us > waited) ? $rtoi((sifs_us - waited) * 20) : 0;
      iq_impair::scale(b, env.cfg.chan_gain);
      env.adc.sqr.execute_item(b);
    endtask
    task rd(ow_block_base blk, string name, output bit [31:0] v);
      uvm_status_e st; uvm_reg_data_t d; blk.r(name).read(st, d, .parent(this)); v = d;
    endtask
    function wifi_frame data_frame(bit [47:0] a1, bit [47:0] a2, int unsigned len_min = 28, int unsigned len_max = 1500);
      wifi_frame f = wifi_frame::type_id::create("f");
      if (!f.randomize() with { mpdu_len inside {[len_min:len_max]}; }) `uvm_fatal("RAND", "frame")
      f.set_header(16'h0008, 16'd0, a1, a2, a2, 12'($urandom));
      return f;
    endfunction
  endclass

  // openwifi_start() on the DUT + hw_init of the peer PHYs
  class chip_bringup_vseq extends chip_vseq_base;
    `uvm_object_utils(chip_bringup_vseq)
    bit [31:0] filter_flag = 32'h2000;
    function new(string name = "chip_bringup_vseq"); super.new(name); endfunction
    task body();
      openwifi_start_seq st = openwifi_start_seq::type_id::create("st");
      openofdm_tx_init_seq ptx = openofdm_tx_init_seq::type_id::create("ptx");
      openofdm_rx_init_seq prx = openofdm_rx_init_seq::type_id::create("prx");
      st.rm = env.rm; st.mac_addr = env.cfg.dut_mac; st.filter_flag = filter_flag;
      ptx.rb = env.peer.tx_regs; prx.rb = env.peer.rx_regs;
      fork st.start(null, this); ptx.start(null, this); prx.start(null, this); join
    endtask
  endclass

  class chip_tx_vseq extends chip_vseq_base;
    `uvm_object_utils(chip_tx_vseq)
    int unsigned n = 8; bit broadcast = 1; bit rand_queue = 0;
    function new(string name = "chip_tx_vseq"); super.new(name); endfunction
    task body();
      for (int k = 0; k < n; k++) begin
        air_expect e = air_expect::type_id::create("e");
        // broadcast/no-ack so the DUT does not wait for an ACK the peer never sends
        e.f = data_frame(broadcast ? 48'hFF_FF_FF_FF_FF_FF : env.cfg.peer_mac, env.cfg.dut_mac, 28, 1500);
        e.f.need_ack = 0; e.f.queue_idx = rand_queue ? 2'($urandom) : 0; e.why = "host-tx";
        env.air_sb.expect_air(e);
        host_tx(e.f, k[5:0]);
        @(env.air_sb.air_done_ev);
      end
    endtask
  endclass

  class chip_rx_vseq extends chip_vseq_base;
    `uvm_object_utils(chip_rx_vseq)
    int unsigned n = 8;
    function new(string name = "chip_rx_vseq"); super.new(name); endfunction
    task body();
      for (int k = 0; k < n; k++) begin
        rx_expect_c e = rx_expect_c::type_id::create("e"); time t;
        // addressed to a third station: no ACK, but MONITOR_ALL delivers it to the host
        e.f = data_frame(48'h99_00_00_00_00_02, env.cfg.peer_mac, 28, 1500);
        env.rx_sb.expect_rx(e);
        peer_send(e.f, 400, t);
        @(env.rx_sb.dma_ev);
      end
    endtask
  endclass

  // unicast to the DUT: frame delivered to host AND an ACK to the peer within SIFS window
  class chip_ack_vseq extends chip_vseq_base;
    `uvm_object_utils(chip_ack_vseq)
    int unsigned n = 6;
    function new(string name = "chip_ack_vseq"); super.new(name); endfunction
    task body();
      for (int k = 0; k < n; k++) begin
        rx_expect_c e = rx_expect_c::type_id::create("e"); air_expect a = air_expect::type_id::create("a"); time t_end;
        e.f = data_frame(env.cfg.dut_mac, env.cfg.peer_mac, 28, 600);
        a.f = new("ack"); a.f.ht = 0; a.f.rate_hw = 4; a.f.sgi = 0; a.f.ht_aggr = 0; a.f.mpdu_len = 10; a.f.mpdu = new[10];
        a.f.mpdu[0] = 8'hD4; a.f.mpdu[1] = 0; a.f.mpdu[2] = 0; a.f.mpdu[3] = 0;
        for (int b = 0; b < 6; b++) a.f.mpdu[4 + b] = env.cfg.peer_mac[8*b +: 8];
        a.why = "ack"; a.gap_min_us = env.cfg.sifs_min_us; a.gap_max_us = env.cfg.sifs_max_us;
        env.rx_sb.expect_rx(e);
        env.air_sb.expect_air(a);
        peer_send(e.f, 400, t_end); a.t_ref = t_end;
        fork @(env.air_sb.air_done_ev); @(env.rx_sb.dma_ev); join
      end
    endtask
  endclass

  // ------------------------------------------------------------------ tests
  class chip_base_test extends uvm_test;
    `uvm_component_utils(chip_base_test)
    chip_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase); env = chip_env::type_id::create("env", this); endfunction
    task bringup(bit [31:0] filter_flag = 32'h2000);
      chip_bringup_vseq b = chip_bringup_vseq::type_id::create("b");
      b.env = env; b.filter_flag = filter_flag; b.start(null);
    endtask
    function void end_of_elaboration_phase(uvm_phase phase);
      uvm_top.set_timeout(50ms, 1);
    endfunction
  endclass

  // all registers of all IPs through the real address decode: reset values + access
  class chip_reg_test extends chip_base_test;
    `uvm_component_utils(chip_reg_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      uvm_reg_hw_reset_seq rs = uvm_reg_hw_reset_seq::type_id::create("rs");
      phase.raise_objection(this);
      rs.model = env.rm; rs.start(null);
      phase.drop_objection(this);
    endtask
  endclass

  class chip_tx_test extends chip_base_test;
    `uvm_component_utils(chip_tx_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      chip_tx_vseq v = chip_tx_vseq::type_id::create("v");
      phase.raise_objection(this);
      bringup(); v.env = env; void'($value$plusargs("N_PKT=%d", v.n)); v.start(null);
      #20us; phase.drop_objection(this);
    endtask
  endclass

  class chip_rx_test extends chip_base_test;
    `uvm_component_utils(chip_rx_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      chip_rx_vseq v = chip_rx_vseq::type_id::create("v");
      phase.raise_objection(this);
      bringup(); v.env = env; void'($value$plusargs("N_PKT=%d", v.n)); v.start(null);
      #20us; phase.drop_objection(this);
    endtask
  endclass

  class chip_ack_test extends chip_base_test;
    `uvm_component_utils(chip_ack_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      chip_ack_vseq v = chip_ack_vseq::type_id::create("v");
      phase.raise_objection(this);
      bringup(32'h0000_0600);                 // UNICAST_FOR_US | BROADCAST_ALL_ONE
      v.env = env; v.start(null);
      #50us; phase.drop_objection(this);
    endtask
  endclass

  // TX and RX traffic interleaved with the medium shared: exercises CCA/backoff,
  // mute_adc_out_to_bb during own TX, and rx_intf/tx_intf DMA concurrency.
  // The peer defers while the DUT is on air (wait_medium_idle); the DUT defers through
  // CSMA/CCA. A simultaneous start is still possible (as on a real channel); if it
  // happens the scoreboards report the lost frame -- rerun with another seed and treat a
  // reproducible loss as a bug.
  class chip_mixed_test extends chip_base_test;
    `uvm_component_utils(chip_mixed_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      chip_tx_vseq t = chip_tx_vseq::type_id::create("t"); chip_rx_vseq r = chip_rx_vseq::type_id::create("r");
      phase.raise_objection(this);
      bringup(); t.env = env; r.env = env; t.n = 10; r.n = 10;
      fork t.start(null); r.start(null); join
      #50us; phase.drop_objection(this);
    endtask
  endclass

  // ------------------------------------------------------------------ CHP-07 / CHP-08
  // need_ack host frame to the peer. The peer ACKs attempt number ack_on (0 = never), SIFS
  // after it. Every attempt must be on air and decoded by the peer, retries with the FC Retry
  // bit (xpu sets it in the BRAM copy), and PKT_INFO must report num_retrans = attempts - 1.
  class chip_retx_vseq extends chip_vseq_base;
    `uvm_object_utils(chip_retx_vseq)
    int unsigned ack_on = 1, limit = 3, n_attempts;
    bit [3:0] num_retrans;
    function new(string name = "chip_retx_vseq"); super.new(name); endfunction
    task body();
      wifi_frame f = data_frame(env.cfg.peer_mac, env.cfg.dut_mac, 40, 400), ack = ack_frame(env.cfg.dut_mac);
      iq_item ack_iq; bit [31:0] info1; int unsigned n_exp;
      f.need_ack = 1; f.queue_idx = 0; f.retry_limit = 4'(limit);
      env.peer.render(ack, ack_iq);
      n_exp = (ack_on == 0) ? 1 + limit : ack_on;
      for (int k = 0; k < n_exp; k++) begin
        air_expect e = air_expect::type_id::create("e");
        e.f = wifi_frame::type_id::create("fk"); e.f.copy(f); e.f.mpdu = new[f.mpdu.size()](f.mpdu);
        if (k > 0) e.f.mpdu[1] |= 8'h08;                       // Retry
        e.why = $sformatf("attempt %0d", k + 1);
        env.air_sb.expect_air(e);
      end
      if (ack_on) begin
        rx_expect_c r = rx_expect_c::type_id::create("r"); r.f = ack; env.rx_sb.expect_rx(r);   // UNICAST_FOR_US delivers the ACK
      end
      fork
        host_tx(f, 6'd1);
        if (ack_on) begin
          for (int k = 1; k < ack_on; k++) @(env.air_sb.dac_ev);
          peer_reply_sifs(ack_iq);
        end
      join
      env.irq.wait_tx_itrpt(400_000);
      #2us;
      rd(env.rm.tx_intf, "PKT_INFO1", info1);
      num_retrans = info1[3:0]; n_attempts = n_exp;
      if (info1 == 32'hFFFF_FFFF) `uvm_error("RETX", "no tx_status entry after the frame")
      else if (num_retrans != n_exp - 1) `uvm_error("RETX", $sformatf("PKT_INFO1 num_retrans %0d, expected %0d (%0d attempts)", num_retrans, n_exp - 1, n_exp))
      else `uvm_info("RETX", $sformatf("%0d attempt(s), num_retrans %0d", n_exp, num_retrans), UVM_LOW)
      #100us;
    endtask
  endclass

  class chip_retrans_test extends chip_base_test;
    `uvm_component_utils(chip_retrans_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(100ms, 1); endfunction
    task run_phase(uvm_phase phase);
      chip_retx_vseq v; int unsigned ack_on[3] = '{3, 2, 0};   // ACK the 3rd / 2nd attempt / never
      phase.raise_objection(this);
      bringup(32'h0000_0600);
      foreach (ack_on[i]) begin
        v = chip_retx_vseq::type_id::create("v"); v.env = env; v.ack_on = ack_on[i]; v.limit = 3; v.start(null);
      end
      phase.drop_objection(this);
    endtask
  endclass

  class chip_tx_ack_test extends chip_base_test;
    `uvm_component_utils(chip_tx_ack_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      bringup(32'h0000_0600);
      repeat (4) begin
        chip_retx_vseq v = chip_retx_vseq::type_id::create("v");
        v.env = env; v.ack_on = 1; v.limit = 3; v.start(null);
      end
      phase.drop_objection(this);
    endtask
  endclass

  // ------------------------------------------------------------------ CHP-09
  // filter flag matrix end to end: delivered to the host (RX DMA) or not, per FILTER_FLAG;
  // frames unicast to the DUT are ACKed on air whatever the filter says.
  class chip_filter_test extends chip_base_test;
    `uvm_component_utils(chip_filter_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(200ms, 1); endfunction
    task run_phase(uvm_phase phase);
      bit [31:0] flags[$] = '{32'h2000, 32'h0600, 32'h0200, 32'h0400, 32'h0000};
      chip_rx_vseq h = chip_rx_vseq::type_id::create("h");
      phase.raise_objection(this);
      foreach (flags[fi]) begin
        if (fi == 0) bringup(flags[fi]);
        else begin uvm_status_e st; env.rm.xpu.r("FILTER_FLAG").write(st, flags[fi]); end
        h.env = env;
        for (int k = 0; k < 4; k++) begin
          rx_expect_c e = rx_expect_c::type_id::create("e"); time t;
          bit [47:0] a1 = (k == 0) ? env.cfg.dut_mac : (k == 1) ? 48'hFF_FF_FF_FF_FF_FF : 48'h99_00_00_00_00_02;
          e.f = h.data_frame(a1, env.cfg.peer_mac, 28, 300);
          if (k == 3) begin e.f.mpdu[0] = 8'h80; e.f.mpdu[1] = 8'h00; for (int b = 0; b < 6; b++) e.f.mpdu[4 + b] = 8'hFF; a1 = '1; end   // beacon
          e.to_host = flags[fi][13] || (flags[fi][9] && a1 == env.cfg.dut_mac) || (flags[fi][10] && a1 == 48'hFF_FF_FF_FF_FF_FF);
          env.rx_sb.expect_rx(e);
          if (a1 == env.cfg.dut_mac) begin
            air_expect a = air_expect::type_id::create("a");
            a.f = h.ack_frame(env.cfg.peer_mac); a.why = "ack"; a.gap_min_us = env.cfg.sifs_min_us; a.gap_max_us = env.cfg.sifs_max_us;
            env.air_sb.expect_air(a);
            h.peer_send(e.f, 400, t); a.t_ref = t;
            @(env.air_sb.air_done_ev);
          end else h.peer_send(e.f, 400, t);
          #100us;
        end
        `uvm_info("FILTER", $sformatf("FILTER_FLAG 0x%04h done (delivered %0d, filtered %0d so far)", flags[fi], env.rx_sb.n_ok_dma, env.rx_sb.n_filtered), UVM_LOW)
      end
      phase.drop_objection(this);
    endtask
  endclass

  // ------------------------------------------------------------------ CHP-10
  // FPGA internal loopback (rx_intf IQ_SRC_SEL[8]): the DUT's own transmission goes through its
  // own openofdm_rx and must reach the host on RX DMA byte-exact (MONITOR_ALL), besides being
  // on air for the peer. First on-board test (FLOW.md S6a) uses the same mode.
  class chip_loopback_test extends chip_base_test;
    `uvm_component_utils(chip_loopback_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      uvm_status_e st;
      phase.raise_objection(this);
      bringup();
      env.rm.rx_intf.r("IQ_SRC_SEL").write(st, 32'h100);
      for (int k = 0; k < 6; k++) begin
        chip_tx_vseq t = chip_tx_vseq::type_id::create("t");
        air_expect e = air_expect::type_id::create("e"); rx_expect_c r = rx_expect_c::type_id::create("r");
        t.env = env;
        e.f = t.data_frame(48'hFF_FF_FF_FF_FF_FF, env.cfg.dut_mac, 28, 1000); e.f.need_ack = 0; e.f.queue_idx = 0; e.why = "loopback-tx";
        r.f = e.f;
        env.air_sb.expect_air(e); env.rx_sb.expect_rx(r);
        t.host_tx(e.f, k[5:0]);
        fork @(env.air_sb.air_done_ev); @(env.rx_sb.dma_ev); join
      end
      env.rm.rx_intf.r("IQ_SRC_SEL").write(st, 0);
      #20us; phase.drop_objection(this);
    endtask
  endclass

  // ------------------------------------------------------------------ CHP-11
  // side_ch CSI capture at chip level: every peer frame gives one record on the side_ch DMA
  // (2 + 56 + num_eq*52 words) whose TSF equals the TSF in the RX descriptor of the same frame
  // (both latched at SIGNAL valid).
  class chip_sch_collect extends uvm_subscriber #(axis_item);
    `uvm_component_utils(chip_sch_collect)
    bit [63:0] words[$]; bit [63:0] rec_tsf[$]; int unsigned rec_len = 2 + 56 + 52;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void write(axis_item t);
      foreach (t.data[i]) words.push_back(t.data[i]);
      while (words.size() >= rec_len) begin rec_tsf.push_back(words[0]); repeat (rec_len) void'(words.pop_front()); end
    endfunction
  endclass

  class chip_sidech_test extends chip_base_test;
    `uvm_component_utils(chip_sidech_test)
    chip_sch_collect col;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase); super.build_phase(phase); col = chip_sch_collect::type_id::create("col", this); endfunction
    function void connect_phase(uvm_phase phase); env.dma_sch.mon.ap.connect(col.analysis_export); endfunction
    task run_phase(uvm_phase phase);
      chip_rx_vseq v = chip_rx_vseq::type_id::create("v");
      uvm_status_e st; int unsigned n = 6;
      phase.raise_objection(this);
      bringup();
      env.rm.side_ch.r("MULTI_RST").write(st, 4); env.rm.side_ch.r("MULTI_RST").write(st, 0);
      env.rm.side_ch.r("CONFIG").write(st, 1); env.rm.side_ch.r("IQ_CAPTURE").write(st, 0);
      env.rm.side_ch.r("NUM_EQ").write(st, 1);
      v.env = env; v.n = n; v.start(null);
      #50us;
      begin   // driver get_side_info(): pull whole records; the NUM_DMA_SYMBOL write starts the DMA
        uvm_reg_data_t d; int unsigned w;
        env.rm.side_ch.r("M_AXIS_DATA_COUNT").read(st, d);
        w = col.rec_len * (int'(d) / col.rec_len);
        if (w) env.rm.side_ch.r("NUM_DMA_SYMBOL").write(st, w);
      end
      #100us;
      if (col.rec_tsf.size() != n) `uvm_error("SIDECH", $sformatf("%0d side_ch records for %0d received frames", col.rec_tsf.size(), n))
      foreach (col.rec_tsf[i]) if (i < env.rx_sb.tsf_q.size() && col.rec_tsf[i] != env.rx_sb.tsf_q[i])
        `uvm_error("SIDECH", $sformatf("record %0d TSF %0d, RX descriptor TSF %0d", i, col.rec_tsf[i], env.rx_sb.tsf_q[i]))
      phase.drop_objection(this);
    endtask
  endclass

  // ------------------------------------------------------------------ CHP-12
  // peer frames through channel impairments the receiver must handle: gain 0.1..1.0, CFO
  // +-20 kHz (~ +-4 ppm at 5 GHz), ADC noise floor. All must be decoded and delivered.
  class chip_rx_impair_test extends chip_base_test;
    `uvm_component_utils(chip_rx_impair_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(200ms, 1); endfunction
    task run_phase(uvm_phase phase);
      real gains[3] = '{0.1, 0.3, 1.0}; real cfos[3] = '{-20e3, 0.0, 20e3};
      phase.raise_objection(this);
      bringup();
      env.adc.cfg.noise_amp = 20;
      foreach (gains[g]) foreach (cfos[c]) begin
        chip_rx_vseq v = chip_rx_vseq::type_id::create("v");
        env.cfg.chan_gain = gains[g]; env.cfg.chan_cfo_hz = cfos[c];
        v.env = env; v.n = 2; v.start(null);
        `uvm_info("IMPAIR", $sformatf("gain %.1f cfo %.0f Hz: delivered so far %0d", gains[g], cfos[c], env.rx_sb.n_ok_dma), UVM_LOW)
      end
      phase.drop_objection(this);
    endtask
  endclass

  // ------------------------------------------------------------------ CHP-13
  // long mixed run: TX on random queues, RX from the peer, RX DMA ready 30 %; no loss, no
  // deadlock, interrupt counts match the traffic.
  class chip_stress_test extends chip_base_test;
    `uvm_component_utils(chip_stress_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(2000ms, 1); endfunction
    task run_phase(uvm_phase phase);
      chip_tx_vseq t = chip_tx_vseq::type_id::create("t"); chip_rx_vseq r = chip_rx_vseq::type_id::create("r");
      int unsigned n = 40;
      phase.raise_objection(this);
      void'($value$plusargs("N_PKT=%d", n));
      bringup();
      env.dma_rx.cfg.ready_pct = 30;
      t.env = env; r.env = env; t.n = n; r.n = n; t.rand_queue = 1;
      fork t.start(null); r.start(null); join
      #200us;
      if (env.irq.n_tx_itrpt < n) `uvm_error("STRESS", $sformatf("%0d tx interrupts for %0d frames", env.irq.n_tx_itrpt, n))
      if (env.irq.n_rx_pkt_intr < env.rx_sb.n_ok_dma) `uvm_error("STRESS", $sformatf("%0d rx interrupts for %0d delivered packets", env.irq.n_rx_pkt_intr, env.rx_sb.n_ok_dma))
      phase.drop_objection(this);
    endtask
  endclass
endpackage
