// openofdm_rx output-side agent.
//   monitor : turns the header/byte/fcs strobes into phy_rx_result (one per MPDU)
//   driver  : emulates openofdm_rx timing from a wifi_frame (rx_intf / xpu / side_ch block TBs)
package phy_rx_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import wifi_pkg::*;

  class phy_rx_result extends uvm_object;
    bit          header_ok, ht_unsupport, ht, sgi, aggr, aggr_last, fcs_ok;
    bit [7:0]    pkt_rate; int unsigned pkt_len;
    byte unsigned bytes[$];
    time         t_preamble, t_header, t_fcs;
    `uvm_object_utils(phy_rx_result)
    function new(string name = "phy_rx_result"); super.new(name); endfunction
    virtual function string convert2string();
      return $sformatf("hdr_ok=%0b rate=0x%02h ht=%0b sgi=%0b len=%0d got=%0d fcs_ok=%0b",
                       header_ok, pkt_rate, ht, sgi, pkt_len, bytes.size(), fcs_ok);
    endfunction
    // compare against what was sent; returns "" when it matches
    function string check(wifi_frame f);
      byte unsigned p[$];
      bit [7:0] exp_rate = f.ht ? {1'b1, 7'(f.rate_hw)} : {4'b0, legacy_rate_code(f.rate_hw)};
      f.psdu(p);
      if (!header_ok)               return "header not valid";
      if (pkt_rate != exp_rate)     return $sformatf("rate 0x%02h != 0x%02h", pkt_rate, exp_rate);
      if (pkt_len != p.size())      return $sformatf("len %0d != %0d", pkt_len, p.size());
      if (f.ht && sgi != f.sgi)     return "sgi mismatch";
      if (bytes.size() < p.size())  return $sformatf("only %0d of %0d bytes", bytes.size(), p.size());
      foreach (p[k]) if (bytes[k] != p[k]) return $sformatf("byte %0d: 0x%02h != 0x%02h", k, bytes[k], p[k]);
      if (!fcs_ok)                  return "fcs_ok=0 with matching bytes";
      return "";
    endfunction
  endclass

  class phy_rx_cfg extends uvm_object;
    int unsigned clk_per_us   = 100;
    bit          fast_mode    = 0;   // driver: compress airtime (byte every 'fast_byte_gap' clocks)
    int unsigned fast_byte_gap = 4;
    `uvm_object_utils(phy_rx_cfg)
    function new(string name = "phy_rx_cfg"); super.new(name); endfunction
  endclass

  class phy_rx_monitor extends uvm_monitor;
    `uvm_component_utils(phy_rx_monitor)
    virtual phy_rx_if vif;
    uvm_analysis_port #(phy_rx_result) ap;
    function new(string name, uvm_component parent); super.new(name, parent); ap = new("ap", this); endfunction
    task run_phase(uvm_phase phase);
      phy_rx_result r; bit in_data, unsup_d; time t_pre;
      forever begin
        @(vif.mon_cb);
        if (!vif.rst_n) begin r = null; in_data = 0; unsup_d = 0; continue; end
        if (vif.mon_cb.long_preamble_detected) t_pre = $time;
        // HT-SIG rejected (dot11.v S_CHECK_HT_SIG -> S_HT_SIG_ERROR) without a header strobe
        if (vif.mon_cb.ht_unsupport && !unsup_d && !vif.mon_cb.pkt_header_valid_strobe) begin
          phy_rx_result u = phy_rx_result::type_id::create("rx_unsup");
          u.ht_unsupport = 1; u.ht = 1; u.t_preamble = t_pre; u.t_header = $time;
          ap.write(u);
        end
        unsup_d = vif.mon_cb.ht_unsupport;
        if (vif.mon_cb.pkt_header_valid_strobe) begin
          r = phy_rx_result::type_id::create("rx");
          r.header_ok = vif.mon_cb.pkt_header_valid; r.ht_unsupport = vif.mon_cb.ht_unsupport;
          r.pkt_rate = vif.mon_cb.pkt_rate; r.pkt_len = vif.mon_cb.pkt_len; r.ht = vif.mon_cb.pkt_rate[7];
          r.sgi = vif.mon_cb.ht_sgi; r.aggr = vif.mon_cb.ht_aggr; r.aggr_last = vif.mon_cb.ht_aggr_last;
          r.t_preamble = t_pre; r.t_header = $time;
          in_data = r.header_ok;
          if (!r.header_ok) begin ap.write(r); r = null; end   // header error / unsupported
          continue;
        end
        if (in_data && vif.mon_cb.byte_out_strobe) r.bytes.push_back(vif.mon_cb.byte_out);
        if (in_data && vif.mon_cb.fcs_out_strobe) begin
          r.fcs_ok = vif.mon_cb.fcs_ok; r.t_fcs = $time;
          `uvm_info("PHY_RX_MON", r.convert2string(), UVM_MEDIUM)
          ap.write(r); in_data = 0; r = null;
        end
      end
    endtask
  endclass

  // stimulus knobs on top of the frame
  class phy_rx_item extends uvm_sequence_item;
    rand wifi_frame frame;
    rand bit corrupt_fcs, header_error, ht_unsupport;
    // A-MPDU subframes the way openofdm_rx reports them (dot11.v S_MPDU_DELIM): one header
    // strobe + bytes + fcs strobe per MPDU, no new preamble after the first (cont=1), and
    // ht_aggr_last only on the last subframe (frame.ht_aggr must be 1)
    bit aggr_last = 1, cont = 0;
    constraint c_default { soft corrupt_fcs == 0; soft header_error == 0; soft ht_unsupport == 0; }
    `uvm_object_utils(phy_rx_item)
    function new(string name = "phy_rx_item"); super.new(name); frame = wifi_frame::type_id::create("frame"); endfunction
  endclass

  typedef uvm_sequencer #(phy_rx_item) phy_rx_sequencer;

  // Emulates dot11.v: preamble (16us legacy / +HT fields), header strobe, PSDU bytes at
  // the air rate, then fcs_out_strobe. Timing follows the PHY so xpu SIFS/ACK timers see
  // realistic gaps; fast_mode shrinks it for data-path-only tests.
  class phy_rx_driver extends uvm_driver #(phy_rx_item);
    `uvm_component_utils(phy_rx_driver)
    virtual phy_rx_if vif; phy_rx_cfg cfg;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction

    task idle();
      vif.drv_cb.demod_is_ongoing <= 0; vif.drv_cb.short_preamble_detected <= 0; vif.drv_cb.long_preamble_detected <= 0;
      vif.drv_cb.pkt_header_valid <= 0; vif.drv_cb.pkt_header_valid_strobe <= 0; vif.drv_cb.ht_unsupport <= 0;
      vif.drv_cb.byte_out_strobe <= 0; vif.drv_cb.fcs_out_strobe <= 0; vif.drv_cb.fcs_ok <= 0;
      vif.drv_cb.csi_valid <= 0; vif.drv_cb.equalizer_valid <= 0; vif.drv_cb.ofdm_symbol_eq_out_pulse <= 0;
      vif.drv_cb.phy_len_valid <= 0;
      vif.drv_cb.phase_offset_taken <= 0; vif.drv_cb.csi <= 0; vif.drv_cb.equalizer <= 0;
      vif.drv_cb.ht_sgi <= 0; vif.drv_cb.ht_aggr <= 0; vif.drv_cb.ht_aggr_last <= 0;
      vif.drv_cb.n_ofdm_sym <= 0; vif.drv_cb.n_bit_in_last_sym <= 0; vif.drv_cb.byte_out <= 0;
    endtask
    task wait_us(real us);
      repeat ($rtoi(us * cfg.clk_per_us)) @(vif.drv_cb);
    endtask
    // 52 equalizer strobes {Q=k+0x200+sym, I=k} and the end-of-symbol pulse
    task eq_symbol(int unsigned sym);
      for (int k = 0; k < 52; k++) begin
        vif.drv_cb.equalizer <= {16'(k + 16'h200 + sym), 16'(k)}; vif.drv_cb.equalizer_valid <= 1; @(vif.drv_cb);
      end
      vif.drv_cb.equalizer_valid <= 0;
      vif.drv_cb.ofdm_symbol_eq_out_pulse <= 1; @(vif.drv_cb); vif.drv_cb.ofdm_symbol_eq_out_pulse <= 0;
    endtask
    task pulse_hdr(bit ok);
      vif.drv_cb.pkt_header_valid <= ok; vif.drv_cb.pkt_header_valid_strobe <= 1; @(vif.drv_cb);
      vif.drv_cb.pkt_header_valid_strobe <= 0;
    endtask

    task run_phase(uvm_phase phase);
      idle(); vif.drv_cb.byte_count <= 0; vif.drv_cb.pkt_rate <= 0; vif.drv_cb.pkt_len <= 0;
      @(posedge vif.rst_n);
      forever begin
        seq_item_port.get_next_item(req);
        drive(req);
        seq_item_port.item_done();
      end
    endtask

    task drive(phy_rx_item it);
      wifi_frame f = it.frame; byte unsigned p[$];
      int unsigned bytes_per_sym = n_dbps(f.ht, f.rate_hw) / 8;
      real sym_us = (f.ht && f.sgi) ? 3.6 : 4.0;
      f.psdu(p);
      if (f.ht_aggr) begin                       // MPDU of an A-MPDU: openofdm_rx strips the delimiter
        bit [31:0] fc; p.delete(); foreach (f.mpdu[k]) p.push_back(f.mpdu[k]);
        fc = crc32(p, p.size()); for (int k = 0; k < 4; k++) p.push_back(fc[8*k +: 8]);
      end
      if (it.corrupt_fcs) p[p.size()-1] ^= 8'h5A;
      vif.drv_cb.demod_is_ongoing <= 1;
      if (!it.cont) begin
        vif.drv_cb.short_preamble_detected <= 1; @(vif.drv_cb); vif.drv_cb.short_preamble_detected <= 0;
        wait_us(cfg.fast_mode ? 1 : 8);
        vif.drv_cb.long_preamble_detected <= 1;  @(vif.drv_cb); vif.drv_cb.long_preamble_detected <= 0;
        wait_us(cfg.fast_mode ? 1 : 12);          // L-LTF rest + L-SIG + decode latency
      end
      vif.drv_cb.pkt_rate <= f.ht ? {1'b1, 7'(f.rate_hw)} : {4'b0, legacy_rate_code(f.rate_hw)};
      vif.drv_cb.pkt_len  <= p.size(); vif.drv_cb.ht_sgi <= f.sgi;
      vif.drv_cb.ht_aggr  <= f.ht_aggr; vif.drv_cb.ht_aggr_last <= f.ht_aggr && it.aggr_last;
      if (!it.cont) eq_symbol(0);                 // L-SIG symbol (side_ch starts counting here)
      if (f.ht && !cfg.fast_mode && !it.cont) wait_us(8);   // HT-SIG
      if (it.header_error || it.ht_unsupport) begin
        vif.drv_cb.ht_unsupport <= it.ht_unsupport;
        pulse_hdr(0); wait_us(2); idle(); return;
      end
      vif.drv_cb.n_ofdm_sym <= f.n_sym(); vif.drv_cb.n_bit_in_last_sym <= (16 + 8*p.size() + 6) % n_dbps(f.ht, f.rate_hw);
      vif.drv_cb.phy_len_valid <= 1;
      pulse_hdr(1);
      vif.drv_cb.phy_len_valid <= 0;
      vif.drv_cb.pkt_header_valid <= 0;
      // channel estimate (one strobe per FFT bin, side_ch keeps 56 of them) and one
      // equalizer output symbol; deterministic pattern {Q=k+0x100, I=k} so the side_ch
      // record can be checked word by word
      for (int k = 0; k < 64; k++) begin
        vif.drv_cb.csi <= {16'(k + 16'h100), 16'(k)}; vif.drv_cb.csi_valid <= 1; @(vif.drv_cb);
      end
      vif.drv_cb.csi_valid <= 0;
      // one equalizer output symbol per data OFDM symbol, as openofdm_rx (side_ch counts
      // ofdm_symbol_eq_out_pulse to find the last symbol of the packet)
      for (int sym = 1; sym <= f.n_sym(); sym++) eq_symbol(sym);
      if (f.ht && !cfg.fast_mode && !it.cont) wait_us(8);   // HT-STF/LTF
      foreach (p[k]) begin
        if (cfg.fast_mode) repeat (cfg.fast_byte_gap) @(vif.drv_cb);
        else wait_us(sym_us / bytes_per_sym);
        // dot11.v: byte_count is the index of the byte during its strobe and counts up after it
        vif.drv_cb.byte_out <= p[k]; vif.drv_cb.byte_count <= k; vif.drv_cb.byte_out_strobe <= 1;
        @(vif.drv_cb); vif.drv_cb.byte_out_strobe <= 0; vif.drv_cb.byte_count <= k + 1;
      end
      // fcs_out_strobe two clocks after the last byte strobe (byte_count == pkt_len in between):
      // rx_intf's byte_to_word_fcs_sn_insert puts {fcs_ok, rx_pkt_sn} into that last byte's slot
      @(vif.drv_cb);
      vif.drv_cb.fcs_ok <= !it.corrupt_fcs; vif.drv_cb.fcs_out_strobe <= 1; vif.drv_cb.byte_count <= 0;
      @(vif.drv_cb);
      vif.drv_cb.fcs_out_strobe <= 0;
      repeat (10) @(vif.drv_cb);
      if (f.ht_aggr && !it.aggr_last) return;   // more subframes follow in the same PPDU
      idle();
    endtask
  endclass

  class phy_rx_agent extends uvm_agent;
    `uvm_component_utils(phy_rx_agent)
    virtual phy_rx_if vif; phy_rx_cfg cfg;
    phy_rx_monitor mon; phy_rx_driver drv; phy_rx_sequencer sqr;
    function new(string name, uvm_component parent); super.new(name, parent); endfunction
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);   // uvm_agent::build_phase reads is_active from the config DB
      if (!uvm_config_db#(virtual phy_rx_if)::get(this, "", "vif", vif)) `uvm_fatal("NOVIF", get_full_name())
      if (!uvm_config_db#(phy_rx_cfg)::get(this, "", "cfg", cfg)) cfg = phy_rx_cfg::type_id::create("cfg");
      mon = phy_rx_monitor::type_id::create("mon", this); mon.vif = vif;
      if (get_is_active() == UVM_ACTIVE) begin
        drv = phy_rx_driver::type_id::create("drv", this); drv.vif = vif; drv.cfg = cfg;
        sqr = phy_rx_sequencer::type_id::create("sqr", this);
      end
    endfunction
    function void connect_phase(uvm_phase phase);
      if (get_is_active() == UVM_ACTIVE) drv.seq_item_port.connect(sqr.seq_item_export);
    endfunction
  endclass
endpackage
