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
    wifi_frame exp_q[$], obs_q[$];
    string dump_dir = "";
    int n_ok, n_err, n_pkt, n_abort;
    // scrambler seeds the PHY was programmed with for the frames now in flight; written
    // into every dump so check_tx_dumps.py rebuilds the reference with the same seeds
    bit [6:0] data_seed = 7'h7F, pilot_seed = 7'h7F;
    time t_abort[$];   // MULTI_RST mid-packet: bursts that started before these times are dropped
    function new(string name, uvm_component parent);
      super.new(name, parent);
      sent_imp = new("sent_imp", this); iq_imp = new("iq_imp", this); obs_imp = new("obs_imp", this);
    endfunction
    function void build_phase(uvm_phase phase);
      void'($value$plusargs("TX_DUMP_DIR=%s", dump_dir));
    endfunction
    function void write_sent(wifi_frame f); exp_q.push_back(f); obs_q.push_back(f); endfunction
    function void write_obs(phy_tx_obs o);
      // the BRAM words the PHY actually read must be the image the server was given
      if (obs_q.size()) begin
        wifi_frame f = obs_q.pop_front(); string w = o.check(f);
        if (w != "") `uvm_error("OTX_SB", {"BRAM read by PHY: ", w})
      end
      // latency sanity: started must follow start; done must follow started
      if (!(o.t_started > o.t_start && o.t_done > o.t_started))
        `uvm_error("OTX_SB", $sformatf("bad phase order start=%0t started=%0t done=%0t", o.t_start, o.t_started, o.t_done))
    endfunction
    // the in-flight frame was reset away: forget it; its partial burst (if any) is dropped
    function void abort_in_flight();
      if (exp_q.size()) void'(exp_q.pop_back());
      if (obs_q.size()) void'(obs_q.pop_back());
      t_abort.push_back($time); n_abort++;
    endfunction
    function void write_iq(iq_item b);
      wifi_frame f;
      while (t_abort.size() && b.t_start >= t_abort[0]) void'(t_abort.pop_front());
      if (t_abort.size() && b.t_start < t_abort[0]) begin
        `uvm_info("OTX_SB", $sformatf("dropping aborted burst (%0d samples)", b.size()), UVM_MEDIUM)
        void'(t_abort.pop_front()); return;
      end
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
      $fwrite(fd, "{\"ht\":%0d,\"rate\":%0d,\"sgi\":%0d,\"aggr\":%0d,\"seed\":%0d,\"pilot_seed\":%0d,\"mpdu_hex\":\"%s\"}\n",
              f.ht, f.ht ? f.rate_hw : legacy_mbps(f.rate_hw), f.sgi, f.ht_aggr, data_seed, pilot_seed, hex);
      $fclose(fd);
      iq_file_util::write($sformatf("%s/rtl_%04d.txt", dump_dir, n_pkt), b);
    endfunction
    function void check_phase(uvm_phase phase);
      if (exp_q.size()) `uvm_error("OTX_SB", $sformatf("%0d frames never produced I/Q", exp_q.size()))
    endfunction
    function void report_phase(uvm_phase phase);
      if (n_abort) `uvm_info("OTX_SB", $sformatf("%0d packets reset mid-flight", n_abort), UVM_NONE)
      `uvm_info("OTX_SB", $sformatf("packets %0d  length-ok %0d  errors %0d%s", n_pkt, n_ok, n_err,
                dump_dir != "" ? {"  dumps in ", dump_dir, " (run scripts/check_tx_dumps.py)"} : ""), UVM_NONE)
    endfunction
  endclass

  class otx_env extends uvm_env;
    `uvm_component_utils(otx_env)
    axil_agent axil; phy_tx_agent ptx; iq_agent iqm; otx_scoreboard sb; wifi_frame_cov cov; ow_cov_pkg::ral_access_cov rcov;
    openofdm_tx_regs regs; axil_reg_adapter adapter;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      phy_tx_cfg pc = phy_tx_cfg::type_id::create("pc");
      iq_cfg     ic = iq_cfg::type_id::create("ic");
      pc.role = PHY_TX_BRAM_SERVER;
      if ($value$plusargs("HOLD_PCT=%d", pc.hold_pct)) pc.hold_mode = HOLD_RANDOM;
      void'($value$plusargs("HOLD_FIFO_TH=%d", pc.fifo_th));
      ic.pack = PACK_IQ32; ic.end_gap_clks = 1000; ic.end_gap_samples = 100000; // close on strobe silence only:
                                                      // > max gap inside a packet (~300 clk after the preamble at 12+ Mbps), < ifs_clks
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
      rcov = ow_cov_pkg::ral_access_cov::type_id::create("rcov", this); rcov.blk = regs;
      adapter = axil_reg_adapter::type_id::create("adapter");
    endfunction
    function void connect_phase(uvm_phase phase);
      axil.mon.ap.connect(rcov.analysis_export);
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
    task wr(string name, bit [31:0] v);
      uvm_status_e st;
      env.regs.r(name).write(st, v);
      if (st != UVM_IS_OK) `uvm_error("REGWR", $sformatf("%s <= 0x%0h failed", name, v))
    endtask
    task send(bit ht, int unsigned rate, bit sgi, int unsigned len);
      wifi_frame f = wifi_frame::type_id::create("f");
      if (!f.randomize() with { ht == local::ht; rate_hw == rate; sgi == local::sgi; mpdu_len == len; })
        `uvm_fatal("RAND", "randomize")
      env.ptx.sqr.execute_item(f);
    endtask
  endclass

  // every rate/MCS/GI combination at short, medium and max-BRAM lengths
  class otx_rate_sweep_test extends otx_base_test;
    `uvm_component_utils(otx_rate_sweep_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    // +OTX_REPLAY=<dir>: take each frame's MPDU from <dir>/frame_NNNN.json (a TX_DUMP_DIR of an
    // earlier run, e.g. vectors/otx_rate_sweep/fixed) instead of $urandom. Payload randomisation
    // differs between simulators; with the same MPDUs the I/Q of xsim and Verilator must be
    // bit-identical, which is the cross-simulator check (scripts/compare_golden.py).
    function void replay_mpdu(wifi_frame f, string dir, int n);
      string fn = $sformatf("%s/frame_%04d.json", dir, n), line = "", hex = "", key = "\"mpdu_hex\"";
      int fd = $fopen(fn, "r"), p = -1;
      if (!fd) `uvm_fatal("REPLAY", {"cannot open ", fn})
      void'($fgets(line, fd)); $fclose(fd);
      for (int i = 0; i + key.len() <= line.len(); i++)
        if (line.substr(i, i + key.len() - 1) == key) begin p = i + key.len(); break; end
      if (p < 0) `uvm_fatal("REPLAY", {"no mpdu_hex in ", fn})
      while (p < line.len() && (line[p] == ":" || line[p] == " " || line[p] == "\"")) p++;   // : "
      for (int i = p; i < line.len() && line[i] != "\""; i++) hex = {hex, string'(line[i])};
      if (hex.len() / 2 != f.mpdu_len)
        `uvm_fatal("REPLAY", $sformatf("%s: %0d bytes, frame expects %0d", fn, hex.len() / 2, f.mpdu_len))
      f.mpdu = new[f.mpdu_len];
      foreach (f.mpdu[k]) f.mpdu[k] = hex.substr(2 * k, 2 * k + 1).atohex();
    endfunction
    task run_phase(uvm_phase phase);
      int unsigned lens[3] = '{14, 100, 1500};
      string replay = ""; int n = 0;
      void'($value$plusargs("OTX_REPLAY=%s", replay));
      if (replay != "") `uvm_info("REPLAY", {"MPDUs from ", replay}, UVM_NONE)
      phase.raise_objection(this);
      init_regs();
      for (int h = 0; h < 2; h++)
        for (int r = (h ? 0 : 4); r <= (h ? 7 : 11); r++)
          for (int g = 0; g <= h; g++)
            foreach (lens[li]) begin
              wifi_frame f = wifi_frame::type_id::create("f");
              if (!f.randomize() with { ht == h; rate_hw == r; sgi == g; mpdu_len == lens[li]; })
                `uvm_fatal("RAND", "randomize")
              n++;
              if (replay != "") replay_mpdu(f, replay, n);
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

  // OTX-05: non-default scrambler seeds. Both seeds are loaded at every packet start
  // (data: dot11_tx S1_*; pilot: fix B), so they can change between frames. Each dump
  // carries the seeds; check_tx_dumps.py rebuilds the reference with them.
  class otx_scrambler_seed_test extends otx_base_test;
    `uvm_component_utils(otx_scrambler_seed_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      bit [6:0] seeds[$] = '{7'h01, 7'h2A, 7'h55, 7'h7E, 7'h40};
      phase.raise_objection(this);
      init_regs();
      repeat (3) seeds.push_back(7'($urandom_range(127, 1)));
      foreach (seeds[i]) begin
        bit [6:0] ps = (i % 2) ? 7'h7F : 7'(seeds[i] ^ 7'h33) | 7'h01;
        wr("INIT_DATA_STATE", seeds[i]); wr("INIT_PILOT_STATE", ps);
        env.sb.data_seed = seeds[i]; env.sb.pilot_seed = ps;
        send(0, 4, 0, 100);            //  6 Mbps
        send(0, 11, 0, 300);           // 54 Mbps
        send(1, 0, 0, 60);             // MCS0
        send(1, 7, 1, 500);            // MCS7 SGI
      end
      wr("INIT_DATA_STATE", 7'h7F); wr("INIT_PILOT_STATE", 7'h7F);
      env.sb.data_seed = 7'h7F; env.sb.pilot_seed = 7'h7F;
      send(1, 3, 0, 200);              // back to the driver default
      #10us;
      phase.drop_objection(this);
    endtask
  endclass

  // OTX-06: A-MPDU. HT-SIG aggregation bit set, PSDU = delimiters + MPDUs (with FCS) + pad
  // served from BRAM as is; dot11_tx must not append an FCS (HT_AGGR path) and the burst
  // length follows the A-MPDU length. EVM per symbol via check_tx_dumps.py (aggr in JSON).
  class otx_ampdu_test extends otx_base_test;
    `uvm_component_utils(otx_ampdu_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      int unsigned cfgs[$][3] = '{'{0, 0, 1}, '{3, 1, 2}, '{5, 0, 3}, '{7, 1, 4}, '{7, 0, 6}, '{2, 0, 2}};
      phase.raise_objection(this);
      init_regs();
      foreach (cfgs[c]) begin
        wifi_frame f = wifi_frame::type_id::create("f");
        byte unsigned m[$], a[$]; int unsigned lens[$];
        repeat (cfgs[c][2]) begin
          int unsigned l = $urandom_range(300, 24);
          lens.push_back(l);
          repeat (l) m.push_back(8'($urandom));
        end
        ampdu_pack(m, lens, a);
        // fields set after a plain randomize(): xsim 2022.2 null-object error on randomize() with {} here (finding 10)
        if (!f.randomize()) `uvm_fatal("RAND", "randomize")
        f.ht = 1; f.ht_aggr = 1; f.rate_hw = cfgs[c][0]; f.sgi = cfgs[c][1]; f.mpdu_len = a.size();
        f.mpdu = new[a.size()]; foreach (a[k]) f.mpdu[k] = a[k];
        `uvm_info("OTX_AMPDU", $sformatf("%s: %0d subframes, PSDU %0d B", f.rate_str(), lens.size(), a.size()), UVM_LOW)
        env.ptx.sqr.execute_item(f);
      end
      #10us;
      phase.drop_objection(this);
    endtask
  endclass

  // OTX-07: MULTI_RST in the middle of a packet (MULTI_RST[0] is ORed with ~phy_tx_arestn
  // into dot11_tx phy_tx_arest, so this is the same reset path as the pin). The partial
  // burst is dropped; the PHY must come back idle and the next frames must be exact
  // (length check here, EVM via check_tx_dumps.py on the dumps).
  class otx_reset_midpacket_test extends otx_base_test;
    `uvm_component_utils(otx_reset_midpacket_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(20ms, 1); endfunction
    task run_phase(uvm_phase phase);
      int unsigned n = 6;
      phase.raise_objection(this);
      init_regs();
      void'($value$plusargs("N_PKT=%d", n));
      for (int i = 0; i < n; i++) begin
        wifi_frame f = wifi_frame::type_id::create("f");
        int unsigned clk_ns = 1000 / `NUM_CLK_PER_US, k_rst, k = 0; bit done_seen = 0;
        if (!f.randomize() with { mpdu_len inside {[100:800]}; }) `uvm_fatal("RAND", "randomize")
        // reset point: after a random number of output samples, preamble to the last symbol
        k_rst = $urandom_range(f.tx_samples() - 20, 1);
        fork
          env.ptx.sqr.execute_item(f);
          begin
            while (k < k_rst) begin
              @(posedge env.ptx.vif.clk);
              if (env.ptx.vif.phy_tx_done) done_seen = 1;
              if (env.ptx.vif.result_iq_valid && !env.ptx.vif.tx_hold) k++;
            end
            if (done_seen) `uvm_error("OTX_RST", "packet finished before the reset point")
            `uvm_info("OTX_RST", $sformatf("pkt %0d %s: MULTI_RST after %0d of %0d samples", i, f.convert2string(), k_rst, f.tx_samples()), UVM_LOW)
            wr("MULTI_RST", 1);
            env.sb.abort_in_flight(); env.ptx.srv.abort = 1;
            repeat (10) #(clk_ns * 1ns);
            wr("MULTI_RST", 0);
          end
        join
        send(f.ht, f.rate_hw, f.sgi, 120);            // same format right after recovery
        send(1, 7, 0, 1000);                          // and a long one
      end
      #10us;
      phase.drop_objection(this);
    endtask
  endclass

  // every named register read, every writable one written with its own value (RAL coverage)
  class otx_ral_access_test extends otx_base_test;
    `uvm_component_utils(otx_ral_access_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      ral_touch_seq t = ral_touch_seq::type_id::create("t");
      phase.raise_objection(this);
      init_regs();
      t.rb = env.regs; t.start(null);
      #1us;
      phase.drop_objection(this);
    endtask
  endclass

  // wifi_frame coverage closure: every legacy rate and MCS x GI x the five length bins of
  // wifi_frame_cov (min <= 24, short <= 100, mid <= 600, long <= 1500, jumbo > 1500 B), 120 frames
  class otx_cov_test extends otx_base_test;
    `uvm_component_utils(otx_cov_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      int unsigned lens[5] = '{20, 60, 300, 1000, 1600};
      phase.raise_objection(this);
      init_regs();
      for (int h = 0; h < 2; h++)
        for (int r = (h ? 0 : 4); r <= (h ? 7 : 11); r++)
          for (int g = 0; g <= h; g++)
            for (int li = 0; li < 5; li++) begin
              wifi_frame f = wifi_frame::type_id::create("f");
              // plain randomize() and fields set afterwards (xsim, finding 10; 1600 B is past c_len)
              if (!f.randomize()) `uvm_fatal("RAND", "randomize")
              f.ht = h; f.rate_hw = r; f.sgi = g; f.ht_aggr = 0; f.set_len(lens[li]);
              env.ptx.sqr.execute_item(f);
            end
      #10us;
      phase.drop_objection(this);
    endtask
  endclass
endpackage
