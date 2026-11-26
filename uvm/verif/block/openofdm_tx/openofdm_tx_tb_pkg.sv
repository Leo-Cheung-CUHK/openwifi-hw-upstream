// Block-level UVM environment for openofdm_tx (dot11_tx + s_axi).
//   stimulus : phy_tx_agent in BRAM_SERVER role (TB = tx_intf), random wifi_frames
//   checks   : (1) burst length == wifi_frame::tx_samples() (exact, from 802.11 timing)
//              (2) every burst + frame is dumped to $TX_DUMP_DIR for the independent
//                  reference (scripts/check_tx_dumps.py -> wifi_ref_tx.py, EVM per symbol)
//              (3) phy_tx_started / phy_tx_done ordering and latency bounds
//              (4) registers: uvm_reg_hw_reset_seq on the RAL block
package openofdm_tx_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axil_pkg::*; import iq_pkg::*; import wifi_pkg::*; import phy_tx_pkg::*;
  import openwifi_ral_pkg::*; import openwifi_seq_pkg::*;

  `uvm_analysis_imp_decl(_sent)
  `uvm_analysis_imp_decl(_iq)
  `uvm_analysis_imp_decl(_obs)

  class otx_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(otx_scoreboard)
    uvm_analysis_imp_sent #(wifi_frame, otx_scoreboard) sent_imp;
    uvm_analysis_imp_iq   #(iq_item,    otx_scoreboard) iq_imp;
    uvm_analysis_imp_obs  #(phy_tx_obs, otx_scoreboard) obs_imp;
    wifi_frame exp_q[$];
    string dump_dir = "";
    int n_ok, n_err, n_pkt;
    function new(string name, uvm_component parent);
      super.new(name, parent);
      sent_imp = new("sent_imp", this); iq_imp = new("iq_imp", this); obs_imp = new("obs_imp", this);
    endfunction
    function void build_phase(uvm_phase phase);
      void'($value$plusargs("TX_DUMP_DIR=%s", dump_dir));
    endfunction
    function void write_sent(wifi_frame f); exp_q.push_back(f); endfunction
    function void write_obs(phy_tx_obs o);
      // latency sanity: started must follow start; done must follow started
      if (!(o.t_started > o.t_start && o.t_done > o.t_started))
        `uvm_error("OTX_SB", $sformatf("bad phase order start=%0t started=%0t done=%0t", o.t_start, o.t_started, o.t_done))
    endfunction
    function void write_iq(iq_item b);
      wifi_frame f;
      if (exp_q.size() == 0) begin `uvm_error("OTX_SB", "I/Q burst with no frame sent") return; end
      f = exp_q.pop_front(); n_pkt++;
      if (b.size() != f.tx_samples()) begin
        n_err++;
        `uvm_error("OTX_SB", $sformatf("pkt %0d %s: %0d samples, expected %0d", n_pkt, f.convert2string(), b.size(), f.tx_samples()))
      end else n_ok++;
      if (dump_dir != "") dump(f, b);
    endfunction
    function void dump(wifi_frame f, iq_item b);
      int fd; string hex = "";
      foreach (f.mpdu[k]) hex = {hex, $sformatf("%02x", f.mpdu[k])};
      fd = $fopen($sformatf("%s/frame_%04d.json", dump_dir, n_pkt), "w");
      $fwrite(fd, "{\"ht\":%0d,\"rate\":%0d,\"sgi\":%0d,\"mpdu_hex\":\"%s\"}\n",
              f.ht, f.ht ? f.rate_hw : legacy_mbps(f.rate_hw), f.sgi, hex);
      $fclose(fd);
      iq_file_util::write($sformatf("%s/rtl_%04d.txt", dump_dir, n_pkt), b);
    endfunction
    function void check_phase(uvm_phase phase);
      if (exp_q.size()) `uvm_error("OTX_SB", $sformatf("%0d frames never produced I/Q", exp_q.size()))
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("OTX_SB", $sformatf("packets %0d  length-ok %0d  errors %0d%s", n_pkt, n_ok, n_err,
                dump_dir != "" ? {"  dumps in ", dump_dir, " (run scripts/check_tx_dumps.py)"} : ""), UVM_NONE)
    endfunction
  endclass

  class otx_env extends uvm_env;
    `uvm_component_utils(otx_env)
    axil_agent axil; phy_tx_agent ptx; iq_agent iqm; otx_scoreboard sb; wifi_frame_cov cov;
    openofdm_tx_regs regs; axil_reg_adapter adapter;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      phy_tx_cfg pc = phy_tx_cfg::type_id::create("pc");
      iq_cfg     ic = iq_cfg::type_id::create("ic");
      pc.role = PHY_TX_BRAM_SERVER;
      if ($value$plusargs("HOLD_PCT=%d", pc.hold_pct)) pc.hold_mode = HOLD_RANDOM;
      void'($value$plusargs("HOLD_FIFO_TH=%d", pc.fifo_th));
      ic.pack = PACK_IQ32; ic.end_gap_clks = 200; ic.end_gap_samples = 100000;  // close on strobe silence only
      ic.use_ready = 1;                                                           // ready = ~tx_hold
      if ($test$plusargs("HOLD_FIFO")) pc.hold_mode = HOLD_FIFO_MODEL;           // tx_intf-like back-pressure
      uvm_config_db#(phy_tx_cfg)::set(this, "ptx", "cfg", pc);
      uvm_config_db#(iq_cfg)::set(this, "iqm", "cfg", ic);
      uvm_config_db#(uvm_active_passive_enum)::set(this, "iqm", "is_active", UVM_PASSIVE);
      axil = axil_agent::type_id::create("axil", this);
      ptx  = phy_tx_agent::type_id::create("ptx", this);
      iqm  = iq_agent::type_id::create("iqm", this);
      sb   = otx_scoreboard::type_id::create("sb", this);
      cov  = wifi_frame_cov::type_id::create("cov", this);
      regs = openofdm_tx_regs::type_id::create("regs"); regs.configure(null); regs.build();
      adapter = axil_reg_adapter::type_id::create("adapter");
    endfunction
    function void connect_phase(uvm_phase phase);
      regs.default_map.set_sequencer(axil.sqr, adapter);
      regs.default_map.set_auto_predict(1);
      ptx.srv.sent_ap.connect(sb.sent_imp);
      ptx.srv.sent_ap.connect(cov.analysis_export);
      ptx.mon.ap.connect(sb.obs_imp);
      iqm.mon.ap.connect(sb.iq_imp);
    endfunction
  endclass

  // random frames; knobs via plusargs so one test covers the matrix in regression
  class otx_frames_seq extends uvm_sequence #(wifi_frame);
    `uvm_object_utils(otx_frames_seq)
    int unsigned n = 20; int ht_only = -1;   // -1 random, 0 legacy, 1 HT
    function new(string name = "otx_frames_seq"); super.new(name); endfunction
    task body();
      repeat (n) begin
        wifi_frame f = wifi_frame::type_id::create("f");
        start_item(f);
        if (!f.randomize() with { if (ht_only >= 0) ht == ht_only; mpdu_len inside {[14:400]}; })
          `uvm_fatal("RAND", "frame randomize failed")
        finish_item(f);
      end
    endtask
  endclass

  class otx_base_test extends uvm_test;
    `uvm_component_utils(otx_base_test)
    otx_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase); env = otx_env::type_id::create("env", this); endfunction
    task init_regs();
      openofdm_tx_init_seq s = openofdm_tx_init_seq::type_id::create("init");
      s.rb = env.regs; s.start(null);
    endtask
  endclass

  // every rate/MCS/GI combination at short, medium and max-BRAM lengths
  class otx_rate_sweep_test extends otx_base_test;
    `uvm_component_utils(otx_rate_sweep_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      int unsigned lens[3] = '{14, 100, 1500};
      phase.raise_objection(this);
      init_regs();
      for (int h = 0; h < 2; h++)
        for (int r = (h ? 0 : 4); r <= (h ? 7 : 11); r++)
          for (int g = 0; g <= h; g++)
            foreach (lens[li]) begin
              wifi_frame f = wifi_frame::type_id::create("f");
              if (!f.randomize() with { ht == h; rate_hw == r; sgi == g; mpdu_len == lens[li]; })
                `uvm_fatal("RAND", "randomize")
              env.ptx.sqr.execute_item(f);
            end
      #10us;
      phase.drop_objection(this);
    endtask
  endclass

  class otx_random_test extends otx_base_test;
    `uvm_component_utils(otx_random_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      otx_frames_seq s = otx_frames_seq::type_id::create("s");
      phase.raise_objection(this);
      init_regs();
      void'($value$plusargs("N_PKT=%d", s.n));
      s.start(env.ptx.sqr);
      #10us;
      phase.drop_objection(this);
    endtask
  endclass

  // tx_intf-like back-pressure: FIFO model with a low threshold so hold toggles around it
  // for most of every packet (the steady state the PHY sees in the FPGA for long frames).
  // Found with Verilator on dot11_tx alone: with hold high 4 of every 5 cycles the last
  // sample is still pending at phy_tx_done; some other periodic patterns livelock the
  // output stream. This test + phy_tx_if assertions + the length check expose both.
  class otx_backpressure_test extends otx_base_test;
    `uvm_component_utils(otx_backpressure_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase);
      env.ptx.cfg.hold_mode = HOLD_FIFO_MODEL; env.ptx.cfg.fifo_th = 32;
      uvm_top.set_timeout(20ms, 1);
    endfunction
    task run_phase(uvm_phase phase);
      otx_frames_seq s = otx_frames_seq::type_id::create("s");
      phase.raise_objection(this);
      init_regs();
      s.n = 20; s.start(env.ptx.sqr);
      #10us;
      phase.drop_objection(this);
    endtask
  endclass

  class otx_reg_reset_test extends otx_base_test;
    `uvm_component_utils(otx_reg_reset_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      uvm_reg_hw_reset_seq rs = uvm_reg_hw_reset_seq::type_id::create("rs");
      uvm_reg_bit_bash_seq bb = uvm_reg_bit_bash_seq::type_id::create("bb");
      phase.raise_objection(this);
      rs.model = env.regs; rs.start(null);
      bb.model = env.regs; bb.start(null);
      phase.drop_objection(this);
    endtask
  endclass
endpackage
