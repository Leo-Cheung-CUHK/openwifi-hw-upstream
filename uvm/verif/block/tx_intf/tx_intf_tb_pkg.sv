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

  // DAC lane / filter configuration the scoreboard models (mirrors the registers a test wrote)
  class txi_dac_cfg extends uvm_object;
    int unsigned bb_gain = 250;
    bit ant_flag;                       // ANT_SEL[1]: samples on the second DAC lane
    bit [1:0] cdd;                      // ANT_SEL[5:4]: [1] both lanes, [0] lane1 = lane0 one sample late
    int g1, g2; bit r1, r2;             // CSI_FUZZER: tap gains (7-bit signed) and rot90 flags
    `uvm_object_utils(txi_dac_cfg)
    function new(string name = "txi_dac_cfg"); super.new(name); endfunction
    function bit fuzz_on(); return g1 != 0 || g2 != 0; endfunction
  endclass

  class txi_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(txi_scoreboard)
    uvm_analysis_imp_obs #(phy_tx_obs, txi_scoreboard) obs_imp;
    uvm_analysis_imp_dac #(iq_item,    txi_scoreboard) dac_imp;
    wifi_frame bram_q[$], dac_q[$];
    // per DAC burst: list of expected {Q,I} words (arbitrary-I/Q mode), else the ACC ramp
    bit [31:0] dac_list_q[$][$];
    bit        dac_is_list[$];
    txi_dac_cfg dcfg = new("dcfg");
    int unsigned bb_gain = 250;         // kept for older tests; copied into dcfg
    int n_bram_ok, n_dac_ok, n_err, n_done;
    time t_dac_start[$], t_dac_end[$];  // per checked burst, for timing checks (CTS SIFS)
    event tx_done_ev;
    function new(string name, uvm_component parent);
      super.new(name, parent); obs_imp = new("obs_imp", this); dac_imp = new("dac_imp", this);
    endfunction
    function void expect_frame(wifi_frame f);
      bram_q.push_back(f); dac_q.push_back(f); dac_is_list.push_back(0);
    endfunction
    function void expect_iq_list(bit [31:0] l[$]);   // arbitrary I/Q burst, no PHY packet
      dac_list_q.push_back(l); dac_is_list.push_back(1);
    endfunction

    function void write_obs(phy_tx_obs o);
      wifi_frame f; string why;
      if (bram_q.size() == 0) begin `uvm_error("TXI_SB", "PHY started a packet nobody queued") return; end
      f = bram_q.pop_front();
      why = o.check(f);
      if (why == "") n_bram_ok++;
      else begin n_err++; `uvm_error("TXI_SB", {"BRAM image ", f.convert2string(), ": ", why}) end
      n_done++;
      ->tx_done_ev;
    endfunction

    // lane-0 sample k of the ACC ramp after tx_iq_intf (x*BB_GAIN >>> 7) and csi_fuzzer
    // (out_k = x_k + (g1*x_{k-2}) >>> 7 + (g2*x_{k-3}) >>> 7; rot90: tap = (-q*g, i*g))
    function void base(int k, output int i, output int q);
      shortint ri, rq;
      if (k < 0) begin i = 0; q = 0; return; end
      phy_tx_acc_model::ramp(k, ri, rq);
      i = int'(16'((32'(ri) * $signed(10'(dcfg.bb_gain))) >>> 7)); i = int'(shortint'(i));
      q = int'(16'((32'(rq) * $signed(10'(dcfg.bb_gain))) >>> 7)); q = int'(shortint'(q));
    endfunction
    function void tap(int k, int g, bit r, output int ti, output int tq);
      int i, q; base(k, i, q);
      ti = r ? ((-q * g) >>> 7) : ((i * g) >>> 7);
      tq = r ? (( i * g) >>> 7) : ((q * g) >>> 7);
    endfunction
    function void exp_ramp(int k, output shortint ei, output shortint eq);
      int i, q, t1i, t1q, t2i, t2q;
      base(k, i, q);
      tap(k - 2, dcfg.g1, dcfg.r1, t1i, t1q); tap(k - 3, dcfg.g2, dcfg.r2, t2i, t2q);
      ei = shortint'(i + t1i + t2i); eq = shortint'(q + t1q + t2q);
    endfunction

    function void write_dac(iq_item b);
      int unsigned n, extra; bit is_list; bit [31:0] lst[$]; wifi_frame f;
      if (dac_is_list.size() == 0) begin `uvm_error("TXI_SB", "DAC burst with no packet") return; end
      is_list = dac_is_list.pop_front();
      if (is_list) begin lst = dac_list_q.pop_front(); n = lst.size(); end
      else begin
        if (dac_q.size() == 0) begin `uvm_error("TXI_SB", "DAC burst with no packet") return; end
        f = dac_q.pop_front(); n = f.tx_samples();
      end
      extra = (dcfg.fuzz_on() ? 3 : 0) + (dcfg.cdd == 2'b01 ? 1 : 0);   // filter / CDD tails
      if (b.size() < n || b.size() > n + extra) begin
        n_err++; `uvm_error("TXI_SB", $sformatf("DAC burst %0d samples, expected %0d%s (%s)", b.size(), n,
                                                extra ? $sformatf("..%0d", n + extra) : "", is_list ? "arbitrary I/Q" : f.convert2string()))
        return;
      end
      for (int k = 0; k < n; k++) begin
        shortint ei, eq, l0i, l0q, l1i, l1q, pi, pq;
        if (is_list) begin ei = shortint'(lst[k][15:0]); eq = shortint'(lst[k][31:16]); end
        else exp_ramp(k, ei, eq);
        // lane placement (dac_intf.v): ant_flag -> lane1; cdd[1] both; cdd[0] lane1 delayed 1 sample
        if (is_list) begin pi = k ? shortint'(lst[k-1][15:0]) : 0; pq = k ? shortint'(lst[k-1][31:16]) : 0; end
        else if (k) exp_ramp(k - 1, pi, pq); else begin pi = 0; pq = 0; end
        if (dcfg.cdd[1])      begin l0i = ei; l0q = eq; l1i = ei; l1q = eq; end
        else if (dcfg.cdd[0]) begin l0i = ei; l0q = eq; l1i = pi; l1q = pq; end
        else if (dcfg.ant_flag) begin l0i = 0; l0q = 0; l1i = ei; l1q = eq; end
        else                  begin l0i = ei; l0q = eq; l1i = 0; l1q = 0; end
        if (b.i0[k] !== l0i || b.q0[k] !== l0q || b.i1[k] !== l1i || b.q1[k] !== l1q) begin
          n_err++;
          `uvm_error("TXI_SB", $sformatf("DAC sample %0d: lane0 (%0d,%0d) lane1 (%0d,%0d), expected (%0d,%0d) (%0d,%0d)",
                     k, b.i0[k], b.q0[k], b.i1[k], b.q1[k], l0i, l0q, l1i, l1q))
          return;
        end
      end
      t_dac_start.push_back(b.t_start); t_dac_end.push_back(b.t_start + b.size() * 50ns);   // last sample, 20 Msps
      n_dac_ok++;
    endfunction
    function void check_phase(uvm_phase phase);
      if (bram_q.size() || dac_is_list.size())
        `uvm_error("TXI_SB", $sformatf("outstanding: %0d never reached the PHY, %0d never reached the DAC", bram_q.size(), dac_is_list.size()))
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("TXI_SB", $sformatf("BRAM ok %0d  DAC ok %0d  errors %0d", n_bram_ok, n_dac_ok, n_err), UVM_NONE)
    endfunction
  endclass

  class txi_env extends uvm_env;
    `uvm_component_utils(txi_env)
    axil_agent axil; axis_agent dma; phy_tx_agent acc; iq_agent dac; txi_scoreboard sb; ow_cov_pkg::ral_access_cov rcov;
    tx_intf_regs regs; axil_reg_adapter adapter;
    virtual interface irq_if irq;
    virtual xpu_stub_ctl_if xctl;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      axis_cfg ac = axis_cfg::type_id::create("ac");
      phy_tx_cfg pc = phy_tx_cfg::type_id::create("pc");
      iq_cfg dc = iq_cfg::type_id::create("dc");
      ac.role = AXIS_MASTER;
      // dot11_tx produces symbols faster than real time and is held back by tx_hold
      // (FIFO > TX_HOLD_THRESHOLD); 2 clocks/sample keeps the I/Q FIFO filled the same way
      // (at exactly 20 Msps it would hover near empty, unlike the FPGA)
      pc.role = PHY_TX_ACC_MODEL; pc.acc_clk_per_sample = 2; pc.clk_per_us = `NUM_CLK_PER_US;
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
      rcov = ow_cov_pkg::ral_access_cov::type_id::create("rcov", this); rcov.blk = regs;
      adapter = axil_reg_adapter::type_id::create("adapter");
      if (!uvm_config_db#(virtual irq_if)::get(this, "", "irq", irq)) `uvm_fatal("NOVIF", "irq_if")
      if (!uvm_config_db#(virtual xpu_stub_ctl_if)::get(this, "", "xctl", xctl)) `uvm_fatal("NOVIF", "xpu_stub_ctl_if")
    endfunction
    function void connect_phase(uvm_phase phase);
      axil.mon.ap.connect(rcov.analysis_export);
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
          // ISR latency: tx_status_fifo publishes the entry 2-3 clocks after tx_try_complete
          // (registered empty flag + slv_reg22 copy); a CPU is microseconds behind the interrupt
          #1us;
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
      env.sb.bb_gain = s.bb_gain; env.sb.dcfg.bb_gain = s.bb_gain;
      // driver enables the tx interrupt in openwifi_start()
      s.wr(env.regs, "INTERRUPT_SEL", 32'h4);
    endtask
    task wr(string name, bit [31:0] v);
      uvm_status_e st; env.regs.r(name).write(st, v);
      if (st != UVM_IS_OK) `uvm_error("REGWR", $sformatf("%s <= 0x%0h failed", name, v))
    endtask
    task rd(string name, output bit [31:0] v);
      uvm_status_e st; uvm_reg_data_t d; env.regs.r(name).read(st, d); v = d;
      if (st != UVM_IS_OK) `uvm_error("REGRD", {name, " read failed"})
    endtask
    // openwifi_tx() for one MPDU / A-MPDU subframe: CTS_TOSELF_CONFIG, TX_CONFIG, PHY_HDR_CONFIG,
    // then the DMA buffer. dma: the bytes the driver hands to MM2S (default: the MPDU).
    // phy_hdr overrides f.phy_hdr_config() when non-zero (A-MPDU subframes).
    task submit(wifi_frame f, bit [5:0] bd, bit [31:0] cts_cfg = 0, bit [31:0] phy_hdr = 0,
                byte unsigned dma[$] = '{});
      axis_item dm = axis_item::type_id::create("dm");
      byte unsigned b[$]; bit [31:0] tc;
      if (dma.size()) begin b = dma; while (b.size() % 8) b.push_back(8'h00); end
      else f.tx_dma_bytes(b);
      tc = f.tx_config(bd);
      tc[12:0] = 13'(b.size() / 8);                     // num_dma_symbol of what is DMA'd
      wr("CTS_TOSELF_CONFIG", cts_cfg);
      wr("TX_CONFIG", tc);
      wr("PHY_HDR_CONFIG", phy_hdr ? phy_hdr : f.phy_hdr_config());
      dm.from_bytes_word_padded(b);
      env.dma.sqr.execute_item(dm);
    endtask
    // the frame the PHY will be asked for next: scoreboard + ACC model, in air order
    function void expect_air(wifi_frame f);
      env.sb.expect_frame(f); void'(env.acc.acc.exp_mb.try_put(f));
    endfunction
    task wait_done(int unsigned n, real timeout_us = 20000);
      int unsigned target = env.sb.n_done + n;
      fork
        wait (env.sb.n_done >= target);
        begin #(timeout_us * 1us); `uvm_error("TXI", $sformatf("timeout: %0d of %0d packets done", n - (target - env.sb.n_done), n)) end
      join_any
      disable fork;
      #50us;   // DAC drain (<= TX_HOLD_THRESHOLD 420 samples = 21 us) + stub 20 us + status FIFO
    endtask
    // one tx_status entry (= one tx_try_complete), as the ISR reads it
    task pkt_info(output bit [5:0] bd, output bit [1:0] q, output bit [5:0] pkt_cnt);
      bit [31:0] i1, i2;
      rd("PKT_INFO1", i1); rd("PKT_INFO2", i2);
      if (i1 == 32'hFFFF_FFFF) `uvm_error("PKT_INFO", "status FIFO empty")
      bd = i1[10:5]; q = i1[16:15]; pkt_cnt = i2[5:0];
    endtask
    // (argument names must not match wifi_frame members: inside randomize() with {} an
    //  unqualified name resolves to the object first)
    function wifi_frame rand_frame(int unsigned lmin, int unsigned lmax, int want_q = -1, int want_ht = -1);
      wifi_frame f = wifi_frame::type_id::create("f");
      if (!f.randomize() with { mpdu_len inside {[lmin:lmax]}; need_ack == 0;
                                if (want_q >= 0) queue_idx == want_q; if (want_ht >= 0) ht == want_ht; })
        `uvm_fatal("RAND", "frame")
      return f;
    endfunction
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

  // TXI-03: four queues. With slice_en off the frames wait in their queue FIFOs; enabling
  // queues sends them queue by queue in priority order 0 > 1 > 2 > 3 (tx_bit_intf
  // WAIT_TO_TRIG), FIFO order inside a queue; PKT_INFO reports the queue; QUEUE_FIFO_DATA_COUNT
  // counts pending frames. Then S_AXIS_FIFO_TH: S_AXIS_FIFO_NO_ROOM[q] must be 1 exactly while
  // the queue's DMA FIFO holds more 64-bit words than the threshold.
  class txi_queues_test extends txi_base_test;
    `uvm_component_utils(txi_queues_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(200ms, 1); endfunction
    task release_and_check(bit [3:0] en, ref wifi_frame qf[4][$], ref bit [5:0] qbd[4][$]);
      int unsigned n = 0; bit [5:0] bd, pc; bit [1:0] q;
      wifi_frame order[$]; bit [5:0] obd[$]; bit [1:0] oq[$];
      for (int k = 0; k < 4; k++) if (en[k]) while (qf[k].size()) begin
        order.push_back(qf[k].pop_front()); obd.push_back(qbd[k].pop_front()); oq.push_back(k[1:0]);
      end
      foreach (order[i]) expect_air(order[i]);
      env.xctl.slice_en = en;
      wait_done(order.size());
      env.xctl.slice_en = 0;
      foreach (order[i]) begin
        pkt_info(bd, q, pc);
        if (bd != obd[i] || q != oq[i])
          `uvm_error("TXI_Q", $sformatf("completion %0d: bd %0d queue %0d, expected bd %0d queue %0d", i, bd, q, obd[i], oq[i]))
      end
      `uvm_info("TXI_Q", $sformatf("slice_en=%04b: %0d frames in priority/FIFO order", en, order.size()), UVM_LOW)
    endtask
    task run_phase(uvm_phase phase);
      wifi_frame qf[4][$]; bit [5:0] qbd[4][$]; int unsigned nq[4] = '{2, 3, 3, 2}, bd = 0;
      bit [31:0] cnt, nr; int unsigned th = 100, words = 0;
      phase.raise_objection(this);
      init_regs();
      env.xctl.slice_en = 0;
      foreach (nq[k]) repeat (nq[k]) begin
        wifi_frame f = rand_frame(24, 400, k);
        submit(f, bd[5:0]); qf[k].push_back(f); qbd[k].push_back(bd[5:0]); bd++;
      end
      #2us; rd("QUEUE_FIFO_DATA_COUNT", cnt);
      if (cnt[6:0] != nq[0] || cnt[14:8] != nq[1] || cnt[22:16] != nq[2] || cnt[30:24] != nq[3])
        `uvm_error("TXI_Q", $sformatf("QUEUE_FIFO_DATA_COUNT 0x%08h, expected %0d/%0d/%0d/%0d", cnt, nq[0], nq[1], nq[2], nq[3]))
      if (env.irq.n_tx_itrpt) `uvm_error("TXI_Q", "frames left a queue whose slice_en is 0")
      release_and_check(4'b0100, qf, qbd);       // queue 2 alone
      release_and_check(4'b1010, qf, qbd);       // queues 1 and 3: 1 first
      release_and_check(4'b0001, qf, qbd);       // queue 0
      // DMA FIFO room flag
      wr("S_AXIS_FIFO_TH", th);
      while (words <= th + 40) begin
        wifi_frame f = rand_frame(200, 300, 1);
        submit(f, bd[5:0]); qf[1].push_back(f); qbd[1].push_back(bd[5:0]); bd++;
        words += (f.mpdu_len + 7) / 8;
        #1us; rd("S_AXIS_FIFO_NO_ROOM", nr);
        if (nr[1] != (words > th)) `uvm_error("TXI_Q", $sformatf("S_AXIS_FIFO_NO_ROOM=0x%0h with %0d words queued, threshold %0d", nr, words, th))
        if (nr[0] || nr[2] || nr[3]) `uvm_error("TXI_Q", $sformatf("S_AXIS_FIFO_NO_ROOM=0x%0h: flag on an empty queue", nr))
      end
      release_and_check(4'b0010, qf, qbd);
      rd("S_AXIS_FIFO_NO_ROOM", nr);
      if (nr[1]) `uvm_error("TXI_Q", "S_AXIS_FIFO_NO_ROOM[1] still set after the queue drained")
      phase.drop_objection(this);
    endtask
  endclass

  // TXI-04: A-MPDU build. Subframes exactly as openwifi_tx() makes them (delimiter, MPDU, FCS,
  // pad to 4, empty delimiter to an 8-byte multiple), queued while the queue is blocked, then
  // released. tx_bit_intf must join them into one PSDU per aggregate, stopping at
  // AMPDU_ACTION_CONFIG buf_size / max_tx_bytes, at a new session (ht_aggr_start) and at a
  // non-aggregated frame; HT-SIG LENGTH = sum of the subframes, aggregation bit set;
  // PKT_INFO2[5:0] = subframes in the aggregate.
  class txi_ampdu_test extends txi_base_test;
    `uvm_component_utils(txi_ampdu_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(200ms, 1); endfunction
    // driver subframe: [delimiter | MPDU | FCS | pad to 4] (+ empty delimiter 0x4e140000 to 8)
    static function void subframe(const ref byte unsigned m[$], ref byte unsigned out[$]);
      bit [31:0] fcs = crc32(m, m.size()); bit [15:0] d16 = {12'(m.size() + 4), 4'h0};
      int unsigned l;
      out.delete();
      out.push_back(d16[7:0]); out.push_back(d16[15:8]); out.push_back(crc8_bits(64'(d16), 16)); out.push_back(8'h4E);
      foreach (m[k]) out.push_back(m[k]);
      for (int k = 0; k < 4; k++) out.push_back(fcs[8*k +: 8]);
      while (out.size() % 4) out.push_back(8'h00);
      if (out.size() % 8) begin out.push_back(8'h00); out.push_back(8'h00); out.push_back(8'h14); out.push_back(8'h4E); end
    endfunction
    // one scenario: n subframes (start flags given), buf_size / max bytes; returns nothing,
    // checks against the greedy model of tx_bit_intf CHECK_AGGR
    task scenario(string name, int unsigned rate, bit sgi, int unsigned lens[$], bit starts[$], int unsigned buf_sz, int unsigned max_b,
                  bit tail_plain = 0, ref int unsigned bd);
      byte unsigned sf[$][$]; wifi_frame agg[$]; int unsigned agg_n[$]; byte unsigned cur[$]; int unsigned cnt = 0;
      wifi_frame plain;
      wr("AMPDU_ACTION_CONFIG", (2 << 24) | (buf_sz << 16) | max_b);
      foreach (lens[i]) begin
        byte unsigned m[$], o[$];
        m.push_back(8'h88); m.push_back(8'h01);          // QoS data FC
        for (int k = 2; k < lens[i]; k++) m.push_back(8'($urandom));
        subframe(m, o); sf.push_back(o);
      end
      // expected aggregates
      foreach (sf[i]) begin
        if (cnt && (cnt + 1 > buf_sz || cur.size() + sf[i].size() > max_b || starts[i])) begin
          wifi_frame a = wifi_frame::type_id::create("agg"); a.c_aggr.constraint_mode(0);
          if (!a.randomize() with { ht == 1; ht_aggr == 1; rate_hw == rate; sgi == local::sgi; mpdu_len == cur.size(); queue_idx == 2; need_ack == 0; })
            `uvm_fatal("RAND", "agg")
          a.mpdu = new[cur.size()]; foreach (cur[k]) a.mpdu[k] = cur[k];
          agg.push_back(a); agg_n.push_back(cnt); cur.delete(); cnt = 0;
        end
        foreach (sf[i][k]) cur.push_back(sf[i][k]); cnt++;
      end
      begin
        wifi_frame a = wifi_frame::type_id::create("agg"); a.c_aggr.constraint_mode(0);
        if (!a.randomize() with { ht == 1; ht_aggr == 1; rate_hw == rate; sgi == local::sgi; mpdu_len == cur.size(); queue_idx == 2; need_ack == 0; })
          `uvm_fatal("RAND", "agg")
        a.mpdu = new[cur.size()]; foreach (cur[k]) a.mpdu[k] = cur[k];
        agg.push_back(a); agg_n.push_back(cnt);
      end
      // queue everything with queue 2 blocked
      env.xctl.slice_en = 0;
      foreach (sf[i]) begin
        wifi_frame t = wifi_frame::type_id::create("t"); t.c_aggr.constraint_mode(0);
        if (!t.randomize() with { ht == 1; ht_aggr == 1; rate_hw == rate; sgi == local::sgi; queue_idx == 2; need_ack == 0; mpdu_len == 24; })
          `uvm_fatal("RAND", "sub")
        submit(t, bd[5:0], 0, {11'd0, starts[i], 4'(rate), 1'b1, sgi, 1'b1, 13'(sf[i].size())}, sf[i]); bd++;
      end
      if (tail_plain) begin
        plain = rand_frame(40, 200, 2, 1); plain.sgi = sgi; plain.rate_hw = rate;
        submit(plain, bd[5:0]); bd++;
      end
      foreach (agg[i]) expect_air(agg[i]);
      if (tail_plain) expect_air(plain);
      env.xctl.slice_en = 4'b0100;
      wait_done(agg.size() + tail_plain);
      env.xctl.slice_en = 0;
      foreach (agg[i]) begin
        bit [5:0] b, pc; bit [1:0] q;
        pkt_info(b, q, pc);
        if (pc != agg_n[i]) `uvm_error("TXI_AMPDU", $sformatf("%s aggregate %0d: PKT_INFO2 pkt_cnt %0d, expected %0d subframes", name, i, pc, agg_n[i]))
      end
      if (tail_plain) begin bit [5:0] b, pc; bit [1:0] q; pkt_info(b, q, pc); end
      `uvm_info("TXI_AMPDU", $sformatf("%s: %0d subframes -> %0d aggregates%s", name, sf.size(), agg.size(), tail_plain ? " + 1 plain frame" : ""), UVM_LOW)
    endtask
    task run_phase(uvm_phase phase);
      int unsigned bd = 0;
      phase.raise_objection(this);
      init_regs();
      scenario("buf_size=4",   7, 0, '{60, 120, 80, 200, 90, 150}, '{1, 0, 0, 0, 0, 0}, 4, 8191, 0, bd);
      // buf_size is AMPDU_ACTION_CONFIG[21:16] (6 bits, max 63; the driver writes 4)
      scenario("max_bytes=600", 4, 1, '{150, 150, 150, 150, 150}, '{1, 0, 0, 0, 0}, 63, 600, 0, bd);
      scenario("new session",  2, 0, '{100, 100, 100, 100}, '{1, 0, 1, 0}, 63, 8191, 0, bd);
      scenario("then plain",   5, 0, '{70, 70, 70}, '{1, 0, 0}, 63, 8191, 1, bd);
      phase.drop_objection(this);
    endtask
  endclass

  // TXI-05: CTS-to-self. CTS_TOSELF_CONFIG[31] makes tx_bit_intf send a CTS (FC 0xC4, duration,
  // RA = own MAC, 14-byte PSDU at the CTS rate) first, wait CTS_TOSELF_WAIT_SIFS_TOP after its
  // I/Q left the FIFO, then send the data frame. Checks: both BRAM images, both DAC bursts,
  // the gap between them, one tx_try_complete for the pair (the stub, like xpu tx_control,
  // ignores the CTS's phy_tx_done while cts_toself_bb_is_ongoing).
  class txi_cts_toself_test extends txi_base_test;
    `uvm_component_utils(txi_cts_toself_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(100ms, 1); endfunction
    task run_phase(uvm_phase phase);
      int unsigned rates[$] = '{4, 6, 11};   // CTS rate_hw (6, 12, 54 Mbps)
      bit [47:0] mac = 48'hA1_B2_C3_D4_E5_F6;
      int unsigned sifs_us = 16;
      phase.raise_objection(this);
      init_regs();
      env.xctl.mac_addr = mac;
      foreach (rates[r]) for (int traffic = 0; traffic < 2; traffic++) begin
        wifi_frame d = rand_frame(60, 400, 0, traffic ? 0 : -1), c = wifi_frame::type_id::create("cts");
        bit [15:0] dur = 16'($urandom_range(2000, 100)); int unsigned cts_hw;
        bit [3:0] data_code;
        time gap;
        data_code = d.ht ? 4'(d.rate_hw) : legacy_rate_code(d.rate_hw);
        cts_hw = traffic ? (d.ht ? 4 : d.rate_hw) : rates[r];
        // fields set after a plain randomize(): xsim 2022.2 null-object error on randomize() with {} here (finding 10)
        if (!c.randomize()) `uvm_fatal("RAND", "cts")
        c.ht = 0; c.sgi = 0; c.ht_aggr = 0; c.rate_hw = cts_hw; c.need_ack = 0; c.set_len(10);   // a CTS MPDU is 10 bytes
        c.mpdu[0] = 8'hC4; c.mpdu[1] = 8'h00; c.mpdu[2] = dur[7:0]; c.mpdu[3] = dur[15:8];
        for (int k = 0; k < 6; k++) c.mpdu[4 + k] = mac[8*k +: 8];
        expect_air(c); expect_air(d);
        submit(d, 6'(r * 2 + traffic), {1'b1, 1'(traffic), 6'd0, dur, legacy_rate_code(rates[r]), data_code});
        wait_done(2);
        if (env.sb.t_dac_start.size() >= 2) begin
          gap = env.sb.t_dac_start[$] - env.sb.t_dac_end[$-1];
          if (gap < sifs_us * 1us || gap > (sifs_us + 6) * 1us)
            `uvm_error("TXI_CTS", $sformatf("CTS end -> data start %0t, expected SIFS %0d us (+ PHY latency)", gap, sifs_us))
        end
        if (env.irq.n_tx_itrpt != r * 2 + traffic + 1)
          `uvm_error("TXI_CTS", $sformatf("%0d tx_try_complete interrupts for %0d CTS+data pairs", env.irq.n_tx_itrpt, r * 2 + traffic + 1))
        begin bit [5:0] b, pc; bit [1:0] q; pkt_info(b, q, pc);
          if (b != 6'(r * 2 + traffic)) `uvm_error("TXI_CTS", $sformatf("PKT_INFO bd %0d, expected %0d", b, r * 2 + traffic)) end
      end
      phase.drop_objection(this);
    endtask
  endclass

  // TXI-06: arbitrary I/Q (sysfs_intf.c tx_intf_iq_ctl_store): ARBITRARY_IQ_CTL=1, N writes
  // of {Q,I} to ARBITRARY_IQ, CTL=3 (trigger), CTL=0. The DAC must play exactly the written
  // samples, without BB_GAIN; afterwards normal frames must still work.
  class txi_arbitrary_iq_test extends txi_base_test;
    `uvm_component_utils(txi_arbitrary_iq_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      int unsigned ns[$] = '{1, 7, 64, 300};
      phase.raise_objection(this);
      init_regs();
      foreach (ns[t]) begin
        bit [31:0] l[$];
        repeat (ns[t]) begin
          shortint i = shortint'($urandom_range(20000, 200)), q = shortint'($urandom_range(20000, 200));
          if ($urandom_range(1)) i = -i; if ($urandom_range(1)) q = -q;
          l.push_back({q, i});
        end
        env.sb.expect_iq_list(l);
        wr("ARBITRARY_IQ_CTL", 1);
        foreach (l[k]) wr("ARBITRARY_IQ", l[k]);
        wr("ARBITRARY_IQ_CTL", 3);
        wr("ARBITRARY_IQ_CTL", 0);
        #(ns[t] * 50ns + 10us);
        `uvm_info("TXI_ARB", $sformatf("%0d samples played", ns[t]), UVM_LOW)
      end
      begin wifi_frame f = rand_frame(40, 300); expect_air(f); submit(f, 0); wait_done(1); end
      phase.drop_objection(this);
    endtask
  endclass

  // TXI-07: DAC lane placement and the CSI fuzzer. ANT_SEL[1] moves the stream to the second
  // DAC lane; ANT_SEL[5:4]=10 duplicates it, =01 adds a one-sample cyclic delay on lane 1;
  // CSI_FUZZER adds two delayed taps (g1 at 2 samples, g2 at 3, optional 90-degree rotation).
  // The scoreboard models each setting sample-exact.
  class txi_ant_test extends txi_base_test;
    `uvm_component_utils(txi_ant_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task cfg_and_send(string name, bit ant, bit [1:0] cdd, int g1, bit r1, int g2, bit r2);
      wifi_frame f = rand_frame(40, 250);
      env.sb.dcfg.ant_flag = ant; env.sb.dcfg.cdd = cdd;
      env.sb.dcfg.g1 = g1; env.sb.dcfg.r1 = r1; env.sb.dcfg.g2 = g2; env.sb.dcfg.r2 = r2;
      wr("ANT_SEL", {26'd0, cdd, 2'b00, ant, ~ant});
      wr("CSI_FUZZER", {12'd0, r2, 2'd0, 7'(g2), r1, 2'd0, 7'(g1)});   // [6:0] g1, [9] rot1, [16:10] g2, [19] rot2
      #2us;                                          // CDC of ant/cdd flags into the DAC clock domain
      expect_air(f); submit(f, 0); wait_done(1);
      `uvm_info("TXI_ANT", {name, " ok"}, UVM_LOW)
    endtask
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      init_regs();
      cfg_and_send("ant0",              0, 2'b00,   0, 0,   0, 0);
      cfg_and_send("ant1",              1, 2'b00,   0, 0,   0, 0);
      cfg_and_send("both lanes",        0, 2'b10,   0, 0,   0, 0);
      cfg_and_send("simple CDD",        0, 2'b01,   0, 0,   0, 0);
      cfg_and_send("fuzzer g1=+40",     0, 2'b00,  40, 0,   0, 0);
      cfg_and_send("fuzzer g1=-30 rot", 0, 2'b00, -30, 1,   0, 0);
      cfg_and_send("fuzzer g1,g2",      0, 2'b00,  25, 0, -20, 1);
      cfg_and_send("ant1 + fuzzer",     1, 2'b00, -64, 0,  63, 0);
      cfg_and_send("back to default",   0, 2'b00,   0, 0,   0, 0);
      phase.drop_objection(this);
    endtask
  endclass
endpackage
