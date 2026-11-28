// Block-level UVM environment for openofdm_rx (dot11 receiver + s_axi + watchdog).
//   stimulus : iq_agent (sample_in / sample_in_strobe, 20 Msps) driven from
//              - openofdm_rx/testing_inputs/** (MATLAB/captured, expectation from file name)
//              - scripts/gen_rx_vectors.py output (random frames, exact PSDU expected, .exp)
//   checks   : per-packet window: header rate/len, PSDU bytes, fcs_ok, no spurious
//              packets, decode latency; RAL reset values.
package openofdm_rx_tb_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import axil_pkg::*; import iq_pkg::*; import wifi_pkg::*; import phy_rx_pkg::*;
  import openwifi_ral_pkg::*; import openwifi_seq_pkg::*;

  // EXP_FULL   : exactly one decode, PSDU exact (generated vectors)
  // EXP_HDR    : exactly one decode, rate/len/fcs from the file name (repo vectors)
  // EXP_NONE   : observed, not checked
  // EXP_REJECT : header must be refused (no header_ok decode); want_unsup: ht_unsupport seen
  // EXP_MULTI  : frames[] back to back in one window, each decoded exactly, in order
  // EXP_SILENT : noise only, nothing may be detected as a packet header
  typedef enum {EXP_FULL, EXP_HDR, EXP_NONE, EXP_REJECT, EXP_MULTI, EXP_SILENT} rx_exp_kind_e;

  class rx_expect extends uvm_object;
    rx_exp_kind_e kind = EXP_NONE;
    wifi_frame    f;                 // EXP_FULL
    bit [7:0]     rate8; int unsigned len; bit sgi;   // EXP_HDR
    bit           want_unsup;                         // EXP_REJECT
    wifi_frame    frames[$];                          // EXP_MULTI
    string        src;
    `uvm_object_utils(rx_expect)
    function new(string name = "rx_expect"); super.new(name); endfunction

    // signal_watchdog drops a frame whose L-SIG LENGTH is outside [MIN_LEN_TH, MAX_LEN_TH]
    // (SOFT_DECODING[15:12] / [31:16], set by ow_rx_init_seq; enforced since fix K)
    static int unsigned min_len_th = 14, max_len_th = 1700;
    // L-SIG LENGTH of a legacy frame, or the one an HT-mixed transmitter puts in L-SIG
    // (802.11-2020 19.3.9.4.3: LENGTH = (TXTIME - 20) / 4 * 3 - 3)
    static function int unsigned lsig_len(bit ht, int unsigned mcs, bit sgi, int unsigned l);
      int unsigned ndbps[8] = '{26, 52, 78, 104, 156, 208, 234, 260};
      int unsigned nsym, txtime;
      if (!ht) return l;
      nsym   = (16 + 8 * l + 6 + ndbps[mcs % 8] - 1) / ndbps[mcs % 8];
      txtime = 36 + (sgi ? 4 * ((nsym * 36 + 39) / 40) : 4 * nsym);   // L-STF..HT-LTF1, then data
      return (txtime - 20) / 4 * 3 - 3;
    endfunction
    static function bit len_dropped(bit ht, int unsigned mcs, bit sgi, int unsigned l);
      int unsigned x = lsig_len(ht, mcs, sgi, l);
      return x < min_len_th || x > max_len_th;
    endfunction

    // expectation from a vector file: <name>.exp sidecar, else the file-name convention
    static function rx_expect from_file(string path);
      rx_expect e = new("e"); string base = path; int fd, ht, r, g, l, a, n;
      e.src = path;
      for (int i = path.len() - 1; i >= 0; i--) if (path[i] == "/") begin base = path.substr(i + 1, path.len() - 1); break; end
      // <name>.rej sidecar (gen_rx_vectors.py --craft): "<want_ht_unsupport> <reason>"
      fd = $fopen({path.substr(0, path.len() - 5), ".rej"}, "r");
      if (fd != 0) begin
        string why; n = $fscanf(fd, "%d %s\n", a, why); $fclose(fd);
        e.want_unsup = a; e.kind = EXP_REJECT; e.src = {path, " [reject: ", why, "]"}; return e;
      end
      fd = $fopen({path.substr(0, path.len() - 5), ".exp"}, "r");
      if (fd != 0) begin
        string hex; e.f = wifi_frame::type_id::create("f");
        n = $fscanf(fd, "%d %d %d %d\n", ht, r, g, l);
        n = $fscanf(fd, "%s\n", hex); $fclose(fd);
        e.f.ht = ht; e.f.rate_hw = r; e.f.sgi = g; e.f.mpdu_len = l; e.f.mpdu = new[l];
        foreach (e.f.mpdu[k]) e.f.mpdu[k] = hex.substr(2*k, 2*k+1).atohex();
        e.kind = EXP_FULL; return e;
      end
      if ($sscanf(base, "ag_%dM_len%d", r, l) == 2) begin
        int unsigned mb[8] = '{6, 9, 12, 18, 24, 36, 48, 54};
        foreach (mb[k]) if (mb[k] == r) e.rate8 = {4'b0, legacy_rate_code(4 + k)};
        e.len = l; e.kind = EXP_HDR;
        if (len_dropped(0, 0, 0, l)) begin e.kind = EXP_REJECT; e.src = {path, " [reject: L-SIG LENGTH > MAX_LEN_TH]"}; end
        return e;
      end
      if ($sscanf(base, "dot11a_%dmbps", r) == 1) begin          // testing_inputs/conducted: rate only
        int unsigned mb[8] = '{6, 9, 12, 18, 24, 36, 48, 54};
        foreach (mb[k]) if (mb[k] == r) e.rate8 = {4'b0, legacy_rate_code(4 + k)};
        e.len = 0; e.kind = EXP_HDR; return e;
      end
      if ($sscanf(base, "ht_mcs%d_gi%d_aggr%d_len%d", r, g, a, l) == 4) begin
        e.rate8 = {1'b1, 7'(r)}; e.sgi = g; e.len = l; e.kind = EXP_HDR;
        if (len_dropped(1, r, g, l)) begin e.kind = EXP_REJECT; e.src = {path, " [reject: L-SIG LENGTH > MAX_LEN_TH]"}; end
        return e;
      end
      return e;   // unknown naming: decode is observed but not checked
    endfunction
  endclass

  class orx_scoreboard extends uvm_subscriber #(phy_rx_result);
    `uvm_component_utils(orx_scoreboard)
    rx_expect cur; phy_rx_result got[$];
    int n_pass, n_fail, n_unchecked;
    bit quiet;               // count only (PER measurements): failures are not UVM errors
    string last_why;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void open_window(rx_expect e); cur = e; got.delete(); endfunction
    function void write(phy_rx_result t);
      if (cur == null) `uvm_error("ORX_SB", {"packet outside any stimulus window: ", t.convert2string()})
      else got.push_back(t);
    endfunction
    // returns 1 when the window met its expectation
    function bit close_window();
      string why = "";
      phy_rx_result ok_r[$];
      bit unsup = 0;
      foreach (got[i]) begin if (got[i].header_ok) ok_r.push_back(got[i]); if (got[i].ht_unsupport) unsup = 1; end
      case (cur.kind)
        EXP_NONE: begin n_unchecked++; cur = null; return 1; end
        EXP_REJECT: begin
          if (ok_r.size()) why = $sformatf("header accepted (%s), expected rejection", ok_r[0].convert2string());
          else if (cur.want_unsup && !unsup) why = "ht_unsupport not raised";
        end
        EXP_SILENT: begin
          if (got.size()) why = $sformatf("%0d spurious header strobe(s) on noise, first: %s", got.size(), got[0].convert2string());
        end
        EXP_MULTI: begin
          if (ok_r.size() != cur.frames.size()) why = $sformatf("%0d decoded packets (expected %0d back to back)", ok_r.size(), cur.frames.size());
          else foreach (cur.frames[k]) if (why == "") begin
            why = ok_r[k].check(cur.frames[k]);
            if (why != "") why = $sformatf("frame %0d: %s", k, why);
          end
        end
        EXP_FULL: begin
          if (ok_r.size() != 1) why = $sformatf("%0d decoded packets (expected 1)", ok_r.size());
          else why = ok_r[0].check(cur.f);
        end
        EXP_HDR: begin
          if (ok_r.size() != 1) why = $sformatf("%0d decoded packets (expected 1)", ok_r.size());
          else if (ok_r[0].pkt_rate != cur.rate8) why = $sformatf("rate 0x%02h != 0x%02h", ok_r[0].pkt_rate, cur.rate8);
          else if (cur.len && ok_r[0].pkt_len != cur.len) why = $sformatf("len %0d != %0d", ok_r[0].pkt_len, cur.len);
          else if (!ok_r[0].fcs_ok)               why = "fcs_ok=0";
        end
      endcase
      last_why = why;
      if (why == "") begin n_pass++; `uvm_info("ORX_SB", {"PASS ", cur.src}, UVM_LOW) end
      else if (quiet) `uvm_info("ORX_SB", {"miss ", cur.src, ": ", why}, UVM_HIGH)
      else begin n_fail++; `uvm_error("ORX_SB", {"FAIL ", cur.src, ": ", why}) end
      cur = null;
      return why == "";
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("ORX_SB", $sformatf("vectors pass %0d  fail %0d  unchecked %0d", n_pass, n_fail, n_unchecked), UVM_NONE)
    endfunction
  endclass

  class orx_env extends uvm_env;
    `uvm_component_utils(orx_env)
    axil_agent axil; iq_agent iq; phy_rx_agent prx; orx_scoreboard sb; ow_cov_pkg::ral_access_cov rcov;
    openofdm_rx_regs regs; axil_reg_adapter adapter;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      iq_cfg ic = iq_cfg::type_id::create("ic");
      ic.pack = PACK_IQ32; ic.valid_style = VALID_PULSE; ic.clk_per_sample = `NUM_CLK_PER_US / 20;
      void'($value$plusargs("IQ_NOISE=%d", ic.noise_amp));
      uvm_config_db#(iq_cfg)::set(this, "iq", "cfg", ic);
      uvm_config_db#(uvm_active_passive_enum)::set(this, "prx", "is_active", UVM_PASSIVE);
      axil = axil_agent::type_id::create("axil", this);
      iq   = iq_agent::type_id::create("iq", this);
      prx  = phy_rx_agent::type_id::create("prx", this);
      sb   = orx_scoreboard::type_id::create("sb", this);
      regs = openofdm_rx_regs::type_id::create("regs"); regs.configure(null); regs.build();
      rcov = ow_cov_pkg::ral_access_cov::type_id::create("rcov", this); rcov.blk = regs;
      adapter = axil_reg_adapter::type_id::create("adapter");
    endfunction
    function void connect_phase(uvm_phase phase);
      axil.mon.ap.connect(rcov.analysis_export);
      regs.default_map.set_sequencer(axil.sqr, adapter);
      regs.default_map.set_auto_predict(1);
      prx.mon.ap.connect(sb.analysis_export);
    endfunction
  endclass

  // plays a list of vector files, one stimulus window per file
  class orx_vector_vseq extends uvm_sequence;
    `uvm_object_utils(orx_vector_vseq)
    orx_env env; string files[$];
    int unsigned gap_samples = 400;     // idle between packets (>= 20 us)
    real drain_us = 60;                 // decode latency allowance after the last sample
    function new(string name = "orx_vector_vseq"); super.new(name); endfunction
    task body();
      foreach (files[i]) begin
        iq_item it = iq_item::type_id::create("it");
        rx_expect e;
        if (!iq_file_util::read(files[i], it)) begin `uvm_error("VEC", {"cannot read ", files[i]}) continue; end
        e = rx_expect::from_file(files[i]);
        it.idle_before = gap_samples;
        env.sb.open_window(e);
        `uvm_info("VEC", $sformatf("[%0d/%0d] %s (%0d samples)", i + 1, files.size(), files[i], it.size()), UVM_LOW)
        env.iq.sqr.execute_item(it);
        #(drain_us * 1us);
        void'(env.sb.close_window());
      end
    endtask
    // +RX_VEC_LIST=<file with one path per line>  or  +RX_VEC=<single file>
    function void load_from_plusargs();
      string lst, one; int fd; string line;
      if ($value$plusargs("RX_VEC=%s", one)) files.push_back(one);
      if ($value$plusargs("RX_VEC_LIST=%s", lst)) begin
        fd = $fopen(lst, "r");
        if (fd == 0) `uvm_fatal("VEC", {"cannot open ", lst})
        while ($fgets(line, fd)) begin
          while (line.len() && (line[line.len()-1] == "\n" || line[line.len()-1] == " ")) line = line.substr(0, line.len() - 2);
          if (line.len() && line[0] != "#") files.push_back(line);
        end
        $fclose(fd);
      end
      if (files.size() == 0) `uvm_fatal("VEC", "no vectors: give +RX_VEC=<file> or +RX_VEC_LIST=<list>")
    endfunction
  endclass

  class orx_base_test extends uvm_test;
    `uvm_component_utils(orx_base_test)
    orx_env env;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase); env = orx_env::type_id::create("env", this); endfunction
    task init_regs();
      openofdm_rx_init_seq s = openofdm_rx_init_seq::type_id::create("init");
      s.rb = env.regs; s.start(null);
    endtask
    // play one item as one window, return the scoreboard verdict
    task play(iq_item it, rx_expect e, int unsigned gap, real drain_us = 60);
      it.idle_before = gap;
      env.sb.open_window(e);
      env.iq.sqr.execute_item(it);
      #(drain_us * 1us);
    endtask
    function iq_item load(string f);
      iq_item it = iq_item::type_id::create("it");
      if (!iq_file_util::read(f, it)) `uvm_fatal("VEC", {"cannot read ", f})
      return it;
    endfunction
  endclass

  // regression entry: list = repo testing_inputs (header/FCS checks) and/or generated
  // vectors (full PSDU checks), e.g. +RX_VEC_LIST=sim/lists/rx_simulated.list
  class orx_vectors_test extends orx_base_test;
    `uvm_component_utils(orx_vectors_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      orx_vector_vseq v = orx_vector_vseq::type_id::create("v");
      phase.raise_objection(this);
      init_regs();
      v.env = env; v.load_from_plusargs();
      v.start(null);
      phase.drop_objection(this);
    endtask
  endclass

  // same vectors with impairments applied in the TB (gain steps, CFO)
  class orx_impair_test extends orx_base_test;
    `uvm_component_utils(orx_impair_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      orx_vector_vseq v = orx_vector_vseq::type_id::create("v");
      real gains[3] = '{0.25, 1.0, 2.0}; real cfos[3] = '{-40e3, 0.0, 40e3};
      phase.raise_objection(this);
      init_regs();
      v.env = env; v.load_from_plusargs();
      foreach (v.files[i]) foreach (gains[g]) begin
        iq_item it = iq_item::type_id::create("it");
        void'(iq_file_util::read(v.files[i], it));
        iq_impair::scale(it, gains[g]); iq_impair::cfo(it, cfos[g]);
        it.idle_before = v.gap_samples;
        env.sb.open_window(rx_expect::from_file(v.files[i]));
        env.iq.sqr.execute_item(it);
        #(v.drain_us * 1us);
        void'(env.sb.close_window());
      end
      phase.drop_objection(this);
    endtask
  endclass

  class orx_reg_reset_test extends orx_base_test;
    `uvm_component_utils(orx_reg_reset_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      uvm_reg_hw_reset_seq rs = uvm_reg_hw_reset_seq::type_id::create("rs");
      phase.raise_objection(this);
      rs.model = env.regs; rs.start(null);
      phase.drop_objection(this);
    endtask
  endclass

  // ORX-06: PER vs SNR. Clean generated vectors (+RX_VEC_LIST, .exp sidecars) get AWGN in
  // the TB at each SNR of +ORX_SNR_LIST (default: required SNR -3, 0, +3 dB per rate);
  // +ORX_N trials per vector and SNR. Pass: PER <= +ORX_PER_MAX (10 %) at the required SNR.
  // Required SNR (provisional): 802.11-2020 minimum sensitivity (Tables 17-18 / 19-23) minus
  // the kTB noise floor of a 20 MHz channel (-101 dBm) and the 10 dB noise figure the
  // standard assumes; the 5 dB implementation margin is left in, so a receiver that meets
  // the standard has a few dB to spare. Override per run with +ORX_SNR_MARGIN=<dB>.
  class orx_snr_sweep_test extends orx_base_test;
    `uvm_component_utils(orx_snr_sweep_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    static function real req_snr(bit ht, int unsigned rate_hw);
      real leg[8] = '{9, 10, 12, 14, 17, 21, 25, 26};   //  6..54 Mbps: -82..-65 dBm + 101 - 10
      real htt[8] = '{9, 12, 14, 17, 21, 25, 26, 27};   // MCS0..7:     -82..-64 dBm + 101 - 10
      return ht ? htt[rate_hw] : leg[rate_hw - 4];
    endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(1000ms, 1); endfunction
    task run_phase(uvm_phase phase);
      orx_vector_vseq v = orx_vector_vseq::type_id::create("v");
      int unsigned n = 10; real per_max = 0.10, margin = 0;
      real offs[$]; string lst;
      int tries[string], hits[string]; bit at_req[string]; real snr_of[string];
      phase.raise_objection(this);
      init_regs();
      v.env = env; v.load_from_plusargs();
      void'($value$plusargs("ORX_N=%d", n));
      if ($value$plusargs("ORX_PER_MAX=%f", per_max)) ;
      if ($value$plusargs("ORX_SNR_MARGIN=%f", margin)) ;
      if ($value$plusargs("ORX_SNR_LIST=%s", lst)) begin
        string t = ""; lst = {lst, ","};
        for (int i = 0; i < lst.len(); i++) if (lst[i] == ",") begin offs.push_back(t.atoreal()); t = ""; end else t = {t, string'(lst[i])};
      end else offs = '{-3.0, 0.0, 3.0};
      env.sb.quiet = 1;
      foreach (v.files[i]) begin
        rx_expect e = rx_expect::from_file(v.files[i]);
        if (e.kind != EXP_FULL) begin `uvm_warning("SNR", {"no .exp, skipped: ", v.files[i]}) continue; end
        foreach (offs[o]) begin
          real snr = req_snr(e.f.ht, e.f.rate_hw) + margin + offs[o];
          string key = $sformatf("%-12s %5.1f dB", e.f.rate_str(), snr);
          snr_of[key] = snr; at_req[key] = (offs[o] == 0.0);
          repeat (n) begin
            iq_item it = load(v.files[i]);
            iq_impair::awgn(it, snr);
            play(it, rx_expect::from_file(v.files[i]), v.gap_samples, v.drain_us);
            tries[key]++; if (env.sb.close_window()) hits[key]++;
          end
        end
      end
      env.sb.quiet = 0;
      foreach (tries[key]) begin
        real per = 1.0 - real'(hits.exists(key) ? hits[key] : 0) / tries[key];
        `uvm_info("SNR", $sformatf("%s  PER %5.1f %%  (%0d/%0d)%s", key, 100.0 * per, tries[key] - (hits.exists(key) ? hits[key] : 0),
                                   tries[key], at_req[key] ? "  <- required SNR" : ""), UVM_NONE)
        if (at_req[key] && per > per_max)
          `uvm_error("SNR", $sformatf("%s: PER %.1f %% > %.1f %% at the required SNR", key, 100.0 * per, 100.0 * per_max))
      end
      phase.drop_objection(this);
    endtask
  endclass

  // ORX-07: crafted headers (gen_rx_vectors.py --craft): L-SIG LENGTH below MIN_LEN_TH /
  // above MAX_LEN_TH, the two boundaries themselves, HT-SIG with MCS>7, 40 MHz, STBC, LDPC,
  // and a one-symbol HT frame. Rejections carry a .rej sidecar. After every vector a clean
  // frame (+ORX_RECOVERY=<file>, default: the first .exp vector of the list) must decode:
  // the receiver may not hang after an early termination (watchdog / S_HT_SIG_ERROR).
  class orx_len_limits_test extends orx_base_test;
    `uvm_component_utils(orx_len_limits_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    task run_phase(uvm_phase phase);
      orx_vector_vseq v = orx_vector_vseq::type_id::create("v");
      string rec = "";
      phase.raise_objection(this);
      init_regs();
      v.env = env; v.load_from_plusargs();
      if (!$value$plusargs("ORX_RECOVERY=%s", rec))
        foreach (v.files[i]) if (rec == "" && rx_expect::from_file(v.files[i]).kind == EXP_FULL) rec = v.files[i];
      if (rec == "") `uvm_fatal("LEN", "no clean recovery vector (+ORX_RECOVERY or an .exp vector in the list)")
      foreach (v.files[i]) begin
        `uvm_info("LEN", v.files[i], UVM_LOW)
        play(load(v.files[i]), rx_expect::from_file(v.files[i]), v.gap_samples, v.drain_us);
        void'(env.sb.close_window());
        play(load(rec), rx_expect::from_file(rec), v.gap_samples, v.drain_us);
        if (!env.sb.close_window()) `uvm_error("LEN", {"receiver did not recover after ", v.files[i]})
      end
      phase.drop_objection(this);
    endtask
  endclass

  // ORX-08: back to back and noise. (1) pairs of vectors in ONE window separated by SIFS
  // (16 us = 320 samples) and by +ORX_GAP_MIN (default 80 samples, 4 us), both must decode;
  // (2) noise-only windows (+IQ_NOISE idle floor plus AWGN-only items at the packets'
  // power) must produce no header strobe at all; (3) every vector again after the noise.
  class orx_b2b_test extends orx_base_test;
    `uvm_component_utils(orx_b2b_test)
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void end_of_elaboration_phase(uvm_phase phase); uvm_top.set_timeout(1000ms, 1); endfunction
    task run_phase(uvm_phase phase);
      orx_vector_vseq v = orx_vector_vseq::type_id::create("v");
      int unsigned gaps[$] = '{320, 80}; int unsigned gmin; string full[$];
      phase.raise_objection(this);
      init_regs();
      v.env = env; v.load_from_plusargs();
      if ($value$plusargs("ORX_GAP_MIN=%d", gmin)) gaps[1] = gmin;
      foreach (v.files[i]) if (rx_expect::from_file(v.files[i]).kind == EXP_FULL) full.push_back(v.files[i]);
      if (full.size() < 2) `uvm_fatal("B2B", "need >= 2 generated (.exp) vectors in the list")
      foreach (gaps[g]) for (int i = 0; i + 1 < full.size(); i += 2) begin
        iq_item a = load(full[i]), b = load(full[i + 1]);
        rx_expect e = rx_expect::type_id::create("e");
        e.kind = EXP_MULTI; e.src = $sformatf("%s + %s, gap %0d samples", full[i], full[i + 1], gaps[g]);
        e.frames.push_back(rx_expect::from_file(full[i]).f); e.frames.push_back(rx_expect::from_file(full[i + 1]).f);
        iq_impair::concat(a, b, gaps[g]);
        play(a, e, v.gap_samples, v.drain_us + 40);
        void'(env.sb.close_window());
      end
      for (int k = 0; k < 10; k++) begin           // noise only: 2000 samples at a packet's power, 10..30 dB below
        iq_item ref_it = load(full[k % full.size()]), nz;
        rx_expect e = rx_expect::type_id::create("e");
        real p = 0; int unsigned cnt = 0;
        foreach (ref_it.i0[j]) if (ref_it.i0[j] != 0) begin p += real'(ref_it.i0[j])**2 + real'(ref_it.q0[j])**2; cnt++; end
        nz = iq_impair::noise(2000, $sqrt(p / cnt) * (10.0 ** (-(10.0 + 2 * k) / 20.0)));
        e.kind = EXP_SILENT; e.src = $sformatf("noise %0.1f dB below packet power", 10.0 + 2 * k);
        play(nz, e, v.gap_samples, 20);
        void'(env.sb.close_window());
      end
      foreach (full[i]) begin
        play(load(full[i]), rx_expect::from_file(full[i]), v.gap_samples, v.drain_us);
        void'(env.sb.close_window());
      end
      phase.drop_objection(this);
    endtask
  endclass

  // every named register read, every writable one written with its own value (RAL coverage)
  class orx_ral_access_test extends orx_base_test;
    `uvm_component_utils(orx_ral_access_test)
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
