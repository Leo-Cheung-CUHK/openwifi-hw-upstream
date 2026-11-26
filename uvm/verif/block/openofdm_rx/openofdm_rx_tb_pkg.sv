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

  typedef enum {EXP_FULL, EXP_HDR, EXP_NONE} rx_exp_kind_e;

  class rx_expect extends uvm_object;
    rx_exp_kind_e kind = EXP_NONE;
    wifi_frame    f;                 // EXP_FULL
    bit [7:0]     rate8; int unsigned len; bit sgi;   // EXP_HDR
    string        src;
    `uvm_object_utils(rx_expect)
    function new(string name = "rx_expect"); super.new(name); endfunction

    // expectation from a vector file: <name>.exp sidecar, else the file-name convention
    static function rx_expect from_file(string path);
      rx_expect e = new("e"); string base = path; int fd, ht, r, g, l, a, n;
      e.src = path;
      for (int i = path.len() - 1; i >= 0; i--) if (path[i] == "/") begin base = path.substr(i + 1, path.len() - 1); break; end
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
        e.len = l; e.kind = EXP_HDR; return e;
      end
      if ($sscanf(base, "dot11a_%dmbps", r) == 1) begin          // testing_inputs/conducted: rate only
        int unsigned mb[8] = '{6, 9, 12, 18, 24, 36, 48, 54};
        foreach (mb[k]) if (mb[k] == r) e.rate8 = {4'b0, legacy_rate_code(4 + k)};
        e.len = 0; e.kind = EXP_HDR; return e;
      end
      if ($sscanf(base, "ht_mcs%d_gi%d_aggr%d_len%d", r, g, a, l) == 4) begin
        e.rate8 = {1'b1, 7'(r)}; e.sgi = g; e.len = l; e.kind = EXP_HDR; return e;
      end
      return e;   // unknown naming: decode is observed but not checked
    endfunction
  endclass

  class orx_scoreboard extends uvm_subscriber #(phy_rx_result);
    `uvm_component_utils(orx_scoreboard)
    rx_expect cur; phy_rx_result got[$];
    int n_pass, n_fail, n_unchecked;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void open_window(rx_expect e); cur = e; got.delete(); endfunction
    function void write(phy_rx_result t);
      if (cur == null) `uvm_error("ORX_SB", {"packet outside any stimulus window: ", t.convert2string()})
      else got.push_back(t);
    endfunction
    function void close_window();
      string why = "";
      phy_rx_result ok_r[$];
      foreach (got[i]) if (got[i].header_ok) ok_r.push_back(got[i]);
      case (cur.kind)
        EXP_NONE: begin n_unchecked++; cur = null; return; end
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
      if (why == "") begin n_pass++; `uvm_info("ORX_SB", {"PASS ", cur.src}, UVM_LOW) end
      else begin n_fail++; `uvm_error("ORX_SB", {"FAIL ", cur.src, ": ", why}) end
      cur = null;
    endfunction
    function void report_phase(uvm_phase phase);
      `uvm_info("ORX_SB", $sformatf("vectors pass %0d  fail %0d  unchecked %0d", n_pass, n_fail, n_unchecked), UVM_NONE)
    endfunction
  endclass

  class orx_env extends uvm_env;
    `uvm_component_utils(orx_env)
    axil_agent axil; iq_agent iq; phy_rx_agent prx; orx_scoreboard sb;
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
      adapter = axil_reg_adapter::type_id::create("adapter");
    endfunction
    function void connect_phase(uvm_phase phase);
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
        env.sb.close_window();
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
        env.sb.close_window();
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
endpackage
