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
    // IQ-capture mode (IQ_CAPTURE=1, iq_capture_cfg=01: {iq1, iq0} per word): record = TSF + iq_len
    // words; iq0 = {sample0[15:0], sample0[31:16]}, so word[15:0] is the TB's sample counter.
    // trig_n: sample counter at each expected trigger; the window must start pre_len before it.
    bit iq_mode; int unsigned iq_len, pre_len; int unsigned trig_n[$];
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function int unsigned rec_len(); return iq_mode ? 1 + iq_len : HEADER_LEN + CSI_LEN + num_eq * EQ_LEN; endfunction
    function void check_iq(int unsigned r);
      bit [15:0] n0 = words[1][15:0];
      for (int k = 1; k < iq_len; k++)
        if (words[1 + k][15:0] !== 16'(n0 + k)) begin
          n_err++; `uvm_error("SCH_SB", $sformatf("IQ record %0d: sample %0d is %0d, expected %0d (window not contiguous)", r, k, words[1 + k][15:0], 16'(n0 + k)))
          return;
        end
      if (trig_n.size() == 0) begin n_err++; `uvm_error("SCH_SB", $sformatf("IQ record %0d without an expected trigger", r)) return; end
      begin
        int d = int'(16'(trig_n[0] - n0)) - int'(pre_len);
        void'(trig_n.pop_front());
        if (d < -3 || d > 3) begin n_err++; `uvm_error("SCH_SB", $sformatf("IQ record %0d starts %0d samples before the trigger, PRE_TRIGGER_LEN %0d", r, d + pre_len, pre_len)) end
      end
    endfunction
    function void write(axis_item t);
      foreach (t.data[i]) words.push_back(t.data[i]);
      n_words_total += t.data.size();
      while (words.size() >= rec_len()) begin
        bit [63:0] tsf = words[0];
        n_rec++;
        if (iq_mode) check_iq(n_rec);
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
    axil_agent axil; axis_agent dma; phy_rx_agent prx; sch_scoreboard sb; ow_cov_pkg::ral_access_cov rcov;
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
      rcov = ow_cov_pkg::ral_access_cov::type_id::create("rcov", this); rcov.blk = regs;
      adapter = axil_reg_adapter::type_id::create("adapter");
      if (!uvm_config_db#(virtual side_ch_side_if)::get(this, "", "side", side)) `uvm_fatal("NOVIF", "side_ch_side_if")
    endfunction
    function void connect_phase(uvm_phase phase);
      axil.mon.ap.connect(rcov.analysis_export);
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

  class sch_base_test extends uvm_test;
    `uvm_component_utils(sch_base_test)
    sch_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase); env = sch_env::type_id::create("env", this); endfunction
    task wr(string name, bit [31:0] v);
      uvm_status_e st; env.regs.r(name).write(st, v);
      if (st != UVM_IS_OK) `uvm_error("REGWR", $sformatf("%s <= 0x%0h failed", name, v))
    endtask
    task csi_cfg(int unsigned num_eq, bit [31:0] config_reg = 32'h1);
      side_ch_csi_cfg_seq c = side_ch_csi_cfg_seq::type_id::create("c");
      c.rb = env.regs; c.num_eq = num_eq; env.sb.num_eq = num_eq; c.start(null);
      if (config_reg != 1) wr("CONFIG", config_reg);
    endtask
    // a received frame with the given FC / addr1 / addr2
    task rx(bit [15:0] fc, bit [47:0] a1, bit [47:0] a2, bit corrupt = 0, int unsigned len = 60);
      phy_rx_item it = phy_rx_item::type_id::create("it");
      if (!it.randomize() with { frame.mpdu_len == len; frame.ht == 0; corrupt_fcs == corrupt; }) `uvm_fatal("RAND", "item")
      it.frame.set_header(fc, 16'd44, a1, a2, a2, 12'($urandom));
      env.prx.sqr.execute_item(it);
    endtask
    // driver get_side_info(): read M_AXIS_DATA_COUNT, round down to whole records, write that
    // to NUM_DMA_SYMBOL (its write edge starts one DMA transfer), wait for the transfer
    task pull();
      uvm_status_e st; uvm_reg_data_t d; int unsigned n, per = env.sb.rec_len(), w0 = env.sb.n_words_total;
      env.regs.r("M_AXIS_DATA_COUNT").read(st, d);
      n = per * (int'(d) / per);
      if (n == 0) return;
      wr("NUM_DMA_SYMBOL", n);
      fork : wait_drain
        wait (env.sb.n_words_total >= w0 + n);
        #200us;
      join_any
      disable wait_drain;
      if (env.sb.n_words_total < w0 + n) `uvm_error("SCH_PULL", $sformatf("pulled %0d words, %0d arrived", n, env.sb.n_words_total - w0))
    endtask
    // the last 4 octets of an address as side_ch compares them (side_ch_control.v)
    static function bit [31:0] addr_target(bit [47:0] a); return {a[23:16], a[31:24], a[39:32], a[47:40]}; endfunction
  endclass

  // SCH-02: match filters. CONFIG[14:12] = {addr2, addr1, FC} enables; FC_TARGET / ADDR1_TARGET
  // / ADDR2_TARGET. A CSI record must be produced exactly for the frames matching every
  // enabled field.
  class sch_match_test extends sch_base_test;
    `uvm_component_utils(sch_match_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      bit [47:0] me = 48'h66_55_44_33_22_12, other = 48'h07_00_00_00_00_02, peer = 48'h02_AA_BB_CC_DD_EE;
      bit [15:0] fc_data = 16'h0008, fc_qos = 16'h0088;
      bit [2:0] cfgs[$] = '{3'b000, 3'b001, 3'b010, 3'b100, 3'b011, 3'b111};
      int unsigned exp_rec = 0;
      phase.raise_objection(this);
      foreach (cfgs[c]) begin
        csi_cfg(1, {17'd0, cfgs[c], 12'h001});
        wr("FC_TARGET", fc_qos); wr("ADDR1_TARGET", addr_target(me)); wr("ADDR2_TARGET", addr_target(peer));
        for (int fc_i = 0; fc_i < 2; fc_i++) for (int a1_i = 0; a1_i < 2; a1_i++) for (int a2_i = 0; a2_i < 2; a2_i++) begin
          bit m = (!cfgs[c][0] || fc_i) && (!cfgs[c][1] || a1_i) && (!cfgs[c][2] || a2_i);
          int unsigned n0 = env.sb.n_rec;
          if (m) env.sb.tsf_min_q.push_back(env.side.tsf);
          rx(fc_i ? fc_qos : fc_data, a1_i ? me : other, a2_i ? peer : other);
          #40us; pull();
          exp_rec += m;
          if (env.sb.n_rec != n0 + m)
            `uvm_error("SCH_MATCH", $sformatf("match_cfg %03b, FC %s addr1 %s addr2 %s: %0d records, expected %0d", cfgs[c],
                       fc_i ? "match" : "other", a1_i ? "match" : "other", a2_i ? "match" : "other", env.sb.n_rec - n0, m))
        end
      end
      `uvm_info("SCH_MATCH", $sformatf("%0d records for %0d matching frames", env.sb.n_rec, exp_rec), UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass

  // SCH-03: IQ capture (IQ_CAPTURE=1, {iq1, iq0} words, source sample0). For trigger sources
  // fcs (0), fcs ok (1), fcs bad (2) and SIGNAL valid (4) a record must appear exactly for the
  // frames that fire the trigger; each record = TSF + IQ_LEN consecutive samples starting
  // PRE_TRIGGER_LEN samples before the trigger.
  class sch_iq_capture_test extends sch_base_test;
    `uvm_component_utils(sch_iq_capture_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(200ms, 1); endfunction
    task run_phase(uvm_phase phase);
      int unsigned sels[$] = '{0, 1, 2, 4}; int unsigned L = 120, P = 40;
      phase.raise_objection(this);
      env.sb.iq_mode = 1; env.sb.iq_len = L; env.sb.pre_len = P;
      foreach (sels[si]) begin
        wr("MULTI_RST", 4); wr("MULTI_RST", 0);
        wr("CONFIG", 1); wr("FC_TARGET", 0);              // iq_source_select 0 (sample0), no free run
        wr("IQ_CAPTURE", 32'h11);                         // iq_capture=1, iq_capture_cfg=01
        wr("PRE_TRIGGER_LEN", P); wr("IQ_LEN", L); wr("IQ_TRIGGER", sels[si]);
        #20us;
        for (int k = 0; k < 4; k++) begin
          bit bad = k % 2, fire = (sels[si] == 0 || sels[si] == 4) || (sels[si] == 1 && !bad) || (sels[si] == 2 && bad);
          int unsigned n0 = env.sb.n_rec;
          fork
            rx(16'h0008, 48'h07_00_00_00_00_02, 48'h02_AA_BB_CC_DD_EE, bad, 80);
            begin
              if (sels[si] == 4) @(posedge env.side.clk iff env.prx.vif.pkt_header_valid_strobe);
              else               @(posedge env.side.clk iff env.prx.vif.fcs_out_strobe);
              if (fire) begin env.sb.trig_n.push_back(env.side.sample_n); env.sb.tsf_min_q.push_back(env.side.tsf - 1); end
            end
          join
          #((L + 50) * 50ns);
          wr("NUM_DMA_SYMBOL", ((L + 1) << 16) | (L + 1));     // pull the record (driver get_side_info)
          #((L + 1) * 20ns + 10us);
          if (env.sb.n_rec != n0 + fire)
            `uvm_error("SCH_IQ", $sformatf("trigger %0d, frame %0d (%s FCS): %0d records, expected %0d", sels[si], k, bad ? "bad" : "good", env.sb.n_rec - n0, fire))
        end
      end
      phase.drop_objection(this);
    endtask
  endclass

  // SCH-04: NUM_EQ sweep 0..8: every CSI record must be 2 + 56 + num_eq*52 words long and the
  // stream must stay on record boundaries (frames long enough to have >= num_eq symbols and short ones).
  class sch_num_eq_test extends sch_base_test;
    `uvm_component_utils(sch_num_eq_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(200ms, 1); endfunction
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      for (int ne = 0; ne <= 8; ne++) begin
        int unsigned n0 = env.sb.n_rec;
        #20us;
        if (env.sb.words.size()) `uvm_error("SCH_EQ", $sformatf("num_eq %0d: %0d words left from the previous setting", ne, env.sb.words.size()))
        env.sb.words.delete();
        csi_cfg(ne);
        for (int k = 0; k < 2; k++) begin
          env.sb.tsf_min_q.push_back(env.side.tsf);
          rx(16'h0008, 48'h07_00_00_00_00_02, 48'h02_AA_BB_CC_DD_EE, 0, k ? 400 : 30);
          #60us; pull();
        end
        if (env.sb.n_rec != n0 + 2) `uvm_error("SCH_EQ", $sformatf("num_eq %0d: %0d records of %0d words, expected 2", ne, env.sb.n_rec - n0, env.sb.rec_len()))
        else `uvm_info("SCH_EQ", $sformatf("num_eq %0d: records of %0d words", ne, env.sb.rec_len()), UVM_LOW)
      end
      phase.drop_objection(this);
    endtask
  endclass

  class sch_csi_test extends sch_base_test;
    `uvm_component_utils(sch_csi_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      bit [31:0] cnt; uvm_status_e st; uvm_reg_data_t d;
      phase.raise_objection(this);
      csi_cfg(1);
      #20us; env.sb.words.delete(); env.sb.n_rec = 0;   // drop the transfer started by the config write
      repeat (8) begin
        phy_rx_item it = phy_rx_item::type_id::create("it");
        if (!it.randomize() with { frame.mpdu_len inside {[24:200]}; }) `uvm_fatal("RAND", "item")
        env.sb.tsf_min_q.push_back(env.side.tsf);
        env.prx.sqr.execute_item(it);
        #20us; pull();
      end
      #50us;
      env.regs.r("M_AXIS_DATA_COUNT").read(st, d); cnt = d;
      `uvm_info("SCH", $sformatf("M_AXIS_DATA_COUNT=%0d after drain, %0d words drained", cnt, env.sb.n_words_total), UVM_LOW)
      if (env.sb.n_rec != 8) `uvm_error("SCH", $sformatf("%0d CSI records for 8 frames", env.sb.n_rec))
      if (cnt != 0) `uvm_error("SCH", $sformatf("M_AXIS_DATA_COUNT %0d after pulling every record", cnt))
      phase.drop_objection(this);
    endtask
  endclass
endpackage
