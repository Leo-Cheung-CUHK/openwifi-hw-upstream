// Block-level UVM environment for xpu (low MAC: CSMA/CA, ACK/CTS response, retransmission,
// address filter, RSSI/CCA, TSF).
//   TB plays: openofdm_rx (phy_rx_agent ACTIVE, real PHY timing), the DDC I/Q feed for
//             RSSI/CCA (iq_agent), and tx_intf + openofdm_tx (xpu_phy_model below).
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

  // one host (tx_intf) transmission attempt sequence, as recorded by xpu_phy_model
  class host_tx_result extends uvm_object;
    int unsigned attempts; bit [3:0] num_retrans; time t_trigger, t_backoff_done[$], t_tx_done[$];
    int unsigned cw[$], nsr[$];        // xpu cw / num_slot_random seen at each attempt
    `uvm_object_utils(host_tx_result)
    function new(string name = "host_tx_result"); super.new(name); endfunction
  endclass

  // Plays tx_intf + openofdm_tx towards xpu:
  //  * xpu-originated responses (ACK, CTS, BlockAck): on start_tx_ack it starts the PHY, walks
  //    bram_addr over the image xpu serves through dina while ack_tx_flag=1 (word count from the
  //    L-SIG LENGTH in word 0) and ends after the response airtime;
  //  * host frames (send()): raises high_trigger for the queue, waits for backoff_done, sends,
  //    then follows xpu: start_retrans -> send again, tx_try_complete -> done (tx_status).
  // One PHY: the two kinds are serialised with a semaphore.
  class xpu_phy_model extends uvm_component;
    `uvm_component_utils(xpu_phy_model)
    virtual xpu_tx_side_if vif;
    uvm_analysis_port #(ack_obs) ap;
    semaphore phy = new(1);
    event tx_done_ev;                   // every host phy_tx_done (peer ACK timing)
    time  t_last_tx_done;
    function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
    // as tx_intf: the IQ FIFO fills shortly after phy_tx_started and drains after phy_tx_done
    // (xpu tx_on_detection derives tx_bb/rf_is_ongoing from those FIFO edges)
    task air_start();
      @(posedge vif.clk) vif.phy_tx_start <= 1;
      @(posedge vif.clk) vif.phy_tx_start <= 0;
      repeat (20) @(posedge vif.clk);
      vif.phy_tx_started <= 1; @(posedge vif.clk) vif.phy_tx_started <= 0;
      repeat (10) @(posedge vif.clk); vif.tx_iq_fifo_empty <= 0;
    endtask
    task air_end();   // the FIFO drain runs in run_phase: send()'s disable fork must not cut it
      vif.phy_tx_done <= 1; @(posedge vif.clk) vif.phy_tx_done <= 0;
    endtask
    task play(real air_us);
      air_start();
      repeat ($rtoi(air_us * `NUM_CLK_PER_US)) @(posedge vif.clk);
      air_end();
    endtask
    task run_phase(uvm_phase phase);
      vif.phy_tx_start <= 0; vif.phy_tx_started <= 0; vif.phy_tx_done <= 0; vif.bram_addr <= 0;
      fork forever begin
        @(posedge vif.clk iff vif.phy_tx_done);
        repeat (20) @(posedge vif.clk); vif.tx_iq_fifo_empty <= 1;
      end join_none
      forever begin
        ack_obs a = ack_obs::type_id::create("a");
        int unsigned n_words, len; bit [63:0] w0;
        @(posedge vif.clk iff vif.start_tx_ack);
        phy.get();
        a.t_start_tx_ack = $time;
        air_start();
        n_words = 4;
        for (int w = 0; w < n_words; w++) begin
          vif.bram_addr <= w;
          repeat (3) @(posedge vif.clk);
          if (!vif.ack_tx_flag) `uvm_error("XPU_PHY", "ack_tx_flag low while the PHY reads the response image")
          a.obs.words[w] = vif.dina;
          if (w == 0) begin len = vif.dina[16:5]; n_words = 2 + (len - 4 + 7) / 8; end   // L-SIG LENGTH incl. FCS
        end
        vif.bram_addr <= 0;
        // response at 6 Mbps: 20 us preamble+SIG + 4 us x ceil((16 + 8*len + 6)/24)
        repeat ((20 + 4 * ((16 + 8 * len + 6 + 23) / 24)) * `NUM_CLK_PER_US) @(posedge vif.clk);
        air_end();
        phy.put();
        ap.write(a);
      end
    endtask
    // host frame f on queue q; returns after tx_try_complete
    task send(wifi_frame f, bit [1:0] q, bit need_ack, bit [3:0] retrans_limit, output host_tx_result r,
              input real timeout_us = 20000);
      bit done = 0;
      r = host_tx_result::type_id::create("r");
      vif.tx_queue_idx <= q; vif.tx_pkt_need_ack <= need_ack; vif.tx_pkt_retrans_limit <= retrans_limit;
      @(posedge vif.clk iff vif.slice_en[q]);
      r.t_trigger = $time;
      vif.high_trigger <= 1; @(posedge vif.clk) vif.high_trigger <= 0;
      fork
        begin
          // first attempt after backoff_done; then one more per start_retrans
          @(posedge vif.clk iff vif.backoff_done);
          forever begin
            r.t_backoff_done.push_back($time); r.cw.push_back(vif.cw); r.nsr.push_back(vif.num_slot_random);
            phy.get(); play(f.airtime_us()); phy.put();
            r.attempts++; r.t_tx_done.push_back($time); t_last_tx_done = $time; ->tx_done_ev;
            @(posedge vif.clk iff (vif.start_retrans || vif.tx_try_complete));
            if (vif.tx_try_complete) break;
          end
        end
        begin @(posedge vif.clk iff vif.tx_try_complete); end
        begin #(timeout_us * 1us); `uvm_error("XPU_HOST", $sformatf("no tx_try_complete within %0.0f us", timeout_us)) end
      join_any
      disable fork;
      vif.tx_pkt_need_ack <= 0;
      repeat (5) @(posedge vif.clk);
      r.num_retrans = vif.tx_status[3:0];   // tx_status settles after tx_try_complete
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

    // other responses (CTS, BlockAck): expected frame + per-byte mask (1 = compare)
    wifi_frame cust_q[$]; bit cust_mask_q[$][$]; int n_resp_ok;
    function void expect_response(wifi_frame f, bit mask[$]); cust_q.push_back(f); cust_mask_q.push_back(mask); endfunction
    function void check_custom(ack_obs a);
      wifi_frame e = cust_q.pop_front(); bit m[$] = cust_mask_q.pop_front();
      bit [63:0] w[$]; e.bram_words(w);
      if (!a.obs.words.exists(0) || a.obs.words[0] !== w[0]) begin
        n_err++; `uvm_error("XPU_SB", $sformatf("response L-SIG word 0x%016h, expected 0x%016h", a.obs.words[0], w[0])) return;
      end
      foreach (e.mpdu[k]) if (m[k]) begin
        bit [63:0] got = a.obs.words.exists(2 + k / 8) ? a.obs.words[2 + k / 8] : 'x;
        if (got[8*(k%8) +: 8] !== e.mpdu[k]) begin
          n_err++; `uvm_error("XPU_SB", $sformatf("response byte %0d: 0x%02h, expected 0x%02h (FC %02h%02h)", k, got[8*(k%8) +: 8], e.mpdu[k], e.mpdu[1], e.mpdu[0]))
          return;
        end
      end
      n_resp_ok++;
      `uvm_info("XPU_SB", $sformatf("response FC 0x%02h%02h len %0d ok", e.mpdu[1], e.mpdu[0], e.mpdu_len), UVM_LOW)
    endfunction
    function void write_ack(ack_obs a);
      wifi_frame e; string why; real dt;
      if (cust_q.size()) begin check_custom(a); return; end
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
      if (cust_q.size()) `uvm_error("XPU_SB", $sformatf("%0d responses (CTS/BlockAck) were due but never sent", cust_q.size()))
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("XPU_SB", $sformatf("ACK ok %0d  no-ACK cases %0d  errors %0d", n_ack_ok, n_no_ack_ok, n_err), UVM_NONE)
    endfunction
  endclass

  class xpu_env extends uvm_env;
    `uvm_component_utils(xpu_env)
    axil_agent axil; phy_rx_agent prx; iq_agent ddc; xpu_phy_model rsp; xpu_scoreboard sb; ow_cov_pkg::ral_access_cov rcov;
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
      rsp  = xpu_phy_model::type_id::create("rsp", this);
      sb   = xpu_scoreboard::type_id::create("sb", this);
      if (!uvm_config_db#(virtual xpu_tx_side_if)::get(this, "", "txside", rsp.vif)) `uvm_fatal("NOVIF", "xpu_tx_side_if")
      regs = xpu_regs::type_id::create("regs"); regs.configure(null); regs.build();
      rcov = ow_cov_pkg::ral_access_cov::type_id::create("rcov", this); rcov.blk = regs;
      adapter = axil_reg_adapter::type_id::create("adapter");
    endfunction
    function void connect_phase(uvm_phase phase);
      axil.mon.ap.connect(rcov.analysis_export);
      regs.default_map.set_sequencer(axil.sqr, adapter);
      regs.default_map.set_auto_predict(1);
      prx.mon.ap.connect(sb.rx_imp);
      rsp.ap.connect(sb.ack_imp);
    endfunction
  endclass

  class xpu_base_test extends uvm_test;
    `uvm_component_utils(xpu_base_test)
    xpu_env env; bit [47:0] my_mac = 48'h66_55_44_33_22_12;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase); env = xpu_env::type_id::create("env", this); endfunction
    task init_regs();
      xpu_init_seq s = xpu_init_seq::type_id::create("init");
      s.rb = env.regs; s.start(null);
      s.wr(env.regs, "MAC_ADDR_LOW",  my_mac[31:0]);
      s.wr(env.regs, "MAC_ADDR_HIGH", {16'h0, my_mac[47:32]});
      s.wr(env.regs, "BAND_CHANNEL",  (1 << 24) | (4 << 16) | 5220);   // 5.8 GHz band, short slot
      env.sb.my_mac = my_mac;
      // The TB's RSSI scale is not an RF front end's (no AD9361 gain chain): put the LBT
      // threshold 20 half-dB above the measured DDC noise floor, as one calibrates it on air
      #40us;
      lbt_th = $signed(env.prx.vif.rssi_half_db) + 20;
      s.wr(env.regs, "LBT_TH", lbt_th);
      `uvm_info("LBT", $sformatf("noise floor %0d half-dB, LBT_TH %0d", lbt_th - 20, lbt_th), UVM_LOW)
    endtask
    int lbt_th;
    bit [47:0] peer = 48'h02_AA_BB_CC_DD_EE;
    task wr(string name, bit [31:0] v);
      uvm_status_e st; env.regs.r(name).write(st, v);
      if (st != UVM_IS_OK) `uvm_error("REGWR", $sformatf("%s <= 0x%0h failed", name, v))
    endtask
    // a frame from the emulated openofdm_rx (blocks for its airtime); the scoreboard's ACK
    // bookkeeping sees it unless no_ack_check
    task rx(wifi_frame f, bit corrupt = 0, bit no_ack_check = 0, bit aggr_last = 1, bit cont = 0);
      phy_rx_item it = phy_rx_item::type_id::create("it");
      it.frame = f; it.corrupt_fcs = corrupt; it.aggr_last = aggr_last; it.cont = cont;
      env.sb.stimulus(f, corrupt | no_ack_check);
      env.prx.sqr.execute_item(it);
    endtask
    // generic MPDU: FC, duration, then addresses; len >= 10
    function wifi_frame mk(bit [15:0] fc, bit [15:0] dur, bit [47:0] a1, bit [47:0] a2 = 0, bit [47:0] a3 = 0,
                           int unsigned len = 60, int unsigned rate_hw = 4);
      wifi_frame f = wifi_frame::type_id::create("f");
      // set rate/length after randomize(): xsim 2022.2 fails this inline constraint (finding 10)
      if (!f.randomize() with { ht == 0; }) `uvm_fatal("RAND", "frame")
      f.rate_hw = rate_hw; f.set_len(len);
      f.mpdu[0] = fc[7:0]; f.mpdu[1] = fc[15:8]; f.mpdu[2] = dur[7:0]; f.mpdu[3] = dur[15:8];
      for (int k = 0; k < 6; k++) begin
        if (4 + k < len)  f.mpdu[4 + k]  = a1[8*k +: 8];
        if (10 + k < len) f.mpdu[10 + k] = a2[8*k +: 8];
        if (16 + k < len) f.mpdu[16 + k] = a3[8*k +: 8];
      end
      return f;
    endfunction
    // peer ACK for our frame, SIFS after its end
    task peer_ack(real after_us = 16);
      @(env.rsp.tx_done_ev);
      #(after_us * 1us);
      rx(mk(16'h00D4, 0, my_mac, 0, 0, 10), 0, 1);
    endtask
    // 24-byte data header + payload; to_me selects addr1
    function wifi_frame data_frame(bit to_me, bit bcast);
      wifi_frame f = wifi_frame::type_id::create("f");
      bit [47:0] a1 = bcast ? 48'hFF_FF_FF_FF_FF_FF : (to_me ? my_mac : 48'h07_00_00_00_00_02);
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

  // XPU-03: CSMA/CA. DIFS = SIFS + 2 slots (5 GHz: 16 + 2*9 = 34 us) minus DIFS_ADVANCE.
  // (1) idle medium: first access goes out one DIFS after high_trigger, no random backoff
  //     (csma_ca IDLE -> BACKOFF_WAIT_1); (2) medium busy (a frame being received): no
  //     backoff_done while busy, then DIFS + num_slot_random * slot after it ends; (3) per-queue
  //     CSMA_CFG: the random backoff stays inside [0, 2^cw_min - 1] slots of the queue.
  class xpu_csma_test extends xpu_base_test;
    `uvm_component_utils(xpu_csma_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(500ms, 1); endfunction
    task run_phase(uvm_phase phase);
      host_tx_result r; real difs_us = 34 - 2, slot_us = 9, dt;
      bit [3:0] cwmin[4] = '{2, 3, 4, 5};
      phase.raise_objection(this);
      init_regs();
      wr("CSMA_CFG", {4'd8, cwmin[3], 4'd8, cwmin[2], 4'd8, cwmin[1], 4'd8, cwmin[0]});   // per queue {cw_max, cw_min}
      // (1) idle medium
      repeat (3) begin
        env.rsp.send(rand_frame(), 0, 0, 0, r);
        dt = (r.t_backoff_done[0] - r.t_trigger) / 1us;
        if (dt < difs_us - 1.5 || dt > difs_us + 1.5)
          `uvm_error("CSMA", $sformatf("idle medium: backoff_done %.2f us after high_trigger, expected DIFS-advance = %.0f us", dt, difs_us))
        #100us;
      end
      // (2)+(3) busy medium on each queue
      for (int q = 0; q < 4; q++) repeat (4) begin
        wifi_frame busy = mk(16'h0008, 0, 48'h99_00_00_00_00_02, peer, peer, 300);   // not for us, no NAV
        time t_end;
        fork
          begin rx(busy); t_end = $time; end         // demod_is_ongoing falls here
          begin
            #60us;
            env.rsp.send(rand_frame(), 2'(q), 0, 0, r);   // 2'(q), not q[1:0]: xelab 2022.2 hangs on the part-select (finding 9)
          end
        join
        if (r.t_backoff_done[0] < t_end) `uvm_error("CSMA", $sformatf("queue %0d: backoff_done while a frame was being received", q))
        dt = (r.t_backoff_done[0] - t_end) / 1us;
        if (r.nsr[0] > (1 << cwmin[q]) - 1)
          `uvm_error("CSMA", $sformatf("queue %0d: num_slot_random %0d outside CW %0d (cw_min exp %0d)", q, r.nsr[0], (1 << cwmin[q]) - 1, cwmin[q]))
        if (dt < difs_us + r.nsr[0] * slot_us - 2 || dt > difs_us + r.nsr[0] * slot_us + 25)
          `uvm_error("CSMA", $sformatf("queue %0d: backoff_done %.2f us after the medium went idle, expected DIFS %.0f + %0d slots", q, dt, difs_us, r.nsr[0]))
        else `uvm_info("CSMA", $sformatf("queue %0d: %.2f us after busy end (%0d slots, cw %0d)", q, dt, r.nsr[0], r.cw[0]), UVM_LOW)
        #100us;
      end
      phase.drop_objection(this);
    endtask
    function wifi_frame rand_frame(); return mk(16'h0008, 0, peer, my_mac, peer, $urandom_range(200, 40), 6); endfunction
  endclass

  // XPU-04: retransmission. need_ack host frames: (a) peer ACK after SIFS -> one attempt,
  // num_retrans 0; (b) no ACK -> 1 + retrans_limit attempts, then tx_try_complete with
  // num_retrans = limit, CW growing per retry; (c) ACK to the 3rd attempt -> num_retrans 2;
  // (d) ACK too late (outside the ACK timeout) counts as missing.
  class xpu_retrans_test extends xpu_base_test;
    `uvm_component_utils(xpu_retrans_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(500ms, 1); endfunction
    task run_phase(uvm_phase phase);
      host_tx_result r; wifi_frame f;
      phase.raise_objection(this);
      init_regs();
      wr("CSMA_CFG", 32'h5252_5252);                                      // cw_min 2, cw_max 5
      f = mk(16'h0008, 44, peer, my_mac, peer, 120, 6);
      // (a)
      fork env.rsp.send(f, 0, 1, 3, r); peer_ack(); join
      if (r.attempts != 1 || r.num_retrans != 0) `uvm_error("RETX", $sformatf("ACKed frame: %0d attempts, num_retrans %0d", r.attempts, r.num_retrans))
      #200us;
      // (b)
      env.rsp.send(f, 0, 1, 3, r);
      if (r.attempts != 4 || r.num_retrans != 3) `uvm_error("RETX", $sformatf("no ACK, limit 3: %0d attempts, num_retrans %0d (expected 4, 3)", r.attempts, r.num_retrans))
      for (int k = 1; k < r.cw.size(); k++)
        if (r.cw[k] < r.cw[k-1] || r.cw[k] > 5) `uvm_error("RETX", $sformatf("cw sequence not growing within cw_max: attempt %0d cw %0d after %0d", k, r.cw[k], r.cw[k-1]))
      `uvm_info("RETX", $sformatf("no ACK: attempts %0d, cw per attempt %p", r.attempts, r.cw), UVM_LOW)
      #200us;
      // (c)
      fork
        env.rsp.send(f, 0, 1, 5, r);
        begin @(env.rsp.tx_done_ev); @(env.rsp.tx_done_ev); peer_ack(); end   // ACK the third attempt
      join
      if (r.attempts != 3 || r.num_retrans != 2) `uvm_error("RETX", $sformatf("ACK on 3rd attempt: %0d attempts, num_retrans %0d", r.attempts, r.num_retrans))
      #200us;
      // (d)
      fork env.rsp.send(f, 0, 1, 1, r); peer_ack(120); join
      if (r.attempts != 2) `uvm_error("RETX", $sformatf("late ACK: %0d attempts (expected the late ACK to count as missing)", r.attempts))
      phase.drop_objection(this);
    endtask
  endclass

  // XPU-05: receive filter (pkt_filter_ctl.v). A reference model of FILTER_FLAG, the high
  // priority discard mask and the BSSID tracking decides block_rx_dma_to_ps for every frame of
  // a frame-type x address matrix under several flag settings.
  class xpu_filter_test extends xpu_base_test;
    `uvm_component_utils(xpu_filter_test)
    bit [47:0] bssid_me = 48'h55_44_33_22_11_02, bssid_other = 48'h55_66_77_88_99_02;
    bit [47:0] filt_bssid; bit filt_bssid_valid;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(800ms, 1); endfunction
    // model; also updates the BSSID state like the RTL (kept across frames)
    function bit model_block(wifi_frame f, bit [13:0] cfg, bit [8:0] mask);
      bit [1:0] typ = f.mpdu[0][3:2]; bit [3:0] sub = f.mpdu[0][7:4];
      bit to_ds = f.mpdu[1][0], from_ds = f.mpdu[1][1]; bit [1:0] tf = {to_ds, from_ds};
      bit [47:0] a1 = f.addr(1), a2 = f.mpdu_len >= 16 ? f.addr(2) : 0, a3 = f.mpdu_len >= 22 ? f.addr(3) : 0;
      int unsigned slen = f.mpdu_len + 4;
      bit beacon = typ == 0 && sub == 8, preq = typ == 0 && sub == 4, presp = typ == 0 && sub == 5;
      bit ack = typ == 1 && sub == 13, cwrap = typ == 1 && sub == 7, pspoll = typ == 1 && sub == 10;
      bit stop2 = typ == 1 && sub inside {11, 10, 14, 15, 8, 9}, except_pspoll = typ == 1 && sub != 10;
      bit multi = (a1[23:0] == 24'h5E0001) || (a1[15:0] == 16'h3333), other_bss;
      bit [13:0] allow = 0; bit [8:0] disc = 0;
      if (tf == 2'b10) begin filt_bssid = a1; filt_bssid_valid = 1; end
      if (!(cwrap || ack) && slen >= 20) begin
        if (tf == 2'b01) begin filt_bssid = a2; filt_bssid_valid = 1; end
        if (!stop2 && slen >= 26 && tf == 2'b00) begin filt_bssid = a3; filt_bssid_valid = 1; end
      end
      other_bss = filt_bssid_valid && filt_bssid != bssid_me;
      allow[1]  = cfg[1] && multi;                 disc[1] = !cfg[1] && multi;
      allow[4]  = cfg[4] && (beacon || presp);     disc[4] = !cfg[4] && (beacon || presp) && other_bss;
      allow[5]  = cfg[5] && a1 == my_mac && except_pspoll; disc[5] = !cfg[5] && except_pspoll;
      allow[6]  = cfg[6] && other_bss;             disc[6] = !cfg[6] && other_bss;
      allow[7]  = cfg[7] && pspoll;                disc[7] = !cfg[7] && pspoll;
      allow[8]  = cfg[8] && preq;                  disc[8] = !cfg[8] && preq;
      allow[9]  = cfg[9] && a1 == my_mac;
      allow[10] = cfg[10] && a1 == 48'hFFFF_FFFF_FFFF;
      allow[11] = cfg[11] && a1 == 0;
      allow[12] = cfg[12] && filt_bssid_valid && filt_bssid == bssid_me && beacon;
      allow[13] = cfg[13];
      return !cfg[13] && ((allow == 0) || |(disc & mask));
    endfunction
    task run_phase(uvm_phase phase);
      bit [13:0] cfgs[$] = '{14'h2000, 14'h0200, 14'h0600, 14'h0E00, 14'h0212, 14'h0260, 14'h1180, 14'h0042, 14'h0000};
      bit [8:0]  masks[$] = '{9'h000, 9'h000, 9'h000, 9'h000, 9'h1F2, 9'h1F2, 9'h000, 9'h0F2, 9'h000};
      wifi_frame fr[$]; int n_ok = 0;
      phase.raise_objection(this);
      init_regs();
      wr("BSSID_FILTER_LOW", bssid_me[31:0]); wr("BSSID_FILTER_HIGH", {16'h0, bssid_me[47:32]});
      fr.push_back(mk(16'h0008, 0, my_mac, peer, bssid_me, 80));              // data to me, my BSS
      fr.push_back(mk(16'h0008, 0, 48'h07_00_00_00_00_02, peer, bssid_other, 80)); // data to other, other BSS
      fr.push_back(mk(16'h0008, 0, 48'hFF_FF_FF_FF_FF_FF, peer, bssid_me, 80)); // broadcast
      fr.push_back(mk(16'h0008, 0, 48'h00_00_00_00_00_00, peer, bssid_me, 80)); // all-zero
      fr.push_back(mk(16'h0008, 0, 48'h01_02_03_5E_00_01, peer, bssid_me, 80)); // IPv4 multicast 01:00:5e:..
      fr.push_back(mk(16'h0108, 0, bssid_other, peer, 48'h07_00_00_00_00_02, 80)); // ToDS to another AP
      fr.push_back(mk(16'h0208, 0, my_mac, bssid_other, peer, 80));          // FromDS from another AP
      fr.push_back(mk(16'h0080, 0, 48'hFF_FF_FF_FF_FF_FF, bssid_me, bssid_me, 80));    // beacon, my BSS
      fr.push_back(mk(16'h0080, 0, 48'hFF_FF_FF_FF_FF_FF, bssid_other, bssid_other, 80)); // beacon, other BSS
      fr.push_back(mk(16'h0040, 0, 48'hFF_FF_FF_FF_FF_FF, peer, 48'hFF_FF_FF_FF_FF_FF, 60)); // probe request
      fr.push_back(mk(16'h0050, 0, my_mac, bssid_other, bssid_other, 80));   // probe response
      fr.push_back(mk(16'h00B4, 300, 48'h07_00_00_00_00_02, peer, 0, 16));   // RTS, not for me
      fr.push_back(mk(16'h00A4, 0, bssid_me, peer, 0, 16));                   // PS-Poll
      fr.push_back(mk(16'h00D4, 0, 48'h07_00_00_00_00_02, 0, 0, 10));         // ACK, not for me
      foreach (cfgs[c]) begin
        wr("FILTER_FLAG", {7'd0, masks[c], 2'd0, cfgs[c]});
        filt_bssid_valid = 0; filt_bssid = 0;      // pkt_filter_ctl keeps it across frames; xpu reset below clears it
        wr("MULTI_RST", 1 << 2); wr("MULTI_RST", 0);
        foreach (fr[k]) begin
          bit exp = model_block(fr[k], cfgs[c], masks[c]), got; bit seen = 0;
          fork
            rx(fr[k]);
            begin @(posedge env.rsp.vif.clk iff env.rsp.vif.block_rx_dma_to_ps_valid); seen = 1; got = env.rsp.vif.block_rx_dma_to_ps; end
          join
          #60us;                                     // ACK (if any) out of the way
          if (!seen) `uvm_error("FILTER", $sformatf("flags 0x%04h frame %0d: no filter decision", cfgs[c], k))
          else if (got != exp) `uvm_error("FILTER", $sformatf("flags 0x%04h mask 0x%03h frame %0d (FC %02h%02h a1 %012h): block=%0b, model %0b",
                                                      cfgs[c], masks[c], k, fr[k].mpdu[1], fr[k].mpdu[0], fr[k].addr(1), got, exp))
          else n_ok++;
        end
      end
      `uvm_info("FILTER", $sformatf("%0d of %0d filter decisions match the model", n_ok, cfgs.size() * fr.size()), UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass

  // XPU-06: CTS in response to an RTS addressed to us: xpu serves the CTS image (6 Mbps or
  // the CTS_TO_RTS_CONFIG rate, FC 0xC4, RA = TA of the RTS) SIFS after the RTS.
  class xpu_cts_test extends xpu_base_test;
    `uvm_component_utils(xpu_cts_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      init_regs();
      for (int k = 0; k < 4; k++) begin
        bit [47:0] ta = 48'h00_00_00_10_00_02 | (48'(k) << 40);
        bit [15:0] dur = 16'(200 + 100 * k);
        wifi_frame rts = mk(16'h00B4, dur, my_mac, ta, 0, 16), cts = mk(16'h00C4, 0, ta, 0, 0, 10);
        bit m[$]; for (int b = 0; b < 10; b++) m.push_back(!(b == 2 || b == 3));   // duration not compared
        env.sb.expect_response(cts, m);
        rx(rts, 0, 1);
        #80us;
      end
      rx(mk(16'h00B4, 300, 48'h07_00_00_00_00_02, peer, 0, 16), 0, 1);   // RTS not for us: no CTS
      #80us;
      phase.drop_objection(this);
    endtask
  endclass

  // XPU-07: BlockAck after an A-MPDU addressed to us (AMPDU_ACTION: rx session for the TID).
  // Expected Compressed BlockAck (802.11-2020 9.3.1.8): FC 0x94, RA = TA of the A-MPDU,
  // TA = our MAC, BA Control = compressed bitmap | TID_INFO << 12, SSC = SSN << 4, bitmap bit i
  // = MPDU SSN + i received with good FCS. Run for TID 0 and a non-zero TID.
  class xpu_blkack_test extends xpu_base_test;
    `uvm_component_utils(xpu_blkack_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(500ms, 1); endfunction
    task run_phase(uvm_phase phase);
      int unsigned tids[$] = '{0, 5}; bit [11:0] ssn = 12'd100;
      phase.raise_objection(this);
      init_regs();
      foreach (tids[t]) begin
        int unsigned n = 5; bit [4:0] bad = 5'b00100;        // 3rd subframe with a bad FCS
        bit [63:0] bitmap = 0; wifi_frame ba; bit m[$];
        wr("AMPDU_ACTION", (1 << 31) | (tids[t] << 1)); wr("AMPDU_ACTION", (1 << 31) | (tids[t] << 1) | 1);   // rx start (clears the scoreboard)
        for (int k = 0; k < n; k++) if (!bad[k]) bitmap[k] = 1;
        ba = mk(16'h0094, 0, peer, my_mac, 0, 28);
        ba.mpdu[16] = 8'h04; ba.mpdu[17] = {4'(tids[t]), 4'h0};     // BA Control: compressed, TID_INFO
        ba.mpdu[18] = {ssn[3:0], 4'h0}; ba.mpdu[19] = ssn[11:4];    // SSC: fragment 0, SSN
        for (int b = 0; b < 8; b++) ba.mpdu[20 + b] = bitmap[8*b +: 8];
        for (int b = 0; b < 28; b++) m.push_back(!(b == 2 || b == 3));
        env.sb.expect_response(ba, m);
        for (int k = 0; k < n; k++) begin
          wifi_frame s = mk(16'h0088, 44, my_mac, peer, peer, 120);
          bit [11:0] sn = ssn + k;
          s.ht = 1; s.rate_hw = 4; s.ht_aggr = 1;
          s.mpdu[22] = {sn[3:0], 4'h0}; s.mpdu[23] = sn[11:4];       // sequence control
          s.mpdu[24] = {4'h0, 4'(tids[t])}; s.mpdu[25] = 0;          // QoS control: TID
          rx(s, bad[k], 1, k == n - 1, k != 0);
        end
        #120us;
        ssn += 64;
      end
      phase.drop_objection(this);
    endtask
  endclass

  // XPU-08: RSSI and LBT. A DDC tone at amplitudes A, 2A, 4A must raise rssi_half_db by
  // 12 and 24 half-dB (+-2); with LBT_TH between the A and 4A levels a host frame must not get
  // backoff_done while the strong tone is on, and must get it while only the weak one is.
  // rssi_half_db_lock_by_sig_valid must equal rssi_half_db at the SIGNAL-valid strobe.
  class xpu_rssi_test extends xpu_base_test;
    `uvm_component_utils(xpu_rssi_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(500ms, 1); endfunction
    function iq_item tone(real amp, int unsigned n);
      iq_item t = iq_item::type_id::create("tone");
      for (int k = 0; k < n; k++) begin
        t.i0.push_back(shortint'($rtoi(amp * $cos(2.0 * 3.14159265 * k / 16.0))));
        t.q0.push_back(shortint'($rtoi(amp * $sin(2.0 * 3.14159265 * k / 16.0))));
        t.i1.push_back(0); t.q1.push_back(0);
      end
      return t;
    endfunction
    task level(real amp, output int r);
      fork env.ddc.sqr.execute_item(tone(amp, 4000)); join_none
      #150us; r = $signed(env.prx.vif.rssi_half_db);
      wait fork;
    endtask
    task run_phase(uvm_phase phase);
      int r1, r2, r4; host_tx_result h; wifi_frame f;
      phase.raise_objection(this);
      init_regs();
      level(400, r1); level(800, r2); level(1600, r4);
      `uvm_info("RSSI", $sformatf("rssi_half_db: A %0d  2A %0d  4A %0d", r1, r2, r4), UVM_LOW)
      if (r2 - r1 < 10 || r2 - r1 > 14 || r4 - r1 < 22 || r4 - r1 > 26)
        `uvm_error("RSSI", $sformatf("rssi steps %0d / %0d half-dB for x2 / x4 amplitude, expected 12 / 24", r2 - r1, r4 - r1))
      wr("LBT_TH", (r1 + r4) / 2);
      f = mk(16'h0008, 0, peer, my_mac, peer, 80, 6);
      // strong tone on: no access until it stops
      fork
        env.ddc.sqr.execute_item(tone(1600, 4000));
        begin #20us; env.rsp.send(f, 0, 0, 0, h); end
      join
      if ((h.t_backoff_done[0] - h.t_trigger) < 150us)
        `uvm_error("LBT", $sformatf("backoff_done %0t after trigger while RSSI was above LBT_TH", h.t_backoff_done[0] - h.t_trigger))
      // weak tone: medium idle
      fork
        env.ddc.sqr.execute_item(tone(400, 4000));
        begin #20us; env.rsp.send(f, 0, 0, 0, h); end
      join
      if ((h.t_backoff_done[0] - h.t_trigger) > 40us)
        `uvm_error("LBT", $sformatf("backoff_done %0t after trigger although RSSI was below LBT_TH", h.t_backoff_done[0] - h.t_trigger))
      // lock by SIGNAL valid
      begin
        int at_sig; wifi_frame d = mk(16'h0008, 0, 48'h07_00_00_00_00_02, peer, peer, 60);
        fork
          env.ddc.sqr.execute_item(tone(800, 2000));
          rx(d);
          begin @(posedge env.prx.vif.clk iff env.prx.vif.pkt_header_valid_strobe); at_sig = $signed(env.prx.vif.rssi_half_db); end
        join
        #2us;
        if ($signed(env.rsp.vif.rssi_half_db_lock_by_sig_valid) != at_sig)
          `uvm_error("RSSI", $sformatf("rssi_half_db_lock_by_sig_valid %0d, rssi_half_db at SIGNAL valid %0d", $signed(env.rsp.vif.rssi_half_db_lock_by_sig_valid), at_sig))
      end
      phase.drop_objection(this);
    endtask
  endclass

  // XPU-09: time slices. Per queue SLICE_COUNT_TOTAL/START/END (us, queue index in [21:20]):
  // slice_en[q] is high while start <= counter <= end of a counter running 0..total, i.e.
  // (end-start+1) us every (total+1) us.
  class xpu_slice_test extends xpu_base_test;
    `uvm_component_utils(xpu_slice_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      int unsigned tot[4] = '{99, 49, 199, 29}, st[4] = '{10, 0, 50, 5}, en[4] = '{39, 24, 199, 5};
      phase.raise_objection(this);
      init_regs();
      for (int q = 0; q < 4; q++) begin
        wr("SLICE_COUNT_TOTAL", (q << 20) | tot[q]); wr("SLICE_COUNT_START", (q << 20) | st[q]); wr("SLICE_COUNT_END", (q << 20) | en[q]);
      end
      #500us;
      for (int q = 0; q < 4; q++) begin
        time r0, f0, r1; real hi, per;
        @(posedge env.rsp.vif.clk iff !env.rsp.vif.slice_en[q]);
        @(posedge env.rsp.vif.clk iff env.rsp.vif.slice_en[q]); r0 = $time;
        @(posedge env.rsp.vif.clk iff !env.rsp.vif.slice_en[q]); f0 = $time;
        @(posedge env.rsp.vif.clk iff env.rsp.vif.slice_en[q]); r1 = $time;
        hi = (f0 - r0) / 1us; per = (r1 - r0) / 1us;
        if (hi < en[q] - st[q] + 1 - 0.05 || hi > en[q] - st[q] + 1 + 0.05 || per < tot[q] + 1 - 0.05 || per > tot[q] + 1 + 0.05)
          `uvm_error("SLICE", $sformatf("queue %0d: on %.2f us every %.2f us, expected %0d every %0d", q, hi, per, en[q] - st[q] + 1, tot[q] + 1))
        else `uvm_info("SLICE", $sformatf("queue %0d: on %.2f us every %.2f us", q, hi, per), UVM_LOW)
      end
      phase.drop_objection(this);
    endtask
  endclass

  // every named register read, every writable one written with its own value (RAL coverage)
  class xpu_ral_access_test extends xpu_base_test;
    `uvm_component_utils(xpu_ral_access_test)
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
endpackage
