// Agent for the tx_intf <-> openofdm_tx interface.
//   PHY_TX_BRAM_SERVER : TB plays tx_intf  (DUT = openofdm_tx, also used for the peer TX)
//   PHY_TX_ACC_MODEL   : TB plays openofdm_tx (DUT = tx_intf): reads the BRAM image the DUT
//                        built, then plays out a deterministic I/Q ramp so the DAC path can be
//                        checked sample-exact
//   passive monitor    : publishes the BRAM image read for each packet (phy_tx_obs)
package phy_tx_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import wifi_pkg::*;

  typedef enum {PHY_TX_BRAM_SERVER, PHY_TX_ACC_MODEL, PHY_TX_PASSIVE} phy_tx_role_e;
  // BRAM-server back-pressure: none, random per cycle, or a model of tx_iq_intf's FIFO
  // (hold = occupancy > threshold, drained at 20 Msps) -- the pattern the real PHY sees
  typedef enum {HOLD_NONE, HOLD_RANDOM, HOLD_FIFO_MODEL} phy_tx_hold_e;

  class phy_tx_cfg extends uvm_object;
    phy_tx_role_e role        = PHY_TX_PASSIVE;
    int unsigned  bram_latency = 1;
    phy_tx_hold_e hold_mode    = HOLD_NONE;
    int unsigned  hold_pct     = 0;    // HOLD_RANDOM: % of cycles with tx_hold=1
    int unsigned  fifo_th      = 420;  // HOLD_FIFO_MODEL: TX_HOLD_THRESHOLD (driver default)
    int unsigned  drain_clks   = 5;    // HOLD_FIFO_MODEL: clocks per 20 Msps sample
    int unsigned  ifs_clks     = 1600; // BRAM server: idle after phy_tx_done before the next frame
                                       // (16 us SIFS @100 MHz; real frames are never back to back)
    int unsigned  acc_clk_per_sample = 5;
    int unsigned  acc_start_latency  = 20;  // clocks from phy_tx_start to phy_tx_started
    `uvm_object_utils(phy_tx_cfg)
    function new(string name = "phy_tx_cfg"); super.new(name); endfunction
  endclass

  class phy_tx_obs extends uvm_object;
    bit [63:0] words[int];      // bram_addr -> data seen by the PHY
    int unsigned n_iq; time t_start, t_started, t_done;
    `uvm_object_utils(phy_tx_obs)
    function new(string name = "phy_tx_obs"); super.new(name); endfunction
    // compare against wifi_frame::bram_words(); only words the PHY actually read are checked
    function string check(wifi_frame f);
      bit [63:0] exp[$]; f.bram_words(exp);
      foreach (exp[k]) begin
        if (k == 1 && !f.ht) continue;            // legacy: word1 not written by tx_intf
        if (!words.exists(k)) return $sformatf("PHY never read word %0d", k);
        if (words[k] !== exp[k]) return $sformatf("word %0d: %016h != exp %016h", k, words[k], exp[k]);
      end
      return "";
    endfunction
  endclass

  typedef uvm_sequencer #(wifi_frame) phy_tx_sequencer;

  // ---------------- TB as tx_intf: serve the BRAM image of each frame to openofdm_tx
  class phy_tx_bram_server extends uvm_driver #(wifi_frame);
    `uvm_component_utils(phy_tx_bram_server)
    virtual phy_tx_if vif; phy_tx_cfg cfg;
    bit [63:0] mem[1024];
    bit abort;                                 // set by a test that resets the PHY mid-packet:
                                               // stop waiting for this frame's phy_tx_done
    uvm_analysis_port #(wifi_frame) sent_ap;   // frame handed to the PHY (for scoreboards)
    function new(string name, uvm_component parent); super.new(name, parent); sent_ap = new("sent_ap", this); endfunction
    task run_phase(uvm_phase phase);
      vif.srv_cb.phy_tx_start <= 0; vif.srv_cb.tx_hold <= 0; vif.srv_cb.bram_din <= '0;
      @(posedge vif.rst_n);
      fork
        forever begin                       // BRAM read port model (latency 1..n)
          bit [9:0] a = vif.srv_cb.bram_addr;
          repeat (cfg.bram_latency - 1) @(vif.srv_cb);
          vif.srv_cb.bram_din <= mem[a];
          @(vif.srv_cb);
        end
        begin                               // back-pressure
          int unsigned occ = 0, div = 0; bit hold = 0;
          forever begin
            @(vif.srv_cb);
            case (cfg.hold_mode)
              HOLD_NONE:   hold = 0;
              HOLD_RANDOM: hold = ($urandom_range(99) < cfg.hold_pct);
              HOLD_FIFO_MODEL: begin
                if (vif.srv_cb.result_iq_valid && !hold) occ++;
                if (++div == cfg.drain_clks) begin div = 0; if (occ) occ--; end
                hold = (occ > cfg.fifo_th);
              end
            endcase
            vif.srv_cb.tx_hold <= hold;
          end
        end
      join_none
      forever begin
        bit [63:0] w[$];
        seq_item_port.get_next_item(req);
        req.bram_words(w);
        foreach (mem[k]) mem[k] = (k < w.size()) ? w[k] : '0;
        sent_ap.write(req);
        abort = 0;
        vif.srv_cb.phy_tx_start <= 1; @(vif.srv_cb); vif.srv_cb.phy_tx_start <= 0;
        do @(vif.srv_cb); while (!vif.srv_cb.phy_tx_done && !abort);
        repeat (cfg.ifs_clks) @(vif.srv_cb);
        seq_item_port.item_done();
      end
    endtask
  endclass

  // ---------------- TB as openofdm_tx
  class phy_tx_acc_model extends uvm_component;
    `uvm_component_utils(phy_tx_acc_model)
    virtual phy_tx_if vif; phy_tx_cfg cfg;
    // expected frames, pushed by the env in DUT order, used to know how much to read/play
    mailbox #(wifi_frame) exp_mb = new();
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    // deterministic I/Q so tx_iq_intf/dac_intf can be checked exactly downstream
    static function void ramp(int unsigned n, output shortint i, output shortint q);
      i = shortint'(16'(n * 3 + 1)); q = shortint'(16'(~(n * 5)));
    endfunction

    task run_phase(uvm_phase phase);
      vif.acc_cb.bram_addr <= 0; vif.acc_cb.result_iq_valid <= 0; vif.acc_cb.phy_tx_started <= 0; vif.acc_cb.phy_tx_done <= 0;
      @(posedge vif.rst_n);
      forever begin
        wifi_frame f; bit [63:0] w[$]; int unsigned n_words, n_iq, sent;
        do @(vif.acc_cb); while (!vif.acc_cb.phy_tx_start);
        if (!exp_mb.try_get(f)) `uvm_error("ACC", "phy_tx_start with no expected frame queued")
        if (f != null) begin f.bram_words(w); n_words = w.size(); n_iq = f.tx_samples(); end
        else begin n_words = 2; n_iq = 400; end
        repeat (cfg.acc_start_latency) @(vif.acc_cb);
        vif.acc_cb.phy_tx_started <= 1; @(vif.acc_cb); vif.acc_cb.phy_tx_started <= 0;
        // read the image word by word (the monitor records what comes back)
        for (int a = 0; a < n_words; a++) begin vif.acc_cb.bram_addr <= a; @(vif.acc_cb); end
        repeat (cfg.bram_latency + 1) @(vif.acc_cb);
        // play out n_iq samples, one per acc_clk_per_sample clocks, stalled by tx_hold
        sent = 0;
        while (sent < n_iq) begin
          shortint i, q;
          ramp(sent, i, q);
          vif.acc_cb.result_i <= i; vif.acc_cb.result_q <= q; vif.acc_cb.result_iq_valid <= 1;
          do @(vif.acc_cb); while (vif.acc_cb.tx_hold);   // valid/ready handshake, ready = ~tx_hold
          vif.acc_cb.result_iq_valid <= 0;
          repeat (cfg.acc_clk_per_sample - 1) @(vif.acc_cb);
          sent++;
        end
        vif.acc_cb.phy_tx_done <= 1; @(vif.acc_cb); vif.acc_cb.phy_tx_done <= 0;
      end
    endtask
  endclass

  class phy_tx_monitor extends uvm_monitor;
    `uvm_component_utils(phy_tx_monitor)
    virtual phy_tx_if vif; phy_tx_cfg cfg;
    uvm_analysis_port #(phy_tx_obs) ap;
    bit trace; int trace_fd, trace_cyc;     // +PHY_TX_TRACE=<file>: per-cycle log of the first packet
    function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
    task run_phase(uvm_phase phase);
      phy_tx_obs o; bit [9:0] a_pipe[$]; string tf;
      if ($value$plusargs("PHY_TX_TRACE=%s", tf)) begin trace = 1; trace_fd = $fopen(tf, "w"); end
      forever begin
        @(vif.mon_cb);
        if (!vif.rst_n) begin o = null; a_pipe.delete(); continue; end
        if (vif.mon_cb.phy_tx_start) begin   // a start with o != null: previous packet aborted, drop it
          o = phy_tx_obs::type_id::create("obs"); o.t_start = $time; a_pipe.delete();
        end
        if (o == null) continue;
        if (trace) $fdisplay(trace_fd, "%0d %03h %016h %0b %0b", ++trace_cyc, vif.mon_cb.bram_addr, vif.mon_cb.bram_din,
                             vif.mon_cb.result_iq_valid, vif.mon_cb.tx_hold);
        // address issued at cycle t is answered at t+latency
        a_pipe.push_back(vif.mon_cb.bram_addr);
        if (a_pipe.size() > cfg.bram_latency) begin
          bit [9:0] a = a_pipe.pop_front();
          if (!o.words.exists(a)) o.words[a] = vif.mon_cb.bram_din;
        end
        if (vif.mon_cb.phy_tx_started) o.t_started = $time;
        if (vif.mon_cb.result_iq_valid && !vif.mon_cb.tx_hold) o.n_iq++;
        if (vif.mon_cb.phy_tx_done) begin
          o.t_done = $time;
          `uvm_info("PHY_TX_MON", $sformatf("tx done: %0d words seen, %0d IQ", o.words.size(), o.n_iq), UVM_MEDIUM)
          ap.write(o); o = null;
          if (trace) begin $fclose(trace_fd); trace = 0; end
        end
      end
    endtask
  endclass

  class phy_tx_agent extends uvm_agent;
    `uvm_component_utils(phy_tx_agent)
    virtual phy_tx_if vif; phy_tx_cfg cfg;
    phy_tx_monitor mon; phy_tx_bram_server srv; phy_tx_sequencer sqr; phy_tx_acc_model acc;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual phy_tx_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", get_full_name())
      if (!uvm_config_db#(phy_tx_cfg)::get(this, "", "cfg", cfg)) cfg = phy_tx_cfg::type_id::create("cfg");
      mon = phy_tx_monitor::type_id::create("mon", this); mon.vif = vif; mon.cfg = cfg;
      case (cfg.role)
        PHY_TX_BRAM_SERVER: begin
          srv = phy_tx_bram_server::type_id::create("srv", this); srv.vif = vif; srv.cfg = cfg;
          sqr = phy_tx_sequencer::type_id::create("sqr", this);
        end
        PHY_TX_ACC_MODEL: begin acc = phy_tx_acc_model::type_id::create("acc", this); acc.vif = vif; acc.cfg = cfg; end
        default: ;
      endcase
    endfunction
    function void connect_phase(uvm_phase phase);
      if (cfg.role == PHY_TX_BRAM_SERVER) srv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass
endpackage
